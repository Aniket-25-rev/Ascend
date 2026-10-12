public class HaasPricingTriggerHandler {

    // =========================================================
    // HAAS HARDWARE / IMPLEMENTATION PRICING (ARM-108) — trigger fallback
    // The post-hook (QuoteMarginRollupPostHook.applyHaasPricing) only fires
    // when Revenue Cloud's pricing context actually includes the line in
    // that save's SalesTransactionItem payload — confirmed live (multiple
    // times, quote 0Q0VF000002gAxt0AE) that several UI edit paths (a bare
    // Reprice click, inline grid quantity edits, a direct field save on the
    // record) commit a plain DML update to QuoteLineItem WITHOUT routing
    // through that context at all, so the post-hook never runs and
    // UnitPrice/NetTotalPrice are left at whatever the native Pricing
    // Procedure computed (often 0 or the raw undivided rate).
    //
    // This handler recalculates the same math directly on the record inside
    // a before insert/update trigger, so it applies on every save regardless
    // of which path the UI used — Trigger.new always carries the current
    // PricingTermCount/Quantity/Discount/HaaS_Hardware_Amount__c field
    // values (unlike the context tag payload, which is only populated for
    // fields actually touched by that specific save).
    //
    // CORRECTED: this used to recalculate price for EVERY HaaS line,
    // including ones carried forward from an existing Asset on Amend/
    // Renew — wrong. Once a line becomes an Asset, its price should come
    // from the Asset (PricingSource = LastTransaction) and never be
    // touched again; we should only ever price a line the FIRST time it's
    // added (New Business, or a brand-new Hardware/Implementation line
    // added mid-Amendment/Renewal). Confirmed live: this is exactly why
    // Implementation's NetUnitPrice went stale on quote 0Q0VF000003dRmb0AE
    // — our trigger kept forcibly recalculating UnitPrice on the carried-
    // forward line every save, fighting the native LastTransaction price
    // instead of leaving it alone. Now uses the same isNewlyAddedLine
    // check (QuoteActionId/QuoteAction.Type) already proven for pairing
    // validation below — Hardware happened to "work" before only because
    // HaaS_Hardware_Amount__c is null on carryover, not because this was
    // actually scoped correctly.
    //
    // Only ever touches these two SKUs — every other line on every other
    // quote is untouched.
    // =========================================================
    private static final String HAAS_HARDWARE_SKU       = '001-INFR-ASC-HAAS-HAAS-001';
    private static final String HAAS_IMPLEMENTATION_SKU = '001-INFR-SVC-HAAS-IMPL-001';
    private static final Decimal HAAS_IMPL_SELL_RATE    = 223.00;
    private static final Decimal HAAS_IMPL_COST_RATE    = 78.88;
    private static final Set<String> HAAS_SKUS = new Set<String>{
        HAAS_HARDWARE_SKU, HAAS_IMPLEMENTATION_SKU
    };

    // Core Support bundle + its Onboarding Fee — same "new line requires its
    // pair" shape as HaaS Hardware/Implementation above, but the pairing
    // rule itself is looser: at least one Onboarding Fee line present on the
    // quote satisfies any number of new Bundle lines (not a strict 1:1
    // count match). See validateBundleOnboardingPairing below.
    private static final String BUNDLE_CORE_SKU       = '001-BNDL-SVC-CORE-SUPP-001';
    private static final String CS_ONBOARDING_FEE_SKU = '001-BNDL-SVC-CORE-ONOB-001';

    // A QuoteLineItem's QuoteActionId (lookup to QuoteAction) tells us
    // whether this line represents an existing Asset being carried forward
    // (Renew/Amend/No Change/Transfer/Cancel) versus a genuinely new
    // addition (QuoteActionId null on New Business, or QuoteAction.Type =
    // 'Add' on an Amendment/Renewal quote where the rep adds a brand-new
    // line). Confirmed live: QuoteAction.Type picklist has exactly these
    // 6 values (Add, Amend, Cancel, Renew, No Change, Transfer) — any value
    // other than 'Add' means this line is a carryover/modification of
    // something that already existed, not a fresh addition.
    private static final Set<String> CARRYOVER_ACTION_TYPES = new Set<String>{
        'Renew', 'Amend', 'No Change', 'Transfer', 'Cancel'
    };

    public static void applyHaasPricing(List<QuoteLineItem> lines) {
        Set<Id> productIds = new Set<Id>();
        for (QuoteLineItem qli : lines) {
            if (qli.Product2Id != null) productIds.add(qli.Product2Id);
        }
        if (productIds.isEmpty()) return;

        Map<Id, String> skuByProductId = new Map<Id, String>();
        for (Product2 p : [
            SELECT Id, StockKeepingUnit
            FROM   Product2
            WHERE  Id IN :productIds
            AND    StockKeepingUnit IN :HAAS_SKUS
        ]) {
            skuByProductId.put(p.Id, p.StockKeepingUnit);
        }
        if (skuByProductId.isEmpty()) return;

        Map<Id, String> actionTypeById = getActionTypesByActionId(lines);
        Map<Id, Decimal> renewalAssetMrrByActionId = getRenewalSourceAssetMrrByActionId(lines);

        for (QuoteLineItem qli : lines) {
            String sku = skuByProductId.get(qli.Product2Id);
            if (sku == null) continue;

            if (!isNewlyAddedLine(qli, actionTypeById)) {
                // Renewal carryover specifically: native Renewal pricing leaves
                // UnitPrice/NetUnitPrice blank for these two SKUs (confirmed live,
                // quote 0Q0VF000003dnqL0AQ — the Amend-side PricingSource fix in
                // Amend_Renew_and_Cancel_Assets_Custom does not carry over the same
                // way for Renew). The Asset's own CurrentMrr is the authoritative
                // real price once populated (see ARM-108 CMRR investigation), so
                // source Sales Price directly from it: QuoteActionId ->
                // QuoteAction.SourceAssetId -> Asset.CurrentMrr.
                Decimal renewalMrr = qli.QuoteActionId != null ? renewalAssetMrrByActionId.get(qli.QuoteActionId) : null;
                if (renewalMrr != null) {
                    qli.UnitPrice = renewalMrr;
                    System.debug('==HaasPricingTrigger Renewal== sku=' + sku
                        + ' sourceAssetCurrentMrr=' + renewalMrr + ' -> UnitPrice set');
                } else {
                    System.debug('==HaasPricingTrigger SKIPPED== sku=' + sku
                        + ' carried forward from existing Asset — price comes from the Asset, not recalculated');
                }
                continue;
            }

            Decimal ptc = qli.PricingTermCount;
            if (ptc == null || ptc <= 0) {
                System.debug('==HaasPricingTrigger SKIPPED== sku=' + sku + ' PricingTermCount unavailable');
                continue;
            }

            Decimal quantity = qli.Quantity == null ? 1 : qli.Quantity;

            if (HAAS_HARDWARE_SKU.equals(sku)) {
                if (qli.HaaS_Hardware_Amount__c == null) {
                    System.debug('==HaasPricingTrigger SKIPPED== Hardware line missing HaaS_Hardware_Amount__c');
                    continue;
                }
                Decimal unitPrice = (qli.HaaS_Hardware_Amount__c / ptc).setScale(2, RoundingMode.HALF_UP);

                qli.UnitPrice = unitPrice;

                System.debug('==HaasPricingTrigger Hardware== amount=' + qli.HaaS_Hardware_Amount__c
                    + ' ptc=' + ptc + ' unitPrice=' + unitPrice);
            } else {
                Decimal unitPrice = (HAAS_IMPL_SELL_RATE / ptc).setScale(4, RoundingMode.HALF_UP);
                Decimal unitCost  = (HAAS_IMPL_COST_RATE / ptc).setScale(4, RoundingMode.HALF_UP);

                qli.UnitPrice = unitPrice;
                qli.UnitCost = unitCost;

                System.debug('==HaasPricingTrigger Implementation== ptc=' + ptc + ' hours=' + quantity
                    + ' unitPrice=' + unitPrice + ' unitCost=' + unitCost);
            }
        }
    }

    // =========================================================
    // HAAS HARDWARE DESCRIPTION REQUIREMENT (ARM-108, AC4)
    // "When the user enters the hardware amount, Then the system shall
    // provide a free-text Description field... And the Description field
    // shall be required before the quote can be submitted."
    //
    // Uses the dedicated HaaS_Hardware_Description__c long text field
    // instead of the standard Description field — the standard field is
    // shared with other uses on the line (e.g. the Onboarding Fee
    // detection in Quote_Approval_Flow keys off Description containing
    // "Onboarding"), so a HaaS-specific field avoids any collision there
    // and keeps this requirement's data on a field that's unambiguously
    // ours.
    //
    // Enforced at save time (every insert/update), not tied to a specific
    // "submission" step — same reasoning as the pairing validation: a
    // save-time block is a strict superset of "blocked at submission," so
    // it satisfies the requirement without needing to hook into whatever
    // approval/status-change mechanism this org uses for "submit."
    //
    // Scoped to the trigger condition itself ("when the user enters the
    // hardware amount") rather than new-vs-carryover: HaaS_Hardware_Amount__c
    // is only ever populated on a newly added line in practice (carried-
    // forward lines always have it null — see applyHaasPricing above), so
    // this naturally never fires for a pure carryover. If a rep manually
    // re-enters the amount on an existing carried-forward line, the
    // requirement still applies, which matches the AC's literal wording.
    // Implementation is explicitly out of scope — AC4 only ever mentions
    // the Hardware SKU.
    // =========================================================
    public static void validateHardwareDescription(List<QuoteLineItem> lines) {
        Map<Id, String> skuByProductId = getHaasSkusByProductId(lines);
        if (skuByProductId.isEmpty()) return;

        for (QuoteLineItem qli : lines) {
            String sku = skuByProductId.get(qli.Product2Id);
            if (!HAAS_HARDWARE_SKU.equals(sku)) continue;
            if (qli.HaaS_Hardware_Amount__c == null) continue;

            if (String.isBlank(qli.HaaS_Hardware_Description__c)) {
                qli.HaaS_Hardware_Description__c.addError('A Description is required for this Hardware as a Service line. '
                    + 'Please enter details about the hardware being provided before saving.');
            }
        }
    }

    // =========================================================
    // HAAS PAIRING VALIDATION (ARM-108)
    // Rachel: "they could have multiple HaaS SKUs (one for each hardware),
    // and each one needs its own implementation SKU" — AND per the written
    // requirement: "Implementation shall not be required when the quote is
    // only renewing or modifying existing HaaS service", but "a brand new/
    // different Hardware SKU added to the customer's existing footprint on
    // an Amendment/Renewal quote shall also require Implementation".
    //
    // CORRECTED (was wrong twice):
    //   v1 assumed a carried-forward Hardware line would show up as an
    //   UPDATE to an already-persisted QuoteLineItem on Amend/Renew, so
    //   scoping to INSERT-only would exempt it. Confirmed live (Contract
    //   800VF00000Zju0JYAR) that's false — Revenue Cloud inserts a
    //   brand-new QuoteLineItem for the carryover, indistinguishable from a
    //   genuine new addition by insert-vs-update alone. Wrongly blocked a
    //   real amendment.
    //   v2 (interim) just skipped the whole check on any Amend/Renew quote
    //   — unblocked the common case but silently dropped the "brand new
    //   Hardware added mid-Amendment still needs Implementation" rule.
    //
    // v3 (this version) uses QuoteActionId instead — confirmed live that a
    // line carried forward from an existing Asset has QuoteActionId
    // populated with QuoteAction.Type = 'Renew' (checked a real Renewal
    // quote, 0Q0VF000003apwk0AA), while a freshly-added New Business line
    // has QuoteActionId = null (checked 0Q0VF000003dFYX0A2). QuoteAction.Type
    // is a 6-value picklist: Add, Amend, Cancel, Renew, No Change, Transfer
    // — everything except 'Add' represents an action on something that
    // already existed. So: QuoteActionId null, or QuoteAction.Type = 'Add',
    // means this line is a genuine new addition and IS subject to pairing;
    // any other QuoteAction.Type means it's carried forward and is EXEMPT.
    // This one rule satisfies both AC3 clauses — New Business and a brand
    // new Hardware line added mid-Amendment both count as "subject to
    // pairing"; a pure carryover renewal never does.
    // =========================================================
    public static void validateHaasPairing(
        List<QuoteLineItem> newLines,
        Map<Id, QuoteLineItem> oldMap,
        Boolean isInsert,
        Boolean isDelete
    ) {
        if (isDelete) {
            validateHaasPairingOnDelete(oldMap);
            return;
        }
        if (!isInsert) {
            return; // plain updates (e.g. field edits on an already-persisted line) never require pairing
        }
        validateHaasPairingOnInsert(newLines);
    }

    // Lines with no QuoteAction, or QuoteAction.Type = 'Add', are genuine
    // new additions — subject to both pricing and pairing. Everything else
    // (Renew, Amend, Cancel, No Change, Transfer) is a carryover/
    // modification of something that already existed, and is exempt from
    // both: its price should come from the Asset (PricingSource =
    // LastTransaction) untouched, and it never counts toward the pairing
    // requirement either.
    private static Boolean isNewlyAddedLine(QuoteLineItem qli, Map<Id, String> actionTypeById) {
        if (qli.QuoteActionId == null) return true;
        String actionType = actionTypeById.get(qli.QuoteActionId);
        return actionType == null || actionType == 'Add';
    }

    private static Map<Id, String> getActionTypesByActionId(List<QuoteLineItem> lines) {
        Set<Id> quoteActionIds = new Set<Id>();
        for (QuoteLineItem qli : lines) {
            if (qli.QuoteActionId != null) quoteActionIds.add(qli.QuoteActionId);
        }

        Map<Id, String> actionTypeById = new Map<Id, String>();
        if (quoteActionIds.isEmpty()) return actionTypeById;

        for (QuoteAction qa : [SELECT Id, Type FROM QuoteAction WHERE Id IN :quoteActionIds]) {
            actionTypeById.put(qa.Id, qa.Type);
        }
        return actionTypeById;
    }

    // For a Renewal carryover line specifically (QuoteAction.Type = 'Renew'),
    // sources the real Sales Price directly from the originating Asset's
    // CurrentMrr, keyed by QuoteActionId so the caller can look it up per line
    // via qli.QuoteActionId. Only Renew is included here — Amend/No Change/
    // Transfer/Cancel carryovers are handled by the separate PricingSource fix
    // in the Amend_Renew_and_Cancel_Assets_Custom flow, not this path.
    private static Map<Id, Decimal> getRenewalSourceAssetMrrByActionId(List<QuoteLineItem> lines) {
        Map<Id, Decimal> mrrByActionId = new Map<Id, Decimal>();

        Set<Id> quoteActionIds = new Set<Id>();
        for (QuoteLineItem qli : lines) {
            if (qli.QuoteActionId != null) quoteActionIds.add(qli.QuoteActionId);
        }
        if (quoteActionIds.isEmpty()) return mrrByActionId;

        Map<Id, Id> sourceAssetIdByActionId = new Map<Id, Id>();
        for (QuoteAction qa : [
            SELECT Id, SourceAssetId
            FROM   QuoteAction
            WHERE  Id IN :quoteActionIds
            AND    Type = 'Renew'
            AND    SourceAssetId != null
        ]) {
            sourceAssetIdByActionId.put(qa.Id, qa.SourceAssetId);
        }
        if (sourceAssetIdByActionId.isEmpty()) return mrrByActionId;

        Map<Id, Decimal> currentMrrByAssetId = new Map<Id, Decimal>();
        for (Asset a : [
            SELECT Id, CurrentMrr
            FROM   Asset
            WHERE  Id IN :sourceAssetIdByActionId.values()
            AND    CurrentMrr != null
        ]) {
            currentMrrByAssetId.put(a.Id, a.CurrentMrr);
        }

        for (Id actionId : sourceAssetIdByActionId.keySet()) {
            Id assetId = sourceAssetIdByActionId.get(actionId);
            if (currentMrrByAssetId.containsKey(assetId)) {
                mrrByActionId.put(actionId, currentMrrByAssetId.get(assetId));
            }
        }
        return mrrByActionId;
    }

    private static void validateHaasPairingOnInsert(List<QuoteLineItem> newLines) {
        Map<Id, String> skuByProductId = getHaasSkusByProductId(newLines);
        if (skuByProductId.isEmpty()) return;

        Map<Id, String> actionTypeById = getActionTypesByActionId(newLines);

        Map<Id, Integer> hardwareCountByQuote = new Map<Id, Integer>();
        Map<Id, Integer> implCountByQuote = new Map<Id, Integer>();
        Map<Id, List<QuoteLineItem>> touchedHaasLinesByQuote = new Map<Id, List<QuoteLineItem>>();

        for (QuoteLineItem qli : newLines) {
            String sku = skuByProductId.get(qli.Product2Id);
            if (sku == null || qli.QuoteId == null) continue;
            if (!isNewlyAddedLine(qli, actionTypeById)) continue; // carried-forward Asset line — exempt

            if (!touchedHaasLinesByQuote.containsKey(qli.QuoteId)) {
                touchedHaasLinesByQuote.put(qli.QuoteId, new List<QuoteLineItem>());
                hardwareCountByQuote.put(qli.QuoteId, 0);
                implCountByQuote.put(qli.QuoteId, 0);
            }
            touchedHaasLinesByQuote.get(qli.QuoteId).add(qli);

            if (HAAS_HARDWARE_SKU.equals(sku)) {
                hardwareCountByQuote.put(qli.QuoteId, hardwareCountByQuote.get(qli.QuoteId) + 1);
            } else {
                implCountByQuote.put(qli.QuoteId, implCountByQuote.get(qli.QuoteId) + 1);
            }
        }

        for (Id quoteId : touchedHaasLinesByQuote.keySet()) {
            Integer hwCount   = hardwareCountByQuote.get(quoteId);
            Integer implCount = implCountByQuote.get(quoteId);
            if (hwCount == implCount) continue;

            String message = 'New HaaS Hardware lines (' + hwCount + ') and new Implementation lines (' + implCount
                + ') being added in this save must match. Each new HaaS Hardware line needs its own new '
                + 'Implementation line, and vice versa. Add or remove a line to balance them before saving.';

            for (QuoteLineItem qli : touchedHaasLinesByQuote.get(quoteId)) {
                qli.addError(message);
            }
        }
    }

    private static void validateHaasPairingOnDelete(Map<Id, QuoteLineItem> oldMap) {
        List<QuoteLineItem> deletedLines = oldMap.values();
        Map<Id, String> skuByProductId = getHaasSkusByProductId(deletedLines);
        if (skuByProductId.isEmpty()) return;

        Map<Id, String> deletedActionTypeById = getActionTypesByActionId(deletedLines);

        Map<Id, List<QuoteLineItem>> touchedHaasLinesByQuote = new Map<Id, List<QuoteLineItem>>();
        for (QuoteLineItem qli : deletedLines) {
            if (!skuByProductId.containsKey(qli.Product2Id) || qli.QuoteId == null) continue;
            if (!isNewlyAddedLine(qli, deletedActionTypeById)) continue; // deleting a carryover line was never pairing-protected
            if (!touchedHaasLinesByQuote.containsKey(qli.QuoteId)) {
                touchedHaasLinesByQuote.put(qli.QuoteId, new List<QuoteLineItem>());
            }
            touchedHaasLinesByQuote.get(qli.QuoteId).add(qli);
        }
        if (touchedHaasLinesByQuote.isEmpty()) return;

        Set<Id> excludedIds = new Set<Id>();
        for (QuoteLineItem qli : deletedLines) excludedIds.add(qli.Id);

        Map<Id, Integer> hardwareCountByQuote = new Map<Id, Integer>();
        Map<Id, Integer> implCountByQuote = new Map<Id, Integer>();
        for (Id quoteId : touchedHaasLinesByQuote.keySet()) {
            hardwareCountByQuote.put(quoteId, 0);
            implCountByQuote.put(quoteId, 0);
        }

        List<QuoteLineItem> remainingLines = [
            SELECT Id, QuoteId, QuoteActionId, Product2.StockKeepingUnit
            FROM   QuoteLineItem
            WHERE  QuoteId IN :touchedHaasLinesByQuote.keySet()
            AND    Product2.StockKeepingUnit IN :HAAS_SKUS
        ];
        Map<Id, String> remainingActionTypeById = getActionTypesByActionId(remainingLines);

        for (QuoteLineItem qli : remainingLines) {
            if (excludedIds.contains(qli.Id)) continue;
            if (!isNewlyAddedLine(qli, remainingActionTypeById)) continue; // carryover lines don't count toward the pairing balance
            if (HAAS_HARDWARE_SKU.equals(qli.Product2.StockKeepingUnit)) {
                hardwareCountByQuote.put(qli.QuoteId, hardwareCountByQuote.get(qli.QuoteId) + 1);
            } else {
                implCountByQuote.put(qli.QuoteId, implCountByQuote.get(qli.QuoteId) + 1);
            }
        }

        for (Id quoteId : touchedHaasLinesByQuote.keySet()) {
            Integer hwCount   = hardwareCountByQuote.get(quoteId);
            Integer implCount = implCountByQuote.get(quoteId);
            if (hwCount == implCount) continue;

            String message = 'Deleting this line would leave HaaS Hardware lines (' + hwCount
                + ') and Implementation lines (' + implCount + ') unbalanced on this quote. Each HaaS '
                + 'Hardware line needs its own Implementation line, and vice versa. Delete both together, '
                + 'or add a replacement line to balance them.';

            for (QuoteLineItem qli : touchedHaasLinesByQuote.get(quoteId)) {
                qli.addError(message);
            }
        }
    }

    private static Map<Id, String> getHaasSkusByProductId(List<QuoteLineItem> lines) {
        Set<Id> productIds = new Set<Id>();
        for (QuoteLineItem qli : lines) {
            if (qli.Product2Id != null) productIds.add(qli.Product2Id);
        }

        Map<Id, String> skuByProductId = new Map<Id, String>();
        if (productIds.isEmpty()) return skuByProductId;

        for (Product2 p : [
            SELECT Id, StockKeepingUnit
            FROM   Product2
            WHERE  Id IN :productIds
            AND    StockKeepingUnit IN :HAAS_SKUS
        ]) {
            skuByProductId.put(p.Id, p.StockKeepingUnit);
        }
        return skuByProductId;
    }

    // =========================================================
    // BUNDLE + ONBOARDING FEE PAIRING VALIDATION
    // When a newly-added Core Support bundle line is added to a quote, the
    // quote must also carry at least one Core Support Onboarding Fee line —
    // new (added in this same save) or already persisted on the quote from
    // before. Unlike HaaS Hardware/Implementation, this is NOT a strict 1:1
    // count match — one Onboarding Fee line satisfies any number of new
    // Bundle lines.
    //
    // Same carryover exemption as HaaS pairing: a Bundle line carried
    // forward from an existing Asset on Amend/Renew (isNewlyAddedLine =
    // false) already satisfied this requirement the first time it was
    // added, so it's exempt here too. Scoped to insert only — plain updates
    // on an already-persisted line never re-trigger this check.
    //
    // Ramp deals: only the first ramp segment (Year 1) needs the Onboarding
    // Fee. Bundle lines in a later ramped segment (Year 2, Year 3 ...) are
    // exempt — otherwise the rule forced an Onboarding Fee into every segment.
    // The segment is the line's QuoteLineGroup (one per ramp year, shared by
    // every product in that year); the first segment is the quote's ramped
    // group with the lowest SortOrder (earliest StartDate on a tie).
    // =========================================================
    public static void validateBundleOnboardingPairing(List<QuoteLineItem> newLines, Boolean isInsert) {
        if (!isInsert) return;

        Map<Id, String> skuByProductId = getSkusByProductId(newLines,
            new Set<String>{ BUNDLE_CORE_SKU, CS_ONBOARDING_FEE_SKU });
        if (skuByProductId.isEmpty()) return;

        Map<Id, String> actionTypeById = getActionTypesByActionId(newLines);
        Set<Id> laterRampSegmentIds = getLaterRampSegmentIds(newLines, skuByProductId);

        Map<Id, List<QuoteLineItem>> newBundleLinesByQuote = new Map<Id, List<QuoteLineItem>>();
        Set<Id> quoteIdsWithOnboardingInThisSave = new Set<Id>();

        for (QuoteLineItem qli : newLines) {
            String sku = skuByProductId.get(qli.Product2Id);
            if (sku == null || qli.QuoteId == null) continue;

            if (CS_ONBOARDING_FEE_SKU.equals(sku)) {
                quoteIdsWithOnboardingInThisSave.add(qli.QuoteId);
                continue;
            }

            if (!isNewlyAddedLine(qli, actionTypeById)) continue; // carried-forward bundle already satisfied this once
            if (qli.QuoteLineGroupId != null && laterRampSegmentIds.contains(qli.QuoteLineGroupId)) continue; // Year 2+ of a ramp - only Year 1 needs the fee

            if (!newBundleLinesByQuote.containsKey(qli.QuoteId)) {
                newBundleLinesByQuote.put(qli.QuoteId, new List<QuoteLineItem>());
            }
            newBundleLinesByQuote.get(qli.QuoteId).add(qli);
        }
        if (newBundleLinesByQuote.isEmpty()) return;

        Set<Id> quoteIdsNeedingCheck = new Set<Id>();
        for (Id quoteId : newBundleLinesByQuote.keySet()) {
            if (!quoteIdsWithOnboardingInThisSave.contains(quoteId)) {
                quoteIdsNeedingCheck.add(quoteId);
            }
        }

        Set<Id> quoteIdsWithExistingOnboarding = new Set<Id>();
        if (!quoteIdsNeedingCheck.isEmpty()) {
            for (QuoteLineItem qli : [
                SELECT QuoteId
                FROM   QuoteLineItem
                WHERE  QuoteId IN :quoteIdsNeedingCheck
                AND    Product2.StockKeepingUnit = :CS_ONBOARDING_FEE_SKU
            ]) {
                quoteIdsWithExistingOnboarding.add(qli.QuoteId);
            }
        }

        for (Id quoteId : newBundleLinesByQuote.keySet()) {
            Boolean hasOnboarding = quoteIdsWithOnboardingInThisSave.contains(quoteId)
                || quoteIdsWithExistingOnboarding.contains(quoteId);
            if (hasOnboarding) continue;

            String message = 'This quote adds a new Core Support bundle line, which requires a Core Support '
                + 'Onboarding Fee line to also be present on the quote. Add the Onboarding Fee line before saving.';

            for (QuoteLineItem qli : newBundleLinesByQuote.get(quoteId)) {
                qli.addError(message);
            }
        }
    }

    // Ramped QuoteLineGroups that are NOT their quote's first ramp segment,
    // for the quotes of the Bundle lines in this save. Groups that are not
    // ramped never appear here, so non-ramp quotes keep the full check.
    private static Set<Id> getLaterRampSegmentIds(List<QuoteLineItem> lines, Map<Id, String> skuByProductId) {
        Set<Id> quoteIds = new Set<Id>();
        for (QuoteLineItem qli : lines) {
            if (qli.QuoteLineGroupId != null && qli.QuoteId != null
                && BUNDLE_CORE_SKU.equals(skuByProductId.get(qli.Product2Id))) {
                quoteIds.add(qli.QuoteId);
            }
        }
        Set<Id> laterSegmentIds = new Set<Id>();
        if (quoteIds.isEmpty()) return laterSegmentIds;

        Set<Id> quotesWithFirstSegment = new Set<Id>();
        for (QuoteLineGroup grp : [
            SELECT Id, QuoteId
            FROM   QuoteLineGroup
            WHERE  QuoteId IN :quoteIds
            AND    IsRamped = true
            ORDER BY QuoteId, SortOrder ASC NULLS LAST, StartDate ASC NULLS LAST
        ]) {
            if (quotesWithFirstSegment.add(grp.QuoteId)) continue; // first ramped group of this quote = Year 1
            laterSegmentIds.add(grp.Id);
        }
        return laterSegmentIds;
    }

    private static Map<Id, String> getSkusByProductId(List<QuoteLineItem> lines, Set<String> skus) {
        Set<Id> productIds = new Set<Id>();
        for (QuoteLineItem qli : lines) {
            if (qli.Product2Id != null) productIds.add(qli.Product2Id);
        }

        Map<Id, String> skuByProductId = new Map<Id, String>();
        if (productIds.isEmpty()) return skuByProductId;

        for (Product2 p : [
            SELECT Id, StockKeepingUnit
            FROM   Product2
            WHERE  Id IN :productIds
            AND    StockKeepingUnit IN :skus
        ]) {
            skuByProductId.put(p.Id, p.StockKeepingUnit);
        }
        return skuByProductId;
    }
}