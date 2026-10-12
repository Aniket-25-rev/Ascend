trigger OrderItemPTCTrigger on OrderItem (before insert, before update) {
    // Intercept Revenue Cloud Instant Pricing before it commits PricingTermCount as a
    // rounded integer. We compute the decimal value from ServiceDate/EndDate and assign
    // it directly to Trigger.new — Salesforce commits our value, not RC's integer.
    //
    // Runs on every before-insert/before-update, including RC's own follow-up saves —
    // unlike a record-triggered Flow reacting to this same change, a trigger has no
    // "fires once per transaction" limit, so it reliably wins even if RC rewrites
    // PricingTermCount more than once in the same transaction.
    //
    // Uses the linked QuoteLineItem's PricingTermCount only while the OrderItem dates
    // still equal the QLI dates (so MTM lines keep e.g. 0.98, not 1.0); once the dates
    // are moved (e.g. Change Contract Start Date flow) the term follows the new dates.
    // See OrderItemPTCCalculator.resolve.

    Set<Id> psmIds = new Set<Id>();
    Set<Id> qliIds = new Set<Id>();
    for (OrderItem oi : Trigger.new) {
        if (oi.ProductSellingModelId != null) psmIds.add(oi.ProductSellingModelId);
        if (oi.QuoteLineItemId != null) qliIds.add(oi.QuoteLineItemId);
    }
    Map<Id, String> psmTypeMap = new Map<Id, String>();
    if (!psmIds.isEmpty()) {
        for (ProductSellingModel psm : [
            SELECT Id, SellingModelType FROM ProductSellingModel WHERE Id IN :psmIds
        ]) psmTypeMap.put(psm.Id, psm.SellingModelType);
    }
    Map<Id, QuoteLineItem> qliMap = new Map<Id, QuoteLineItem>();
    if (!qliIds.isEmpty()) {
        qliMap = new Map<Id, QuoteLineItem>([
            SELECT Id, StartDate, EndDate, PricingTermCount FROM QuoteLineItem WHERE Id IN :qliIds
        ]);
    }

    for (OrderItem oi : Trigger.new) {
        if (oi.ServiceDate == null || oi.EndDate == null) continue;
        String modelType = oi.ProductSellingModelId != null ? psmTypeMap.get(oi.ProductSellingModelId) : null;
        if ('OneTime'.equalsIgnoreCase(modelType)) continue;

        QuoteLineItem qli = oi.QuoteLineItemId != null ? qliMap.get(oi.QuoteLineItemId) : null;
        Decimal ptc = OrderItemPTCCalculator.resolve(
            oi.ServiceDate, oi.EndDate,
            qli != null ? qli.StartDate : null,
            qli != null ? qli.EndDate : null,
            qli != null ? qli.PricingTermCount : null
        );

        if (ptc != oi.PricingTermCount) {
            oi.PricingTermCount = ptc;
        }
    }
}