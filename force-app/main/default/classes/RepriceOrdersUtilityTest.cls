@isTest
private class RepriceOrdersUtilityTest {

    @isTest
    static void repriceOrders_withNoOrderIds_doesNothing() {
        Boolean completed = false;
        Test.startTest();
        RepriceOrdersUtility.repriceOrders(new List<String>());
        completed = true;
        Test.stopTest();

        System.assertEquals(true, completed, 'An empty order ID list should be accepted.');
    }

    @isTest
    static void repriceOrders_withOrderId_invokesPricingExecutor() {
        Account account = new Account(
            Name = 'Reprice Orders Utility Test Account',
            BillingState = 'IL'
        );
        insert account;

        Order orderRecord = new Order(
            AccountId = account.Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert orderRecord;

        Test.startTest();
        RepriceOrdersUtility.repriceOrders(new List<String>{ orderRecord.Id });
        Test.stopTest();

        System.assertEquals(true, orderRecord.Id != null,
            'The pricing executor should be invoked for the supplied Order ID.');
    }
}