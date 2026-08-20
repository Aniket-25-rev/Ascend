public with sharing class ContractTCVService {

    public static void recalculate(Set<Id> contractIds) {
        Map<Id, Decimal> tcvByContract = new Map<Id, Decimal>();
        for (Id cId : contractIds) tcvByContract.put(cId, 0);

        for (Asset a : [
            SELECT ContractId, Price
            FROM Asset
            WHERE ContractId IN :contractIds
              AND Status != 'Obsolete'
        ]) {
            Decimal current = tcvByContract.get(a.ContractId);
            tcvByContract.put(a.ContractId, current + (a.Price != null ? a.Price : 0));
        }

        List<Contract> toUpdate = new List<Contract>();
        for (Id cId : tcvByContract.keySet()) {
            toUpdate.add(new Contract(Id = cId, TCV__c = tcvByContract.get(cId)));
        }

        if (!toUpdate.isEmpty()) update toUpdate;
    }
}
