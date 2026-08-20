@IsTest
private class ContractAssetChangeHandlerTest {

    @TestSetup
    static void makeData() {
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Contract con = new Contract(
            AccountId    = acc.Id,
            StartDate    = Date.today(),
            ContractTerm = 12,
            Status       = 'Draft'
        );
        insert con;

        Asset asset = new Asset(
            Name       = 'Test Asset',
            AccountId  = acc.Id,
            ContractId = con.Id,
            Price      = 1000,
            Status     = 'Purchased'
        );
        insert asset;
    }

    @IsTest
    static void testDecreaseLogsPartialChurn() {
        Asset asset = [SELECT Id, Price, Status, AccountId, ContractId, InstallDate, UsageEndDate FROM Asset LIMIT 1];
        asset.Price = 600;

        Test.startTest();
        update asset;
        Test.stopTest();

        List<Contract_Asset_Change__c> changes = [
            SELECT Transaction_Type__c, Churn_Type__c, Change_Amount__c, Is_Churn__c
            FROM Contract_Asset_Change__c
        ];
        System.assertEquals(1, changes.size(), 'Expected one change log');
        System.assertEquals('Decrease', changes[0].Transaction_Type__c);
        System.assertEquals('Partial Churn', changes[0].Churn_Type__c);
        System.assertEquals(-400, changes[0].Change_Amount__c);
        System.assertEquals(true, changes[0].Is_Churn__c);
    }

    @IsTest
    static void testRemovalLogsFullChurn() {
        Asset asset = [SELECT Id, Price, Status, AccountId, ContractId, InstallDate, UsageEndDate FROM Asset LIMIT 1];
        asset.Status = 'Obsolete';

        Test.startTest();
        update asset;
        Test.stopTest();

        List<Contract_Asset_Change__c> changes = [
            SELECT Transaction_Type__c, Churn_Type__c, Is_Churn__c
            FROM Contract_Asset_Change__c
        ];
        System.assertEquals(1, changes.size(), 'Expected one change log');
        System.assertEquals('Removal', changes[0].Transaction_Type__c);
        System.assertEquals('Full Churn', changes[0].Churn_Type__c);
        System.assertEquals(true, changes[0].Is_Churn__c);
    }

    @IsTest
    static void testIncreaseNoChurn() {
        Asset asset = [SELECT Id, Price, Status, AccountId, ContractId, InstallDate, UsageEndDate FROM Asset LIMIT 1];
        asset.Price = 1500;

        Test.startTest();
        update asset;
        Test.stopTest();

        List<Contract_Asset_Change__c> changes = [
            SELECT Transaction_Type__c, Churn_Type__c, Change_Amount__c, Is_Churn__c
            FROM Contract_Asset_Change__c
        ];
        System.assertEquals(1, changes.size());
        System.assertEquals('Increase', changes[0].Transaction_Type__c);
        System.assertEquals('N/A', changes[0].Churn_Type__c);
        System.assertEquals(500, changes[0].Change_Amount__c);
        System.assertEquals(false, changes[0].Is_Churn__c);
    }

    @IsTest
    static void testTCVRecalculatedAfterChange() {
        Asset asset = [SELECT Id, Price, Status, AccountId, ContractId FROM Asset LIMIT 1];
        Id contractId = asset.ContractId;
        asset.Price = 800;

        Test.startTest();
        update asset;
        Test.stopTest();

        Contract con = [SELECT TCV__c FROM Contract WHERE Id = :contractId];
        System.assertEquals(800, con.TCV__c, 'TCV should reflect the updated asset price');
    }

    @IsTest
    static void testNoLogWhenNothingChanged() {
        Asset asset = [SELECT Id, Name, AccountId, ContractId FROM Asset LIMIT 1];
        asset.Name = 'Renamed Asset';

        Test.startTest();
        update asset;
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM Contract_Asset_Change__c];
        System.assertEquals(0, count, 'No change log expected when price and status are unchanged');
    }
}
