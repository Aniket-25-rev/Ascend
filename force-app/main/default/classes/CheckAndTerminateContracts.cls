public class CheckAndTerminateContracts {

    /*
     
    public class Request {
        @InvocableVariable(required=true)
        public List<String> contractIds;
    }

   
    @InvocableMethod(
        label       = 'Check and Terminate Contracts'
        description = 'Sets Contract.Status to Contract Terminated when every recurring (non-OneTime) Asset linked to the contract has a latest AssetAction with Business Category (CategoryEnum) = Cancellations.'
    )
    public static void execute(List<Request> requests) {
        Set<Id> allContractIds = new Set<Id>();
        for (Request req : requests) {
            if (req.contractIds == null) continue;
            for (String cid : req.contractIds) {
                if (cid != null) allContractIds.add((Id) cid);
            }
        }
        if (allContractIds.isEmpty()) return;

        // Build Contract → Set<AssetId> map via the junction object
        Map<Id, Set<Id>> contractToAssetIds = new Map<Id, Set<Id>>();
        for (AssetContractRelationship acr : [
            SELECT ContractId, AssetId
            FROM   AssetContractRelationship
            WHERE  ContractId IN :allContractIds
        ]) {
            if (!contractToAssetIds.containsKey(acr.ContractId)) {
                contractToAssetIds.put(acr.ContractId, new Set<Id>());
            }
            contractToAssetIds.get(acr.ContractId).add(acr.AssetId);
        }
        processContracts(contractToAssetIds);
    }

    
     
    @TestVisible
    private static void processContracts(Map<Id, Set<Id>> contractToAssetIds) {
        if (contractToAssetIds.isEmpty()) return;

        Set<Id> allAssetIds = new Set<Id>();
        for (Set<Id> ids : contractToAssetIds.values()) allAssetIds.addAll(ids);

        // CurrentMrr = 0 / null identifies OneTime assets — they are excluded
        // from the "all cancelled" check so they do not block termination
        Map<Id, Decimal> mrrByAssetId = new Map<Id, Decimal>();
        for (Asset a : [
            SELECT Id, CurrentMrr
            FROM   Asset
            WHERE  Id IN :allAssetIds
        ]) {
            mrrByAssetId.put(a.Id, a.CurrentMrr);
        }

        // Retrieve all AssetActions for these assets to determine their latest
        // Business Category. "Latest" = highest ActionDate wins.
        List<AssetAction> assetActions = [
            SELECT AssetId, CategoryEnum, ActionDate
            FROM   AssetAction
            WHERE  AssetId IN :allAssetIds
        ];
        Map<Id, String> latestCategoryByAssetId = buildLatestCategoryByAssetId(assetActions);

        Set<Id> contractToTerminate = determineContractsToTerminate(
            contractToAssetIds, mrrByAssetId, latestCategoryByAssetId
        );
        terminateQualifyingContracts(contractToTerminate);
    }

    
     
    @TestVisible
    private static void terminateQualifyingContracts(Set<Id> contractToTerminate) {
        if (contractToTerminate.isEmpty()) return;

        List<Contract> toUpdate = new List<Contract>();
        for (Contract c : [
            SELECT Id FROM Contract
            WHERE  Id IN :contractToTerminate AND Status = 'Activated'
        ]) {
            toUpdate.add(new Contract(Id = c.Id, Status = 'Contract Terminated'));
        }
        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }
    }

    
    @TestVisible
    private static Map<Id, String> buildLatestCategoryByAssetId(List<AssetAction> assetActions) {
        Map<Id, AssetAction> latestByAssetId = new Map<Id, AssetAction>();
        for (AssetAction aa : assetActions) {
            AssetAction existing = latestByAssetId.get(aa.AssetId);
            if (existing == null || aa.ActionDate > existing.ActionDate) {
                latestByAssetId.put(aa.AssetId, aa);
            }
        }

        Map<Id, String> result = new Map<Id, String>();
        for (Id assetId : latestByAssetId.keySet()) {
            result.put(assetId, latestByAssetId.get(assetId).CategoryEnum);
        }
        return result;
    }

    
    @TestVisible
    private static Set<Id> determineContractsToTerminate(
        Map<Id, Set<Id>> contractToAssetIds,
        Map<Id, Decimal> mrrByAssetId,
        Map<Id, String> latestCategoryByAssetId
    ) {
        Set<Id> contractToTerminate = new Set<Id>();
        for (Id contractId : contractToAssetIds.keySet()) {
            Integer recurringTotal     = 0;
            Integer recurringCancelled = 0;

            for (Id assetId : contractToAssetIds.get(contractId)) {
                if (!mrrByAssetId.containsKey(assetId)) continue;

                Decimal mrr = mrrByAssetId.get(assetId);
                if (mrr == null || mrr == 0) continue; // Skip OneTime assets (MRR = 0)

                recurringTotal++;
                if (latestCategoryByAssetId.get(assetId) == 'Cancellations') recurringCancelled++;
            }

            // All recurring Assets must be cancelled; at least one must exist
            if (recurringTotal > 0 && recurringTotal == recurringCancelled) {
                contractToTerminate.add(contractId);
            }
        }
        return contractToTerminate;
    }
   */
}