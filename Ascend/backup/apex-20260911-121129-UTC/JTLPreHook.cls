global class JTLPreHook implements RevSignaling.SignalingApexProcessor {

    // =========================================================
    // ONBOARDING FEE SKUS (ARM-62)
    // These One-Time products always get a system-calculated
    // 1-month term (Start Date -> Start Date + 1 month, Term
    // Count = 1), regardless of quote type or persisted state —
    // bypassing the normal One-Time-selling-model skip below.
    // =========================================================
    private static final Set<String> ONBOARDING_FEE_SKUS = new Set<String>{
        '001-DESK-SVC-DESK-ONOB-001',
        '001-INFR-SVC-INFR-ONOB-001',
        '001-CYBR-SVC-CYBR-ONOB-001',
        '001-HOST-SVC-HOST-ONOB-001',
        '000-CS-SVC-CS-ONON-001'    
    };

    // =========================================================
    // MONTHLY ONBOARDING FEE SKUS (amortized)
    // These SKUs amortize over Quote.Amortized_Term_Months__c instead of
    // the fixed 1-month term used by ONBOARDING_FEE_SKUS above — EndDate =
    // StartDate + Amortized_Term_Months__c (month-end aligned), PTC = the
    // resulting fractional term. Only applies when Amortized_Term_Months__c
    // is populated; otherwise the line falls through to the normal
    // New Business / Amend-Renew date logic below.
    // =========================================================
    private static final Set<String> MONTHLY_AMORT_SKUS = new Set<String>{
        '001-DESK-SVC-DESK-MONB-001',
        '001-INFR-SVC-INFR-MONB-001',
        '001-CYBR-SVC-CYBR-MONB-001',
        '001-HOST-SVC-HOST-MONB-001'
    };

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

            Context.IndustriesContext ctx =
                new Context.IndustriesContext();

            List<Object> items = queryLineItems(contextId, ctx);
            System.debug('==total items in context== ' + items.size());

            Integer activeCount = countActiveLines(items);
            System.debug('==active lines count== ' + activeCount);

            if (activeCount == 0) {
                return success(response, 'No active lines — skipping date population');
            }

            // =========================================================
            // BUNDLE FLAGGING (Case #473938467)
            // Only the SKU lookup happens up front. The actual
            // Is_Bundle_Parent__c / Is_Part_Of_Bundle__c attributes are
            // merged into the SAME node-update entry as the Start/End
            // Date attributes inside buildLineUpdates below — each line
            // gets exactly ONE entry per updateContextAttributes call,
            // never two competing entries for the same node.
            // buildLineUpdates removes a SKU from these sets once
            // handled; buildStandaloneBundleFlagUpdates covers whatever's
            // left (lines skipped by the date logic, or any early-exit
            // branch below that never reaches it).
            //
            // Is_Bundle_Parent__c = true only on the bundle parent line.
            // Is_Part_Of_Bundle__c = true on the parent AND every child —
            // the whole bundle is priced as one $125 unit (confirmed via
            // DoesBundlePriceIncludeChild=true on all 27 component rows),
            // so minimum-dollar enforcement needs to skip all of them,
            // not just the parent.
            // =========================================================
            BundleSkuInfo bundleInfo = getBundleSkuInfo(items);
            Set<String> bundleParentSkus = bundleInfo.parentSkus;
            Set<String> bundleMemberSkus = bundleInfo.memberSkus;

            TransactionContext tc = build(contextId, ctx);

            System.debug('==tc.quoteStartDate== ' + tc.quoteStartDate);
            System.debug('==tc.contractTerm==   ' + tc.contractTerm);
            System.debug('==tc.quoteType==      ' + tc.quoteType);

            if (String.isBlank(tc.quoteStartDate)) {
                return pushUpdates(ctx, contextId,
                    buildStandaloneBundleFlagUpdates(items, bundleParentSkus, bundleMemberSkus), response,
                    'Start Date blank — bundle flags only');
            }

            // null  -> New Business  (StartDate + Term → EndDate)
            // Amend -> Amendment     (StartDate only, new lines only, EndDate from co-term)
            // Renew -> Renewal       (Quote StartDate propagates to ALL QLIs; EndDate = StartDate + Term)
            Boolean isNewBusiness  = String.isBlank(tc.quoteType);
            Boolean isRenewal      = 'Renew'.equalsIgnoreCase(tc.quoteType);
            Boolean isAmendOrRenew =
                'Amend'.equalsIgnoreCase(tc.quoteType)
                || isRenewal;
            Boolean isCancel = 'Cancel'.equalsIgnoreCase(tc.quoteType);

            if (!isNewBusiness && !isAmendOrRenew) {
                return pushUpdates(ctx, contextId,
                    buildStandaloneBundleFlagUpdates(items, bundleParentSkus, bundleMemberSkus), response,
                    'Unhandled OriginalActionType (' + tc.quoteType + ') — bundle flags only');
            }

            Date startDate     = Date.valueOf(tc.quoteStartDate);
            Date endDate       = null;  // New Business only
            Date coTermEndDate = null;  // Amend/Renew only
            Map<Id, Date> persistedStartDates = new Map<Id, Date>();  // Amend/Renew only

            if (isNewBusiness) {
                if (tc.contractTerm != null && tc.contractTerm > 0) {
                    endDate = monthEndAligned(startDate, tc.contractTerm);
                    System.debug('==New Business endDate== ' + endDate);
                }
                // contractTerm null/zero: may be Order Instant Pricing where the Quote ID
                // is absent from the context. buildLineUpdates falls back to per-line
                // StartDate/EndDate tags for a decimal PricingTermCount — no early return.
            } else {
                coTermEndDate = getContractCoTermEndDate(tc.quoteId);
                System.debug('==Amend/Renew coTermEndDate== ' + coTermEndDate);
                // The transaction context's per-line tag payload only carries
                // attributes actually touched by this save (e.g. a plain
                // Reprice doesn't touch StartDate), so an already-persisted
                // line's own StartDate is frequently absent from li.startDate.
                // Query it directly instead — reliable regardless of what
                // triggered this pricing pass.
                persistedStartDates = getPersistedQLIStartDates(tc.quoteId);
                System.debug('==Amend/Renew persistedStartDates== ' + persistedStartDates);
            }

            List<Map<String, Object>> updates = buildLineUpdates(
                items, startDate, endDate, coTermEndDate, isNewBusiness,
                tc.contractTerm, persistedStartDates, isRenewal,
                bundleParentSkus, bundleMemberSkus, tc.amortizedTermMonths
            );

            // Anything left in these sets was skipped by the date logic
            // (ramp segment / persisted Amend-Renew line / One-Time
            // selling model) — still needs its own flag-only entry.
            updates.addAll(buildStandaloneBundleFlagUpdates(items, bundleParentSkus, bundleMemberSkus));

            System.debug('==updates count== ' + updates.size());

            return pushUpdates(ctx, contextId, updates, response,
                'Dates and bundle flags populated successfully');

        } catch (Exception e) {
            System.debug('==JTLPreHook EXCEPTION== ' + e.getMessage());
            System.debug('==JTLPreHook STACK==     ' + e.getStackTraceString());
            return success(response, 'Hook error — skipped: ' + e.getMessage());
        }
    }

    // =========================================================
    // GET CONTRACT CO-TERM END DATE (Amend/Renew only)
    // Most common EndDate among existing non-OneTime, non-Ramp
    // lines on the quote — via SOQL on QuoteLineItem directly.
    // RampIdentifier is the actual SOQL field name on QLineItem.
    // =========================================================
    @TestVisible
    private static Date getContractCoTermEndDate(String quoteId) {
        if (String.isBlank(quoteId)) return null;

        Map<Date, Integer> endDateCounts = new Map<Date, Integer>();
        try {
            for (QuoteLineItem qli : [
                SELECT EndDate
                FROM   QuoteLineItem
                WHERE  QuoteId          = :quoteId
                AND    EndDate          != null
                AND    RampIdentifier   = null
                AND    SellingModelType != 'OneTime'
            ]) {
                Integer cnt = endDateCounts.containsKey(qli.EndDate)
                    ? endDateCounts.get(qli.EndDate) : 0;
                endDateCounts.put(qli.EndDate, cnt + 1);
            }
        } catch (Exception e) {
            System.debug('==getContractCoTermEndDate SOQL error== ' + e.getMessage());
            return null;
        }

        Date    best      = null;
        Integer bestCount = -1;
        for (Date d : endDateCounts.keySet()) {
            if (endDateCounts.get(d) > bestCount) {
                bestCount = endDateCounts.get(d);
                best = d;
            }
        }
        System.debug('==endDateCounts== ' + endDateCounts + ' | chosen== ' + best);
        return best;
    }

    // =========================================================
    // GET PERSISTED QLI START DATES (Amend/Renew only)
    // AC1 needs each persisted line's own StartDate to recalc EndDate,
    // but the transaction context's per-line tag payload only carries
    // attributes actually touched by the current save (e.g. Reprice
    // All doesn't touch StartDate) — so li.startDate is unreliable for
    // an unedited persisted line. Query it directly instead.
    // =========================================================
    @TestVisible
    private static Map<Id, Date> getPersistedQLIStartDates(String quoteId) {
        Map<Id, Date> startDates = new Map<Id, Date>();
        if (String.isBlank(quoteId)) return startDates;

        try {
            for (QuoteLineItem qli : [
                SELECT Id, StartDate
                FROM   QuoteLineItem
                WHERE  QuoteId   = :quoteId
                AND    StartDate != null
            ]) {
                startDates.put(qli.Id, qli.StartDate);
            }
        } catch (Exception e) {
            System.debug('==getPersistedQLIStartDates SOQL error== ' + e.getMessage());
        }
        return startDates;
    }

    // =========================================================
    // COUNT ACTIVE (NON-DELETED) LINES
    // =========================================================
    @TestVisible
    private static Integer countActiveLines(List<Object> items) {
        Integer count = 0;
        for (Object obj : items) {
            try {
                Map<String, Object> node = (Map<String, Object>) obj;

                Object rawDel = node.get('deleted');
                if (rawDel != null && Boolean.valueOf(String.valueOf(rawDel))) continue;

                Object rawDel2 = node.get('isDeleted');
                if (rawDel2 != null && Boolean.valueOf(String.valueOf(rawDel2))) continue;

                Map<String, Object> tv = (Map<String, Object>) node.get('tagValue');
                if (tv != null) {
                    if (isTagTrue(tv, 'IsDeleted')) continue;
                    if (isTagTrue(tv, 'Deleted'))   continue;
                }

                count++;
            } catch (Exception e) {}
        }
        return count;
    }

    // =========================================================
    // BUILD TRANSACTION CONTEXT
    // =========================================================
    // Thin wrapper — the only line here that touches the platform is the
    // ctx.queryTags call itself; all parsing logic lives in the pure,
    // directly-testable parseContextData below.
    @TestVisible
    private static TransactionContext build(
        String contextId,
        Context.IndustriesContext ctx
    ) {
        Map<String, Object> res = ctx.queryTags(new Map<String, Object>{
            'contextId' => contextId,
            'tags'      => new List<String>{ 'SalesTransaction' }
        });
        return parseContextData(res);
    }

    @TestVisible
    private static TransactionContext parseContextData(Map<String, Object> res) {
        TransactionContext tc = new TransactionContext();

        Map<String, Object> queryResult =
            (Map<String, Object>) res.get('queryResult');
        if (queryResult == null) return tc;

        List<Object> nodes = (List<Object>) queryResult.get('SalesTransaction');
        if (nodes == null || nodes.isEmpty()) return tc;

        Map<String, Object> tags =
            (Map<String, Object>)
            ((Map<String, Object>) nodes.get(0)).get('tagValue');
        if (tags == null) return tc;

        tc.quoteStartDate = extractTagDate(tags, 'StartDate');

        // Scan all header tags for the Quote Id (starts with 0Q0)
        for (String key : tags.keySet()) {
            try {
                Object wrapper = tags.get(key);
                if (wrapper instanceof Map<String, Object>) {
                    Object val = ((Map<String, Object>) wrapper).get('tagValue');
                    if (val != null) {
                        String strVal = String.valueOf(val).trim();
                        if (strVal.startsWith('0Q0') && strVal.length() >= 15) {
                            tc.quoteId = strVal;
                            break;
                        }
                    }
                }
            } catch (Exception e) {}
        }

        if (String.isNotBlank(tc.quoteId)) {
            try {
                Quote q = [
                    SELECT Contract_Term_Months__c, OriginalActionType, Amortized_Term_Months__c
                    FROM   Quote
                    WHERE  Id = :tc.quoteId
                    LIMIT  1
                ];
                if (q.Contract_Term_Months__c != null) {
                    tc.contractTerm = Integer.valueOf(q.Contract_Term_Months__c);
                }
                if (q.Amortized_Term_Months__c != null) {
                    tc.amortizedTermMonths = Integer.valueOf(q.Amortized_Term_Months__c);
                }
                tc.quoteType = q.OriginalActionType;
            } catch (Exception e) {
                System.debug('==SOQL error== ' + e.getMessage());
            }
        }

        return tc;
    }

    // =========================================================
    // QUERY LINE ITEMS
    // =========================================================
    // Thin wrapper — the only line here that touches the platform is the
    // ctx.queryTags call itself; all parsing logic lives in the pure,
    // directly-testable parseLineItems below.
    @TestVisible
    private static List<Object> queryLineItems(
        String contextId,
        Context.IndustriesContext ctx
    ) {
        Map<String, Object> res = ctx.queryTags(new Map<String, Object>{
            'contextId' => contextId,
            'tags'      => new List<String>{ 'SalesTransactionItem' }
        });
        return parseLineItems(res);
    }

    @TestVisible
    private static List<Object> parseLineItems(Map<String, Object> res) {
        List<Object> items = (List<Object>)
            ((Map<String, Object>) res.get('queryResult'))
            .get('SalesTransactionItem');

        return items == null ? new List<Object>() : items;
    }

    // =========================================================
    // BUILD UPDATES
    // =========================================================
    // Backward-compatible overload — preserves the original 7-parameter
    // signature exactly (existing JTLPreHookTest.cls callers untouched).
    // Delegates to the ARM-106 signature below with no Contract Term (New
    // Business / Amend-Renew new-line callers never had a term to pass).
    @TestVisible
    private static List<Map<String, Object>> buildLineUpdates(
        List<Object> items,
        Date startDate,
        Date endDate,
        Date coTermEndDate,
        Boolean isNewBusiness,
        Set<String> bundleParentSkus,
        Set<String> bundleMemberSkus
    ) {
        return buildLineUpdates(
            items, startDate, endDate, coTermEndDate, isNewBusiness,
            null, new Map<Id, Date>(), false,
            bundleParentSkus, bundleMemberSkus, null
        );
    }

    @TestVisible
    private static List<Map<String, Object>> buildLineUpdates(
        List<Object> items,
        Date startDate,
        Date endDate,         // New Business: Start + Term
        Date coTermEndDate,   // Amend/Renew: pulled from existing lines via SOQL
        Boolean isNewBusiness,
        Integer contractTerm,    // ARM-106 AC1: persisted Amend/Renew lines — EndDate = StartDate + Term
        Map<Id, Date> persistedStartDates,  // ARM-106 AC1: queried StartDate per persisted line, keyed by Id
        Boolean isRenewal,   // Renewal: Quote StartDate propagates to every QLI; EndDate = StartDate + Term
        Set<String> bundleParentSkus,  // mutated: SKUs handled here are removed
        Set<String> bundleMemberSkus,  // mutated: SKUs handled here are removed
        Integer amortizedTermMonths  // Quote.Amortized_Term_Months__c — MONTHLY_AMORT_SKUS only
    ) {
        List<Map<String, Object>> updates = new List<Map<String, Object>>();

        for (Integer i = 0; i < items.size(); i++) {

            LineItemNodeWrapper li = new LineItemNodeWrapper(items.get(i));

            if (!li.isValid() || li.deleted) {
                System.debug('==item[' + i + '] SKIPPED — invalid or deleted==');
                continue;
            }
            try {
                if (li.quantity != null && Decimal.valueOf(li.quantity) == 0) {
                    // Persisted Amend/Renew cancellation lines: set PTC from contract term
                    // so it stays consistent with Quote.Contract_Term_Months__c.
                    // Dates are left untouched — Revenue Cloud owns them for credit prorations.
                    if (!isNewBusiness && li.isPersisted() && contractTerm != null) {
                        updates.add(buildNodeUpdate(li.salesPath, new List<List<Object>>{
                            new List<Object>{ 'PricingTermCount', 'PricingTermCount', (Decimal) contractTerm }
                        }));
                        System.debug('==item[' + i + '] Qty=0 persisted AmendRenew — PTC set to contractTerm=' + contractTerm);
                    } else {
                        System.debug('==item[' + i + '] SKIPPED — zero quantity==');
                    }
                    continue;
                }
            } catch (Exception e) { /* non-numeric quantity tag — proceed */ }

            // Bundle flags (Is_Bundle_Parent__c / Is_Part_Of_Bundle__c) are only
            // ever (re)derived for lines newly added in this transaction. A line
            // that already has a real persisted Id was saved on a prior
            // transaction — if it was standalone then, it stays standalone now,
            // even if some other bundle added in THIS transaction happens to
            // share its SKU. Without this guard, adding e.g. the Core Support
            // bundle (whose catalog children include the same SKU as an
            // unrelated, already-persisted standalone line) flips that
            // unrelated line's Is_Part_Of_Bundle__c to true, which then makes
            // it wrongly skip minimum-dollar-amount enforcement.
            Boolean isNewLine = !li.isPersisted();

            // ✅ RAMP EXCLUSION — uses ItemSegmentIdentifier context tag.
            // Any line with a non-blank segment identifier is a ramp segment;
            // its per-segment Start/End dates come from user entry in the
            // ramp group UI and must never be overwritten by this hook.
            if (String.isNotBlank(li.segmentIdentifier)) {
                System.debug('==item[' + i + '] SKIPPED — Ramp segment, ItemSegmentIdentifier='
                    + li.segmentIdentifier);
                continue;
            }

            // ✅ ONBOARDING FEE SKUS (ARM-62) — system-calculated 1-month
            // term, independent of quote type / persisted state / selling
            // model. Handled before the persisted-line and One-Time skips
            // below so it applies whether this is a brand-new line or an
            // existing onboarding fee line whose Start Date changed.
            if (ONBOARDING_FEE_SKUS.contains(li.stockKeepingUnit)) {
                System.debug('==item[' + i + '] Onboarding Fee SKU=' + li.stockKeepingUnit
                    + ' | startDate=' + startDate);

                List<List<Object>> onboardingAttributes = new List<List<Object>>{
                    new List<Object>{ 'StartDate',        'EffectiveFrom',    startDate              },
                    new List<Object>{ 'EndDate',          'EffectiveTo',      startDate.addMonths(1) - 1 },
                    new List<Object>{ 'PricingTermCount', 'PricingTermCount', 1                      }
                };

                if (isNewLine) {
                    appendBundleAttributes(onboardingAttributes, li.stockKeepingUnit,
                        bundleParentSkus, bundleMemberSkus);
                }

                updates.add(buildNodeUpdate(li.salesPath, onboardingAttributes));
                continue;
            }

            // ✅ MONTHLY ONBOARDING FEE SKUS (amortized) — EndDate = StartDate
            // + Quote.Amortized_Term_Months__c (month-end aligned), PTC = the
            // resulting fractional term (e.g. ~12.53 for a mid-month start).
            // Applies on every quote type, same as the Onboarding Fee branch
            // above, but only when Amortized_Term_Months__c is populated —
            // when it's null the line falls through to the normal date logic
            // below instead of a separate fallback branch.
            if (MONTHLY_AMORT_SKUS.contains(li.stockKeepingUnit) && amortizedTermMonths != null) {
                Date amortEndDate = monthEndAligned(startDate, amortizedTermMonths);
                Decimal amortPTC  = calcLineItemPTC(startDate, amortEndDate);

                System.debug('==item[' + i + '] Monthly Amortized Fee SKU=' + li.stockKeepingUnit
                    + ' | startDate=' + startDate + ' | amortEndDate=' + amortEndDate
                    + ' | amortizedTermMonths=' + amortizedTermMonths + ' | ptc=' + amortPTC);

                List<List<Object>> amortAttributes = new List<List<Object>>{
                    new List<Object>{ 'StartDate',        'EffectiveFrom',    startDate    },
                    new List<Object>{ 'EndDate',          'EffectiveTo',      amortEndDate },
                    new List<Object>{ 'PricingTermCount', 'PricingTermCount', amortPTC     }
                };

                if (isNewLine) {
                    appendBundleAttributes(amortAttributes, li.stockKeepingUnit,
                        bundleParentSkus, bundleMemberSkus);
                }

                updates.add(buildNodeUpdate(li.salesPath, amortAttributes));
                continue;
            }

            System.debug('==item[' + i + '] lineItemId=' + String.valueOf(li.dataPath.get(2))
                + ' | isNewLine=' + isNewLine
                + ' | isNewBusiness=' + isNewBusiness);

            Boolean isPersistedAmendRenew = !isNewBusiness && !isNewLine;

            String sellingModel = li.sellingModelType;
            if (String.isBlank(sellingModel)) {
                sellingModel = scanSellingModelFromTags(li.tags);
            }

            if (isOneTimeSelling(sellingModel)) {
                System.debug('==item[' + i + '] SKIPPED — One Time selling model==');
                continue;
            }

            List<List<Object>> attributes = new List<List<Object>>();

            if (isPersistedAmendRenew) {
                // Renewal: every persisted line adopts the quote's current StartDate
                // (the new renewal date) so all QLIs stay aligned with the header.
                // Amendment: each line keeps its own original StartDate (co-term
                // logic — lines end on the same date regardless of when each started).
                //
                // For both: EndDate = lineStartDate + Contract Term, recalculated
                // inside this pricing transaction so EndDate and the recalculated
                // Net/Unit Price land in the same pass (unlike a backend Flow
                // recordUpdate which would leave prices stale).
                //
                // For Amendment: li.startDate only carries attributes touched by this
                // save (Reprice doesn't touch StartDate), so persistedStartDates
                // (queried from DB in execute()) is authoritative.
                // For Renewal: use Quote Start Date so all QLIs align to the renewal date.
                // persistedStartDates is queried for both Renewal and Amendment so we can
                // compare and only push StartDate when it has actually changed — avoids
                // triggering RC's AssetStatePeriod recreation on every Reprice, which causes
                // a concurrent-lock error ("asset was updated by another process") when
                // multiple QLIs all send a StartDate attribute in the same pricing pass.
                Date persistedLineStart = persistedStartDates.get(Id.valueOf(String.valueOf(li.dataPath.get(2))));
                Date lineStartDate;
                if (isRenewal) {
                    lineStartDate = startDate;
                } else {
                    lineStartDate = persistedLineStart;
                    if (lineStartDate == null && String.isNotBlank(li.startDate)) {
                        lineStartDate = Date.valueOf(li.startDate);
                    }
                }

                if (contractTerm != null && lineStartDate != null) {
                    Date recalcEndDate = monthEndAligned(lineStartDate, contractTerm);
                    // Derive PTC from recalcEndDate (the EndDate this hook is setting),
                    // not from li.endDate (the stale EndDate from the prior pricing pass).
                    // Using li.endDate caused PTC to reflect the old date range while EndDate
                    // was updated to the new range — PTC=9 with EndDate=2027-11-30, for example.
                    Decimal decPTC = calcLineItemPTC(lineStartDate, recalcEndDate);
                    Decimal ptcToSet = decPTC != null ? decPTC : (Decimal) contractTerm;
                    // Only push StartDate when the Quote Start Date differs from the persisted
                    // QLI StartDate. Pushing it unconditionally on every Reprice causes RC to
                    // recreate AssetStatePeriods for all lines simultaneously → concurrent
                    // Asset lock error.
                    if (isRenewal && (persistedLineStart == null || persistedLineStart != lineStartDate)) {
                        attributes.add(new List<Object>{ 'StartDate', 'EffectiveFrom', lineStartDate });
                    }
                    attributes.add(new List<Object>{ 'EndDate', 'EffectiveTo', recalcEndDate });
                    attributes.add(new List<Object>{ 'PricingTermCount', 'PricingTermCount', ptcToSet });
                    System.debug('==item[' + i + '] ' + (isRenewal ? 'Renewal' : 'Amend')
                        + ' recalculated dates== lineStart=' + lineStartDate
                        + ' persistedStart=' + persistedLineStart
                        + ' term=' + contractTerm + ' endDate=' + recalcEndDate + ' ptc=' + ptcToSet);
                } else if (String.isNotBlank(li.startDate) && String.isNotBlank(li.endDate)) {
                    // contractTerm or StartDate lookup absent but per-line dates present.
                    Date lineSD = Date.valueOf(li.startDate);
                    Date lineED = Date.valueOf(li.endDate);
                    Decimal decPTC = calcLineItemPTC(lineSD, lineED);
                    if (decPTC != null) {
                        attributes.add(new List<Object>{ 'PricingTermCount', 'PricingTermCount', decPTC });
                    }
                    System.debug('==item[' + i + '] Amend/Renew per-line PTC== sd=' + lineSD + ' ed=' + lineED + ' ptc=' + decPTC);
                } else {
                    System.debug('==item[' + i + '] SKIPPED — persisted Amend/Renew line missing term or StartDate==');
                    continue;
                }
            } else {
                // New Business: endDate = startDate + contractTerm (set in execute())
                // Renewal new lines: EndDate = quoteStartDate + contractTerm
                // Amendment new lines: EndDate = coTermEndDate (most common end date among existing lines)
                Date effectiveEndDate;
                if (isNewBusiness) {
                    effectiveEndDate = endDate;
                } else if (isRenewal && contractTerm != null) {
                    effectiveEndDate = monthEndAligned(startDate, contractTerm);
                } else {
                    effectiveEndDate = coTermEndDate;
                }

                // Order Instant Pricing carries no transaction-level EndDate (no quote term
                // resolved from context). Fall back to the per-line EndDate tag so decimal
                // PTC can be derived from the OrderItem's own start/end dates.
                if (effectiveEndDate == null && String.isNotBlank(li.endDate)) {
                    effectiveEndDate = Date.valueOf(li.endDate);
                }

                attributes.add(new List<Object>{ 'StartDate', 'EffectiveFrom', startDate });
                if (effectiveEndDate != null) {
                    attributes.add(new List<Object>{ 'EndDate', 'EffectiveTo', effectiveEndDate });
                }

                // Prefer decimal PTC from actual start/end dates over integer contractTerm.
                Decimal ptcToSet = null;
                if (effectiveEndDate != null) {
                    Date lineSD = String.isNotBlank(li.startDate) ? Date.valueOf(li.startDate) : startDate;
                    ptcToSet = calcLineItemPTC(lineSD, effectiveEndDate);
                }
                if (ptcToSet == null && contractTerm != null) {
                    ptcToSet = contractTerm;
                }
                if (ptcToSet != null) {
                    attributes.add(new List<Object>{ 'PricingTermCount', 'PricingTermCount', ptcToSet });
                }
            }

            if (isNewLine) {
                appendBundleAttributes(attributes, li.stockKeepingUnit,
                    bundleParentSkus, bundleMemberSkus);
            }

            updates.add(buildNodeUpdate(li.salesPath, attributes));
        }

        return updates;
    }

    // =========================================================
    // BUNDLE DETECTION (Case #473938467)
    // Every transaction-context signal tried came back null at
    // prehook time — ParentSalesTransactionItem / MainItem /
    // ProductRelatedComponent (context tag) / RootItem all resolve to
    // the persisted ParentQuoteLineItem formula field (null pre-save,
    // per SF Support); ParentContextId and AggregatedGroupId__std are
    // computed by a later step inside the Pricing Procedure itself, so
    // a prehook — which runs before the Pricing Procedure — can never
    // see them either way.
    //
    // ProductRelatedComponent the SOBJECT (not a context tag) is
    // catalog-level, not transaction-level — it defines bundle
    // structure at the product level, so it's available regardless of
    // pricing/persistence timing. Confirmed via direct query against
    // "Core Support" — 27 rows, all ChildProduct SKUs matching what
    // this hook sees on the quote, all with DoesBundlePriceIncludeChild
    // = true (child prices are internal allocations of the bundle's
    // flat total, not independently billable) — hence memberSkus
    // covers parent AND children, not just the parent.
    // =========================================================
    @TestVisible
    private class BundleSkuInfo {
        public Set<String> parentSkus = new Set<String>();  // bundle parent lines only
        public Set<String> memberSkus = new Set<String>();  // parent + every child
    }

    @TestVisible
    private static BundleSkuInfo getBundleSkuInfo(List<Object> items) {
        BundleSkuInfo info = new BundleSkuInfo();

        Set<String> skus = new Set<String>();
        Set<String> newSkus = new Set<String>(); // SKUs present on at least one NOT-YET-persisted line
        for (Object obj : items) {
            LineItemNodeWrapper li = new LineItemNodeWrapper(obj);
            if (!li.isValid() || li.deleted) continue;
            if (String.isNotBlank(li.stockKeepingUnit)) {
                skus.add(li.stockKeepingUnit);
                if (!li.isPersisted()) newSkus.add(li.stockKeepingUnit);
            }
        }
        if (skus.isEmpty()) return info;

        try {
            // Deliberately NOT "OR ChildProduct.StockKeepingUnit IN :skus" —
            // that would flag a product as a bundle member just because it's
            // registered as a child of SOME bundle somewhere in the catalog,
            // even when that bundle's parent isn't on this quote at all (e.g.
            // the same component sold standalone). Only ParentProduct IN :skus
            // guarantees every row we act on has its actual parent present on
            // THIS quote.
            for (ProductRelatedComponent prc : [
                SELECT ParentProduct.StockKeepingUnit, ChildProduct.StockKeepingUnit
                FROM   ProductRelatedComponent
                WHERE  ParentProduct.StockKeepingUnit IN :skus
            ]) {
                String parentSku = prc.ParentProduct != null ? prc.ParentProduct.StockKeepingUnit : null;
                String childSku  = prc.ChildProduct  != null ? prc.ChildProduct.StockKeepingUnit  : null;

                if (String.isBlank(parentSku)) continue;

                // Only treat this as an active "bundle is being added" event
                // when the bundle's own parent/root SKU is itself new in this
                // transaction. Otherwise a bundle that's already persisted on
                // the quote (added in an earlier save) would "claim" any
                // unrelated new standalone line that happens to share one of
                // its catalog child SKUs — e.g. adding Core Support first,
                // then later adding a standalone Per User line with the same
                // SKU as one of Core Support's children, wrongly flagging
                // that new standalone line as Is_Part_Of_Bundle__c=true and
                // making it skip minimum-dollar-amount enforcement.
                if (!newSkus.contains(parentSku)) continue;

                info.parentSkus.add(parentSku);
                info.memberSkus.add(parentSku);
                if (String.isNotBlank(childSku)) {
                    info.memberSkus.add(childSku);
                }
            }
        } catch (Exception e) {
            System.debug('==getBundleSkuInfo SOQL error== ' + e.getMessage());
        }

        return info;
    }

    // Appends Is_Bundle_Parent__c / Is_Part_Of_Bundle__c to an
    // in-progress attribute list for one line, if applicable, and
    // marks the SKU as handled in both sets (Apex passes Sets by
    // reference, so this is visible to the caller after return).
    @TestVisible
    private static void appendBundleAttributes(
        List<List<Object>> attributes,
        String sku,
        Set<String> bundleParentSkus,
        Set<String> bundleMemberSkus
    ) {
        if (bundleParentSkus.contains(sku)) {
            attributes.add(new List<Object>{ 'Is_Bundle_Parent__c', 'Is_Bundle_Parent__c', true });
            bundleParentSkus.remove(sku);
        }
        if (bundleMemberSkus.contains(sku)) {
            attributes.add(new List<Object>{ 'Is_Part_Of_Bundle__c', 'Is_Part_Of_Bundle__c', true });
            bundleMemberSkus.remove(sku);
        }
    }

    // Fallback ONLY for bundle SKUs that buildLineUpdates never reached
    // (ramp segment / persisted Amend-Renew line / One-Time selling
    // model) or that never went through it at all (any of the
    // early-exit branches in execute()). In the normal path the flags
    // are merged directly into that line's own node-update entry
    // instead of being sent as a second, separate entry for the same
    // node.
    @TestVisible
    private static List<Map<String, Object>> buildStandaloneBundleFlagUpdates(
        List<Object> items,
        Set<String> remainingBundleParentSkus,
        Set<String> remainingBundleMemberSkus
    ) {
        List<Map<String, Object>> updates = new List<Map<String, Object>>();
        if (remainingBundleParentSkus.isEmpty() && remainingBundleMemberSkus.isEmpty()) {
            return updates;
        }

        for (Object obj : items) {
            LineItemNodeWrapper li = new LineItemNodeWrapper(obj);
            if (!li.isValid() || li.deleted) continue;
            if (li.isPersisted()) continue; // never re-derive bundle flags for already-saved lines

            List<List<Object>> attributes = new List<List<Object>>();
            appendBundleAttributes(attributes, li.stockKeepingUnit,
                remainingBundleParentSkus, remainingBundleMemberSkus);

            if (attributes.isEmpty()) continue;

            System.debug('==Bundle flag (standalone)== SKU=' + li.stockKeepingUnit);
            updates.add(buildNodeUpdate(li.salesPath, attributes));
        }

        return updates;
    }

    // =========================================================
    // SCAN ALL TAGS FOR SELLING MODEL VALUE (fallback)
    // =========================================================
    @TestVisible
    private static String scanSellingModelFromTags(Map<String, Object> tags) {
        if (tags == null) return null;
        for (String key : tags.keySet()) {
            String keyLower = key.toLowerCase();
            if (keyLower.contains('selling') || keyLower.contains('sellingmodel')) {
                try {
                    Object val =
                        ((Map<String, Object>) tags.get(key)).get('tagValue');
                    if (val != null) return String.valueOf(val).trim();
                } catch (Exception e) {}
            }
        }
        return null;
    }

    // =========================================================
    // CHECK ONE TIME SELLING MODEL
    // =========================================================
    @TestVisible
    private static Boolean isOneTimeSelling(String sellingModelType) {
        if (String.isBlank(sellingModelType)) return false;
        String n = sellingModelType
            .toLowerCase().replace(' ', '').replace('_', '').replace('-', '');
        return n == 'onetime';
    }

    // =========================================================
    // BUILD NODE UPDATE
    // =========================================================
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

    // =========================================================
    // PUSH UPDATES
    // =========================================================
    @TestVisible
    private static RevSignaling.TransactionResponse pushUpdates(
        Context.IndustriesContext ctx,
        String contextId,
        List<Map<String, Object>> updates,
        RevSignaling.TransactionResponse response,
        String successMessage
    ) {
        if (updates.isEmpty()) {
            return success(response, 'No lines to update');
        }
        try {
            ctx.updateContextAttributes(new Map<String, Object>{
                'contextId'             => contextId,
                'nodePathAndAttributes' => updates
            });
            response.status  = RevSignaling.TransactionStatus.SUCCESS;
            response.message = successMessage;
        } catch (Exception e) {
            System.debug('==pushUpdates ERROR== ' + e.getMessage());
            System.debug('==pushUpdates STACK== ' + e.getStackTraceString());
            response.status  = RevSignaling.TransactionStatus.SUCCESS;
            response.message = 'Update skipped: ' + e.getMessage();
        }
        return response;
    }

    // =========================================================
    // HELPERS
    // =========================================================

    // Returns the last calendar day of the final month of the term.
    // Start on the 1st: anniversary - 1 day (e.g. Aug 1 + 12 → Jul 31).
    // Start mid-month: last day of the anniversary month (e.g. Aug 15 + 12 → Aug 31).
    @TestVisible
    private static Date monthEndAligned(Date startDate, Integer termMonths) {
        Date anniversary = startDate.addMonths(termMonths);
        if (startDate.day() == 1) {
            return anniversary.addDays(-1);
        }
        return Date.newInstance(anniversary.year(), anniversary.month(), 1)
                   .addMonths(1).addDays(-1);
    }

    @TestVisible
    private static Boolean isTagTrue(Map<String, Object> tagValue, String key) {
        if (!tagValue.containsKey(key)) return false;
        try {
            Object val = ((Map<String, Object>) tagValue.get(key)).get('tagValue');
            return val != null && Boolean.valueOf(String.valueOf(val));
        } catch (Exception e) {}
        return false;
    }

    @TestVisible
    private static String extractTagDate(Map<String, Object> tags, String key) {
        if (tags == null || !tags.containsKey(key)) return null;
        try {
            Object val = ((Map<String, Object>) tags.get(key)).get('tagValue');
            if (val == null) return null;
            if (val instanceof Datetime) {
                return String.valueOf(((Datetime) val).dateGmt());
            }
            return String.valueOf(Date.valueOf(String.valueOf(val)));
        } catch (Exception e) {
            System.debug('==extractTagDate error== ' + e.getMessage());
            return null;
        }
    }

    @TestVisible
    private static RevSignaling.TransactionResponse success(
        RevSignaling.TransactionResponse res, String msg) {
        res.status  = RevSignaling.TransactionStatus.SUCCESS;
        res.message = msg;
        return res;
    }

    @TestVisible
    private static RevSignaling.TransactionResponse fail(
        RevSignaling.TransactionResponse res, String msg) {
        res.status  = RevSignaling.TransactionStatus.FAILED;
        res.message = msg;
        return res;
    }

    // =========================================================
    // DECIMAL PTC FROM DATES
    // Same formula as SetOrderItemPricingTerm.calcPTC — kept here to avoid
    // coupling the pricing pre-hook to the post-Closed-Won processing class.
    // Returns fullMonths + remainingDays / daysInThatMonth, e.g. for
    // 8/15/2026–8/31/2027: 12 + 17/31 = 12.5484 (displayed as 12.55).
    // =========================================================
    @TestVisible
    private static Decimal calcLineItemPTC(Date serviceDate, Date endDate) {
        if (serviceDate == null || endDate == null) return null;
        Integer fullMonths = serviceDate.monthsBetween(endDate);
        Date    baseDate   = serviceDate.addMonths(fullMonths);
        while (fullMonths > 0 && baseDate > endDate) {
            fullMonths--;
            baseDate = serviceDate.addMonths(fullMonths);
        }
        Integer remainDays  = baseDate.daysBetween(endDate.addDays(1));
        Date    monthStart  = Date.newInstance(baseDate.year(), baseDate.month(), 1);
        Integer daysInMonth = monthStart.daysBetween(monthStart.addMonths(1));
        return (fullMonths + (Decimal) remainDays / daysInMonth).setScale(2, System.RoundingMode.HALF_UP);
    }

    // =========================================================
    // DTO
    // =========================================================
    public class TransactionContext {
        public String  quoteStartDate;
        public Integer contractTerm;
        public String  quoteId;
        public String  quoteType;
        public Integer amortizedTermMonths;
    }
}