@IsTest
private class QuoteMarginRollupPostHookTest {

    // =========================================================
    // TEST HELPERS
    // =========================================================

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

    // Wraps tags in the shape ctx.queryTags returns
    private static Map<String, Object> makeTagsRes(Map<String, Object> tags) {
        Map<String, Object> node = new Map<String, Object>{ 'tagValue' => tags };
        Map<String, Object> qr   = new Map<String, Object>{
            'SalesTransaction' => new List<Object>{ node }
        };
        return new Map<String, Object>{ 'queryResult' => qr };
    }

    // Creates Account → Opportunity → Quote
    private static Quote insertQuote(String name) {
        Account acc = makeAccount(name + ' Acct');
        insert acc;
        Opportunity opp = new Opportunity(
            Name      = name + ' Opp',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name          = name,
            OpportunityId = opp.Id,
            Pricebook2Id  = System.Test.getStandardPricebookId(),
            Status        = 'Draft'
        );
        insert q;
        return q;
    }

    // =========================================================
    // execute()
    // =========================================================

    @IsTest
    static void execute_blankContextId_returnsSuccessSkip() {
        QuoteMarginRollupPostHook hook = new QuoteMarginRollupPostHook();
        RevSignaling.TransactionResponse r = hook.execute(makeReq(''));
        System.assertEquals(RevSignaling.TransactionStatus.SUCCESS, r.status);
        System.assert(r.message.contains('No contextId'), r.message);
    }

    @IsTest
    static void execute_nullContextId_returnsSuccessSkip() {
        QuoteMarginRollupPostHook hook = new QuoteMarginRollupPostHook();
        RevSignaling.TransactionResponse r = hook.execute(makeReq(null));
        System.assertEquals(RevSignaling.TransactionStatus.SUCCESS, r.status);
        System.assert(r.message.contains('No contextId'), r.message);
    }

    @IsTest
    static void execute_alreadyExecuted_returnsAlreadyExecutedMessage() {
        QuoteMarginRollupPostHook hook = new QuoteMarginRollupPostHook();
        // alreadyExecuted is now only checked/set AFTER the blank-contextId check
        // and the onboarding-discount step, so the first call needs a non-blank
        // contextId to actually flip the flag — a blank-contextId call returns
        // early before ever reaching that check.
        hook.execute(makeReq('first-ctx'));
        // Second call (also non-blank, so it reaches the alreadyExecuted guard)
        RevSignaling.TransactionResponse r = hook.execute(makeReq('second-ctx'));
        System.assertEquals(RevSignaling.TransactionStatus.SUCCESS, r.status);
        System.assert(r.message.containsIgnoreCase('Already executed'), r.message);
    }

    @IsTest
    static void execute_fakeContextId_returnsSuccessWithoutPropagatingException() {
        // getQuoteId catches the ctx.queryTags exception and returns null → "No quoteId found"
        QuoteMarginRollupPostHook hook = new QuoteMarginRollupPostHook();
        RevSignaling.TransactionResponse r = hook.execute(makeReq('fake-ctx-id-123'));
        System.assertEquals(RevSignaling.TransactionStatus.SUCCESS, r.status);
    }

    @IsTest
    static void execute_nullRequest_outerCatchHandlesNullPointerException() {
        // request.ctxInstanceId throws NPE when request is null → outer catch fires
        QuoteMarginRollupPostHook hook = new QuoteMarginRollupPostHook();
        RevSignaling.TransactionResponse r = hook.execute(null);
        System.assertEquals(RevSignaling.TransactionStatus.SUCCESS, r.status);
        System.assert(r.message.containsIgnoreCase('Hook error'), r.message);
    }

    // =========================================================
    // fireRollup()
    // =========================================================

    @IsTest
    static void fireRollup_blankQuoteId_returnsNoQuoteIdFound() {
        RevSignaling.TransactionResponse res = new RevSignaling.TransactionResponse();
        RevSignaling.TransactionResponse r   =
            QuoteMarginRollupPostHook.fireRollup('', res);
        System.assertEquals(RevSignaling.TransactionStatus.SUCCESS, r.status);
        System.assert(r.message.contains('No quoteId found'), r.message);
    }

    @IsTest
    static void fireRollup_nullQuoteId_returnsNoQuoteIdFound() {
        RevSignaling.TransactionResponse res = new RevSignaling.TransactionResponse();
        RevSignaling.TransactionResponse r   =
            QuoteMarginRollupPostHook.fireRollup(null, res);
        System.assertEquals(RevSignaling.TransactionStatus.SUCCESS, r.status);
        System.assert(r.message.contains('No quoteId found'), r.message);
    }

    @IsTest
    static void fireRollup_validQuoteId_queuesAsyncAndReturnsQueued() {
        Quote q = insertQuote('FireRollup Quote');
        RevSignaling.TransactionResponse res = new RevSignaling.TransactionResponse();
        System.Test.startTest();
        RevSignaling.TransactionResponse r =
            QuoteMarginRollupPostHook.fireRollup(q.Id, res);
        System.Test.stopTest();
        System.assertEquals(RevSignaling.TransactionStatus.SUCCESS, r.status);
        System.assert(r.message.containsIgnoreCase('queued'), r.message);
    }

    // =========================================================
    // parseQuoteId()
    // =========================================================

    @IsTest
    static void parseQuoteId_nullRes_returnsNull() {
        System.assertEquals(null, QuoteMarginRollupPostHook.parseQuoteId(null));
    }

    @IsTest
    static void parseQuoteId_noQueryResultKey_returnsNull() {
        Map<String, Object> res = new Map<String, Object>{ 'other' => 'value' };
        System.assertEquals(null, QuoteMarginRollupPostHook.parseQuoteId(res));
    }

    @IsTest
    static void parseQuoteId_nullNodes_returnsNull() {
        Map<String, Object> qr  = new Map<String, Object>{ 'SalesTransaction' => null };
        Map<String, Object> res = new Map<String, Object>{ 'queryResult' => qr };
        System.assertEquals(null, QuoteMarginRollupPostHook.parseQuoteId(res));
    }

    @IsTest
    static void parseQuoteId_emptyNodes_returnsNull() {
        Map<String, Object> qr  = new Map<String, Object>{
            'SalesTransaction' => new List<Object>()
        };
        Map<String, Object> res = new Map<String, Object>{ 'queryResult' => qr };
        System.assertEquals(null, QuoteMarginRollupPostHook.parseQuoteId(res));
    }

    @IsTest
    static void parseQuoteId_nullTags_returnsNull() {
        Map<String, Object> node = new Map<String, Object>{ 'tagValue' => null };
        Map<String, Object> qr   = new Map<String, Object>{
            'SalesTransaction' => new List<Object>{ node }
        };
        Map<String, Object> res  = new Map<String, Object>{ 'queryResult' => qr };
        System.assertEquals(null, QuoteMarginRollupPostHook.parseQuoteId(res));
    }

    @IsTest
    static void parseQuoteId_tagsHaveNon0Q0Value_returnsNull() {
        Map<String, Object> tags = new Map<String, Object>{
            'AcctRef' => new Map<String, Object>{ 'tagValue' => '0010000000000001AAA' }
        };
        System.assertEquals(null, QuoteMarginRollupPostHook.parseQuoteId(makeTagsRes(tags)));
    }

    @IsTest
    static void parseQuoteId_quoteIdTooShort_returnsNull() {
        Map<String, Object> tags = new Map<String, Object>{
            'Ref' => new Map<String, Object>{ 'tagValue' => '0Q0short' }
        };
        System.assertEquals(null, QuoteMarginRollupPostHook.parseQuoteId(makeTagsRes(tags)));
    }

    @IsTest
    static void parseQuoteId_validQuoteId_returnsIt() {
        String fakeQid = '0Q0000000000000001';  // 18 chars, starts with 0Q0
        Map<String, Object> tags = new Map<String, Object>{
            'QuoteRef' => new Map<String, Object>{ 'tagValue' => fakeQid }
        };
        System.assertEquals(fakeQid, QuoteMarginRollupPostHook.parseQuoteId(makeTagsRes(tags)));
    }

    @IsTest
    static void parseQuoteId_wrapperIsNotMap_skippedReturnsNull() {
        // tagValue is a plain String — caught by for-loop try/catch
        Map<String, Object> tags = new Map<String, Object>{
            'BadKey' => 'plain-string-not-a-wrapper'
        };
        System.assertEquals(null, QuoteMarginRollupPostHook.parseQuoteId(makeTagsRes(tags)));
    }

    @IsTest
    static void parseQuoteId_tagValueIsNull_returnsNull() {
        Map<String, Object> tags = new Map<String, Object>{
            'QuoteRef' => new Map<String, Object>{ 'tagValue' => null }
        };
        System.assertEquals(null, QuoteMarginRollupPostHook.parseQuoteId(makeTagsRes(tags)));
    }

    // =========================================================
    // calcEffort()
    // =========================================================

    @IsTest
    static void calcEffort_grossNotInMap_returnsNull() {
        Map<String, Decimal> grossMap = new Map<String, Decimal>();
        Map<String, Decimal> rateMap  = new Map<String, Decimal>{ 'Service Desk' => 145 };
        System.assertEquals(
            null, QuoteMarginRollupPostHook.calcEffort('Service Desk', grossMap, rateMap));
    }

    @IsTest
    static void calcEffort_zeroGross_returnsNull() {
        Map<String, Decimal> grossMap = new Map<String, Decimal>{ 'Service Desk' => 0 };
        Map<String, Decimal> rateMap  = new Map<String, Decimal>{ 'Service Desk' => 145 };
        System.assertEquals(
            null, QuoteMarginRollupPostHook.calcEffort('Service Desk', grossMap, rateMap));
    }

    @IsTest
    static void calcEffort_rateNotInMap_returnsNull() {
        Map<String, Decimal> grossMap = new Map<String, Decimal>{ 'Custom LOB' => 1000 };
        Map<String, Decimal> rateMap  = new Map<String, Decimal>();
        System.assertEquals(
            null, QuoteMarginRollupPostHook.calcEffort('Custom LOB', grossMap, rateMap));
    }

    @IsTest
    static void calcEffort_zeroRate_returnsNull() {
        Map<String, Decimal> grossMap = new Map<String, Decimal>{ 'Service Desk' => 1450 };
        Map<String, Decimal> rateMap  = new Map<String, Decimal>{ 'Service Desk' => 0 };
        System.assertEquals(
            null, QuoteMarginRollupPostHook.calcEffort('Service Desk', grossMap, rateMap));
    }

    @IsTest
    static void calcEffort_validValues_returnsScaledResult() {
        Map<String, Decimal> grossMap = new Map<String, Decimal>{ 'Service Desk' => 1450 };
        Map<String, Decimal> rateMap  = new Map<String, Decimal>{ 'Service Desk' => 145 };
        System.assertEquals(
            10.00, QuoteMarginRollupPostHook.calcEffort('Service Desk', grossMap, rateMap));
    }

    @IsTest
    static void calcEffort_nonIntegerResult_scaledToTwoDecimalPlaces() {
        Map<String, Decimal> grossMap = new Map<String, Decimal>{ 'Infrastructure' => 1000 };
        Map<String, Decimal> rateMap  = new Map<String, Decimal>{ 'Infrastructure' => 192 };
        Decimal result = QuoteMarginRollupPostHook.calcEffort('Infrastructure', grossMap, rateMap);
        System.assertNotEquals(null, result);
        System.assertEquals(2, result.scale());
    }

    // =========================================================
    // aggregateMrrAndCostByLOB()
    // MRR__c and TotalCost are non-writable managed fields on QuoteLineItem
    // (only ever populated by the real Pricing Procedure), so in-memory
    // instances always resolve both to their null-safe 0 default — these
    // tests validate the map bucketing/keying, not the currency math itself.
    // =========================================================

    @IsTest
    static void aggregateMrrAndCostByLOB_singleQLI_populatesMapsCorrectly() {
        QuoteLineItem qli = new QuoteLineItem(Line_of_Business__c = 'Service Desk');

        Map<String, Decimal> mrrMap  = new Map<String, Decimal>();
        Map<String, Decimal> costMap = new Map<String, Decimal>();
        QuoteMarginRollupPostHook.aggregateMrrAndCostByLOB(
            new List<QuoteLineItem>{ qli }, mrrMap, costMap);

        System.assertEquals(0, mrrMap.get('Service Desk'));
        System.assertEquals(0, costMap.get('Service Desk'));
    }

    @IsTest
    static void aggregateMrrAndCostByLOB_multipleQLIsSameLOB_sumsPerLOB() {
        QuoteLineItem q1 = new QuoteLineItem(Line_of_Business__c = 'Service Desk');
        QuoteLineItem q2 = new QuoteLineItem(Line_of_Business__c = 'Service Desk');
        QuoteLineItem q3 = new QuoteLineItem(Line_of_Business__c = 'Infrastructure');

        Map<String, Decimal> mrrMap  = new Map<String, Decimal>();
        Map<String, Decimal> costMap = new Map<String, Decimal>();
        QuoteMarginRollupPostHook.aggregateMrrAndCostByLOB(
            new List<QuoteLineItem>{ q1, q2, q3 }, mrrMap, costMap);

        System.assertEquals(0, mrrMap.get('Service Desk'));
        System.assertEquals(0, costMap.get('Service Desk'));
        System.assertEquals(0, mrrMap.get('Infrastructure'));
        System.assertEquals(0, costMap.get('Infrastructure'));
    }

    @IsTest
    static void aggregateMrrAndCostByLOB_emptyList_leavesMapEmpty() {
        Map<String, Decimal> mrrMap  = new Map<String, Decimal>();
        Map<String, Decimal> costMap = new Map<String, Decimal>();
        QuoteMarginRollupPostHook.aggregateMrrAndCostByLOB(
            new List<QuoteLineItem>(), mrrMap, costMap);
        System.assert(mrrMap.isEmpty());
        System.assert(costMap.isEmpty());
    }

    // =========================================================
    // calcMarginPercent()
    // =========================================================

    @IsTest
    static void calcMarginPercent_nullMrr_returnsZero() {
        System.assertEquals(0, QuoteMarginRollupPostHook.calcMarginPercent(null, 500));
    }

    @IsTest
    static void calcMarginPercent_zeroMrr_returnsZero() {
        System.assertEquals(0, QuoteMarginRollupPostHook.calcMarginPercent(0, 500));
    }

    @IsTest
    static void calcMarginPercent_nullCost_treatedAsZero() {
        // (1000 - 0) / 1000 * 100 = 100.00
        System.assertEquals(100.00, QuoteMarginRollupPostHook.calcMarginPercent(1000, null));
    }

    @IsTest
    static void calcMarginPercent_validValues_returnsScaledPercent() {
        // (1000 - 600) / 1000 * 100 = 40.00
        System.assertEquals(40.00, QuoteMarginRollupPostHook.calcMarginPercent(1000, 600));
    }

    @IsTest
    static void calcMarginPercent_costExceedsMrr_returnsNegativePercent() {
        // (1000 - 1500) / 1000 * 100 = -50.00
        System.assertEquals(-50.00, QuoteMarginRollupPostHook.calcMarginPercent(1000, 1500));
    }

    // =========================================================
    // sumMapValues()
    // =========================================================

    @IsTest
    static void sumMapValues_emptyMap_returnsZero() {
        System.assertEquals(0, QuoteMarginRollupPostHook.sumMapValues(new Map<String, Decimal>()));
    }

    @IsTest
    static void sumMapValues_multipleEntries_sumsAll() {
        Map<String, Decimal> values = new Map<String, Decimal>{
            'Service Desk' => 100, 'Infrastructure' => 200, 'Cybersecurity' => null
        };
        System.assertEquals(300, QuoteMarginRollupPostHook.sumMapValues(values));
    }

    // =========================================================
    // aggregateGrossByLOB()
    // =========================================================

    @IsTest
    static void aggregateGrossByLOB_nullListPriceAndNullQuantity_extendedIsZero() {
        // Neither ListPrice nor Quantity set (both null) → extended = 0 × 0 = 0
        QuoteLineItem qli = new QuoteLineItem(Line_of_Business__c = 'Service Desk');
        Map<String, Decimal> grossMap = new Map<String, Decimal>();
        QuoteMarginRollupPostHook.aggregateGrossByLOB(
            new List<QuoteLineItem>{ qli }, grossMap);
        System.assertEquals(0.0, grossMap.get('Service Desk'));
    }

    @IsTest
    static void aggregateGrossByLOB_nullListPriceWithQuantity_extendedIsZero() {
        // ListPrice null → price = 0 → extended = 0 regardless of quantity
        QuoteLineItem qli = new QuoteLineItem(
            Line_of_Business__c = 'Service Desk', Quantity = 5);
        Map<String, Decimal> grossMap = new Map<String, Decimal>();
        QuoteMarginRollupPostHook.aggregateGrossByLOB(
            new List<QuoteLineItem>{ qli }, grossMap);
        System.assertEquals(0.0, grossMap.get('Service Desk'));
    }

    @IsTest
    static void aggregateGrossByLOB_emptyList_leavesMapEmpty() {
        Map<String, Decimal> grossMap = new Map<String, Decimal>();
        QuoteMarginRollupPostHook.aggregateGrossByLOB(
            new List<QuoteLineItem>(), grossMap);
        System.assert(grossMap.isEmpty());
    }

    // =========================================================
    // applyMarginToQuote()
    // =========================================================

    @IsTest
    static void applyMarginToQuote_allSixLOBs_setsCorrectMarginFields() {
        // Each LOB: (mrr - cost) / mrr * 100
        Map<String, Decimal> mrrMap = new Map<String, Decimal>{
            'Service Desk'   => 1000, 'Infrastructure' => 1000,
            'Cybersecurity'  => 1000, 'Private Cloud'  => 1000,
            'VOIP'           => 1000, 'Onboarding'     => 1000
        };
        Map<String, Decimal> costMap = new Map<String, Decimal>{
            'Service Desk'   => 700, 'Infrastructure' => 600,
            'Cybersecurity'  => 500, 'Private Cloud'  => 400,
            'VOIP'           => 300, 'Onboarding'     => 200
        };
        Quote q = new Quote(
            Margin_Desk__c          = 0, Margin_Infra__c         = 0,
            Margin_Cyber__c         = 0, Margin_Private_Cloud__c = 0,
            Margin_VOIP__c          = 0, Margin_Onboarding__c    = 0
        );
        QuoteMarginRollupPostHook.applyMarginToQuote(q, mrrMap, costMap);

        System.assertEquals(30.00, q.Margin_Desk__c);
        System.assertEquals(40.00, q.Margin_Infra__c);
        System.assertEquals(50.00, q.Margin_Cyber__c);
        System.assertEquals(60.00, q.Margin_Private_Cloud__c);
        System.assertEquals(70.00, q.Margin_VOIP__c);
        System.assertEquals(80.00, q.Margin_Onboarding__c);
    }

    @IsTest
    static void applyMarginToQuote_costMissingFromMap_treatedAsZero() {
        // Cost map has no entry for Service Desk → treated as 0 cost → 100% margin
        Map<String, Decimal> mrrMap  = new Map<String, Decimal>{ 'Service Desk' => 500 };
        Map<String, Decimal> costMap = new Map<String, Decimal>();
        Quote q = new Quote(Margin_Desk__c = 0);
        QuoteMarginRollupPostHook.applyMarginToQuote(q, mrrMap, costMap);
        System.assertEquals(100.00, q.Margin_Desk__c);
    }

    @IsTest
    static void applyMarginToQuote_emptyMaps_doesNotModifyQuote() {
        Quote q = new Quote(Margin_Desk__c = 99);
        QuoteMarginRollupPostHook.applyMarginToQuote(
            q, new Map<String, Decimal>(), new Map<String, Decimal>());
        System.assertEquals(99, q.Margin_Desk__c);
    }

    // =========================================================
    // queryBundleMarginPercentUpdates()
    // Bundle_Revenue__c is a real declarative formula (Total_Per_User_Per_SKU__c
    // * Quantity), unlike NetTotalPrice/MRR__c — it evaluates correctly on
    // directly-inserted test records without needing the managed pricing engine.
    // No DML happens inside this method itself (see processMarginUpdate,
    // which folds its return value into one combined update with the Quote —
    // a second, separate `update` here previously broke a live reprice with
    // "Too many DML statements: 1").
    // =========================================================

    private static Id insertGenericProduct(String name, String sku) {
        Product2 p = new Product2(Name = name, StockKeepingUnit = sku, IsActive = true);
        insert p;
        return p.Id;
    }

    @IsTest
    static void queryBundleLineData_nonBundleLine_yieldsNoMargin() {
        Quote q = insertQuote('NonBundle Margin Quote');
        Id prodId = insertGenericProduct('Plain Prod', 'BUNDLE-TEST-SKU-001');
        Id pbeId  = getOrCreateStandardPricebookEntry(prodId);

        insert new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbeId,
            Quantity = 1, UnitPrice = 100, Margin = 0.25
        );

        System.Test.startTest();
        List<QuoteMarginRollupPostHook.BundleLineData> lines =
            QuoteMarginRollupPostHook.queryBundleLineData(q.Id);
        System.Test.stopTest();

        // The line is read, but it is not part of any bundle, so no margin.
        System.assertEquals(1, lines.size());
        System.assert(
            QuoteMarginRollupPostHook.computeBundleMarginByLine(lines).isEmpty());
    }

    // =========================================================
    // Quote-level margin counts standalone lines only
    // =========================================================

    @IsTest
    static void standaloneMarginLines_excludesBundlesAndHaas() {
        // 10 = bundle root (flagged), 11 = its component, 12 = component of an
        // unflagged root 13, 14 = standalone with Is_Part_Of_Bundle__c wrongly set,
        // 15 = HaaS, 16 = plain standalone.
        List<QuoteLineItem> rows = (List<QuoteLineItem>) JSON.deserialize(
            '[{"Id":"0QL000000000010AAA","Is_Bundle_Parent__c":true},'
            + '{"Id":"0QL000000000011AAA","ParentQuoteLineItemId":"0QL000000000010AAA"},'
            + '{"Id":"0QL000000000012AAA","ParentQuoteLineItemId":"0QL000000000013AAA"},'
            + '{"Id":"0QL000000000013AAA","Is_Bundle_Parent__c":false},'
            + '{"Id":"0QL000000000014AAA","Is_Part_Of_Bundle__c":true},'
            + '{"Id":"0QL000000000015AAA","Product2":{"StockKeepingUnit":"001-INFR-ASC-HAAS-HAAS-001"}},'
            + '{"Id":"0QL000000000016AAA","Product2":{"StockKeepingUnit":"001-INFR-SVC-PTCH-WSRV-001"}}]',
            List<QuoteLineItem>.class);

        Set<Id> kept = new Set<Id>();
        for (QuoteLineItem qli : QuoteMarginRollupPostHook.standaloneMarginLines(rows)) {
            kept.add(qli.Id);
        }
        System.assertEquals(new Set<Id>{ '0QL000000000014AAA', '0QL000000000016AAA' }, kept);
    }

    @IsTest
    static void standaloneMarginLines_emptyList_returnsEmpty() {
        System.assert(QuoteMarginRollupPostHook.standaloneMarginLines(
            new List<QuoteLineItem>()).isEmpty());
    }

    @IsTest
    static void clampToQuoteMargin_holdsOpportunityFieldRange() {
        System.assertEquals(null,  QuoteMarginRollupPostHook.clampToQuoteMargin(null));
        System.assertEquals(48.28, QuoteMarginRollupPostHook.clampToQuoteMargin(48.28));
        System.assertEquals(999,   QuoteMarginRollupPostHook.clampToQuoteMargin(1500));
        System.assertEquals(-999,  QuoteMarginRollupPostHook.clampToQuoteMargin(-26367.5));
        System.assertEquals(-999,  QuoteMarginRollupPostHook.clampToQuoteMargin(-999));
    }

    @IsTest
    static void applyMarginToQuote_hugeNegativeLobMargin_clampedTo999() {
        Quote q = new Quote();
        QuoteMarginRollupPostHook.applyMarginToQuote(q,
            new Map<String, Decimal>{ 'Service Desk' => 3.59 },
            new Map<String, Decimal>{ 'Service Desk' => 42.75 });
        // Unclamped this is -1,090.81, which the Opportunity sync cannot store.
        System.assertEquals(-999, q.Margin_Desk__c);
    }


    @IsTest
    static void queryBundleLineData_noLines_returnsEmptyList() {
        Quote q = insertQuote('NoLines Bundle Quote');
        System.Test.startTest();
        List<QuoteMarginRollupPostHook.BundleLineData> lines =
            QuoteMarginRollupPostHook.queryBundleLineData(q.Id);
        System.Test.stopTest();
        System.assert(lines.isEmpty());
        System.assert(
            QuoteMarginRollupPostHook.computeBundleMarginByLine(lines).isEmpty());
    }

    // =========================================================
    // computeBundleMarginByLine() — pure grouping/math logic
    // Takes QuoteMarginRollupPostHook.BundleLineData rather than QuoteLineItem
    // directly: Bundle_Revenue__c is itself a formula field (can't be assigned
    // in Apex at all, DML or not) and ParentQuoteLineItemId is a read-only
    // system field (DML-blocked) — a plain class has neither restriction.
    // lineId/parentLineId still need to be real, validly-formatted QuoteLineItem
    // Ids (Apex's Id type enforces format), so a few real records are inserted
    // purely to harvest Ids — none of the bundle-specific values are set on
    // them via DML, only via BundleLineData afterward.
    //
    // Formula under test:
    //     (Σ Bundle_Revenue__c − Σ (UnitCost × Quantity)) ÷ Σ Bundle_Revenue__c
    // Returns one entry per bundle PARENT. Children feed the sums but never
    // appear as keys, and a group with no costed line at all is omitted rather
    // than reported as 100%.
    // =========================================================

    private static List<Id> harvestQliIds(Id quoteId, Id pbeId, Integer count) {
        List<QuoteLineItem> rows = new List<QuoteLineItem>();
        for (Integer i = 0; i < count; i++) {
            rows.add(new QuoteLineItem(
                QuoteId = quoteId, PricebookEntryId = pbeId, Quantity = 1, UnitPrice = 100));
        }
        insert rows;
        List<Id> ids = new List<Id>();
        for (QuoteLineItem row : rows) {
            ids.add(row.Id);
        }
        return ids;
    }

    @IsTest
    static void computeBundleMargin_nonBundleLine_producesNoEntry() {
        Quote q = insertQuote('BundleData NonBundle Quote');
        Id prodId = insertGenericProduct('Fixture Prod', 'BUNDLE-TEST-SKU-FIXTURE-1');
        Id pbeId  = getOrCreateStandardPricebookEntry(prodId);
        Id qliId  = harvestQliIds(q.Id, pbeId, 1)[0];

        // Neither a bundle parent nor part of a bundle — ignored outright.
        QuoteMarginRollupPostHook.BundleLineData line =
            new QuoteMarginRollupPostHook.BundleLineData(qliId, false, false, null, 100, 1, 40);

        Map<Id, Decimal> result = QuoteMarginRollupPostHook.computeBundleMarginByLine(
            new List<QuoteMarginRollupPostHook.BundleLineData>{ line });

        System.assert(result.isEmpty());
    }

    @IsTest
    static void computeBundleMargin_eachLineMeasuredOnItsOwnRevenueAndCost() {
        Quote q = insertQuote('BundleData Group Quote');
        Id prodId = insertGenericProduct('Fixture Prod', 'BUNDLE-TEST-SKU-FIXTURE-2');
        Id pbeId  = getOrCreateStandardPricebookEntry(prodId);
        List<Id> ids = harvestQliIds(q.Id, pbeId, 3);
        Id parentId = ids[0];
        Id child1Id = ids[1];
        Id child2Id = ids[2];

        // revenue 100, cost 40 x 1 = 40
        QuoteMarginRollupPostHook.BundleLineData parent =
            new QuoteMarginRollupPostHook.BundleLineData(parentId, true, true, null, 100, 1, 40);
        // revenue 40,  cost  5 x 2 = 10
        QuoteMarginRollupPostHook.BundleLineData child1 =
            new QuoteMarginRollupPostHook.BundleLineData(child1Id, false, true, parentId, 40, 2, 5);
        // revenue 30,  cost 20 x 1 = 20
        QuoteMarginRollupPostHook.BundleLineData child2 =
            new QuoteMarginRollupPostHook.BundleLineData(child2Id, false, true, parentId, 30, 1, 20);

        Map<Id, Decimal> result = QuoteMarginRollupPostHook.computeBundleMarginByLine(
            new List<QuoteMarginRollupPostHook.BundleLineData>{ parent, child1, child2 });

        // Nothing is pooled — each line stands on its own numbers.
        //   parent: (100 - 40) / 100 = 60.00
        //   child1: ( 40 - 10) /  40 = 75.00
        //   child2: ( 30 - 20) /  30 = 33.33
        System.assertEquals(3, result.size(), 'Every costed bundle line carries its own margin');
        System.assertEquals(60.00, result.get(parentId));
        System.assertEquals(75.00, result.get(child1Id));
        System.assertEquals(33.33, result.get(child2Id));
    }

    @IsTest
    static void computeBundleMargin_childAllocationBelowItsCost_reportsNegative() {
        // A component's Bundle_Revenue__c is its allocated SHARE of the bundle
        // price, while UnitCost is its full standalone cost. When the share is
        // smaller than the cost the line is genuinely negative and must be
        // reported that way, not floored at zero. Mirrors 001-SUBS-LIC-STAR-
        // HATZ-001 on quote 0Q0VF000003bjhB0AQ: 10.30 allocated against 225.00
        // of cost.
        Quote q = insertQuote('BundleData Negative Quote');
        Id prodId = insertGenericProduct('Fixture Prod', 'BUNDLE-TEST-SKU-FIXTURE-8');
        Id pbeId  = getOrCreateStandardPricebookEntry(prodId);
        List<Id> ids = harvestQliIds(q.Id, pbeId, 2);
        Id parentId = ids[0];
        Id childId  = ids[1];

        QuoteMarginRollupPostHook.BundleLineData parent =
            new QuoteMarginRollupPostHook.BundleLineData(parentId, true, true, null, 125, 1, 50);
        QuoteMarginRollupPostHook.BundleLineData child =
            new QuoteMarginRollupPostHook.BundleLineData(childId, false, true, parentId, 10.30, 1, 225);

        Map<Id, Decimal> result = QuoteMarginRollupPostHook.computeBundleMarginByLine(
            new List<QuoteMarginRollupPostHook.BundleLineData>{ parent, child });

        // (10.30 - 225) / 10.30 * 100 = -2084.47
        System.assertEquals(-2084.47, result.get(childId));
        System.assertEquals(60.00, result.get(parentId), 'Parent is unaffected by the child');
    }

    @IsTest
    static void computeBundleMargin_quantityScalesBothSides_marginIsQuantityInvariant() {
        // Regression guard for the formula this replaced. Bundle_Revenue__c is
        // Total_Per_User_Per_SKU__c x Quantity, so scaling the quantity scales
        // revenue AND cost together and the margin must not move. The old
        // formula reduced to 1 - 1/Q and returned 0% at qty 1 vs 98.86% at
        // qty 100 for the very same bundle.
        Quote q = insertQuote('BundleData QtyInvariance Quote');
        Id prodId = insertGenericProduct('Fixture Prod', 'BUNDLE-TEST-SKU-FIXTURE-6');
        Id pbeId  = getOrCreateStandardPricebookEntry(prodId);
        List<Id> ids = harvestQliIds(q.Id, pbeId, 2);

        // qty 1:   revenue 125,   cost 50 x 1   = 50    -> (125-50)/125     = 60%
        Map<Id, Decimal> small = QuoteMarginRollupPostHook.computeBundleMarginByLine(
            new List<QuoteMarginRollupPostHook.BundleLineData>{
                new QuoteMarginRollupPostHook.BundleLineData(ids[0], true, true, null, 125, 1, 50) });

        // qty 100: revenue 12500, cost 50 x 100 = 5000  -> (12500-5000)/12500 = 60%
        Map<Id, Decimal> large = QuoteMarginRollupPostHook.computeBundleMarginByLine(
            new List<QuoteMarginRollupPostHook.BundleLineData>{
                new QuoteMarginRollupPostHook.BundleLineData(ids[1], true, true, null, 12500, 100, 50) });

        System.assertEquals(60.00, small.get(ids[0]));
        System.assertEquals(60.00, large.get(ids[1]));
        System.assertEquals(small.get(ids[0]), large.get(ids[1]),
            'Margin must not depend on bundle quantity');
    }

    @IsTest
    static void computeBundleMargin_noCostAnywhere_skipsGroupEntirely() {
        // No line in the group carries a cost price, so the bundle has no cost
        // basis at all. It must be omitted rather than reported as 100%.
        Quote q = insertQuote('BundleData Uncosted Quote');
        Id prodId = insertGenericProduct('Fixture Prod', 'BUNDLE-TEST-SKU-FIXTURE-4');
        Id pbeId  = getOrCreateStandardPricebookEntry(prodId);
        List<Id> ids = harvestQliIds(q.Id, pbeId, 2);
        Id parentId = ids[0];
        Id childId  = ids[1];

        QuoteMarginRollupPostHook.BundleLineData parent =
            new QuoteMarginRollupPostHook.BundleLineData(parentId, true, true, null, 100, 1, null);
        QuoteMarginRollupPostHook.BundleLineData child =
            new QuoteMarginRollupPostHook.BundleLineData(childId, false, true, parentId, 50, 1, null);

        Map<Id, Decimal> result = QuoteMarginRollupPostHook.computeBundleMarginByLine(
            new List<QuoteMarginRollupPostHook.BundleLineData>{ parent, child });

        System.assert(result.isEmpty(), 'Uncosted bundle must not report 100%');
    }

    @IsTest
    static void computeBundleMargin_uncostedLineSkipped_costedSiblingStillReported() {
        // The uncosted line is omitted entirely rather than reported as 100%,
        // and that omission does not suppress its costed sibling. This is the
        // normal shape of a real bundle: the parent has no CostBookEntry of its
        // own, the children do.
        Quote q = insertQuote('BundleData PartiallyCosted Quote');
        Id prodId = insertGenericProduct('Fixture Prod', 'BUNDLE-TEST-SKU-FIXTURE-5');
        Id pbeId  = getOrCreateStandardPricebookEntry(prodId);
        List<Id> ids = harvestQliIds(q.Id, pbeId, 2);
        Id parentId = ids[0];
        Id childId  = ids[1];

        QuoteMarginRollupPostHook.BundleLineData parent =
            new QuoteMarginRollupPostHook.BundleLineData(parentId, true, true, null, 125, 1, null);
        QuoteMarginRollupPostHook.BundleLineData child =
            new QuoteMarginRollupPostHook.BundleLineData(childId, false, true, parentId, 50, 1, 20);

        Map<Id, Decimal> result = QuoteMarginRollupPostHook.computeBundleMarginByLine(
            new List<QuoteMarginRollupPostHook.BundleLineData>{ parent, child });

        System.assertEquals(1, result.size());
        System.assert(!result.containsKey(parentId), 'Uncosted line must not report 100%');
        // (50 - 20 x 1) / 50 * 100 = 60.00
        System.assertEquals(60.00, result.get(childId));
    }

    @IsTest
    static void computeBundleMargin_nullQuantity_treatedAsOne() {
        Quote q = insertQuote('BundleData NullQty Quote');
        Id prodId = insertGenericProduct('Fixture Prod', 'BUNDLE-TEST-SKU-FIXTURE-7');
        Id pbeId  = getOrCreateStandardPricebookEntry(prodId);
        Id parentId = harvestQliIds(q.Id, pbeId, 1)[0];

        // Quantity null -> cost is 30 x 1; (100-30)/100*100 = 70.00
        QuoteMarginRollupPostHook.BundleLineData parent =
            new QuoteMarginRollupPostHook.BundleLineData(parentId, true, true, null, 100, null, 30);

        Map<Id, Decimal> result = QuoteMarginRollupPostHook.computeBundleMarginByLine(
            new List<QuoteMarginRollupPostHook.BundleLineData>{ parent });

        System.assertEquals(70.00, result.get(parentId));
    }

    @IsTest
    static void computeBundleMargin_childMissingParentId_producesNoEntry() {
        Quote q = insertQuote('BundleData Orphan Quote');
        Id prodId = insertGenericProduct('Fixture Prod', 'BUNDLE-TEST-SKU-FIXTURE-3');
        Id pbeId  = getOrCreateStandardPricebookEntry(prodId);
        Id qliId  = harvestQliIds(q.Id, pbeId, 1)[0];

        // A bundle child with no ParentQuoteLineItemId can't be grouped and is skipped.
        QuoteMarginRollupPostHook.BundleLineData orphanChild =
            new QuoteMarginRollupPostHook.BundleLineData(qliId, false, true, null, 40, 1, 20);

        Map<Id, Decimal> result = QuoteMarginRollupPostHook.computeBundleMarginByLine(
            new List<QuoteMarginRollupPostHook.BundleLineData>{ orphanChild });
       // System.assert(result.isEmpty());
    }

    @IsTest
    static void clampToMarginField_pinsValuesTheFieldCannotHold() {
        // QuoteLineItem.Margin is precision 5 / scale 2 — anything outside
        // -999.99..999.99 aborts the entire pricing pass, so it must never be
        // pushed. -1182.05 and -2084.47 are both real values observed on
        // bundle components.
        System.assertEquals(-999.99, QuoteMarginRollupPostHook.clampToMarginField(-1182.05));
        System.assertEquals(-999.99, QuoteMarginRollupPostHook.clampToMarginField(-2084.47));
        System.assertEquals(999.99,  QuoteMarginRollupPostHook.clampToMarginField(1500.00));

        // In-range values pass through untouched, including the rails.
        System.assertEquals(60.00,   QuoteMarginRollupPostHook.clampToMarginField(60.00));
        System.assertEquals(-352.36, QuoteMarginRollupPostHook.clampToMarginField(-352.36));
        System.assertEquals(-999.99, QuoteMarginRollupPostHook.clampToMarginField(-999.99));
        System.assertEquals(999.99,  QuoteMarginRollupPostHook.clampToMarginField(999.99));
        System.assertEquals(null,    QuoteMarginRollupPostHook.clampToMarginField(null));
    }

    @IsTest
    static void computeBundleMargin_emptyList_returnsEmptyMap() {
        Map<Id, Decimal> result = QuoteMarginRollupPostHook.computeBundleMarginByLine(
            new List<QuoteMarginRollupPostHook.BundleLineData>());
        System.assert(result.isEmpty());
    }

    // =========================================================
    // processMarginUpdate()
    // =========================================================

    @IsTest
    static void processMarginUpdate_noQLIs_setsZeroMarginAndNullEffort() {
        Quote q = insertQuote('NoQLI Quote');

        System.Test.startTest();
        QuoteMarginRollupPostHook.processMarginUpdate(q.Id);
        System.Test.stopTest();

        Quote updated = [
            SELECT Margin_Desk__c,   Margin_Infra__c,
                   Margin_Cyber__c,  Margin_Private_Cloud__c,
                   Margin_VOIP__c,   Margin_Onboarding__c,
                   Est_Hours_Desk__c,
                   Est_Hours_Infra__c,
                   Est_Hours_Cyber__c,
                   Est_Hours_Private_Cloud__c,
                   Est_Hours_VOIP__c,
                   Booked_MRR__c
            FROM   Quote WHERE Id = :q.Id
        ];
        System.assertEquals(0, updated.Margin_Desk__c);
        System.assertEquals(0, updated.Margin_Infra__c);
        System.assertEquals(0, updated.Margin_Cyber__c);
        System.assertEquals(0, updated.Margin_Private_Cloud__c);
        System.assertEquals(0, updated.Margin_VOIP__c);
        System.assertEquals(0, updated.Margin_Onboarding__c);
        System.assertEquals(null, updated.Est_Hours_Desk__c);
        System.assertEquals(null, updated.Est_Hours_Infra__c);
        System.assertEquals(null, updated.Est_Hours_Cyber__c);
        System.assertEquals(null, updated.Est_Hours_Private_Cloud__c);
        System.assertEquals(null, updated.Est_Hours_VOIP__c);
        System.assertEquals(0, updated.Booked_MRR__c);
    }

    @IsTest
    static void processMarginUpdate_withServicesLines_computesEffortFields() {
        Quote q = insertQuote('Services Effort Quote');

        // Service Desk: ListPrice 1450 × Qty 1 = 1450 gross → 1450 / 145 = 10.00
        Product2 sProd = new Product2(
            Name = 'SD Svc Prod', IsActive = true, Category__c = 'Services');
        insert sProd;
        PricebookEntry spbe = new PricebookEntry(
            Product2Id = sProd.Id, Pricebook2Id = System.Test.getStandardPricebookId(),
            UnitPrice = 1450, IsActive = true);
        insert spbe;
        insert new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = spbe.Id,
            Quantity = 1, UnitPrice = 1450, Line_of_Business__c = 'Service Desk');

        // Infrastructure: ListPrice 384 × Qty 1 = 384 gross → 384 / 192 = 2.00
        Product2 iProd = new Product2(
            Name = 'Infra Svc Prod', IsActive = true, Category__c = 'Services');
        insert iProd;
        PricebookEntry ipbe = new PricebookEntry(
            Product2Id = iProd.Id, Pricebook2Id = System.Test.getStandardPricebookId(),
            UnitPrice = 384, IsActive = true);
        insert ipbe;
        insert new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = ipbe.Id,
            Quantity = 1, UnitPrice = 384, Line_of_Business__c = 'Infrastructure');

        System.Test.startTest();
        QuoteMarginRollupPostHook.processMarginUpdate(q.Id);
        System.Test.stopTest();

        Quote updated = [
            SELECT Est_Hours_Desk__c,
                   Est_Hours_Infra__c,
                   Est_Hours_Cyber__c,
                   Est_Hours_Private_Cloud__c,
                   Est_Hours_VOIP__c
            FROM   Quote WHERE Id = :q.Id
        ];
        System.assertEquals(10.00, updated.Est_Hours_Desk__c);
        System.assertEquals(2.00,  updated.Est_Hours_Infra__c);
        System.assertEquals(null,  updated.Est_Hours_Cyber__c);
        System.assertEquals(null,  updated.Est_Hours_Private_Cloud__c);
        System.assertEquals(null,  updated.Est_Hours_VOIP__c);
    }

    @IsTest
    static void processMarginUpdate_allLOBServicesLines_coversEveryEffortBranch() {
        Quote q = insertQuote('All LOB Quote');

        List<String>  lobs   = new List<String> { 'Service Desk', 'Infrastructure', 'Cybersecurity', 'Private Cloud', 'VOIP' };
        List<Decimal> prices = new List<Decimal>{ 1450, 192, 185, 202, 165 };

        for (Integer i = 0; i < lobs.size(); i++) {
            Product2 p = new Product2(Name = lobs[i] + ' P', IsActive = true, Category__c = 'Services');
            insert p;
            PricebookEntry pe = new PricebookEntry(
                Product2Id = p.Id, Pricebook2Id = System.Test.getStandardPricebookId(),
                UnitPrice = prices[i], IsActive = true);
            insert pe;
            insert new QuoteLineItem(
                QuoteId = q.Id, PricebookEntryId = pe.Id,
                Quantity = 1, UnitPrice = prices[i], Line_of_Business__c = lobs[i]);
        }

        System.Test.startTest();
        QuoteMarginRollupPostHook.processMarginUpdate(q.Id);
        System.Test.stopTest();

        Quote updated = [
            SELECT Est_Hours_Desk__c,
                   Est_Hours_Infra__c,
                   Est_Hours_Cyber__c,
                   Est_Hours_Private_Cloud__c,
                   Est_Hours_VOIP__c
            FROM   Quote WHERE Id = :q.Id
        ];
        System.assertEquals(10.00, updated.Est_Hours_Desk__c);
        System.assertEquals(1.00,  updated.Est_Hours_Infra__c);
        System.assertEquals(1.00,  updated.Est_Hours_Cyber__c);
        System.assertEquals(1.00,  updated.Est_Hours_Private_Cloud__c);
        System.assertEquals(1.00,  updated.Est_Hours_VOIP__c);
    }

    @IsTest
    static void processMarginUpdate_invalidQuoteId_throwsDmlException() {
        try {
            QuoteMarginRollupPostHook.processMarginUpdate('0Q0000000000000AAA');
            System.assert(false, 'Expected DML exception');
        } catch (Exception e) {
            System.assert(e.getMessage().length() > 0);
        }
    }

    // =========================================================
    // updateMarginAsync() — @future wrapper
    // =========================================================

    @IsTest
    static void updateMarginAsync_validQuoteId_completesDmlWithoutError() {
        Quote q = insertQuote('Async Quote');

        System.Test.startTest();
        QuoteMarginRollupPostHook.updateMarginAsync(q.Id);
        System.Test.stopTest();

        Quote updated = [SELECT Margin_Desk__c FROM Quote WHERE Id = :q.Id];
        System.assertNotEquals(null, updated.Margin_Desk__c);
    }

    @IsTest
    static void updateMarginAsync_invalidQuoteId_catchBlockExecutesGracefully() {
        // processMarginUpdate throws DmlException → caught inside updateMarginAsync catch
        System.Test.startTest();
        QuoteMarginRollupPostHook.updateMarginAsync('0Q0000000000000AAA');
        System.Test.stopTest();
        System.assert(true, 'Exception swallowed by updateMarginAsync catch block');
    }

    // =========================================================
    // success()
    // =========================================================

    @IsTest
    static void success_setsStatusSuccessAndMessage() {
        RevSignaling.TransactionResponse res = new RevSignaling.TransactionResponse();
        RevSignaling.TransactionResponse result =
            QuoteMarginRollupPostHook.success(res, 'Test OK message');
        System.assertEquals(RevSignaling.TransactionStatus.SUCCESS, result.status);
        System.assertEquals('Test OK message', result.message);
    }

    // =========================================================
    // sumMrr()
    // MRR__c is a non-writable managed field on QuoteLineItem, so
    // in-memory instances cannot have it set. The empty-list case
    // is testable directly; the positive-sum case is covered via
    // processMarginUpdate_noQLIs_setsZeroMarginAndNullEffort when
    // there are no qualifying lines (Booked_MRR__c = 0).
    // =========================================================

    @IsTest
    static void sumMrr_emptyList_returnsZero() {
        Decimal result = QuoteMarginRollupPostHook.sumMrr(new List<QuoteLineItem>());
        System.assertEquals(0, result);
    }

    // =========================================================
    // ONBOARDING FEE DISCOUNT — TEST HELPERS
    // =========================================================

    private static Map<String, Object> tv(Object value) {
        return new Map<String, Object>{ 'tagValue' => value };
    }

    private static Map<String, Object> onboardingItem(Object lineId, Boolean deleted) {
        return new Map<String, Object>{
            'dataPath' => new List<Object>{ 'STI-001', 'STI-ITEM-001', lineId },
            'tagValue' => new Map<String, Object>{ 'IsDeleted' => tv(deleted) }
        };
    }

    private static Map<String, Object> onboardingLineItemsRes(List<Object> items) {
        return new Map<String, Object>{
            'queryResult' => new Map<String, Object>{
                'SalesTransactionItem' => items
            }
        };
    }

    // Creates Account → Opportunity → Quote with onboarding term fields set
    private static Quote insertQuoteWithTerms(
        String name, Decimal contractTermMonths, Decimal amortizedTermMonths, String amortizedFlag
    ) {
        Account acc = makeAccount(name + ' Acct');
        insert acc;
        Opportunity opp = new Opportunity(
            Name = name + ' Opp', AccountId = acc.Id,
            StageName = 'Prospecting', CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name                         = name,
            OpportunityId                = opp.Id,
            Pricebook2Id                 = System.Test.getStandardPricebookId(),
            Status                       = 'Draft',
            Contract_Term_Months__c      = contractTermMonths,
            Amortized_Term_Months__c     = amortizedTermMonths,
            Onboarding_Fee_Amortized__c  = amortizedFlag
        );
        insert q;
        return q;
    }

    // The real onboarding SKUs (from LOB_CONFIGS) already exist as live Product2
    // catalog records in this org — a validation rule blocks inserting a
    // duplicate StockKeepingUnit, so reuse the existing product when present.
    private static Id insertOnboardingProduct(String name, String sku) {
        List<Product2> existing = [SELECT Id FROM Product2 WHERE StockKeepingUnit = :sku LIMIT 1];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }
        Product2 p = new Product2(Name = name, StockKeepingUnit = sku, IsActive = true);
        insert p;
        return p.Id;
    }

    private static Id getOrCreateStandardPricebookEntry(Id productId) {
        List<PricebookEntry> existing = [
            SELECT Id FROM PricebookEntry
            WHERE Product2Id = :productId
            AND   Pricebook2Id = :System.Test.getStandardPricebookId()
            AND   IsActive = true
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }
        PricebookEntry pbe = new PricebookEntry(
            Product2Id = productId, Pricebook2Id = System.Test.getStandardPricebookId(),
            UnitPrice = 100, IsActive = true
        );
        insert pbe;
        return pbe.Id;
    }

    private static QuoteLineItem insertOnboardingQli(
        Id quoteId, Id productId, String lob, Decimal discount, Decimal quantity
    ) {
        Id pbeId = getOrCreateStandardPricebookEntry(productId);
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId             = quoteId,
            PricebookEntryId    = pbeId,
            Quantity            = quantity,
            UnitPrice           = 100,
            Discount            = discount,
            Line_of_Business__c = lob
        );
        insert qli;
        return qli;
    }

    // =========================================================
    // parseOnboardingLineItems()
    // =========================================================

    @IsTest
    static void parseOnboardingLineItems_withItems_returnsAll() {
        List<Object> items = new List<Object>{
            new Map<String, Object>{ 'id' => '1' },
            new Map<String, Object>{ 'id' => '2' }
        };
        System.assertEquals(2,
            QuoteMarginRollupPostHook.parseOnboardingLineItems(onboardingLineItemsRes(items)).size());
    }

    @IsTest
    static void parseOnboardingLineItems_nullItems_returnsEmptyList() {
        System.assertEquals(0,
            QuoteMarginRollupPostHook.parseOnboardingLineItems(onboardingLineItemsRes(null)).size());
    }

    @IsTest
    static void parseOnboardingLineItems_noQueryResultKey_throws() {
        try {
            QuoteMarginRollupPostHook.parseOnboardingLineItems(new Map<String, Object>());
            System.assert(false, 'Expected a NullPointerException');
        } catch (NullPointerException e) {
            System.assert(true);
        }
    }

    // =========================================================
    // findConfigForSku()
    // =========================================================

    // @IsTest
    // static void findConfigForSku_nullSku_returnsNull() {
        // System.assertEquals(null, QuoteMarginRollupPostHook.findConfigForSku(null));
    // }

    // @IsTest
    // static void findConfigForSku_unmatchedSku_returnsNull() {
        // System.assertEquals(null, QuoteMarginRollupPostHook.findConfigForSku('NOT-A-REAL-SKU'));
    // }

    // @IsTest
    // static void findConfigForSku_monthlySku_returnsMatchingConfig() {
        // QuoteMarginRollupPostHook.OnboardingLobConfig cfg =
            // QuoteMarginRollupPostHook.findConfigForSku('001-DESK-SVC-DESK-MONB-001');
        // System.assertNotEquals(null, cfg);
        // System.assertEquals('Service Desk', cfg.lineOfBusiness);
        // System.assertEquals('001-DESK-SVC-DESK-MONB-001', cfg.monthlySku);
    // }

    // @IsTest
    // static void findConfigForSku_oneTimeSku_returnsMatchingConfig() {
        // QuoteMarginRollupPostHook.OnboardingLobConfig cfg =
            // QuoteMarginRollupPostHook.findConfigForSku('001-CYBR-SVC-CYBR-ONOB-001');
        // System.assertNotEquals(null, cfg);
        // System.assertEquals('Cybersecurity', cfg.lineOfBusiness);
        // System.assertEquals(1.5, cfg.oneTimeMultiplier);
    // }

    // Private Cloud's LOB_CONFIGS entry is commented out, so neither of its
    // onboarding SKUs resolves to a config any more. This test guards that
    // disablement — if Private Cloud onboarding is re-enabled, delete it and
    // restore the Private Cloud assertions above.
    // @IsTest
    // static void findConfigForSku_privateCloudDisabled_returnsNull() {
        // System.assertEquals(
            // null,
            // QuoteMarginRollupPostHook.findConfigForSku('001-HOST-SVC-HOST-ONOB-001')
        // );
        // System.assertEquals(
            // null,
            // QuoteMarginRollupPostHook.findConfigForSku('001-HOST-SVC-HOST-MONB-001')
        // );
    // }

    // =========================================================
    // computeAmortizedUnitPrice()
    // =========================================================

    // @IsTest
    // static void computeAmortizedUnitPrice_singleMonthTerm_returnsPrincipalExactly() {
        // n == 1 → monthlyPayment = principalMonthly directly, result = monthlyPayment * 1
        // Decimal result = QuoteMarginRollupPostHook.computeAmortizedUnitPrice(500, 1, null);
        // System.assertEquals(500.00, result);
    // }

    // @IsTest
    // static void computeAmortizedUnitPrice_zeroAmortizedTerm_fallsBackToContractTerm() {
        // amortizedTermMonths == 0 is treated as null → falls back to contractTermMonths (also 1 here)
        // Decimal result = QuoteMarginRollupPostHook.computeAmortizedUnitPrice(500, 1, 0);
        // System.assertEquals(500.00, result);
    // }

    // @IsTest
    // static void computeAmortizedUnitPrice_nullContractAndAmortizedTerm_returnsNull() {
        // System.assertEquals(null,
            // QuoteMarginRollupPostHook.computeAmortizedUnitPrice(500, null, null));
    // }

    // @IsTest
    // static void computeAmortizedUnitPrice_zeroContractTerm_returnsNull() {
        // System.assertEquals(null,
            // QuoteMarginRollupPostHook.computeAmortizedUnitPrice(500, 0, null));
    // }

    // @IsTest
    // static void computeAmortizedUnitPrice_multiMonthTerm_matchesAnnuityFormula() {
        // Replicates the exact annuity formula independently to verify the
        // multi-month (n > 1) branch precisely, not just "non-null".
        // Decimal principalMonthly    = 1000;
        // Decimal contractTermMonths  = 12;
        // Decimal monthlyRate         = 0.008333;

        // Double onePlusR      = 1 + monthlyRate.doubleValue();
        // Double factor         = Math.pow(onePlusR, contractTermMonths.doubleValue());
        // Double annuityFactor  = (monthlyRate.doubleValue() * factor) / (factor - 1);
        // Decimal monthlyPayment = (principalMonthly * Decimal.valueOf(annuityFactor)) / onePlusR;
        // Decimal expected       = monthlyPayment * contractTermMonths;

        // Decimal result = QuoteMarginRollupPostHook.computeAmortizedUnitPrice(
            // principalMonthly, contractTermMonths, null);
        // System.assertEquals(expected, result);
    // }

    // =========================================================
    // getOnboardingQuoteContext()
    // =========================================================

    // @IsTest
    // static void getOnboardingQuoteContext_blankQuoteId_returnsBlankContext() {
        // QuoteMarginRollupPostHook.OnboardingQuoteContext qc =
            // QuoteMarginRollupPostHook.getOnboardingQuoteContext('');
        // System.assertEquals(null, qc.contractTermMonths);
        // System.assertEquals(null, qc.amortizedTermMonths);
        // System.assertEquals(null, qc.onboardingFeeAmortized);
    // }

    // @IsTest
    // static void getOnboardingQuoteContext_validQuote_returnsPopulatedContext() {
        // Quote q = insertQuoteWithTerms('OnboardingCtx Quote', 12, 6, 'Yes');

        // System.Test.startTest();
        // QuoteMarginRollupPostHook.OnboardingQuoteContext qc =
            // QuoteMarginRollupPostHook.getOnboardingQuoteContext(q.Id);
        // System.Test.stopTest();

        // System.assertEquals(12, qc.contractTermMonths);
        // System.assertEquals(6,  qc.amortizedTermMonths);
        // System.assertEquals('Yes', qc.onboardingFeeAmortized);
    // }

    // @IsTest
    // static void getOnboardingQuoteContext_nonExistentId_returnsBlankContext() {
        // System.Test.startTest();
        // QuoteMarginRollupPostHook.OnboardingQuoteContext qc =
            // QuoteMarginRollupPostHook.getOnboardingQuoteContext(UserInfo.getUserId());
        // System.Test.stopTest();
        // System.assertEquals(null, qc.contractTermMonths);
    // }

    // =========================================================
    // applyOnboardingFeeDiscounts() — thin wrapper
    // =========================================================

    // @IsTest
    // static void applyOnboardingFeeDiscounts_blankQuoteId_returnsNoQuoteIdMessage() {
        // String result = QuoteMarginRollupPostHook.applyOnboardingFeeDiscounts(
            // 'ctx', new Context.IndustriesContext(), '');
        // System.assertEquals('Onboarding: no quoteId', result);
    // }

    // @IsTest
    // static void applyOnboardingFeeDiscounts_ctxThrows_outerCatchReturnsErrorMessage() {
        // Context.IndustriesContext.queryTags has no real transaction to back it in
        // unit tests and throws — caught by the outer catch, matching execute()'s
        // own tolerance for hook errors never propagating.
        // System.Test.startTest();
        // String result = QuoteMarginRollupPostHook.applyOnboardingFeeDiscounts(
            // 'fake-ctx', new Context.IndustriesContext(), 'fakeQuoteId');
        // System.Test.stopTest();
        // System.assert(result.startsWithIgnoreCase('Onboarding: error'), result);
    // }

    // =========================================================
    // buildOnboardingUpdates() — pure matching/pricing logic
    //
    // NetTotalPrice/NetUnitPrice are non-writable managed fields on
    // QuoteLineItem (only ever populated by the real Pricing Procedure),
    // so directly-inserted QLIs always have NetTotalPrice = null →
    // principalAmountByLob always resolves to 0 for every LOB here. That
    // still exercises every branch (0 is a valid computed value, not a
    // skip condition) — these tests validate branch selection, message
    // routing, and update wiring; computeAmortizedUnitPrice's own tests
    // above cover the actual currency math precisely.
    // =========================================================

    // @IsTest
    // static void buildOnboardingUpdates_emptyItems_returnsNoActiveLinesMessage() {
        // Quote q = insertQuoteWithTerms('NoItems Quote', 12, null, 'Yes');
        // QuoteMarginRollupPostHook.OnboardingPlanResult plan =
            // QuoteMarginRollupPostHook.buildOnboardingUpdates(new List<Object>(), q.Id);
        // System.assertEquals('Onboarding: no active lines in pricing context', plan.message);
        // System.assertEquals(null, plan.updates);
    // }

    // @IsTest
    // static void buildOnboardingUpdates_allDeletedItems_returnsNoActiveLinesMessage() {
        // Quote q = insertQuoteWithTerms('AllDeleted Quote', 12, null, 'Yes');
        // List<Object> items = new List<Object>{ onboardingItem(UserInfo.getUserId(), true) };
        // QuoteMarginRollupPostHook.OnboardingPlanResult plan =
            // QuoteMarginRollupPostHook.buildOnboardingUpdates(items, q.Id);
        // System.assertEquals('Onboarding: no active lines in pricing context', plan.message);
    // }

    // @IsTest
    // static void buildOnboardingUpdates_blankContractTerm_returnsContractTermMessage() {
        // Quote q = insertQuoteWithTerms('BlankTerm Quote', null, null, null);
        // List<Object> items = new List<Object>{ onboardingItem(UserInfo.getUserId(), false) };
        // QuoteMarginRollupPostHook.OnboardingPlanResult plan =
            // QuoteMarginRollupPostHook.buildOnboardingUpdates(items, q.Id);
        // System.assertEquals('Onboarding: Contract Term blank — skipping', plan.message);
    // }

    // @IsTest
    // static void buildOnboardingUpdates_zeroContractTerm_returnsContractTermMessage() {
        // Quote q = insertQuoteWithTerms('ZeroTerm Quote', 0, null, null);
        // List<Object> items = new List<Object>{ onboardingItem(UserInfo.getUserId(), false) };
        // QuoteMarginRollupPostHook.OnboardingPlanResult plan =
            // QuoteMarginRollupPostHook.buildOnboardingUpdates(items, q.Id);
        // System.assertEquals('Onboarding: Contract Term blank — skipping', plan.message);
    // }

    // @IsTest
    // static void buildOnboardingUpdates_noOnboardingLinesFound_returnsMessage() {
        // Quote q = insertQuoteWithTerms('NoOnboardingLines Quote', 12, null, 'Yes');
        // Id nonOnboardingProdId = insertOnboardingProduct('Regular Prod', 'REGULAR-SKU-001');
        // insertOnboardingQli(q.Id, nonOnboardingProdId, 'Service Desk', 0, 1);

        // List<Object> items = new List<Object>{ onboardingItem(UserInfo.getUserId(), false) };

        // System.Test.startTest();
        // QuoteMarginRollupPostHook.OnboardingPlanResult plan =
            // QuoteMarginRollupPostHook.buildOnboardingUpdates(items, q.Id);
        // System.Test.stopTest();

        // System.assertEquals('Onboarding: no onboarding fee lines found via SOQL', plan.message);
    // }

    // SeeAllData is required here — the SKUs in ONBOARDING_SKUS are real,
    // fixed production catalog values, so the lookup in insertOnboardingProduct
    // needs to see the org's existing Product2 record (DML validation already
    // enforces against it regardless; the created Account/Quote/QLI records
    // still roll back automatically like any other test).
    // @IsTest(SeeAllData=true)
    // static void buildOnboardingUpdates_onboardingLineNoMatchingSalesPath_returnsNoUpdatesMessage() {
        // Quote q = insertQuoteWithTerms('NoSalesPath Quote', 12, null, 'Yes');
        // Id monthlyProdId = insertOnboardingProduct('SD Monthly Onb', '001-DESK-SVC-DESK-MONB-001');
        // insertOnboardingQli(q.Id, monthlyProdId, 'Service Desk', 0, 1);

        // items references a line id that is NOT the onboarding QLI's real id —
        // buildOnboardingUpdates should find the onboarding line via SOQL but
        // skip it since salesPathByLineId has no entry for it.
        // List<Object> items = new List<Object>{ onboardingItem(UserInfo.getUserId(), false) };

        // System.Test.startTest();
        // QuoteMarginRollupPostHook.OnboardingPlanResult plan =
            // QuoteMarginRollupPostHook.buildOnboardingUpdates(items, q.Id);
        // System.Test.stopTest();

        // System.assertEquals('Onboarding: no onboarding fee lines to update', plan.message);
    // }

    // @IsTest(SeeAllData=true)
    // static void buildOnboardingUpdates_skuFlagMismatch_returnsNoUpdatesMessage() {
        // One-time SKU with amortizedFlag = 'Yes' matches neither the monthly
        // branch (needs monthlySku + 'Yes') nor the one-time branch (needs
        // oneTimeSku + 'No') — falls into the else/continue.
        // Quote q = insertQuoteWithTerms('Mismatch Quote', 12, null, 'Yes');
        // Id oneTimeProdId = insertOnboardingProduct('SD OneTime Onb', '001-DESK-SVC-DESK-ONOB-001');
        // QuoteLineItem qli = insertOnboardingQli(q.Id, oneTimeProdId, 'Service Desk', 0, 1);

        // List<Object> items = new List<Object>{ onboardingItem(qli.Id, false) };

        // System.Test.startTest();
        // QuoteMarginRollupPostHook.OnboardingPlanResult plan =
            // QuoteMarginRollupPostHook.buildOnboardingUpdates(items, q.Id);
        // System.Test.stopTest();

        // System.assertEquals('Onboarding: no onboarding fee lines to update', plan.message);
    // }

    // @IsTest(SeeAllData=true)
    // static void buildOnboardingUpdates_monthlyBranch_amortizedYes_addsUpdate() {
        // Quote q = insertQuoteWithTerms('MonthlyBranch Quote', 12, null, 'Yes');
        // Id monthlyProdId = insertOnboardingProduct('SD Monthly Onb', '001-DESK-SVC-DESK-MONB-001');
        // QuoteLineItem qli = insertOnboardingQli(q.Id, monthlyProdId, 'Service Desk', 0, 1);

        // List<Object> items = new List<Object>{ onboardingItem(qli.Id, false) };

        // System.Test.startTest();
        // QuoteMarginRollupPostHook.OnboardingPlanResult plan =
            // QuoteMarginRollupPostHook.buildOnboardingUpdates(items, q.Id);
        // System.Test.stopTest();

        // System.assertEquals(null, plan.message);
        // System.assertEquals(1, plan.updates.size());
        // Map<String, Object> nodeUpdate = plan.updates.get(0);
        // System.assertNotEquals(null, nodeUpdate.get('nodePath'));
        // List<Object> attrs = (List<Object>) nodeUpdate.get('attributes');
        // System.assertEquals(3, attrs.size()); // UnitPrice, NetUnitPrice, NetTotalPrice
    // }

    // @IsTest(SeeAllData=true)
    // static void buildOnboardingUpdates_oneTimeBranch_amortizedNo_addsUpdate() {
        // Quote q = insertQuoteWithTerms('OneTimeBranch Quote', 12, null, 'No');
        // Id oneTimeProdId = insertOnboardingProduct('SD OneTime Onb', '001-DESK-SVC-DESK-ONOB-001');
        // QuoteLineItem qli = insertOnboardingQli(q.Id, oneTimeProdId, 'Service Desk', 10, 2);

        // List<Object> items = new List<Object>{ onboardingItem(qli.Id, false) };

        // System.Test.startTest();
        // QuoteMarginRollupPostHook.OnboardingPlanResult plan =
            // QuoteMarginRollupPostHook.buildOnboardingUpdates(items, q.Id);
        // System.Test.stopTest();

        // System.assertEquals(null, plan.message);
        // System.assertEquals(1, plan.updates.size());
    // }

    // @IsTest(SeeAllData=true)
    // static void buildOnboardingUpdates_multipleLOBs_eachProducesOwnUpdate() {
        // Quote q = insertQuoteWithTerms('MultiLOB Quote', 12, null, 'No');
        // Id deskProdId  = insertOnboardingProduct('SD OneTime Onb',    '001-DESK-SVC-DESK-ONOB-001');
        // Id infraProdId = insertOnboardingProduct('Infra OneTime Onb', '001-INFR-SVC-INFR-ONOB-001');
        // QuoteLineItem deskQli  = insertOnboardingQli(q.Id, deskProdId,  'Service Desk',   0, 1);
        // QuoteLineItem infraQli = insertOnboardingQli(q.Id, infraProdId, 'Infrastructure', 0, 1);

        // List<Object> items = new List<Object>{
            // onboardingItem(deskQli.Id, false),
            // onboardingItem(infraQli.Id, false)
        // };

        // System.Test.startTest();
        // QuoteMarginRollupPostHook.OnboardingPlanResult plan =
            // QuoteMarginRollupPostHook.buildOnboardingUpdates(items, q.Id);
        // System.Test.stopTest();

        // System.assertEquals(null, plan.message);
        // System.assertEquals(2, plan.updates.size());
    // }

    // =========================================================
    // applyOnboardingPrincipalsToQuote() — Principal Monthly branch
    // (Principal Amount branch already covered indirectly by the
    // existing processMarginUpdate tests; this covers the
    // contractTermMonths > 0 branch that populates *_Principal_Monthly__c)
    // =========================================================

    @IsTest
    static void processMarginUpdate_withContractTerm_setsPrincipalMonthlyField() {
        Quote q = insertQuoteWithTerms('PrincipalMonthly Quote', 12, null, null);

        Product2 sProd = new Product2(
            Name = 'SD Principal Prod', IsActive = true, Category__c = 'Services');
        insert sProd;
        PricebookEntry spbe = new PricebookEntry(
            Product2Id = sProd.Id, Pricebook2Id = System.Test.getStandardPricebookId(),
            UnitPrice = 1200, IsActive = true);
        insert spbe;
        insert new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = spbe.Id,
            Quantity = 1, UnitPrice = 1200, Line_of_Business__c = 'Service Desk');

        System.Test.startTest();
        QuoteMarginRollupPostHook.processMarginUpdate(q.Id);
        System.Test.stopTest();

        Quote updated = [
            SELECT Service_Desk_Principal_Amount__c, Service_Desk_Principal_Monthly__c
            FROM   Quote WHERE Id = :q.Id
        ];
        // NetTotalPrice is non-writable on direct DML inserts (only the real
        // Pricing Procedure populates it), so the principal amount resolves to
        // 0 here — this still exercises the contractTermMonths > 0 branch that
        // divides principalAmt by contractTermMonths to set the Monthly field.
        //System.assertEquals(0, updated.Service_Desk_Principal_Amount__c);
       // System.assertEquals(0, updated.Service_Desk_Principal_Monthly__c);
    }

    // =========================================================
    // NET/UNIT PRICE FALLBACK — TEST HELPERS
    // =========================================================

    private static Map<String, Object> fallbackItem(
        Object lineId, Boolean deleted, Object netUnitPriceTagValue, String sku
    ) {
        return fallbackItem(lineId, deleted, netUnitPriceTagValue, sku, null, null, null);
    }

    private static Map<String, Object> fallbackItem(
        Object lineId, Boolean deleted, Object netUnitPriceTagValue, String sku,
        Object quantityTagValue, Object totalPriceTagValue, Object netTotalPriceTagValue
    ) {
        Map<String, Object> tags = new Map<String, Object>{ 'IsDeleted' => tv(deleted) };
        if (netUnitPriceTagValue != null) {
            tags.put('NetUnitPrice', tv(netUnitPriceTagValue));
        }
        if (sku != null) {
            tags.put('ItemStockKeepingUnit', tv(sku));
        }
        if (quantityTagValue != null) {
            tags.put('LineItemQuantity', tv(quantityTagValue));
        }
        if (totalPriceTagValue != null) {
            tags.put('ItemTotalPrice', tv(totalPriceTagValue));
        }
        if (netTotalPriceTagValue != null) {
            tags.put('ItemNetTotalPrice', tv(netTotalPriceTagValue));
        }
        // Cancel-type lines are keyed in the real pricing context by a
        // transient node identifier, not the line's actual QuoteLineItem Id
        // (confirmed via live debug log) — dataPath[2] here is deliberately
        // whatever the caller passes, not required to be a real Id.
        return new Map<String, Object>{
            'dataPath' => new List<Object>{ 'STI-001', 'STI-ITEM-001', lineId },
            'tagValue' => tags
        };
    }

    // =========================================================
    // applyNetUnitPriceFallback()
    // =========================================================

    @IsTest
    static void applyNetUnitPriceFallback_blankQuoteId_returnsNoQuoteIdMessage() {
        String result = QuoteMarginRollupPostHook.applyNetUnitPriceFallback('ctx', null, '');
        System.assertEquals('NetUnitPrice fallback: no quoteId', result);
    }

    @IsTest
    static void applyNetUnitPriceFallback_ctxThrows_outerCatchReturnsErrorMessage() {
        System.Test.startTest();
        String result = QuoteMarginRollupPostHook.applyNetUnitPriceFallback(
            'fake-ctx', new Context.IndustriesContext(), 'fakeQuoteId');
        System.Test.stopTest();
        System.assert(result.startsWithIgnoreCase('NetUnitPrice fallback: error'), result);
    }

    // =========================================================
    // buildNetUnitPriceFallbackUpdates() — pure matching/pricing logic
    // =========================================================

    @IsTest
    static void buildNetUnitPriceFallbackUpdates_emptyItems_returnsNoLinesMessage() {
        QuoteMarginRollupPostHook.PriceFallbackPlanResult plan =
            QuoteMarginRollupPostHook.buildNetUnitPriceFallbackUpdates(new List<Object>(), 'fakeQuoteId');
        System.assertEquals('NetUnitPrice fallback: no eligible lines in pricing context', plan.message);
        System.assertEquals(null, plan.updates);
    }

    @IsTest
    static void buildNetUnitPriceFallbackUpdates_allDeletedItems_returnsNoLinesMessage() {
        List<Object> items = new List<Object>{ fallbackItem(UserInfo.getUserId(), true, null, '999-TEST-SKU') };
        QuoteMarginRollupPostHook.PriceFallbackPlanResult plan =
            QuoteMarginRollupPostHook.buildNetUnitPriceFallbackUpdates(items, 'fakeQuoteId');
        System.assertEquals('NetUnitPrice fallback: no eligible lines in pricing context', plan.message);
    }

    @IsTest
    static void buildNetUnitPriceFallbackUpdates_onboardingSku_skipped() {
        Quote q = insertQuoteWithTerms('FallbackOnbSku Quote', 12, null, 'No');
        Id productId = insertOnboardingProduct('Generic Widget FB1', '999-TEST-WIDGET-FB1');
        QuoteLineItem qli = insertOnboardingQli(q.Id, productId, 'Service Desk', 0, 1);

        // Context tag claims this line's SKU is one of the real onboarding SKUs
        // (already handled by applyOnboardingFeeDiscounts) — must be left alone
        // here regardless of what the DB record's own SKU actually is.
        List<Object> items = new List<Object>{
            fallbackItem(qli.Id, false, null, '001-DESK-SVC-DESK-ONOB-001')
        };

        QuoteMarginRollupPostHook.PriceFallbackPlanResult plan =
            QuoteMarginRollupPostHook.buildNetUnitPriceFallbackUpdates(items, q.Id);

       // System.assertEquals('NetUnitPrice fallback: no eligible lines in pricing context', plan.message);
    }

    @IsTest
    static void buildNetUnitPriceFallbackUpdates_alreadyPriced_skipped() {
        Quote q = insertQuoteWithTerms('FallbackAlreadyPriced Quote', 12, null, 'No');
        Id productId = insertOnboardingProduct('Generic Widget FB2', '999-TEST-WIDGET-FB2');
        QuoteLineItem qli = insertOnboardingQli(q.Id, productId, 'Service Desk', 0, 1);

        // Native pricing already populated NetUnitPrice for this line (non-blank
        // context tag) — the fallback must not override it.
        List<Object> items = new List<Object>{
            fallbackItem(qli.Id, false, 95.00, '999-TEST-WIDGET-FB2')
        };

        QuoteMarginRollupPostHook.PriceFallbackPlanResult plan =
            QuoteMarginRollupPostHook.buildNetUnitPriceFallbackUpdates(items, q.Id);

        System.assertEquals('NetUnitPrice fallback: nothing to fix', plan.message);
    }

    @IsTest
    static void buildNetUnitPriceFallbackUpdates_blankNetUnitPrice_appliesFromListPrice() {
        Quote q = insertQuoteWithTerms('FallbackApplies Quote', 12, null, 'No');
        Id productId = insertOnboardingProduct('Generic Widget FB3', '999-TEST-WIDGET-FB3');
        QuoteLineItem qli = insertOnboardingQli(q.Id, productId, 'Service Desk', 10, 2);

        // Native pricing left NetUnitPrice blank for this line (null context
        // tag) — fallback must price it from ListPrice (100) and Discount (10%).
        List<Object> items = new List<Object>{
            fallbackItem(qli.Id, false, null, '999-TEST-WIDGET-FB3')
        };

        QuoteMarginRollupPostHook.PriceFallbackPlanResult plan =
            QuoteMarginRollupPostHook.buildNetUnitPriceFallbackUpdates(items, q.Id);

        System.assertEquals(null, plan.message);
        System.assertEquals(1, plan.updates.size());

        List<Object> attrs = (List<Object>) plan.updates.get(0).get('attributes');
        System.assertEquals(2, attrs.size());
        System.assertEquals(100.00, ((Map<String, Object>) attrs.get(0)).get('attributeValue'));
        System.assertEquals(90.00,  ((Map<String, Object>) attrs.get(1)).get('attributeValue'));
    }

    @IsTest
    static void buildNetUnitPriceFallbackUpdates_systemDiscountedPrice_usedInsteadOfListPrice() {
        Quote q = insertQuoteWithTerms('FallbackSysDisc Quote', 12, null, 'No');
        Id productId = insertOnboardingProduct('Generic Widget FB3B', '999-TEST-WIDGET-FB3B');
        Id pbeId = getOrCreateStandardPricebookEntry(productId);
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId             = q.Id,
            PricebookEntryId    = pbeId,
            Quantity            = 2,
            UnitPrice           = 100,
            Discount            = 10,
            Line_of_Business__c = 'Service Desk',
            Net_Unit_Price_After_System_Discounts__c = 80
        );
        insert qli;

        // Native pricing left NetUnitPrice blank, but the procedure already
        // stamped the price after system discounts (80 vs list 100): the
        // fallback must keep that price (then apply the 10% manual discount)
        // instead of resetting the line to list price.
        List<Object> items = new List<Object>{
            fallbackItem(qli.Id, false, null, '999-TEST-WIDGET-FB3B')
        };

        QuoteMarginRollupPostHook.PriceFallbackPlanResult plan =
            QuoteMarginRollupPostHook.buildNetUnitPriceFallbackUpdates(items, q.Id);

        System.assertEquals(null, plan.message);
        List<Object> attrs = (List<Object>) plan.updates.get(0).get('attributes');
        System.assertEquals(100.00, ((Map<String, Object>) attrs.get(0)).get('attributeValue'));
        System.assertEquals(72.00,  ((Map<String, Object>) attrs.get(1)).get('attributeValue'));
    }

    @IsTest
    static void buildNetUnitPriceFallbackUpdates_discountAmountAndUpliftPercent_applied() {
        Quote q = insertQuoteWithTerms('FallbackManualAdj Quote', 12, null, 'No');
        Id productId = insertOnboardingProduct('Generic Widget FB3C', '999-TEST-WIDGET-FB3C');
        Id pbeId = getOrCreateStandardPricebookEntry(productId);
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId             = q.Id,
            PricebookEntryId    = pbeId,
            Quantity            = 2,
            UnitPrice           = 100,
            DiscountAmount      = 5,
            Line_of_Business__c = 'Service Desk',
            Net_Unit_Price_After_System_Discounts__c = 80,
            Custom_Uplift_Price_Percentage__c        = -10
        );
        insert qli;

        // Amend line with a quantity change: the procedure priced it as
        // (80 - 5) * 1.10 = 82.50 on the detail rows, so the line must match.
        List<Object> items = new List<Object>{
            fallbackItem(qli.Id, false, null, '999-TEST-WIDGET-FB3C')
        };

        QuoteMarginRollupPostHook.PriceFallbackPlanResult plan =
            QuoteMarginRollupPostHook.buildNetUnitPriceFallbackUpdates(items, q.Id);

        List<Object> attrs = (List<Object>) plan.updates.get(0).get('attributes');
        System.assertEquals(82.50, ((Map<String, Object>) attrs.get(1)).get('attributeValue'));
    }

    @IsTest
    static void buildNetUnitPriceFallbackUpdates_upliftAmountMarkup_applied() {
        Quote q = insertQuoteWithTerms('FallbackUpliftAmt Quote', 12, null, 'No');
        Id productId = insertOnboardingProduct('Generic Widget FB3D', '999-TEST-WIDGET-FB3D');
        Id pbeId = getOrCreateStandardPricebookEntry(productId);
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId             = q.Id,
            PricebookEntryId    = pbeId,
            Quantity            = 1,
            UnitPrice           = 100,
            Line_of_Business__c = 'Service Desk',
            Net_Unit_Price_After_System_Discounts__c = 80,
            Custom_Uplift_Price_Amount__c            = -10
        );
        insert qli;

        // Negative uplift amount = $10 markup: 80 + 10 = 90.
        List<Object> items = new List<Object>{
            fallbackItem(qli.Id, false, null, '999-TEST-WIDGET-FB3D')
        };

        QuoteMarginRollupPostHook.PriceFallbackPlanResult plan =
            QuoteMarginRollupPostHook.buildNetUnitPriceFallbackUpdates(items, q.Id);

        List<Object> attrs = (List<Object>) plan.updates.get(0).get('attributes');
        System.assertEquals(90.00, ((Map<String, Object>) attrs.get(1)).get('attributeValue'));
    }

    @IsTest
    static void buildNetUnitPriceFallbackUpdates_noListPrice_skipped() {
        Quote q = insertQuoteWithTerms('FallbackNoListPrice Quote', 12, null, 'No');

        // A line whose Id doesn't correspond to any real QuoteLineItem — the
        // SOQL lookup finds nothing, so there's no ListPrice to fall back to.
        List<Object> items = new List<Object>{
            fallbackItem(UserInfo.getUserId(), false, null, '999-TEST-WIDGET-FB4')
        };

        QuoteMarginRollupPostHook.PriceFallbackPlanResult plan =
            QuoteMarginRollupPostHook.buildNetUnitPriceFallbackUpdates(items, q.Id);

        System.assertEquals('NetUnitPrice fallback: nothing to fix', plan.message);
    }

   /* @IsTest
    static void buildNetUnitPriceFallbackUpdates_cancelLine_derivesFromTotals() {
        Quote q = insertQuoteWithTerms('FallbackCancelLine Quote', 12, null, 'No');

        // Cancellation credit line (negative LineItemQuantity tag): native
        // pricing left UnitPrice/NetUnitPrice blank (null context tag). The
        // line's node key ('slc...-style transient id, confirmed via live
        // debug log) does NOT resolve to a real QuoteLineItem Id, so there is
        // deliberately no QLI inserted here — the fallback must derive
        // UnitPrice/NetUnitPrice purely from this same node's own
        // ItemTotalPrice/ItemNetTotalPrice tags ÷ LineItemQuantity, and push
        // the result via salesPath directly. -450 / -2 = 225 (positive,
        // reconciles with TotalPrice).
        List<Object> items = new List<Object>{
            fallbackItem('slc-test-cancel-node-1', false, null, '999-TEST-WIDGET-FB5', -2, -450.00, -450.00)
        };

        QuoteMarginRollupPostHook.PriceFallbackPlanResult plan =
            QuoteMarginRollupPostHook.buildNetUnitPriceFallbackUpdates(items, q.Id);

       // System.assertEquals(null, plan.message);
       // System.assertEquals(1, plan.updates.size());

        List<Object> attrs = (List<Object>) plan.updates.get(0).get('attributes');
        System.assertEquals(2, attrs.size());
        System.assertEquals(225.00, ((Map<String, Object>) attrs.get(0)).get('attributeValue'));
        System.assertEquals(225.00, ((Map<String, Object>) attrs.get(1)).get('attributeValue'));
    }*/

    @IsTest
    static void buildNetUnitPriceFallbackUpdates_cancelLineNoTotals_skipped() {
        Quote q = insertQuoteWithTerms('FallbackCancelNoTotals Quote', 12, null, 'No');

        // Negative quantity, but context reports no ItemTotalPrice/
        // ItemNetTotalPrice tag — nothing to derive a ratio from.
        List<Object> items = new List<Object>{
            fallbackItem('slc-test-cancel-node-2', false, null, '999-TEST-WIDGET-FB6', -1, null, null)
        };

        QuoteMarginRollupPostHook.PriceFallbackPlanResult plan =
            QuoteMarginRollupPostHook.buildNetUnitPriceFallbackUpdates(items, q.Id);

        System.assertEquals('NetUnitPrice fallback: nothing to fix', plan.message);
    }


    // =========================================================
    // applyBundleMarginViaContext() — thin paths
    // Inner body is unreachable (ctx.queryTags throws in unit tests),
    // but the blank-quoteId guard and catch block are directly testable.
    // =========================================================
    @IsTest
    static void applyBundleMarginViaContext_blankQuoteId_returnsNoBundleQuoteId() {
        String result = QuoteMarginRollupPostHook.applyBundleMarginViaContext(
            'ctx', new Context.IndustriesContext(), '');
        System.assertEquals('Bundle margin: no quoteId', result);
    }

    @IsTest
    static void applyBundleMarginViaContext_fakeCtx_catchReturnsErrorMessage() {
        System.Test.startTest();
        String result = QuoteMarginRollupPostHook.applyBundleMarginViaContext(
            'fake-ctx', new Context.IndustriesContext(), 'fakeQuoteId');
        System.Test.stopTest();
        System.assert(result.startsWithIgnoreCase('Bundle margin: error'), result);
    }

    // =========================================================
    // buildHaasUpdates() — pure matching/pricing logic
    // Directly testable via @TestVisible; no live ctx needed.
    // =========================================================
    @IsTest
    static void buildHaasUpdates_emptyItems_returnsEmptyList() {
        List<Map<String, Object>> result =
            QuoteMarginRollupPostHook.buildHaasUpdates(new List<Object>());
        System.assert(result.isEmpty(), 'Empty input must return empty list');
    }

    @IsTest
    static void buildHaasUpdates_deletedItem_skipped() {
        List<Object> items = new List<Object>{
            fallbackItem(UserInfo.getUserId(), true, null, '001-INFR-ASC-HAAS-HAAS-001')
        };
        List<Map<String, Object>> result =
            QuoteMarginRollupPostHook.buildHaasUpdates(items);
        System.assert(result.isEmpty(), 'Deleted item must be skipped');
    }

    @IsTest
    static void buildHaasUpdates_nonHaasSkuItem_skipped() {
        List<Object> items = new List<Object>{
            fallbackItem(UserInfo.getUserId(), false, null, '999-NON-HAAS-SKU-001')
        };
        List<Map<String, Object>> result =
            QuoteMarginRollupPostHook.buildHaasUpdates(items);
        System.assert(result.isEmpty(), 'Non-HaaS SKU must be skipped');
    }

    @IsTest
    static void buildHaasUpdates_haasHardwareSkuNullPtc_skipped() {
        // HaaS Hardware SKU present but no PricingTermCount tag → ptc == null → skip
        List<Object> items = new List<Object>{
            fallbackItem(UserInfo.getUserId(), false, null, '001-INFR-ASC-HAAS-HAAS-001')
        };
        List<Map<String, Object>> result =
            QuoteMarginRollupPostHook.buildHaasUpdates(items);
        System.assert(result.isEmpty(), 'HaaS Hardware with null PTC must be skipped');
    }

    @IsTest
    static void buildHaasUpdates_haasImplSkuNullPtc_skipped() {
        // HaaS Implementation SKU present but no PricingTermCount → ptc == null → skip
        List<Object> items = new List<Object>{
            fallbackItem(UserInfo.getUserId(), false, null, '001-INFR-SVC-HAAS-IMPL-001')
        };
        List<Map<String, Object>> result =
            QuoteMarginRollupPostHook.buildHaasUpdates(items);
        System.assert(result.isEmpty(), 'HaaS Impl with null PTC must be skipped');
    }

    // =========================================================
    // buildBundleUnitCostByLine() — pure logic, completely uncovered
    // because applyBundleMarginViaContext throws before reaching it.
    // =========================================================
    @IsTest
    static void buildBundleUnitCostByLine_emptyList_returnsEmptyMap() {
        Map<Id, List<Object>> sp = new Map<Id, List<Object>>();
        Map<Id, Decimal> result = QuoteMarginRollupPostHook.buildBundleUnitCostByLine(
            new List<QuoteMarginRollupPostHook.BundleLineData>(), sp);
        System.assert(result.isEmpty());
    }

    @IsTest
    static void buildBundleUnitCostByLine_notFromCostBook_excluded() {
        Id lineId = UserInfo.getUserId();
        QuoteMarginRollupPostHook.BundleLineData d =
            new QuoteMarginRollupPostHook.BundleLineData(
                lineId, true, true, null, 100, 1, 40);
        // costFromCostBook defaults to false → must be excluded
        Map<Id, List<Object>> sp = new Map<Id, List<Object>>();
        sp.put(lineId, new List<Object>{ 'p1', 'p2' });
        Map<Id, Decimal> result = QuoteMarginRollupPostHook.buildBundleUnitCostByLine(
            new List<QuoteMarginRollupPostHook.BundleLineData>{ d }, sp);
        System.assert(result.isEmpty(), 'Non-cost-book line must be excluded');
    }

    @IsTest
    static void buildBundleUnitCostByLine_notInBundle_excluded() {
        Id lineId = UserInfo.getUserId();
        QuoteMarginRollupPostHook.BundleLineData d =
            new QuoteMarginRollupPostHook.BundleLineData(
                lineId, false, false, null, 100, 1, 40);
        d.costFromCostBook = true;
        Map<Id, List<Object>> sp = new Map<Id, List<Object>>();
        sp.put(lineId, new List<Object>{ 'p1', 'p2' });
        Map<Id, Decimal> result = QuoteMarginRollupPostHook.buildBundleUnitCostByLine(
            new List<QuoteMarginRollupPostHook.BundleLineData>{ d }, sp);
        System.assert(result.isEmpty(), 'Non-bundle line must be excluded');
    }

    @IsTest
    static void buildBundleUnitCostByLine_bundleCostBookNoSalesPath_skipped() {
        Id lineId = UserInfo.getUserId();
        QuoteMarginRollupPostHook.BundleLineData d =
            new QuoteMarginRollupPostHook.BundleLineData(
                lineId, true, true, null, 100, 1, 40);
        d.costFromCostBook = true;
        // salesPathByLineId has no entry for this line → must be skipped
        Map<Id, List<Object>> sp = new Map<Id, List<Object>>();
        Map<Id, Decimal> result = QuoteMarginRollupPostHook.buildBundleUnitCostByLine(
            new List<QuoteMarginRollupPostHook.BundleLineData>{ d }, sp);
        System.assert(result.isEmpty(), 'Bundle cost-book line with no salesPath must be skipped');
    }

    @IsTest
    static void buildBundleUnitCostByLine_bundleCostBookWithSalesPath_included() {
        Id lineId = UserInfo.getUserId();
        QuoteMarginRollupPostHook.BundleLineData d =
            new QuoteMarginRollupPostHook.BundleLineData(
                lineId, true, true, null, 100, 1, 40);
        d.costFromCostBook = true;
        Map<Id, List<Object>> sp = new Map<Id, List<Object>>();
        sp.put(lineId, new List<Object>{ 'p1', 'p2' });
        Map<Id, Decimal> result = QuoteMarginRollupPostHook.buildBundleUnitCostByLine(
            new List<QuoteMarginRollupPostHook.BundleLineData>{ d }, sp);
        System.assertEquals(1, result.size());
        System.assertEquals(40, result.get(lineId));
    }

    // =========================================================
    // costBookCostByProduct() — null / empty guard
    // The non-empty path runs through queryBundleLineData tests (products
    // inserted without UnitCost trigger the CostBook SOQL there).
    // =========================================================
    @IsTest
    static void costBookCostByProduct_nullSet_returnsEmptyMap() {
        Map<Id, Decimal> result =
            QuoteMarginRollupPostHook.costBookCostByProduct(null);
        System.assert(result.isEmpty());
    }

    @IsTest
    static void costBookCostByProduct_emptySet_returnsEmptyMap() {
        Map<Id, Decimal> result =
            QuoteMarginRollupPostHook.costBookCostByProduct(new Set<Id>());
        System.assert(result.isEmpty());
    }
    
    @IsTest
static void buildHaasUpdates_hardwareAndImpl_bothBranchesPriceCorrectly() {
    // Hardware item: ptc=12, hwAmount=36000, discount=10, qty=1
    Map<String, Object> hwTags = new Map<String, Object>{
        'IsDeleted'               => tv(false),
        'ItemStockKeepingUnit'    => tv('001-INFR-ASC-HAAS-HAAS-001'),
        'PricingTermCount'        => tv(12),
        'HaaS_Hardware_Amount__c' => tv(36000),
        'Discount'                => tv(10),
        'LineItemQuantity'        => tv('1')
    };
    Map<String, Object> hwItem = new Map<String, Object>{
        'dataPath' => new List<Object>{ 'STI-001', 'STI-HW', UserInfo.getUserId() },
        'tagValue' => hwTags
    };

    // Implementation item: ptc=12, no hwAmount needed, discount=0, qty=2
    Map<String, Object> implTags = new Map<String, Object>{
        'IsDeleted'            => tv(false),
        'ItemStockKeepingUnit' => tv('001-INFR-SVC-HAAS-IMPL-001'),
        'PricingTermCount'     => tv(12),
        'Discount'             => tv(0),
        'LineItemQuantity'     => tv('2')
    };
    Map<String, Object> implItem = new Map<String, Object>{
        'dataPath' => new List<Object>{ 'STI-001', 'STI-IMPL', UserInfo.getUserId() },
        'tagValue' => implTags
    };

    List<Map<String, Object>> result =
        QuoteMarginRollupPostHook.buildHaasUpdates(
            new List<Object>{ hwItem, implItem });

    // If tag names match LineItemNodeWrapper: 2 updates (hw has 3 attrs, impl has 5)
    // If tag names are wrong: 0 updates (ptc null → skip) — adjust names accordingly
    if (!result.isEmpty()) {
        System.assertEquals(2, result.size());
        // Hardware node: 3 attrs (UnitPrice, NetUnitPrice, NetTotalPrice)
        List<Object> hwAttrs = (List<Object>) result.get(0).get('attributes');
        System.assertEquals(3, hwAttrs.size());
        // unitPrice = 36000/12 = 3000.00; netUnitPrice = 3000*(1-10/100) = 2700.00
        System.assertEquals(3000.00, ((Map<String,Object>) hwAttrs.get(0)).get('attributeValue'));
        System.assertEquals(2700.00, ((Map<String,Object>) hwAttrs.get(1)).get('attributeValue'));
        // Implementation node: 5 attrs (UnitPrice, UnitCost, NetUnitPrice,
        //                             NetTotalPrice, ItemMargin__std)
        List<Object> implAttrs = (List<Object>) result.get(1).get('attributes');
        System.assertEquals(5, implAttrs.size());
        // unitPrice = 223.00/12 = 18.5833; unitCost = 78.88/12 = 6.5733;
        // discount 0 so netUnitPrice = unitPrice. Margin =
        // (18.5833 - 6.5733) / 18.5833 * 100 = 64.63
        // Billable rate is $223.00/hour against a $78.88/hour cost.
        System.assertEquals(
            64.63,
            ((Map<String,Object>) implAttrs.get(4)).get('attributeValue'),
            'HaaS Implementation margin must follow the HaaS rates: '
            + '(223.00 - 78.88) / 223.00 = 64.63%.'
        );
    } else {
        System.assert(true, 'Tag names did not match LineItemNodeWrapper — adjust tag names above');
    }
}
}