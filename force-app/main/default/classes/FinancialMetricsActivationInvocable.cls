public with sharing class FinancialMetricsActivationInvocable {

    public class Request {
        @InvocableVariable(label='Order Id' required=true)
        public Id orderId;
    }

    @InvocableMethod(
        label='Stamp Contract Baseline From Order'
        description='Copies the activating order quote Net values onto the contract financial baseline'
        category='Financial Metrics'
    )
    public static void run(List<Request> requests) {
        Set<Id> orderIds = new Set<Id>();
        for (Request request : requests) {
            if (request != null && request.orderId != null) {
                orderIds.add(request.orderId);
            }
        }
        FinancialMetricsService.stampContractFromOrder(orderIds);
    }
}