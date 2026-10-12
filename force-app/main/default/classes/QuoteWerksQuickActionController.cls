public with sharing class QuoteWerksQuickActionController {
    public class QuoteContext {
        @AuraEnabled public String opportunityId;
        @AuraEnabled public String opportunityName;
        @AuraEnabled public String accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String contactId;
        @AuraEnabled public String contactName;
        @AuraEnabled public String contactEmail;
        @AuraEnabled public String billingStreet;
        @AuraEnabled public String billingCity;
        @AuraEnabled public String billingState;
        @AuraEnabled public String billingPostalCode;
        @AuraEnabled public String billingCountry;
        @AuraEnabled public String shippingStreet;
        @AuraEnabled public String shippingCity;
        @AuraEnabled public String shippingState;
        @AuraEnabled public String shippingPostalCode;
        @AuraEnabled public String shippingCountry;
        @AuraEnabled public String accountPhone;
        @AuraEnabled public String accountFax;
    }

    @AuraEnabled(cacheable=true)
    public static QuoteContext getQuoteContext(Id opportunityId) {
        if (opportunityId == null) {
            throw new AuraHandledException('An Opportunity record is required.');
        }

        try {
            List<Opportunity> opportunities = [
                SELECT Id, Name, AccountId
                FROM Opportunity
                WHERE Id = :opportunityId
                WITH USER_MODE
                LIMIT 1
            ];

            if (opportunities.isEmpty()) {
                throw new AuraHandledException(
                    'The Opportunity could not be found or you do not have access to it.'
                );
            }

            Opportunity opportunity = opportunities[0];

            if (opportunity.AccountId == null) {
                throw new AuraHandledException(
                    'This Opportunity must have an Account before creating a QuoteWerks quote.'
                );
            }

            List<Account> accounts = [
                SELECT
                    Id,
                    Name,
                    BillingStreet,
                    BillingCity,
                    BillingState,
                    BillingPostalCode,
                    BillingCountry,
                    ShippingStreet,
                    ShippingCity,
                    ShippingState,
                    ShippingPostalCode,
                    ShippingCountry,
                    Phone,
                    Fax
                FROM Account
                WHERE Id = :opportunity.AccountId
                WITH USER_MODE
                LIMIT 1
            ];

            if (accounts.isEmpty()) {
                throw new AuraHandledException(
                    'The related Account could not be found or you do not have access to it.'
                );
            }

            Account account = accounts[0];

            List<OpportunityContactRole> contactRoles = [
                SELECT ContactId, IsPrimary, CreatedDate
                FROM OpportunityContactRole
                WHERE OpportunityId = :opportunity.Id
                ORDER BY IsPrimary DESC, CreatedDate ASC
                LIMIT 1
            ];

            Contact contact;

            if (!contactRoles.isEmpty() && contactRoles[0].ContactId != null) {
                List<Contact> contacts = [
                    SELECT Id, Name, Email
                    FROM Contact
                    WHERE Id = :contactRoles[0].ContactId
                    WITH USER_MODE
                    LIMIT 1
                ];

                if (!contacts.isEmpty()) {
                    contact = contacts[0];
                }
            }

            QuoteContext context = new QuoteContext();
            context.opportunityId = String.valueOf(opportunity.Id);
            context.opportunityName = opportunity.Name;
            context.accountId = String.valueOf(account.Id);
            context.accountName = account.Name;
            context.contactId = contact == null ? null : String.valueOf(contact.Id);
            context.contactName = contact == null ? null : contact.Name;
            context.contactEmail = contact == null ? null : contact.Email;
            context.billingStreet = account.BillingStreet;
            context.billingCity = account.BillingCity;
            context.billingState = account.BillingState;
            context.billingPostalCode = account.BillingPostalCode;
            context.billingCountry = account.BillingCountry;
            context.shippingStreet = account.ShippingStreet;
            context.shippingCity = account.ShippingCity;
            context.shippingState = account.ShippingState;
            context.shippingPostalCode = account.ShippingPostalCode;
            context.shippingCountry = account.ShippingCountry;
            context.accountPhone = account.Phone;
            context.accountFax = account.Fax;

            return context;
        } catch (AuraHandledException exceptionInstance) {
            throw exceptionInstance;
        } catch (Exception exceptionInstance) {
            throw new AuraHandledException(
                'Unable to prepare QuoteWerks information. Verify your record and field permissions.'
            );
        }
    }
}