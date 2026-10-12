public without sharing class FinancialMetricsService {

    public static final Map<String, String> LOB_TO_SUFFIX = new Map<String, String>{
        'Cybersecurity'  => 'Cyber',
        'Service Desk'   => 'Desk',
        'Infrastructure' => 'Infra',
        'Private Cloud'  => 'Private_Cloud',
        'VOIP'           => 'VOIP'
    };

    // A line's own Line_of_Business__c wins; when it is blank, fall back to the
    // product's Line of Business (Product2.Service_Offering__c). RCA leaves the
    // line field blank on lines it builds from assets (amend/cancel/renew) and on
    // older sales, which dropped their MRR out of every LOB bucket.
    public static String lobOf(String lineLob, String productLob) {
        return String.isBlank(lineLob) ? productLob : lineLob;
    }

    public static String lobOf(QuoteLineItem line) {
        if (line == null) {
            return null;
        }
        return lobOf(line.Line_of_Business__c, line.Product2 == null ? null : line.Product2.Service_Offering__c);
    }

    public static final Set<String> CHANGE_ACTION_TYPES = new Set<String>{
        'Amend', 'Cancel', 'Renew'
    };

    public static final Set<String> RESTATING_ACTION_TYPES = new Set<String>{
        'Renew'
    };

    public static final Map<String, String> QUOTE_TO_CONTRACT_MARGIN = new Map<String, String>{
        'Margin_Total__c'         => 'Sold_Gross_Margin_Total__c',
        'Margin_Cyber__c'         => 'Sold_Gross_Margin_Cyber__c',
        'Margin_Desk__c'          => 'Sold_Gross_Margin_Desk__c',
        'Margin_Infra__c'         => 'Sold_Gross_Margin_Infra__c',
        'Margin_Onboarding__c'    => 'Sold_Gross_Margin_Onboarding__c',
        'Margin_Private_Cloud__c' => 'Sold_Gross_Margin_Private_Cloud__c',
        'Margin_VOIP__c'          => 'Sold_Gross_Margin_VOIP__c'
    };

    public static final Set<String> WALKAWAY_STAGES = new Set<String>{
        'Closed Lost', 'Closed Churn'
    };

    private static final String ONE_TIME = 'OneTime';
    private static final String RENEW = 'Renew';
    private static final String NEW_BUSINESS = 'New';
    private static final String ACTIVATED = 'Activated';
    private static final String FAULT_SUBJECT = 'Financial Metrics Fault';
    private static final String LOSS_TYPE_PARTIAL = 'Renewal - Partial';
    private static final String LOSS_TYPE_FULL = 'Renewal - Full';

    @TestVisible
    private static Set<Id> recalcGuard = new Set<Id>();

    @TestVisible
    private static Set<Id> stampGuard = new Set<Id>();

    @TestVisible
    private static Map<Id, List<QuoteLineItem>> lineOverride;

    @TestVisible
    private static List<String> faultLog = new List<String>();

    @TestVisible
    private static Map<Id, String> actionTypeOverride;

    @TestVisible
    private static Map<Id, Map<Id, Decimal>> assetBaselineOverride;

    @TestVisible
    private static Map<Id, Map<Id, String>> assetBaselineLobOverride;

    // Contract -> Product2Id -> per-unit MRR from the asset book. Used to
    // price Amend/Cancel lines that RCA hands us without a NetUnitPrice.
    @TestVisible
    private static Map<Id, Map<Id, Decimal>> assetUnitMrrOverride;

    private static Map<Id, Map<Id, String>> assetBaselineLobs =
        new Map<Id, Map<Id, String>>();

    private static Map<Id, Map<Id, Decimal>> assetUnitMrrs =
        new Map<Id, Map<Id, Decimal>>();

    private static String actionTypeOf(Id quoteId, String actual) {
        if (actionTypeOverride != null && actionTypeOverride.containsKey(quoteId)) {
            return actionTypeOverride.get(quoteId);
        }
        return actual;
    }

    @TestVisible
    private static Boolean isNewBusiness(String actionType) {
        return String.isBlank(actionType) || actionType == NEW_BUSINESS;
    }

    public static void stampPreviousMetrics(Set<Id> quoteIds) {
        try {
            runStampPreviousMetrics(quoteIds);
        } catch (Exception e) {
            logUnexpected(quoteIds, e);
        }
    }

    public static void recalcNetMetrics(Set<Id> quoteIds, Set<Id> excludedLineIds) {
        try {
            runRecalcNetMetrics(quoteIds, excludedLineIds);
        } catch (Exception e) {
            logUnexpected(quoteIds, e);
        }
    }

    public static void stampOpportunityMetrics(Set<Id> quoteIds) {
        try {
            runStampOpportunityMetrics(quoteIds);
        } catch (Exception e) {
            logUnexpected(quoteIds, e);
        }
    }

    public static void stampRenewalWalkAway(Set<Id> opportunityIds) {
        try {
            runStampRenewalWalkAway(opportunityIds);
        } catch (Exception e) {
            logUnexpected(opportunityIds, e);
        }
    }

    public static void stampContractFromOrder(Set<Id> orderIds) {
        try {
            runStampContractFromOrder(orderIds);
        } catch (Exception e) {
            logUnexpected(orderIds, e);
        }
    }

    private static void runStampPreviousMetrics(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return;
        }

        List<Quote> quotes = [
            SELECT Id, OwnerId, ContractId, OriginalActionType
            FROM Quote
            WHERE Id IN :quoteIds
            AND ContractId != null
        ];

        Set<Id> contractIds = new Set<Id>();
        List<Quote> eligible = new List<Quote>();
        for (Quote q : quotes) {
            if (!CHANGE_ACTION_TYPES.contains(actionTypeOf(q.Id, q.OriginalActionType))) {
                continue;
            }
            eligible.add(q);
            contractIds.add(q.ContractId);
        }
        if (eligible.isEmpty()) {
            return;
        }

        Map<Id, Contract> baselines = loadContractBaselines(contractIds);

        List<Quote> updates = new List<Quote>();
        Map<Id, Id> owners = new Map<Id, Id>();
        for (Quote q : eligible) {
            Contract baseline = baselines.get(q.ContractId);
            if (baseline == null) {
                continue;
            }
            Quote target = new Quote(
                Id = q.Id,
                Existing_TCV__c = zero(baseline.Current_TCV__c),
                Existing_MRR__c = zero(baseline.Current_MRR__c)
            );
            for (String suffix : LOB_TO_SUFFIX.values()) {
                target.put(
                    'Existing_MRR_' + suffix + '__c',
                    zero((Decimal) baseline.get('Current_MRR_' + suffix + '__c'))
                );
            }
            updates.add(target);
            owners.put(q.Id, q.OwnerId);
        }
        commitRecords(updates, owners);
    }

    private static void runRecalcNetMetrics(Set<Id> quoteIds, Set<Id> excludedLineIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return;
        }

        Set<Id> targets = new Set<Id>();
        for (Id quoteId : quoteIds) {
            if (quoteId != null && !recalcGuard.contains(quoteId)) {
                targets.add(quoteId);
            }
        }
        if (targets.isEmpty()) {
            return;
        }
        recalcGuard.addAll(targets);

        Map<Id, Quote> quotes = new Map<Id, Quote>([
            SELECT Id, OwnerId, ContractId, OriginalActionType, Existing_TCV__c, Existing_MRR__c,
                   Existing_MRR_Cyber__c, Existing_MRR_Desk__c, Existing_MRR_Infra__c,
                   Existing_MRR_Private_Cloud__c, Existing_MRR_VOIP__c
            FROM Quote
            WHERE Id IN :targets
        ]);
        if (quotes.isEmpty()) {
            return;
        }

        Map<Id, List<QuoteLineItem>> linesByQuoteId = loadLines(quotes.keySet(), excludedLineIds);

        // Renewals need the asset baseline to diff against; Amend/Cancel need
        // it for the per-unit MRR fallback when RCA leaves NetUnitPrice blank
        // (assets already at PricingSource = LastTransaction are not repriced,
        // and the MRR__c formula then reads 0).
        Set<Id> baselineContractIds = new Set<Id>();
        for (Quote q : quotes.values()) {
            if (q.ContractId != null
                && CHANGE_ACTION_TYPES.contains(actionTypeOf(q.Id, q.OriginalActionType))) {
                baselineContractIds.add(q.ContractId);
            }
        }
        Map<Id, Map<Id, Decimal>> baselines = baselineContractIds.isEmpty()
            ? new Map<Id, Map<Id, Decimal>>()
            : loadAssetBaselines(baselineContractIds);

        List<Quote> updates = new List<Quote>();
        for (Quote q : quotes.values()) {
            updates.add(buildCurrentSet(
                q.Id,
                RESTATING_ACTION_TYPES.contains(actionTypeOf(q.Id, q.OriginalActionType)),
                linesByQuoteId.get(q.Id),
                q.ContractId,
                baselines
            ));
        }
        commitRecords(updates, ownerBySourceId(quotes.values()));
    }

    @TestVisible
    private static Quote buildCurrentSet(
        Id quoteId, Boolean restating, List<QuoteLineItem> lines,
        Id contractId, Map<Id, Map<Id, Decimal>> baselines
    ) {
        Map<Id, Decimal> unitMrr = restating ? null : unitMrrFor(contractId);
        Map<String, Decimal> byLob = restating
            ? sumRenewedMrrByLob(lines)
            : sumMrrByLob(lines, unitMrr);
        Quote target = new Quote(Id = quoteId);
        for (String suffix : LOB_TO_SUFFIX.values()) {
            target.put('Current_MRR_' + suffix + '__c', zero(byLob.get(suffix)));
        }
        target.Current_MRR__c = restating ? sumRenewedMrr(lines) : sumBookedMrr(lines, unitMrr);
        target.Current_TCV__c = restating ? sumRenewedTcv(lines) : sumTcv(lines);

        Map<Id, Decimal> baseline = baselines == null || contractId == null
            ? null
            : baselines.get(contractId);
        Map<String, Decimal> lossByLob = restating
            ? renewalGrossLossByLob(baseline, assetBaselineLobs.get(contractId), lines)
            : sumNegativeMrrByLob(lines, unitMrr);
        for (String suffix : LOB_TO_SUFFIX.values()) {
            Decimal amount = zero(lossByLob.get(suffix));
            target.put(
                'Loss_MRR_' + suffix + '__c',
                amount < 0 ? amount.setScale(2, RoundingMode.HALF_UP) : null
            );
        }
        return target;
    }

    @TestVisible
    private static Boolean currentSetChanged(Quote stored, Quote refreshed) {
        if (zero(stored.Current_MRR__c) != zero(refreshed.Current_MRR__c)) {
            return true;
        }
        if (zero(stored.Current_TCV__c) != zero(refreshed.Current_TCV__c)) {
            return true;
        }
        for (String suffix : LOB_TO_SUFFIX.values()) {
            String field = 'Current_MRR_' + suffix + '__c';
            if (zero((Decimal) stored.get(field)) != zero((Decimal) refreshed.get(field))) {
                return true;
            }
            String lossField = 'Loss_MRR_' + suffix + '__c';
            if (zero((Decimal) stored.get(lossField)) != zero((Decimal) refreshed.get(lossField))) {
                return true;
            }
        }
        return false;
    }

    private static void runStampOpportunityMetrics(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return;
        }

        Set<Id> targets = new Set<Id>();
        for (Id quoteId : quoteIds) {
            if (quoteId != null && !stampGuard.contains(quoteId)) {
                targets.add(quoteId);
            }
        }
        if (targets.isEmpty()) {
            return;
        }
        stampGuard.addAll(targets);

        Map<Id, Quote> quotes = new Map<Id, Quote>([
            SELECT Id, OwnerId, OpportunityId, ContractId, OriginalActionType,
                   Existing_MRR__c, Current_MRR__c, Current_TCV__c,
                   Current_MRR_Cyber__c, Current_MRR_Desk__c, Current_MRR_Infra__c,
                   Current_MRR_Private_Cloud__c, Current_MRR_VOIP__c,
                   Loss_MRR_Cyber__c, Loss_MRR_Desk__c, Loss_MRR_Infra__c,
                   Loss_MRR_Private_Cloud__c, Loss_MRR_VOIP__c,
                   NRR__c, GRR__c
            FROM Quote
            WHERE Id IN :targets
            AND OpportunityId != null
        ]);
        if (quotes.isEmpty()) {
            return;
        }

        Map<Id, List<QuoteLineItem>> linesByQuoteId = loadLines(quotes.keySet(), null);

        Set<Id> opportunityIds = new Set<Id>();
        Set<Id> contractIds = new Set<Id>();
        for (Quote q : quotes.values()) {
            opportunityIds.add(q.OpportunityId);
            if (q.ContractId != null) {
                contractIds.add(q.ContractId);
            }
        }
        Map<Id, Opportunity> priorByOpportunityId = new Map<Id, Opportunity>([
            SELECT Id, StageName, Booked_MRR__c, Loss_MRR__c
            FROM Opportunity
            WHERE Id IN :opportunityIds
        ]);
        Map<Id, Map<Id, Decimal>> assetBaselines = loadAssetBaselines(contractIds);

        Map<Id, Opportunity> updates = new Map<Id, Opportunity>();
        Map<Id, Id> owners = new Map<Id, Id>();
        List<Quote> quoteUpdates = new List<Quote>();
        Map<Id, Id> quoteOwners = new Map<Id, Id>();
        for (Quote q : quotes.values()) {
            String actionType = actionTypeOf(q.Id, q.OriginalActionType);
            Boolean restating = RESTATING_ACTION_TYPES.contains(actionType);
            List<QuoteLineItem> lines = linesByQuoteId.get(q.Id);

            Quote refreshed = buildCurrentSet(
                q.Id, restating, lines, q.ContractId, assetBaselines
            );

            Decimal loss = restating
                ? renewalGrossLoss(assetBaselines.get(q.ContractId), lines)
                : sumNegativeMrr(lines, unitMrrFor(q.ContractId));
            Decimal lossValue = loss < 0 ? loss : null;

            // "booked" is the resulting total after this transaction, already
            // normalized across action types by netOf() (Renew: Current_MRR__c
            // IS the full re-booked total; Amend/Cancel: Current_MRR__c is only
            // the delta, so Existing_MRR__c has to be added back in). NRR/GRR
            // must use this normalized total, not raw Current_MRR__c, or NRR
            // would be wrong for every Amendment (Current_MRR__c alone is just
            // the delta there, not Starting + Expansion - Churn).
            Decimal booked = netOf(
                q.Id, q.OriginalActionType, refreshed.Current_MRR__c, q.Existing_MRR__c
            );

            // NRR/GRR live on the Quote. NRR = the resulting total (booked) as a
            // % of the Existing MRR baseline. GRR excludes expansion, using the
            // same Loss/Churn figure computed above for Opportunity.Loss_MRR__c.
            // Both are blank when there's no Existing MRR baseline (e.g. New
            // Business), since retention isn't a meaningful concept without a
            // starting point.
            refreshed.NRR__c = calcRetentionPercent(booked, q.Existing_MRR__c);
            refreshed.GRR__c = calcRetentionPercent(
                zero(q.Existing_MRR__c) + zero(lossValue), q.Existing_MRR__c
            );
            // currentSetChanged() only looks at Current_MRR__c/TCV/LOB, so it
            // alone would skip writing NRR/GRR the first time they're computed
            // (e.g. right after recalcNetMetrics already wrote an identical
            // Current_MRR__c moments earlier in the same transaction). Checked
            // separately here rather than extending currentSetChanged itself.
            Boolean retentionChanged = zero(q.NRR__c) != zero(refreshed.NRR__c)
                || zero(q.GRR__c) != zero(refreshed.GRR__c);

            if (currentSetChanged(q, refreshed) || retentionChanged) {
                quoteUpdates.add(refreshed);
                quoteOwners.put(q.Id, q.OwnerId);
            }

            Opportunity prior = priorByOpportunityId.get(q.OpportunityId);
            if (prior != null && WALKAWAY_STAGES.contains(prior.StageName)) {
                continue;
            }

            if (prior != null
                && zero(prior.Booked_MRR__c) == zero(booked)
                && zero(prior.Loss_MRR__c) == zero(lossValue)) {
                continue;
            }

            // Per AC-9, Loss_Type__c is Renewal - Partial only when this is a Renewal
            // quote (restating) AND there's an actual loss - the Opportunity still
            // closes Won, just at a lower MRR. Amend/Cancel-driven losses aren't
            // renewal losses, so they leave Loss_Type__c blank; a Renewal with no
            // loss (lossValue null) also clears it, keeping it in lockstep with
            // Loss_MRR__c rather than a separate process that could disagree with it.
            updates.put(q.OpportunityId, new Opportunity(
                Id = q.OpportunityId,
                Booked_MRR__c = booked,
                Loss_MRR__c = lossValue,
                Loss_Type__c = (restating && lossValue != null) ? LOSS_TYPE_PARTIAL : null
            ));
            owners.put(q.OpportunityId, q.OwnerId);
        }
        commitRecords(updates.values(), owners);
        commitRecords(quoteUpdates, quoteOwners);
    }

    private static void runStampRenewalWalkAway(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return;
        }

        List<Opportunity> opportunities = [
            SELECT Id, OwnerId, ContractId
            FROM Opportunity
            WHERE Id IN :opportunityIds
            AND ContractId != null
        ];
        if (opportunities.isEmpty()) {
            return;
        }

        Map<Id, Id> owners = new Map<Id, Id>();
        Set<Id> contractIds = new Set<Id>();
        for (Opportunity opp : opportunities) {
            owners.put(opp.Id, opp.OwnerId);
            contractIds.add(opp.ContractId);
        }

        Map<Id, Contract> baselines = loadContractBaselines(contractIds);

        List<Opportunity> updates = new List<Opportunity>();
        Set<Id> missing = new Set<Id>();
        for (Opportunity opp : opportunities) {
            Contract baseline = baselines.get(opp.ContractId);
            Decimal mrr = baseline == null ? 0 : zero(baseline.Current_MRR__c);
            if (mrr <= 0) {
                missing.add(opp.Id);
                continue;
            }
            updates.add(new Opportunity(Id = opp.Id, Loss_MRR__c = -mrr, Booked_MRR__c = 0, Loss_Type__c = LOSS_TYPE_FULL));
        }
        if (!missing.isEmpty()) {
            logFaults(missing, owners,
                'No MRR baseline on the contract - Loss MRR not stamped');
        }
        commitRecords(updates, owners);
    }

    private static void runStampContractFromOrder(Set<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) {
            return;
        }

        List<Order> orders = [
            SELECT Id, OwnerId, ContractId, QuoteId, ActivatedDate, Quote.OriginalActionType
            FROM Order
            WHERE Id IN :orderIds
            AND Status = :ACTIVATED
            AND ContractId != null
            AND QuoteId != null
        ];
        if (orders.isEmpty()) {
            return;
        }

        Set<Id> contractIds = new Set<Id>();
        Map<Id, Id> owners = new Map<Id, Id>();
        for (Order o : orders) {
            contractIds.add(o.ContractId);
            owners.put(o.ContractId, o.OwnerId);
        }

        Map<Id, Contract> priorByContractId = new Map<Id, Contract>([
            SELECT Id, Last_Stamped_Order__c, Last_Stamped_Order__r.ActivatedDate,
                   Current_TCV__c, Current_MRR__c,
                   Current_MRR_Cyber__c, Current_MRR_Desk__c, Current_MRR_Infra__c,
                   Current_MRR_Private_Cloud__c, Current_MRR_VOIP__c
            FROM Contract
            WHERE Id IN :contractIds
        ]);

        List<Order> eligible = new List<Order>();
        for (Order o : orders) {
            Contract prior = priorByContractId.get(o.ContractId);
            if (prior != null && supersededByLaterStamp(prior, o)) {
                continue;
            }
            eligible.add(o);
        }
        if (eligible.isEmpty()) {
            return;
        }

        Set<Id> quoteIds = new Set<Id>();
        for (Order o : eligible) {
            quoteIds.add(o.QuoteId);
        }

        Map<Id, Quote> currentByQuoteId = new Map<Id, Quote>([
            SELECT Id, Existing_TCV__c, Existing_MRR__c, Existing_MRR_Cyber__c,
                   Existing_MRR_Desk__c, Existing_MRR_Infra__c, Existing_MRR_Private_Cloud__c,
                   Existing_MRR_VOIP__c, Current_TCV__c, Current_MRR__c,
                   Current_MRR_Cyber__c, Current_MRR_Desk__c, Current_MRR_Infra__c,
                   Current_MRR_Private_Cloud__c, Current_MRR_VOIP__c,
                   Margin_Total__c, Margin_Cyber__c, Margin_Desk__c, Margin_Infra__c,
                   Margin_Onboarding__c, Margin_Private_Cloud__c, Margin_VOIP__c
            FROM Quote
            WHERE Id IN :quoteIds
        ]);

        List<Quote> quoteUpdates = new List<Quote>();
        Map<Id, Id> quoteOwners = new Map<Id, Id>();
        for (Order o : eligible) {
            if (!CHANGE_ACTION_TYPES.contains(actionTypeOf(o.QuoteId, o.Quote.OriginalActionType))) {
                continue;
            }
            Quote existing = currentByQuoteId.get(o.QuoteId);
            if (existing == null) {
                continue;
            }
            Contract prior = priorByContractId.get(o.ContractId);

            Decimal tcv = prior == null ? 0 : zero(prior.Current_TCV__c);
            Decimal mrr = prior == null ? 0 : zero(prior.Current_MRR__c);
            Boolean changed = zero(existing.Existing_TCV__c) != tcv
                || zero(existing.Existing_MRR__c) != mrr;

            Quote refreshed = new Quote(
                Id = o.QuoteId,
                Existing_TCV__c = tcv,
                Existing_MRR__c = mrr
            );
            for (String suffix : LOB_TO_SUFFIX.values()) {
                Decimal lob = prior == null
                    ? 0
                    : zero((Decimal) prior.get('Current_MRR_' + suffix + '__c'));
                if (zero((Decimal) existing.get('Existing_MRR_' + suffix + '__c')) != lob) {
                    changed = true;
                }
                refreshed.put('Existing_MRR_' + suffix + '__c', lob);
            }
            if (!changed) {
                continue;
            }
            quoteUpdates.add(refreshed);
            quoteOwners.put(o.QuoteId, o.OwnerId);
        }
        commitRecords(quoteUpdates, quoteOwners);

        Map<Id, Contract> updates = new Map<Id, Contract>();
        for (Order o : eligible) {
            String actionType = o.Quote.OriginalActionType;
            if (!isNewBusiness(actionTypeOf(o.QuoteId, actionType))) {
                continue;
            }
            Contract prior = priorByContractId.get(o.ContractId);
            Quote current = currentByQuoteId.get(o.QuoteId);
            if (current == null) {
                continue;
            }
            Decimal priorMrr = prior == null ? 0 : zero(prior.Current_MRR__c);
            Decimal priorTcv = prior == null ? 0 : zero(prior.Current_TCV__c);

            Contract target = new Contract(
                Id = o.ContractId,
                Existing_MRR__c = prior == null ? null : prior.Current_MRR__c,
                Existing_TCV__c = prior == null ? null : prior.Current_TCV__c,
                Current_MRR__c = netOf(o.QuoteId, actionType, current.Current_MRR__c, priorMrr),
                Current_TCV__c = netOf(o.QuoteId, actionType, current.Current_TCV__c, priorTcv),
                Last_Stamped_Order__c = o.Id
            );
            for (String suffix : LOB_TO_SUFFIX.values()) {
                Decimal priorLob = prior == null
                    ? 0
                    : zero((Decimal) prior.get('Current_MRR_' + suffix + '__c'));
                target.put(
                    'Existing_MRR_' + suffix + '__c',
                    prior == null ? null : (Decimal) prior.get('Current_MRR_' + suffix + '__c')
                );
                target.put(
                    'Current_MRR_' + suffix + '__c',
                    netOf(
                        o.QuoteId,
                        actionType,
                        (Decimal) current.get('Current_MRR_' + suffix + '__c'),
                        priorLob
                    )
                );
            }
            for (String quoteField : QUOTE_TO_CONTRACT_MARGIN.keySet()) {
                target.put(QUOTE_TO_CONTRACT_MARGIN.get(quoteField), current.get(quoteField));
            }
            updates.put(o.ContractId, target);
        }
        commitRecords(updates.values(), owners);
    }

    @TestVisible
    private static Map<Id, Map<Id, Decimal>> loadAssetBaselines(Set<Id> contractIds) {
        if (assetBaselineOverride != null) {
            assetBaselineLobs = assetBaselineLobOverride == null
                ? new Map<Id, Map<Id, String>>()
                : assetBaselineLobOverride;
            assetUnitMrrs = assetUnitMrrOverride == null
                ? new Map<Id, Map<Id, Decimal>>()
                : assetUnitMrrOverride;
            return assetBaselineOverride;
        }
        assetBaselineLobs = new Map<Id, Map<Id, String>>();
        assetUnitMrrs = new Map<Id, Map<Id, Decimal>>();
        Map<Id, Map<Id, Decimal>> result = new Map<Id, Map<Id, Decimal>>();
        if (contractIds == null || contractIds.isEmpty()) {
            return result;
        }

        Map<Id, Id> contractByAssetId = new Map<Id, Id>();
        for (AssetContractRelationship acr : [
            SELECT AssetId, ContractId
            FROM AssetContractRelationship
            WHERE ContractId IN :contractIds
        ]) {
            contractByAssetId.put(acr.AssetId, acr.ContractId);
        }
        if (contractByAssetId.isEmpty()) {
            return result;
        }

        Map<Id, List<AssetStatePeriod>> periodsByAssetId = new Map<Id, List<AssetStatePeriod>>();
        for (AssetStatePeriod period : [
            SELECT AssetId, Asset.Product2Id, Asset.Product2.Service_Offering__c, Mrr, Quantity,
                   StartDate, EndDate, Line_of_Business__c
            FROM AssetStatePeriod
            WHERE AssetId IN :contractByAssetId.keySet()
            ORDER BY StartDate ASC
        ]) {
            if (!periodsByAssetId.containsKey(period.AssetId)) {
                periodsByAssetId.put(period.AssetId, new List<AssetStatePeriod>());
            }
            periodsByAssetId.get(period.AssetId).add(period);
        }

        Map<Id, AssetStatePeriod> latestByAssetId = new Map<Id, AssetStatePeriod>();
        for (Id assetId : periodsByAssetId.keySet()) {
            AssetStatePeriod chosen = periodCoveringNow(periodsByAssetId.get(assetId));
            if (chosen != null) {
                latestByAssetId.put(assetId, chosen);
            }
        }

        // Contract -> Product2Id -> summed asset quantity, so the per-unit MRR
        // is total MRR / total units even when a product spans several assets.
        Map<Id, Map<Id, Decimal>> quantityByProduct = new Map<Id, Map<Id, Decimal>>();
        for (AssetStatePeriod period : latestByAssetId.values()) {
            Id contractId = contractByAssetId.get(period.AssetId);
            if (contractId == null || period.Asset.Product2Id == null) {
                continue;
            }
            if (!result.containsKey(contractId)) {
                result.put(contractId, new Map<Id, Decimal>());
                assetBaselineLobs.put(contractId, new Map<Id, String>());
                quantityByProduct.put(contractId, new Map<Id, Decimal>());
            }
            Map<Id, Decimal> byProductId = result.get(contractId);
            byProductId.put(
                period.Asset.Product2Id,
                zero(byProductId.get(period.Asset.Product2Id)) + zero(period.Mrr)
            );
            Map<Id, Decimal> units = quantityByProduct.get(contractId);
            units.put(
                period.Asset.Product2Id,
                zero(units.get(period.Asset.Product2Id)) + zero(period.Quantity)
            );
            Map<Id, String> lobByProductId = assetBaselineLobs.get(contractId);
            String periodLob = lobOf(
                period.Line_of_Business__c,
                period.Asset.Product2 == null ? null : period.Asset.Product2.Service_Offering__c
            );
            if (lobByProductId.get(period.Asset.Product2Id) == null && periodLob != null) {
                lobByProductId.put(period.Asset.Product2Id, periodLob);
            }
        }

        for (Id contractId : result.keySet()) {
            Map<Id, Decimal> unitByProduct = new Map<Id, Decimal>();
            Map<Id, Decimal> units = quantityByProduct.get(contractId);
            for (Id productId : result.get(contractId).keySet()) {
                Decimal quantity = zero(units.get(productId));
                if (quantity > 0) {
                    unitByProduct.put(productId, result.get(contractId).get(productId) / quantity);
                }
            }
            assetUnitMrrs.put(contractId, unitByProduct);
        }
        return result;
    }

    private static Map<Id, Decimal> unitMrrFor(Id contractId) {
        return contractId == null ? null : assetUnitMrrs.get(contractId);
    }

    // The MRR__c formula is NetUnitPrice * Quantity. RCA leaves NetUnitPrice
    // blank on Amend/Cancel lines for assets already priced from their last
    // transaction, so the formula reads 0 and every loss silently vanishes.
    // Fall back to the asset book's per-unit MRR for that product - the same
    // figure RCA used to derive the line's NetTotalPrice.
    @TestVisible
    private static Decimal mrrOf(QuoteLineItem line, Map<Id, Decimal> unitMrrByProduct) {
        if (line.NetUnitPrice != null || zero(line.MRR__c) != 0
            || unitMrrByProduct == null || line.Quantity == null || line.Product2Id == null) {
            return line.MRR__c;
        }
        Decimal unit = unitMrrByProduct.get(line.Product2Id);
        return unit == null ? line.MRR__c : unit * line.Quantity;
    }

    // A ramped quote carries one copy of every recurring line per ramp segment
    // (Year 1, Year 2, Year 3 ...), each priced for its own year. MRR is a
    // monthly run-rate, so summing MRR__c across the whole quote multiplies it
    // by the number of segments: quote 00016020 booked 382 for a 124/month
    // book (124 + 129 + 129). Monthly figures therefore come from the FIRST
    // segment only - the earliest-starting ramped group - plus any line that
    // sits outside the ramp. This also matches the contract baseline, which
    // the nightly batch reads from the asset period covering today.
    // TCV is deliberately NOT filtered: every segment is real money over the
    // term. Quotes with no ramped group come back untouched.
    @TestVisible
    private static List<QuoteLineItem> mrrLines(List<QuoteLineItem> lines) {
        if (lines == null || lines.isEmpty()) {
            return lines;
        }
        QuoteLineGroup first = null;
        for (QuoteLineItem line : lines) {
            QuoteLineGroup segment = rampSegmentOf(line);
            if (segment != null && (first == null || startsBefore(segment, first))) {
                first = segment;
            }
        }
        if (first == null) {
            return lines;
        }
        List<QuoteLineItem> result = new List<QuoteLineItem>();
        for (QuoteLineItem line : lines) {
            QuoteLineGroup segment = rampSegmentOf(line);
            if (segment == null || sameSegment(segment, first)) {
                result.add(line);
            }
        }
        return result;
    }

    private static QuoteLineGroup rampSegmentOf(QuoteLineItem line) {
        QuoteLineGroup segment = line == null ? null : line.QuoteLineGroup;
        return segment != null && segment.IsRamped == true ? segment : null;
    }

    // Earliest StartDate wins; SortOrder only breaks ties. SortOrder alone is
    // not trustworthy - mid-term amendment segments carry -999999999 and up.
    private static Boolean startsBefore(QuoteLineGroup candidate, QuoteLineGroup current) {
        if (candidate.StartDate != current.StartDate) {
            return current.StartDate == null
                || (candidate.StartDate != null && candidate.StartDate < current.StartDate);
        }
        return candidate.SortOrder != null
            && (current.SortOrder == null || candidate.SortOrder < current.SortOrder);
    }

    private static Boolean sameSegment(QuoteLineGroup a, QuoteLineGroup b) {
        if (a.Id != null && b.Id != null) {
            return a.Id == b.Id;
        }
        return a.StartDate == b.StartDate && a.SortOrder == b.SortOrder;
    }

    @TestVisible
    private static AssetStatePeriod periodCoveringNow(List<AssetStatePeriod> periods) {
        if (periods == null || periods.isEmpty()) {
            return null;
        }
        Datetime now = Datetime.now();
        AssetStatePeriod started = null;
        for (AssetStatePeriod period : periods) {
            Boolean hasStarted = period.StartDate == null || period.StartDate <= now;
            Boolean hasEnded = period.EndDate != null && period.EndDate < now;
            if (hasStarted && !hasEnded) {
                return period;
            }
            if (hasStarted) {
                started = period;
            }
        }
        return started == null ? periods[0] : started;
    }

    @TestVisible
    private static Map<Id, RenewedProduct> renewedByProduct(List<QuoteLineItem> lines) {
        Map<Id, RenewedProduct> byProduct = new Map<Id, RenewedProduct>();
        if (lines == null) {
            return byProduct;
        }
        for (QuoteLineItem line : lines) {
            if (line.Product2Id == null) {
                continue;
            }
            RenewedProduct product = byProduct.get(line.Product2Id);
            if (product == null) {
                product = new RenewedProduct();
                byProduct.put(line.Product2Id, product);
            }
            if (product.lob == null) {
                product.lob = lobOf(line);
            }
            if (isRecurring(line) && line.MRR__c != null) {
                product.mrr += line.MRR__c;
            }
            if (line.NetTotalPrice != null) {
                product.tcv += line.NetTotalPrice;
            }
        }
        for (RenewedProduct product : byProduct.values()) {
            if (product.mrr < 0) {
                product.mrr = 0;
            }
            if (product.tcv < 0) {
                product.tcv = 0;
            }
        }
        return byProduct;
    }

    public static Decimal sumRenewedMrr(List<QuoteLineItem> lines) {
        Decimal total = 0;
        for (RenewedProduct product : renewedByProduct(mrrLines(lines)).values()) {
            total += product.mrr;
        }
        return total;
    }

    public static Decimal sumRenewedTcv(List<QuoteLineItem> lines) {
        Decimal total = 0;
        for (RenewedProduct product : renewedByProduct(lines).values()) {
            total += product.tcv;
        }
        return total;
    }

    public static Map<String, Decimal> sumRenewedMrrByLob(List<QuoteLineItem> lines) {
        Map<String, Decimal> totals = new Map<String, Decimal>();
        for (String suffix : LOB_TO_SUFFIX.values()) {
            totals.put(suffix, 0);
        }
        for (RenewedProduct product : renewedByProduct(mrrLines(lines)).values()) {
            String suffix = LOB_TO_SUFFIX.get(product.lob);
            if (suffix == null) {
                continue;
            }
            totals.put(suffix, totals.get(suffix) + product.mrr);
        }
        return totals;
    }

    @TestVisible
    private static Decimal renewalGrossLoss(Map<Id, Decimal> baseline, List<QuoteLineItem> lines) {
        if (baseline == null || baseline.isEmpty()) {
            return 0;
        }

        Map<Id, RenewedProduct> renewedByProductId = renewedByProduct(mrrLines(lines));

        Decimal loss = 0;
        for (Id productId : baseline.keySet()) {
            Decimal was = zero(baseline.get(productId));
            RenewedProduct product = renewedByProductId.get(productId);
            Decimal renewed = product == null ? 0 : product.mrr;
            if (renewed < was) {
                loss += renewed - was;
            }
        }
        return loss;
    }

    private class RenewedProduct {
        private Decimal mrr = 0;
        private Decimal tcv = 0;
        private String lob;
    }

    @TestVisible
    private static Decimal netOf(Id quoteId, String actionType, Decimal current, Decimal existing) {
        return RESTATING_ACTION_TYPES.contains(actionTypeOf(quoteId, actionType))
            ? zero(current)
            : zero(current) + zero(existing);
    }

    @TestVisible
    private static Boolean supersededByLaterStamp(Contract prior, Order o) {
        if (prior.Last_Stamped_Order__c == null) {
            return false;
        }
        if (prior.Last_Stamped_Order__c == o.Id) {
            return true;
        }
        Datetime stampedAt = prior.Last_Stamped_Order__r == null
            ? null
            : prior.Last_Stamped_Order__r.ActivatedDate;
        if (stampedAt == null || o.ActivatedDate == null) {
            return false;
        }
        return stampedAt > o.ActivatedDate;
    }

    @TestVisible
    private static Map<Id, Contract> loadContractBaselines(Set<Id> contractIds) {
        Map<Id, Contract> result = new Map<Id, Contract>();
        if (contractIds == null || contractIds.isEmpty()) {
            return result;
        }
        for (Contract c : [
            SELECT Id, Current_TCV__c, Current_MRR__c, Current_MRR_Cyber__c, Current_MRR_Desk__c,
                   Current_MRR_Infra__c, Current_MRR_Private_Cloud__c, Current_MRR_VOIP__c
            FROM Contract
            WHERE Id IN :contractIds
        ]) {
            result.put(c.Id, c);
        }
        return result;
    }

    @TestVisible
    private static Map<Id, List<QuoteLineItem>> loadLines(Set<Id> quoteIds, Set<Id> excludedLineIds) {
        Map<Id, List<QuoteLineItem>> result = new Map<Id, List<QuoteLineItem>>();
        if (quoteIds == null || quoteIds.isEmpty()) {
            return result;
        }
        for (Id quoteId : quoteIds) {
            result.put(quoteId, new List<QuoteLineItem>());
        }

        List<QuoteLineItem> source = lineOverride != null
            ? flattenOverride(quoteIds)
            : [
                SELECT Id, QuoteId, Product2Id, Quantity, NetUnitPrice, NetTotalPrice, MRR__c,
                       Line_of_Business__c, Product2.Service_Offering__c, SellingModelType, QuoteLineGroupId,
                       QuoteLineGroup.IsRamped, QuoteLineGroup.StartDate, QuoteLineGroup.SortOrder
                FROM QuoteLineItem
                WHERE QuoteId IN :quoteIds
            ];

        for (QuoteLineItem line : source) {
            if (excludedLineIds != null && line.Id != null && excludedLineIds.contains(line.Id)) {
                continue;
            }
            if (result.containsKey(line.QuoteId)) {
                result.get(line.QuoteId).add(line);
            }
        }
        return result;
    }

    private static List<QuoteLineItem> flattenOverride(Set<Id> quoteIds) {
        List<QuoteLineItem> flattened = new List<QuoteLineItem>();
        for (Id quoteId : quoteIds) {
            List<QuoteLineItem> lines = lineOverride.get(quoteId);
            if (lines != null) {
                flattened.addAll(lines);
            }
        }
        return flattened;
    }

    public static Decimal sumBookedMrr(List<QuoteLineItem> lines) {
        return sumBookedMrr(lines, null);
    }

    public static Decimal sumBookedMrr(List<QuoteLineItem> lines, Map<Id, Decimal> unitMrrByProduct) {
        Decimal total = 0;
        if (lines == null) {
            return total;
        }
        for (QuoteLineItem line : mrrLines(lines)) {
            Decimal mrr = isRecurring(line) ? mrrOf(line, unitMrrByProduct) : null;
            if (mrr != null) {
                total += mrr;
            }
        }
        return total;
    }

    public static Decimal sumNegativeMrr(List<QuoteLineItem> lines) {
        return sumNegativeMrr(lines, null);
    }

    public static Decimal sumNegativeMrr(List<QuoteLineItem> lines, Map<Id, Decimal> unitMrrByProduct) {
        Decimal total = 0;
        if (lines == null) {
            return total;
        }
        for (QuoteLineItem line : mrrLines(lines)) {
            Decimal mrr = isRecurring(line) ? mrrOf(line, unitMrrByProduct) : null;
            if (mrr != null && mrr < 0) {
                total += mrr;
            }
        }
        return total;
    }

    public static Decimal sumTcv(List<QuoteLineItem> lines) {
        Decimal total = 0;
        if (lines == null) {
            return total;
        }
        for (QuoteLineItem line : lines) {
            if (line.NetTotalPrice != null) {
                total += line.NetTotalPrice;
            }
        }
        return total;
    }

    public static Map<String, Decimal> sumMrrByLob(List<QuoteLineItem> lines) {
        return sumMrrByLob(lines, null);
    }

    public static Map<String, Decimal> sumMrrByLob(
        List<QuoteLineItem> lines, Map<Id, Decimal> unitMrrByProduct
    ) {
        Map<String, Decimal> totals = emptyLobTotals();
        if (lines == null) {
            return totals;
        }
        for (QuoteLineItem line : mrrLines(lines)) {
            Decimal mrr = isRecurring(line) ? mrrOf(line, unitMrrByProduct) : null;
            if (mrr == null) {
                continue;
            }
            String suffix = LOB_TO_SUFFIX.get(lobOf(line));
            if (suffix == null) {
                continue;
            }
            totals.put(suffix, totals.get(suffix) + mrr);
        }
        return totals;
    }

    public static Map<String, Decimal> sumNegativeMrrByLob(List<QuoteLineItem> lines) {
        return sumNegativeMrrByLob(lines, null);
    }

    public static Map<String, Decimal> sumNegativeMrrByLob(
        List<QuoteLineItem> lines, Map<Id, Decimal> unitMrrByProduct
    ) {
        Map<String, Decimal> totals = emptyLobTotals();
        if (lines == null) {
            return totals;
        }
        for (QuoteLineItem line : mrrLines(lines)) {
            Decimal mrr = isRecurring(line) ? mrrOf(line, unitMrrByProduct) : null;
            if (mrr == null || mrr >= 0) {
                continue;
            }
            String suffix = LOB_TO_SUFFIX.get(lobOf(line));
            if (suffix == null) {
                continue;
            }
            totals.put(suffix, totals.get(suffix) + mrr);
        }
        return totals;
    }

    @TestVisible
    private static Map<String, Decimal> renewalGrossLossByLob(
        Map<Id, Decimal> baseline, Map<Id, String> lobByProductId, List<QuoteLineItem> lines
    ) {
        Map<String, Decimal> totals = emptyLobTotals();
        if (baseline == null || baseline.isEmpty()) {
            return totals;
        }

        Map<Id, RenewedProduct> renewedByProductId = renewedByProduct(mrrLines(lines));

        for (Id productId : baseline.keySet()) {
            Decimal was = zero(baseline.get(productId));
            RenewedProduct product = renewedByProductId.get(productId);
            Decimal renewed = product == null ? 0 : product.mrr;
            if (renewed >= was) {
                continue;
            }
            String lob = lobByProductId == null ? null : lobByProductId.get(productId);
            if (lob == null && product != null) {
                lob = product.lob;
            }
            String suffix = LOB_TO_SUFFIX.get(lob);
            if (suffix == null) {
                continue;
            }
            totals.put(suffix, totals.get(suffix) + (renewed - was));
        }
        return totals;
    }

    private static Map<String, Decimal> emptyLobTotals() {
        Map<String, Decimal> totals = new Map<String, Decimal>();
        for (String suffix : LOB_TO_SUFFIX.values()) {
            totals.put(suffix, 0);
        }
        return totals;
    }

    private static Boolean isRecurring(QuoteLineItem line) {
        return line != null && line.SellingModelType != ONE_TIME;
    }

    private static Decimal zero(Decimal value) {
        return value == null ? 0 : value;
    }

    // Generic numerator/denominator percent helper for NRR/GRR. Returns null
    // (not 0) when there's no Existing MRR baseline to divide by, since
    // retention is undefined rather than zero in that case (e.g. New Business).
    @TestVisible
    private static Decimal calcRetentionPercent(Decimal numerator, Decimal denominator) {
        if (denominator == null || denominator == 0) {
            return null;
        }
        return ((zero(numerator) / denominator) * 100).setScale(2);
    }

    private static Map<Id, Id> ownerBySourceId(List<Quote> quotes) {
        Map<Id, Id> result = new Map<Id, Id>();
        for (Quote q : quotes) {
            result.put(q.Id, q.OwnerId);
        }
        return result;
    }

    private static void commitRecords(List<SObject> records, Map<Id, Id> ownerByRecordId) {
        if (records == null || records.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = Database.update(records, false);
        List<Task> faults = new List<Task>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                continue;
            }
            Id recordId = records[i].Id;
            faults.add(buildFaultTask(
                recordId,
                ownerByRecordId == null ? null : ownerByRecordId.get(recordId),
                errorText(results[i])
            ));
        }
        insertFaults(faults);
    }

    private static void logFaults(Set<Id> recordIds, Map<Id, Id> ownerByRecordId, String message) {
        List<Task> faults = new List<Task>();
        for (Id recordId : recordIds) {
            faults.add(buildFaultTask(
                recordId,
                ownerByRecordId == null ? null : ownerByRecordId.get(recordId),
                message
            ));
        }
        insertFaults(faults);
    }

    private static void logUnexpected(Set<Id> recordIds, Exception e) {
        String message = e.getTypeName() + ': ' + e.getMessage() + ' | ' + e.getStackTraceString();
        faultLog.add(message);
        List<Task> faults = new List<Task>();
        if (recordIds != null) {
            for (Id recordId : recordIds) {
                faults.add(buildFaultTask(recordId, null, message));
            }
        }
        insertFaults(faults);
    }

    private static void insertFaults(List<Task> faults) {
        if (faults == null || faults.isEmpty()) {
            return;
        }
        try {
            Database.insert(faults, false);
        } catch (Exception ignored) {
            faultLog.add('Fault task insert failed: ' + ignored.getMessage());
        }
    }

    private static Task buildFaultTask(Id recordId, Id ownerId, String message) {
        Task fault = new Task(
            WhatId = recordId,
            Subject = FAULT_SUBJECT,
            Description = truncate(message, 32000),
            Status = 'Open',
            Priority = 'Normal',
            ActivityDate = Date.today()
        );
        if (ownerId != null) {
            fault.OwnerId = ownerId;
        }
        return fault;
    }

    private static String errorText(Database.SaveResult result) {
        List<String> parts = new List<String>();
        for (Database.Error error : result.getErrors()) {
            parts.add(error.getStatusCode() + ': ' + error.getMessage() + ' ' + error.getFields());
        }
        return String.join(parts, ' | ');
    }

    private static String truncate(String value, Integer maxLength) {
        if (value == null) {
            return null;
        }
        return value.length() > maxLength ? value.substring(0, maxLength) : value;
    }
}