/**
 * QuoteLineItemUpliftHandlerTest
 * Integration-style unit tests for QuoteLineItemUpliftHandler.
 * Tests are isolated with @TestSetup data and mock objects.
 */
@IsTest
private class QuoteLineItemUpliftHandlerTest {

    @TestSetup
    static void makeData() {
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Opportunity opp = new Opportunity(
            Name        = 'Test Opp',
            AccountId   = acc.Id,
            StageName   = 'Prospecting',
            CloseDate   = Date.today().addDays(30)
        );
        insert opp;

        Product2 prod = new Product2(Name = 'Test Product', IsActive = true);
        insert prod;

        Id stdPBId = Test.getStandardPricebookId();
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = stdPBId,
            Product2Id   = prod.Id,
            UnitPrice    = 100,
            IsActive     = true
        );
        insert pbe;

        Quote q = new Quote(
            Name         = 'Test Quote',
            OpportunityId= opp.Id,
            Pricebook2Id = stdPBId
        );
        insert q;
    }

    private static Quote getTestQuote() {
        return [SELECT Id, Pricebook2Id FROM Quote LIMIT 1];
    }
    private static PricebookEntry getTestPbe() {
        return [SELECT Id, UnitPrice FROM PricebookEntry LIMIT 1];
    }

    @IsTest
    static void testFilterChanged_noUplift() {
        Quote q   = getTestQuote();
        PricebookEntry pbe = getTestPbe();

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId          = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity         = 1,
            UnitPrice        = 100
        );

        Test.startTest();
        insert qli;
        Test.stopTest();

        List<QuoteLinePriceAdjustment> adjs = [
            SELECT Id FROM QuoteLinePriceAdjustment
            WHERE QuoteLineItemId = :qli.Id
        ];
        System.assertEquals(0, adjs.size(), 'No adjustment should be created without uplift');
    }

    @IsTest
    static void testPercentageMarkup_createsAdjustment() {
        Quote q   = getTestQuote();
        PricebookEntry pbe = getTestPbe();

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId                         = q.Id,
            PricebookEntryId                = pbe.Id,
            Quantity                        = 2,
            UnitPrice                       = 100,
            Custom_Uplift_Price_Percentage__c = -10 // -10% = 10% markup
        );

        Test.startTest();
        insert qli;
        Test.stopTest();

        List<QuoteLinePriceAdjustment> adjs = [
            SELECT Id, AdjustmentType, AdjustmentValue, Description
            FROM QuoteLinePriceAdjustment
            WHERE QuoteLineItemId = :qli.Id
        ];
        System.assertEquals(1, adjs.size(), 'One adjustment should be created');
        System.assertEquals('AdjustmentPercentage', adjs[0].AdjustmentType);
        System.assertEquals(-10, adjs[0].AdjustmentValue);
        System.assertEquals('Custom Markup Applied', adjs[0].Description);
    }

    @IsTest
    static void testAmountMarkup_createsAdjustment() {
        Quote q   = getTestQuote();
        PricebookEntry pbe = getTestPbe();

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId                         = q.Id,
            PricebookEntryId                = pbe.Id,
            Quantity                        = 1,
            UnitPrice                       = 100,
            Custom_Uplift_Price_Amount__c   = -25 // -25 amount = $25 markup
        );

        Test.startTest();
        insert qli;
        Test.stopTest();

        List<QuoteLinePriceAdjustment> adjs = [
            SELECT Id, AdjustmentType, AdjustmentValue, Description
            FROM QuoteLinePriceAdjustment
            WHERE QuoteLineItemId = :qli.Id
        ];
        System.assertEquals(1, adjs.size(), 'One adjustment should be created');
        System.assertEquals('AdjustmentAmount', adjs[0].AdjustmentType);
        System.assertEquals(-25, adjs[0].AdjustmentValue);
        System.assertEquals('Custom Markup Applied', adjs[0].Description);
    }

    @IsTest
    static void testPositiveAmount_createsDiscountAdjustment() {
        Quote q   = getTestQuote();
        PricebookEntry pbe = getTestPbe();

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId                       = q.Id,
            PricebookEntryId              = pbe.Id,
            Quantity                      = 1,
            UnitPrice                     = 100,
            Custom_Uplift_Price_Amount__c = 20 // $20 discount
        );

        Test.startTest();
        insert qli;
        Test.stopTest();

        List<QuoteLinePriceAdjustment> adjs = [
            SELECT Id, Description
            FROM QuoteLinePriceAdjustment
            WHERE QuoteLineItemId = :qli.Id
        ];
        System.assertEquals(1, adjs.size(), 'One adjustment should be created');
        System.assertEquals('Custom Discount Applied', adjs[0].Description,
            'Positive amount should be a discount');
    }

    @IsTest
    static void testUpdateUplift_replacesExistingAdjustment() {
        Quote q   = getTestQuote();
        PricebookEntry pbe = getTestPbe();

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId                       = q.Id,
            PricebookEntryId              = pbe.Id,
            Quantity                      = 1,
            UnitPrice                     = 100,
            Custom_Uplift_Price_Amount__c = -10
        );
        insert qli;

        Integer adjsBefore = [
            SELECT COUNT() FROM QuoteLinePriceAdjustment WHERE QuoteLineItemId = :qli.Id
        ];

        // Update to a different uplift
        qli.Custom_Uplift_Price_Amount__c = -20;

        Test.startTest();
        update qli;
        Test.stopTest();

        List<QuoteLinePriceAdjustment> adjs = [
            SELECT AdjustmentValue
            FROM QuoteLinePriceAdjustment
            WHERE QuoteLineItemId = :qli.Id
        ];
        System.assertEquals(1, adjs.size(), 'Still only one adjustment after update');
        System.assertEquals(-20, adjs[0].AdjustmentValue, 'Adjustment value should be updated to -20');
    }
}