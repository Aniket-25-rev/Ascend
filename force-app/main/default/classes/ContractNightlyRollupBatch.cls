// Nightly batch that recomputes Contract-level rollup metrics derived from
// related Assets. Named generically (not e.g. "...MrrRollupBatch") because
// more rollup logic is expected to land here over time — new metrics should
// be added as additional fields computed within execute(), not as separate
// batch classes, so there's one nightly Contract-reconciliation pass rather
// than many.
public class ContractNightlyRollupBatch implements Database.Batchable<SObject>, Schedulable {

    // Current MRR: sum of AssetStatePeriod.Mrr for the period covering today,
    // across every active Asset linked via AssetContractRelationship. A
    // trigger on AssetStatePeriod alone can't cover this: the covering
    // period can change purely because today's date crossed into a new
    // AssetStatePeriod (e.g. a ramp step-up), with no record written on that
    // date to trigger off of. This batch re-derives the total from scratch
    // every night so drift can't accumulate.
    //
    // Current TCV: sum of Asset.TotalLifecycleAmount across the same active
    // Assets, same reasoning.

    // Only Activated Contracts ever have real Assets — they're created via
    // Order activation, which only happens once a Contract reaches this
    // status. Pre-activation Contracts (Draft, Negotiating, etc.) can never
    // have a matching AssetContractRelationship, so scanning them nightly
    // is pure waste. Once a Contract leaves Activated (Canceled/Expired/
    // Terminated), it's intentionally left alone too — Current_MRR__c/Current_TCV__c
    // simply freeze at their last computed value.
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([SELECT Id FROM Contract WHERE Status = 'Activated']);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        Set<Id> contractIds = new Set<Id>();
        for (SObject s : scope) {
            contractIds.add(((Contract) s).Id);
        }
        recalculateContracts(contractIds);
    }

    public static void recalculateContracts(Set<Id> contractIds) {
        if (contractIds == null || contractIds.isEmpty()) {
            return;
        }

        Map<Id, Decimal> tcvByContractId = new Map<Id, Decimal>();
        for (Id cId : contractIds) {
            tcvByContractId.put(cId, 0);
        }

        Map<Id, Id> contractIdByAssetId = new Map<Id, Id>();
        for (AssetContractRelationship acr : queryActiveAssetRelationships(contractIds, Date.today())) {
            Decimal tcv = (acr.Asset != null && acr.Asset.TotalLifecycleAmount != null)
                ? acr.Asset.TotalLifecycleAmount : 0;
            tcvByContractId.put(acr.ContractId, tcvByContractId.get(acr.ContractId) + tcv);

            contractIdByAssetId.put(acr.AssetId, acr.ContractId);
        }

        List<AssetStatePeriod> periods = activePeriods(contractIdByAssetId.keySet(), System.now());
        Map<Id, Decimal> mrrByContractId = mrrByContract(contractIds, contractIdByAssetId, periods);
        Map<Id, Map<String, Decimal>> lobByContractId =
            lobMrrByContract(contractIds, contractIdByAssetId, periods);

        List<Contract> toUpdate = new List<Contract>();
        for (Id cId : contractIds) {
            Contract target = new Contract(
                Id = cId,
                Current_MRR__c = mrrByContractId.get(cId),
                Current_TCV__c = tcvByContractId.get(cId)
            );
            Map<String, Decimal> lobTotals = lobByContractId.get(cId);
            for (String suffix : FinancialMetricsService.LOB_TO_SUFFIX.values()) {
                Decimal amount = lobTotals == null ? 0 : lobTotals.get(suffix);
                target.put('Current_MRR_' + suffix + '__c', amount == null ? 0 : amount);
            }
            toUpdate.add(target);
        }

        // Partial success, not all-or-nothing: a plain `update` on this list
        // rolls back every record in the chunk if even one fails (e.g. a
        // triggered flow erroring on one Contract's unrelated data) — so one
        // bad record would silently cost up to 199 good ones their rollup
        // update. Database.update(_, false) saves everything that can be
        // saved and reports the rest, so a single problem Contract never
        // blocks its neighbors.
        Database.SaveResult[] results = Database.update(toUpdate, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                for (Database.Error err : results[i].getErrors()) {
                    System.debug('==ContractNightlyRollupBatch update FAILED== Contract '
                        + toUpdate[i].Id + ': ' + err.getStatusCode() + ' - ' + err.getMessage());
                }
            }
        }
    }

    public void finish(Database.BatchableContext bc) {}

    // "Active" per ticket: the Asset's own lifecycle window must cover
    // asOf. LifecycleEndDate is null for open-ended/perpetual assets —
    // null must count as active, not get excluded. This is a deliberate
    // belt-and-suspenders check on top of the AssetStatePeriod date
    // window, not a duplicate of it — it's what makes the active-only rule
    // an explicit, visible part of this batch rather than an implicit side
    // effect of AssetStatePeriod behaving perfectly. Extracted (and
    // @TestVisible) so the filter itself can be asserted on directly.
    @TestVisible
    private static List<AssetContractRelationship> queryActiveAssetRelationships(
        Set<Id> contractIds, Date asOf
    ) {
        return [
            SELECT AssetId, ContractId, Asset.TotalLifecycleAmount
            FROM   AssetContractRelationship
            WHERE  ContractId IN :contractIds
            AND    Asset.LifecycleStartDate <= :asOf
            AND    (Asset.LifecycleEndDate = null OR Asset.LifecycleEndDate >= :asOf)
        ];
    }

    @TestVisible
    private static List<AssetStatePeriod> activePeriods(Set<Id> assetIds, Datetime asOf) {
        if (assetIds == null || assetIds.isEmpty()) {
            return new List<AssetStatePeriod>();
        }
        return [
            SELECT AssetId, Mrr, Line_of_Business__c
            FROM   AssetStatePeriod
            WHERE  AssetId IN :assetIds
            AND    StartDate <= :asOf
            AND    (EndDate = null OR EndDate >= :asOf)
        ];
    }

    @TestVisible
    private static Map<Id, Decimal> mrrByContract(
        Set<Id> contractIds, Map<Id, Id> contractIdByAssetId, List<AssetStatePeriod> periods
    ) {
        Map<Id, Decimal> result = new Map<Id, Decimal>();
        for (Id cId : contractIds) {
            result.put(cId, 0);
        }
        for (AssetStatePeriod asp : periods) {
            if (asp.Mrr == null) {
                continue;
            }
            Id cId = contractIdByAssetId.get(asp.AssetId);
            if (cId == null || !result.containsKey(cId)) {
                continue;
            }
            result.put(cId, result.get(cId) + asp.Mrr);
        }
        return result;
    }

    @TestVisible
    private static Map<Id, Map<String, Decimal>> lobMrrByContract(
        Set<Id> contractIds, Map<Id, Id> contractIdByAssetId, Datetime asOf
    ) {
        return lobMrrByContract(
            contractIds, contractIdByAssetId, activePeriods(contractIdByAssetId.keySet(), asOf)
        );
    }

    @TestVisible
    private static Map<Id, Map<String, Decimal>> lobMrrByContract(
        Set<Id> contractIds, Map<Id, Id> contractIdByAssetId, List<AssetStatePeriod> periods
    ) {
        Map<Id, Map<String, Decimal>> result = new Map<Id, Map<String, Decimal>>();
        for (Id cId : contractIds) {
            Map<String, Decimal> totals = new Map<String, Decimal>();
            for (String suffix : FinancialMetricsService.LOB_TO_SUFFIX.values()) {
                totals.put(suffix, 0);
            }
            result.put(cId, totals);
        }
        for (AssetStatePeriod asp : periods) {
            String suffix = FinancialMetricsService.LOB_TO_SUFFIX.get(asp.Line_of_Business__c);
            if (suffix == null || asp.Mrr == null) {
                continue;
            }
            Id cId = contractIdByAssetId.get(asp.AssetId);
            Map<String, Decimal> totals = result.get(cId);
            if (totals == null) {
                continue;
            }
            totals.put(suffix, totals.get(suffix) + asp.Mrr);
        }
        return result;
    }

    public void execute(SchedulableContext sc) {
        Database.executeBatch(new ContractNightlyRollupBatch(), 200);
    }
}