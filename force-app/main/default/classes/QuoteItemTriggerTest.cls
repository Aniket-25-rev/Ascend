@IsTest
private class QuoteItemTriggerTest {

    // =========================================================
    // HELPERS — DML DATA
    // =========================================================

    private static Account insertAccount() {
        Account a = new Account(
            Name             = 'TrigTest Acct',
            BillingStreet    = '123 Test St',
            BillingCity      = 'Austin',
            BillingState     = 'TX',
            BillingPostalCode= '78701',
            BillingCountry   = 'US'
        );
        insert a;
        return a;
    }

    private static Asset insertAsset(Id accountId) {
        Asset a = new Asset(Name = 'TrigTest Asset', AccountId = accountId, Status = 'Purchased');
        insert a;
        return a;
    }

    private static Quote insertQuote(Id accountId) {
        Opportunity opp = new Opportunity(
            Name      = 'TrigTest Opp',
            AccountId = accountId,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name         = 'TrigTest Quote',
            OpportunityId= opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status       = 'Draft'
        );
        insert q;
        return q;
    }

    private static PricebookEntry insertPBE() {
        Product2 prod = new Product2(Name = 'TrigTest Product', IsActive = true);
        insert prod;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id   = prod.Id,
            UnitPrice    = 100.00,
            IsActive     = true
        );
        insert pbe;
        return pbe;
    }

    // Helper: insert a QuoteAction. 'Add' type allows Quantity > 0 with no StartQuantity constraint.
    private static QuoteAction insertQuoteAction(Id quoteId, Id sourceAssetId) {
        QuoteAction qa = new QuoteAction(QuoteId = quoteId, Type = 'Add');
        if (sourceAssetId != null) qa.SourceAssetId = sourceAssetId;
        insert qa;
        return qa;
    }

    // Helper: build an in-memory QLI (not inserted yet)
    private static QuoteLineItem buildQLI(Id quoteId, Id pbeId, Id quoteActionId, String existingStatus) {
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId          = quoteId,
            PricebookEntryId = pbeId,
            Quantity         = 1,
            UnitPrice        = 100.00
        );
        if (quoteActionId  != null) qli.QuoteActionId                = quoteActionId;
        if (existingStatus != null) qli.ConstraintEngineNodeStatus__c = existingStatus;
        return qli;
    }

    // Deserialise a fake in-memory AssetAction with a specific Id.
    // AssetAction DML is not allowed in this org, so we use JSON.deserialize
    // to create an sObject instance that has Id/AssetId/ActionDate set.
    private static AssetAction fakeAssetAction(Id fakeId, Id assetId, Date actionDate) {
        // String.valueOf(Date) returns YYYY-MM-DD (ISO 8601), required by JSON.deserialize
        String payload = '{"Id":"' + fakeId + '","AssetId":"' + assetId
            + '","ActionDate":"' + String.valueOf(actionDate) + '"}';
        return (AssetAction) JSON.deserialize(payload, AssetAction.class);
    }

    // =========================================================
    // TRIGGER INTEGRATION TESTS (fire via QLI DML)
    // =========================================================

    /**
     * All QLIs have null QuoteActionId → collectQuoteActionIds returns empty
     * set → onBeforeInsert returns early. Nothing stamped.
     */
    @IsTest
    static void trigger_nullQuoteActionId_returnsEarly() {
        Account acc = insertAccount();
        Quote   q   = insertQuote(acc.Id);
        PricebookEntry pbe = insertPBE();

        Test.startTest();
        insert buildQLI(q.Id, pbe.Id, null, null);
        Test.stopTest();

        QuoteLineItem result = [SELECT ConstraintEngineNodeStatus__c FROM QuoteLineItem WHERE QuoteId=:q.Id LIMIT 1];
        System.assertEquals(null, result.ConstraintEngineNodeStatus__c);
    }

    /**
     * QLI has QuoteActionId but ConstraintEngineNodeStatus__c is already set
     * → not added to quoteActionIds → early return. Pre-set status preserved.
     */
    @IsTest
    static void trigger_preExistingStatus_skippedFromCollection() {
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);
        Quote   q     = insertQuote(acc.Id);
        PricebookEntry pbe = insertPBE();
        QuoteAction qa = insertQuoteAction(q.Id, asset.Id);

        Test.startTest();
        insert buildQLI(q.Id, pbe.Id, qa.Id, 'AlreadySet');
        Test.stopTest();

        QuoteLineItem result = [SELECT ConstraintEngineNodeStatus__c FROM QuoteLineItem WHERE QuoteId=:q.Id LIMIT 1];
        System.assertEquals('AlreadySet', result.ConstraintEngineNodeStatus__c);
    }

    /**
     * QuoteAction exists but SourceAssetId is null → filtered by
     * WHERE SourceAssetId != null → quoteActionToAssetId empty →
     * nothing stamped.
     */
    @IsTest
    static void trigger_quoteActionNoSourceAsset_noStatusSet() {
        Account acc = insertAccount();
        Quote   q   = insertQuote(acc.Id);
        PricebookEntry pbe = insertPBE();
        QuoteAction qa = insertQuoteAction(q.Id, null);

        Test.startTest();
        insert buildQLI(q.Id, pbe.Id, qa.Id, null);
        Test.stopTest();

        QuoteLineItem result = [SELECT ConstraintEngineNodeStatus__c FROM QuoteLineItem WHERE QuoteId=:q.Id LIMIT 1];
        System.assertEquals(null, result.ConstraintEngineNodeStatus__c);
    }

    /**
     * QuoteAction has SourceAssetId but no AssetAction records exist →
     * SOQL returns empty list → buildLatestAssetActionsMap receives empty
     * input → assetIdToStatus is empty → nothing stamped.
     */
    @IsTest
    static void trigger_quoteActionWithSourceAsset_noAssetActions_noStatusSet() {
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);
        Quote   q     = insertQuote(acc.Id);
        PricebookEntry pbe = insertPBE();
        QuoteAction qa = insertQuoteAction(q.Id, asset.Id);

        Test.startTest();
        insert buildQLI(q.Id, pbe.Id, qa.Id, null);
        Test.stopTest();

        QuoteLineItem result = [SELECT ConstraintEngineNodeStatus__c FROM QuoteLineItem WHERE QuoteId=:q.Id LIMIT 1];
        System.assertEquals(null, result.ConstraintEngineNodeStatus__c);
    }

    /**
     * Bulk insert: one QLI with QuoteActionId (enters the processing path)
     * and one without (stays null). Exercises the second for-loop's FALSE
     * branch (null QuoteActionId inside the active block).
     */
    @IsTest
    static void trigger_bulkInsert_mixedQLIs_processedCorrectly() {
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);
        Quote   q     = insertQuote(acc.Id);
        PricebookEntry pbe = insertPBE();
        QuoteAction qa = insertQuoteAction(q.Id, asset.Id);

        List<QuoteLineItem> qlis = new List<QuoteLineItem>{
            buildQLI(q.Id, pbe.Id, qa.Id, null),  // enters block, assetId found but no AssetActions → null
            buildQLI(q.Id, pbe.Id, null,  null)   // null QuoteActionId → skipped in second loop
        };

        Test.startTest();
        insert qlis;
        Test.stopTest();

        for (QuoteLineItem r : [SELECT ConstraintEngineNodeStatus__c FROM QuoteLineItem WHERE QuoteId=:q.Id]) {
            System.assertEquals(null, r.ConstraintEngineNodeStatus__c);
        }
    }

    // =========================================================
    // collectQuoteActionIds — pure logic
    // =========================================================

    @IsTest
    static void collectQuoteActionIds_nullQuoteActionId_notCollected() {
        QuoteLineItem qli = new QuoteLineItem();
        Set<Id> result = QuoteItemTriggerHandler.collectQuoteActionIds(new List<QuoteLineItem>{ qli });
        System.assertEquals(true, result.isEmpty());
    }

    @IsTest
    static void collectQuoteActionIds_preSetStatus_notCollected() {
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);
        Quote   q     = insertQuote(acc.Id);
        QuoteAction qa = insertQuoteAction(q.Id, asset.Id);

        QuoteLineItem qli = new QuoteLineItem(
            QuoteActionId               = qa.Id,
            ConstraintEngineNodeStatus__c = 'SomeStatus'
        );
        Set<Id> result = QuoteItemTriggerHandler.collectQuoteActionIds(new List<QuoteLineItem>{ qli });
        System.assertEquals(true, result.isEmpty());
    }

    @IsTest
    static void collectQuoteActionIds_validQuoteActionId_collected() {
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);
        Quote   q     = insertQuote(acc.Id);
        QuoteAction qa = insertQuoteAction(q.Id, asset.Id);

        QuoteLineItem qli = new QuoteLineItem(QuoteActionId = qa.Id);
        Set<Id> result = QuoteItemTriggerHandler.collectQuoteActionIds(new List<QuoteLineItem>{ qli });
        System.assertEquals(1, result.size());
        System.assertEquals(true, result.contains(qa.Id));
    }

    // =========================================================
    // queryQuoteActionToAsset — SOQL wrapper
    // =========================================================

    @IsTest
    static void queryQuoteActionToAsset_quoteActionWithSourceAsset_returned() {
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);
        Quote   q     = insertQuote(acc.Id);
        QuoteAction qa = insertQuoteAction(q.Id, asset.Id);

        Map<Id, Id> result = QuoteItemTriggerHandler.queryQuoteActionToAsset(new Set<Id>{ qa.Id });
        System.assertEquals(1, result.size());
        System.assertEquals(asset.Id, result.get(qa.Id));
    }

    @IsTest
    static void queryQuoteActionToAsset_quoteActionNoSourceAsset_notReturned() {
        Account acc = insertAccount();
        Quote   q   = insertQuote(acc.Id);
        QuoteAction qa = insertQuoteAction(q.Id, null);

        Map<Id, Id> result = QuoteItemTriggerHandler.queryQuoteActionToAsset(new Set<Id>{ qa.Id });
        System.assertEquals(true, result.isEmpty());
    }

    // =========================================================
    // buildLatestAssetActionsMap — pure logic
    // =========================================================

    @IsTest
    static void buildLatestAssetActionsMap_emptyList_returnsEmptyMap() {
        Map<Id, AssetAction> result =
            QuoteItemTriggerHandler.buildLatestAssetActionsMap(new List<AssetAction>());
        System.assertEquals(true, result.isEmpty());
    }

    @IsTest
    static void buildLatestAssetActionsMap_singleAction_returnsIt() {
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);

        // In-memory AssetAction — no DML (AssetAction INSERT not allowed in this org)
        AssetAction aa = new AssetAction(AssetId = asset.Id, ActionDate = Date.today());

        Map<Id, AssetAction> result =
            QuoteItemTriggerHandler.buildLatestAssetActionsMap(new List<AssetAction>{ aa });

        System.assertEquals(1, result.size());
        System.assertEquals(Date.today(), result.get(asset.Id).ActionDate);
    }

    @IsTest
    static void buildLatestAssetActionsMap_twoActionsForSameAsset_latestDateWins() {
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);

        AssetAction older = new AssetAction(AssetId = asset.Id, ActionDate = Date.today().addDays(-5));
        AssetAction newer = new AssetAction(AssetId = asset.Id, ActionDate = Date.today());

        Map<Id, AssetAction> result =
            QuoteItemTriggerHandler.buildLatestAssetActionsMap(
                new List<AssetAction>{ older, newer }
            );

        System.assertEquals(1, result.size());
        System.assertEquals(Date.today(), result.get(asset.Id).ActionDate);
    }

    @IsTest
    static void buildLatestAssetActionsMap_newerProcessedFirst_olderSkipped() {
        // When newer is first in the list, second (older) hits the FALSE branch
        // of (existing == null || actionDate > existing.ActionDate)
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);

        AssetAction newer = new AssetAction(AssetId = asset.Id, ActionDate = Date.today());
        AssetAction older = new AssetAction(AssetId = asset.Id, ActionDate = Date.today().addDays(-3));

        Map<Id, AssetAction> result =
            QuoteItemTriggerHandler.buildLatestAssetActionsMap(
                new List<AssetAction>{ newer, older }
            );

        System.assertEquals(1, result.size());
        System.assertEquals(Date.today(), result.get(asset.Id).ActionDate);
    }

    // =========================================================
    // buildActionIdToAssetIdMap — pure logic
    // =========================================================

    @IsTest
    static void buildActionIdToAssetIdMap_emptyMap_returnsEmptyMap() {
        Map<Id, Id> result =
            QuoteItemTriggerHandler.buildActionIdToAssetIdMap(new Map<Id, AssetAction>());
        System.assertEquals(true, result.isEmpty());
    }

    @IsTest
    static void buildActionIdToAssetIdMap_singleEntry_mapsCorrectly() {
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);

        // Use acc.Id as a stand-in fake AssetAction Id (any 18-char Salesforce Id works
        // for in-memory sObject construction — type is only enforced at DML time)
        Id fakeAAId = acc.Id;

        AssetAction aa = fakeAssetAction(fakeAAId, asset.Id, Date.today());

        Map<Id, AssetAction> input = new Map<Id, AssetAction>{ asset.Id => aa };
        Map<Id, Id> result = QuoteItemTriggerHandler.buildActionIdToAssetIdMap(input);

        System.assertEquals(1, result.size());
        System.assertEquals(asset.Id, result.get(fakeAAId));
    }

    // =========================================================
    // buildAssetIdToStatusMap — pure logic
    // =========================================================

    @IsTest
    static void buildAssetIdToStatusMap_emptyInputs_returnsEmptyMap() {
        Map<Id, String> result = QuoteItemTriggerHandler.buildAssetIdToStatusMap(
            new List<AssetActionSource>(),
            new Map<Id, Id>()
        );
        System.assertEquals(true, result.isEmpty());
    }

    @IsTest
    static void buildAssetIdToStatusMap_validStatus_mapped() {
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);
        Id fakeAAId   = acc.Id;  // acc.Id is a valid 18-char Id; no DML insert needed

        AssetActionSource src = new AssetActionSource(
            AssetActionId               = fakeAAId,
            ConstraintEngineNodeStatus__c = 'Active'
        );
        Map<Id, Id> actionToAsset = new Map<Id, Id>{ fakeAAId => asset.Id };

        Map<Id, String> result = QuoteItemTriggerHandler.buildAssetIdToStatusMap(
            new List<AssetActionSource>{ src },
            actionToAsset
        );

        System.assertEquals('Active', result.get(asset.Id));
    }

    @IsTest
    static void buildAssetIdToStatusMap_nullStatus_notMapped() {
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);
        Id fakeAAId   = acc.Id;

        AssetActionSource src = new AssetActionSource(
            AssetActionId               = fakeAAId,
            ConstraintEngineNodeStatus__c = null
        );
        Map<Id, Id> actionToAsset = new Map<Id, Id>{ fakeAAId => asset.Id };

        Map<Id, String> result = QuoteItemTriggerHandler.buildAssetIdToStatusMap(
            new List<AssetActionSource>{ src },
            actionToAsset
        );

        System.assertEquals(true, result.isEmpty());
    }

    @IsTest
    static void buildAssetIdToStatusMap_unknownActionId_notMapped() {
        // AssetActionSource.AssetActionId not in actionToAsset → assetId is null → skipped
        Account acc    = insertAccount();
        Asset   asset  = insertAsset(acc.Id);
        Id fakeAAId    = acc.Id;   // source uses this Id
        Id differentId = asset.Id; // map uses a different Id — no match

        AssetActionSource src = new AssetActionSource(
            AssetActionId               = fakeAAId,
            ConstraintEngineNodeStatus__c = 'Status'
        );
        // Map has differentId, source has fakeAAId — no match
        Map<Id, Id> actionToAsset = new Map<Id, Id>{ differentId => asset.Id };

        Map<Id, String> result = QuoteItemTriggerHandler.buildAssetIdToStatusMap(
            new List<AssetActionSource>{ src },
            actionToAsset
        );

        System.assertEquals(true, result.isEmpty());
    }

    @IsTest
    static void buildAssetIdToStatusMap_duplicateAsset_firstNonNullWins() {
        // Two sources with same AssetId: first is added, second hits "already in map" branch
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);
        Id fakeAAId   = acc.Id;

        AssetActionSource src1 = new AssetActionSource(
            AssetActionId               = fakeAAId,
            ConstraintEngineNodeStatus__c = 'FirstStatus'
        );
        AssetActionSource src2 = new AssetActionSource(
            AssetActionId               = fakeAAId,
            ConstraintEngineNodeStatus__c = 'SecondStatus'
        );
        Map<Id, Id> actionToAsset = new Map<Id, Id>{ fakeAAId => asset.Id };

        Map<Id, String> result = QuoteItemTriggerHandler.buildAssetIdToStatusMap(
            new List<AssetActionSource>{ src1, src2 },
            actionToAsset
        );

        // First one processed wins; second hits containsKey=true → skipped
        System.assertEquals('FirstStatus', result.get(asset.Id));
        System.assertEquals(1, result.size());
    }

    // =========================================================
    // applyStatuses — pure logic
    // =========================================================

    @IsTest
    static void applyStatuses_quoteActionNotInMap_statusNotSet() {
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);
        Quote   q     = insertQuote(acc.Id);
        QuoteAction qa = insertQuoteAction(q.Id, asset.Id);

        QuoteLineItem qli = new QuoteLineItem(QuoteActionId = qa.Id);
        // quoteActionToAssetId doesn't contain qa.Id → assetId = null
        QuoteItemTriggerHandler.applyStatuses(
            new List<QuoteLineItem>{ qli },
            new Map<Id, Id>(),           // empty map → assetId = null
            new Map<Id, String>{ asset.Id => 'SomeStatus' }
        );

        System.assertEquals(null, qli.ConstraintEngineNodeStatus__c);
    }

    @IsTest
    static void applyStatuses_assetIdInMapButNoStatus_statusNotSet() {
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);
        Quote   q     = insertQuote(acc.Id);
        QuoteAction qa = insertQuoteAction(q.Id, asset.Id);

        QuoteLineItem qli = new QuoteLineItem(QuoteActionId = qa.Id);
        Map<Id, Id>     qaToAsset     = new Map<Id, Id>{ qa.Id => asset.Id };
        Map<Id, String> assetToStatus = new Map<Id, String>();  // empty → status = null

        QuoteItemTriggerHandler.applyStatuses(
            new List<QuoteLineItem>{ qli },
            qaToAsset,
            assetToStatus
        );

        System.assertEquals(null, qli.ConstraintEngineNodeStatus__c);
    }

    @IsTest
    static void applyStatuses_fullChain_statusStamped() {
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);
        Quote   q     = insertQuote(acc.Id);
        QuoteAction qa = insertQuoteAction(q.Id, asset.Id);

        QuoteLineItem qli = new QuoteLineItem(QuoteActionId = qa.Id);
        Map<Id, Id>     qaToAsset     = new Map<Id, Id>{ qa.Id => asset.Id };
        Map<Id, String> assetToStatus = new Map<Id, String>{ asset.Id => 'Stamped' };

        QuoteItemTriggerHandler.applyStatuses(
            new List<QuoteLineItem>{ qli },
            qaToAsset,
            assetToStatus
        );

        System.assertEquals('Stamped', qli.ConstraintEngineNodeStatus__c);
    }

    @IsTest
    static void applyStatuses_preExistingStatus_notOverwritten() {
        Account acc   = insertAccount();
        Asset   asset = insertAsset(acc.Id);
        Quote   q     = insertQuote(acc.Id);
        QuoteAction qa = insertQuoteAction(q.Id, asset.Id);

        QuoteLineItem qli = new QuoteLineItem(
            QuoteActionId               = qa.Id,
            ConstraintEngineNodeStatus__c = 'Existing'
        );
        Map<Id, Id>     qaToAsset     = new Map<Id, Id>{ qa.Id => asset.Id };
        Map<Id, String> assetToStatus = new Map<Id, String>{ asset.Id => 'ShouldNotWin' };

        QuoteItemTriggerHandler.applyStatuses(
            new List<QuoteLineItem>{ qli },
            qaToAsset,
            assetToStatus
        );

        System.assertEquals('Existing', qli.ConstraintEngineNodeStatus__c);
    }

    @IsTest
    static void applyStatuses_nullQuoteActionId_skipped() {
        QuoteLineItem qli = new QuoteLineItem(); // QuoteActionId = null

        QuoteItemTriggerHandler.applyStatuses(
            new List<QuoteLineItem>{ qli },
            new Map<Id, Id>(),
            new Map<Id, String>()
        );

        System.assertEquals(null, qli.ConstraintEngineNodeStatus__c);
    }
}