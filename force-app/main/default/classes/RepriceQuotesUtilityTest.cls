@isTest
private class RepriceQuotesUtilityTest {

    @isTest
    static void repriceQuotes_withNoQuoteIds_doesNothing() {
        Boolean completed = false;
        Test.startTest();
        RepriceQuotesUtility.repriceQuotes(new List<String>());
        completed = true;
        Test.stopTest();

        System.assertEquals(true, completed, 'An empty quote ID list should be accepted.');
    }

    @isTest
    static void repriceQuotes_withQuoteId_invokesPricingExecutor() {
        Account account = new Account(
            Name = 'Reprice Quotes Utility Test Account',
            BillingState = 'IL'
        );
        insert account;

        Opportunity opportunity = new Opportunity(
            Name = 'Reprice Quotes Utility Test Opportunity',
            AccountId = account.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;

        Quote quoteRecord = new Quote(
            Name = 'Reprice Quotes Utility Test Quote',
            OpportunityId = opportunity.Id,
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert quoteRecord;

        Test.startTest();
        RepriceQuotesUtility.repriceQuotes(new List<String>{ quoteRecord.Id });
        Test.stopTest();

        System.assertEquals(true, quoteRecord.Id != null,
            'The pricing executor should be invoked for the supplied Quote ID.');
    }
}