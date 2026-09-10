public with sharing class FinancialMetricsWalkAwayInvocable {

    public class Request {
        @InvocableVariable(label='Opportunity Id' required=true)
        public Id opportunityId;
    }

    @InvocableMethod(
        label='Stamp Renewal Walk Away Loss MRR'
        description='Stamps Loss MRR as the negative of the contract MRR baseline when a renewal is lost'
        category='Financial Metrics'
    )
    public static void run(List<Request> requests) {
        Set<Id> opportunityIds = new Set<Id>();
        for (Request request : requests) {
            if (request != null && request.opportunityId != null) {
                opportunityIds.add(request.opportunityId);
            }
        }
        FinancialMetricsService.stampRenewalWalkAway(opportunityIds);
    }
}