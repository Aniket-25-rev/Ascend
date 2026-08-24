public class AssetActionLOBBackfillQueueable implements Queueable {

    private Set<Id> assetActionIds;

    public AssetActionLOBBackfillQueueable(Set<Id> assetActionIds) {
        this.assetActionIds = assetActionIds;
    }

    public void execute(QueueableContext context) {
        List<AssetAction> actions = [
            SELECT Id, AssetId
            FROM   AssetAction
            WHERE  Id IN :assetActionIds
            AND    Line_of_Business__c = null
        ];

        if (actions.isEmpty()) return;

        Set<Id> assetIds = new Set<Id>();
        for (AssetAction aa : actions) {
            if (aa.AssetId != null) {
                assetIds.add(aa.AssetId);
            }
        }

        if (assetIds.isEmpty()) return;

        Map<Id, String> lobByAssetId = new Map<Id, String>();
        for (AssetStatePeriod asp : [
            SELECT AssetId, Line_of_Business__c
            FROM   AssetStatePeriod
            WHERE  AssetId IN :assetIds
            ORDER BY AssetId, CreatedDate DESC
        ]) {
            if (!lobByAssetId.containsKey(asp.AssetId)) {
                lobByAssetId.put(asp.AssetId, asp.Line_of_Business__c);
            }
        }

        List<AssetAction> toUpdate = new List<AssetAction>();
        for (AssetAction aa : actions) {
            if (lobByAssetId.containsKey(aa.AssetId)) {
                aa.Line_of_Business__c = lobByAssetId.get(aa.AssetId);
                toUpdate.add(aa);
            }
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }
}