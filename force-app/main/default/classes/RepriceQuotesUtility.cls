public without sharing class RepriceQuotesUtility {
    @InvocableMethod(label='Reprice Quote' category='Quote')
    public static void repriceQuotes(List<String> quoteIds) {
        // Implement RevSalesTrxn.placeSalesTransaction with FORCE preference
        for (String quoteId : quoteIds) {
            RevSalesTrxn.RecordResource quoteRecord = new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', quoteId);
            RevSalesTrxn.RecordWithReferenceRequest quoteObject = new RevSalesTrxn.RecordWithReferenceRequest('refQuote', quoteRecord);

            List<RevSalesTrxn.RecordWithReferenceRequest> records = new List<RevSalesTrxn.RecordWithReferenceRequest>();
            records.add(quoteObject);

            RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest('refreshQuoteGraph', records);
            RevSalesTrxn.PricingPreferenceEnum pricingPref = RevSalesTrxn.PricingPreferenceEnum.SYSTEM;
            RevSalesTrxn.ConfigurationExecutionEnum configEnum = RevSalesTrxn.ConfigurationExecutionEnum.SYSTEM;
            RevSalesTrxn.ConfigurationOptionsInput config = new RevSalesTrxn.ConfigurationOptionsInput();

            RevSalesTrxn.PlaceSalesTransactionResponse resp = RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                graph, pricingPref, configEnum, config, null
            );
        }
    }
}