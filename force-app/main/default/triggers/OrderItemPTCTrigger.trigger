trigger OrderItemPTCTrigger on OrderItem (before insert, before update) {
    // Intercept Revenue Cloud Instant Pricing before it commits PricingTermCount as a
    // rounded integer. We compute the decimal value from ServiceDate/EndDate and assign
    // it directly to Trigger.new — Salesforce commits our value, not RC's integer.

    Set<Id> psmIds = new Set<Id>();
    for (OrderItem oi : Trigger.new) {
        if (oi.ProductSellingModelId != null) psmIds.add(oi.ProductSellingModelId);
    }
    Map<Id, String> psmTypeMap = new Map<Id, String>();
    if (!psmIds.isEmpty()) {
        for (ProductSellingModel psm : [
            SELECT Id, SellingModelType FROM ProductSellingModel WHERE Id IN :psmIds
        ]) psmTypeMap.put(psm.Id, psm.SellingModelType);
    }

    for (OrderItem oi : Trigger.new) {
        if (oi.ServiceDate == null || oi.EndDate == null) continue;
        String modelType = oi.ProductSellingModelId != null ? psmTypeMap.get(oi.ProductSellingModelId) : null;
        if ('OneTime'.equalsIgnoreCase(modelType)) continue;

        // calcPTC: fullMonths + remainingDays/daysInMonth
        Integer fullMonths = oi.ServiceDate.monthsBetween(oi.EndDate);
        Date    base       = oi.ServiceDate.addMonths(fullMonths);
        while (fullMonths > 0 && base > oi.EndDate) {
            fullMonths--;
            base = oi.ServiceDate.addMonths(fullMonths);
        }
        Integer remainDays  = base.daysBetween(oi.EndDate.addDays(1));
        Date    monthStart  = Date.newInstance(base.year(), base.month(), 1);
        Integer daysInMonth = monthStart.daysBetween(monthStart.addMonths(1));
        Decimal ptc         = fullMonths + (Decimal) remainDays / daysInMonth;

        if (ptc != oi.PricingTermCount) {
            oi.PricingTermCount = ptc;
        }
    }
}