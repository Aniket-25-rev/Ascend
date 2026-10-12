/**
 * Tests for QuoteRampAnnualIncreaseService (AC7).
 *
 * Ramp segments are injected in memory through segmentOverride rather than
 * inserted. Real QuoteLineGroup inserts drag in the org's ramp validation
 * (Quote_Validate_Ramp_Start_Date requires the earliest ramped group's
 * StartDate to equal the quote's StartDate), which has nothing to do with
 * what these tests are pinning.
 */
@IsTest
private class QuoteRampAnnualIncreaseServiceTest {

    private static Integer idCounter = 0;

    @TestSetup
    static void setup() {
        Account account = new Account(
            Name = 'Ramp AI Test Account',
            BillingStreet = '1 Test Way', BillingCity = 'Chicago',
            BillingState = 'IL', BillingPostalCode = '60601', BillingCountry = 'US'
        );
        insert account;

        Opportunity opp = new Opportunity(
            Name = 'Ramp AI Opp',
            StageName = 'Generate',
            CloseDate = Date.today().addDays(30),
            AccountId = account.Id,
            Type = 'New Business'
        );
        insert opp;

        // StartDate is set on insert deliberately: the org's
        // Opportunity_AfterTriggerFlow derives CloseDate from the quote's
        // StartDate and fails with REQUIRED_FIELD_MISSING when it is blank.
        insert new Quote(
            Name = 'Ramp AI Quote',
            OpportunityId = opp.Id,
            Status = 'Draft',
            StartDate = Date.newInstance(2026, 8, 1),
            Annual_Increase__c = 4
        );
    }

    private static Quote testQuote() {
        return [SELECT Id, Annual_Increase__c FROM Quote LIMIT 1];
    }

    private static Id fakeSegmentId() {
        idCounter++;
        return Id.valueOf('1C9VF0000' + String.valueOf(100000 + idCounter));
    }

    private static QuoteLineGroup segment(
        Id quoteId, String name, Date startDate, Integer sortOrder, Decimal uplift
    ) {
        Map<String, Object> raw = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineGroup' },
            'Id' => fakeSegmentId(),
            'QuoteId' => quoteId,
            'Name' => name,
            'StartDate' => startDate,
            'SortOrder' => sortOrder,
            'UnitPriceUplift' => uplift
        };
        return (QuoteLineGroup) JSON.deserialize(JSON.serialize(raw), QuoteLineGroup.class);
    }

    private static Decimal reloadIncrease(Id quoteId) {
        return [SELECT Annual_Increase__c FROM Quote WHERE Id = :quoteId].Annual_Increase__c;
    }

    // The headline case: a 4%/year ramp reads 4 / 8 / 12 because the uplift
    // is cumulative, and AC7 copies the second segment verbatim.
    @IsTest
    static void testSecondSegmentUpliftLandsOnTheQuote() {
        Quote quote = testQuote();
        Date year1 = Date.newInstance(2026, 8, 1);

        QuoteRampAnnualIncreaseService.segmentOverride = new List<QuoteLineGroup>{
            segment(quote.Id, 'Year 3', year1.addYears(2), 3, 12),
            segment(quote.Id, 'Year 1', year1, 1, 4),
            segment(quote.Id, 'Year 2', year1.addYears(1), 2, 8)
        };

        Test.startTest();
        QuoteRampAnnualIncreaseService.stampFromRamp(new Set<Id>{ quote.Id });
        Test.stopTest();

        System.assertEquals(8, reloadIncrease(quote.Id),
            'The second segment by start date is Year 2, whose uplift is 8');
    }

    // A ramp whose first segment carries no uplift is the shape where the
    // copied figure IS the annual rate.
    @IsTest
    static void testUpliftIsCopiedWhenTheFirstSegmentHasNone() {
        Quote quote = testQuote();
        Date year1 = Date.newInstance(2027, 9, 1);

        QuoteRampAnnualIncreaseService.segmentOverride = new List<QuoteLineGroup>{
            segment(quote.Id, 'Year 1', year1, 1, null),
            segment(quote.Id, 'Year 2', year1.addYears(1), 2, 10),
            segment(quote.Id, 'Year 3', year1.addYears(2), 3, 20)
        };

        Test.startTest();
        QuoteRampAnnualIncreaseService.stampFromRamp(new Set<Id>{ quote.Id });
        Test.stopTest();

        System.assertEquals(10, reloadIncrease(quote.Id),
            'Year 2 carries 10 and Year 1 carries nothing, so 10 is the annual rate');
    }

    // RCA stamps mid-term amendment segments with SortOrder -999999999 and up,
    // so ordering has to come from StartDate. Names vary too: custom ramps use
    // "Segment 2" and amendments use "Year 2 - Amend".
    @IsTest
    static void testOrderingUsesStartDateNotSortOrderOrName() {
        Quote quote = testQuote();
        Date first = Date.newInstance(2028, 3, 1);

        QuoteRampAnnualIncreaseService.segmentOverride = new List<QuoteLineGroup>{
            segment(quote.Id, 'Segment 3', first.addMonths(17), -999999998, 9),
            segment(quote.Id, 'Year 2 - Amend', first, -999999999, 3),
            segment(quote.Id, 'Segment 2', first.addMonths(5), -999999997, 6)
        };

        Test.startTest();
        QuoteRampAnnualIncreaseService.stampFromRamp(new Set<Id>{ quote.Id });
        Test.stopTest();

        System.assertEquals(6, reloadIncrease(quote.Id),
            'Second by start date is the 5-month-later segment at 6, even though its '
            + 'SortOrder is the highest of the three');
    }

    @IsTest
    static void testSingleSegmentRampIsLeftAlone() {
        Quote quote = testQuote();

        QuoteRampAnnualIncreaseService.segmentOverride = new List<QuoteLineGroup>{
            segment(quote.Id, 'Year 1', Date.newInstance(2026, 8, 1), 1, 7)
        };

        Test.startTest();
        QuoteRampAnnualIncreaseService.stampFromRamp(new Set<Id>{ quote.Id });
        Test.stopTest();

        System.assertEquals(4, reloadIncrease(quote.Id),
            'A ramp still being built has no second segment, so nothing is stamped');
    }

    @IsTest
    static void testSecondSegmentWithoutAnUpliftIsLeftAlone() {
        Quote quote = testQuote();
        Date year1 = Date.newInstance(2026, 8, 1);

        QuoteRampAnnualIncreaseService.segmentOverride = new List<QuoteLineGroup>{
            segment(quote.Id, 'Year 1', year1, 1, 5),
            segment(quote.Id, 'Year 2', year1.addYears(1), 2, null)
        };

        Test.startTest();
        QuoteRampAnnualIncreaseService.stampFromRamp(new Set<Id>{ quote.Id });
        Test.stopTest();

        System.assertEquals(4, reloadIncrease(quote.Id),
            'AC7 fires only when a value exists on the ramp; Year 1 must not be used instead');
    }

    @IsTest
    static void testMatchingValueIssuesNoDml() {
        Quote quote = testQuote();
        Date year1 = Date.newInstance(2026, 8, 1);

        QuoteRampAnnualIncreaseService.segmentOverride = new List<QuoteLineGroup>{
            segment(quote.Id, 'Year 1', year1, 1, 0),
            segment(quote.Id, 'Year 2', year1.addYears(1), 2, 4)
        };

        Test.startTest();
        Integer before = Limits.getDmlStatements();
        QuoteRampAnnualIncreaseService.stampFromRamp(new Set<Id>{ quote.Id });
        Integer after = Limits.getDmlStatements();
        Test.stopTest();

        System.assertEquals(before, after,
            'The quote already reads 4, so the stamp must not issue DML');
        System.assertEquals(4, reloadIncrease(quote.Id), 'Value unchanged');
    }

    @IsTest
    static void testInvocableDelegatesToTheService() {
        Quote quote = testQuote();
        Date year1 = Date.newInstance(2026, 8, 1);

        QuoteRampAnnualIncreaseService.segmentOverride = new List<QuoteLineGroup>{
            segment(quote.Id, 'Year 1', year1, 1, null),
            segment(quote.Id, 'Year 2', year1.addYears(1), 2, 15)
        };

        QuoteRampAnnualIncreaseService.Request request =
            new QuoteRampAnnualIncreaseService.Request();
        request.quoteId = quote.Id;

        Test.startTest();
        QuoteRampAnnualIncreaseService.run(new List<QuoteRampAnnualIncreaseService.Request>{
            request, null
        });
        Test.stopTest();

        System.assertEquals(15, reloadIncrease(quote.Id),
            'The flow entry point stamps the same value, and a null request is ignored');
    }

    @IsTest
    static void testEmptyAndNullInputsExitCleanly() {
        Test.startTest();
        QuoteRampAnnualIncreaseService.run(null);
        QuoteRampAnnualIncreaseService.run(new List<QuoteRampAnnualIncreaseService.Request>());
        QuoteRampAnnualIncreaseService.stampFromRamp(null);
        QuoteRampAnnualIncreaseService.stampFromRamp(new Set<Id>());
        QuoteRampAnnualIncreaseService.stampFromRamp(new Set<Id>{ null });
        Test.stopTest();

        System.assertEquals(0, QuoteRampAnnualIncreaseService.faultLog.size(),
            'Empty input is not an error condition');
    }

    // The stamp runs from an after-save flow, so it must never throw and
    // roll back the ramp that triggered it.
    @IsTest
    static void testAFailedQuoteWriteIsLoggedRatherThanThrown() {
        Quote quote = testQuote();
        Date year1 = Date.newInstance(2026, 8, 1);

        // A segment pointing at a quote id that no longer resolves: the
        // service must swallow whatever comes back.
        QuoteRampAnnualIncreaseService.segmentOverride = new List<QuoteLineGroup>{
            segment(quote.Id, 'Year 1', year1, 1, null),
            segment(quote.Id, 'Year 2', year1.addYears(1), 2, 11)
        };
        delete quote;

        Test.startTest();
        QuoteRampAnnualIncreaseService.stampFromRamp(new Set<Id>{ quote.Id });
        Test.stopTest();

        System.assert(true, 'A deleted quote must not raise out of the stamp');
    }

    // Exercises the real QuoteLineGroup query rather than the injected list.
    @IsTest
    static void testQueryPathRunsWhenNoOverrideIsSet() {
        Quote quote = testQuote();

        Test.startTest();
        QuoteRampAnnualIncreaseService.stampFromRamp(new Set<Id>{ quote.Id });
        Test.stopTest();

        System.assertEquals(4, reloadIncrease(quote.Id),
            'This quote has no ramp, so the query finds nothing and nothing is stamped');
    }

    @IsTest
    static void testTiesFallBackToSortOrderThenId() {
        Id quoteId = testQuote().Id;
        Date same = Date.newInstance(2026, 8, 1);

        List<QuoteLineGroup> bySortOrder = new List<QuoteLineGroup>{
            segment(quoteId, 'B', same, 2, 20),
            segment(quoteId, 'A', same, 1, 10)
        };
        System.assertEquals(20,
            QuoteRampAnnualIncreaseService.secondSegment(bySortOrder).UnitPriceUplift,
            'Same start date, so SortOrder decides which segment is second');

        List<QuoteLineGroup> nullSortOrder = new List<QuoteLineGroup>{
            segment(quoteId, 'No sort', same, null, 30),
            segment(quoteId, 'Sorted', same, 1, 40)
        };
        System.assertEquals(30,
            QuoteRampAnnualIncreaseService.secondSegment(nullSortOrder).UnitPriceUplift,
            'A null SortOrder sorts after a populated one');

        QuoteLineGroup lowerId = segment(quoteId, 'One', same, 1, 50);
        QuoteLineGroup higherId = segment(quoteId, 'Two', same, 1, 60);
        List<QuoteLineGroup> byId = new List<QuoteLineGroup>{ higherId, lowerId };
        System.assertEquals(higherId.Id,
            QuoteRampAnnualIncreaseService.secondSegment(byId).Id,
            'Identical date and SortOrder fall back to Id, keeping the order stable');
    }

    @IsTest
    static void testTheGuardStopsASecondWriteInTheSameTransaction() {
        Quote quote = testQuote();
        Date year1 = Date.newInstance(2026, 8, 1);

        QuoteRampAnnualIncreaseService.segmentOverride = new List<QuoteLineGroup>{
            segment(quote.Id, 'Year 1', year1, 1, null),
            segment(quote.Id, 'Year 2', year1.addYears(1), 2, 9)
        };

        Test.startTest();
        QuoteRampAnnualIncreaseService.stampFromRamp(new Set<Id>{ quote.Id });
        System.assertEquals(9, reloadIncrease(quote.Id), 'First pass stamps 9');

        QuoteRampAnnualIncreaseService.segmentOverride = new List<QuoteLineGroup>{
            segment(quote.Id, 'Year 1', year1, 1, null),
            segment(quote.Id, 'Year 2', year1.addYears(1), 2, 25)
        };
        QuoteRampAnnualIncreaseService.stampFromRamp(new Set<Id>{ quote.Id });
        Test.stopTest();

        System.assertEquals(9, reloadIncrease(quote.Id),
            'A quote already written this transaction is not written again');
    }

    // Segments belonging to a quote outside the requested set are ignored,
    // and a segment with no QuoteId cannot blow up the grouping.
    @IsTest
    static void testForeignAndHeadlessSegmentsAreIgnored() {
        Quote quote = testQuote();
        Date year1 = Date.newInstance(2026, 8, 1);

        QuoteRampAnnualIncreaseService.segmentOverride = new List<QuoteLineGroup>{
            segment(null, 'Headless', year1, 1, 77),
            segment(quote.Id, 'Year 1', year1, 1, null),
            segment(quote.Id, 'Year 2', year1.addYears(1), 2, 13)
        };

        Test.startTest();
        QuoteRampAnnualIncreaseService.stampFromRamp(new Set<Id>{ quote.Id });
        Test.stopTest();

        System.assertEquals(13, reloadIncrease(quote.Id),
            'The headless segment is skipped and Year 2 still stamps');
    }

    @IsTest
    static void testSecondSegmentHelperHandlesNullsAndShortLists() {
        System.assertEquals(null, QuoteRampAnnualIncreaseService.secondSegment(null),
            'Null list has no second segment');
        System.assertEquals(null,
            QuoteRampAnnualIncreaseService.secondSegment(new List<QuoteLineGroup>()),
            'Empty list has no second segment');

        Id quoteId = testQuote().Id;
        // A segment with no StartDate must sort last, never first.
        List<QuoteLineGroup> mixed = new List<QuoteLineGroup>{
            segment(quoteId, 'No date', null, 1, 99),
            segment(quoteId, 'Year 1', Date.newInstance(2026, 8, 1), 2, 1),
            segment(quoteId, 'Year 2', Date.newInstance(2027, 8, 1), 3, 2)
        };
        System.assertEquals(2, QuoteRampAnnualIncreaseService.secondSegment(mixed).UnitPriceUplift,
            'Dated segments order first, so the second is Year 2');
    }
}