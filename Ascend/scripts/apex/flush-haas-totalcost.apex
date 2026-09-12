/*
 * Flush the stale TotalCost left on HaaS Implementation lines.
 *
 * BACKGROUND
 * CostBookEntry for 001-INFR-SVC-HAAS-IMPL-001 held 78.88 as a raw HOURLY cost,
 * while the line's UnitPrice is amortised (202.00 / PricingTermCount). The margin
 * step compared the two and produced figures past QuoteLineItem.Margin's
 * percent(3,2) rail (+/-999.99), aborting the whole pricing pass.
 *
 * The cost book entry is now deleted, but affected lines still store the value it
 * stamped: TotalCost = 78.88 x Quantity. TotalCost is NOT writable - only a
 * pricing pass rewrites it - and that pass is rejected by the very value it would
 * replace. Deadlock.
 *
 * HOW THIS BREAKS IT
 * Margin uses (TotalCost / Quantity) as the unit cost. Temporarily tripling
 * Quantity divides that stale cost by three, bringing the margin back inside the
 * rail so a pass can complete and rewrite TotalCost from the real UnitCost.
 * Quantity is then restored and a second pass settles the final numbers.
 *
 *   qty 100  ->  7888/100 = 78.88  ->  margin -2317%  BLOCKED
 *   qty 300  ->  7888/300 = 26.29  ->  margin  -706%  saves
 *
 * Set DRY_RUN = false to apply. Run in Anonymous Apex, one quote at a time for
 * the first few, then widen QUOTE_IDS once you are satisfied.
 */

Boolean DRY_RUN = true;

// Leave empty to target every quote with a HaaS Implementation line.
Set<Id> QUOTE_IDS = new Set<Id>{
    '0Q0VF000003kulS0AQ'
};

final String IMPL_SKU  = '001-INFR-SVC-HAAS-IMPL-001';
final Decimal RAIL     = 999.99;
final Integer DILUTION = 3;   // multiplier applied to Quantity

List<QuoteLineItem> lines = QUOTE_IDS.isEmpty()
    ? [SELECT Id, QuoteId, Quantity, UnitPrice, NetUnitPrice, UnitCost, TotalCost, Margin
       FROM QuoteLineItem WHERE Product2.StockKeepingUnit = :IMPL_SKU]
    : [SELECT Id, QuoteId, Quantity, UnitPrice, NetUnitPrice, UnitCost, TotalCost, Margin
       FROM QuoteLineItem WHERE Product2.StockKeepingUnit = :IMPL_SKU AND QuoteId IN :QUOTE_IDS];

System.debug('=== ' + lines.size() + ' Implementation line(s) in scope ===');

List<QuoteLineItem> needsFlush = new List<QuoteLineItem>();
for (QuoteLineItem l : lines) {
    if (l.Quantity == null || l.Quantity == 0 || l.TotalCost == null || l.UnitCost == null) continue;

    Decimal impliedUnitCost = l.TotalCost / l.Quantity;
    Boolean stale = (impliedUnitCost - l.UnitCost).abs() > 0.01;   // cost book value, not the amortised one

    System.debug(l.Id + ' qty=' + l.Quantity + ' TotalCost=' + l.TotalCost
        + ' implied=' + impliedUnitCost + ' UnitCost=' + l.UnitCost
        + (stale ? '  <-- STALE' : '  ok'));

    if (stale) needsFlush.add(l);
}

System.debug('=== ' + needsFlush.size() + ' line(s) need flushing ===');

if (DRY_RUN) {
    System.debug('DRY_RUN = true, nothing changed. Set it to false to apply.');
} else {
    Map<Id, Decimal> originalQty = new Map<Id, Decimal>();
    Set<Id> quoteIds = new Set<Id>();
    List<QuoteLineItem> up = new List<QuoteLineItem>();

    for (QuoteLineItem l : needsFlush) {
        originalQty.put(l.Id, l.Quantity);
        quoteIds.add(l.QuoteId);
        up.add(new QuoteLineItem(Id = l.Id, Quantity = l.Quantity * DILUTION));
    }

    // --- pass 1: dilute, then reprice so the engine rewrites TotalCost ---
    update up;
    System.debug('diluted ' + up.size() + ' line(s) x' + DILUTION);
    for (Id qid : quoteIds) { repriceQuote(qid); }

    // --- pass 2: restore the real hours, reprice to settle ---
    List<QuoteLineItem> restore = new List<QuoteLineItem>();
    for (Id lid : originalQty.keySet()) {
        restore.add(new QuoteLineItem(Id = lid, Quantity = originalQty.get(lid)));
    }
    update restore;
    System.debug('restored original hours on ' + restore.size() + ' line(s)');
    for (Id qid : quoteIds) { repriceQuote(qid); }

    for (QuoteLineItem a : [SELECT Id, Quantity, UnitPrice, UnitCost, TotalCost, Margin
                            FROM QuoteLineItem WHERE Id IN :originalQty.keySet()]) {
        System.debug('RESULT ' + a.Id + ' qty=' + a.Quantity + ' UnitPrice=' + a.UnitPrice
            + ' UnitCost=' + a.UnitCost + ' TotalCost=' + a.TotalCost + ' Margin=' + a.Margin);
    }
}

// Same mechanism RepriceOrdersUtility uses, pointed at Quote instead of Order.
void repriceQuote(Id quoteId) {
    try {
        RevSalesTrxn.RecordResource rec =
            new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', quoteId);
        RevSalesTrxn.RecordWithReferenceRequest req =
            new RevSalesTrxn.RecordWithReferenceRequest('refQuote', rec);

        RevSalesTrxn.GraphRequest graph =
            new RevSalesTrxn.GraphRequest('refreshQuoteGraph',
                new List<RevSalesTrxn.RecordWithReferenceRequest>{ req });

        RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
            graph,
            RevSalesTrxn.PricingPreferenceEnum.SYSTEM,
            RevSalesTrxn.ConfigurationExecutionEnum.SYSTEM,
            new RevSalesTrxn.ConfigurationOptionsInput(),
            null
        );
        System.debug('repriced ' + quoteId);
    } catch (Exception e) {
        System.debug('reprice FAILED ' + quoteId + ' : ' + e.getMessage());
    }
}
