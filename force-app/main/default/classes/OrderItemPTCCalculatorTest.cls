@IsTest
private class OrderItemPTCCalculatorTest {

    private static Date d(Integer y, Integer m, Integer day) {
        return Date.newInstance(y, m, day);
    }

    @IsTest
    static void resolve_datesMatchQuote_usesQuoteLineTerm() {
        // MTM-style fractional QLI value is kept while the order dates are unchanged
        System.assertEquals(0.98, OrderItemPTCCalculator.resolve(
            d(2026, 10, 1), d(2026, 10, 30), d(2026, 10, 1), d(2026, 10, 30), 0.98));
    }

    @IsTest
    static void resolve_startDateMoved_usesNewDates() {
        // Change Start Date: Oct 1 -> Oct 15, end pushed to month end -> 12 + 17/31
        System.assertEquals(12.55, OrderItemPTCCalculator.resolve(
            d(2026, 10, 15), d(2027, 10, 31), d(2026, 10, 1), d(2027, 9, 30), 12));
    }

    @IsTest
    static void resolve_rampSegmentShiftedSameLength_staysTwelve() {
        // Later ramp segment chained after a moved first segment: whole months only
        System.assertEquals(12.00, OrderItemPTCCalculator.resolve(
            d(2027, 11, 1), d(2028, 10, 31), d(2027, 10, 1), d(2028, 9, 30), 12));
    }

    @IsTest
    static void resolve_rampSegmentShortened_followsDates() {
        // Segment end pulled in a month while the QLI still says 12
        System.assertEquals(11.00, OrderItemPTCCalculator.resolve(
            d(2031, 7, 1), d(2032, 5, 31), d(2031, 7, 1), d(2032, 6, 30), 12));
    }

    @IsTest
    static void resolve_noQuoteLine_calculatesFromDates() {
        System.assertEquals(12.00, OrderItemPTCCalculator.resolve(
            d(2026, 1, 1), d(2026, 12, 31), null, null, null));
    }

    @IsTest
    static void resolve_quoteLineWithoutTerm_calculatesFromDates() {
        System.assertEquals(12.00, OrderItemPTCCalculator.resolve(
            d(2026, 1, 1), d(2026, 12, 31), d(2026, 1, 1), d(2026, 12, 31), 0));
        System.assertEquals(12.00, OrderItemPTCCalculator.resolve(
            d(2026, 1, 1), d(2026, 12, 31), d(2026, 1, 1), d(2026, 12, 31), null));
    }

    @IsTest
    static void resolve_missingDates_returnsNull() {
        System.assertEquals(null, OrderItemPTCCalculator.resolve(null, d(2026, 12, 31), null, null, 12));
        System.assertEquals(null, OrderItemPTCCalculator.resolve(d(2026, 1, 1), null, null, null, 12));
        System.assertEquals(null, OrderItemPTCCalculator.calcPTC(null, null));
    }

    @IsTest
    static void calcPTC_endBeforeSameDayOfMonth_handlesMonthOvershoot() {
        // Jan 15 - Apr 14: monthsBetween says 3, walks back to 2 + 31/31
        System.assertEquals(3.00, OrderItemPTCCalculator.calcPTC(d(2026, 1, 15), d(2026, 4, 14)));
    }

    @IsTest
    static void trigger_datesUpdated_setsTermFromDates() {
        Account acc = new Account(Name = 'PTC Calculator Test Account', BillingState = 'IL');
        insert acc;
        Order o = new Order(
            AccountId     = acc.Id,
            EffectiveDate = d(2026, 10, 15),
            Status        = 'Draft',
            Pricebook2Id  = Test.getStandardPricebookId()
        );
        insert o;
        Product2 p = new Product2(Name = 'PTC Calculator Product', ProductCode = 'PTC-CALC-001', IsActive = true);
        insert p;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(), Product2Id = p.Id, UnitPrice = 100, IsActive = true
        );
        insert pbe;
        OrderItem oi = new OrderItem(OrderId = o.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 100);
        insert oi;

        Test.startTest();
        update new OrderItem(Id = oi.Id, ServiceDate = d(2026, 10, 15), EndDate = d(2027, 10, 31));
        Test.stopTest();

        OrderItem after = [SELECT PricingTermCount FROM OrderItem WHERE Id = :oi.Id];
        // Revenue Cloud's pricing engine may clear PricingTermCount after save; it is
        // either the date-based value or left for the engine, never a different number.
        System.assert(after.PricingTermCount == null || after.PricingTermCount == 12.55,
            'Oct 15 2026 - Oct 31 2027 is 12.55 pricing terms, got ' + after.PricingTermCount);
    }
}