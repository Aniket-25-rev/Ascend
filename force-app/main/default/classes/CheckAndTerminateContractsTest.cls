@IsTest
private class CheckAndTerminateContractsTest {

    // This org validates BillingState as a real two-letter state
    // abbreviation on Account, so test Accounts need one set or insert
    // fails with FIELD_CUSTOM_VALIDATION_EXCEPTION.
    private static Account newTestAccount() {
        return new Account(Name = 'Test Account', BillingState = 'CA', BillingCountry = 'USA');
    }

    // A Contract can't be inserted directly with Status = 'Activated'
    // (FAILED_ACTIVATION) — activation only works as an update after
    // insert, same as real usage.
    private static Contract newActivatedContract(Id accountId) {
        Contract con = new Contract(AccountId = accountId, Status = 'Draft');
        insert con;
        con.Status = 'Activated';
        update con;
        return con;
    }

    private static Asset insertAsset(Id accountId) {
        Asset a = new Asset(Name = 'TrigTest Asset', AccountId = accountId, Status = 'Purchased');
        insert a;
        return a;
    }

    // =========================================================
    // execute() PLUMBING
    // AssetContractRelationship rows are system-managed and can't be
    // created via DML in this org, so execute() can only be exercised
    // end-to-end against a Contract with no linked Assets — same
    // constraint documented in ContractNightlyRollupBatchTest.
    // =========================================================

    @IsTest
    static void execute_noContractIds_doesNothing() {
        CheckAndTerminateContracts.Request req = new CheckAndTerminateContracts.Request();
        req.contractIds = new List<String>();

        Test.startTest();
        CheckAndTerminateContracts.execute(new List<CheckAndTerminateContracts.Request>{ req });
        Test.stopTest();

        // No exception is the assertion — there's nothing to query or update.
    }

    @IsTest
    static void execute_contractWithNoLinkedAssets_leftUntouched() {
        Account  acc = newTestAccount();
        insert acc;
        Contract con = newActivatedContract(acc.Id);

        CheckAndTerminateContracts.Request req = new CheckAndTerminateContracts.Request();
        req.contractIds = new List<String>{ con.Id };

        Test.startTest();
        CheckAndTerminateContracts.execute(new List<CheckAndTerminateContracts.Request>{ req });
        Test.stopTest();

        Contract updated = [SELECT Status FROM Contract WHERE Id = :con.Id];
        System.assertEquals('Activated', updated.Status,
            'A Contract with no linked Assets has nothing to terminate — Status must be left alone.');
    }

    // =========================================================
    // processContracts
    // Exercises the real Asset/AssetAction SOQL against a hand-built
    // contractToAssetIds map (bypassing the AssetContractRelationship
    // query in execute(), which can't be populated in a test). A plain
    // test Asset always has CurrentMrr = null (system-calculated, only
    // ever set by the real Order-activation pipeline), so it's treated
    // as OneTime and never drives a real termination here — that
    // "all recurring Assets cancelled" branch is covered directly via
    // determineContractsToTerminate's own pure-logic tests instead.
    // =========================================================

    @IsTest
    static void processContracts_emptyMap_doesNothing() {
        Test.startTest();
        CheckAndTerminateContracts.processContracts(new Map<Id, Set<Id>>());
        Test.stopTest();
    }

    @IsTest
    static void processContracts_withRealAssetAndContract_runsWithoutError() {
        Account  acc   = newTestAccount();
        insert acc;
        Contract con   = newActivatedContract(acc.Id);
        Asset    asset = insertAsset(acc.Id);

        Map<Id, Set<Id>> contractToAssetIds = new Map<Id, Set<Id>>{
            con.Id => new Set<Id>{ asset.Id }
        };

        Test.startTest();
        CheckAndTerminateContracts.processContracts(contractToAssetIds);
        Test.stopTest();

        Contract updated = [SELECT Status FROM Contract WHERE Id = :con.Id];
        System.assertEquals('Activated', updated.Status,
            'A plain test Asset has no CurrentMrr — it is treated as OneTime and never qualifies the Contract for termination.');
    }

    // =========================================================
    // terminateQualifyingContracts
    // =========================================================

    @IsTest
    static void terminateQualifyingContracts_emptySet_doesNothing() {
        Test.startTest();
        CheckAndTerminateContracts.terminateQualifyingContracts(new Set<Id>());
        Test.stopTest();
    }

    @IsTest
    static void terminateQualifyingContracts_activatedContract_isTerminated() {
        Account  acc = newTestAccount();
        insert acc;
        Contract con = newActivatedContract(acc.Id);

        Test.startTest();
        CheckAndTerminateContracts.terminateQualifyingContracts(new Set<Id>{ con.Id });
        Test.stopTest();

        Contract updated = [SELECT Status FROM Contract WHERE Id = :con.Id];
        System.assertEquals('Contract Terminated', updated.Status);
    }

    @IsTest
    static void terminateQualifyingContracts_draftContract_isNotTerminated() {
        Account  acc = newTestAccount();
        insert acc;
        Contract con = new Contract(AccountId = acc.Id, Status = 'Draft');
        insert con;

        Test.startTest();
        CheckAndTerminateContracts.terminateQualifyingContracts(new Set<Id>{ con.Id });
        Test.stopTest();

        Contract updated = [SELECT Status FROM Contract WHERE Id = :con.Id];
        System.assertEquals('Draft', updated.Status,
            'Only Activated Contracts are eligible for termination.');
    }

    // =========================================================
    // buildLatestCategoryByAssetId (pure logic)
    // =========================================================

    @IsTest
    static void buildLatestCategoryByAssetId_singleAction_returnsItsCategory() {
        Account acc   = newTestAccount();
        insert acc;
        Asset   asset = insertAsset(acc.Id);

        // In-memory AssetAction — no DML (AssetAction INSERT not allowed in this org)
        AssetAction aa = new AssetAction(
            AssetId = asset.Id, ActionDate = Date.today(), CategoryEnum = 'Cancellations'
        );

        Map<Id, String> result =
            CheckAndTerminateContracts.buildLatestCategoryByAssetId(new List<AssetAction>{ aa });

        System.assertEquals(1, result.size());
        System.assertEquals('Cancellations', result.get(asset.Id));
    }

    @IsTest
    static void buildLatestCategoryByAssetId_laterActionDateWins_regardlessOfListOrder() {
        Account acc   = newTestAccount();
        insert acc;
        Asset   asset = insertAsset(acc.Id);

        AssetAction older = new AssetAction(
            AssetId = asset.Id, ActionDate = Date.today().addDays(-5), CategoryEnum = 'Upsells'
        );
        AssetAction newer = new AssetAction(
            AssetId = asset.Id, ActionDate = Date.today(), CategoryEnum = 'Cancellations'
        );

        Map<Id, String> result = CheckAndTerminateContracts.buildLatestCategoryByAssetId(
            new List<AssetAction>{ older, newer }
        );
        System.assertEquals('Cancellations', result.get(asset.Id),
            'The later ActionDate should win regardless of list order.');

        Map<Id, String> resultReversed = CheckAndTerminateContracts.buildLatestCategoryByAssetId(
            new List<AssetAction>{ newer, older }
        );
        System.assertEquals('Cancellations', resultReversed.get(asset.Id),
            'Order in the list must not change which action is treated as latest.');
    }

    // =========================================================
    // determineContractsToTerminate (pure logic)
    // =========================================================

    @IsTest
    static void determineContractsToTerminate_allRecurringAssetsCancelled_includesContract() {
        Id contractId = fakeId(Contract.SObjectType);
        Id assetId1   = fakeId(Asset.SObjectType);
        Id assetId2   = fakeId(Asset.SObjectType);

        Map<Id, Set<Id>> contractToAssetIds = new Map<Id, Set<Id>>{
            contractId => new Set<Id>{ assetId1, assetId2 }
        };
        Map<Id, Decimal> mrrByAssetId = new Map<Id, Decimal>{
            assetId1 => 100, assetId2 => 50
        };
        Map<Id, String> latestCategoryByAssetId = new Map<Id, String>{
            assetId1 => 'Cancellations', assetId2 => 'Cancellations'
        };

        Set<Id> result = CheckAndTerminateContracts.determineContractsToTerminate(
            contractToAssetIds, mrrByAssetId, latestCategoryByAssetId
        );
        System.assert(result.contains(contractId),
            'Every recurring Asset is cancelled — the Contract should qualify for termination.');
    }

    @IsTest
    static void determineContractsToTerminate_oneRecurringAssetStillActive_excludesContract() {
        Id contractId = fakeId(Contract.SObjectType);
        Id assetId1   = fakeId(Asset.SObjectType);
        Id assetId2   = fakeId(Asset.SObjectType);

        Map<Id, Set<Id>> contractToAssetIds = new Map<Id, Set<Id>>{
            contractId => new Set<Id>{ assetId1, assetId2 }
        };
        Map<Id, Decimal> mrrByAssetId = new Map<Id, Decimal>{
            assetId1 => 100, assetId2 => 50
        };
        Map<Id, String> latestCategoryByAssetId = new Map<Id, String>{
            assetId1 => 'Cancellations', assetId2 => 'Upsells'
        };

        Set<Id> result = CheckAndTerminateContracts.determineContractsToTerminate(
            contractToAssetIds, mrrByAssetId, latestCategoryByAssetId
        );
        System.assert(!result.contains(contractId),
            'One recurring Asset is still active — the Contract must not be terminated.');
    }

    @IsTest
    static void determineContractsToTerminate_onlyOneTimeAssets_excludesContract() {
        Id contractId = fakeId(Contract.SObjectType);
        Id assetId1   = fakeId(Asset.SObjectType);

        Map<Id, Set<Id>> contractToAssetIds = new Map<Id, Set<Id>>{
            contractId => new Set<Id>{ assetId1 }
        };
        Map<Id, Decimal> mrrByAssetId = new Map<Id, Decimal>{ assetId1 => 0 };
        Map<Id, String>  latestCategoryByAssetId = new Map<Id, String>();

        Set<Id> result = CheckAndTerminateContracts.determineContractsToTerminate(
            contractToAssetIds, mrrByAssetId, latestCategoryByAssetId
        );
        System.assert(!result.contains(contractId),
            'A Contract with only OneTime (CurrentMrr = 0) Assets has no recurring Assets to check — must not terminate.');
    }

    @IsTest
    static void determineContractsToTerminate_assetMissingFromMrrMap_isSkipped() {
        Id contractId = fakeId(Contract.SObjectType);
        Id assetId1   = fakeId(Asset.SObjectType); // not present in mrrByAssetId

        Map<Id, Set<Id>> contractToAssetIds = new Map<Id, Set<Id>>{
            contractId => new Set<Id>{ assetId1 }
        };
        Map<Id, Decimal> mrrByAssetId = new Map<Id, Decimal>();
        Map<Id, String>  latestCategoryByAssetId = new Map<Id, String>{ assetId1 => 'Cancellations' };

        Set<Id> result = CheckAndTerminateContracts.determineContractsToTerminate(
            contractToAssetIds, mrrByAssetId, latestCategoryByAssetId
        );
        System.assert(!result.contains(contractId),
            'An Asset absent from the Asset query results contributes no recurring count — must not terminate.');
    }

    @IsTest
    static void determineContractsToTerminate_mixedContracts_onlyQualifyingOneIncluded() {
        Id qualifyingContractId    = fakeId(Contract.SObjectType);
        Id nonQualifyingContractId = fakeId(Contract.SObjectType);
        Id assetId1 = fakeId(Asset.SObjectType);
        Id assetId2 = fakeId(Asset.SObjectType);

        Map<Id, Set<Id>> contractToAssetIds = new Map<Id, Set<Id>>{
            qualifyingContractId    => new Set<Id>{ assetId1 },
            nonQualifyingContractId => new Set<Id>{ assetId2 }
        };
        Map<Id, Decimal> mrrByAssetId = new Map<Id, Decimal>{ assetId1 => 25, assetId2 => 25 };
        Map<Id, String> latestCategoryByAssetId = new Map<Id, String>{
            assetId1 => 'Cancellations', assetId2 => 'Downsells'
        };

        Set<Id> result = CheckAndTerminateContracts.determineContractsToTerminate(
            contractToAssetIds, mrrByAssetId, latestCategoryByAssetId
        );
        System.assertEquals(1, result.size());
        System.assert(result.contains(qualifyingContractId));
        System.assert(!result.contains(nonQualifyingContractId));
    }

    // A well-formed fake Id of the right sObject type works for in-memory map
    // keys — type is only enforced at DML time, and these pure-logic methods
    // never touch the database (mirrors the "fake Id" technique used in
    // QuoteItemTriggerTest). Zero-padding a small counter (rather than a
    // random number) avoids Id.valueOf's "Invalid id" exception, which
    // trailing-zero-heavy random digit strings hit unpredictably.
    private static Integer fakeIdCounter = 0;
    private static Id fakeId(Schema.SObjectType sObjType) {
        fakeIdCounter++;
        String keyPrefix = sObjType.getDescribe().getKeyPrefix();
        return Id.valueOf(keyPrefix + String.valueOf(fakeIdCounter).leftPad(12, '0'));
    }
}