/**
 * UpliftPricingCallback
 *
 * Revenue Cloud Industries CPQ pricing callback that interprets negative values
 * in Custom_Uplift_Price_Amount__c and Custom_Uplift_Price_Percentage__c as
 * markups, applying an upward adjustment to NetUnitPrice and NetTotalPrice.
 *
 * Wiring: Registered as a Custom Apex action on both CMEDefaultRecipe and
 * NGPDefaultRecipe. The Pricing Procedure invokes this class via the
 * Callable interface with action = 'priceItems'.
 *
 * Markup Logic:
 *   Percentage field: NetUnitPrice = UnitPrice * (1 - pct / 100)
 *     e.g. pct = -10  →  multiplier = 1.10  →  10 % markup
 *   Amount field:     NetUnitPrice = UnitPrice - amount
 *     e.g. amount = -50 →  NetUnitPrice = UnitPrice + 50
 *   When both fields are populated, amount takes precedence.
 *   NetTotalPrice = NetUnitPrice * Quantity
 */
global with sharing class UpliftPricingCallback implements Callable {

    // Key constants for the pricing context map — public so handler and tests can share them
    public static final String KEY_LINE_ITEMS  = 'lineItems';
    public static final String KEY_UNIT_PRICE  = 'UnitPrice';
    public static final String KEY_QUANTITY    = 'Quantity';
    public static final String KEY_NET_UNIT    = 'NetUnitPrice';
    public static final String KEY_NET_TOTAL   = 'NetTotalPrice';
    public static final String KEY_PCT_FIELD   = 'Custom_Uplift_Price_Percentage__c';
    public static final String KEY_AMT_FIELD   = 'Custom_Uplift_Price_Amount__c';
    public static final String KEY_IS_MARKUP   = 'IsMarkup__c';

    /**
     * Callable entry point invoked by the Revenue Cloud Pricing Engine.
     * action = 'priceItems' triggers the uplift calculation.
     */
    global Object call(String action, Map<String, Object> args) {
        if (action == null || args == null) {
            return null;
        }
        if (action.equalsIgnoreCase('priceItems')) {
            return applyUplift(args);
        }
        return null;
    }

    /**
     * Iterates over each line item in the pricing context and applies
     * the uplift / markup adjustment when custom uplift fields are set.
     */
    @TestVisible
    private Map<String, Object> applyUplift(Map<String, Object> args) {
        Object rawLines = args.get(KEY_LINE_ITEMS);
        if (rawLines == null) {
            return args;
        }

        List<Object> lineItems = (List<Object>) rawLines;

        for (Object lineObj : lineItems) {
            Map<String, Object> line = (Map<String, Object>) lineObj;
            processLine(line);
        }

        args.put(KEY_LINE_ITEMS, lineItems);
        return args;
    }

    /**
     * Applies uplift to a single line item map.
     * Priority: amount-based uplift over percentage-based when both are set.
     */
    @TestVisible
    private void processLine(Map<String, Object> line) {
        Decimal unitPrice = getDecimal(line, KEY_UNIT_PRICE);
        Decimal quantity  = getDecimal(line, KEY_QUANTITY);
        if (unitPrice == null || quantity == null) {
            return;
        }

        Decimal upliftAmt = getDecimal(line, KEY_AMT_FIELD);
        Decimal upliftPct = getDecimal(line, KEY_PCT_FIELD);

        // No uplift configured — leave prices unchanged
        if ((upliftAmt == null || upliftAmt == 0) &&
            (upliftPct == null || upliftPct == 0)) {
            return;
        }

        Decimal netUnitPrice;
        Boolean isMarkup = false;

        if (upliftAmt != null && upliftAmt != 0) {
            // Amount-based: subtract the amount (negative amount = markup)
            netUnitPrice = unitPrice - upliftAmt;
            isMarkup     = upliftAmt < 0;
        } else {
            // Percentage-based: price * (1 - pct/100); negative pct = markup
            netUnitPrice = unitPrice * (1 - (upliftPct / 100));
            isMarkup     = upliftPct < 0;
        }

        // Guard against accidental negative net price
        if (netUnitPrice < 0) {
            netUnitPrice = 0;
        }

        Decimal netTotalPrice = netUnitPrice * quantity;

        line.put(KEY_NET_UNIT,  netUnitPrice.setScale(2, RoundingMode.HALF_UP));
        line.put(KEY_NET_TOTAL, netTotalPrice.setScale(2, RoundingMode.HALF_UP));

        // Visibility flag — can be surfaced in UI to show "Markup Applied"
        line.put(KEY_IS_MARKUP, isMarkup);
    }

    /** Safe decimal extractor from a heterogeneous map value. */
    private Decimal getDecimal(Map<String, Object> m, String key) {
        Object val = m.get(key);
        if (val == null) {
            return null;
        }
        if (val instanceof Decimal) {
            return (Decimal) val;
        }
        try {
            return Decimal.valueOf(String.valueOf(val));
        } catch (Exception ex) {
            return null;
        }
    }
}