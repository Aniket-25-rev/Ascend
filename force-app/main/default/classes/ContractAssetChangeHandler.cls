public with sharing class ContractAssetChangeHandler {

    public static void handleAfterUpdate(List<Asset> newList, Map<Id, Asset> oldMap) {
        Set<Id> contractIds = new Set<Id>();
        for (Asset a : newList) {
            if (a.ContractId != null) contractIds.add(a.ContractId);
        }

        Map<Id, Contract> contractMap = new Map<Id, Contract>();
        if (!contractIds.isEmpty()) {
            contractMap = new Map<Id, Contract>([
                SELECT Id, TCV__c FROM Contract WHERE Id IN :contractIds
            ]);
        }

        List<Contract_Asset_Change__c> changeLog = new List<Contract_Asset_Change__c>();
        Set<Id> contractIdsToRecalc = new Set<Id>();

        for (Asset newAsset : newList) {
            Asset oldAsset = oldMap.get(newAsset.Id);

            Decimal oldAmt = oldAsset.Price != null ? oldAsset.Price : 0;
            Decimal newAmt = newAsset.Price != null ? newAsset.Price : 0;
            Decimal delta  = newAmt - oldAmt;

            Boolean statusChanged = oldAsset.Status != newAsset.Status;
            Boolean amountChanged = delta != 0;
            if (!statusChanged && !amountChanged) continue;

            String txType   = resolveTransactionType(oldAsset, newAsset, delta);
            String churnType = resolveChurnType(txType);

            Decimal prevTCV = 0;
            if (newAsset.ContractId != null && contractMap.containsKey(newAsset.ContractId)) {
                Contract c = contractMap.get(newAsset.ContractId);
                prevTCV = c.TCV__c != null ? c.TCV__c : 0;
            }

            changeLog.add(new Contract_Asset_Change__c(
                Asset__c                = newAsset.Id,
                Account__c              = newAsset.AccountId,
                Contract__c             = newAsset.ContractId,
                Transaction_Date__c     = Date.today(),
                Line_Item_Start_Date__c = newAsset.InstallDate,
                Line_Item_End_Date__c   = newAsset.UsageEndDate,
                Change_Amount__c        = delta,
                Previous_Value__c       = oldAmt,
                New_Value__c            = newAmt,
                Previous_TCV__c         = prevTCV,
                New_TCV__c              = prevTCV + delta,
                Transaction_Type__c     = txType,
                Churn_Type__c           = churnType
            ));

            if (newAsset.ContractId != null) contractIdsToRecalc.add(newAsset.ContractId);
        }

        if (!changeLog.isEmpty()) insert changeLog;
        if (!contractIdsToRecalc.isEmpty()) ContractTCVService.recalculate(contractIdsToRecalc);
    }

    private static String resolveTransactionType(Asset oldA, Asset newA, Decimal delta) {
        if (newA.Status == 'Obsolete' && oldA.Status != 'Obsolete') return 'Removal';
        if (delta < 0) return 'Decrease';
        if (delta > 0) return 'Increase';
        return 'Status Change';
    }

    private static String resolveChurnType(String txType) {
        if (txType == 'Removal')  return 'Full Churn';
        if (txType == 'Decrease') return 'Partial Churn';
        return 'N/A';
    }
}
