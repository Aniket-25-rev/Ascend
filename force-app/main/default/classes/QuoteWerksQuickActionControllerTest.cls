@IsTest
private class QuoteWerksQuickActionControllerTest {
    @IsTest
    static void returnsOpportunityAccountAndPrimaryContactDetails() {
        Account account = new Account(
            Name = 'Acme Corporation',
            BillingStreet = '100 Main Street',
            BillingCity = 'Dallas',
            BillingState = 'TX',
            BillingPostalCode = '75201',
            BillingCountry = 'United States',
            ShippingStreet = '200 Warehouse Road',
            ShippingCity = 'Fort Worth',
            ShippingState = 'TX',
            ShippingPostalCode = '76102',
            ShippingCountry = 'United States',
            Phone = '555-100-2000',
            Fax = '555-100-2001'
        );
        insert account;

        Contact contact = new Contact(
            FirstName = 'Taylor',
            LastName = 'Morgan',
            Email = 'taylor.morgan@example.com',
            AccountId = account.Id,
            MailingState = 'TX'
        );
        insert contact;

        Opportunity opportunity = new Opportunity(
            Name = 'FY26 QuoteWerks Opportunity',
            AccountId = account.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;

        insert new OpportunityContactRole(
            OpportunityId = opportunity.Id,
            ContactId = contact.Id,
            Role = 'Decision Maker',
            IsPrimary = true
        );

        Test.startTest();
        QuoteWerksQuickActionController.QuoteContext result =
            QuoteWerksQuickActionController.getQuoteContext(opportunity.Id);
        Test.stopTest();

        System.assertEquals(String.valueOf(opportunity.Id), result.opportunityId);
        //System.assertEquals('FY26 QuoteWerks Opportunity', result.opportunityName);
        System.assertEquals(String.valueOf(account.Id), result.accountId);
        System.assertEquals('Acme Corporation', result.accountName);
        System.assertEquals(String.valueOf(contact.Id), result.contactId);
        System.assertEquals('Taylor Morgan', result.contactName);
        System.assertEquals('taylor.morgan@example.com', result.contactEmail);
        System.assertEquals('100 Main Street', result.billingStreet);
        System.assertEquals('200 Warehouse Road', result.shippingStreet);
        System.assertEquals('555-100-2000', result.accountPhone);
    }

}