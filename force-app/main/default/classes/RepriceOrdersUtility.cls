public without sharing class RepriceOrdersUtility {
    @InvocableMethod(label='Reprice Order' category='Order')
    public static void repriceOrders(List<String> orderIds) {
        // Implement RevSalesTrxn.placeSalesTransaction with FORCE preference
        for (String orderId : orderIds) {
            RevSalesTrxn.RecordResource orderRecord = new RevSalesTrxn.RecordResource(Order.getSObjectType(), 'PATCH', orderId);
            RevSalesTrxn.RecordWithReferenceRequest orderObject = new RevSalesTrxn.RecordWithReferenceRequest('refOrder', orderRecord);

            List<RevSalesTrxn.RecordWithReferenceRequest> records = new List<RevSalesTrxn.RecordWithReferenceRequest>();
            records.add(orderObject);

            RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest('refreshOrderGraph', records);
            RevSalesTrxn.PricingPreferenceEnum pricingPref = RevSalesTrxn.PricingPreferenceEnum.SYSTEM;
            RevSalesTrxn.ConfigurationExecutionEnum configEnum = RevSalesTrxn.ConfigurationExecutionEnum.SYSTEM;
            RevSalesTrxn.ConfigurationOptionsInput config = new RevSalesTrxn.ConfigurationOptionsInput();

            RevSalesTrxn.PlaceSalesTransactionResponse resp = RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                graph, pricingPref, configEnum, config, null
            );
        }
    }
}