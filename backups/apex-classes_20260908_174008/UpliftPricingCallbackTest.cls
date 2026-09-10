/**
 * UpliftPricingCallbackTest
 * Unit tests for UpliftPricingCallback covering:
 *   - Negative percentage → markup increases NetUnitPrice
 *   - Positive percentage → discount reduces NetUnitPrice
 *   - Negative amount    → markup increases NetUnitPrice
 *   - Positive amount    → discount reduces NetUnitPrice
 *   - Amount takes precedence over percentage when both are set
 *   - Zero/null uplift fields → prices unchanged
 *   - Net price never goes below zero
 *   - NetTotalPrice = NetUnitPrice * Quantity
 */
@IsTest
private class UpliftPricingCallbackTest {

    // ------------------------------------------------------------------ helpers

    private static Map<String, Object> buildLine(
        Decimal unitPrice,
        Decimal quantity,
        Decimal upliftAmt,
        Decimal upliftPct
    ) {
        Map<String, Object> line = new Map<String, Object>{
            UpliftPricingCallback.KEY_UNIT_PRICE => unitPrice,
            UpliftPricingCallback.KEY_QUANTITY   => quantity,
            UpliftPricingCallback.KEY_AMT_FIELD  => upliftAmt,
            UpliftPricingCallback.KEY_PCT_FIELD  => upliftPct
        };
        return line;
    }

    private static Map<String, Object> runCallback(List<Map<String, Object>> lines) {
        Map<String, Object> args = new Map<String, Object>{
            UpliftPricingCallback.KEY_LINE_ITEMS => (List<Object>) (Object) lines
        };
        UpliftPricingCallback cb = new UpliftPricingCallback();
        return (Map<String, Object>) cb.call('priceItems', args);
    }

    private static Map<String, Object> firstLine(Map<String, Object> result) {
        List<Object> lines = (List<Object>) result.get(UpliftPricingCallback.KEY_LINE_ITEMS);
        return (Map<String, Object>) lines[0];
    }

    // ------------------------------------------------------------------ tests

    @IsTest
    static void testNegativePercentageIsMarkup() {
        // -10% discount → 10% markup → NetUnitPrice = 100 * 1.1 = 110
        Map<String, Object> line = buildLine(100, 2, null, -10);
        Map<String, Object> result = runCallback(new List<Map<String, Object>>{ line });
        Map<String, Object> out = firstLine(result);

        System.assertEquals(110.00, out.get(UpliftPricingCallback.KEY_NET_UNIT),
            'Negative pct should produce 10% markup: 100 * 1.1 = 110');
        System.assertEquals(220.00, out.get(UpliftPricingCallback.KEY_NET_TOTAL),
            'NetTotalPrice = 110 * 2 = 220');
        System.assertEquals(true, out.get(UpliftPricingCallback.KEY_IS_MARKUP),
            'IsMarkup flag should be true for negative percentage');
    }

    @IsTest
    static void testPositivePercentageIsDiscount() {
        // 20% discount → NetUnitPrice = 100 * 0.8 = 80
        Map<String, Object> line = buildLine(100, 1, null, 20);
        Map<String, Object> result = runCallback(new List<Map<String, Object>>{ line });
        Map<String, Object> out = firstLine(result);

        System.assertEquals(80.00, out.get(UpliftPricingCallback.KEY_NET_UNIT),
            'Positive pct should reduce price: 100 * 0.8 = 80');
        System.assertEquals(false, out.get(UpliftPricingCallback.KEY_IS_MARKUP),
            'IsMarkup flag should be false for positive percentage');
    }

    @IsTest
    static void testNegativeAmountIsMarkup() {
        // -50 amount → NetUnitPrice = 200 - (-50) = 250
        Map<String, Object> line = buildLine(200, 3, -50, null);
        Map<String, Object> result = runCallback(new List<Map<String, Object>>{ line });
        Map<String, Object> out = firstLine(result);

        System.assertEquals(250.00, out.get(UpliftPricingCallback.KEY_NET_UNIT),
            'Negative amount should produce markup: 200 - (-50) = 250');
        System.assertEquals(750.00, out.get(UpliftPricingCallback.KEY_NET_TOTAL),
            'NetTotalPrice = 250 * 3 = 750');
        System.assertEquals(true, out.get(UpliftPricingCallback.KEY_IS_MARKUP),
            'IsMarkup flag should be true for negative amount');
    }

    @IsTest
    static void testPositiveAmountIsDiscount() {
        // 30 amount discount → NetUnitPrice = 100 - 30 = 70
        Map<String, Object> line = buildLine(100, 5, 30, null);
        Map<String, Object> result = runCallback(new List<Map<String, Object>>{ line });
        Map<String, Object> out = firstLine(result);

        System.assertEquals(70.00, out.get(UpliftPricingCallback.KEY_NET_UNIT),
            'Positive amount reduces price: 100 - 30 = 70');
        System.assertEquals(350.00, out.get(UpliftPricingCallback.KEY_NET_TOTAL),
            'NetTotalPrice = 70 * 5 = 350');
        System.assertEquals(false, out.get(UpliftPricingCallback.KEY_IS_MARKUP));
    }

    @IsTest
    static void testAmountTakesPrecedenceOverPercentage() {
        // Both set: amount (-50) takes priority over percentage (10)
        // NetUnitPrice = 100 - (-50) = 150
        Map<String, Object> line = buildLine(100, 1, -50, 10);
        Map<String, Object> result = runCallback(new List<Map<String, Object>>{ line });
        Map<String, Object> out = firstLine(result);

        System.assertEquals(150.00, out.get(UpliftPricingCallback.KEY_NET_UNIT),
            'Amount field takes precedence: 100 - (-50) = 150');
    }

    @IsTest
    static void testZeroUpliftFieldsLeavesPricesUnchanged() {
        Map<String, Object> line = buildLine(500, 2, 0, 0);
        // Pre-set NetUnitPrice to simulate prior pricing step output
        line.put(UpliftPricingCallback.KEY_NET_UNIT,  500);
        line.put(UpliftPricingCallback.KEY_NET_TOTAL, 1000);
        Map<String, Object> result = runCallback(new List<Map<String, Object>>{ line });
        Map<String, Object> out = firstLine(result);

        System.assertEquals(500, out.get(UpliftPricingCallback.KEY_NET_UNIT),
            'Zero uplift: prices should remain unchanged');
        System.assertEquals(1000, out.get(UpliftPricingCallback.KEY_NET_TOTAL));
    }

    @IsTest
    static void testNullUpliftFieldsLeavesPricesUnchanged() {
        Map<String, Object> line = buildLine(500, 2, null, null);
        line.put(UpliftPricingCallback.KEY_NET_UNIT,  500);
        line.put(UpliftPricingCallback.KEY_NET_TOTAL, 1000);
        Map<String, Object> result = runCallback(new List<Map<String, Object>>{ line });
        Map<String, Object> out = firstLine(result);

        System.assertEquals(500, out.get(UpliftPricingCallback.KEY_NET_UNIT),
            'Null uplift: prices should remain unchanged');
    }

    @IsTest
    static void testNetPriceFloorAtZero() {
        // Large positive discount that would push price below zero
        Map<String, Object> line = buildLine(50, 1, 200, null);
        Map<String, Object> result = runCallback(new List<Map<String, Object>>{ line });
        Map<String, Object> out = firstLine(result);

        System.assertEquals(0.00, out.get(UpliftPricingCallback.KEY_NET_UNIT),
            'Net price should not go below 0');
        System.assertEquals(0.00, out.get(UpliftPricingCallback.KEY_NET_TOTAL));
    }

    @IsTest
    static void testMultipleLinesProcessedIndependently() {
        Map<String, Object> line1 = buildLine(100, 1, null, -10); // markup
        Map<String, Object> line2 = buildLine(200, 2, 20,   null); // discount
        Map<String, Object> result = runCallback(
            new List<Map<String, Object>>{ line1, line2 }
        );
        List<Object> lines = (List<Object>) result.get(UpliftPricingCallback.KEY_LINE_ITEMS);
        Map<String, Object> out1 = (Map<String, Object>) lines[0];
        Map<String, Object> out2 = (Map<String, Object>) lines[1];

        System.assertEquals(110.00, out1.get(UpliftPricingCallback.KEY_NET_UNIT), 'Line 1 markup');
        System.assertEquals(180.00, out2.get(UpliftPricingCallback.KEY_NET_UNIT), 'Line 2 discount');
        System.assertEquals(360.00, out2.get(UpliftPricingCallback.KEY_NET_TOTAL), 'Line 2 total');
    }

    @IsTest
    static void testNullArgsReturnsNull() {
        UpliftPricingCallback cb = new UpliftPricingCallback();
        System.assertEquals(null, cb.call(null, null), 'Null args should return null');
        System.assertEquals(null, cb.call('priceItems', null), 'Null args map should return null');
    }

    @IsTest
    static void testUnknownActionReturnsNull() {
        UpliftPricingCallback cb = new UpliftPricingCallback();
        Map<String, Object> args = new Map<String, Object>();
        System.assertEquals(null, cb.call('unknownAction', args), 'Unknown action should return null');
    }

    @IsTest
    static void testStringValuesInMapAreHandled() {
        // Pricing engine sometimes passes values as String instead of Decimal
        Map<String, Object> line = new Map<String, Object>{
            UpliftPricingCallback.KEY_UNIT_PRICE => '100',
            UpliftPricingCallback.KEY_QUANTITY   => '2',
            UpliftPricingCallback.KEY_AMT_FIELD  => null,
            UpliftPricingCallback.KEY_PCT_FIELD  => '-5'
        };
        Map<String, Object> result = runCallback(new List<Map<String, Object>>{ line });
        Map<String, Object> out = firstLine(result);

        // -5% → 5% markup → 100 * 1.05 = 105
        System.assertEquals(105.00, out.get(UpliftPricingCallback.KEY_NET_UNIT),
            'String values should be coerced: 100 * 1.05 = 105');
    }
}