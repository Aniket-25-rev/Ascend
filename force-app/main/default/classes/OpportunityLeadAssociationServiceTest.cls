@IsTest
private class OpportunityLeadAssociationServiceTest {

    @IsTest
    static void testNoConvertedLeads() {
        Account acc = new Account(Name = 'Test Account');
        insert acc;
        Opportunity opp = new Opportunity(
            Name = 'Test Opp',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        OpportunityLeadAssociationService.Request req = new OpportunityLeadAssociationService.Request();
        req.opportunityId = opp.Id;

        System.Test.startTest();
        List<OpportunityLeadAssociationService.Response> responses =
            OpportunityLeadAssociationService.getLeadAssociation(
                new List<OpportunityLeadAssociationService.Request>{ req }
            );
        System.Test.stopTest();

        System.assertEquals(1, responses.size());
        System.assertEquals(
            'Has Converted Lead: No (0 found)\n' +
            'Logged Activities: No (0 found)\n' +
            'Related Contacts: No (0 found)\n' +
            'Discovery Event: No (0 found)\n' +
            'Project Needs Notes: No (0 found)\n' +
            'Discovery Notes or Files: No (0 found)\n' +
            'Scoping Resource Request: No (0 found)\n' +
            'Opportunity Details Complete: No (1 of 6 filled)\n' +
            'SE on Opportunity Team: No (0 found)\n' +
            'EVP Approval: No (Not Submitted)\n' +
            'Project Record Created: No (0 found)\n' +
            'Project Resources Assigned: No (0 found)',
            responses[0].promptText
        );
    }

    @IsTest
    static void testWithConvertedLead() {
        Account acc = new Account(Name = 'Test Account 2');
        insert acc;
        Opportunity opp = new Opportunity(
            Name = 'Test Opp 2',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Lead ld = new Lead(LastName = 'Converted', Company = 'Acme', Status = 'Open - Not Contacted');
        insert ld;

        LeadStatus convertStatus = [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1];
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(ld.Id);
        lc.setConvertedStatus(convertStatus.MasterLabel);
        lc.setOpportunityId(opp.Id);
        Database.LeadConvertResult lcr = Database.convertLead(lc);
        System.assert(lcr.isSuccess());

        OpportunityLeadAssociationService.Request req = new OpportunityLeadAssociationService.Request();
        req.opportunityId = opp.Id;

        System.Test.startTest();
        List<OpportunityLeadAssociationService.Response> responses =
            OpportunityLeadAssociationService.getLeadAssociation(
                new List<OpportunityLeadAssociationService.Request>{ req }
            );
        System.Test.stopTest();

        System.assertEquals(1, responses.size());
    }
}