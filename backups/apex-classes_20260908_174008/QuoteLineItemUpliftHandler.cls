/**
 * QuoteLineItemUpliftHandler
 *
 * Invoked by QuoteLineItemUpliftTrigger (after insert/update) to:
 * 1. Detect which quote lines have a custom uplift configured.
 * 2. Invoke UpliftPricingCallback to determine markup direction (is it a markup or discount).
 * 3. Create/replace QuoteLinePriceAdjustment child records so the Revenue Cloud pricing
 *    procedure waterfall reflects the uplift in NetUnitPrice, NetTotalPrice, margin, and
 *    approval-threshold evaluations.
 *
 * NetUnitPrice / NetTotalPrice are written by the Revenue Cloud pricing engine — this
 * handler does NOT write to them directly. Instead it creates QuoteLinePriceAdjustment
 * records (AdjustmentType + AdjustmentValue) which the pricing engine picks up on the
 * next price call to recompute the waterfall.
 *
 * Markup visibility: Description = "Custom Markup Applied" or "Custom Discount Applied"
 * appears in the price waterfall UI so sales users see immediately which lines have
 * uplift applied.
 */
public with sharing class QuoteLineItemUpliftHandler {

    private static final String ADJ_SOURCE        = 'Discretionary';    // valid: Discretionary/Promotion/Rule/System
    private static final String ADJ_TYPE_PCT      = 'AdjustmentPercentage'; // valid: AdjustmentPercentage/AdjustmentAmount/OverrideAmount
    private static final String ADJ_TYPE_AMT      = 'AdjustmentAmount';
    private static final String ADJ_SCOPE_UNIT    = 'Unit';              // valid: Unit/Total/UnproratedTotal
    private static final String MARKUP_LABEL      = 'Custom Markup Applied';
    private static final String DISCOUNT_LABEL    = 'Custom Discount Applied';

    /**
     * Entry point called by the trigger.
     * @param newLines  Trigger.new
     * @param oldMap    Trigger.oldMap (null on insert)
     */
    public static void handleUplift(
        List<QuoteLineItem> newLines,
        Map<Id, QuoteLineItem> oldMap
    ) {
        List<QuoteLineItem> linesToProcess = filterChanged(newLines, oldMap);
        if (linesToProcess.isEmpty()) {
            return;
        }

        List<Map<String, Object>> callbackInputs = buildCallbackInputs(linesToProcess);
        Map<String, Object> args = new Map<String, Object>{
            UpliftPricingCallback.KEY_LINE_ITEMS => (List<Object>)(Object) callbackInputs
        };

        UpliftPricingCallback cb = new UpliftPricingCallback();
        Map<String, Object> result = (Map<String, Object>) cb.call('priceItems', args);
        if (result == null) {
            return;
        }

        List<Object> processedLines =
            (List<Object>) result.get(UpliftPricingCallback.KEY_LINE_ITEMS);

        upsertPriceAdjustments(linesToProcess, processedLines);
    }

    // ------------------------------------------------------------------ private

    /**
     * Returns lines where either uplift field changed (or is newly set).
     * On insert, all lines with a non-zero uplift are included.
     */
    private static List<QuoteLineItem> filterChanged(
        List<QuoteLineItem> newLines,
        Map<Id, QuoteLineItem> oldMap
    ) {
        List<QuoteLineItem> changed = new List<QuoteLineItem>();
        for (QuoteLineItem qli : newLines) {
            Decimal amt = qli.Custom_Uplift_Price_Amount__c;
            Decimal pct = qli.Custom_Uplift_Price_Percentage__c;

            Boolean hasUplift = (amt != null && amt != 0) || (pct != null && pct != 0);
            if (!hasUplift) {
                continue;
            }

            if (oldMap == null) {
                changed.add(qli);
                continue;
            }

            QuoteLineItem oldQli = oldMap.get(qli.Id);
            Boolean amtChanged  = (amt != oldQli.Custom_Uplift_Price_Amount__c);
            Boolean pctChanged  = (pct != oldQli.Custom_Uplift_Price_Percentage__c);
            if (amtChanged || pctChanged) {
                changed.add(qli);
            }
        }
        return changed;
    }

    /**
     * Converts QuoteLineItem records into the heterogeneous map format
     * expected by UpliftPricingCallback.
     */
    private static List<Map<String, Object>> buildCallbackInputs(
        List<QuoteLineItem> lines
    ) {
        List<Map<String, Object>> inputs = new List<Map<String, Object>>();
        for (QuoteLineItem qli : lines) {
            inputs.add(new Map<String, Object>{
                UpliftPricingCallback.KEY_UNIT_PRICE => qli.UnitPrice,
                UpliftPricingCallback.KEY_QUANTITY   => qli.Quantity,
                UpliftPricingCallback.KEY_AMT_FIELD  => qli.Custom_Uplift_Price_Amount__c,
                UpliftPricingCallback.KEY_PCT_FIELD  => qli.Custom_Uplift_Price_Percentage__c,
                'Id'                                 => qli.Id
            });
        }
        return inputs;
    }

    /**
     * Creates or replaces QuoteLinePriceAdjustment records so the adjustment
     * is visible in the Revenue Cloud pricing waterfall and approval evaluations.
     * Existing custom uplift adjustments for the same lines are deleted first.
     *
     * The pricing engine uses these records on the next price computation to
     * derive the final NetUnitPrice and NetTotalPrice for the line.
     */
    private static void upsertPriceAdjustments(
        List<QuoteLineItem> originalLines,
        List<Object> processedLines
    ) {
        Set<Id> lineIds = new Set<Id>();
        for (QuoteLineItem qli : originalLines) {
            lineIds.add(qli.Id);
        }

        // Name and Description are not filterable/writable; scope delete to Manual+Priority=1
        // which is exclusively what this handler creates for custom uplift records.
        List<QuoteLinePriceAdjustment> existing = [
            SELECT Id
            FROM QuoteLinePriceAdjustment
            WHERE QuoteLineItemId IN :lineIds
            AND AdjustmentSource = :ADJ_SOURCE
            AND Priority = 1
        ];
        if (!existing.isEmpty()) {
            delete existing;
        }

        List<QuoteLinePriceAdjustment> toInsert = new List<QuoteLinePriceAdjustment>();
        for (Integer i = 0; i < originalLines.size(); i++) {
            Map<String, Object> processed = (Map<String, Object>) processedLines[i];
            Boolean isMarkup = (Boolean) processed.get(UpliftPricingCallback.KEY_IS_MARKUP);
            if (isMarkup == null) {
                continue;
            }

            QuoteLineItem qli = originalLines[i];
            Decimal upliftAmt = qli.Custom_Uplift_Price_Amount__c;
            Decimal upliftPct = qli.Custom_Uplift_Price_Percentage__c;

            QuoteLinePriceAdjustment adj = new QuoteLinePriceAdjustment();
            adj.QuoteLineItemId  = qli.Id;
            adj.AdjustmentSource = ADJ_SOURCE;
            adj.Description      = isMarkup ? MARKUP_LABEL : DISCOUNT_LABEL;
            adj.Priority         = 1;

            if (upliftAmt != null && upliftAmt != 0) {
                adj.AdjustmentType        = ADJ_TYPE_AMT;
                adj.AdjustmentValue       = upliftAmt; // negative = markup, positive = discount
                adj.AdjustmentAmountScope = ADJ_SCOPE_UNIT;
            } else if (upliftPct != null && upliftPct != 0) {
                adj.AdjustmentType        = ADJ_TYPE_PCT;
                adj.AdjustmentValue       = upliftPct; // negative = markup, positive = discount
                adj.AdjustmentAmountScope = ADJ_SCOPE_UNIT;
            } else {
                continue;
            }

            toInsert.add(adj);
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
        }
    }
}