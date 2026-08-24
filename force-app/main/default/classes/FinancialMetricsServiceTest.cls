@IsTest
private class FinancialMetricsServiceTest {

    private static final String LOB_CYBER = 'Cybersecurity';
    private static final String LOB_DESK = 'Service Desk';
    private static final String LOB_INFRA = 'Infrastructure';
    private static final String LOB_PC = 'Private Cloud';
    private static final String LOB_VOIP = 'VOIP';
    private static final String LOB_UNBUCKETED = 'Snap-On';
    private static final Decimal TERM = 12;

    @TestSetup
    static void setup() {
        Account account = new Account(
            Name = 'Financial Metrics Test Account',
            BillingStreet = '1 Test Way', BillingCity = 'Chicago',
            BillingState = 'IL', BillingPostalCode = '60601', BillingCountry = 'US'
        );
        insert account;

        insert new Contract(
            AccountId = account.Id,
            StartDate = Date.today().addMonths(-6),
            ContractTerm = 12,
            Status = 'Draft'
        );

        insert new List<Product2>{
            new Product2(Name = 'FM Desk Product', IsActive = true),
            new Product2(Name = 'FM Cyber Product', IsActive = true),
            new Product2(Name = 'FM Infra Product', IsActive = true),
            new Product2(Name = 'FM Private Cloud Product', IsActive = true),
            new Product2(Name = 'FM VOIP Product', IsActive = true),
            new Product2(Name = 'FM Bundle Parent Product', IsActive = true)
        };
    }

    private static Contract testContract() {
        return [SELECT Id FROM Contract LIMIT 1];
    }

    private static Account testAccount() {
        return [SELECT Id FROM Account LIMIT 1];
    }

    private static Map<String, Id> productIds() {
        Map<String, Id> byName = new Map<String, Id>();
        for (Product2 product : [SELECT Id, Name FROM Product2 WHERE Name LIKE 'FM %']) {
            byName.put(product.Name, product.Id);
        }
        return byName;
    }

    private static Contract baselineContract(Decimal mrr, Decimal tcv, Map<String, Decimal> byLob) {
        Contract c = testContract();
        c.Current_MRR__c = mrr;
        c.Current_TCV__c = tcv;
        c.TCV__c = tcv;
        if (byLob != null) {
            for (String suffix : byLob.keySet()) {
                c.put('Current_MRR_' + suffix + '__c', byLob.get(suffix));
            }
        }
        update c;
        return c;
    }

    private static Opportunity buildOpportunity(String name, Id contractId, String type) {
        return new Opportunity(
            Name = name, StageName = 'Generate', CloseDate = Date.today().addDays(30),
            ContractId = contractId, Type = type
        );
    }

    private static Quote buildQuote(String name, Id opportunityId, Id contractId, String status) {
        return new Quote(
            Name = name, OpportunityId = opportunityId, ContractId = contractId,
            Status = status, Approval_Scenario__c = 'Financial Metrics test data',
            Contract_Term_Months__c = TERM
        );
    }

    private static void asActionType(Id quoteId, String actionType) {
        if (FinancialMetricsService.actionTypeOverride == null) {
            FinancialMetricsService.actionTypeOverride = new Map<Id, String>();
        }
        FinancialMetricsService.actionTypeOverride.put(quoteId, actionType);
    }

    private static QuoteLineItem line(
        Id quoteId, Id productId, String lob, Decimal quantity, Decimal netUnitPrice, String sellingModelType
    ) {
        Map<String, Object> raw = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineItem' },
            'QuoteId' => quoteId, 'Product2Id' => productId, 'Line_of_Business__c' => lob,
            'Quantity' => quantity, 'NetUnitPrice' => netUnitPrice,
            'NetTotalPrice' => quantity * netUnitPrice * TERM,
            'MRR__c' => quantity * netUnitPrice,
            'SellingModelType' => sellingModelType
        };
        return (QuoteLineItem) JSON.deserialize(JSON.serialize(raw), QuoteLineItem.class);
    }

    private static QuoteLineItem delta(Id quoteId, Id productId, String lob, Decimal quantity, Decimal netUnitPrice) {
        return line(quoteId, productId, lob, quantity, netUnitPrice, 'TermDefined');
    }

    private static QuoteLineItem rawLine(
        Id quoteId, Id productId, String lob, Decimal quantity, Decimal mrr, Decimal netTotalPrice
    ) {
        Map<String, Object> raw = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineItem' },
            'QuoteId' => quoteId, 'Product2Id' => productId, 'Line_of_Business__c' => lob,
            'Quantity' => quantity, 'MRR__c' => mrr, 'NetTotalPrice' => netTotalPrice,
            'SellingModelType' => 'TermDefined'
        };
        return (QuoteLineItem) JSON.deserialize(JSON.serialize(raw), QuoteLineItem.class);
    }

    private static AssetStatePeriod statePeriod(Datetime startDate, Datetime endDate, Decimal mrr) {
        Map<String, Object> raw = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'AssetStatePeriod' },
            'StartDate' => startDate, 'EndDate' => endDate, 'Mrr' => mrr
        };
        return (AssetStatePeriod) JSON.deserialize(JSON.serialize(raw), AssetStatePeriod.class);
    }

    private static Quote reload(Id quoteId) {
        return [
            SELECT Id, Existing_MRR__c, Existing_TCV__c,
                   Existing_MRR_Cyber__c, Existing_MRR_Desk__c, Existing_MRR_Infra__c,
                   Existing_MRR_Private_Cloud__c, Existing_MRR_VOIP__c,
                   Current_MRR__c, Current_TCV__c,
                   Current_MRR_Cyber__c, Current_MRR_Desk__c, Current_MRR_Infra__c,
                   Current_MRR_Private_Cloud__c, Current_MRR_VOIP__c,
                   Net_MRR__c, Net_TCV__c, Net_MRR_Cyber__c, Net_MRR_Desk__c, Net_MRR_Infra__c,
                   Net_MRR_Private_Cloud__c, Net_MRR_VOIP__c,
                   MRR_Change_Pct_Cyber__c, MRR_Change_Pct_Desk__c, MRR_Change_Pct_Infra__c,
                   MRR_Change_Pct_Private_Cloud__c, MRR_Change_Pct_VOIP__c,
                   Net_Less_Than_Existing__c
            FROM Quote WHERE Id = :quoteId
        ];
    }

    private static Contract reloadContract(Id contractId) {
        return [
            SELECT Id, Current_MRR__c, Current_TCV__c, Existing_TCV__c, TCV__c, Last_Stamped_Order__c,
                   Current_MRR_Cyber__c, Current_MRR_Desk__c, Current_MRR_Infra__c,
                   Current_MRR_Private_Cloud__c, Current_MRR_VOIP__c,
                   Existing_MRR__c, Existing_MRR_Cyber__c,
                   Existing_MRR_Desk__c, Existing_MRR_Infra__c,
                   Existing_MRR_Private_Cloud__c, Existing_MRR_VOIP__c,
                   Sold_Gross_Margin_Total__c, Sold_Gross_Margin_Cyber__c,
                   Sold_Gross_Margin_Desk__c, Sold_Gross_Margin_Infra__c,
                   Sold_Gross_Margin_Onboarding__c, Sold_Gross_Margin_Private_Cloud__c,
                   Sold_Gross_Margin_VOIP__c
            FROM Contract WHERE Id = :contractId
        ];
    }

    private static Opportunity reloadOpportunity(Id opportunityId) {
        return [SELECT Id, Booked_MRR__c, Loss_MRR__c FROM Opportunity WHERE Id = :opportunityId];
    }

    private static void activateContract(Id contractId) {
        update new Contract(Id = contractId, Status = 'Activated');
    }

    private static Id standardEntryId() {
        Id pricebookId = Test.getStandardPricebookId();
        List<PricebookEntry> existing = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId AND Product2.Name = 'FM Desk Product'
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }
        PricebookEntry entry = new PricebookEntry(
            Pricebook2Id = pricebookId,
            Product2Id = productIds().get('FM Desk Product'),
            UnitPrice = 100,
            IsActive = true
        );
        insert entry;
        return entry.Id;
    }

    private static Order activatedOrder(Id accountId, Id contractId, Id quoteId) {
        Id entryId = standardEntryId();
        Date effective = Date.today();
        if (contractId != null) {
            Contract source = [SELECT StartDate FROM Contract WHERE Id = :contractId];
            if (source.StartDate != null && source.StartDate < effective) {
                effective = source.StartDate;
            }
        }
        Order o = new Order(
            AccountId = accountId, ContractId = contractId, QuoteId = quoteId,
            EffectiveDate = effective, Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert o;
        insert new OrderItem(
            OrderId = o.Id, PricebookEntryId = entryId, Quantity = 1, UnitPrice = 100,
            ServiceDate = effective
        );
        o.Status = 'Activated';
        update o;
        return o;
    }

    @IsTest
    static void testWorkedExampleAmendmentNetsToTenThousand() {
        Contract contract = baselineContract(6000, 72000, new Map<String, Decimal>{
            'Desk' => 4000, 'Cyber' => 2000
        });
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM Amend Opp', contract.Id, 'Change Order');
        insert opp;
        Quote amend = buildQuote('FM Amend', opp.Id, contract.Id, 'Draft');
        insert amend;
        asActionType(amend.Id, 'Amend');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            amend.Id => new List<QuoteLineItem>{
                delta(amend.Id, products.get('FM Desk Product'), LOB_DESK, -10, 100),
                delta(amend.Id, products.get('FM Cyber Product'), LOB_CYBER, 5, 200),
                delta(amend.Id, products.get('FM Infra Product'), LOB_INFRA, 10, 400)
            }
        };

        Test.startTest();
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ amend.Id });
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ amend.Id }, null);
        Test.stopTest();

        Quote result = reload(amend.Id);
        System.assertEquals(6000, result.Existing_MRR__c, 'Existing copied from the contract baseline');
        System.assertEquals(4000, result.Current_MRR__c,
            'Current is the delta sum: -1000 + 1000 + 4000');
        System.assertEquals(-1000, result.Current_MRR_Desk__c, 'Desk reduced by 10 units at 100');
        System.assertEquals(1000, result.Current_MRR_Cyber__c, 'Cyber increased by 5 units at 200');
        System.assertEquals(4000, result.Current_MRR_Infra__c, 'Infra added at 10 units of 400');
        System.assertEquals(10000, result.Net_MRR__c,
            'Amendment lines are deltas, so Net is Current plus Existing');
        System.assertEquals(3000, result.Net_MRR_Desk__c, 'Desk net is 4000 baseline minus 1000');
        System.assertEquals(3000, result.Net_MRR_Cyber__c, 'Cyber net is 2000 baseline plus 1000');
    }

    @IsTest
    static void testFullCancellationNetsToZero() {
        Contract contract = baselineContract(700, 8400, new Map<String, Decimal>{
            'Desk' => 500, 'Cyber' => 200
        });
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM Cancel Opp', contract.Id, 'Full Churn');
        insert opp;
        Quote cancel = buildQuote('FM Cancel', opp.Id, contract.Id, 'Draft');
        insert cancel;
        asActionType(cancel.Id, 'Cancel');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            cancel.Id => new List<QuoteLineItem>{
                delta(cancel.Id, products.get('FM Desk Product'), LOB_DESK, -10, 50),
                delta(cancel.Id, products.get('FM Cyber Product'), LOB_CYBER, -2, 100)
            }
        };

        Test.startTest();
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ cancel.Id });
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ cancel.Id }, null);
        FinancialMetricsService.stampOpportunityMetrics(new Set<Id>{ cancel.Id });
        Test.stopTest();

        Quote result = reload(cancel.Id);
        System.assertEquals(700, result.Existing_MRR__c, 'Existing is the full contract baseline');
        System.assertEquals(-700, result.Current_MRR__c, 'Current is the negative of Existing');
        System.assertEquals(0, result.Net_MRR__c, 'A full cancellation nets the contract to zero');
        System.assertEquals(true, result.Net_Less_Than_Existing__c,
            'Cancelling everything must flag as below the existing baseline');

        Opportunity opp2 = reloadOpportunity(opp.Id);
        System.assertEquals(-700, opp2.Loss_MRR__c, 'Loss is the whole cancelled amount');
        System.assertEquals(0, opp2.Booked_MRR__c, 'Booked is the Net, which is zero after a full cancellation');
    }

    @IsTest
    static void testRenewalCurrentIsTheWholeBook() {
        Contract contract = baselineContract(1600, 19200, new Map<String, Decimal>{ 'Desk' => 1600 });
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM Renew Opp', contract.Id, 'Renewal');
        insert opp;
        Quote renew = buildQuote('FM Renew', opp.Id, contract.Id, 'Draft');
        insert renew;
        asActionType(renew.Id, 'Renew');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            renew.Id => new List<QuoteLineItem>{
                delta(renew.Id, products.get('FM Desk Product'), LOB_DESK, 10, 140)
            }
        };

        Test.startTest();
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ renew.Id });
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ renew.Id }, null);
        Test.stopTest();

        Quote result = reload(renew.Id);
        System.assertEquals(1600, result.Existing_MRR__c, 'Existing still copied for a renewal');
        System.assertEquals(1400, result.Current_MRR__c,
            'A renewal restates the whole book rather than a delta');
        System.assertEquals(1400, result.Current_MRR_Desk__c,
            'Desk renews at 1400 against a 1600 baseline');
    }

    @IsTest
    static void testRenewalWalkAwayLosesTheContractBaseline() {
        Contract contract = baselineContract(1007.23, 18251.76, null);

        Opportunity renewalOpp = buildOpportunity('FM Renewal Opp', contract.Id, 'Renewal');
        insert renewalOpp;

        Test.startTest();
        FinancialMetricsService.stampRenewalWalkAway(new Set<Id>{ renewalOpp.Id });
        Test.stopTest();

        Opportunity result = reloadOpportunity(renewalOpp.Id);
        System.assertEquals(-1007.23, result.Loss_MRR__c, 'Walking away loses the whole contract baseline');
        System.assertEquals(0, result.Booked_MRR__c, 'Nothing was booked');
    }

    @IsTest
    static void testSecondAmendmentReadsTheContractTheBatchStillOwns() {
        Account account = testAccount();
        Contract contract = baselineContract(6000, 72000, new Map<String, Decimal>{ 'Desk' => 6000 });
        Map<String, Id> products = productIds();

        Opportunity opp1 = buildOpportunity('FM Amend Opp 1', contract.Id, 'Change Order');
        insert opp1;
        Quote amend1 = buildQuote('FM Amend 1', opp1.Id, contract.Id, 'Draft');
        insert amend1;
        asActionType(amend1.Id, 'Amend');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            amend1.Id => new List<QuoteLineItem>{
                delta(amend1.Id, products.get('FM Desk Product'), LOB_DESK, 10, 400)
            }
        };
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ amend1.Id });
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ amend1.Id }, null);

        System.assertEquals(10000, reload(amend1.Id).Net_MRR__c, 'First amendment nets to 10000');

        activateContract(contract.Id);

        Order order1 = activatedOrder(account.Id, contract.Id, amend1.Id);

        Test.startTest();
        FinancialMetricsService.stampContractFromOrder(new Set<Id>{ order1.Id });

        Contract stamped = reloadContract(contract.Id);
        System.assertEquals(6000, stamped.Current_MRR__c,
            'An amendment activation must not stamp the contract - the nightly batch owns it');
        System.assertEquals(null, stamped.Last_Stamped_Order__c,
            'Only a new business activation records a stamping order');

        Opportunity opp2 = buildOpportunity('FM Amend Opp 2', contract.Id, 'Change Order');
        insert opp2;
        Quote amend2 = buildQuote('FM Amend 2', opp2.Id, contract.Id, 'Draft');
        insert amend2;
        asActionType(amend2.Id, 'Amend');
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ amend2.Id });
        Test.stopTest();

        System.assertEquals(6000, reload(amend2.Id).Existing_MRR__c,
            'Until the batch re-derives the contract from Assets, a second amendment still '
            + 'baselines off the pre-amendment figure');
    }

    @IsTest
    static void testAmendmentActivationNeverWritesTheContract() {
        Account account = testAccount();
        Contract contract = baselineContract(6000, 72000, null);
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM Amend Opp', contract.Id, 'Change Order');
        insert opp;
        Quote amend = buildQuote('FM Amend', opp.Id, contract.Id, 'Draft');
        insert amend;
        asActionType(amend.Id, 'Amend');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            amend.Id => new List<QuoteLineItem>{
                delta(amend.Id, products.get('FM Desk Product'), LOB_DESK, 10, 400)
            }
        };
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ amend.Id });
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ amend.Id }, null);
        activateContract(contract.Id);
        Order order1 = activatedOrder(account.Id, contract.Id, amend.Id);

        Test.startTest();
        FinancialMetricsService.stampContractFromOrder(new Set<Id>{ order1.Id });
        FinancialMetricsService.stampContractFromOrder(new Set<Id>{ order1.Id });
        FinancialMetricsService.stampContractFromOrder(new Set<Id>{ order1.Id });
        Test.stopTest();

        System.assertEquals(6000, reloadContract(contract.Id).Current_MRR__c,
            'Re-running an amendment activation must leave the contract untouched every time');
    }

    @IsTest
    static void testAmendmentActivationLeavesTheContractBaselineToTheBatch() {
        Account account = testAccount();
        Contract contract = baselineContract(6000, 72000, new Map<String, Decimal>{
            'Desk' => 4000, 'Cyber' => 2000
        });
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM Amend Opp', contract.Id, 'Change Order');
        insert opp;
        Quote amend = buildQuote('FM Amend', opp.Id, contract.Id, 'Draft');
        insert amend;
        asActionType(amend.Id, 'Amend');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            amend.Id => new List<QuoteLineItem>{
                delta(amend.Id, products.get('FM Desk Product'), LOB_DESK, 10, 400)
            }
        };
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ amend.Id });
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ amend.Id }, null);

        activateContract(contract.Id);
        Order order1 = activatedOrder(account.Id, contract.Id, amend.Id);

        Test.startTest();
        FinancialMetricsService.stampContractFromOrder(new Set<Id>{ order1.Id });
        Test.stopTest();

        Contract stamped = reloadContract(contract.Id);
        System.assertEquals(null, stamped.Existing_MRR__c,
            'An amendment activation writes nothing to the contract at all');
        System.assertEquals(6000, stamped.Current_MRR__c,
            'Current still holds the pre-amendment baseline until the batch re-derives it');
        System.assertEquals(4000, stamped.Current_MRR_Desk__c, 'Per LOB left as the batch set it');
        System.assertEquals(72000, stamped.TCV__c,
            'The activation stamp must never write contract TCV');
    }

    @IsTest
    static void testActivationSkipsTheQuoteWriteWhenNothingChanged() {
        Account account = testAccount();
        Contract contract = baselineContract(1000, 12000, new Map<String, Decimal>{ 'Desk' => 1000 });
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM Amend Opp', contract.Id, 'Change Order');
        insert opp;
        Quote amend = buildQuote('FM Amend', opp.Id, contract.Id, 'Draft');
        insert amend;
        asActionType(amend.Id, 'Amend');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            amend.Id => new List<QuoteLineItem>{
                delta(amend.Id, products.get('FM Desk Product'), LOB_DESK, 1, 200)
            }
        };
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ amend.Id });
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ amend.Id }, null);

        activateContract(contract.Id);
        Order order1 = activatedOrder(account.Id, contract.Id, amend.Id);
        Datetime beforeStamp = [SELECT LastModifiedDate FROM Quote WHERE Id = :amend.Id].LastModifiedDate;

        Test.startTest();
        FinancialMetricsService.stampContractFromOrder(new Set<Id>{ order1.Id });
        Test.stopTest();

        Datetime afterStamp = [SELECT LastModifiedDate FROM Quote WHERE Id = :amend.Id].LastModifiedDate;
        System.assertEquals(beforeStamp, afterStamp,
            'The baseline had not moved, so the quote must not be written at all - a pointless '
            + 'update cascades into Quote To Opportunity Margin Sync and can fail on validation');
        System.assertEquals(1000, reloadContract(contract.Id).Current_MRR__c,
            'The contract is left to the batch even though the quote side ran');
    }

    @IsTest
    static void testActivationRefreshesQuoteExistingFromTheCurrentBaseline() {
        Account account = testAccount();
        Contract contract = baselineContract(1000, 12000, new Map<String, Decimal>{ 'Desk' => 1000 });
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM Amend Opp', contract.Id, 'Change Order');
        insert opp;
        Quote amend = buildQuote('FM Amend', opp.Id, contract.Id, 'Draft');
        insert amend;
        asActionType(amend.Id, 'Amend');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            amend.Id => new List<QuoteLineItem>{
                delta(amend.Id, products.get('FM Desk Product'), LOB_DESK, 1, 200)
            }
        };
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ amend.Id });
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ amend.Id }, null);

        System.assertEquals(1000, reload(amend.Id).Existing_MRR__c,
            'Snapshot taken at creation');

        baselineContract(1500, 18000, new Map<String, Decimal>{ 'Desk' => 1500 });

        activateContract(contract.Id);
        Order order1 = activatedOrder(account.Id, contract.Id, amend.Id);

        Test.startTest();
        FinancialMetricsService.stampContractFromOrder(new Set<Id>{ order1.Id });
        Test.stopTest();

        Quote result = reload(amend.Id);
        System.assertEquals(1500, result.Existing_MRR__c,
            'Activation refreshes Existing from the baseline as it stands at activation');
        System.assertEquals(1500, result.Existing_MRR_Desk__c, 'Per LOB refreshed too');
        System.assertEquals(1700, result.Net_MRR__c,
            'Net recomputes off the refreshed baseline: 1500 plus the 200 delta');

        Contract stamped = reloadContract(contract.Id);
        System.assertEquals(1500, stamped.Current_MRR__c,
            'The quote side still refreshes, but the contract itself is the batch\'s to move');
        System.assertEquals(null, stamped.Existing_MRR__c,
            'An amendment activation leaves contract Existing alone');
    }

    @IsTest
    static void testIsNewBusinessTreatsBlankAndNewAsNewBusiness() {
        System.assertEquals(true, FinancialMetricsService.isNewBusiness(null),
            'A new business quote carries a blank OriginalActionType in this org');
        System.assertEquals(true, FinancialMetricsService.isNewBusiness(''),
            'An empty string is blank too');
        System.assertEquals(true, FinancialMetricsService.isNewBusiness('New'),
            'An explicit New action type is new business');
        System.assertEquals(false, FinancialMetricsService.isNewBusiness('Amend'),
            'Amend is not new business');
        System.assertEquals(false, FinancialMetricsService.isNewBusiness('Renew'),
            'Renew is not new business');
        System.assertEquals(false, FinancialMetricsService.isNewBusiness('Cancel'),
            'Cancel is not new business');
    }

    @IsTest
    static void testNewBusinessActivationStampsSoldGrossMarginFromTheQuote() {
        Account account = testAccount();
        Contract contract = testContract();
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM Margin Opp', contract.Id, 'New Business');
        insert opp;
        Quote newBusiness = buildQuote('FM Margin Q', opp.Id, contract.Id, 'Draft');
        insert newBusiness;

        update new Quote(
            Id = newBusiness.Id,
            Margin_Total__c = 45,
            Margin_Desk__c = 45,
            Margin_Cyber__c = 30,
            Margin_Infra__c = 12,
            Margin_Onboarding__c = 60,
            Margin_Private_Cloud__c = 22,
            Margin_VOIP__c = 18
        );

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            newBusiness.Id => new List<QuoteLineItem>{
                delta(newBusiness.Id, products.get('FM Desk Product'), LOB_DESK, 10, 50)
            }
        };
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ newBusiness.Id }, null);

        activateContract(contract.Id);
        Order order1 = activatedOrder(account.Id, contract.Id, newBusiness.Id);

        Test.startTest();
        FinancialMetricsService.stampContractFromOrder(new Set<Id>{ order1.Id });
        Test.stopTest();

        Contract stamped = reloadContract(contract.Id);
        System.assertEquals(45, stamped.Sold_Gross_Margin_Total__c, 'Total margin stamped');
        System.assertEquals(45, stamped.Sold_Gross_Margin_Desk__c, 'Desk margin stamped');
        System.assertEquals(30, stamped.Sold_Gross_Margin_Cyber__c, 'Cyber margin stamped');
        System.assertEquals(12, stamped.Sold_Gross_Margin_Infra__c, 'Infra margin stamped');
        System.assertEquals(60, stamped.Sold_Gross_Margin_Onboarding__c, 'Onboarding margin stamped');
        System.assertEquals(22, stamped.Sold_Gross_Margin_Private_Cloud__c,
            'Private Cloud margin stamped');
        System.assertEquals(18, stamped.Sold_Gross_Margin_VOIP__c, 'VOIP margin stamped');
    }

    @IsTest
    static void testAmendmentActivationDoesNotOverwriteSoldGrossMargin() {
        Account account = testAccount();
        Contract contract = baselineContract(1000, 12000, new Map<String, Decimal>{ 'Desk' => 1000 });
        Map<String, Id> products = productIds();

        update new Contract(Id = contract.Id, Sold_Gross_Margin_Total__c = 45);

        Opportunity opp = buildOpportunity('FM Margin Amend Opp', contract.Id, 'Change Order');
        insert opp;
        Quote amend = buildQuote('FM Margin Amend', opp.Id, contract.Id, 'Draft');
        insert amend;
        asActionType(amend.Id, 'Amend');

        update new Quote(Id = amend.Id, Margin_Total__c = 12);

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            amend.Id => new List<QuoteLineItem>{
                delta(amend.Id, products.get('FM Desk Product'), LOB_DESK, 1, 200)
            }
        };
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ amend.Id });
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ amend.Id }, null);

        activateContract(contract.Id);
        Order order1 = activatedOrder(account.Id, contract.Id, amend.Id);

        Test.startTest();
        FinancialMetricsService.stampContractFromOrder(new Set<Id>{ order1.Id });
        Test.stopTest();

        System.assertEquals(45, reloadContract(contract.Id).Sold_Gross_Margin_Total__c,
            'The margin as originally sold survives every later amendment');
    }

    @IsTest
    static void testNewBusinessActivationBootstrapsTheContractBaseline() {
        Account account = testAccount();
        Contract contract = testContract();
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM New Business Opp', contract.Id, 'New Business');
        insert opp;
        Quote newBusiness = buildQuote('FM New Business', opp.Id, contract.Id, 'Draft');
        insert newBusiness;

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            newBusiness.Id => new List<QuoteLineItem>{
                delta(newBusiness.Id, products.get('FM Desk Product'), LOB_DESK, 10, 50),
                delta(newBusiness.Id, products.get('FM Cyber Product'), LOB_CYBER, 2, 100)
            }
        };
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ newBusiness.Id });
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ newBusiness.Id }, null);

        System.assertEquals(null, reload(newBusiness.Id).Existing_MRR__c,
            'New business has no baseline to copy');

        activateContract(contract.Id);
        Order order1 = activatedOrder(account.Id, contract.Id, newBusiness.Id);

        Test.startTest();
        FinancialMetricsService.stampContractFromOrder(new Set<Id>{ order1.Id });
        Test.stopTest();

        Contract stamped = reloadContract(contract.Id);
        System.assertEquals(700, stamped.Current_MRR__c,
            'Activating the first new business order must seed the contract MRR baseline');
        System.assertEquals(500, stamped.Current_MRR_Desk__c, 'Desk baseline seeded');
        System.assertEquals(200, stamped.Current_MRR_Cyber__c, 'Cyber baseline seeded');
        System.assertEquals(order1.Id, stamped.Last_Stamped_Order__c, 'Stamping order recorded');
    }

    @IsTest
    static void testAmendmentAfterNewBusinessSeesTheSeededBaseline() {
        Account account = testAccount();
        Contract contract = testContract();
        Map<String, Id> products = productIds();

        Opportunity opp1 = buildOpportunity('FM NB Opp', contract.Id, 'New Business');
        insert opp1;
        Quote newBusiness = buildQuote('FM NB', opp1.Id, contract.Id, 'Draft');
        insert newBusiness;

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            newBusiness.Id => new List<QuoteLineItem>{
                delta(newBusiness.Id, products.get('FM Desk Product'), LOB_DESK, 10, 50)
            }
        };
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ newBusiness.Id }, null);
        activateContract(contract.Id);
        Order nbOrder = activatedOrder(account.Id, contract.Id, newBusiness.Id);
        FinancialMetricsService.stampContractFromOrder(new Set<Id>{ nbOrder.Id });

        Opportunity opp2 = buildOpportunity('FM Amend Opp', contract.Id, 'Change Order');
        insert opp2;
        Quote amend = buildQuote('FM Amend', opp2.Id, contract.Id, 'Draft');
        insert amend;
        asActionType(amend.Id, 'Amend');

        Test.startTest();
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ amend.Id });
        Test.stopTest();

        Quote result = reload(amend.Id);
        System.assertEquals(500, result.Existing_MRR__c,
            'The amendment must inherit the baseline seeded by the new business activation');
        System.assertEquals(500, result.Existing_MRR_Desk__c, 'Per LOB baseline inherited too');
    }

    @IsTest
    static void testNewBusinessQuoteLeavesTheExistingSetBlank() {
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM New Business Opp', null, 'New Business');
        insert opp;
        Quote newBusiness = buildQuote('FM New Business', opp.Id, null, 'Draft');
        insert newBusiness;

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            newBusiness.Id => new List<QuoteLineItem>{
                delta(newBusiness.Id, products.get('FM Desk Product'), LOB_DESK, 10, 50)
            }
        };

        Test.startTest();
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ newBusiness.Id });
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ newBusiness.Id }, null);
        Test.stopTest();

        Quote result = reload(newBusiness.Id);
        System.assertEquals(null, result.Existing_MRR__c,
            'New business has no contract baseline, so Existing stays blank rather than zero');
        System.assertEquals(null, result.Existing_TCV__c, 'Existing TCV stays blank');
        System.assertEquals(500, result.Current_MRR__c, 'Current still rolls up its own lines');
        System.assertEquals(500, result.Net_MRR__c, 'Net equals Current when there is no baseline');
        System.assertEquals(false, result.Net_Less_Than_Existing__c, 'No baseline means nothing to fall below');
    }

    @IsTest
    static void testNewLobHasNullChangePercentAndDoesNotError() {
        Contract contract = baselineContract(6000, 72000, new Map<String, Decimal>{ 'Desk' => 6000 });
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM Amend Opp', contract.Id, 'Change Order');
        insert opp;
        Quote amend = buildQuote('FM Amend', opp.Id, contract.Id, 'Draft');
        insert amend;
        asActionType(amend.Id, 'Amend');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            amend.Id => new List<QuoteLineItem>{
                delta(amend.Id, products.get('FM VOIP Product'), LOB_VOIP, 4, 25)
            }
        };

        Test.startTest();
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ amend.Id });
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ amend.Id }, null);
        Test.stopTest();

        Quote result = reload(amend.Id);
        System.assertEquals(0, result.Existing_MRR_VOIP__c, 'No VOIP baseline existed');
        System.assertEquals(100, result.Current_MRR_VOIP__c, 'VOIP is brand new on this quote');
        System.assertEquals(null, result.MRR_Change_Pct_VOIP__c,
            'A brand new LOB divides by zero, so the percentage must be blank rather than an error');
        System.assertEquals(100, result.MRR_Change_Pct_Desk__c,
            'Desk has no line on this quote, so its Net equals its baseline at 100 percent');
        System.assertEquals(0, FinancialMetricsService.faultLog.size(), 'Zero division must not raise a fault');
    }

    @IsTest
    static void testUnbucketedLobAndOneTimeHandling() {
        Map<String, Id> products = productIds();
        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            delta(null, products.get('FM Desk Product'), LOB_DESK, 10, 100),
            delta(null, products.get('FM Bundle Parent Product'), LOB_UNBUCKETED, 10, 85),
            delta(null, products.get('FM Bundle Parent Product'), null, 10, 125),
            line(null, products.get('FM Cyber Product'), LOB_CYBER, 1, 5000, 'OneTime')
        };

        Map<String, Decimal> byLob = FinancialMetricsService.sumMrrByLob(lines);
        System.assertEquals(1000, byLob.get('Desk'), 'Only mapped LOBs get a bucket');
        System.assertEquals(0, byLob.get('Cyber'), 'One time lines never reach a bucket');
        System.assertEquals(3100, FinancialMetricsService.sumBookedMrr(lines),
            'Total includes unbucketed and blank LOB money but excludes one time');
        System.assertEquals(97200, FinancialMetricsService.sumTcv(lines),
            'TCV counts every line including the one time line');
        System.assertEquals(0, FinancialMetricsService.sumNegativeMrr(lines), 'Nothing negative here');
    }

    @IsTest
    static void testSumNegativeMrrIgnoresPositivesAndOneTime() {
        Map<String, Id> products = productIds();
        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            delta(null, products.get('FM Desk Product'), LOB_DESK, -3, 100),
            delta(null, products.get('FM Cyber Product'), LOB_CYBER, 5, 200),
            line(null, products.get('FM Infra Product'), LOB_INFRA, -1, 900, 'OneTime')
        };
        System.assertEquals(-300, FinancialMetricsService.sumNegativeMrr(lines),
            'Only recurring negative deltas count toward loss');
    }

    @IsTest
    static void testLossIsGrossNegativeAndBookedIsNet() {
        Contract contract = baselineContract(500, 6000, new Map<String, Decimal>{ 'Infra' => 500 });
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM Swap Opp', contract.Id, 'Change Order');
        insert opp;
        Quote swap = buildQuote('FM Swap', opp.Id, contract.Id, 'Draft');
        insert swap;
        asActionType(swap.Id, 'Amend');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            swap.Id => new List<QuoteLineItem>{
                delta(swap.Id, products.get('FM Cyber Product'), LOB_CYBER, 1, 72),
                delta(swap.Id, products.get('FM Infra Product'), LOB_INFRA, -1, 190)
            }
        };

        Test.startTest();
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ swap.Id });
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ swap.Id }, null);
        FinancialMetricsService.stampOpportunityMetrics(new Set<Id>{ swap.Id });
        Test.stopTest();

        Opportunity result = reloadOpportunity(opp.Id);
        System.assertEquals(-190, result.Loss_MRR__c,
            'Gross loss reports the swapped out amount without offsetting the swap in');
        System.assertEquals(382, result.Booked_MRR__c,
            'Booked is the Net: 500 baseline plus the minus 118 delta');
    }

    @IsTest
    static void testBookedMrrIsAlwaysOverwrittenWithTheNet() {
        Contract contract = baselineContract(1000, 12000, null);
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM Amend Opp', contract.Id, 'Change Order');
        opp.Booked_MRR__c = 4321;
        insert opp;
        Quote amend = buildQuote('FM Amend', opp.Id, contract.Id, 'Draft');
        insert amend;
        asActionType(amend.Id, 'Amend');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            amend.Id => new List<QuoteLineItem>{
                delta(amend.Id, products.get('FM Desk Product'), LOB_DESK, -2, 100)
            }
        };

        Test.startTest();
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ amend.Id });
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ amend.Id }, null);
        FinancialMetricsService.stampOpportunityMetrics(new Set<Id>{ amend.Id });
        Test.stopTest();

        Opportunity result = reloadOpportunity(opp.Id);
        System.assertEquals(800, result.Booked_MRR__c,
            'The stale value is replaced by the Net, not preserved');
        System.assertEquals(-200, result.Loss_MRR__c, 'Loss still stamped');
    }

    @IsTest
    static void testWalkAwayWithoutContractValueLogsFault() {
        Account account = testAccount();
        Contract emptyContract = new Contract(
            AccountId = account.Id, StartDate = Date.today().addMonths(-3),
            ContractTerm = 12, Status = 'Draft'
        );
        insert emptyContract;

        Opportunity renewalOpp = buildOpportunity('FM Orphan Renewal', emptyContract.Id, 'Renewal');
        insert renewalOpp;

        Test.startTest();
        FinancialMetricsService.stampRenewalWalkAway(new Set<Id>{ renewalOpp.Id });
        Test.stopTest();

        System.assertEquals(null, reloadOpportunity(renewalOpp.Id).Loss_MRR__c, 'Nothing to lose');
        System.assertEquals(1, [
            SELECT COUNT() FROM Task
            WHERE WhatId = :renewalOpp.Id AND Subject = 'Financial Metrics Fault'
        ], 'A fault task explains why nothing was stamped');
    }

    @IsTest
    static void testDeletePathExcludesTheDeletedLine() {
        Contract contract = testContract();
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM Amend Opp', contract.Id, 'Change Order');
        insert opp;
        Quote amend = buildQuote('FM Amend', opp.Id, contract.Id, 'Draft');
        insert amend;

        Id droppedId = '0QL000000000001AAA';
        QuoteLineItem keep = delta(amend.Id, products.get('FM Desk Product'), LOB_DESK, 5, 100);
        QuoteLineItem drop = delta(amend.Id, products.get('FM Cyber Product'), LOB_CYBER, 5, 100);
        drop.Id = droppedId;

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            amend.Id => new List<QuoteLineItem>{ keep, drop }
        };

        Test.startTest();
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ amend.Id }, new Set<Id>{ droppedId });
        Test.stopTest();

        Quote result = reload(amend.Id);
        System.assertEquals(500, result.Current_MRR__c, 'Only the surviving line counts');
        System.assertEquals(0, result.Current_MRR_Cyber__c, 'The deleted line contributes nothing');
    }

    @IsTest
    static void testBulkQuotesUseAFixedNumberOfQueries() {
        Contract contract = testContract();
        Map<String, Id> products = productIds();
        Id desk = products.get('FM Desk Product');

        List<Opportunity> opportunities = new List<Opportunity>();
        for (Integer i = 0; i < 50; i++) {
            opportunities.add(buildOpportunity('FM Bulk Opp ' + i, contract.Id, 'Change Order'));
        }
        insert opportunities;

        List<Quote> quotes = new List<Quote>();
        for (Integer i = 0; i < 50; i++) {
            quotes.add(buildQuote('FM Bulk ' + i, opportunities[i].Id, contract.Id, 'Draft'));
        }
        insert quotes;

        Map<Id, List<QuoteLineItem>> lineMap = new Map<Id, List<QuoteLineItem>>();
        Set<Id> quoteIds = new Set<Id>();
        for (Quote q : quotes) {
            lineMap.put(q.Id, new List<QuoteLineItem>{ delta(q.Id, desk, LOB_DESK, -6, 100) });
            quoteIds.add(q.Id);
        }
        FinancialMetricsService.lineOverride = lineMap;
        FinancialMetricsService.recalcGuard = new Set<Id>();

        Test.startTest();
        Integer before = Limits.getQueries();
        FinancialMetricsService.recalcNetMetrics(quoteIds, null);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        System.assert(used <= 6, 'Constant query count for 50 quotes. Used: ' + used);
        for (Quote q : [SELECT Current_MRR_Desk__c FROM Quote WHERE Id IN :quoteIds]) {
            System.assertEquals(-600, q.Current_MRR_Desk__c, 'Each bulk quote nets the same reduction');
        }
    }

    @IsTest
    static void testBulkStampPreviousUsesAFixedNumberOfQueries() {
        Contract contract = baselineContract(6000, 72000, new Map<String, Decimal>{ 'Desk' => 6000 });

        List<Opportunity> opportunities = new List<Opportunity>();
        for (Integer i = 0; i < 50; i++) {
            opportunities.add(buildOpportunity('FM Bulk Prev Opp ' + i, contract.Id, 'Change Order'));
        }
        insert opportunities;

        List<Quote> quotes = new List<Quote>();
        for (Integer i = 0; i < 50; i++) {
            quotes.add(buildQuote('FM Bulk Prev ' + i, opportunities[i].Id, contract.Id, 'Draft'));
        }
        insert quotes;

        Set<Id> quoteIds = new Set<Id>();
        for (Quote q : quotes) {
            quoteIds.add(q.Id);
            asActionType(q.Id, 'Amend');
        }

        Test.startTest();
        Integer before = Limits.getQueries();
        FinancialMetricsService.stampPreviousMetrics(quoteIds);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        System.assert(used <= 4, 'Constant query count for 50 quotes. Used: ' + used);
        for (Quote q : [SELECT Existing_MRR__c FROM Quote WHERE Id IN :quoteIds]) {
            System.assertEquals(6000, q.Existing_MRR__c, 'Every quote reads the same baseline');
        }
    }

    @IsTest
    static void testInvocableEntryPointsDelegateToTheService() {
        Account account = testAccount();
        Contract contract = baselineContract(1000, 12000, null);
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM Amend Opp', contract.Id, 'Change Order');
        insert opp;
        Opportunity walkOpp = buildOpportunity('FM Walk Opp', contract.Id, 'Renewal');
        insert walkOpp;

        Quote amend = buildQuote('FM Amend', opp.Id, contract.Id, 'Draft');
        insert amend;
        asActionType(amend.Id, 'Amend');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            amend.Id => new List<QuoteLineItem>{
                delta(amend.Id, products.get('FM Desk Product'), LOB_DESK, -3, 100)
            }
        };

        FinancialMetricsStampPreviousInvocable.Request prev = new FinancialMetricsStampPreviousInvocable.Request();
        prev.quoteId = amend.Id;
        FinancialMetricsRecalcNetInvocable.Request recalc = new FinancialMetricsRecalcNetInvocable.Request();
        recalc.quoteId = amend.Id;
        FinancialMetricsLossMrrInvocable.Request loss = new FinancialMetricsLossMrrInvocable.Request();
        loss.quoteId = amend.Id;
        FinancialMetricsWalkAwayInvocable.Request walk = new FinancialMetricsWalkAwayInvocable.Request();
        walk.opportunityId = walkOpp.Id;

        Test.startTest();
        FinancialMetricsStampPreviousInvocable.run(new List<FinancialMetricsStampPreviousInvocable.Request>{ prev });
        FinancialMetricsRecalcNetInvocable.run(new List<FinancialMetricsRecalcNetInvocable.Request>{ recalc });
        FinancialMetricsLossMrrInvocable.run(new List<FinancialMetricsLossMrrInvocable.Request>{ loss });
        FinancialMetricsWalkAwayInvocable.run(new List<FinancialMetricsWalkAwayInvocable.Request>{ walk });

        activateContract(contract.Id);

        Order order1 = activatedOrder(account.Id, contract.Id, amend.Id);
        FinancialMetricsActivationInvocable.Request act = new FinancialMetricsActivationInvocable.Request();
        act.orderId = order1.Id;
        FinancialMetricsActivationInvocable.run(new List<FinancialMetricsActivationInvocable.Request>{ act });
        Test.stopTest();

        Quote result = reload(amend.Id);
        System.assertEquals(1000, result.Existing_MRR__c, 'Stamp previous invocable reached the service');
        System.assertEquals(-300, result.Current_MRR__c, 'Recalc invocable reached the service');
        System.assertEquals(-300, reloadOpportunity(opp.Id).Loss_MRR__c, 'Loss invocable reached the service');
        System.assertEquals(-1000, reloadOpportunity(walkOpp.Id).Loss_MRR__c, 'Walk away invocable reached the service');
        System.assertEquals(1000, reloadContract(contract.Id).Current_MRR__c,
            'The activation invocable reaches the service but leaves an amended contract alone');
    }

    @IsTest
    static void testEmptyAndNullInputsExitCleanly() {
        FinancialMetricsRecalcNetInvocable.Request blank = new FinancialMetricsRecalcNetInvocable.Request();

        Test.startTest();
        FinancialMetricsService.stampPreviousMetrics(null);
        FinancialMetricsService.recalcNetMetrics(new Set<Id>(), null);
        FinancialMetricsService.stampOpportunityMetrics(null);
        FinancialMetricsService.stampRenewalWalkAway(null);
        FinancialMetricsService.stampContractFromOrder(null);
        FinancialMetricsStampPreviousInvocable.run(new List<FinancialMetricsStampPreviousInvocable.Request>());
        FinancialMetricsRecalcNetInvocable.run(new List<FinancialMetricsRecalcNetInvocable.Request>{ blank, null });
        FinancialMetricsLossMrrInvocable.run(new List<FinancialMetricsLossMrrInvocable.Request>{ null });
        FinancialMetricsWalkAwayInvocable.run(new List<FinancialMetricsWalkAwayInvocable.Request>{ null });
        FinancialMetricsActivationInvocable.run(new List<FinancialMetricsActivationInvocable.Request>{ null });
        Test.stopTest();

        System.assertEquals(0, FinancialMetricsService.faultLog.size(), 'Empty input must not raise faults');
    }

    private static Contract stampedBy(Id orderId, Datetime activatedAt) {
        Map<String, Object> raw = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'Contract' },
            'Last_Stamped_Order__c' => orderId
        };
        if (orderId != null) {
            raw.put('Last_Stamped_Order__r', new Map<String, Object>{
                'attributes' => new Map<String, Object>{ 'type' => 'Order' },
                'Id' => orderId,
                'ActivatedDate' => activatedAt
            });
        }
        return (Contract) JSON.deserialize(JSON.serialize(raw), Contract.class);
    }

    private static Order activatedAt(Id orderId, Datetime activatedOn) {
        Map<String, Object> raw = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'Order' },
            'Id' => orderId,
            'ActivatedDate' => activatedOn
        };
        return (Order) JSON.deserialize(JSON.serialize(raw), Order.class);
    }

    @IsTest
    static void testSupersededStampGuardAllowsOnlyTheNewestActivation() {
        Id firstOrder = '801000000000001AAA';
        Id secondOrder = '801000000000002AAA';
        Datetime early = Datetime.now().addMinutes(-10);
        Datetime late = Datetime.now();

        System.assertEquals(false,
            FinancialMetricsService.supersededByLaterStamp(stampedBy(null, null), activatedAt(firstOrder, early)),
            'A contract that has never been stamped must accept the stamp');

        System.assertEquals(true,
            FinancialMetricsService.supersededByLaterStamp(
                stampedBy(firstOrder, early), activatedAt(firstOrder, early)),
            'The same order must not stamp the same contract twice');

        System.assertEquals(true,
            FinancialMetricsService.supersededByLaterStamp(
                stampedBy(secondOrder, late), activatedAt(firstOrder, early)),
            'An older activation must not overwrite a baseline a newer one already owns');

        System.assertEquals(false,
            FinancialMetricsService.supersededByLaterStamp(
                stampedBy(firstOrder, early), activatedAt(secondOrder, late)),
            'A newer activation must be free to advance the baseline');

        System.assertEquals(false,
            FinancialMetricsService.supersededByLaterStamp(
                stampedBy(firstOrder, null), activatedAt(secondOrder, late)),
            'A missing activation date must not block the stamp');
    }

    @IsTest
    static void testOpportunityStampSkipsWhenNothingChanged() {
        Contract contract = baselineContract(1000, 12000, new Map<String, Decimal>{ 'Desk' => 1000 });
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM Idempotent Opp', contract.Id, 'Change Order');
        insert opp;
        Quote amend = buildQuote('FM Idempotent', opp.Id, contract.Id, 'Draft');
        insert amend;
        asActionType(amend.Id, 'Amend');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            amend.Id => new List<QuoteLineItem>{
                delta(amend.Id, products.get('FM Desk Product'), LOB_DESK, -2, 150)
            }
        };

        Test.startTest();
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ amend.Id });
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ amend.Id }, null);
        FinancialMetricsService.stampOpportunityMetrics(new Set<Id>{ amend.Id });
        Opportunity first = reloadOpportunity(opp.Id);
        Datetime firstTouch = [SELECT LastModifiedDate FROM Opportunity WHERE Id = :opp.Id].LastModifiedDate;
        FinancialMetricsService.stampGuard.clear();
        FinancialMetricsService.stampOpportunityMetrics(new Set<Id>{ amend.Id });
        Test.stopTest();

        Opportunity second = reloadOpportunity(opp.Id);
        System.assertEquals(-300, first.Loss_MRR__c, 'A negative recurring line is the loss');
        System.assertEquals(700, first.Booked_MRR__c, 'Booked MRR is the Net: 1000 baseline minus 300');
        System.assertEquals(first.Loss_MRR__c, second.Loss_MRR__c, 'A re-fire must not change the value');
        System.assertEquals(first.Booked_MRR__c, second.Booked_MRR__c, 'A re-fire must not change the value');
        System.assertEquals(firstTouch,
            [SELECT LastModifiedDate FROM Opportunity WHERE Id = :opp.Id].LastModifiedDate,
            'A re-fire with identical values must not issue a second DML');
        System.assertEquals(0, FinancialMetricsService.faultLog.size(), 'No faults');
    }

    private static void assetBaseline(Id contractId, Map<Id, Decimal> mrrByProductId) {
        FinancialMetricsService.assetBaselineOverride =
            new Map<Id, Map<Id, Decimal>>{ contractId => mrrByProductId };
    }

    @IsTest
    static void testRenewalPartialLosesTheDroppedProduct() {
        Contract contract = baselineContract(1000, 12000, new Map<String, Decimal>{ 'Desk' => 1000 });
        Map<String, Id> products = productIds();
        Id keptProduct = products.get('FM Desk Product');
        Id droppedProduct = products.get('FM Cyber Product');

        assetBaseline(contract.Id, new Map<Id, Decimal>{
            keptProduct => 600, droppedProduct => 400
        });

        Opportunity opp = buildOpportunity('FM Renewal Partial', contract.Id, 'Renewal');
        insert opp;
        Quote renew = buildQuote('FM Renewal Partial Q', opp.Id, contract.Id, 'Draft');
        insert renew;
        asActionType(renew.Id, 'Renew');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            renew.Id => new List<QuoteLineItem>{
                delta(renew.Id, keptProduct, LOB_DESK, 4, 150)
            }
        };

        Test.startTest();
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ renew.Id }, null);
        FinancialMetricsService.stampOpportunityMetrics(new Set<Id>{ renew.Id });
        Test.stopTest();

        Opportunity result = reloadOpportunity(opp.Id);
        System.assertEquals(-400, result.Loss_MRR__c,
            'The dropped product is a loss even though no negative line exists');
    }

    @IsTest
    static void testRenewalGrossLossIgnoresOffsettingAdditions() {
        Map<String, Id> products = productIds();
        Id keptProduct = products.get('FM Desk Product');
        Id droppedProduct = products.get('FM Cyber Product');
        Id addedProduct = products.get('FM Infra Product');

        Map<Id, Decimal> baseline = new Map<Id, Decimal>{
            keptProduct => 600, droppedProduct => 400
        };
        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            delta(null, keptProduct, LOB_DESK, 4, 150),
            delta(null, addedProduct, LOB_INFRA, 1, 250)
        };

        Test.startTest();
        Decimal loss = FinancialMetricsService.renewalGrossLoss(baseline, lines);
        Test.stopTest();

        System.assertEquals(-400, loss,
            'A 250 addition must not net off a 400 drop - loss is gross');
    }

    @IsTest
    static void testRenewalFullAndUpliftRecordNoLoss() {
        Map<String, Id> products = productIds();
        Id a = products.get('FM Desk Product');
        Id b = products.get('FM Cyber Product');
        Map<Id, Decimal> baseline = new Map<Id, Decimal>{ a => 600, b => 400 };

        Test.startTest();
        Decimal full = FinancialMetricsService.renewalGrossLoss(baseline, new List<QuoteLineItem>{
            delta(null, a, LOB_DESK, 4, 150), delta(null, b, LOB_CYBER, 4, 100)
        });
        Decimal uplift = FinancialMetricsService.renewalGrossLoss(baseline, new List<QuoteLineItem>{
            delta(null, a, LOB_DESK, 4, 160), delta(null, b, LOB_CYBER, 4, 110)
        });
        Test.stopTest();

        System.assertEquals(0, full, 'Renewing everything at the same price loses nothing');
        System.assertEquals(0, uplift, 'An uplift loses nothing');
    }

    @IsTest
    static void testWalkAwayStageBlocksTheQuoteStamp() {
        Contract contract = baselineContract(1000, 12000, new Map<String, Decimal>{ 'Desk' => 1000 });
        Map<String, Id> products = productIds();

        Opportunity opp = buildOpportunity('FM Lost Renewal', contract.Id, 'Renewal');
        insert opp;
        Quote renew = buildQuote('FM Lost Renewal Q', opp.Id, contract.Id, 'Draft');
        insert renew;
        asActionType(renew.Id, 'Renew');

        assetBaseline(contract.Id, new Map<Id, Decimal>{ products.get('FM Desk Product') => 1000 });
        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            renew.Id => new List<QuoteLineItem>{
                delta(renew.Id, products.get('FM Desk Product'), LOB_DESK, 4, 150)
            }
        };

        Test.startTest();
        FinancialMetricsService.stampRenewalWalkAway(new Set<Id>{ opp.Id });
        update new Opportunity(
            Id = opp.Id,
            StageName = 'Closed Lost',
            Lost_Category__c = 'Chose Different Partner',
            Lost_Reason__c = 'Business Priorities Changed'
        );
        FinancialMetricsService.stampOpportunityMetrics(new Set<Id>{ renew.Id });
        Test.stopTest();

        Opportunity result = reloadOpportunity(opp.Id);
        System.assertEquals(-1000, result.Loss_MRR__c,
            'Walk away owns Loss MRR - a later quote stamp must not overwrite it');
        System.assertEquals(0, result.Booked_MRR__c, 'Nothing was booked on a lost renewal');
    }

    @IsTest
    static void testRenewalRemovalAsNegativeLineIsNotDoubleCounted() {
        Map<String, Id> products = productIds();
        Id dropped = products.get('FM Cyber Product');
        Id kept = products.get('FM Desk Product');

        Test.startTest();
        Decimal loss = FinancialMetricsService.renewalGrossLoss(
            new Map<Id, Decimal>{ dropped => 55, kept => 600 },
            new List<QuoteLineItem>{
                rawLine(null, dropped, LOB_CYBER, 0, -55, -660),
                rawLine(null, kept, LOB_DESK, 4, 600, 7200)
            }
        );
        Test.stopTest();

        System.assertEquals(-55, loss,
            'A removal written as a negative line loses 55, not 110');
    }

    @IsTest
    static void testRenewalLossCoversEveryRemovalShape() {
        Map<String, Id> products = productIds();
        Id parity = products.get('FM Desk Product');
        Id negativeDrop = products.get('FM Cyber Product');
        Id zeroDrop = products.get('FM Infra Product');
        Id reduced = products.get('FM Private Cloud Product');
        Id negativeDropTwo = products.get('FM VOIP Product');

        Map<Id, Decimal> baseline = new Map<Id, Decimal>{
            parity => 5, negativeDrop => 55, zeroDrop => 520,
            reduced => 9.9, negativeDropTwo => 114.78
        };
        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            rawLine(null, parity, LOB_DESK, 1, 5, 60),
            rawLine(null, negativeDrop, LOB_CYBER, 0, -55, -660),
            rawLine(null, zeroDrop, LOB_INFRA, 0, 0, -16.75),
            rawLine(null, reduced, LOB_PC, 1, 9, 108),
            rawLine(null, negativeDropTwo, LOB_VOIP, 0, -115, -3.7)
        };

        Test.startTest();
        Decimal loss = FinancialMetricsService.renewalGrossLoss(baseline, lines);
        Decimal renewed = FinancialMetricsService.sumRenewedMrr(lines);
        Test.stopTest();

        System.assertEquals(-690.68, loss,
            'Every removal shape loses its baseline exactly once');
        System.assertEquals(14, renewed,
            'The renewed book is the surviving lines only - removals contribute zero');
    }

    @IsTest
    static void testRenewalCurrentNeverGoesNegative() {
        Map<String, Id> products = productIds();
        Id dropped = products.get('FM Cyber Product');

        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            rawLine(null, dropped, LOB_CYBER, 0, -55, -660)
        };

        Test.startTest();
        Decimal mrr = FinancialMetricsService.sumRenewedMrr(lines);
        Decimal tcv = FinancialMetricsService.sumRenewedTcv(lines);
        Map<String, Decimal> byLob = FinancialMetricsService.sumRenewedMrrByLob(lines);
        Test.stopTest();

        System.assertEquals(0, mrr, 'A renewal cannot book negative MRR');
        System.assertEquals(0, tcv, 'A renewal cannot book negative TCV');
        System.assertEquals(0, byLob.get('Cyber'), 'The LOB bucket clamps with the total');
    }

    @IsTest
    static void testAssetPeriodSelectionUsesTheCurrentNotTheLatestPeriod() {
        AssetStatePeriod current = statePeriod(
            Datetime.now().addDays(-30), Datetime.now().addDays(365), 520
        );
        AssetStatePeriod future = statePeriod(
            Datetime.now().addDays(365), Datetime.now().addDays(1460), -0.47
        );

        Test.startTest();
        AssetStatePeriod chosen = FinancialMetricsService.periodCoveringNow(
            new List<AssetStatePeriod>{ current, future }
        );
        AssetStatePeriod onlyFuture = FinancialMetricsService.periodCoveringNow(
            new List<AssetStatePeriod>{ future }
        );
        Test.stopTest();

        System.assertEquals(520, chosen.Mrr,
            'The period covering today wins - not the one the renewal just created');
        System.assertEquals(-0.47, onlyFuture.Mrr,
            'With no current period the only period available is still returned');
    }

    @IsTest
    static void testStampRefreshesACurrentSetThatWentStaleAfterApproval() {
        Contract contract = baselineContract(285, 10260, new Map<String, Decimal>{ 'Infra' => 285 });
        Map<String, Id> products = productIds();
        Id infra = products.get('FM Infra Product');

        Opportunity opp = buildOpportunity('FM Stale Current', contract.Id, 'Renewal');
        insert opp;
        Quote renew = buildQuote('FM Stale Current Q', opp.Id, contract.Id, 'Draft');
        insert renew;
        asActionType(renew.Id, 'Renew');

        update new Quote(
            Id = renew.Id,
            Current_MRR__c = 285,
            Current_MRR_Infra__c = 285,
            Current_TCV__c = 10260
        );

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            renew.Id => new List<QuoteLineItem>{
                delta(renew.Id, infra, LOB_INFRA, 2, 285)
            }
        };

        Test.startTest();
        FinancialMetricsService.stampOpportunityMetrics(new Set<Id>{ renew.Id });
        Test.stopTest();

        Quote result = reload(renew.Id);
        System.assertEquals(570, result.Current_MRR__c,
            'The stamp refreshes a Current set that went stale when the quote was approved');
        System.assertEquals(570, result.Current_MRR_Infra__c, 'The LOB bucket refreshes with it');
        System.assertEquals(570, reloadOpportunity(opp.Id).Booked_MRR__c,
            'The quote and the opportunity agree after the refresh');
    }

    @IsTest
    static void testStampLeavesAnAlreadyCurrentQuoteUntouched() {
        Contract contract = baselineContract(285, 10260, new Map<String, Decimal>{ 'Infra' => 285 });
        Map<String, Id> products = productIds();
        Id infra = products.get('FM Infra Product');

        Opportunity opp = buildOpportunity('FM Fresh Current', contract.Id, 'Renewal');
        insert opp;
        Quote renew = buildQuote('FM Fresh Current Q', opp.Id, contract.Id, 'Draft');
        insert renew;
        asActionType(renew.Id, 'Renew');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            renew.Id => new List<QuoteLineItem>{
                delta(renew.Id, infra, LOB_INFRA, 2, 285)
            }
        };

        Test.startTest();
        FinancialMetricsService.recalcNetMetrics(new Set<Id>{ renew.Id }, null);
        Datetime afterRecalc =
            [SELECT LastModifiedDate FROM Quote WHERE Id = :renew.Id].LastModifiedDate;
        FinancialMetricsService.stampOpportunityMetrics(new Set<Id>{ renew.Id });
        Test.stopTest();

        System.assertEquals(afterRecalc,
            [SELECT LastModifiedDate FROM Quote WHERE Id = :renew.Id].LastModifiedDate,
            'A quote already holding the right numbers must not be written again');
        System.assertEquals(0, FinancialMetricsService.faultLog.size(), 'No faults');
    }

    @IsTest
    static void testStampGuardBlocksReEntryWithinTheTransaction() {
        Contract contract = baselineContract(1000, 12000, new Map<String, Decimal>{ 'Desk' => 1000 });
        Map<String, Id> products = productIds();
        Id desk = products.get('FM Desk Product');

        Opportunity opp = buildOpportunity('FM Guarded Stamp', contract.Id, 'Change Order');
        insert opp;
        Quote amend = buildQuote('FM Guarded Stamp Q', opp.Id, contract.Id, 'Draft');
        insert amend;
        asActionType(amend.Id, 'Amend');

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            amend.Id => new List<QuoteLineItem>{ delta(amend.Id, desk, LOB_DESK, 1, 200) }
        };

        Test.startTest();
        FinancialMetricsService.stampPreviousMetrics(new Set<Id>{ amend.Id });
        FinancialMetricsService.stampOpportunityMetrics(new Set<Id>{ amend.Id });
        Decimal afterFirst = reloadOpportunity(opp.Id).Booked_MRR__c;

        FinancialMetricsService.lineOverride = new Map<Id, List<QuoteLineItem>>{
            amend.Id => new List<QuoteLineItem>{ delta(amend.Id, desk, LOB_DESK, 5, 200) }
        };
        FinancialMetricsService.stampOpportunityMetrics(new Set<Id>{ amend.Id });
        Test.stopTest();

        System.assertEquals(1200, afterFirst, 'Booked MRR is the Net: 1000 baseline plus 200');
        System.assertEquals(afterFirst, reloadOpportunity(opp.Id).Booked_MRR__c,
            'The guard blocks a second stamp of the same quote in one transaction');
    }

    @IsTest
    static void testAmendmentDeltaSumsAreUnchangedByTheRenewalClamp() {
        Map<String, Id> products = productIds();
        Id down = products.get('FM Cyber Product');
        Id up = products.get('FM Desk Product');

        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            rawLine(null, down, LOB_CYBER, 0, -190, -2280),
            rawLine(null, up, LOB_DESK, 1, 72, 864)
        };

        Test.startTest();
        Decimal booked = FinancialMetricsService.sumBookedMrr(lines);
        Decimal loss = FinancialMetricsService.sumNegativeMrr(lines);
        Map<String, Decimal> byLob = FinancialMetricsService.sumMrrByLob(lines);
        Test.stopTest();

        System.assertEquals(-118, booked,
            'An amendment still nets its deltas - the clamp must not reach this path');
        System.assertEquals(-190, loss, 'Amendment loss is still gross negative');
        System.assertEquals(-190, byLob.get('Cyber'),
            'Amendment LOB buckets still carry negative deltas');
    }
}