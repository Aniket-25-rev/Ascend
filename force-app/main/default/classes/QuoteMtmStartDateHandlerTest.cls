@IsTest
private class QuoteMtmStartDateHandlerTest {

    // Quote.OriginalActionType is read-only in Apex (system-managed by ARM),
    // so Amend quotes are built in memory via JSON.deserialize.
    private static Quote amendQuote(Id quoteId, Id contractId, Boolean mtm, Date startDate) {
        Map<String, Object> raw = new Map<String, Object>{
            'Id'                 => quoteId,
            'ContractId'         => contractId,
            'OriginalActionType' => 'Amend',
            'Month_to_Month__c'  => mtm,
            'StartDate'          => startDate == null ? null : String.valueOf(startDate)
        };
        return (Quote) JSON.deserialize(JSON.serialize(raw), Quote.class);
    }

    private static Id fakeId(Schema.SObjectType t, Integer n) {
        String prefix = t.getDescribe().getKeyPrefix();
        String body   = String.valueOf(n).leftPad(12, '0');
        return Id.valueOf(prefix + body);
    }

    @IsTest
    static void mtmAmend_startDateSetToContractEnd() {
        Id qId = fakeId(Quote.SObjectType, 1);
        Id cId = fakeId(Contract.SObjectType, 1);
        Date contractEnd = Date.newInstance(2027, 9, 30);
        Quote q = amendQuote(qId, cId, true, Date.newInstance(2026, 10, 1));

        Integer changed = QuoteMtmStartDateHandler.applyContractEndDate(
            new List<Quote>{ q }, new Map<Id, Date>{ cId => contractEnd });

        System.assertEquals(1, changed);
        System.assertEquals(contractEnd, q.StartDate);
    }

    @IsTest
    static void mtmAmend_alreadyAligned_noChange() {
        Id qId = fakeId(Quote.SObjectType, 2);
        Id cId = fakeId(Contract.SObjectType, 2);
        Date contractEnd = Date.newInstance(2027, 9, 30);
        Quote q = amendQuote(qId, cId, true, contractEnd);

        System.assertEquals(0, QuoteMtmStartDateHandler.applyContractEndDate(
            new List<Quote>{ q }, new Map<Id, Date>{ cId => contractEnd }));
        System.assertEquals(contractEnd, q.StartDate);
    }

    @IsTest
    static void notMtm_orNoContractEnd_untouched() {
        Id cId = fakeId(Contract.SObjectType, 3);
        Date original = Date.newInstance(2026, 10, 1);

        Quote notMtm = amendQuote(fakeId(Quote.SObjectType, 3), cId, false, original);
        Quote noEnd  = amendQuote(fakeId(Quote.SObjectType, 4), cId, true,  original);

        System.assertEquals(0, QuoteMtmStartDateHandler.applyContractEndDate(
            new List<Quote>{ notMtm }, new Map<Id, Date>{ cId => Date.newInstance(2027, 9, 30) }));
        System.assertEquals(original, notMtm.StartDate);

        System.assertEquals(0, QuoteMtmStartDateHandler.applyContractEndDate(
            new List<Quote>{ noEnd }, new Map<Id, Date>()));
        System.assertEquals(original, noEnd.StartDate);
    }

    @IsTest
    static void isMtmAmend_requiresAmendMtmAndContract() {
        Id cId = fakeId(Contract.SObjectType, 5);
        System.assertEquals(true,  QuoteMtmStartDateHandler.isMtmAmend(amendQuote(fakeId(Quote.SObjectType, 5), cId, true, null)));
        System.assertEquals(false, QuoteMtmStartDateHandler.isMtmAmend(amendQuote(fakeId(Quote.SObjectType, 6), cId, false, null)));
        System.assertEquals(false, QuoteMtmStartDateHandler.isMtmAmend(amendQuote(fakeId(Quote.SObjectType, 7), null, true, null)));
        System.assertEquals(false, QuoteMtmStartDateHandler.isMtmAmend(new Quote(Month_to_Month__c = true)));
        System.assertEquals(false, QuoteMtmStartDateHandler.isMtmAmend(null));
    }

    @IsTest
    static void trigger_nonAmendQuoteUpdate_unaffected() {
        // Real DML path: a plain (New Business) quote must save untouched.
        Account acc = new Account(
            Name = 'MTM Trigger Test', BillingStreet = '1 Test St', BillingCity = 'Austin',
            BillingState = 'TX', BillingPostalCode = '78701', BillingCountry = 'US');
        insert acc;
        Opportunity opp = new Opportunity(
            Name = 'MTM Trigger Opp', AccountId = acc.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30));
        insert opp;
        Quote q = new Quote(
            Name = 'MTM Trigger Quote', OpportunityId = opp.Id, Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId(),
            StartDate = Date.newInstance(2026, 10, 1), Month_to_Month__c = true);
        insert q;

        Test.startTest();
        q.Description = 'touch';
        update q;
        Test.stopTest();

        System.assertEquals(Date.newInstance(2026, 10, 1),
            [SELECT StartDate FROM Quote WHERE Id = :q.Id].StartDate);
    }
}