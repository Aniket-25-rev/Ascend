public with sharing class FinancialMetricsRecalcNetInvocable {

    public class Request {
        @InvocableVariable(label='Quote Id' required=true)
        public Id quoteId;

        @InvocableVariable(label='Quote Line Item Id To Exclude')
        public Id excludeLineId;
    }

    @InvocableMethod(
        label='Recalculate Net Quote Metrics'
        description='Recalculates the Current set: per LOB MRR, MRR total and TCV from this quote own lines'
        category='Financial Metrics'
    )
    public static void run(List<Request> requests) {
        Set<Id> quoteIds = new Set<Id>();
        Set<Id> excludedLineIds = new Set<Id>();
        for (Request request : requests) {
            if (request == null) {
                continue;
            }
            if (request.quoteId != null) {
                quoteIds.add(request.quoteId);
            }
            if (request.excludeLineId != null) {
                excludedLineIds.add(request.excludeLineId);
            }
        }
        FinancialMetricsService.recalcNetMetrics(quoteIds, excludedLineIds);
    }
}