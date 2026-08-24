public class SetOrderItemNetTotalPrice implements Queueable {

    private Set<Id> orderIds;

    public SetOrderItemNetTotalPrice(Set<Id> orderIds) {
        this.orderIds = orderIds;
    }

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

            if (ntp != null && ntp != oi.NetTotalPrice) {
                oi.NetTotalPrice = ntp;
                toUpdate.add(oi);
            }
        }

        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }
    }
}