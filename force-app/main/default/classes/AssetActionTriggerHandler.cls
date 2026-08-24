public class AssetActionTriggerHandler {

    public static void beforeInsert(List<AssetAction> newRecords) {
        populateLineOfBusiness(newRecords);
    }

    // =========================================================
    // AFTER INSERT — catch any record the before-insert pass
    // couldn't resolve (its AssetStatePeriod didn't exist yet at
    // that point in the transaction — true for a brand-new Asset's
    // first "Generate Initial Sale" AssetAction) and backfill it
    // asynchronously, once the transaction (and its AssetStatePeriod)
    // has committed.
    // =========================================================
    public static void afterInsert(List<AssetAction> newRecords) {
        Set<Id> unresolvedIds = new Set<Id>();
        for (AssetAction aa : newRecords) {
            if (aa.Line_of_Business__c == null && aa.AssetId != null) {
                unresolvedIds.add(aa.Id);
            }
        }

        if (!unresolvedIds.isEmpty()) {
            System.enqueueJob(new AssetActionLOBBackfillQueueable(unresolvedIds));
        }
    }

    // =========================================================
    // POPULATE LINE OF BUSINESS (ARM-101)
    // Line of Business is invariant per Asset across its state
    // periods, so the most recently created AssetStatePeriod for
    // a given Asset is a correct source whenever it already exists.
    // It won't exist yet for a brand-new Asset's first AssetAction —
    // that case is caught by afterInsert's async backfill instead.
    // =========================================================
    @TestVisible
    private static void populateLineOfBusiness(List<AssetAction> newRecords) {
        Set<Id> assetIds = new Set<Id>();
        for (AssetAction aa : newRecords) {
            if (aa.AssetId != null) {
                assetIds.add(aa.AssetId);
            }
        }

        if (assetIds.isEmpty()) return;

        Map<Id, String> lobByAssetId = getLatestLOBByAssetId(assetIds);

        for (AssetAction aa : newRecords) {
            if (aa.AssetId != null && lobByAssetId.containsKey(aa.AssetId)) {
                aa.Line_of_Business__c = lobByAssetId.get(aa.AssetId);
            }
        }
    }

    @TestVisible
    private static Map<Id, String> getLatestLOBByAssetId(Set<Id> assetIds) {
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
        return lobByAssetId;
    }
}