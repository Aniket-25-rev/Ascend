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

        // Only Contracts whose rolled-up values actually changed are saved. Every save
        // fires the Contract automation (e.g. onContract_Upsert_Set_Integeration_Status
        // marks the Contract for the ServiceNow sync), so re-saving unchanged Contracts
        // every night would flag all of them for integration with no real change.
        List<String> rollupFields = rollupFieldNames();
        Map<Id, Contract> currentById = new Map<Id, Contract>((List<Contract>) Database.query(
            'SELECT Id, ' + String.join(rollupFields, ', ') + ' FROM Contract WHERE Id IN :contractIds'
        ));

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
            if (hasRollupChanged(currentById.get(cId), target, rollupFields)) {
                toUpdate.add(target);
            }
        }
        lastUpdateCount = toUpdate.size();

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

    // Number of Contracts the last recalculateContracts() call tried to save, so tests
    // can assert that unchanged Contracts are skipped.
    @TestVisible
    private static Integer lastUpdateCount = 0;

    @TestVisible
    private static List<String> rollupFieldNames() {
        List<String> fields = new List<String>{ 'Current_MRR__c', 'Current_TCV__c' };
        for (String suffix : FinancialMetricsService.LOB_TO_SUFFIX.values()) {
            fields.add('Current_MRR_' + suffix + '__c');
        }
        return fields;
    }

    // A blank stored value counts as a change even when the new value is 0, so a
    // Contract that was never rolled up still gets its first values written.
    @TestVisible
    private static Boolean hasRollupChanged(Contract current, Contract target, List<String> fields) {
        if (current == null) {
            return true;
        }
        for (String f : fields) {
            Decimal before = (Decimal) current.get(f);
            Decimal after = (Decimal) target.get(f);
            if (before != after) {
                return true;
            }
        }
        return false;
    }

    // "Active" here means not yet ended — deliberately NOT "already started".
    // An Order can be activated well before its service begins, and the
    // Contract must show its metrics from activation. Filtering on
    // LifecycleStartDate <= asOf excluded those Assets, so the rollup wrote 0
    // over the numbers Order_Stamp_Contract_Baseline had just stamped, and
    // the next quote then copied that 0 as its Existing baseline.
    // LifecycleEndDate is null for open-ended/perpetual assets — null must
    // count as active, not get excluded. Ended Assets are still excluded, so
    // genuine churn still rolls to 0. Extracted (and @TestVisible) so the
    // filter itself can be asserted on directly.
    @TestVisible
    private static List<AssetContractRelationship> queryActiveAssetRelationships(
        Set<Id> contractIds, Date asOf
    ) {
        return [
            SELECT AssetId, ContractId, Asset.TotalLifecycleAmount
            FROM   AssetContractRelationship
            WHERE  ContractId IN :contractIds
            AND    (Asset.LifecycleEndDate = null OR Asset.LifecycleEndDate >= :asOf)
        ];
    }

    // Every period for the scoped Assets is queried and narrowed in Apex
    // rather than filtered in SOQL, because the choice isn't a pure date
    // window: an Asset whose service starts in the future has no covering
    // period, and must still contribute its first one. Selection lives in
    // chooseCoveringPeriods() so it can be asserted on without DML —
    // lifecycle-managed Assets can't be built in a test.
    @TestVisible
    private static List<AssetStatePeriod> activePeriods(Set<Id> assetIds, Datetime asOf) {
        if (assetIds == null || assetIds.isEmpty()) {
            return new List<AssetStatePeriod>();
        }
        return chooseCoveringPeriods([
            SELECT AssetId, Mrr, Line_of_Business__c, Asset.Product2.Service_Offering__c, StartDate, EndDate
            FROM   AssetStatePeriod
            WHERE  AssetId IN :assetIds
            ORDER BY StartDate ASC
        ], asOf);
    }

    // One period per Asset, mirroring FinancialMetricsService.periodCoveringNow()
    // so the nightly reconciliation and the Loss MRR baseline can't disagree
    // about which period represents an Asset: the period covering asOf wins;
    // failing that the most recent period that has started; failing that the
    // earliest period, which is the not-yet-started case this exists for.
    // Expects periods ordered by StartDate ASC.
    @TestVisible
    private static List<AssetStatePeriod> chooseCoveringPeriods(
        List<AssetStatePeriod> periods, Datetime asOf
    ) {
        Map<Id, AssetStatePeriod> chosenByAssetId = new Map<Id, AssetStatePeriod>();
        Map<Id, AssetStatePeriod> earliestByAssetId = new Map<Id, AssetStatePeriod>();
        Set<Id> settled = new Set<Id>();
        if (periods == null) {
            return new List<AssetStatePeriod>();
        }
        for (AssetStatePeriod asp : periods) {
            if (settled.contains(asp.AssetId)) {
                continue;
            }
            if (!earliestByAssetId.containsKey(asp.AssetId)) {
                earliestByAssetId.put(asp.AssetId, asp);
            }
            Boolean hasStarted = asp.StartDate == null || asp.StartDate <= asOf;
            Boolean hasEnded = asp.EndDate != null && asp.EndDate < asOf;
            if (hasStarted && !hasEnded) {
                chosenByAssetId.put(asp.AssetId, asp);
                settled.add(asp.AssetId);
            } else if (hasStarted) {
                chosenByAssetId.put(asp.AssetId, asp);
            }
        }
        for (Id assetId : earliestByAssetId.keySet()) {
            if (!chosenByAssetId.containsKey(assetId)) {
                chosenByAssetId.put(assetId, earliestByAssetId.get(assetId));
            }
        }
        return chosenByAssetId.values();
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
            String suffix = FinancialMetricsService.LOB_TO_SUFFIX.get(FinancialMetricsService.lobOf(
                asp.Line_of_Business__c,
                asp.Asset == null || asp.Asset.Product2 == null ? null : asp.Asset.Product2.Service_Offering__c
            ));
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