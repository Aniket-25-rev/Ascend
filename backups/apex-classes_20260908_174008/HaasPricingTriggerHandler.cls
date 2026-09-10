public class HaasPricingTriggerHandler {

    // =========================================================
    // HAAS HARDWARE / IMPLEMENTATION PRICING (ARM-108) — trigger fallback
    // The post-hook (QuoteMarginRollupPostHook.applyHaasPricing) only fires
    // when Revenue Cloud's pricing context actually includes the line in
    // that save's SalesTransactionItem payload — confirmed live (multiple
    // times, quote 0Q0VF000002gAxt0AE) that several UI edit paths (a bare
    // Reprice click, inline grid quantity edits, a direct field save on the
    // record) commit a plain DML update to QuoteLineItem WITHOUT routing
    // through that context at all, so the post-hook never runs and
    // UnitPrice/NetTotalPrice are left at whatever the native Pricing
    // Procedure computed (often 0 or the raw undivided rate).
    //
    // This handler recalculates the same math directly on the record inside
    // a before insert/update trigger, so it applies on every save regardless
    // of which path the UI used — Trigger.new always carries the current
    // PricingTermCount/Quantity/Discount/HaaS_Hardware_Amount__c field
    // values (unlike the context tag payload, which is only populated for
    // fields actually touched by that specific save).
    //
    // Only ever touches these two SKUs — every other line on every other
    // quote is untouched.
    // =========================================================
    private static final String HAAS_HARDWARE_SKU       = '001-INFR-ASC-HAAS-HAAS-001';
    private static final String HAAS_IMPLEMENTATION_SKU = '001-INFR-SVC-HAAS-IMPL-001';
    private static final Decimal HAAS_IMPL_SELL_RATE    = 223.00;
    private static final Decimal HAAS_IMPL_COST_RATE    = 78.88;
    private static final Set<String> HAAS_SKUS = new Set<String>{
        HAAS_HARDWARE_SKU, HAAS_IMPLEMENTATION_SKU
    };

    public static void applyHaasPricing(List<QuoteLineItem> lines) {
        Set<Id> productIds = new Set<Id>();
        for (QuoteLineItem qli : lines) {
            if (qli.Product2Id != null) productIds.add(qli.Product2Id);
        }
        if (productIds.isEmpty()) return;

        Map<Id, String> skuByProductId = new Map<Id, String>();
        for (Product2 p : [
            SELECT Id, StockKeepingUnit
            FROM   Product2
            WHERE  Id IN :productIds
            AND    StockKeepingUnit IN :HAAS_SKUS
        ]) {
            skuByProductId.put(p.Id, p.StockKeepingUnit);
        }
        if (skuByProductId.isEmpty()) return;

        for (QuoteLineItem qli : lines) {
            String sku = skuByProductId.get(qli.Product2Id);
            if (sku == null) continue;

            Decimal ptc = qli.PricingTermCount;
            if (ptc == null || ptc <= 0) {
                System.debug('==HaasPricingTrigger SKIPPED== sku=' + sku + ' PricingTermCount unavailable');
                continue;
            }

            Decimal quantity = qli.Quantity == null ? 1 : qli.Quantity;

            if (HAAS_HARDWARE_SKU.equals(sku)) {
                if (qli.HaaS_Hardware_Amount__c == null) {
                    System.debug('==HaasPricingTrigger SKIPPED== Hardware line missing HaaS_Hardware_Amount__c');
                    continue;
                }
                Decimal unitPrice = (qli.HaaS_Hardware_Amount__c / ptc).setScale(2, RoundingMode.HALF_UP);

                qli.UnitPrice = unitPrice;

                System.debug('==HaasPricingTrigger Hardware== amount=' + qli.HaaS_Hardware_Amount__c
                    + ' ptc=' + ptc + ' unitPrice=' + unitPrice);
            } else {
                Decimal unitPrice = (HAAS_IMPL_SELL_RATE / ptc).setScale(4, RoundingMode.HALF_UP);
                Decimal unitCost  = (HAAS_IMPL_COST_RATE / ptc).setScale(4, RoundingMode.HALF_UP);

                qli.UnitPrice = unitPrice;
                qli.UnitCost = unitCost;

                System.debug('==HaasPricingTrigger Implementation== ptc=' + ptc + ' hours=' + quantity
                    + ' unitPrice=' + unitPrice + ' unitCost=' + unitCost);
            }
        }
    }

    // =========================================================
    // HAAS PAIRING VALIDATION (ARM-108)
    // Rachel: "they could have multiple HaaS SKUs (one for each hardware),
    // and each one needs its own implementation SKU" — but this only
    // applies to lines being ADDED together in the same save (New Business,
    // or a brand-new Hardware line added mid-Amendment/Renewal).
    //
    // It deliberately does NOT apply to an already-existing Hardware line
    // carried forward from Assets on a Renewal/Amendment quote: per the
    // requirement, "Implementation Services shall not be required when the
    // quote is only renewing or modifying existing HaaS service" — that
    // carried-forward line only ever gets UPDATED (dates/PricingTermCount
    // recalculated by JTLPreHook), never re-inserted, and Implementation
    // was never part of that carryover to begin with. So this validation
    // only runs on INSERT: within a single save, the count of brand-new
    // Hardware lines must equal the count of brand-new Implementation
    // lines. Plain updates to already-persisted lines are never checked —
    // there is no way to "break" a pairing via update since neither SKU
    // nor QuoteId changes on an update in practice.
    //
    // Delete still blocks removing one half of an existing pair, as a
    // general safety net within a quote's own edit lifecycle (e.g. New
    // Business, before submit) — this doesn't conflict with the
    // Renewal/Amendment carryover case, since Implementation is never
    // present there to begin with.
    // =========================================================
    public static void validateHaasPairing(
        List<QuoteLineItem> newLines,
        Map<Id, QuoteLineItem> oldMap,
        Boolean isInsert,
        Boolean isDelete
    ) {
        if (isDelete) {
            validateHaasPairingOnDelete(oldMap);
            return;
        }
        if (!isInsert) {
            return; // plain updates (e.g. Renewal/Amendment date recalculation on a carried-forward line) never require pairing
        }
        validateHaasPairingOnInsert(newLines);
    }

    private static void validateHaasPairingOnInsert(List<QuoteLineItem> newLines) {
        Map<Id, String> skuByProductId = getHaasSkusByProductId(newLines);
        if (skuByProductId.isEmpty()) return;

        Map<Id, Integer> hardwareCountByQuote = new Map<Id, Integer>();
        Map<Id, Integer> implCountByQuote = new Map<Id, Integer>();
        Map<Id, List<QuoteLineItem>> touchedHaasLinesByQuote = new Map<Id, List<QuoteLineItem>>();

        for (QuoteLineItem qli : newLines) {
            String sku = skuByProductId.get(qli.Product2Id);
            if (sku == null || qli.QuoteId == null) continue;

            if (!touchedHaasLinesByQuote.containsKey(qli.QuoteId)) {
                touchedHaasLinesByQuote.put(qli.QuoteId, new List<QuoteLineItem>());
                hardwareCountByQuote.put(qli.QuoteId, 0);
                implCountByQuote.put(qli.QuoteId, 0);
            }
            touchedHaasLinesByQuote.get(qli.QuoteId).add(qli);

            if (HAAS_HARDWARE_SKU.equals(sku)) {
                hardwareCountByQuote.put(qli.QuoteId, hardwareCountByQuote.get(qli.QuoteId) + 1);
            } else {
                implCountByQuote.put(qli.QuoteId, implCountByQuote.get(qli.QuoteId) + 1);
            }
        }

        for (Id quoteId : touchedHaasLinesByQuote.keySet()) {
            Integer hwCount   = hardwareCountByQuote.get(quoteId);
            Integer implCount = implCountByQuote.get(quoteId);
            if (hwCount == implCount) continue;

            String message = 'New HaaS Hardware lines (' + hwCount + ') and new Implementation lines (' + implCount
                + ') being added in this save must match — each new HaaS Hardware line needs its own new '
                + 'Implementation line, and vice versa. Add or remove a line to balance them before saving.';

            for (QuoteLineItem qli : touchedHaasLinesByQuote.get(quoteId)) {
                qli.addError(message);
            }
        }
    }

    private static void validateHaasPairingOnDelete(Map<Id, QuoteLineItem> oldMap) {
        List<QuoteLineItem> deletedLines = oldMap.values();
        Map<Id, String> skuByProductId = getHaasSkusByProductId(deletedLines);
        if (skuByProductId.isEmpty()) return;

        Map<Id, List<QuoteLineItem>> touchedHaasLinesByQuote = new Map<Id, List<QuoteLineItem>>();
        for (QuoteLineItem qli : deletedLines) {
            if (!skuByProductId.containsKey(qli.Product2Id) || qli.QuoteId == null) continue;
            if (!touchedHaasLinesByQuote.containsKey(qli.QuoteId)) {
                touchedHaasLinesByQuote.put(qli.QuoteId, new List<QuoteLineItem>());
            }
            touchedHaasLinesByQuote.get(qli.QuoteId).add(qli);
        }
        if (touchedHaasLinesByQuote.isEmpty()) return;

        Set<Id> excludedIds = new Set<Id>();
        for (QuoteLineItem qli : deletedLines) excludedIds.add(qli.Id);

        Map<Id, Integer> hardwareCountByQuote = new Map<Id, Integer>();
        Map<Id, Integer> implCountByQuote = new Map<Id, Integer>();
        for (Id quoteId : touchedHaasLinesByQuote.keySet()) {
            hardwareCountByQuote.put(quoteId, 0);
            implCountByQuote.put(quoteId, 0);
        }

        for (QuoteLineItem qli : [
            SELECT Id, QuoteId, Product2.StockKeepingUnit
            FROM   QuoteLineItem
            WHERE  QuoteId IN :touchedHaasLinesByQuote.keySet()
            AND    Product2.StockKeepingUnit IN :HAAS_SKUS
        ]) {
            if (excludedIds.contains(qli.Id)) continue;
            if (HAAS_HARDWARE_SKU.equals(qli.Product2.StockKeepingUnit)) {
                hardwareCountByQuote.put(qli.QuoteId, hardwareCountByQuote.get(qli.QuoteId) + 1);
            } else {
                implCountByQuote.put(qli.QuoteId, implCountByQuote.get(qli.QuoteId) + 1);
            }
        }

        for (Id quoteId : touchedHaasLinesByQuote.keySet()) {
            Integer hwCount   = hardwareCountByQuote.get(quoteId);
            Integer implCount = implCountByQuote.get(quoteId);
            if (hwCount == implCount) continue;

            String message = 'Deleting this line would leave HaaS Hardware lines (' + hwCount
                + ') and Implementation lines (' + implCount + ') unbalanced on this quote — each HaaS '
                + 'Hardware line needs its own Implementation line, and vice versa. Delete both together, '
                + 'or add a replacement line to balance them.';

            for (QuoteLineItem qli : touchedHaasLinesByQuote.get(quoteId)) {
                qli.addError(message);
            }
        }
    }

    private static Map<Id, String> getHaasSkusByProductId(List<QuoteLineItem> lines) {
        Set<Id> productIds = new Set<Id>();
        for (QuoteLineItem qli : lines) {
            if (qli.Product2Id != null) productIds.add(qli.Product2Id);
        }

        Map<Id, String> skuByProductId = new Map<Id, String>();
        if (productIds.isEmpty()) return skuByProductId;

        for (Product2 p : [
            SELECT Id, StockKeepingUnit
            FROM   Product2
            WHERE  Id IN :productIds
            AND    StockKeepingUnit IN :HAAS_SKUS
        ]) {
            skuByProductId.put(p.Id, p.StockKeepingUnit);
        }
        return skuByProductId;
    }
}