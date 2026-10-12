public without sharing class OrderProductTableController {
    

    @AuraEnabled(cacheable=false)
    public static List<OrderItem> getOrderProducts(String orderId) {
        return [SELECT Id, OrderItemGroup.Id, OrderItemGroup.Name, Product2.Id,
            Product2.Name, Product2.ProductCode, Product2.Description,
            OrderItemGroup.StartDate, OrderItemGroup.EndDate, OrderItemGroup.OrderId,
            OrderItemGroup.SortOrder, OrderItemGroup.Type, OrderItemGroup.Description,
            OrderItemGroup.SummarySubtotal, OrderItemGroup.IsRamped, OrderItemGroup.SegmentType,
            OrderItemGroup.CreatedById, OrderItemGroup.LastModifiedById,
            OrderItemGroup.CreatedDate, OrderItemGroup.LastModifiedDate,
            ServiceDate,
            EndDate, Quantity, Discount, DiscountAmount, ListPrice,
            QuoteLineItem.Id, QuoteLineItem.MRR__c, NetUnitPrice, NetTotalPrice, PricingTermCount,
            Description, LineNumber, QuantityUnitOfMeasure.Name, TotalLineAmount, TotalPrice,
            UnitPrice, PartnerDiscountPercent, SubscriptionTerm, StartQuantity, EndQuantity,
            IsPrimarySegment, RampIdentifier,
            Order.Opportunity.RecordType.Name
            FROM OrderItem
            WHERE OrderId = :orderId
            ORDER BY OrderItemGroup.StartDate ASC, Product2.Name ASC];
    }
}