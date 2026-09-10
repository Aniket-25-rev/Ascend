public without sharing class FinancialMetricsService {

    public static final Map<String, String> LOB_TO_SUFFIX = new Map<String, String>{
        'Cybersecurity'  => 'Cyber',
        'Service Desk'   => 'Desk',
        'Infrastructure' => 'Infra',
        'Private Cloud'  => 'Private_Cloud',
        'VOIP'           => 'VOIP'
    };

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
            SELECT Id, OwnerId, OriginalActionType, Existing_TCV__c, Existing_MRR__c,
                   Existing_MRR_Cyber__c, Existing_MRR_Desk__c, Existing_MRR_Infra__c,
                   Existing_MRR_Private_Cloud__c, Existing_MRR_VOIP__c
            FROM Quote
            WHERE Id IN :targets
        ]);
        if (quotes.isEmpty()) {
            return;
        }

        Map<Id, List<QuoteLineItem>> linesByQuoteId = loadLines(quotes.keySet(), excludedLineIds);

        List<Quote> updates = new List<Quote>();
        for (Quote q : quotes.values()) {
            updates.add(buildCurrentSet(
                q.Id,
                RESTATING_ACTION_TYPES.contains(actionTypeOf(q.Id, q.OriginalActionType)),
                linesByQuoteId.get(q.Id)
            ));
        }
        commitRecords(updates, ownerBySourceId(quotes.values()));
    }

    @TestVisible
    private static Quote buildCurrentSet(Id quoteId, Boolean restating, List<QuoteLineItem> lines) {
        Map<String, Decimal> byLob = restating ? sumRenewedMrrByLob(lines) : sumMrrByLob(lines);
        Quote target = new Quote(Id = quoteId);
        for (String suffix : LOB_TO_SUFFIX.values()) {
            target.put('Current_MRR_' + suffix + '__c', zero(byLob.get(suffix)));
        }
        target.Current_MRR__c = restating ? sumRenewedMrr(lines) : sumBookedMrr(lines);
        target.Current_TCV__c = restating ? sumRenewedTcv(lines) : sumTcv(lines);
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
                   Current_MRR_Private_Cloud__c, Current_MRR_VOIP__c
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

            Quote refreshed = buildCurrentSet(q.Id, restating, lines);
            if (currentSetChanged(q, refreshed)) {
                quoteUpdates.add(refreshed);
                quoteOwners.put(q.Id, q.OwnerId);
            }

            Opportunity prior = priorByOpportunityId.get(q.OpportunityId);
            if (prior != null && WALKAWAY_STAGES.contains(prior.StageName)) {
                continue;
            }

            Decimal loss = restating
                ? renewalGrossLoss(assetBaselines.get(q.ContractId), lines)
                : sumNegativeMrr(lines);
            Decimal booked = netOf(
                q.Id, q.OriginalActionType, refreshed.Current_MRR__c, q.Existing_MRR__c
            );
            Decimal lossValue = loss < 0 ? loss : null;

            if (prior != null
                && zero(prior.Booked_MRR__c) == zero(booked)
                && zero(prior.Loss_MRR__c) == zero(lossValue)) {
                continue;
            }

            updates.put(q.OpportunityId, new Opportunity(
                Id = q.OpportunityId,
                Booked_MRR__c = booked,
                Loss_MRR__c = lossValue
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
            updates.add(new Opportunity(Id = opp.Id, Loss_MRR__c = -mrr, Booked_MRR__c = 0));
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
            return assetBaselineOverride;
        }
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
            SELECT AssetId, Asset.Product2Id, Mrr, StartDate, EndDate
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

        for (AssetStatePeriod period : latestByAssetId.values()) {
            Id contractId = contractByAssetId.get(period.AssetId);
            if (contractId == null || period.Asset.Product2Id == null) {
                continue;
            }
            if (!result.containsKey(contractId)) {
                result.put(contractId, new Map<Id, Decimal>());
            }
            Map<Id, Decimal> byProductId = result.get(contractId);
            byProductId.put(
                period.Asset.Product2Id,
                zero(byProductId.get(period.Asset.Product2Id)) + zero(period.Mrr)
            );
        }
        return result;
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
                product.lob = line.Line_of_Business__c;
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
        for (RenewedProduct product : renewedByProduct(lines).values()) {
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
        for (RenewedProduct product : renewedByProduct(lines).values()) {
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

        Map<Id, RenewedProduct> renewedByProductId = renewedByProduct(lines);

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
                       Line_of_Business__c, SellingModelType
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
        Decimal total = 0;
        if (lines == null) {
            return total;
        }
        for (QuoteLineItem line : lines) {
            if (isRecurring(line) && line.MRR__c != null) {
                total += line.MRR__c;
            }
        }
        return total;
    }

    public static Decimal sumNegativeMrr(List<QuoteLineItem> lines) {
        Decimal total = 0;
        if (lines == null) {
            return total;
        }
        for (QuoteLineItem line : lines) {
            if (isRecurring(line) && line.MRR__c != null && line.MRR__c < 0) {
                total += line.MRR__c;
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
        Map<String, Decimal> totals = new Map<String, Decimal>();
        for (String suffix : LOB_TO_SUFFIX.values()) {
            totals.put(suffix, 0);
        }
        if (lines == null) {
            return totals;
        }
        for (QuoteLineItem line : lines) {
            if (!isRecurring(line) || line.MRR__c == null) {
                continue;
            }
            String suffix = LOB_TO_SUFFIX.get(line.Line_of_Business__c);
            if (suffix == null) {
                continue;
            }
            totals.put(suffix, totals.get(suffix) + line.MRR__c);
        }
        return totals;
    }

    private static Boolean isRecurring(QuoteLineItem line) {
        return line != null && line.SellingModelType != ONE_TIME;
    }

    private static Decimal zero(Decimal value) {
        return value == null ? 0 : value;
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