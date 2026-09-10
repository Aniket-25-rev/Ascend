@IsTest
private class ContractNightlyRollupBatchTest {

    // This org validates BillingState as a real two-letter state
    // abbreviation on Account, so test Accounts need one set or insert
    // fails with FIELD_CUSTOM_VALIDATION_EXCEPTION.
    private static Account newTestAccount() {
        return new Account(Name = 'Test Account', BillingState = 'CA', BillingCountry = 'USA');
    }

    // Asset.HasLifecycleManagement, LifecycleStartDate, and LifecycleEndDate
    // are all not createable — a lifecycle-managed Asset only comes into
    // existence through the platform's real Order-activation pipeline, not
    // plain DML. A unit test can't construct one, so these tests only
    // confirm the batch/schedulable plumbing runs correctly against
    // Contracts with no (or non-lifecycle-managed) linked Assets. The
    // active-vs-expired filter's actual date logic should be verified
    // against real sandbox data instead of a synthetic test.

    @IsTest
    static void execute_updatesContractToZeroWhenNoAssetsLinked() {
        Account acc = newTestAccount();
        insert acc;

        // A Contract can't be inserted directly with Status = 'Activated'
        // (FAILED_ACTIVATION) — activation only works as an update after
        // insert, same as real usage.
        Contract con = new Contract(AccountId = acc.Id, Status = 'Draft');
        insert con;
        con.Status = 'Activated';
        update con;

        Test.startTest();
        Database.executeBatch(new ContractNightlyRollupBatch(), 200);
        Test.stopTest();

        Contract updated = [SELECT Current_MRR__c, Current_TCV__c FROM Contract WHERE Id = :con.Id];
        System.assertEquals(0, updated.Current_MRR__c,
            'An Activated Contract with no linked Assets should be rolled up to 0, not left null.');
        System.assertEquals(0, updated.Current_TCV__c,
            'Current_TCV__c should also be rolled up to 0 for a Contract with no linked Assets.');
    }

    @IsTest
    static void execute_skipsNonActivatedContracts() {
        Account acc = newTestAccount();
        insert acc;

        Contract con = new Contract(AccountId = acc.Id, Status = 'Draft');
        insert con;

        Test.startTest();
        Database.executeBatch(new ContractNightlyRollupBatch(), 200);
        Test.stopTest();

        Contract updated = [SELECT Current_MRR__c, Current_TCV__c FROM Contract WHERE Id = :con.Id];
        System.assertEquals(null, updated.Current_MRR__c,
            'A Draft Contract is never in scope for the batch — it should be left untouched, not rolled up to 0.');
        System.assertEquals(null, updated.Current_TCV__c,
            'Same for Current_TCV__c — a Draft Contract should never be touched by this batch.');
    }

    @IsTest
    static void queryActiveAssetRelationships_runsWithoutError() {
        Account acc = newTestAccount();
        insert acc;

        Contract con = new Contract(AccountId = acc.Id, Status = 'Draft');
        insert con;

        Test.startTest();
        List<AssetContractRelationship> result =
            ContractNightlyRollupBatch.queryActiveAssetRelationships(new Set<Id>{ con.Id }, Date.today());
        Test.stopTest();

        System.assertEquals(0, result.size(),
            'No Assets are linked to this Contract, so the query should return no rows.');
    }

    @IsTest
    static void lobMrrByContract_queriesStatePeriodsForLinkedAssets() {
        Account acc = newTestAccount();
        insert acc;

        Contract con = new Contract(AccountId = acc.Id, Status = 'Draft');
        insert con;

        Map<Id, Id> contractIdByAssetId = new Map<Id, Id>{
            '02i000000000001AAA' => con.Id
        };

        Test.startTest();
        Map<Id, Map<String, Decimal>> result = ContractNightlyRollupBatch.lobMrrByContract(
            new Set<Id>{ con.Id }, contractIdByAssetId, System.now()
        );
        Test.stopTest();

        for (String suffix : FinancialMetricsService.LOB_TO_SUFFIX.values()) {
            System.assertEquals(0, result.get(con.Id).get(suffix),
                'An Asset with no state periods contributes nothing: ' + suffix);
        }
    }

    @IsTest
    static void execute_rollsUpEveryFieldWhenCalledDirectly() {
        Account acc = newTestAccount();
        insert acc;

        Contract con = new Contract(AccountId = acc.Id, Status = 'Draft');
        insert con;
        con.Status = 'Activated';
        update con;

        Test.startTest();
        new ContractNightlyRollupBatch().execute(null, new List<Contract>{ new Contract(Id = con.Id) });
        Test.stopTest();

        Contract updated = [
            SELECT Current_MRR__c, Current_TCV__c, Current_MRR_Cyber__c, Current_MRR_Desk__c,
                   Current_MRR_Infra__c, Current_MRR_Private_Cloud__c, Current_MRR_VOIP__c
            FROM Contract WHERE Id = :con.Id
        ];
        System.assertEquals(0, updated.Current_MRR__c, 'Current MRR rolls up to 0 with no Assets.');
        System.assertEquals(0, updated.Current_TCV__c, 'TCV rolls up to 0 with no Assets.');
        for (String suffix : FinancialMetricsService.LOB_TO_SUFFIX.values()) {
            System.assertEquals(0, (Decimal) updated.get('Current_MRR_' + suffix + '__c'),
                'Every LOB bucket rolls up to 0, not left null: ' + suffix);
        }
    }

    @IsTest
    static void lobMrrByContract_returnsZeroedBucketsWhenNoAssets() {
        Account acc = newTestAccount();
        insert acc;

        Contract con = new Contract(AccountId = acc.Id, Status = 'Draft');
        insert con;

        Test.startTest();
        Map<Id, Map<String, Decimal>> result = ContractNightlyRollupBatch.lobMrrByContract(
            new Set<Id>{ con.Id }, new Map<Id, Id>(), System.now()
        );
        Test.stopTest();

        System.assertEquals(1, result.size(), 'Every in-scope Contract gets an entry.');
        Map<String, Decimal> buckets = result.get(con.Id);
        System.assertEquals(
            FinancialMetricsService.LOB_TO_SUFFIX.values().size(), buckets.size(),
            'One bucket per mapped line of business.'
        );
        for (String suffix : FinancialMetricsService.LOB_TO_SUFFIX.values()) {
            System.assertEquals(0, buckets.get(suffix), 'Bucket starts at zero: ' + suffix);
        }
    }

    private static Integer idSeed = 1;

    private static Id fakeId(Schema.SObjectType sot) {
        String suffix = String.valueOf(idSeed++);
        return Id.valueOf(
            sot.getDescribe().getKeyPrefix() + '0'.repeat(12 - suffix.length()) + suffix
        );
    }

    private static AssetStatePeriod statePeriod(Id assetId, Decimal mrr, String lob) {
        Map<String, Object> raw = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'AssetStatePeriod' },
            'AssetId' => assetId, 'Mrr' => mrr, 'Line_of_Business__c' => lob
        };
        return (AssetStatePeriod) JSON.deserialize(JSON.serialize(raw), AssetStatePeriod.class);
    }

    @IsTest
    static void mrrByContract_sumsExtendedStatePeriodMrrNotPerUnitAssetMrr() {
        Id contractId = fakeId(Contract.SObjectType);
        Id assetA = fakeId(Asset.SObjectType);
        Id assetB = fakeId(Asset.SObjectType);

        Map<Id, Id> contractByAsset = new Map<Id, Id>{
            assetA => contractId, assetB => contractId
        };
        List<AssetStatePeriod> periods = new List<AssetStatePeriod>{
            statePeriod(assetA, 570, 'Infrastructure'),
            statePeriod(assetB, 268, 'Service Desk')
        };

        Map<Id, Decimal> totals = ContractNightlyRollupBatch.mrrByContract(
            new Set<Id>{ contractId }, contractByAsset, periods
        );

        System.assertEquals(838, totals.get(contractId),
            'The total must be the sum of extended AssetStatePeriod.Mrr, not per-unit Asset.CurrentMrr.');
    }

    @IsTest
    static void mrrByContract_totalAgreesWithTheSumOfItsOwnLobBuckets() {
        Id contractId = fakeId(Contract.SObjectType);
        Id assetA = fakeId(Asset.SObjectType);
        Id assetB = fakeId(Asset.SObjectType);

        Map<Id, Id> contractByAsset = new Map<Id, Id>{
            assetA => contractId, assetB => contractId
        };
        List<AssetStatePeriod> periods = new List<AssetStatePeriod>{
            statePeriod(assetA, 570, 'Infrastructure'),
            statePeriod(assetB, 268, 'Service Desk')
        };

        Decimal total = ContractNightlyRollupBatch.mrrByContract(
            new Set<Id>{ contractId }, contractByAsset, periods
        ).get(contractId);

        Map<String, Decimal> buckets = ContractNightlyRollupBatch.lobMrrByContract(
            new Set<Id>{ contractId }, contractByAsset, periods
        ).get(contractId);

        Decimal bucketSum = 0;
        for (Decimal amount : buckets.values()) {
            bucketSum += amount;
        }
        System.assertEquals(total, bucketSum,
            'Total and per-LOB buckets now read the same source, so they can never disagree.');
    }

    @IsTest
    static void mrrByContract_ignoresPeriodsForAssetsOutsideTheScope() {
        Id contractId = fakeId(Contract.SObjectType);
        Id scoped = fakeId(Asset.SObjectType);
        Id stranger = fakeId(Asset.SObjectType);

        Map<Id, Id> contractByAsset = new Map<Id, Id>{ scoped => contractId };
        List<AssetStatePeriod> periods = new List<AssetStatePeriod>{
            statePeriod(scoped, 100, 'Infrastructure'),
            statePeriod(stranger, 999, 'Infrastructure')
        };

        Map<Id, Decimal> totals = ContractNightlyRollupBatch.mrrByContract(
            new Set<Id>{ contractId }, contractByAsset, periods
        );

        System.assertEquals(100, totals.get(contractId),
            'A period whose Asset is not in the scope map must not reach the total.');
    }

    @IsTest
    static void schedule_enqueuesBatch() {
        Test.startTest();
        System.schedule(
            'ContractNightlyRollupBatchTest Job',
            '0 0 2 * * ?',
            new ContractNightlyRollupBatch()
        );
        Test.stopTest();
    }
}