@IsTest
private class JTLPreHookTest {

    // ─────────────────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────────────────

    private static Map<String, Object> tv(Object value) {
        return new Map<String, Object>{ 'tagValue' => value };
    }

    private static Map<String, Object> buildNode(List<Object> dataPath, Map<String, Object> tagValues) {
        return new Map<String, Object>{ 'dataPath' => dataPath, 'tagValue' => tagValues };
    }

    private static List<Object> path(Object lineItemId) {
        return new List<Object>{ 'STI-001', 'STI-ITEM-001', lineItemId };
    }

    private static Map<String, Object> lineTags(Boolean isDeleted, String sellingModel, String segmentId) {
        return new Map<String, Object>{
            'IsDeleted'             => tv(isDeleted),
            'SellingModelType'      => tv(sellingModel),
            'ItemSegmentIdentifier' => tv(segmentId),
            'ProductCode'           => tv('PROD-001')
        };
    }

    private static Map<String, Object> lineTagsWithSku(Boolean isDeleted, String sellingModel, String segmentId, String sku) {
        Map<String, Object> tags = lineTags(isDeleted, sellingModel, segmentId);
        tags.put('ItemStockKeepingUnit', tv(sku));
        return tags;
    }

    private static RevSignaling.TransactionRequest makeReq(String ctxId) {
        String payload = ctxId == null
            ? '{"ctxInstanceId":null}'
            : '{"ctxInstanceId":"' + ctxId + '"}';
        return (RevSignaling.TransactionRequest)
            JSON.deserialize(payload, RevSignaling.TransactionRequest.class);
    }

    private static Account makeAccount(String name) {
        return new Account(
            Name              = name,
            BillingStreet     = '123 Test St',
            BillingCity       = 'Austin',
            BillingState      = 'TX',
            BillingPostalCode = '78701',
            BillingCountry    = 'US'
        );
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 1 – execute()
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void execute_blankContextId_returnsSuccess() {
        System.Test.startTest();
        RevSignaling.TransactionResponse r = new JTLPreHook().execute(makeReq(''));
        System.Test.stopTest();
        System.assertEquals(RevSignaling.TransactionStatus.SUCCESS, r.status);
        System.assert(r.message.containsIgnoreCase('No contextId'), r.message);
    }

    @IsTest
    static void execute_nullContextId_returnsSuccess() {
        System.Test.startTest();
        RevSignaling.TransactionResponse r = new JTLPreHook().execute(makeReq(null));
        System.Test.stopTest();
        System.assertEquals(RevSignaling.TransactionStatus.SUCCESS, r.status);
    }

    @IsTest
    static void execute_fakeContextId_returnsSuccess() {
        // ctx.queryTags throws or returns nothing in test context → outer catch or no-active-lines → SUCCESS
        System.Test.startTest();
        RevSignaling.TransactionResponse r = new JTLPreHook().execute(makeReq('fake-ctx-99999'));
        System.Test.stopTest();
        System.assertEquals(RevSignaling.TransactionStatus.SUCCESS, r.status);
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 2 – countActiveLines()
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void countActiveLines_emptyList_returnsZero() {
        System.assertEquals(0, JTLPreHook.countActiveLines(new List<Object>()));
    }

    @IsTest
    static void countActiveLines_deletedFlagTrue_skips() {
        System.assertEquals(0,
            JTLPreHook.countActiveLines(new List<Object>{
                new Map<String, Object>{ 'deleted' => true }
            }));
    }

    @IsTest
    static void countActiveLines_isDeletedFlagTrue_skips() {
        System.assertEquals(0,
            JTLPreHook.countActiveLines(new List<Object>{
                new Map<String, Object>{ 'isDeleted' => true }
            }));
    }

    @IsTest
    static void countActiveLines_tagValueIsDeletedTrue_skips() {
        Map<String, Object> tvMap = new Map<String, Object>{ 'IsDeleted' => tv(true) };
        System.assertEquals(0,
            JTLPreHook.countActiveLines(new List<Object>{
                new Map<String, Object>{ 'tagValue' => tvMap }
            }));
    }

    @IsTest
    static void countActiveLines_tagValueDeletedTrue_skips() {
        Map<String, Object> tvMap = new Map<String, Object>{ 'Deleted' => tv(true) };
        System.assertEquals(0,
            JTLPreHook.countActiveLines(new List<Object>{
                new Map<String, Object>{ 'tagValue' => tvMap }
            }));
    }

    @IsTest
    static void countActiveLines_activeItem_counts() {
        System.assertEquals(1,
            JTLPreHook.countActiveLines(new List<Object>{
                new Map<String, Object>{ 'deleted' => false }
            }));
    }

    @IsTest
    static void countActiveLines_nonMapItem_skipped() {
        System.assertEquals(0,
            JTLPreHook.countActiveLines(new List<Object>{ 'not-a-map' }));
    }

    @IsTest
    static void countActiveLines_mixed_countsOnlyActive() {
        List<Object> items = new List<Object>{
            new Map<String, Object>{ 'deleted' => false },
            new Map<String, Object>{ 'deleted' => true  },
            new Map<String, Object>{ 'deleted' => false }
        };
        System.assertEquals(2, JTLPreHook.countActiveLines(items));
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 3 – buildLineUpdates()
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void buildLineUpdates_invalidPath_skipped() {
        Map<String, Object> node = new Map<String, Object>{
            'dataPath' => new List<Object>{ 'one' }, 'tagValue' => null };
        System.assertEquals(0,
            JTLPreHook.buildLineUpdates(
                new List<Object>{ node }, Date.today(), Date.today().addMonths(12), null, true,
                new Set<String>(), new Set<String>()).size());
    }

    @IsTest
    static void buildLineUpdates_deleted_skipped() {
        System.assertEquals(0,
            JTLPreHook.buildLineUpdates(
                new List<Object>{ buildNode(path('TEMP-D'), lineTags(true, 'TermBased', null)) },
                Date.today(), Date.today().addMonths(12), null, true,
                new Set<String>(), new Set<String>()).size());
    }

    @IsTest
    static void buildLineUpdates_rampSegment_skipped() {
        System.assertEquals(0,
            JTLPreHook.buildLineUpdates(
                new List<Object>{ buildNode(path('TEMP-R'), lineTags(false, 'TermBased', 'SEG-001')) },
                Date.today(), Date.today().addMonths(12), null, true,
                new Set<String>(), new Set<String>()).size());
    }

    @IsTest
    static void buildLineUpdates_onboardingFeeSku_gets1MonthTerm() {
        String sku    = '001-DESK-SVC-DESK-ONOB-001';
        Date start    = Date.newInstance(2025, 6, 1);
        Date expected = Date.newInstance(2025, 6, 30); // start + 1 month - 1 day
        List<Map<String, Object>> result = JTLPreHook.buildLineUpdates(
            new List<Object>{ buildNode(path('TEMP-OB'), lineTagsWithSku(false, 'OneTime', null, sku)) },
            start, null, null, true,
            new Set<String>(), new Set<String>());
        System.assertEquals(1, result.size());
        List<Object> attrs = (List<Object>) result.get(0).get('attributes');
        System.assertEquals(2, attrs.size(), 'Onboarding fee must have StartDate + EndDate');
        System.assertEquals(start,    ((Map<String, Object>) attrs.get(0)).get('attributeValue'));
        System.assertEquals(expected, ((Map<String, Object>) attrs.get(1)).get('attributeValue'));
    }

    @IsTest
    static void buildLineUpdates_onboardingFeeSku_midMonthStart_endDateIsStartPlus1MonthMinus1Day() {
        String sku    = '001-DESK-SVC-DESK-ONOB-001';
        Date start    = Date.newInstance(2026, 8, 10);   // Aug 10, 2026
        Date expected = Date.newInstance(2026, 9, 9);    // Sep 9, 2026 (Aug 10 + 1m - 1d)
        List<Map<String, Object>> result = JTLPreHook.buildLineUpdates(
            new List<Object>{ buildNode(path('TEMP-OB-MID'), lineTagsWithSku(false, 'OneTime', null, sku)) },
            start, null, null, true,
            new Set<String>(), new Set<String>());
        System.assertEquals(1, result.size());
        List<Object> attrs = (List<Object>) result.get(0).get('attributes');
        System.assertEquals(expected, ((Map<String, Object>) attrs.get(1)).get('attributeValue'));
    }

    @IsTest
    static void buildLineUpdates_onboardingFeeSku_allFourSkusRecognised() {
        List<String> skus = new List<String>{
            '001-DESK-SVC-DESK-ONOB-001',
            '001-INFR-SVC-INFR-ONOB-001',
            '001-CYBR-SVC-CYBR-ONOB-001',
            '001-HOST-SVC-HOST-ONOB-001'
        };
        Date start = Date.today();
        for (String sku : skus) {
            List<Map<String, Object>> result = JTLPreHook.buildLineUpdates(
                new List<Object>{ buildNode(path('TEMP-OB-' + sku), lineTagsWithSku(false, 'OneTime', null, sku)) },
                start, null, null, true,
                new Set<String>(), new Set<String>());
            System.assertEquals(1, result.size(), 'Expected 1-month entry for SKU: ' + sku);
            System.assertEquals(2, ((List<Object>) result.get(0).get('attributes')).size());
        }
    }

    @IsTest
    static void buildLineUpdates_onboardingFeeSku_newLine_getsBundleFlags() {
        String sku = '001-DESK-SVC-DESK-ONOB-001';
        Set<String> parentSkus = new Set<String>{ sku };
        Set<String> memberSkus = new Set<String>{ sku };
        List<Map<String, Object>> result = JTLPreHook.buildLineUpdates(
            new List<Object>{ buildNode(path('TEMP-OB-BUNDLE'), lineTagsWithSku(false, 'OneTime', null, sku)) },
            Date.today(), null, null, true,
            parentSkus, memberSkus);
        System.assertEquals(1, result.size());
        // StartDate + EndDate + Is_Bundle_Parent__c + Is_Part_Of_Bundle__c
        System.assertEquals(4, ((List<Object>) result.get(0).get('attributes')).size());
        System.assertEquals(true, parentSkus.isEmpty());
        System.assertEquals(true, memberSkus.isEmpty());
    }

    @IsTest
    static void buildLineUpdates_onboardingFeeSku_persistedLine_bundleFlagsNotApplied() {
        String sfId = UserInfo.getUserId();
        String sku  = '001-DESK-SVC-DESK-ONOB-001';
        Set<String> parentSkus = new Set<String>{ sku };
        Set<String> memberSkus = new Set<String>{ sku };
        List<Map<String, Object>> result = JTLPreHook.buildLineUpdates(
            new List<Object>{ buildNode(path(sfId), lineTagsWithSku(false, 'OneTime', null, sku)) },
            Date.today(), null, null, true,
            parentSkus, memberSkus);
        System.assertEquals(1, result.size());
        // Persisted line — only StartDate + EndDate, no bundle flags, sets untouched
        System.assertEquals(2, ((List<Object>) result.get(0).get('attributes')).size());
        System.assertEquals(false, parentSkus.isEmpty());
        System.assertEquals(false, memberSkus.isEmpty());
    }

    @IsTest
    static void buildLineUpdates_oneTimeSelling_skipped() {
        System.assertEquals(0,
            JTLPreHook.buildLineUpdates(
                new List<Object>{ buildNode(path('TEMP-OT'), lineTags(false, 'OneTime', null)) },
                Date.today(), Date.today().addMonths(12), null, true,
                new Set<String>(), new Set<String>()).size());
    }

    @IsTest
    static void buildLineUpdates_sellingModelFromScan_oneTime_skipped() {
        Map<String, Object> tags = new Map<String, Object>{
            'IsDeleted'             => tv(false),
            'ItemSegmentIdentifier' => tv(null),
            'ProductCode'           => tv('P1'),
            'SellingModelTypeName'  => tv('OneTime')
        };
        System.assertEquals(0,
            JTLPreHook.buildLineUpdates(
                new List<Object>{ buildNode(path('TEMP-SC'), tags) },
                Date.today(), Date.today().addMonths(12), null, true,
                new Set<String>(), new Set<String>()).size());
    }

    @IsTest
    static void buildLineUpdates_sellingModelFromScan_termBased_processed() {
        Map<String, Object> tags = new Map<String, Object>{
            'IsDeleted'             => tv(false),
            'ItemSegmentIdentifier' => tv(null),
            'ProductCode'           => tv('P1'),
            'SellingModelTypeName'  => tv('TermBased')
        };
        List<Map<String, Object>> result = JTLPreHook.buildLineUpdates(
            new List<Object>{ buildNode(path('TEMP-SC2'), tags) },
            Date.today(), Date.today().addMonths(12), null, true,
            new Set<String>(), new Set<String>());
        System.assertEquals(1, result.size());
    }

    @IsTest
    static void buildLineUpdates_amendRenew_persistedId_skipped() {
        String sfId = UserInfo.getUserId();
        System.assertEquals(0,
            JTLPreHook.buildLineUpdates(
                new List<Object>{ buildNode(path(sfId), lineTags(false, 'TermBased', null)) },
                Date.today(), null, Date.today().addMonths(12), false,
                new Set<String>(), new Set<String>()).size());
    }

    @IsTest
    static void buildLineUpdates_amendRenew_tempId_getsStartAndCoTerm() {
        Date start  = Date.newInstance(2025, 6, 1);
        Date coTerm = Date.newInstance(2026, 5, 31);
        List<Map<String, Object>> result = JTLPreHook.buildLineUpdates(
            new List<Object>{ buildNode(path('TEMP-AM'), lineTags(false, 'TermBased', null)) },
            start, null, coTerm, false,
            new Set<String>(), new Set<String>());
        System.assertEquals(1, result.size());
        List<Object> attrs = (List<Object>) result.get(0).get('attributes');
        System.assertEquals(2, attrs.size());
        System.assertEquals(start,  ((Map<String, Object>) attrs.get(0)).get('attributeValue'));
        System.assertEquals(coTerm, ((Map<String, Object>) attrs.get(1)).get('attributeValue'));
    }

    @IsTest
    static void buildLineUpdates_amendRenew_nullCoTerm_onlyStart() {
        List<Map<String, Object>> result = JTLPreHook.buildLineUpdates(
            new List<Object>{ buildNode(path('TEMP-AN'), lineTags(false, 'TermBased', null)) },
            Date.today(), null, null, false,
            new Set<String>(), new Set<String>());
        System.assertEquals(1, result.size());
        System.assertEquals(1, ((List<Object>) result.get(0).get('attributes')).size());
    }

    @IsTest
    static void buildLineUpdates_newBusiness_startAndEndSet() {
        Date start = Date.newInstance(2025, 1, 1);
        Date endDt = Date.newInstance(2025, 12, 31);
        List<Map<String, Object>> result = JTLPreHook.buildLineUpdates(
            new List<Object>{ buildNode(path('TEMP-NB'), lineTags(false, 'TermBased', null)) },
            start, endDt, null, true,
            new Set<String>(), new Set<String>());
        System.assertEquals(1, result.size());
        List<Object> attrs = (List<Object>) result.get(0).get('attributes');
        System.assertEquals(2, attrs.size());
        System.assertEquals(start, ((Map<String, Object>) attrs.get(0)).get('attributeValue'));
        System.assertEquals(endDt, ((Map<String, Object>) attrs.get(1)).get('attributeValue'));
    }

    @IsTest
    static void buildLineUpdates_newBusiness_nullEndDate_onlyStart() {
        List<Map<String, Object>> result = JTLPreHook.buildLineUpdates(
            new List<Object>{ buildNode(path('TEMP-NE'), lineTags(false, 'TermBased', null)) },
            Date.today(), null, null, true,
            new Set<String>(), new Set<String>());
        System.assertEquals(1, result.size());
        System.assertEquals(1, ((List<Object>) result.get(0).get('attributes')).size());
    }

    @IsTest
    static void buildLineUpdates_newBusiness_persistedLine_processedButNoBundleFlags() {
        // isNewBusiness=true so the amend/renew skip doesn't apply, even though the line is persisted —
        // but bundle flags must NOT be applied since isNewLine is false.
        String sfId = UserInfo.getUserId();
        String sku  = 'BUNDLE-PARENT-NB';
        Set<String> parentSkus = new Set<String>{ sku };
        Set<String> memberSkus = new Set<String>{ sku };
        List<Map<String, Object>> result = JTLPreHook.buildLineUpdates(
            new List<Object>{ buildNode(path(sfId), lineTagsWithSku(false, 'TermBased', null, sku)) },
            Date.today(), Date.today().addMonths(12), null, true,
            parentSkus, memberSkus);
        System.assertEquals(1, result.size());
        System.assertEquals(2, ((List<Object>) result.get(0).get('attributes')).size(), 'Start+End only, no bundle flags');
        System.assertEquals(false, parentSkus.isEmpty(), 'sets must remain untouched for a persisted line');
        System.assertEquals(false, memberSkus.isEmpty());
    }

    @IsTest
    static void buildLineUpdates_bundleParent_newLine_mergesFlags() {
        String sku = 'BUNDLE-PARENT-001';
        Set<String> parentSkus = new Set<String>{ sku };
        Set<String> memberSkus = new Set<String>{ sku };
        List<Map<String, Object>> result = JTLPreHook.buildLineUpdates(
            new List<Object>{ buildNode(path('TEMP-BP'), lineTagsWithSku(false, 'TermBased', null, sku)) },
            Date.today(), Date.today().addMonths(12), null, true,
            parentSkus, memberSkus);
        System.assertEquals(1, result.size());
        // StartDate + EndDate + Is_Bundle_Parent__c + Is_Part_Of_Bundle__c
        System.assertEquals(4, ((List<Object>) result.get(0).get('attributes')).size());
        System.assertEquals(true, parentSkus.isEmpty(), 'parentSkus should be cleared');
        System.assertEquals(true, memberSkus.isEmpty(), 'memberSkus should be cleared');
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 4 – getBundleSkuInfo()
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void getBundleSkuInfo_emptyItems_emptyResult() {
        JTLPreHook.BundleSkuInfo info = JTLPreHook.getBundleSkuInfo(new List<Object>());
        System.assertEquals(true, info.parentSkus.isEmpty());
        System.assertEquals(true, info.memberSkus.isEmpty());
    }

    @IsTest
    static void getBundleSkuInfo_allDeletedItems_emptyResult() {
        List<Object> items = new List<Object>{
            buildNode(path('D'), lineTagsWithSku(true, 'TermBased', null, 'SOME-SKU'))
        };
        JTLPreHook.BundleSkuInfo info = JTLPreHook.getBundleSkuInfo(items);
        System.assertEquals(true, info.parentSkus.isEmpty());
        System.assertEquals(true, info.memberSkus.isEmpty());
    }

    @IsTest
    static void getBundleSkuInfo_noMatchingProductComponents_emptyResult() {
        List<Object> items = new List<Object>{
            buildNode(path('TEMP-X'), lineTagsWithSku(false, 'TermBased', null, 'NO-BUNDLE-SKU'))
        };
        System.Test.startTest();
        JTLPreHook.BundleSkuInfo info = JTLPreHook.getBundleSkuInfo(items);
        System.Test.stopTest();
        System.assertEquals(true, info.parentSkus.isEmpty());
        System.assertEquals(true, info.memberSkus.isEmpty());
    }

    @IsTest
    static void getBundleSkuInfo_realCatalogBundle_newLine_flagsParentAndChild() {
        Product2 parent = new Product2(Name = 'Bundle Parent', StockKeepingUnit = 'BP-SKU-REAL', IsActive = true, Type = 'Bundle');
        Product2 child  = new Product2(Name = 'Bundle Child',  StockKeepingUnit = 'BC-SKU-REAL', IsActive = true);
        insert new List<Product2>{ parent, child };

        ProductRelationshipType relType = new ProductRelationshipType(
            Name = 'Test Bundle Relationship',
            MainProductRoleCat = 'Bundle',
            AssociatedProductRoleCat = 'BundleComponent');
        insert relType;

        insert new ProductRelatedComponent(
            ParentProductId           = parent.Id,
            ChildProductId            = child.Id,
            ProductRelationshipTypeId = relType.Id,
            IsDefaultComponent        = true
        );

        List<Object> items = new List<Object>{
            buildNode(path('TEMP-REAL-BUNDLE'), lineTagsWithSku(false, 'TermBased', null, 'BP-SKU-REAL'))
        };

        System.Test.startTest();
        JTLPreHook.BundleSkuInfo info = JTLPreHook.getBundleSkuInfo(items);
        System.Test.stopTest();

        System.assertEquals(true, info.parentSkus.contains('BP-SKU-REAL'));
        System.assertEquals(true, info.memberSkus.contains('BP-SKU-REAL'));
        System.assertEquals(true, info.memberSkus.contains('BC-SKU-REAL'));
    }

    @IsTest
    static void getBundleSkuInfo_realCatalogBundle_persistedLine_notFlagged() {
        // Parent SKU only appears on an already-persisted line — since the bundle
        // itself isn't "new" in this transaction, it must not be claimed.
        Product2 parent = new Product2(Name = 'Bundle Parent 2', StockKeepingUnit = 'BP-SKU-PERSISTED', IsActive = true, Type = 'Bundle');
        Product2 child  = new Product2(Name = 'Bundle Child 2',  StockKeepingUnit = 'BC-SKU-PERSISTED', IsActive = true);
        insert new List<Product2>{ parent, child };

        ProductRelationshipType relType = new ProductRelationshipType(
            Name = 'Test Bundle Relationship',
            MainProductRoleCat = 'Bundle',
            AssociatedProductRoleCat = 'BundleComponent');
        insert relType;

        insert new ProductRelatedComponent(
            ParentProductId           = parent.Id,
            ChildProductId            = child.Id,
            ProductRelationshipTypeId = relType.Id,
            IsDefaultComponent        = true
        );

        String sfId = UserInfo.getUserId();
        List<Object> items = new List<Object>{
            buildNode(path(sfId), lineTagsWithSku(false, 'TermBased', null, 'BP-SKU-PERSISTED'))
        };

        System.Test.startTest();
        JTLPreHook.BundleSkuInfo info = JTLPreHook.getBundleSkuInfo(items);
        System.Test.stopTest();

        System.assertEquals(true, info.parentSkus.isEmpty());
        System.assertEquals(true, info.memberSkus.isEmpty());
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 5 – appendBundleAttributes()
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void appendBundle_notInEitherSet_noChange() {
        List<List<Object>> attrs = new List<List<Object>>();
        JTLPreHook.appendBundleAttributes(attrs, 'OTHER',
            new Set<String>{ 'PARENT' }, new Set<String>{ 'MEMBER' });
        System.assertEquals(0, attrs.size());
    }

    @IsTest
    static void appendBundle_inParentSet_addsParentFlagAndRemoves() {
        List<List<Object>> attrs = new List<List<Object>>();
        Set<String> parentSkus = new Set<String>{ 'SKU-P' };
        JTLPreHook.appendBundleAttributes(attrs, 'SKU-P', parentSkus, new Set<String>());
        System.assertEquals(1, attrs.size());
        System.assertEquals('Is_Bundle_Parent__c', attrs.get(0).get(0));
        System.assertEquals(true, attrs.get(0).get(2));
        System.assertEquals(true, parentSkus.isEmpty());
    }

    @IsTest
    static void appendBundle_inMemberSet_addsMemberFlagAndRemoves() {
        List<List<Object>> attrs = new List<List<Object>>();
        Set<String> memberSkus = new Set<String>{ 'SKU-M' };
        JTLPreHook.appendBundleAttributes(attrs, 'SKU-M', new Set<String>(), memberSkus);
        System.assertEquals(1, attrs.size());
        System.assertEquals('Is_Part_Of_Bundle__c', attrs.get(0).get(0));
        System.assertEquals(true, attrs.get(0).get(2));
        System.assertEquals(true, memberSkus.isEmpty());
    }

    @IsTest
    static void appendBundle_inBothSets_addsBothFlagsAndRemoves() {
        List<List<Object>> attrs = new List<List<Object>>();
        Set<String> parentSkus = new Set<String>{ 'SKU-B' };
        Set<String> memberSkus = new Set<String>{ 'SKU-B' };
        JTLPreHook.appendBundleAttributes(attrs, 'SKU-B', parentSkus, memberSkus);
        System.assertEquals(2, attrs.size());
        System.assertEquals('Is_Bundle_Parent__c',  attrs.get(0).get(0));
        System.assertEquals('Is_Part_Of_Bundle__c', attrs.get(1).get(0));
        System.assertEquals(true, parentSkus.isEmpty());
        System.assertEquals(true, memberSkus.isEmpty());
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 6 – buildStandaloneBundleFlagUpdates()
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void buildStandalone_bothSetsEmpty_returnsEmpty() {
        List<Object> items = new List<Object>{ buildNode(path('X'), lineTags(false, 'TermBased', null)) };
        System.assertEquals(0,
            JTLPreHook.buildStandaloneBundleFlagUpdates(items, new Set<String>(), new Set<String>()).size());
    }

    @IsTest
    static void buildStandalone_matchingSku_newLine_returnsEntry() {
        String sku = 'BUNDLE-SA';
        List<Object> items = new List<Object>{
            buildNode(path('TEMP-SB'), lineTagsWithSku(false, 'TermBased', null, sku))
        };
        List<Map<String, Object>> result = JTLPreHook.buildStandaloneBundleFlagUpdates(
            items, new Set<String>{ sku }, new Set<String>{ sku });
        System.assertEquals(1, result.size());
    }

    @IsTest
    static void buildStandalone_matchingSku_persistedLine_skipped() {
        String sfId = UserInfo.getUserId();
        String sku  = 'BUNDLE-SA-PERSISTED';
        List<Object> items = new List<Object>{
            buildNode(path(sfId), lineTagsWithSku(false, 'TermBased', null, sku))
        };
        System.assertEquals(0,
            JTLPreHook.buildStandaloneBundleFlagUpdates(
                items, new Set<String>{ sku }, new Set<String>{ sku }).size());
    }

    @IsTest
    static void buildStandalone_deletedItem_skipped() {
        String sku = 'BUNDLE-DEL';
        List<Object> items = new List<Object>{
            buildNode(path('TEMP-BD'), lineTagsWithSku(true, 'TermBased', null, sku))
        };
        System.assertEquals(0,
            JTLPreHook.buildStandaloneBundleFlagUpdates(
                items, new Set<String>{ sku }, new Set<String>{ sku }).size());
    }

    @IsTest
    static void buildStandalone_noSkuMatch_returnsEmpty() {
        List<Object> items = new List<Object>{
            buildNode(path('TEMP-NS'), lineTagsWithSku(false, 'TermBased', null, 'OTHER-SKU'))
        };
        System.assertEquals(0,
            JTLPreHook.buildStandaloneBundleFlagUpdates(
                items, new Set<String>{ 'BUNDLE-SKU' }, new Set<String>{ 'BUNDLE-SKU' }).size());
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 7 – getContractCoTermEndDate()
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void getCoTerm_blankAndNull_returnNull() {
        System.assertEquals(null, JTLPreHook.getContractCoTermEndDate(''));
        System.assertEquals(null, JTLPreHook.getContractCoTermEndDate(null));
    }

    @IsTest
    static void getCoTerm_malformedId_returnsNullViaCatch() {
        System.Test.startTest();
        System.assertEquals(null, JTLPreHook.getContractCoTermEndDate('not-a-valid-id-format'));
        System.Test.stopTest();
    }

    @IsTest
    static void getCoTerm_nonExistentId_returnsNull() {
        System.Test.startTest();
        System.assertEquals(null, JTLPreHook.getContractCoTermEndDate(UserInfo.getUserId()));
        System.Test.stopTest();
    }

    @IsTest
    static void getCoTerm_validQuoteNoQli_returnsNull() {
        Account acc = makeAccount('CoTerm Account');
        insert acc;
        Opportunity opp = new Opportunity(
            Name = 'CoTerm Opp', AccountId = acc.Id,
            StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        insert opp;
        Quote q = new Quote(
            Name = 'CoTerm Quote', OpportunityId = opp.Id,
            Status = 'Draft', Pricebook2Id = System.Test.getStandardPricebookId());
        insert q;
        System.Test.startTest();
        System.assertEquals(null, JTLPreHook.getContractCoTermEndDate(q.Id));
        System.Test.stopTest();
    }

    @IsTest
    static void getCoTerm_withRealQuoteLineItems_returnsMostCommonEndDate() {
        Account acc = makeAccount('CoTerm QLI Account');
        insert acc;
        Opportunity opp = new Opportunity(
            Name = 'CoTerm QLI Opp', AccountId = acc.Id,
            StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        insert opp;
        Quote q = new Quote(
            Name = 'CoTerm QLI Quote', OpportunityId = opp.Id,
            Status = 'Draft', Pricebook2Id = System.Test.getStandardPricebookId());
        insert q;

        Product2 prod = new Product2(Name = 'CoTerm Test Product', IsActive = true);
        insert prod;

        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = System.Test.getStandardPricebookId(),
            Product2Id   = prod.Id,
            UnitPrice    = 100,
            IsActive     = true
        );
        insert pbe;

        Date majorityEndDate = Date.newInstance(2026, 5, 31);
        Date minorityEndDate = Date.newInstance(2026, 6, 30);

        insert new List<QuoteLineItem>{
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
                Quantity = 1, UnitPrice = 100, EndDate = majorityEndDate),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
                Quantity = 1, UnitPrice = 100, EndDate = majorityEndDate),
            new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = prod.Id,
                Quantity = 1, UnitPrice = 100, EndDate = minorityEndDate)
        };

        System.Test.startTest();
        Date result = JTLPreHook.getContractCoTermEndDate(q.Id);
        System.Test.stopTest();

        System.assertEquals(majorityEndDate, result);
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 8 – appendBundleAttributes / buildNodeUpdate reuse checks
    //             (buildNodeUpdate)
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void buildNodeUpdate_singleAttr_correctStructure() {
        Date today = Date.today();
        Map<String, Object> result = JTLPreHook.buildNodeUpdate(
            new List<Object>{ 'A', 'B' },
            new List<List<Object>>{ new List<Object>{ 'StartDate', 'EffectiveFrom', today } }
        );
        System.assertNotEquals(null, result.get('nodePath'));
        List<Object> attrs = (List<Object>) result.get('attributes');
        System.assertEquals(1, attrs.size());
        Map<String, Object> a = (Map<String, Object>) attrs.get(0);
        System.assertEquals('StartDate',     a.get('attributeName'));
        System.assertEquals('EffectiveFrom', a.get('attributeTag'));
        System.assertEquals(today,           a.get('attributeValue'));
    }

    @IsTest
    static void buildNodeUpdate_multipleAttrs_allPresent() {
        Map<String, Object> result = JTLPreHook.buildNodeUpdate(
            new List<Object>{ 'A', 'B' },
            new List<List<Object>>{
                new List<Object>{ 'StartDate', 'EffectiveFrom', Date.today() },
                new List<Object>{ 'EndDate',   'EffectiveTo',   Date.today().addMonths(12) }
            }
        );
        System.assertEquals(2, ((List<Object>) result.get('attributes')).size());
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 9 – isOneTimeSelling()
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void isOneTimeSelling_nullAndBlank_returnsFalse() {
        System.assertEquals(false, JTLPreHook.isOneTimeSelling(null));
        System.assertEquals(false, JTLPreHook.isOneTimeSelling(''));
        System.assertEquals(false, JTLPreHook.isOneTimeSelling('   '));
    }

    @IsTest
    static void isOneTimeSelling_allVariants_returnTrue() {
        for (String v : new List<String>{ 'OneTime', 'onetime', 'ONETIME', 'one_time', 'one-time', 'One Time' }) {
            System.assertEquals(true, JTLPreHook.isOneTimeSelling(v), 'Failed for: ' + v);
        }
    }

    @IsTest
    static void isOneTimeSelling_nonOneTime_returnsFalse() {
        for (String v : new List<String>{ 'TermBased', 'Evergreen', 'Usage' }) {
            System.assertEquals(false, JTLPreHook.isOneTimeSelling(v), 'Failed for: ' + v);
        }
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 10 – scanSellingModelFromTags()
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void scanSellingModel_nullTags_returnsNull() {
        System.assertEquals(null, JTLPreHook.scanSellingModelFromTags(null));
    }

    @IsTest
    static void scanSellingModel_noMatchingKey_returnsNull() {
        System.assertEquals(null,
            JTLPreHook.scanSellingModelFromTags(new Map<String, Object>{ 'ProductCode' => tv('P') }));
    }

    @IsTest
    static void scanSellingModel_matchingKey_returnsValue() {
        System.assertEquals('TermBased',
            JTLPreHook.scanSellingModelFromTags(
                new Map<String, Object>{ 'SellingModelType' => tv('TermBased') }));
    }

    @IsTest
    static void scanSellingModel_wrapperNotMap_returnsNull() {
        System.assertEquals(null,
            JTLPreHook.scanSellingModelFromTags(
                new Map<String, Object>{ 'SellingModelType' => 'raw' }));
    }

    @IsTest
    static void scanSellingModel_nullTagValue_returnsNull() {
        System.assertEquals(null,
            JTLPreHook.scanSellingModelFromTags(
                new Map<String, Object>{ 'SellingModelType' => tv(null) }));
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 11 – isTagTrue()
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void isTagTrue_keyAbsent_returnsFalse() {
        System.assertEquals(false, JTLPreHook.isTagTrue(new Map<String, Object>(), 'IsDeleted'));
    }

    @IsTest
    static void isTagTrue_trueValue_returnsTrue() {
        System.assertEquals(true,
            JTLPreHook.isTagTrue(new Map<String, Object>{ 'IsDeleted' => tv(true) }, 'IsDeleted'));
    }

    @IsTest
    static void isTagTrue_falseValue_returnsFalse() {
        System.assertEquals(false,
            JTLPreHook.isTagTrue(new Map<String, Object>{ 'IsDeleted' => tv(false) }, 'IsDeleted'));
    }

    @IsTest
    static void isTagTrue_nullValue_returnsFalse() {
        System.assertEquals(false,
            JTLPreHook.isTagTrue(new Map<String, Object>{ 'IsDeleted' => tv(null) }, 'IsDeleted'));
    }

    @IsTest
    static void isTagTrue_wrapperNotMap_returnsFalse() {
        System.assertEquals(false,
            JTLPreHook.isTagTrue(new Map<String, Object>{ 'IsDeleted' => 'bad' }, 'IsDeleted'));
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 12 – extractTagDate()
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void extractTagDate_nullTags_returnsNull() {
        System.assertEquals(null, JTLPreHook.extractTagDate(null, 'StartDate'));
    }

    @IsTest
    static void extractTagDate_keyAbsent_returnsNull() {
        System.assertEquals(null,
            JTLPreHook.extractTagDate(new Map<String, Object>(), 'StartDate'));
    }

    @IsTest
    static void extractTagDate_nullValue_returnsNull() {
        System.assertEquals(null,
            JTLPreHook.extractTagDate(
                new Map<String, Object>{ 'StartDate' => tv(null) }, 'StartDate'));
    }

    @IsTest
    static void extractTagDate_validDateString_returnsIso() {
        System.assertEquals('2025-06-01',
            JTLPreHook.extractTagDate(
                new Map<String, Object>{ 'StartDate' => tv('2025-06-01') }, 'StartDate'));
    }

    @IsTest
    static void extractTagDate_datetimeValue_returnsDatePart() {
        Datetime dt = Datetime.newInstanceGmt(2025, 3, 15, 10, 30, 0);
        String result = JTLPreHook.extractTagDate(
            new Map<String, Object>{ 'StartDate' => tv(dt) }, 'StartDate');
        System.assertNotEquals(null, result);
        System.assert(result.startsWith('2025'), result);
    }

    @IsTest
    static void extractTagDate_invalidString_returnsNull() {
        System.assertEquals(null,
            JTLPreHook.extractTagDate(
                new Map<String, Object>{ 'StartDate' => tv('not-a-date') }, 'StartDate'));
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 13 – success() / fail()
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void success_setsStatusAndMessage() {
        RevSignaling.TransactionResponse r = new RevSignaling.TransactionResponse();
        JTLPreHook.success(r, 'all good');
        System.assertEquals(RevSignaling.TransactionStatus.SUCCESS, r.status);
        System.assertEquals('all good', r.message);
    }

    @IsTest
    static void fail_setsStatusAndMessage() {
        RevSignaling.TransactionResponse r = new RevSignaling.TransactionResponse();
        JTLPreHook.fail(r, 'bad');
        System.assertEquals(RevSignaling.TransactionStatus.FAILED, r.status);
        System.assertEquals('bad', r.message);
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 14 – pushUpdates()
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void pushUpdates_emptyUpdates_returnsNoLines() {
        RevSignaling.TransactionResponse r = new RevSignaling.TransactionResponse();
        RevSignaling.TransactionResponse result = JTLPreHook.pushUpdates(
            new Context.IndustriesContext(), 'ctx-001',
            new List<Map<String, Object>>(), r, 'should not appear');
        System.assertEquals(RevSignaling.TransactionStatus.SUCCESS, result.status);
        System.assert(result.message.containsIgnoreCase('No lines'), result.message);
    }

    @IsTest
    static void pushUpdates_nonEmptyUpdates_returnsSuccess() {
        RevSignaling.TransactionResponse r = new RevSignaling.TransactionResponse();
        List<Map<String, Object>> updates = new List<Map<String, Object>>{
            JTLPreHook.buildNodeUpdate(new List<Object>{ 'A', 'B' },
                new List<List<Object>>{ new List<Object>{ 'StartDate', 'EffectiveFrom', Date.today() } })
        };
        System.Test.startTest();
        RevSignaling.TransactionResponse result = JTLPreHook.pushUpdates(
            new Context.IndustriesContext(), 'ctx-001', updates, r, 'Dates populated');
        System.Test.stopTest();
        System.assertEquals(RevSignaling.TransactionStatus.SUCCESS, result.status);
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 15 – parseLineItems()
    //
    // build()/queryLineItems() are thin wrappers around ctx.queryTags —
    // all the actual parsing logic they used to contain inline now lives
    // in parseLineItems/parseContextData below, which take the raw
    // ctx.queryTags-shaped Map directly and are fully testable without
    // touching Context.IndustriesContext at all.
    // ─────────────────────────────────────────────────────────

    private static Map<String, Object> lineItemsRes(List<Object> items) {
        return new Map<String, Object>{
            'queryResult' => new Map<String, Object>{
                'SalesTransactionItem' => items
            }
        };
    }

    @IsTest
    static void parseLineItems_withItems_returnsAll() {
        List<Object> items = new List<Object>{
            new Map<String, Object>{ 'id' => '1' },
            new Map<String, Object>{ 'id' => '2' }
        };
        System.assertEquals(2, JTLPreHook.parseLineItems(lineItemsRes(items)).size());
    }

    @IsTest
    static void parseLineItems_nullItems_returnsEmptyList() {
        System.assertEquals(0, JTLPreHook.parseLineItems(lineItemsRes(null)).size());
    }

    @IsTest
    static void parseLineItems_noQueryResultKey_throws() {
        // No null-check on queryResult in this path — matches the original
        // inline behavior exactly (pre-existing, not introduced by extraction).
        try {
            JTLPreHook.parseLineItems(new Map<String, Object>());
            System.assert(false, 'Expected a NullPointerException');
        } catch (NullPointerException e) {
            System.assert(true);
        }
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 16 – parseContextData()
    // ─────────────────────────────────────────────────────────

    private static Map<String, Object> contextRes(List<Object> nodes) {
        return new Map<String, Object>{
            'queryResult' => new Map<String, Object>{
                'SalesTransaction' => nodes
            }
        };
    }

    @IsTest
    static void parseContextData_noQueryResultKey_returnsBlankTc() {
        JTLPreHook.TransactionContext tc =
            JTLPreHook.parseContextData(new Map<String, Object>());
        System.assertEquals(null, tc.quoteStartDate);
        System.assertEquals(null, tc.quoteId);
    }

    @IsTest
    static void parseContextData_nullQueryResult_returnsBlankTc() {
        Map<String, Object> res = new Map<String, Object>{ 'queryResult' => null };
        System.assertEquals(null, JTLPreHook.parseContextData(res).quoteStartDate);
    }

    @IsTest
    static void parseContextData_emptyNodes_returnsBlankTc() {
        JTLPreHook.TransactionContext tc =
            JTLPreHook.parseContextData(contextRes(new List<Object>()));
        System.assertEquals(null, tc.quoteStartDate);
    }

    @IsTest
    static void parseContextData_nullNodes_returnsBlankTc() {
        JTLPreHook.TransactionContext tc =
            JTLPreHook.parseContextData(contextRes(null));
        System.assertEquals(null, tc.quoteStartDate);
    }

    @IsTest
    static void parseContextData_nullTagsOnNode_returnsBlankTc() {
        Map<String, Object> node = new Map<String, Object>{ 'tagValue' => null };
        JTLPreHook.TransactionContext tc =
            JTLPreHook.parseContextData(contextRes(new List<Object>{ node }));
        System.assertEquals(null, tc.quoteStartDate);
    }

    @IsTest
    static void parseContextData_validTagsNoQuoteId_setsStartDateOnly() {
        Map<String, Object> nodeTags = new Map<String, Object>{
            'StartDate' => tv('2025-03-01')
        };
        Map<String, Object> node = new Map<String, Object>{ 'tagValue' => nodeTags };
        JTLPreHook.TransactionContext tc =
            JTLPreHook.parseContextData(contextRes(new List<Object>{ node }));
        System.assertEquals('2025-03-01', tc.quoteStartDate);
        System.assertEquals(null, tc.quoteId);
    }

    @IsTest
    static void parseContextData_tagWrapperNotMap_skippedGracefully() {
        Map<String, Object> nodeTags = new Map<String, Object>{
            'StartDate' => tv('2025-01-01'),
            'BadTag'    => 'raw-string-not-a-map'
        };
        Map<String, Object> node = new Map<String, Object>{ 'tagValue' => nodeTags };
        JTLPreHook.TransactionContext tc =
            JTLPreHook.parseContextData(contextRes(new List<Object>{ node }));
        System.assertEquals('2025-01-01', tc.quoteStartDate);
        System.assertEquals(null, tc.quoteId); // bad tag skipped, no 0Q0 found
    }

    @IsTest
    static void parseContextData_quoteIdNoMatchingQuote_soqlCaught() {
        // Well-formed 0Q0-prefixed string that isn't a real Quote → SOQL throws → caught
        Map<String, Object> nodeTags = new Map<String, Object>{
            'StartDate' => tv('2025-06-01'),
            'QuoteRef'  => tv('0Q0000000000001AAA')
        };
        Map<String, Object> node = new Map<String, Object>{ 'tagValue' => nodeTags };
        JTLPreHook.TransactionContext tc =
            JTLPreHook.parseContextData(contextRes(new List<Object>{ node }));
        System.assertEquals('2025-06-01', tc.quoteStartDate);
        System.assertEquals('0Q0000000000001AAA', tc.quoteId);
        System.assertEquals(null, tc.contractTerm);
    }

    @IsTest
    static void parseContextData_withRealQuoteId_setsQuoteFields() {
        Account acc = makeAccount('ParseCtx Account');
        insert acc;
        Opportunity opp = new Opportunity(
            Name      = 'ParseCtx Opp',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name                    = 'ParseCtx Quote',
            OpportunityId           = opp.Id,
            Status                  = 'Draft',
            Pricebook2Id            = System.Test.getStandardPricebookId(),
            Contract_Term_Months__c = 12
        );
        insert q;

        Map<String, Object> nodeTags = new Map<String, Object>{
            'StartDate' => tv('2025-01-01'),
            'QuoteRef'  => tv(q.Id)   // starts with 0Q0, length >= 15
        };
        Map<String, Object> node = new Map<String, Object>{ 'tagValue' => nodeTags };

        System.Test.startTest();
        JTLPreHook.TransactionContext tc =
            JTLPreHook.parseContextData(contextRes(new List<Object>{ node }));
        System.Test.stopTest();

        System.assertEquals('2025-01-01', tc.quoteStartDate);
        System.assertEquals(q.Id, tc.quoteId);
        System.assertEquals(12, tc.contractTerm);
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 17 – TransactionContext DTO
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void transactionContext_fieldsRoundTrip() {
        JTLPreHook.TransactionContext tc = new JTLPreHook.TransactionContext();
        tc.quoteStartDate = '2025-01-01';
        tc.contractTerm   = 24;
        tc.quoteId        = 'QUOTE-001';
        tc.quoteType      = 'Amend';
        System.assertEquals('2025-01-01', tc.quoteStartDate);
        System.assertEquals(24,           tc.contractTerm);
        System.assertEquals('QUOTE-001',  tc.quoteId);
        System.assertEquals('Amend',      tc.quoteType);
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 18 – LineItemNodeWrapper
    // ─────────────────────────────────────────────────────────

    @IsTest
    static void wrapper_fullNode_allFieldsParsed() {
        LineItemNodeWrapper w = new LineItemNodeWrapper(
            buildNode(path('LINE-001'), lineTagsWithSku(false, 'TermBased', 'SEG-1', 'SKU-001')));
        System.assertEquals(false,       w.deleted);
        System.assertEquals('TermBased', w.sellingModelType);
        System.assertEquals('SEG-1',     w.segmentIdentifier);
        System.assertEquals('PROD-001',  w.productCode);
        System.assertEquals('SKU-001',   w.stockKeepingUnit);
        System.assertEquals(true,        w.isValid());
        System.assertEquals(2,           w.salesPath.size());
    }

    @IsTest
    static void wrapper_nullSku_returnsNull() {
        LineItemNodeWrapper w = new LineItemNodeWrapper(
            buildNode(path('LINE-NS'), lineTags(false, 'TermBased', null)));
        System.assertEquals(null, w.stockKeepingUnit);
    }

    @IsTest
    static void wrapper_isValid_falseShortPath() {
        Map<String, Object> node = new Map<String, Object>{
            'dataPath' => new List<Object>{ 'one' }, 'tagValue' => null };
        System.assertEquals(false, new LineItemNodeWrapper(node).isValid());
    }

    @IsTest
    static void wrapper_isValid_falseNullPath() {
        Map<String, Object> node = new Map<String, Object>{
            'dataPath' => null, 'tagValue' => null };
        System.assertEquals(false, new LineItemNodeWrapper(node).isValid());
    }

    @IsTest
    static void wrapper_deletedTrue_flagSet() {
        LineItemNodeWrapper w = new LineItemNodeWrapper(
            buildNode(path('D'), lineTags(true, 'TermBased', null)));
        System.assertEquals(true, w.deleted);
    }

    @IsTest
    static void wrapper_isTermBased_returnsTrue() {
        LineItemNodeWrapper w = new LineItemNodeWrapper(
            buildNode(path('X'), lineTags(false, 'TermBased', null)));
        System.assertEquals(true, w.isTermBased());
    }

    @IsTest
    static void wrapper_isTermBased_oneTimeReturnsFalse() {
        LineItemNodeWrapper w = new LineItemNodeWrapper(
            buildNode(path('X'), lineTags(false, 'OneTime', null)));
        System.assertEquals(false, w.isTermBased());
    }

    @IsTest
    static void wrapper_noTagValue_defaults() {
        LineItemNodeWrapper w = new LineItemNodeWrapper(buildNode(path('X'), null));
        System.assertEquals(false, w.deleted);
        System.assertEquals(null,  w.sellingModelType);
        System.assertEquals(null,  w.stockKeepingUnit);
    }

    @IsTest
    static void wrapper_isPersisted_realId_returnsTrue() {
        LineItemNodeWrapper w = new LineItemNodeWrapper(
            buildNode(path(UserInfo.getUserId()), lineTags(false, 'TermBased', null)));
        System.assertEquals(true, w.isPersisted());
    }

    @IsTest
    static void wrapper_isPersisted_tempId_returnsFalse() {
        LineItemNodeWrapper w = new LineItemNodeWrapper(
            buildNode(path('TEMP-001'), lineTags(false, 'TermBased', null)));
        System.assertEquals(false, w.isPersisted());
    }

    @IsTest
    static void wrapper_isPersisted_shortPath_returnsFalse() {
        Map<String, Object> node = new Map<String, Object>{
            'dataPath' => new List<Object>{ 'one' }, 'tagValue' => null };
        System.assertEquals(false, new LineItemNodeWrapper(node).isPersisted());
    }
}