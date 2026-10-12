@isTest
private class OrderProductTableControllerTest {

    @isTest
    static void getOrderProducts_returnsOrderItemsAndRelationships() {
        Account account = new Account(
            Name = 'Order Product Table Test Account',
            BillingState = 'IL'
        );
        insert account;

        Opportunity opportunity = new Opportunity(
            AccountId = account.Id,
            Name = 'Order Product Table Test Opportunity',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;

        Product2 product = new Product2(
            Name = 'Order Product Table Test Product',
            IsActive = true
        );
        insert product;

        Id standardPricebookId = Test.getStandardPricebookId();

        Pricebook2 standardPricebook = new Pricebook2(
            Id = standardPricebookId, 
            IsActive = true
        );
        update standardPricebook;
        

        PricebookEntry pricebookEntry = new PricebookEntry(
            Pricebook2Id = standardPricebookId,
            Product2Id = product.Id,
            UnitPrice = 100,
            IsActive = true
        );
        insert pricebookEntry;

        Order orderRecord = new Order(
            AccountId = account.Id,
            OpportunityId = opportunity.Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = standardPricebookId
        );
        insert orderRecord;

        OrderItem orderItem = new OrderItem(
            OrderId = orderRecord.Id,
            PricebookEntryId = pricebookEntry.Id,
            Quantity = 2,
            UnitPrice = 100,
            ServiceDate = Date.today()
        );
        insert orderItem;

        Test.startTest();
        List<OrderItem> results = OrderProductTableController.getOrderProducts(orderRecord.Id);
        Test.stopTest();

        opportunity = [SELECT Id, RecordType.Name FROM Opportunity WHERE Id = :opportunity.Id];

        System.assertEquals(1, results.size(), 'The controller should return the order item for the requested order.');
        System.assertEquals(orderItem.Id, results[0].Id, 'The returned order item should match the inserted order item.');
        System.assertEquals(product.Name, results[0].Product2.Name, 'The Product2 relationship should be queried.');
        System.assertEquals(opportunity.RecordType.Name, results[0].Order.Opportunity.RecordType.Name, 'The Opportunity record type name should be queried.');
    }
}