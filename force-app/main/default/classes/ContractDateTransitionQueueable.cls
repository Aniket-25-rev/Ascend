public without sharing class ContractDateTransitionQueueable
    implements Queueable, Database.AllowsCallouts {

    private static final Integer MAX_RETRIES = 3;

    private final Map<Id, Date> oldStartDates;
    private final Map<Id, Date> targetEndDates;
    private final Map<Id, Date> realNewStartDates;
    private final Boolean bridgeComplete;
    private final Boolean finalizePhase;
    private final Integer retryCount;

    public ContractDateTransitionQueueable(
        Map<Id, Date> oldStartDates,
        Map<Id, Date> targetEndDates,
        Map<Id, Date> realNewStartDates,
        Boolean bridgeComplete,
        Boolean finalizePhase,
        Integer retryCount
    ) {
        this.oldStartDates = oldStartDates;
        this.targetEndDates = targetEndDates;
        this.realNewStartDates = realNewStartDates;
        this.bridgeComplete = bridgeComplete;
        this.finalizePhase = finalizePhase;
        this.retryCount = retryCount;
    }

    public void execute(QueueableContext context) {
        try {
            // FOR UPDATE: lock the contracts so concurrent chains serialize
            // instead of colliding on the same contract records.
            List<Contract> contracts = [
                SELECT Id, StartDate, EndDate, ContractTerm
                FROM Contract
                WHERE Id IN :oldStartDates.keySet()
                FOR UPDATE
            ];
            Map<Id, Contract> oldContracts = new Map<Id, Contract>();
            for (Contract contract : contracts) {
                oldContracts.put(
                    contract.Id,
                    new Contract(Id = contract.Id, StartDate = oldStartDates.get(contract.Id))
                );
            }

            if (!contracts.isEmpty()) {
                if (finalizePhase) {
                    ContractTriggerHandler.finalizeDates(contracts, targetEndDates, realNewStartDates);
                    return;
                }
                ContractTriggerHandler.handleAfterUpdate(
                    contracts,
                    oldContracts,
                    targetEndDates,
                    realNewStartDates,
                    bridgeComplete
                );
            }
        } catch (DmlException ex) {
            // UNABLE_TO_LOCK_ROW: another chain holds the lock. Re-enqueue with
            // a bounded retry so the chain eventually completes instead of
            // failing permanently.
            if (ex.getMessage().contains('UNABLE_TO_LOCK_ROW') && retryCount < MAX_RETRIES) {
                System.enqueueJob(new ContractDateTransitionQueueable(
                    oldStartDates,
                    targetEndDates,
                    realNewStartDates,
                    bridgeComplete,
                    finalizePhase,
                    retryCount + 1
                ));
            } else {
                throw ex;
            }
        }
    }
}