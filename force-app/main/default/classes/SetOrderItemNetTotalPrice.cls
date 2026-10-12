public class SetOrderItemNetTotalPrice implements Queueable {

    /** Order IDs passed in from SetOrderItemPricingTerm. */
    private Set<Id> orderIds;

    /**
     * Constructor — receives the set of Order IDs to process.
     *
     * @param orderIds  IDs of Orders whose OrderItems need NetTotalPrice set
     */
    public SetOrderItemNetTotalPrice(Set<Id> orderIds) {
        this.orderIds = orderIds;
    }

    /**
     * Queueable entry point. Queries all non-null-TotalPrice OrderItems for
     * the given Orders, calculates NetTotalPrice for each, and bulk-updates
     * only the records where the value has changed.
     *
     * Two calculation paths exist:
     *
     *   Standard path  (NetUnitPrice is populated):
     *     NetTotalPrice = NetUnitPrice × Quantity × PricingTermCount
     *     Used for new business, amendments, and renewals where Revenue Cloud
     *     provides a per-unit price.
     *
     *   Cancellation path  (NetUnitPrice is null):
     *     NetTotalPrice = TotalPrice
     *     On Cancellation Order Items, Revenue Cloud sets NetUnitPrice to null
     *     and instead places the correct signed credit amount directly in
     *     TotalPrice (via createOrderFromQuote). Using TotalPrice preserves
     *     the credit value without modification.
     *
     * Ramp Order Items (RampIdentifier != null) are skipped because their
     * prices are managed separately by Revenue Cloud's ramp schedule logic.
     *
     * @param context  System-injected Queueable execution context (unused)
     */
    public void execute(QueueableContext context) {
        List<OrderItem> items = [
            SELECT Id, NetUnitPrice, Quantity, PricingTermCount,
                   NetTotalPrice, TotalPrice, RampIdentifier
            FROM   OrderItem
            WHERE  OrderId IN :orderIds
            AND    TotalPrice != null
        ];
        if (items.isEmpty()) return;

        List<OrderItem> toUpdate = new List<OrderItem>();
        for (OrderItem oi : items) {
            // Ramp items are managed by the ramp schedule — skip them
            if (oi.RampIdentifier != null) continue;

            Decimal ntp;
            if (oi.NetUnitPrice != null && oi.PricingTermCount != null && oi.PricingTermCount > 0) {
                // Standard path: NetUnitPrice is available
                ntp = oi.NetUnitPrice * oi.Quantity * oi.PricingTermCount;
            } else if (oi.TotalPrice != null) {
                // Cancellation path: NetUnitPrice is null; TotalPrice is already
                // the correct signed credit amount set by createOrderFromQuote
                ntp = oi.TotalPrice;
            }

            // Only update records where the computed value differs from current
            if (ntp != null && ntp != oi.NetTotalPrice) {
                oi.NetTotalPrice = ntp;
                toUpdate.add(oi);
            }
        }

        if (!toUpdate.isEmpty()) {
            // Partial success — log failures without rolling back the entire batch
            Database.update(toUpdate, false);
        }
    }
}