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

    // A period with a blank Line_of_Business__c (older sales) must still land in
    // its product's Line of Business bucket; its own LOB wins when set.
    @IsTest
    static void lobMrrByContract_fallsBackToTheProductLineOfBusiness() {
        Id contractId = fakeId(Contract.SObjectType);
        Id assetA = fakeId(Asset.SObjectType);
        Id assetB = fakeId(Asset.SObjectType);

        Map<Id, Id> contractByAsset = new Map<Id, Id>{
            assetA => contractId, assetB => contractId
        };
        List<AssetStatePeriod> periods = new List<AssetStatePeriod>{
            withProductLob(statePeriod(assetA, 7116, null), 'Infrastructure'),
            withProductLob(statePeriod(assetB, 57.51, 'Service Desk'), 'Infrastructure')
        };

        Map<String, Decimal> buckets = ContractNightlyRollupBatch.lobMrrByContract(
            new Set<Id>{ contractId }, contractByAsset, periods
        ).get(contractId);

        System.assertEquals(7116, buckets.get('Infra'), 'Blank period LOB falls back to the product');
        System.assertEquals(57.51, buckets.get('Desk'), 'The period\'s own LOB wins over the product');
    }

    private static AssetStatePeriod withProductLob(AssetStatePeriod period, String productLob) {
        Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(period));
        raw.put('Asset', new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'Asset' },
            'Product2' => new Map<String, Object>{
                'attributes' => new Map<String, Object>{ 'type' => 'Product2' },
                'Service_Offering__c' => productLob
            }
        });
        return (AssetStatePeriod) JSON.deserialize(JSON.serialize(raw), AssetStatePeriod.class);
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

    // Same fabrication trick as statePeriod(), with the date window set —
    // StartDate/EndDate drive the selection this batch got wrong.
    private static AssetStatePeriod statePeriod(
        Id assetId, Decimal mrr, String lob, Datetime startDate, Datetime endDate
    ) {
        Map<String, Object> raw = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'AssetStatePeriod' },
            'AssetId' => assetId, 'Mrr' => mrr, 'Line_of_Business__c' => lob,
            'StartDate' => startDate, 'EndDate' => endDate
        };
        return (AssetStatePeriod) JSON.deserialize(JSON.serialize(raw), AssetStatePeriod.class);
    }

    // The regression this batch shipped without: an Order activated ahead of
    // its service start date has no period covering today, and used to
    // contribute nothing — zeroing the Contract overnight.
    @IsTest
    static void chooseCoveringPeriods_usesFirstPeriodWhenServiceStartsInFuture() {
        Datetime now = Datetime.now();
        Id assetId = fakeId(Asset.SObjectType);
        List<AssetStatePeriod> periods = new List<AssetStatePeriod>{
            statePeriod(assetId, 500, 'Infrastructure', now.addDays(30), now.addDays(395))
        };

        List<AssetStatePeriod> chosen =
            ContractNightlyRollupBatch.chooseCoveringPeriods(periods, now);

        System.assertEquals(1, chosen.size(),
            'An Asset whose service has not started yet must still contribute a period.');
        System.assertEquals(500, chosen[0].Mrr,
            'It contributes its first period MRR, so the Contract keeps the value stamped at activation.');
    }

    @IsTest
    static void chooseCoveringPeriods_prefersThePeriodCoveringNowOverALaterOne() {
        Datetime now = Datetime.now();
        Id assetId = fakeId(Asset.SObjectType);
        List<AssetStatePeriod> periods = new List<AssetStatePeriod>{
            statePeriod(assetId, 100, 'Infrastructure', now.addDays(-60), now.addDays(-1)),
            statePeriod(assetId, 200, 'Infrastructure', now.addDays(-1), now.addDays(60)),
            statePeriod(assetId, 300, 'Infrastructure', now.addDays(61), now.addDays(400))
        };

        List<AssetStatePeriod> chosen =
            ContractNightlyRollupBatch.chooseCoveringPeriods(periods, now);

        System.assertEquals(1, chosen.size(), 'Exactly one period per Asset reaches the rollup.');
        System.assertEquals(200, chosen[0].Mrr,
            'A started Asset still uses the period covering now — unchanged behaviour, e.g. a ramp step.');
    }

    @IsTest
    static void chooseCoveringPeriods_keepsOnePeriodPerAssetAcrossAssets() {
        Datetime now = Datetime.now();
        Id started = fakeId(Asset.SObjectType);
        Id notYetStarted = fakeId(Asset.SObjectType);
        List<AssetStatePeriod> periods = new List<AssetStatePeriod>{
            statePeriod(started, 150, 'Infrastructure', now.addDays(-10), now.addDays(355)),
            statePeriod(notYetStarted, 250, 'Service Desk', now.addDays(45), now.addDays(410))
        };

        Map<Id, Id> contractByAsset = new Map<Id, Id>();
        Id contractId = fakeId(Contract.SObjectType);
        contractByAsset.put(started, contractId);
        contractByAsset.put(notYetStarted, contractId);

        Map<Id, Decimal> totals = ContractNightlyRollupBatch.mrrByContract(
            new Set<Id>{ contractId },
            contractByAsset,
            ContractNightlyRollupBatch.chooseCoveringPeriods(periods, now)
        );

        System.assertEquals(400, totals.get(contractId),
            'A Contract mixing in-service and not-yet-started Assets rolls up both, not just the live one.');
    }

    @IsTest
    static void execute_skipsContractsWhoseRollupDidNotChange() {
        Account acc = newTestAccount();
        insert acc;

        Contract con = new Contract(AccountId = acc.Id, Status = 'Draft');
        insert con;
        con.Status = 'Activated';
        update con;

        Test.startTest();
        ContractNightlyRollupBatch.recalculateContracts(new Set<Id>{ con.Id });
        System.assertEquals(1, ContractNightlyRollupBatch.lastUpdateCount,
            'First run: the blank rollup fields are written as 0, so the Contract is saved.');

        ContractNightlyRollupBatch.recalculateContracts(new Set<Id>{ con.Id });
        System.assertEquals(0, ContractNightlyRollupBatch.lastUpdateCount,
            'Second run: nothing changed, so the Contract must not be saved again '
            + '(each save re-flags it for the ServiceNow integration).');
        Test.stopTest();
    }

    @IsTest
    static void hasRollupChanged_detectsChangedBlankAndUnchangedValues() {
        List<String> fields = ContractNightlyRollupBatch.rollupFieldNames();
        Contract current = new Contract(Current_MRR__c = 100, Current_TCV__c = 1200);
        Contract target = new Contract(Current_MRR__c = 100.00, Current_TCV__c = 1200);
        for (String suffix : FinancialMetricsService.LOB_TO_SUFFIX.values()) {
            current.put('Current_MRR_' + suffix + '__c', 0);
            target.put('Current_MRR_' + suffix + '__c', 0);
        }
        System.assertEquals(false, ContractNightlyRollupBatch.hasRollupChanged(current, target, fields),
            'Same values (100 vs 100.00) are not a change.');

        target.Current_TCV__c = 1300;
        System.assertEquals(true, ContractNightlyRollupBatch.hasRollupChanged(current, target, fields),
            'A different TCV is a change.');

        target.Current_TCV__c = 1200;
        current.Current_MRR__c = null;
        target.Current_MRR__c = 0;
        System.assertEquals(true, ContractNightlyRollupBatch.hasRollupChanged(current, target, fields),
            'Blank -> 0 is a change, so never-rolled-up Contracts still get their first values.');

        System.assertEquals(true, ContractNightlyRollupBatch.hasRollupChanged(null, target, fields),
            'A Contract that could not be read is saved rather than skipped.');
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