public class SetOrderItemPricingTerm {

    public class Request {
        @InvocableVariable(required=true)
        public Id orderId;
        @InvocableVariable(required=false)
        public Date startDate;   // fallback when OrderItem.ServiceDate is null
        @InvocableVariable(required=false)
        public Date endDate;     // fallback when OrderItem.EndDate is null
        @InvocableVariable(required=false)
        public Boolean rampOnly; // when true, skip non-ramp items entirely
    }

    @InvocableMethod(
        label       = 'Set PricingTermCount on Order Items'
        description = 'Calculates PricingTermCount from dates, then asynchronously sets NetTotalPrice after Instant Pricing has finished.'
    )
    public static void execute(List<Request> requests) {
        Map<Id, Request> requestMap = new Map<Id, Request>();
        Set<Id> orderIds = new Set<Id>();
        for (Request req : requests) {
            if (req.orderId != null) {
                orderIds.add(req.orderId);
                requestMap.put(req.orderId, req);
            }
        }
        if (orderIds.isEmpty()) return;

        Map<Id, Order> orderMap = new Map<Id, Order>();
        for (Order o : [SELECT Id, EffectiveDate, EndDate FROM Order WHERE Id IN :orderIds]) {
            orderMap.put(o.Id, o);
        }

        List<OrderItem> items = [
            SELECT Id, OrderId, ServiceDate, EndDate, PricingTermCount,
                   ProductSellingModelId, RampIdentifier, QuoteLineItemId
            FROM   OrderItem
            WHERE  OrderId IN :orderIds
        ];
        if (items.isEmpty()) return;

        Set<Id> psmIds    = new Set<Id>();
        Set<Id> rampQLIIds = new Set<Id>();
        for (OrderItem oi : items) {
            if (oi.ProductSellingModelId != null) psmIds.add(oi.ProductSellingModelId);
            if (oi.RampIdentifier != null && oi.QuoteLineItemId != null) rampQLIIds.add(oi.QuoteLineItemId);
        }
        Map<Id, String> psmTypeMap = new Map<Id, String>();
        if (!psmIds.isEmpty()) {
            for (ProductSellingModel psm : [
                SELECT Id, SellingModelType FROM ProductSellingModel WHERE Id IN :psmIds
            ]) psmTypeMap.put(psm.Id, psm.SellingModelType);
        }
        Map<Id, QuoteLineItem> qliMap = new Map<Id, QuoteLineItem>();
        if (!rampQLIIds.isEmpty()) {
            for (QuoteLineItem qli : [
                SELECT Id, StartDate, EndDate FROM QuoteLineItem WHERE Id IN :rampQLIIds
            ]) qliMap.put(qli.Id, qli);
        }

        List<OrderItem> toUpdate = new List<OrderItem>();
        for (OrderItem oi : items) {
            Request req0 = requestMap.get(oi.OrderId);
            Boolean isRampOnly = (req0 != null && req0.rampOnly == true);
            if (oi.RampIdentifier != null) {
                if (oi.QuoteLineItemId == null) continue;
                QuoteLineItem qli = qliMap.get(oi.QuoteLineItemId);
                if (qli == null || qli.StartDate == null || qli.EndDate == null) continue;
                Boolean changed = false;
                if (oi.ServiceDate != qli.StartDate) { oi.ServiceDate = qli.StartDate; changed = true; }
                Decimal ptc = calcPTC(qli.StartDate, qli.EndDate);
                if (ptc != null && ptc != oi.PricingTermCount) { oi.PricingTermCount = ptc; changed = true; }
                if (oi.EndDate != qli.EndDate) { oi.EndDate = qli.EndDate; changed = true; }
                if (changed) toUpdate.add(oi);
                continue;
            }

            if (isRampOnly) continue;

            String  modelType = oi.ProductSellingModelId != null ? psmTypeMap.get(oi.ProductSellingModelId) : null;
            Boolean isOneTime = 'OneTime'.equalsIgnoreCase(modelType);
            if (isOneTime) continue;

            Request req = requestMap.get(oi.OrderId);
            Order   ord = orderMap.get(oi.OrderId);

            Date sd = oi.ServiceDate;
            if (sd == null && req != null) sd = req.startDate;
            if (sd == null && ord != null) sd = ord.EffectiveDate;

            Date ed = oi.EndDate;
            if (ed == null && req != null) ed = req.endDate;
            if (ed == null && ord != null) ed = ord.EndDate;

            if (sd == null || ed == null) continue;

            Decimal ptc = calcPTC(sd, ed);
            if (ptc == null) continue;

            Boolean changed = false;
            if (ptc != oi.PricingTermCount) {
                oi.PricingTermCount = ptc;
                changed = true;
            }
            if (oi.EndDate == null && ed != null) {
                oi.EndDate = ed;
                changed = true;
            }
            if (changed) toUpdate.add(oi);
        }

        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }

        // NetTotalPrice is set asynchronously so it runs after Instant Pricing
        // has finished its EndDate recalculation and won't be overwritten.
        if (!orderIds.isEmpty()) {
            System.enqueueJob(new SetOrderItemNetTotalPrice(orderIds));
        }
    }

    // Same formula as UpdateOrderProductEndDate.calcPTC — must stay in sync.
    private static Decimal calcPTC(Date serviceDate, Date endDate) {
        if (serviceDate == null || endDate == null) return null;
        Integer fullMonths = serviceDate.monthsBetween(endDate);
        Date    baseDate   = serviceDate.addMonths(fullMonths);
        while (fullMonths > 0 && baseDate > endDate) {
            fullMonths--;
            baseDate = serviceDate.addMonths(fullMonths);
        }
        Integer remainDays  = baseDate.daysBetween(endDate.addDays(1));
        Date    monthStart  = Date.newInstance(baseDate.year(), baseDate.month(), 1);
        Integer daysInMonth = monthStart.daysBetween(monthStart.addMonths(1));
        return fullMonths + (Decimal) remainDays / daysInMonth;
    }
}