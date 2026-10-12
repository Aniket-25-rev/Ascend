/**
 * Invocable Apex class called from the Create Order From Quote Custom flow.
 * Sets PricingTermCount (and optionally ServiceDate / EndDate) on OrderItem
 * records, then asynchronously stamps NetTotalPrice after Revenue Cloud's
 * Instant Pricing has completed.
 *
 * Why two steps?
 * Revenue Cloud's Instant Pricing runs after Order activation and can
 * recalculate EndDate from PricingTermCount. This class sets PricingTermCount
 * synchronously so Instant Pricing derives the correct EndDate. Then
 * SetOrderItemNetTotalPrice is enqueued to run after Instant Pricing has
 * settled, preventing price values from being overwritten.
 *
 * Entry point  : execute()
 * Called from  : Flow — Create Order From Quote Custom
 * Enqueues     : SetOrderItemNetTotalPrice
 *
 * Date resolution priority (per OrderItem):
 *   1. OrderItem's own ServiceDate / EndDate (if already populated)
 *   2. Linked QuoteLineItem's StartDate / EndDate (most accurate per-line date)
 *   3. Request-level fallback startDate / endDate (Flow-supplied)
 *   4. Order.EffectiveDate / Order.EndDate (last resort)
 *
 * PricingTermCount resolution priority (non-ramp items):
 *   1. QuoteLineItem.PricingTermCount (RC's own calculation — preserves MTM
 *      fractional values such as 0.98 that date-based recalc would round to 1)
 *   2. calcPTC(startDate, endDate) — date-based fallback
 */
public class SetOrderItemPricingTerm {

    /**
     * Input received from the Flow invocable action.
     *
     * orderId   : (required) The Order whose items need PricingTermCount set
     * startDate : (optional) Fallback start date when OrderItem.ServiceDate is null
     * endDate   : (optional) Fallback end date when OrderItem.EndDate is null
     * rampOnly  : (optional) When true, only ramp Order Items are processed;
     *             non-ramp items are skipped entirely (used during ramp-schedule setup)
     */
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

    /**
     * Invocable entry point. Processes each Request in the batch:
     *   1. Queries all Orders and their OrderItems for the given IDs.
     *   2. Resolves ProductSellingModel type (to skip OneTime items).
     *   3. Resolves QuoteLineItem dates and PricingTermCount for per-line accuracy.
     *   4. For ramp items: syncs ServiceDate, EndDate, PricingTermCount from the QLI.
     *   5. For non-ramp items: calculates and sets PricingTermCount (and EndDate if missing).
     *   6. Enqueues SetOrderItemNetTotalPrice to stamp prices after Instant Pricing.
     *
     * @param requests  List of Request objects from the Flow
     */
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

        // Fetch Order-level fallback dates (used when OrderItem dates are absent)
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

        // Collect all ProductSellingModel and QuoteLineItem IDs needed for lookups
        Set<Id> psmIds   = new Set<Id>();
        Set<Id> allQLIIds = new Set<Id>();
        for (OrderItem oi : items) {
            if (oi.ProductSellingModelId != null) psmIds.add(oi.ProductSellingModelId);
            if (oi.QuoteLineItemId != null) allQLIIds.add(oi.QuoteLineItemId);
        }

        // Map PSM ID → SellingModelType to identify and skip OneTime products
        Map<Id, String> psmTypeMap = new Map<Id, String>();
        if (!psmIds.isEmpty()) {
            for (ProductSellingModel psm : [
                SELECT Id, SellingModelType FROM ProductSellingModel WHERE Id IN :psmIds
            ]) psmTypeMap.put(psm.Id, psm.SellingModelType);
        }

        // Map QLI ID → QLI for per-line date and PricingTermCount resolution
        Map<Id, QuoteLineItem> qliMap = new Map<Id, QuoteLineItem>();
        if (!allQLIIds.isEmpty()) {
            for (QuoteLineItem qli : [
                SELECT Id, StartDate, EndDate, PricingTermCount FROM QuoteLineItem WHERE Id IN :allQLIIds
            ]) qliMap.put(qli.Id, qli);
        }

        List<OrderItem> toUpdate = new List<OrderItem>();
        for (OrderItem oi : items) {
            Request req0 = requestMap.get(oi.OrderId);
            Boolean isRampOnly = (req0 != null && req0.rampOnly == true);

            // ---- Ramp Order Items ----
            // Sync ServiceDate, PricingTermCount, and EndDate directly from the
            // linked QLI (each ramp segment has its own unique dates on the QLI).
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

            // When rampOnly=true, non-ramp items are intentionally skipped
            if (isRampOnly) continue;

            // OneTime products must not have EndDate or PricingTermCount — skip
            String  modelType = oi.ProductSellingModelId != null ? psmTypeMap.get(oi.ProductSellingModelId) : null;
            Boolean isOneTime = 'OneTime'.equalsIgnoreCase(modelType);
            if (isOneTime) continue;

            // ---- Non-ramp, Term-Defined / Evergreen Order Items ----
            Request req = requestMap.get(oi.OrderId);
            Order   ord = orderMap.get(oi.OrderId);
            QuoteLineItem linkedQLI = oi.QuoteLineItemId != null ? qliMap.get(oi.QuoteLineItemId) : null;

            /*
             * Date resolution — per-QLI dates take precedence over shared fallbacks.
             *
             * Different Order Items on the same Order (e.g. an Amend/Renew/Cancel order
             * covering products added to the contract at different times) can have
             * genuinely different original StartDate/EndDate. A single shared fallback
             * value is only ever correct for a brand-new, single-term order (New
             * Business). Using it for every line on a Cancellation order caused the
             * line with the earliest original EndDate to overwrite every other line's
             * EndDate, desyncing them from their Asset's real LifecycleEndDate and
             * blocking cancellation ("Lifecycle End Date on the asset is different from
             * the End Date on the line item").
             */
            Date sd = oi.ServiceDate;
            if (sd == null && linkedQLI != null && linkedQLI.StartDate != null) sd = linkedQLI.StartDate;
            if (sd == null && req != null) sd = req.startDate;
            if (sd == null && ord != null) sd = ord.EffectiveDate;

            Date ed = oi.EndDate;
            if (ed == null && linkedQLI != null && linkedQLI.EndDate != null) ed = linkedQLI.EndDate;
            if (ed == null && req != null) ed = req.endDate;
            if (ed == null && ord != null) ed = ord.EndDate;

            if (sd == null || ed == null) continue;

            /*
             * PricingTermCount resolution — prefer QLI.PricingTermCount so the
             * OrderItem exactly matches the Quote (e.g. 0.98 for MTM quotes, not
             * 1.0 from date-based recalc). Only fall back to calcPTC when the QLI
             * value is absent or zero.
             */
            Decimal ptc;
            if (linkedQLI != null && linkedQLI.PricingTermCount != null && linkedQLI.PricingTermCount > 0) {
                ptc = linkedQLI.PricingTermCount.setScale(2, System.RoundingMode.HALF_UP);
            } else {
                ptc = calcPTC(sd, ed);
            }
            if (ptc == null) continue;

            Boolean changed = false;
            if (ptc != oi.PricingTermCount) {
                oi.PricingTermCount = ptc;
                changed = true;
            }
            // Stamp EndDate only if it was previously null (avoids overriding a valid value)
            if (oi.EndDate == null && ed != null) {
                oi.EndDate = ed;
                changed = true;
            }
            if (changed) toUpdate.add(oi);
        }

        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }

        /*
         * Enqueue NetTotalPrice calculation after Instant Pricing has settled.
         * Instant Pricing recalculates EndDate from PricingTermCount in a
         * post-activation step; running NetTotalPrice in a separate Queueable
         * ensures it reads the final stable prices and is not overwritten.
         */
        if (!orderIds.isEmpty()) {
            System.enqueueJob(new SetOrderItemNetTotalPrice(orderIds));
        }
    }

    /**
     * Calculates a decimal PricingTermCount matching Salesforce Revenue Cloud's
     * own formula:
     *   fullMonths + (remainingDays / daysInThatCalendarMonth)
     *
     * EndDate is treated as inclusive — an extra day is added before computing
     * the remainder so the partial month fraction is correct.
     *
     * This formula must stay in sync with UpdateOrderProductEndDate.calcPTC,
     * which contains an identical implementation.
     *
     * @param serviceDate  The OrderItem's start date
     * @param endDate      The OrderItem's end date (inclusive)
     * @return             Decimal PricingTermCount, or null if either date is null
     */
    private static Decimal calcPTC(Date serviceDate, Date endDate) {
        if (serviceDate == null || endDate == null) return null;
        Integer fullMonths = serviceDate.monthsBetween(endDate);
        Date    baseDate   = serviceDate.addMonths(fullMonths);
        // monthsBetween can overshoot when endDate falls before the same day-of-month
        while (fullMonths > 0 && baseDate > endDate) {
            fullMonths--;
            baseDate = serviceDate.addMonths(fullMonths);
        }
        Integer remainDays  = baseDate.daysBetween(endDate.addDays(1)); // inclusive end
        Date    monthStart  = Date.newInstance(baseDate.year(), baseDate.month(), 1);
        Integer daysInMonth = monthStart.daysBetween(monthStart.addMonths(1));
        return (fullMonths + (Decimal) remainDays / daysInMonth).setScale(2, System.RoundingMode.HALF_UP);
    }
}