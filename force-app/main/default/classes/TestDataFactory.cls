@isTest
public class TestDataFactory {

    public static Account createAccount(String name) {
        Account acc = new Account(
            Name = name,
            BillingState = 'IL'
        );
        insert acc;
        return acc;
    }

    public static Contract createContract(Id accountId, Date startDate, Integer contractTerm) {
        Contract contract = new Contract(
            AccountId = accountId,
            Status = 'Draft',
            StartDate = startDate,
            ContractTerm = contractTerm
        );
        insert contract;
        return contract;
    }

    private static Id recurringSellingModelId;

    /**
     * OrderItem.EndDate is cleared to null on insert by the org's active
     * "Set_Order_Product_Dates_On_Creation" flow unless the product's
     * selling model is TermDefined, so recurring test products must be
     * linked to one via ProductSellingModelOption.
     */
    private static Id getRecurringSellingModelId() {
        if (recurringSellingModelId != null) {
            return recurringSellingModelId;
        }
        ProductSellingModel psm = new ProductSellingModel(
            Name = 'Test Term Defined Model',
            SellingModelType = 'TermDefined',
            Status = 'Active',
            PricingTerm = 1,
            PricingTermUnit = 'Months'
        );
        insert psm;
        recurringSellingModelId = psm.Id;
        return recurringSellingModelId;
    }

    public static PricebookEntry createStandardPricebookEntry(String productName, Decimal unitPrice) {
        Product2 product = new Product2(
            Name = productName,
            IsActive = true
        );
        insert product;

        Id sellingModelId = getRecurringSellingModelId();
        insert new ProductSellingModelOption(
            Product2Id = product.Id,
            ProductSellingModelId = sellingModelId
        );

        Id standardPricebookId = Test.getStandardPricebookId();
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = standardPricebookId,
            Product2Id = product.Id,
            ProductSellingModelId = sellingModelId,
            UnitPrice = unitPrice,
            IsActive = true
        );
        insert pbe;
        return pbe;
    }

    public static Order createOrder(Id accountId, Id contractId, Date effectiveDate, Date endDate) {
        Order ord = new Order(
            AccountId = accountId,
            ContractId = contractId,
            EffectiveDate = effectiveDate,
            EndDate = endDate,
            Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert ord;
        return ord;
    }

    public static OrderItemGroup createOrderItemGroup(Id orderId, String name, Date startDate, Date endDate) {
        OrderItemGroup itemGroup = new OrderItemGroup(
            OrderId = orderId,
            Name = name,
            StartDate = startDate,
            EndDate = endDate
        );
        insert itemGroup;
        return itemGroup;
    }

    public static OrderItem createOrderItem(
        Id orderId,
        Id orderItemGroupId,
        Id pricebookEntryId,
        Date serviceDate,
        Date endDate
    ) {
        OrderItem item = new OrderItem(
            OrderId = orderId,
            OrderItemGroupId = orderItemGroupId,
            PricebookEntryId = pricebookEntryId,
            Quantity = 1,
            UnitPrice = 100,
            ServiceDate = serviceDate,
            EndDate = endDate
        );
        insert item;

        // The org's "Set_Order_Product_Dates_On_Creation" flow (Create-only)
        // can clear EndDate back to null depending on the product's selling
        // model. Re-asserting it via a follow-up update (not a create) does
        // not re-trigger that flow, guaranteeing the test data we asked for.
        item.EndDate = endDate;
        update item;
        return item;
    }
}