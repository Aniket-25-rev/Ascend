public with sharing class FinancialMetricsStampPreviousInvocable {

    public class Request {
        @InvocableVariable(label='Quote Id' required=true)
        public Id quoteId;
    }

    @InvocableMethod(
        label='Stamp Previous Quote Metrics'
        description='Copies the contract financial baseline into the quote Existing set'
        category='Financial Metrics'
    )
    public static void run(List<Request> requests) {
        Set<Id> quoteIds = new Set<Id>();
        for (Request request : requests) {
            if (request != null && request.quoteId != null) {
                quoteIds.add(request.quoteId);
            }
        }
        FinancialMetricsService.stampPreviousMetrics(quoteIds);
    }
}