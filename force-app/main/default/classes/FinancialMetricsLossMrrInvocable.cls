public with sharing class FinancialMetricsLossMrrInvocable {

    public class Request {
        @InvocableVariable(label='Quote Id' required=true)
        public Id quoteId;
    }

    @InvocableMethod(
        label='Stamp Opportunity Booked and Loss MRR'
        description='Stamps Booked MRR from the quote Net MRR and gross negative Loss MRR from the negative line deltas'
        category='Financial Metrics'
    )
    public static void run(List<Request> requests) {
        Set<Id> quoteIds = new Set<Id>();
        for (Request request : requests) {
            if (request != null && request.quoteId != null) {
                quoteIds.add(request.quoteId);
            }
        }
        FinancialMetricsService.stampOpportunityMetrics(quoteIds);
    }
}