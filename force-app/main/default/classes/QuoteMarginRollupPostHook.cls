global class QuoteMarginRollupPostHook implements RevSignaling.SignalingApexProcessor {

    private static Boolean alreadyExecuted = false;

    // =========================================================
    // BUNDLE MARGIN — context attribute name
    // =========================================================
    // Bundle margin is written through the pricing context, NOT via DML.
    // Two live tests established why:
    //
    //   TEST 1 — bundle-margin QuoteLineItem DML disabled entirely:
    //            Quote.ValidationResult stayed null. ✅
    //   TEST 2 — same DML re-enabled but targeting a plain CUSTOM field
    //            (Bundle_Margin_Percent__c) instead of the standard Margin:
    //            ValidationResult went to 'TransactionIncomplete' again. ❌
    //
    // Conclusion: Revenue Cloud's constraint engine re-validates on ANY
    // modification to a QuoteLineItem record — it is record-level, not
    // field-level. No choice of field avoids it, so no DML-based design can
    // deliver bundle margin without also flagging the quote. (Quote-level DML
    // is fine — TEST 1 still ran `update q` and stayed clean.)
    //
    // The way out is to stop writing after the fact and instead contribute the
    // value DURING the platform's own pricing pass, which is what
    // ctx.updateContextAttributes does — the same mechanism the onboarding and
    // NetUnitPrice blocks below already use every day without ever flagging a
    // quote.
    //
    // An earlier attempt at this pushed the attribute name 'Margin' and
    // silently no-op'd. That was a wrong-name bug, not an unsupported
    // operation: the SalesTransactionItem node inherits a standard margin
    // attribute called ItemMargin__std (see Ascend_SalesTransactionContext,
    // contextAttribute ItemMargin__std). Pushing that name writes margin
    // through the pricing pass, with no QuoteLineItem DML at all.
    // =========================================================
    @TestVisible
    private static String BUNDLE_MARGIN_CONTEXT_ATTRIBUTE = 'ItemMargin__std';

    // =========================================================
    // ONBOARDING FEE DISCOUNT — added constants
    // =========================================================
    private static final Decimal MONTHLY_RATE = 0.008333; // Constant_MonthlyRate from Pricing Procedure

    // One entry per Line of Business with onboarding fee SKUs. principalAmountField
    // / principalMonthlyField are the Quote fields the old declarative Aggregate
    // Price / Formula Based Pricing 1 steps used to populate — kept in sync here
    // (async, in processMarginUpdate) so anything else reading them off the Quote
    // record directly (page layout, reports, Conga) doesn't go stale.
    // oneTimeMultiplier is the multiplier for the non-amortized (one-time) SKU's
    // formula — most LOBs use 1.5, Private Cloud uses 0.5.
    private static final List<OnboardingLobConfig> LOB_CONFIGS = new List<OnboardingLobConfig>{
        new OnboardingLobConfig(
            'Service Desk', '001-DESK-SVC-DESK-MONB-001', '001-DESK-SVC-DESK-ONOB-001',
            'Service_Desk_Principal_Amount__c', 'Service_Desk_Principal_Monthly__c', 1.5
        ),
        new OnboardingLobConfig(
            'Infrastructure', '001-INFR-SVC-INFR-MONB-001', '001-INFR-SVC-INFR-ONOB-001',
            'Infrastructure_Principal_Amount__c', 'Infrastructure_Principal_Monthly__c', 1.5
        ),
        new OnboardingLobConfig(
            'Cybersecurity', '001-CYBR-SVC-CYBR-MONB-001', '001-CYBR-SVC-CYBR-ONOB-001',
            'Cybersecurity_Principal_Amount__c', 'Cybersecurity_Principal_Monthly__c', 1.5
        ),
        new OnboardingLobConfig(
            'Private Cloud', '001-HOST-SVC-HOST-MONB-001', '001-HOST-SVC-HOST-ONOB-001',
            'Private_Cloud_Principal_Amount__c', 'Private_Cloud_Principal_Monthly__c', 0.5
        )
    };

    private static final Set<String> ONBOARDING_SKUS = buildOnboardingSkuSet();

    // =========================================================
    // HAAS HARDWARE / IMPLEMENTATION PRICING (ARM-108)
    // Moved here from JTLPreHook because a pre-hook write to UnitPrice
    // (tag InputUnitPrice) never lands — confirmed live on quote
    // 0Q0VF000002gAxt0AE: PricingTermCount landed correctly at 36 but
    // UnitPrice stayed the raw $223 rate. InputUnitPrice appears reserved
    // for genuine interactive Sales Price keystrokes, not programmatic
    // pre-hook writes. This runs as a POST-hook instead, after the Pricing
    // Procedure, using the same 'UnitPrice'/'UnitPrice' tag pairing the
    // onboarding-fee-discount code below already writes successfully —
    // it reads the PricingTermCount JTLPreHook pushed earlier in this same
    // transaction.
    // =========================================================
    private static final String HAAS_HARDWARE_SKU       = '001-INFR-ASC-HAAS-HAAS-001';
    private static final String HAAS_IMPLEMENTATION_SKU = '001-INFR-SVC-HAAS-IMPL-001';
    private static final Decimal HAAS_IMPL_SELL_RATE    = 223.00;
    private static final Decimal HAAS_IMPL_COST_RATE    = 78.88;

    private static Set<String> buildOnboardingSkuSet() {
        Set<String> skus = new Set<String>();
        for (OnboardingLobConfig cfg : LOB_CONFIGS) {
            skus.add(cfg.monthlySku);
            skus.add(cfg.oneTimeSku);
        }
        return skus;
    }

    public RevSignaling.TransactionResponse execute(
        RevSignaling.TransactionRequest request
    ) {
        RevSignaling.TransactionResponse response =
            new RevSignaling.TransactionResponse();

        try {
            String contextId = request.ctxInstanceId;
            if (String.isBlank(contextId)) {
                return success(response, 'No contextId — skipping');
            }

            Context.IndustriesContext ctx = new Context.IndustriesContext();

            String quoteId = getQuoteId(contextId, ctx);
            System.debug('==QuoteMarginRollup quoteId== ' + quoteId);

            // ---- Onboarding fee discount / amortization pricing ----
            // Runs synchronously and on EVERY invocation (not gated by
            // alreadyExecuted) — pricing must reflect current inputs on every
            // pass, and the write has to land in this same transaction so
            // Subtotal / TCV / MRR recalculate against the discounted amount.
            String onboardingStatus = applyOnboardingFeeDiscounts(contextId, ctx, quoteId);
            System.debug('==OnboardingFeeDiscount status== ' + onboardingStatus);

            // ---- Net/Unit Price fallback for non-onboarding lines ----
            // Salesforce's native Pricing Procedure sometimes leaves UnitPrice/
            // NetUnitPrice blank on Amend lines whose EndDate was just
            // recalculated (see JTLPreHook) — a platform pricing gap we can't
            // fix from outside. Runs synchronously, same transaction, same
            // reason as the onboarding step above.
            String fallbackStatus = applyNetUnitPriceFallback(contextId, ctx, quoteId);
            System.debug('==NetUnitPriceFallback status== ' + fallbackStatus);

            // ---- HaaS Hardware / Implementation pricing (ARM-108) ----
            // Runs synchronously and on EVERY invocation, same reason as
            // the two blocks above — the price has to land in this same
            // transaction so Subtotal / TCV / MRR recalculate correctly.
            String haasStatus = applyHaasPricing(contextId, ctx);
            System.debug('==HaasPricing status== ' + haasStatus);

            // ---- Bundle margin, pushed through the pricing context ----
            // Runs synchronously and on EVERY invocation, like the two blocks
            // above. Writes via ctx.updateContextAttributes rather than DML —
            // see BUNDLE_MARGIN_CONTEXT_ATTRIBUTE at the top of this class for
            // the test evidence behind that choice.
            String bundleMarginStatus = applyBundleMarginViaContext(contextId, ctx, quoteId);
            System.debug('==BundleMargin status== ' + bundleMarginStatus);

            // ---- Async margin rollup (also now carries Principal fields) ----
            if (alreadyExecuted) {
                return success(response, onboardingStatus + ' | ' + fallbackStatus + ' | ' + haasStatus + ' | ' + bundleMarginStatus + ' | Margin rollup already executed — skipping');
            }
            alreadyExecuted = true;

            RevSignaling.TransactionResponse rollupResponse = fireRollup(quoteId, response);
            rollupResponse.message = onboardingStatus + ' | ' + fallbackStatus + ' | ' + haasStatus + ' | ' + bundleMarginStatus + ' | ' + rollupResponse.message;
            return rollupResponse;

        } catch (Exception e) {
            System.debug('==QuoteMarginRollup EXCEPTION== ' + e.getMessage());
            System.debug('==QuoteMarginRollup STACK==     ' + e.getStackTraceString());
            return success(response, 'Hook error — skipped: ' + e.getMessage());
        }
    }

    @TestVisible
    private static RevSignaling.TransactionResponse fireRollup(
        String quoteId,
        RevSignaling.TransactionResponse response
    ) {
        if (String.isBlank(quoteId)) {
            return success(response, 'No quoteId found — skipping');
        }
        QuoteMarginRollupPostHook.updateMarginAsync(quoteId);
        System.debug('==QuoteMarginRollup async fired for quoteId== ' + quoteId);
        return success(response, 'Margin rollup queued');
    }

    @future
    public static void updateMarginAsync(String quoteId) {
        try {
            processMarginUpdate(quoteId);
        } catch (Exception e) {
            System.debug('==updateMarginAsync EXCEPTION== ' + e.getMessage());
            System.debug('==updateMarginAsync STACK==     ' + e.getStackTraceString());
        }
    }

    @TestVisible
    private static void processMarginUpdate(String quoteId) {
        System.debug('==processMarginUpdate START quoteId== ' + quoteId);

        Map<String, Decimal> lobMrrSum  = new Map<String, Decimal>();
        Map<String, Decimal> lobCostSum = new Map<String, Decimal>();

        // LOB margin is now computed on a BOOKED MRR basis:
        //     (Booked_MRR__c - TotalCost) / Booked_MRR__c
        // "Booked MRR" is the same definition used for the Quote's
        // Booked_MRR__c field — recurring lines only (SellingModelType is not
        // 'OneTime'). One-time lines are therefore excluded from BOTH the MRR
        // and the cost side, so numerator and denominator stay on the same
        // population of lines.
        //
        // HaaS Hardware (ARM-108) is deliberately excluded here — it should
        // still contribute to MRR/TCV (see the unfiltered mrrLines query
        // below, which this exclusion does NOT apply to) but never to any
        // LOB's margin percentage, since it has no defined cost basis. Only
        // the Hardware SKU is excluded — Implementation still contributes
        // normally to Onboarding margin.
        List<QuoteLineItem> qliList = [
            SELECT Id, Line_of_Business__c, MRR__c, TotalCost
            FROM   QuoteLineItem
            WHERE  QuoteId = :quoteId
            AND    Line_of_Business__c != null
            AND    SellingModelType    != 'OneTime'
            AND    Product2.StockKeepingUnit != :HAAS_HARDWARE_SKU
        ];

        System.debug('==processMarginUpdate booked QLI count== ' + qliList.size());

        aggregateMrrAndCostByLOB(qliList, lobMrrSum, lobCostSum);

        System.debug('==LOB Booked MRR Map==  ' + lobMrrSum);
        System.debug('==LOB Cost Map==        ' + lobCostSum);

        Map<String, Decimal> lobGrossTotal = new Map<String, Decimal>();

        List<QuoteLineItem> serviceLines = [
            SELECT Line_of_Business__c, ListPrice, Quantity
            FROM   QuoteLineItem
            WHERE  QuoteId              = :quoteId
            AND    Product2.Category__c = 'Services'
            AND    Line_of_Business__c  != null
        ];

        System.debug('==EstEffort Services QLI count== ' + serviceLines.size());

        aggregateGrossByLOB(serviceLines, lobGrossTotal);

        System.debug('==LOB Gross Total Map== ' + lobGrossTotal);

        // Quote-level Booked_MRR__c — same recurring-line definition as the LOB
        // aggregation above, but NOT restricted to lines that carry a Line of
        // Business, so the header figure still reflects the whole quote.
        List<QuoteLineItem> mrrLines = [
            SELECT MRR__c
            FROM   QuoteLineItem
            WHERE  QuoteId          = :quoteId
            AND    SellingModelType != 'OneTime'
            AND    MRR__c           != null
        ];
        System.debug('==Booked MRR QLI count== ' + mrrLines.size());
        Decimal bookedMrr = sumMrr(mrrLines);
        System.debug('==Booked MRR total== ' + bookedMrr);

        Map<String, Decimal> blendRates = new Map<String, Decimal>{
            'Service Desk'   => 145,
            'Infrastructure' => 192,
            'Cybersecurity'  => 185,
            'Private Cloud'  => 202,
            'VOIP'           => 165
        };

        Quote q = new Quote(Id = quoteId);

        // This method only ever runs once a pricing pass (Reprice All, or any
        // save that goes through the pricing engine) has actually completed —
        // that's the signal the reprice banner is waiting for, so clear it here
        // via the same async DML as everything else in this method. Direct DML
        // on Quote inside the synchronous pre/post-hook transaction is not
        // tolerated (see JTLPreHook history) — this @future path is safe.
        q.Term_Change_Requested__c = false;

        q.Margin_Desk__c          = 0;
        q.Margin_Infra__c         = 0;
        q.Margin_Cyber__c         = 0;
        q.Margin_Private_Cloud__c = 0;
        q.Margin_VOIP__c          = 0;
        q.Margin_Onboarding__c    = 0;

        applyMarginToQuote(q, lobMrrSum, lobCostSum);

        q.Est_Hours_Desk__c          = calcEffort('Service Desk',   lobGrossTotal, blendRates);
        q.Est_Hours_Infra__c         = calcEffort('Infrastructure', lobGrossTotal, blendRates);
        q.Est_Hours_Cyber__c         = calcEffort('Cybersecurity',  lobGrossTotal, blendRates);
        q.Est_Hours_Private_Cloud__c = calcEffort('Private Cloud',  lobGrossTotal, blendRates);
        q.Est_Hours_VOIP__c          = calcEffort('VOIP',           lobGrossTotal, blendRates);

        q.Booked_MRR__c = bookedMrr;

        // Total margin = (Σ Booked MRR across all LOBs − Σ TotalCost across all
        // LOBs) / Σ Booked MRR across all LOBs — i.e. the same booked-MRR basis
        // rolled up, not an average of the per-LOB percentages.
        Decimal totalBookedMrr = sumMapValues(lobMrrSum);
        Decimal totalCost      = sumMapValues(lobCostSum);
        q.Margin_Total__c = calcMarginPercent(totalBookedMrr, totalCost);
        System.debug('==Margin_Total__c== bookedMrr=' + totalBookedMrr
            + ' cost=' + totalCost + ' margin=' + q.Margin_Total__c);

        // ─────────────────────────────────────────────────────
        // BLOCK 4 — Onboarding LOB Principal Amount / Monthly
        // Mirrors what the old declarative Aggregate Price + Formula Based
        // Pricing 1 steps used to write onto the Quote. Computed async/DML-safe
        // here rather than in the synchronous pricing hook.
        // ─────────────────────────────────────────────────────
        applyOnboardingPrincipalsToQuote(q, quoteId);

        // NOTE: bundle margin is deliberately NOT written here. It goes out
        // through the pricing context during the synchronous hook instead —
        // see applyBundleMarginViaContext. Writing it with DML from this async
        // job is exactly what was flagging every bundle quote as
        // TransactionIncomplete.

        update q;
        System.debug('==processMarginUpdate Quote DML SUCCESS==');

        // ─────────────────────────────────────────────────────
        // BLOCK 6 — Re-assert pricing freshness (CalculationStatus ONLY)
        // Revenue Cloud re-flags Quote.CalculationStatus as stale on ANY DML
        // touching the Quote — including the `update q` above. Because this
        // job runs async, it lands AFTER the platform's own Calculate pass has
        // already cleared that flag, so our write is what puts it back.
        // CalculationStatus is a plain writable picklist (verified:
        // IsCalculated = false), so we re-assert the healthy value as the
        // FINAL write of this transaction. That's truthful, not a cosmetic
        // override: every field this method writes (Margin_*__c,
        // Booked_MRR__c, Est_Hours_*__c, *_Principal_*__c) is a derived
        // reporting value. None feed the pricing engine — no UnitPrice,
        // NetUnitPrice, Quantity or date is altered — so the pricing the
        // platform just computed genuinely is still current.
        //
        // Quote.ValidationResult is deliberately NOT touched here. It belongs
        // to the Constraint/Configuration engine, not the pricing engine, and
        // is unrelated to anything this class does. Its 'TransactionIncomplete'
        // value means a line carries an unsatisfied cfgStatus:"Required"
        // relation — a Product Configuration Rule wants a component that isn't
        // on the quote (verified against ConstraintEngineNodeStatus__c: quotes
        // showing "Required" entries carry TransactionIncomplete, quotes with
        // only "New"/"User" entries carry null, and the flag predates this
        // class entirely). Nulling it would suppress a real "required product
        // missing" warning and let incomplete configurations reach customers,
        // so that banner must be resolved in the product configuration data,
        // not here.
        //
        // Issued as its own statement, after `update q`, so that a rejection
        // here can never roll back the margin values themselves.
        // ─────────────────────────────────────────────────────
        try {
            update new Quote(
                Id                = quoteId,
                CalculationStatus = 'CompletedWithPricing'
            );
            System.debug('==Quote pricing status re-asserted==');
        } catch (Exception statusEx) {
            // Margins are already committed above; log and move on.
            System.debug('==Quote pricing status reset REJECTED== ' + statusEx.getMessage());
        }
    }

    @TestVisible
    private static void applyOnboardingPrincipalsToQuote(Quote q, String quoteId) {
        try {
            Quote quoteRec = [
                SELECT Contract_Term_Months__c
                FROM   Quote
                WHERE  Id = :quoteId
                LIMIT  1
            ];
            Decimal contractTermMonths = quoteRec.Contract_Term_Months__c;

            List<QuoteLineItem> principalLines = [
                SELECT Line_of_Business__c, NetTotalPrice
                FROM   QuoteLineItem
                WHERE  QuoteId                   = :quoteId
                AND    Product2.Category__c      = 'Services'
                AND    Product2.StockKeepingUnit NOT IN :ONBOARDING_SKUS
                AND    Line_of_Business__c       != null
            ];

            Map<String, Decimal> principalByLob = new Map<String, Decimal>();
            for (QuoteLineItem qli : principalLines) {
                Decimal current = principalByLob.containsKey(qli.Line_of_Business__c)
                    ? principalByLob.get(qli.Line_of_Business__c) : 0;
                principalByLob.put(
                    qli.Line_of_Business__c,
                    current + (qli.NetTotalPrice == null ? 0 : qli.NetTotalPrice)
                );
            }
            System.debug('==applyOnboardingPrincipalsToQuote principalByLob== ' + principalByLob);

            for (OnboardingLobConfig cfg : LOB_CONFIGS) {
                Decimal principalAmt = principalByLob.containsKey(cfg.lineOfBusiness)
                    ? principalByLob.get(cfg.lineOfBusiness) : 0;

                if (String.isNotBlank(cfg.principalAmountField)) {
                    q.put(cfg.principalAmountField, principalAmt);
                }
                if (String.isNotBlank(cfg.principalMonthlyField)
                    && contractTermMonths != null && contractTermMonths > 0) {
                    q.put(cfg.principalMonthlyField, (principalAmt / contractTermMonths).setScale(2));
                }
            }
        } catch (Exception e) {
            System.debug('==applyOnboardingPrincipalsToQuote EXCEPTION== ' + e.getMessage());
            System.debug('==applyOnboardingPrincipalsToQuote STACK==     ' + e.getStackTraceString());
        }
    }

    @TestVisible
    private static void aggregateMrrAndCostByLOB(
        List<QuoteLineItem> qliList,
        Map<String, Decimal> lobMrrSum,
        Map<String, Decimal> lobCostSum
    ) {
        for (QuoteLineItem qli : qliList) {
            String  lob  = qli.Line_of_Business__c;
            Decimal mrr  = qli.MRR__c    != null ? qli.MRR__c    : 0;
            Decimal cost = qli.TotalCost != null ? qli.TotalCost : 0;

            System.debug('==QLI LOB=' + lob + ' | BookedMRR=' + mrr + ' | TotalCost=' + cost);

            Decimal currentMrr  = lobMrrSum.containsKey(lob)  ? lobMrrSum.get(lob)  : 0;
            Decimal currentCost = lobCostSum.containsKey(lob) ? lobCostSum.get(lob) : 0;

            lobMrrSum.put(lob,  currentMrr  + mrr);
            lobCostSum.put(lob, currentCost + cost);
        }
    }

    @TestVisible
    private static void aggregateGrossByLOB(
        List<QuoteLineItem> serviceLines,
        Map<String, Decimal> lobGrossTotal
    ) {
        for (QuoteLineItem qli : serviceLines) {
            String  lob      = qli.Line_of_Business__c;
            Decimal price    = qli.ListPrice != null ? qli.ListPrice : 0;
            Decimal qty      = qli.Quantity  != null ? qli.Quantity  : 0;
            Decimal extended = price * qty;

            System.debug('==EstEffort LOB=' + lob + ' | ListPrice=' + price + ' | Qty=' + qty + ' | Extended=' + extended);

            Decimal current = lobGrossTotal.containsKey(lob) ? lobGrossTotal.get(lob) : 0;
            lobGrossTotal.put(lob, current + extended);
        }
    }

    // Per-LOB margin: (Booked_MRR__c − TotalCost) / Booked_MRR__c, expressed as
    // a percentage on the Quote's Margin_*__c fields.
    @TestVisible
    private static void applyMarginToQuote(
        Quote q,
        Map<String, Decimal> lobMrrSum,
        Map<String, Decimal> lobCostSum
    ) {
        for (String lob : lobMrrSum.keySet()) {
            Decimal bookedMrr = lobMrrSum.get(lob);
            Decimal cost      = lobCostSum.containsKey(lob) ? lobCostSum.get(lob) : 0;
            Decimal margin    = calcMarginPercent(bookedMrr, cost);
            System.debug('==Setting Margin ' + lob + ' = ' + margin + ' (BookedMRR=' + bookedMrr + ', Cost=' + cost + ')');

            if      (lob == 'Service Desk')   q.Margin_Desk__c          = margin;
            else if (lob == 'Infrastructure') q.Margin_Infra__c         = margin;
            else if (lob == 'Cybersecurity')  q.Margin_Cyber__c         = margin;
            else if (lob == 'Private Cloud')  q.Margin_Private_Cloud__c = margin;
            else if (lob == 'VOIP')           q.Margin_VOIP__c          = margin;
            else if (lob == 'Onboarding')     q.Margin_Onboarding__c    = margin;
        }
    }

    // (Revenue − Cost) / Revenue, expressed as a percentage (0–100).
    // revenueTotal == 0/null means there's nothing to divide by — returns 0
    // rather than dividing by zero.
    @TestVisible
    private static Decimal calcMarginPercent(Decimal revenueTotal, Decimal costTotal) {
        if (revenueTotal == null || revenueTotal == 0) {
            return 0;
        }
        Decimal cost = costTotal == null ? 0 : costTotal;
        return (((revenueTotal - cost) / revenueTotal) * 100).setScale(2);
    }

    @TestVisible
    private static Decimal sumMapValues(Map<String, Decimal> values) {
        Decimal total = 0;
        for (Decimal v : values.values()) {
            total += (v == null ? 0 : v);
        }
        return total;
    }

    // =========================================================
    // BUNDLE SKU MARGIN  →  pushed via context as ItemMargin__std
    // Margin = (Σ Bundle_Revenue__c across the bundle's lines
    //           − Σ Total_Per_User_Per_SKU__c across the bundle's lines)
    //          ÷ Σ Bundle_Revenue__c, on a 0–100 percent scale (matches
    //          calcMarginPercent, same as every other Margin_*__c on this
    //          Quote — it's a percent field, so 25.50 must mean 25.5%).
    // Groups bundle line items by their bundle parent (Is_Bundle_Parent__c's
    // own Id, or a child's ParentQuoteLineItemId) and sums Bundle_Revenue__c
    // and Total_Per_User_Per_SKU__c across the whole group — parent AND
    // children — but applies the resulting margin to the bundle PARENT line
    // only. Child lines contribute to the figure without carrying it
    // themselves; non-bundle lines are untouched entirely.
    // =========================================================
    // Orchestrator — reads the quote's lines by SOQL (the same approach the
    // onboarding block uses in this same synchronous hook), computes one
    // margin per bundle parent, then pushes each value through the pricing
    // context on that parent's own salesPath. No DML anywhere in this path,
    // which is the whole point — see BUNDLE_MARGIN_CONTEXT_ATTRIBUTE at the
    // top of this class.
    @TestVisible
    private static String applyBundleMarginViaContext(
        String contextId,
        Context.IndustriesContext ctx,
        String quoteId
    ) {
        try {
            if (String.isBlank(quoteId)) {
                return 'Bundle margin: no quoteId';
            }

            // salesPath per line, straight from the live pricing context —
            // that's how updateContextAttributes addresses nodes.
            Map<Id, List<Object>> salesPathByLineId = new Map<Id, List<Object>>();
            for (Object itemObj : queryOnboardingLineItems(contextId, ctx)) {
                LineItemNodeWrapper li = new LineItemNodeWrapper(itemObj);
                if (!li.isValid() || li.deleted) continue;
                try {
                    Id lineId = (Id) String.valueOf(li.dataPath.get(2));
                    salesPathByLineId.put(lineId, li.salesPath);
                } catch (Exception idEx) {
                    System.debug('==Bundle margin salesPath map skip== ' + idEx.getMessage());
                }
            }

            if (salesPathByLineId.isEmpty()) {
                return 'Bundle margin: no active lines in pricing context';
            }

            Map<Id, Decimal> marginByParent = computeBundleMarginByParent(queryBundleLineData(quoteId));
            if (marginByParent.isEmpty()) {
                return 'Bundle margin: nothing to compute';
            }

            List<Map<String, Object>> updates = new List<Map<String, Object>>();
            for (Id parentLineId : marginByParent.keySet()) {
                List<Object> salesPath = salesPathByLineId.get(parentLineId);
                if (salesPath == null) {
                    System.debug('==Bundle margin SKIPPED== no salesPath for parent ' + parentLineId);
                    continue;
                }
                Decimal margin = marginByParent.get(parentLineId);
                System.debug('==Bundle margin PUSH== parent=' + parentLineId
                    + ' ' + BUNDLE_MARGIN_CONTEXT_ATTRIBUTE + '=' + margin);

                updates.add(buildNodeUpdate(salesPath, new List<List<Object>>{
                    new List<Object>{
                        BUNDLE_MARGIN_CONTEXT_ATTRIBUTE,
                        BUNDLE_MARGIN_CONTEXT_ATTRIBUTE,
                        margin
                    }
                }));
            }

            if (updates.isEmpty()) {
                return 'Bundle margin: no bundle parent lines in pricing context';
            }

            ctx.updateContextAttributes(new Map<String, Object>{
                'contextId'             => contextId,
                'nodePathAndAttributes' => updates
            });
            return 'Bundle margin applied to ' + updates.size() + ' parent line(s) via context';

        } catch (Exception e) {
            System.debug('==applyBundleMarginViaContext EXCEPTION== ' + e.getMessage());
            System.debug('==applyBundleMarginViaContext STACK==     ' + e.getStackTraceString());
            return 'Bundle margin: error — skipped: ' + e.getMessage();
        }
    }

    // Bundle_Revenue__c is itself a formula field and ParentQuoteLineItemId is
    // a read-only system field — Apex can't assign either on a QuoteLineItem
    // (in-memory or via DML), so the pure logic below works off the plain
    // BundleLineData class instead, which has no such restrictions.
    @TestVisible
    private static List<BundleLineData> queryBundleLineData(String quoteId) {
        List<BundleLineData> data = new List<BundleLineData>();
        for (QuoteLineItem qli : [
            SELECT Id, ParentQuoteLineItemId, Is_Bundle_Parent__c,
                   Is_Part_Of_Bundle__c, Bundle_Revenue__c, Total_Per_User_Per_SKU__c
            FROM   QuoteLineItem
            WHERE  QuoteId = :quoteId
        ]) {
            data.add(new BundleLineData(
                qli.Id, qli.Is_Bundle_Parent__c, qli.Is_Part_Of_Bundle__c,
                qli.ParentQuoteLineItemId, qli.Bundle_Revenue__c, qli.Total_Per_User_Per_SKU__c
            ));
        }
        return data;
    }

    // Pure — returns one margin per bundle parent Id. Keyed by parent so the
    // caller can address each bundle's own context node; children contribute
    // to the sums but never appear as keys.
    @TestVisible
    private static Map<Id, Decimal> computeBundleMarginByParent(List<BundleLineData> lines) {
        Map<Id, Decimal> bundleRevenueByGroup = new Map<Id, Decimal>();
        Map<Id, Decimal> perSkuTotalByGroup   = new Map<Id, Decimal>();
        // Only bundle PARENT lines end up carrying the margin. Child lines are
        // still summed into their parent's aggregate (that IS the formula —
        // Σ across the bundle's SKUs) but their own margin is left alone.
        // Collected separately from the aggregation keys so a group whose
        // parent line isn't present on this quote is skipped rather than
        // keyed against a dangling Id.
        Set<Id> parentLineIds = new Set<Id>();
        // Bundle_Revenue__c/Total_Per_User_Per_SKU__c are populated by the
        // platform's bundle pricing engine, which can still be mid-flight
        // when this runs (confirmed via live testing: re-running later against
        // the same quote, once pricing had caught up, correctly computed a
        // non-zero margin). A group where every line's
        // Total_Per_User_Per_SKU__c is null is a sign pricing hasn't reached
        // it yet — tracked here so we skip emitting a misleading 0 for it.
        Set<Id> groupsWithPricedLine = new Set<Id>();

        for (BundleLineData qli : lines) {
            Boolean inBundle = qli.isBundleParent == true || qli.isPartOfBundle == true;
            if (!inBundle) continue;

            Id groupKey = qli.isBundleParent == true ? qli.lineId : qli.parentLineId;
            if (groupKey == null) continue;

            if (qli.isBundleParent == true) {
                parentLineIds.add(qli.lineId);
            }

            Decimal revenue = qli.bundleRevenue      != null ? qli.bundleRevenue      : 0;
            Decimal perSku  = qli.totalPerUserPerSku != null ? qli.totalPerUserPerSku : 0;

            if (qli.totalPerUserPerSku != null) {
                groupsWithPricedLine.add(groupKey);
            }

            bundleRevenueByGroup.put(groupKey,
                (bundleRevenueByGroup.containsKey(groupKey) ? bundleRevenueByGroup.get(groupKey) : 0) + revenue);
            perSkuTotalByGroup.put(groupKey,
                (perSkuTotalByGroup.containsKey(groupKey) ? perSkuTotalByGroup.get(groupKey) : 0) + perSku);
        }

        System.debug('==computeBundleMarginByParent bundleRevenueByGroup== ' + bundleRevenueByGroup);
        System.debug('==computeBundleMarginByParent perSkuTotalByGroup==   ' + perSkuTotalByGroup);
        System.debug('==computeBundleMarginByParent parentLineIds==        ' + parentLineIds);
        System.debug('==computeBundleMarginByParent groupsWithPricedLine== ' + groupsWithPricedLine);

        Map<Id, Decimal> marginByParent = new Map<Id, Decimal>();
        for (Id parentLineId : parentLineIds) {
            if (!groupsWithPricedLine.contains(parentLineId)) {
                System.debug('==computeBundleMarginByParent SKIPPED (pricing not ready)== parent=' + parentLineId);
                continue;
            }
            Decimal margin = calcMarginPercent(
                bundleRevenueByGroup.get(parentLineId), perSkuTotalByGroup.get(parentLineId)
            );
            System.debug('==computeBundleMarginByParent parent=' + parentLineId + ' margin=' + margin);
            marginByParent.put(parentLineId, margin);
        }
        return marginByParent;
    }

    @TestVisible
    private class BundleLineData {
        @TestVisible Id      lineId;
        @TestVisible Boolean isBundleParent;
        @TestVisible Boolean isPartOfBundle;
        @TestVisible Id      parentLineId;
        @TestVisible Decimal bundleRevenue;
        @TestVisible Decimal totalPerUserPerSku;

        @TestVisible
        BundleLineData(
            Id lineId, Boolean isBundleParent, Boolean isPartOfBundle,
            Id parentLineId, Decimal bundleRevenue, Decimal totalPerUserPerSku
        ) {
            this.lineId             = lineId;
            this.isBundleParent     = isBundleParent;
            this.isPartOfBundle     = isPartOfBundle;
            this.parentLineId       = parentLineId;
            this.bundleRevenue      = bundleRevenue;
            this.totalPerUserPerSku = totalPerUserPerSku;
        }
    }

    @TestVisible
    private static Decimal calcEffort(
        String lob,
        Map<String, Decimal> grossMap,
        Map<String, Decimal> rateMap
    ) {
        Decimal gross = grossMap.containsKey(lob) ? grossMap.get(lob) : null;
        Decimal rate  = rateMap.containsKey(lob)  ? rateMap.get(lob)  : null;

        if (gross == null || gross == 0 || rate == null || rate == 0) {
            System.debug('==calcEffort ' + lob + ' → null (gross=' + gross + ', rate=' + rate + ')');
            return null;
        }

        Decimal result = (gross / rate).setScale(2);
        System.debug('==calcEffort ' + lob + ' → ' + gross + ' / ' + rate + ' = ' + result);
        return result;
    }

    @TestVisible
    private static Decimal sumMrr(List<QuoteLineItem> mrrLines) {
        Decimal total = 0;
        for (QuoteLineItem qli : mrrLines) {
            if (qli.MRR__c != null) {
                total += qli.MRR__c;
            }
        }
        return total;
    }

    private static String getQuoteId(
        String contextId,
        Context.IndustriesContext ctx
    ) {
        Map<String, Object> res = null;
        try {
            res = ctx.queryTags(new Map<String, Object>{
                'contextId' => contextId,
                'tags'      => new List<String>{ 'SalesTransaction' }
            });
        } catch (Exception e) {
            System.debug('==getQuoteId error== ' + e.getMessage());
        }
        return parseQuoteId(res);
    }

    @TestVisible
    private static String parseQuoteId(Map<String, Object> res) {
        if (res == null) return null;

        Map<String, Object> queryResult = (Map<String, Object>) res.get('queryResult');
        if (queryResult == null) return null;

        List<Object> nodes = (List<Object>) queryResult.get('SalesTransaction');
        if (nodes == null || nodes.isEmpty()) return null;

        Map<String, Object> tags =
            (Map<String, Object>)
            ((Map<String, Object>) nodes.get(0)).get('tagValue');

        if (tags == null) return null;

        for (String key : tags.keySet()) {
            Object wrapper = tags.get(key);
            if (wrapper instanceof Map<String, Object>) {
                Object val = ((Map<String, Object>) wrapper).get('tagValue');
                if (val != null) {
                    String strVal = String.valueOf(val).trim();
                    if (strVal.startsWith('0Q0') && strVal.length() >= 15) {
                        return strVal;
                    }
                }
            }
        }

        return null;
    }

    @TestVisible
    private static RevSignaling.TransactionResponse success(
        RevSignaling.TransactionResponse res,
        String msg
    ) {
        res.status  = RevSignaling.TransactionStatus.SUCCESS;
        res.message = msg;
        return res;
    }

    // =========================================================
    // ============  ONBOARDING FEE DISCOUNT — ADDED  ============
    // Generalized across LOB_CONFIGS so each Line of Business's onboarding SKUs
    // get their own principal base (Service Desk lines feed Service Desk's
    // principal only, Infrastructure lines feed Infrastructure's principal only,
    // Cybersecurity lines feed Cybersecurity's principal only, Private Cloud
    // lines feed Private Cloud's principal only) rather than being pooled
    // together, and their own one-time multiplier.
    // =========================================================
    // Thin orchestrator — obtains items/quoteId-derived state via the platform
    // and delegates all matching/pricing logic to the pure, directly-testable
    // buildOnboardingUpdates below.
    @TestVisible
    private static String applyOnboardingFeeDiscounts(
        String contextId,
        Context.IndustriesContext ctx,
        String quoteId
    ) {
        try {
            if (String.isBlank(quoteId)) {
                return 'Onboarding: no quoteId';
            }

            List<Object> items = queryOnboardingLineItems(contextId, ctx);
            OnboardingPlanResult plan = buildOnboardingUpdates(items, quoteId);

            if (plan.message != null) {
                return plan.message;
            }

            return pushOnboardingUpdates(ctx, contextId, plan.updates);

        } catch (Exception e) {
            System.debug('==applyOnboardingFeeDiscounts EXCEPTION== ' + e.getMessage());
            System.debug('==applyOnboardingFeeDiscounts STACK==     ' + e.getStackTraceString());
            return 'Onboarding: error — skipped: ' + e.getMessage();
        }
    }

    // Pure matching/pricing logic, extracted verbatim from applyOnboardingFeeDiscounts
    // so it can be tested directly with fabricated items + real Quote/QuoteLineItem
    // data, without needing Context.IndustriesContext to succeed.
    @TestVisible
    private static OnboardingPlanResult buildOnboardingUpdates(List<Object> items, String quoteId) {
        OnboardingPlanResult plan = new OnboardingPlanResult();

        Map<Id, List<Object>> salesPathByLineId = new Map<Id, List<Object>>();
        for (Object itemObj : items) {
            LineItemNodeWrapper li = new LineItemNodeWrapper(itemObj);
            if (!li.isValid() || li.deleted) continue;
            try {
                Id lineId = (Id) String.valueOf(li.dataPath.get(2));
                salesPathByLineId.put(lineId, li.salesPath);
            } catch (Exception idEx) {
                System.debug('==Onboarding salesPath map skip== ' + idEx.getMessage());
            }
        }

        if (salesPathByLineId.isEmpty()) {
            plan.message = 'Onboarding: no active lines in pricing context';
            return plan;
        }

        OnboardingQuoteContext qc = getOnboardingQuoteContext(quoteId);
        System.debug('==Onboarding QuoteContext== contractTerm=' + qc.contractTermMonths
            + ' amortizedTerm=' + qc.amortizedTermMonths
            + ' amortizedFlag=' + qc.onboardingFeeAmortized);

        if (qc.contractTermMonths == null || qc.contractTermMonths <= 0) {
            plan.message = 'Onboarding: Contract Term blank — skipping';
            return plan;
        }

        List<QuoteLineItem> allLines = [
            SELECT Id, Line_of_Business__c, NetTotalPrice, Discount, Quantity,
                   Product2.StockKeepingUnit, Product2.Category__c
            FROM   QuoteLineItem
            WHERE  QuoteId = :quoteId
        ];

        // Principal is computed PER LOB — Service Desk lines only feed
        // Service Desk's principal, Infrastructure lines only feed
        // Infrastructure's principal, Cybersecurity lines only feed
        // Cybersecurity's principal, Private Cloud lines only feed Private
        // Cloud's principal. Onboarding fee lines themselves (any LOB) are
        // always excluded from every principal sum.
        Map<String, Decimal> principalAmountByLob = new Map<String, Decimal>();
        List<QuoteLineItem> onboardingLines = new List<QuoteLineItem>();

        for (QuoteLineItem qli : allLines) {
            String sku = qli.Product2 != null ? qli.Product2.StockKeepingUnit : null;

            if (sku != null && ONBOARDING_SKUS.contains(sku)) {
                onboardingLines.add(qli);
                continue;
            }

            String category = qli.Product2 != null ? qli.Product2.Category__c : null;
            if (category == 'Services' && qli.Line_of_Business__c != null) {
                Decimal current = principalAmountByLob.containsKey(qli.Line_of_Business__c)
                    ? principalAmountByLob.get(qli.Line_of_Business__c) : 0;
                principalAmountByLob.put(
                    qli.Line_of_Business__c,
                    current + (qli.NetTotalPrice == null ? 0 : qli.NetTotalPrice)
                );
            }
        }

        System.debug('==Onboarding principalAmountByLob== ' + principalAmountByLob);

        if (onboardingLines.isEmpty()) {
            plan.message = 'Onboarding: no onboarding fee lines found via SOQL';
            return plan;
        }

        List<Map<String, Object>> updates = new List<Map<String, Object>>();

        for (QuoteLineItem qli : onboardingLines) {
            List<Object> salesPath = salesPathByLineId.get(qli.Id);
            if (salesPath == null) {
                System.debug('==Onboarding SKIPPED== no salesPath for QLI ' + qli.Id);
                continue;
            }

            String sku = qli.Product2.StockKeepingUnit;
            OnboardingLobConfig cfg = findConfigForSku(sku);
            if (cfg == null) {
                System.debug('==Onboarding SKIPPED== no LOB config for sku=' + sku);
                continue;
            }

            String amortizedFlag = qc.onboardingFeeAmortized == null ? null : qc.onboardingFeeAmortized.trim();
            Decimal principalAmount = principalAmountByLob.containsKey(cfg.lineOfBusiness)
                ? principalAmountByLob.get(cfg.lineOfBusiness) : 0;
            Decimal principalMonthly = principalAmount / qc.contractTermMonths;

            try {
                Decimal unitPrice;
                if (sku == cfg.monthlySku && amortizedFlag == 'Yes') {
                    unitPrice = computeAmortizedUnitPrice(
                        principalMonthly, qc.contractTermMonths, qc.amortizedTermMonths
                    );
                    System.debug('==Onboarding MONTHLY branch== lob=' + cfg.lineOfBusiness
                        + ' QLI=' + qli.Id + ' principalMonthly=' + principalMonthly + ' unitPrice=' + unitPrice);
                } else if (sku == cfg.oneTimeSku && amortizedFlag == 'No') {
                    unitPrice = principalMonthly * cfg.oneTimeMultiplier;
                    System.debug('==Onboarding ONETIME branch== lob=' + cfg.lineOfBusiness
                        + ' QLI=' + qli.Id + ' principalMonthly=' + principalMonthly
                        + ' multiplier=' + cfg.oneTimeMultiplier + ' unitPrice=' + unitPrice);
                } else {
                    System.debug('==Onboarding SKIPPED== sku/flag combo did not match (sku=' + sku + ', flag=' + amortizedFlag + ')');
                    continue;
                }

                if (unitPrice == null) {
                    System.debug('==Onboarding SKIPPED== unitPrice null for QLI ' + qli.Id);
                    continue;
                }
                unitPrice = unitPrice.setScale(2, RoundingMode.HALF_UP);

                Decimal discountPct = qli.Discount == null ? 0 : qli.Discount;
                Decimal netUnitPrice = unitPrice * (1 - (discountPct / 100));
                if (netUnitPrice < 0) netUnitPrice = 0;
                netUnitPrice = netUnitPrice.setScale(2, RoundingMode.HALF_UP);

                Decimal quantity = qli.Quantity == null ? 1 : qli.Quantity;
                Decimal netTotalPrice = (netUnitPrice * quantity).setScale(2, RoundingMode.HALF_UP);

                updates.add(buildNodeUpdate(salesPath, new List<List<Object>>{
                    new List<Object>{ 'UnitPrice',     'UnitPrice',     unitPrice     },
                    new List<Object>{ 'NetUnitPrice',  'NetUnitPrice',  netUnitPrice  },
                    new List<Object>{ 'NetTotalPrice', 'NetTotalPrice', netTotalPrice }
                }));

            } catch (Exception lineEx) {
                System.debug('==Onboarding LINE EXCEPTION== QLI=' + qli.Id + ' msg=' + lineEx.getMessage());
                System.debug('==Onboarding LINE STACK==     ' + lineEx.getStackTraceString());
            }
        }

        if (updates.isEmpty()) {
            plan.message = 'Onboarding: no onboarding fee lines to update';
            return plan;
        }

        plan.updates = updates;
        return plan;
    }

    @TestVisible
    private static OnboardingLobConfig findConfigForSku(String sku) {
        if (sku == null) return null;
        for (OnboardingLobConfig cfg : LOB_CONFIGS) {
            if (cfg.monthlySku == sku || cfg.oneTimeSku == sku) return cfg;
        }
        return null;
    }

    // Var1: level monthly annuity payment amortized over n months.
    // Var2: monthlyPayment * n — multiplies back out over the term.
    // Amortized_Term_Months__c == 0 (field defaults to 0 rather than truly null
    // in some quotes) is treated the same as null — falls back to
    // Contract_Term_Months__c instead of forcing n = 0.
    @TestVisible
    private static Decimal computeAmortizedUnitPrice(
        Decimal principalMonthly,
        Decimal contractTermMonths,
        Decimal amortizedTermMonths
    ) {
        Decimal n = (amortizedTermMonths == null || amortizedTermMonths == 0)
            ? contractTermMonths
            : amortizedTermMonths;

        System.debug('==computeAmortizedUnitPrice== principalMonthly=' + principalMonthly
            + ' contractTermMonths=' + contractTermMonths
            + ' amortizedTermMonths=' + amortizedTermMonths
            + ' resolved n=' + n);

        if (n == null || n <= 0) {
            System.debug('==computeAmortizedUnitPrice== n invalid, returning null');
            return null;
        }

        Decimal monthlyPayment;
        if (n == 1) {
            monthlyPayment = principalMonthly;
        } else if (MONTHLY_RATE == 0) {
            monthlyPayment = principalMonthly / n;
        } else {
            Double onePlusR = 1 + MONTHLY_RATE.doubleValue();
            Double factor = Math.pow(onePlusR, n.doubleValue());
            Double annuityFactor = (MONTHLY_RATE.doubleValue() * factor) / (factor - 1);
            monthlyPayment = (principalMonthly * Decimal.valueOf(annuityFactor)) / onePlusR;
        }

        Decimal result = monthlyPayment * n;
        System.debug('==computeAmortizedUnitPrice== monthlyPayment=' + monthlyPayment + ' result=' + result);
        return result;
    }

    @TestVisible
    private static OnboardingQuoteContext getOnboardingQuoteContext(String quoteId) {
        OnboardingQuoteContext qc = new OnboardingQuoteContext();
        if (String.isBlank(quoteId)) return qc;
        try {
            Quote q = [
                SELECT Contract_Term_Months__c,
                       Amortized_Term_Months__c,
                       Onboarding_Fee_Amortized__c
                FROM   Quote
                WHERE  Id = :quoteId
                LIMIT  1
            ];
            qc.contractTermMonths     = q.Contract_Term_Months__c;
            qc.amortizedTermMonths    = q.Amortized_Term_Months__c;
            qc.onboardingFeeAmortized = q.Onboarding_Fee_Amortized__c;
        } catch (Exception e) {
            System.debug('==getOnboardingQuoteContext error== ' + e.getMessage());
        }
        return qc;
    }

    // Thin wrapper — the only line here that touches the platform is the
    // ctx.queryTags call itself; parsing lives in the pure, directly-testable
    // parseOnboardingLineItems below.
    @TestVisible
    private static List<Object> queryOnboardingLineItems(
        String contextId,
        Context.IndustriesContext ctx
    ) {
        Map<String, Object> res = ctx.queryTags(new Map<String, Object>{
            'contextId' => contextId,
            'tags'      => new List<String>{ 'SalesTransactionItem' }
        });
        return parseOnboardingLineItems(res);
    }

    @TestVisible
    private static List<Object> parseOnboardingLineItems(Map<String, Object> res) {
        List<Object> items = (List<Object>)
            ((Map<String, Object>) res.get('queryResult'))
            .get('SalesTransactionItem');

        return items == null ? new List<Object>() : items;
    }

    @TestVisible
    private static Map<String, Object> buildNodeUpdate(
        List<Object> dataPath,
        List<List<Object>> attributes
    ) {
        List<Object> attrs = new List<Object>();
        for (List<Object> pair : attributes) {
            attrs.add(new Map<String, Object>{
                'attributeName'  => pair[0],
                'attributeTag'   => pair[1],
                'attributeValue' => pair[2]
            });
        }
        return new Map<String, Object>{
            'nodePath'   => new Map<String, Object>{ 'dataPath' => dataPath },
            'attributes' => attrs
        };
    }

    private static String pushOnboardingUpdates(
        Context.IndustriesContext ctx,
        String contextId,
        List<Map<String, Object>> updates
    ) {
        try {
            ctx.updateContextAttributes(new Map<String, Object>{
                'contextId'             => contextId,
                'nodePathAndAttributes' => updates
            });
            return 'Onboarding fee discount applied';
        } catch (Exception e) {
            System.debug('==pushOnboardingUpdates ERROR== ' + e.getMessage());
            System.debug('==pushOnboardingUpdates STACK== ' + e.getStackTraceString());
            return 'Onboarding update skipped: ' + e.getMessage();
        }
    }

    // =========================================================
    // ========  HAAS HARDWARE / IMPLEMENTATION PRICING — ADDED (ARM-108)  ========
    // Reads everything off the pricing context tags (not SOQL against
    // QuoteLineItem) so this fires correctly for a HaaS line added in THIS
    // same save — a brand-new line has no persisted QuoteLineItem row yet
    // for a SOQL query to find, but its tag values are already live in the
    // context by the time this post-hook runs.
    // =========================================================
    @TestVisible
    private static String applyHaasPricing(
        String contextId,
        Context.IndustriesContext ctx
    ) {
        try {
            List<Object> items = queryOnboardingLineItems(contextId, ctx);
            List<Map<String, Object>> updates = buildHaasUpdates(items);

            if (updates.isEmpty()) {
                return 'HaaS: no HaaS lines to update';
            }

            ctx.updateContextAttributes(new Map<String, Object>{
                'contextId'             => contextId,
                'nodePathAndAttributes' => updates
            });
            return 'HaaS pricing applied';

        } catch (Exception e) {
            System.debug('==applyHaasPricing EXCEPTION== ' + e.getMessage());
            System.debug('==applyHaasPricing STACK==     ' + e.getStackTraceString());
            return 'HaaS: error — skipped: ' + e.getMessage();
        }
    }

    // Pure matching/pricing logic, separated out the same way
    // buildOnboardingUpdates is, so it can be unit tested with fabricated
    // items and no live Context.IndustriesContext.
    @TestVisible
    private static List<Map<String, Object>> buildHaasUpdates(List<Object> items) {
        List<Map<String, Object>> updates = new List<Map<String, Object>>();

        for (Object itemObj : items) {
            LineItemNodeWrapper li = new LineItemNodeWrapper(itemObj);
            if (!li.isValid() || li.deleted) continue;

            Boolean isHardware = HAAS_HARDWARE_SKU.equals(li.stockKeepingUnit);
            Boolean isImpl     = HAAS_IMPLEMENTATION_SKU.equals(li.stockKeepingUnit);
            if (!isHardware && !isImpl) continue;

            Decimal ptc = li.pricingTermCount;
            if (ptc == null || ptc <= 0) {
                System.debug('==HaaS post-hook SKIPPED== sku=' + li.stockKeepingUnit
                    + ' PricingTermCount unavailable');
                continue;
            }

            Decimal discountPct = li.discount == null ? 0 : li.discount;
            Decimal quantity = String.isNotBlank(li.quantity)
                ? Decimal.valueOf(li.quantity) : 1;

            List<List<Object>> attrs = new List<List<Object>>();

            if (isHardware) {
                if (li.haasHardwareAmount == null) {
                    System.debug('==HaaS post-hook SKIPPED== Hardware line missing HaaS_Hardware_Amount__c');
                    continue;
                }
                Decimal unitPrice = (li.haasHardwareAmount / ptc).setScale(2, RoundingMode.HALF_UP);
                Decimal netUnitPrice = (unitPrice * (1 - (discountPct / 100))).setScale(2, RoundingMode.HALF_UP);
                Decimal netTotalPrice = (netUnitPrice * quantity * ptc).setScale(2, RoundingMode.HALF_UP);

                attrs.add(new List<Object>{ 'UnitPrice',     'UnitPrice',     unitPrice     });
                attrs.add(new List<Object>{ 'NetUnitPrice',  'NetUnitPrice',  netUnitPrice  });
                attrs.add(new List<Object>{ 'NetTotalPrice', 'NetTotalPrice', netTotalPrice });

                System.debug('==HaaS Hardware pricing== amount=' + li.haasHardwareAmount
                    + ' ptc=' + ptc + ' unitPrice=' + unitPrice + ' netTotalPrice=' + netTotalPrice);
            } else {
                Decimal unitPrice = (HAAS_IMPL_SELL_RATE / ptc).setScale(4, RoundingMode.HALF_UP);
                Decimal unitCost  = (HAAS_IMPL_COST_RATE / ptc).setScale(4, RoundingMode.HALF_UP);
                Decimal netUnitPrice = (unitPrice * (1 - (discountPct / 100))).setScale(4, RoundingMode.HALF_UP);
                Decimal netTotalPrice = (netUnitPrice * quantity * ptc).setScale(2, RoundingMode.HALF_UP);

                attrs.add(new List<Object>{ 'UnitPrice',     'UnitPrice',     unitPrice     });
                attrs.add(new List<Object>{ 'UnitCost',      'UnitCost',      unitCost      });
                attrs.add(new List<Object>{ 'NetUnitPrice',  'NetUnitPrice',  netUnitPrice  });
                attrs.add(new List<Object>{ 'NetTotalPrice', 'NetTotalPrice', netTotalPrice });

                System.debug('==HaaS Implementation pricing== ptc=' + ptc + ' hours=' + quantity
                    + ' unitPrice=' + unitPrice + ' unitCost=' + unitCost + ' netTotalPrice=' + netTotalPrice);
            }

            updates.add(buildNodeUpdate(li.salesPath, attrs));
        }

        return updates;
    }

    // =========================================================
    // ========  NET/UNIT PRICE FALLBACK — ADDED  ========
    // Salesforce's native Pricing Procedure sometimes leaves UnitPrice/
    // NetUnitPrice blank on Amend/Renew lines right after their EndDate
    // was recalculated (see JTLPreHook) — confirmed via debug log that
    // our own pre/post-hooks aren't the ones nulling these fields; the
    // native pricing step between them is. Since we can't fix that
    // native step, this fills the gap it leaves: for any non-onboarding
    // line where NetUnitPrice came back blank, price it ourselves from
    // the line's own ListPrice (catalog price) and Discount.
    // =========================================================
    @TestVisible
    private static String applyNetUnitPriceFallback(
        String contextId,
        Context.IndustriesContext ctx,
        String quoteId
    ) {
        try {
            if (String.isBlank(quoteId)) {
                return 'NetUnitPrice fallback: no quoteId';
            }

            List<Object> items = queryOnboardingLineItems(contextId, ctx);
            PriceFallbackPlanResult plan = buildNetUnitPriceFallbackUpdates(items, quoteId);

            if (plan.message != null) {
                return plan.message;
            }

            return pushNetUnitPriceFallbackUpdates(ctx, contextId, plan.updates);

        } catch (Exception e) {
            System.debug('==applyNetUnitPriceFallback EXCEPTION== ' + e.getMessage());
            System.debug('==applyNetUnitPriceFallback STACK==     ' + e.getStackTraceString());
            return 'NetUnitPrice fallback: error — skipped: ' + e.getMessage();
        }
    }

    // Pure matching/pricing logic — mirrors buildOnboardingUpdates above so it
    // can be tested directly with fabricated items + real QuoteLineItem data,
    // without needing Context.IndustriesContext to succeed.
    @TestVisible
    private static PriceFallbackPlanResult buildNetUnitPriceFallbackUpdates(List<Object> items, String quoteId) {
        PriceFallbackPlanResult plan = new PriceFallbackPlanResult();

        Map<Id, List<Object>> salesPathByLineId = new Map<Id, List<Object>>();
        List<Map<String, Object>> updates       = new List<Map<String, Object>>();
        Boolean anyEligibleLine = false;

        for (Object itemObj : items) {
            LineItemNodeWrapper li = new LineItemNodeWrapper(itemObj);
            if (!li.isValid() || li.deleted) continue;
            if (ONBOARDING_SKUS.contains(li.stockKeepingUnit)) continue; // already handled above

            anyEligibleLine = true;

            if (String.isNotBlank(li.netUnitPrice)) {
                continue; // native pricing already set it — leave alone
            }

            Decimal quantity = parseTagDecimal(li.quantity);

            if (quantity != null && quantity < 0) {
                // Cancellation credit line: native pricing leaves UnitPrice/
                // NetUnitPrice blank because a per-unit rate isn't meaningful
                // for a prorated credit (TotalPrice is a lump-sum proration of
                // the original rate, not Quantity * ListPrice). Confirmed via
                // live debug log that Cancel-type lines are represented in the
                // pricing context under a transient node key that does NOT
                // resolve to the line's real QuoteLineItem Id, so a SOQL join
                // (like the ListPrice branch below uses) isn't possible here —
                // and direct DML on UnitPrice/NetUnitPrice is blocked by the
                // platform once a QLI has Quote Line Detail records anyway.
                // Derive the rate purely from this same node's own totals and
                // push it straight through its salesPath — both totals are
                // negative, so the ratio comes out positive and always
                // reconciles with TotalPrice/NetTotalPrice by construction.
                Decimal totalPrice    = parseTagDecimal(li.totalPrice);
                Decimal netTotalPrice = parseTagDecimal(li.netTotalPrice);
                if (totalPrice == null || netTotalPrice == null || li.salesPath == null) {
                    System.debug('==NetUnitPrice fallback SKIPPED (cancel, no totals)== path=' + li.salesPath);
                    continue;
                }
                Decimal unitPrice    = (totalPrice / quantity).setScale(2, RoundingMode.HALF_UP);
                Decimal netUnitPrice = (netTotalPrice / quantity).setScale(2, RoundingMode.HALF_UP);

                System.debug('==NetUnitPrice fallback APPLIED (cancel)== path=' + li.salesPath
                    + ' unitPrice=' + unitPrice + ' netUnitPrice=' + netUnitPrice);

                updates.add(buildNodeUpdate(li.salesPath, new List<List<Object>>{
                    new List<Object>{ 'UnitPrice',    'UnitPrice',    unitPrice    },
                    new List<Object>{ 'NetUnitPrice', 'NetUnitPrice', netUnitPrice }
                }));
                continue;
            }

            try {
                Id lineId = (Id) String.valueOf(li.dataPath.get(2));
                salesPathByLineId.put(lineId, li.salesPath);
            } catch (Exception idEx) {
                System.debug('==NetUnitPrice fallback salesPath map skip== ' + idEx.getMessage());
            }
        }

        if (!anyEligibleLine) {
            plan.message = 'NetUnitPrice fallback: no eligible lines in pricing context';
            return plan;
        }

        if (!salesPathByLineId.isEmpty()) {
            List<QuoteLineItem> qliList = [
                SELECT Id, ListPrice, Discount
                FROM   QuoteLineItem
                WHERE  QuoteId = :quoteId
                AND    Id IN :salesPathByLineId.keySet()
            ];

            for (QuoteLineItem qli : qliList) {
                List<Object> salesPath = salesPathByLineId.get(qli.Id);
                if (salesPath == null || qli.ListPrice == null) {
                    System.debug('==NetUnitPrice fallback SKIPPED== QLI=' + qli.Id + ' listPrice=' + qli.ListPrice);
                    continue;
                }

                Decimal unitPrice = qli.ListPrice.setScale(2, RoundingMode.HALF_UP);
                Decimal discountPct = qli.Discount == null ? 0 : qli.Discount;
                Decimal netUnitPrice = unitPrice * (1 - (discountPct / 100));
                if (netUnitPrice < 0) netUnitPrice = 0;
                netUnitPrice = netUnitPrice.setScale(2, RoundingMode.HALF_UP);

                System.debug('==NetUnitPrice fallback APPLIED== QLI=' + qli.Id
                    + ' unitPrice=' + unitPrice + ' netUnitPrice=' + netUnitPrice);

                updates.add(buildNodeUpdate(salesPath, new List<List<Object>>{
                    new List<Object>{ 'UnitPrice',    'UnitPrice',    unitPrice    },
                    new List<Object>{ 'NetUnitPrice', 'NetUnitPrice', netUnitPrice }
                }));
            }
        }

        if (updates.isEmpty()) {
            plan.message = 'NetUnitPrice fallback: nothing to fix';
            return plan;
        }

        plan.updates = updates;
        return plan;
    }

    @TestVisible
    private static Decimal parseTagDecimal(String tagValue) {
        if (String.isBlank(tagValue)) return null;
        try {
            return Decimal.valueOf(tagValue);
        } catch (Exception e) {
            return null;
        }
    }

    private static String pushNetUnitPriceFallbackUpdates(
        Context.IndustriesContext ctx,
        String contextId,
        List<Map<String, Object>> updates
    ) {
        try {
            ctx.updateContextAttributes(new Map<String, Object>{
                'contextId'             => contextId,
                'nodePathAndAttributes' => updates
            });
            return 'NetUnitPrice fallback applied';
        } catch (Exception e) {
            System.debug('==pushNetUnitPriceFallbackUpdates ERROR== ' + e.getMessage());
            System.debug('==pushNetUnitPriceFallbackUpdates STACK== ' + e.getStackTraceString());
            return 'NetUnitPrice fallback skipped: ' + e.getMessage();
        }
    }

    @TestVisible
    private class PriceFallbackPlanResult {
        @TestVisible List<Map<String, Object>> updates;
        @TestVisible String message; // non-null only for early-exit cases
    }

    @TestVisible
    private class OnboardingPlanResult {
        @TestVisible List<Map<String, Object>> updates;
        @TestVisible String message; // non-null only for early-exit cases
    }

    @TestVisible
    private class OnboardingQuoteContext {
        @TestVisible Decimal contractTermMonths;
        @TestVisible Decimal amortizedTermMonths;
        @TestVisible String  onboardingFeeAmortized;
    }

    @TestVisible
    private class OnboardingLobConfig {
        @TestVisible String  lineOfBusiness;
        @TestVisible String  monthlySku;
        @TestVisible String  oneTimeSku;
        @TestVisible String  principalAmountField;
        @TestVisible String  principalMonthlyField;
        @TestVisible Decimal oneTimeMultiplier;
        OnboardingLobConfig(
            String lineOfBusiness, String monthlySku, String oneTimeSku,
            String principalAmountField, String principalMonthlyField, Decimal oneTimeMultiplier
        ) {
            this.lineOfBusiness        = lineOfBusiness;
            this.monthlySku            = monthlySku;
            this.oneTimeSku            = oneTimeSku;
            this.principalAmountField  = principalAmountField;
            this.principalMonthlyField = principalMonthlyField;
            this.oneTimeMultiplier     = oneTimeMultiplier;
        }
    }
}