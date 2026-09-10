public without sharing class QuoteItemTriggerHandler {

    // =========================================================
    // ENTRY POINT
    // =========================================================
    public static void onBeforeInsert(List<QuoteLineItem> newQLIs) {
        // Step 1: Collect unique QuoteActionIds from lines that need processing
        Set<Id> quoteActionIds = collectQuoteActionIds(newQLIs);
        if (quoteActionIds.isEmpty()) return;

        // Step 2: QuoteAction → SourceAssetId map
        Map<Id, Id> quoteActionToAssetId = queryQuoteActionToAsset(quoteActionIds);

        // Step 3: AssetActions for those assets
        List<AssetAction> assetActions = [
            SELECT Id, AssetId, ActionDate
            FROM   AssetAction
            WHERE  AssetId IN :quoteActionToAssetId.values()
        ];

        // Step 4: Latest AssetAction per Asset (pure logic — @TestVisible)
        Map<Id, AssetAction> assetIdToLatest = buildLatestAssetActionsMap(assetActions);

        // Step 5: Reverse map: AssetActionId → AssetId (pure logic — @TestVisible)
        Map<Id, Id> actionIdToAssetId = buildActionIdToAssetIdMap(assetIdToLatest);

        // Step 6: AssetActionSource records for the latest actions
        List<AssetActionSource> sources = [
            SELECT AssetActionId, ConstraintEngineNodeStatus__c
            FROM   AssetActionSource
            WHERE  AssetActionId IN :actionIdToAssetId.keySet()
            ORDER BY CreatedDate DESC
        ];

        // Step 7: First non-null status per Asset (pure logic — @TestVisible)
        Map<Id, String> assetIdToStatus = buildAssetIdToStatusMap(sources, actionIdToAssetId);

        // Step 8: Stamp status onto Trigger.new records (pure logic — @TestVisible)
        applyStatuses(newQLIs, quoteActionToAssetId, assetIdToStatus);
    }

    // =========================================================
    // COLLECT QUOTE ACTION IDS
    // =========================================================
    @TestVisible
    private static Set<Id> collectQuoteActionIds(List<QuoteLineItem> qlis) {
        Set<Id> ids = new Set<Id>();
        for (QuoteLineItem qli : qlis) {
            if (qli.QuoteActionId != null && qli.ConstraintEngineNodeStatus__c == null) {
                ids.add(qli.QuoteActionId);
            }
        }
        return ids;
    }

    // =========================================================
    // QUERY QUOTE ACTION → ASSET ID
    // =========================================================
    @TestVisible
    private static Map<Id, Id> queryQuoteActionToAsset(Set<Id> quoteActionIds) {
        Map<Id, Id> result = new Map<Id, Id>();
        for (QuoteAction qa : [
            SELECT Id, SourceAssetId
            FROM   QuoteAction
            WHERE  SourceAssetId != null
            AND    Id IN :quoteActionIds
        ]) {
            result.put(qa.Id, qa.SourceAssetId);
        }
        return result;
    }

    // =========================================================
    // BUILD LATEST ASSET ACTION MAP (pure logic — no SOQL)
    // =========================================================
    @TestVisible
    private static Map<Id, AssetAction> buildLatestAssetActionsMap(List<AssetAction> assetActions) {
        Map<Id, AssetAction> result = new Map<Id, AssetAction>();
        for (AssetAction aa : assetActions) {
            AssetAction existing = result.get(aa.AssetId);
            if (existing == null || aa.ActionDate > existing.ActionDate) {
                result.put(aa.AssetId, aa);
            }
        }
        return result;
    }

    // =========================================================
    // BUILD REVERSE MAP: AssetActionId → AssetId (pure logic — no SOQL)
    // =========================================================
    @TestVisible
    private static Map<Id, Id> buildActionIdToAssetIdMap(Map<Id, AssetAction> assetIdToLatest) {
        Map<Id, Id> result = new Map<Id, Id>();
        for (Id assetId : assetIdToLatest.keySet()) {
            result.put(assetIdToLatest.get(assetId).Id, assetId);
        }
        return result;
    }

    // =========================================================
    // BUILD ASSET ID → STATUS MAP (pure logic — no SOQL)
    // =========================================================
    @TestVisible
    private static Map<Id, String> buildAssetIdToStatusMap(
        List<AssetActionSource> sources,
        Map<Id, Id> actionIdToAssetId
    ) {
        Map<Id, String> result = new Map<Id, String>();
        for (AssetActionSource src : sources) {
            Id assetId = actionIdToAssetId.get(src.AssetActionId);
            if (assetId != null
                && !result.containsKey(assetId)
                && src.ConstraintEngineNodeStatus__c != null) {
                result.put(assetId, src.ConstraintEngineNodeStatus__c);
            }
        }
        return result;
    }

    // =========================================================
    // APPLY STATUSES TO TRIGGER.NEW (pure logic — no SOQL)
    // =========================================================
    @TestVisible
    private static void applyStatuses(
        List<QuoteLineItem> qlis,
        Map<Id, Id> quoteActionToAssetId,
        Map<Id, String> assetIdToStatus
    ) {
        for (QuoteLineItem qli : qlis) {
            if (qli.QuoteActionId != null && qli.ConstraintEngineNodeStatus__c == null) {
                Id assetId = quoteActionToAssetId.get(qli.QuoteActionId);
                if (assetId != null) {
                    String status = assetIdToStatus.get(assetId);
                    if (status != null) {
                        qli.ConstraintEngineNodeStatus__c = status;
                    }
                }
            }
        }
    }
}