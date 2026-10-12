@isTest
private class ContractTriggerHandlerTest {

    private static final Date BASE_START = Date.newInstance(2026, 2, 1);
    private static final Integer TERM_MONTHS = 12;

    @TestSetup
    static void setupTestData() {
        Account acc = TestDataFactory.createAccount('CTH Test Account');
        TestDataFactory.createStandardPricebookEntry('CTH Test Product', 100);
    }

    private static Account getAccount() {
        return [SELECT Id FROM Account LIMIT 1];
    }

    private static Id getPricebookEntryId() {
        return [SELECT Id FROM PricebookEntry LIMIT 1].Id;
    }

    @isTest
    static void handleBeforeUpdate_normalizesEndDateToLastDayOfMonth() {
        Account acc = getAccount();
        Contract contract = TestDataFactory.createContract(acc.Id, Date.newInstance(2026, 3, 1), 6);
        contract = [SELECT Id, StartDate, EndDate FROM Contract WHERE Id = :contract.Id];

        // 15th of the month, 6-month term: the raw StartDate + Term - 1 day
        // formula lands on 2026-09-14, which is not month-end.
        Contract oldState = new Contract(Id = contract.Id, StartDate = contract.StartDate, EndDate = contract.EndDate);
        Contract newState = new Contract(
            Id = contract.Id, StartDate = Date.newInstance(2026, 3, 15), ContractTerm = 6
        );

        ContractTriggerHandler.handleBeforeUpdate(
            new List<Contract>{ newState }, new Map<Id, Contract>{ contract.Id => oldState }
        );

        System.assertEquals(Date.newInstance(2026, 9, 30), newState.EndDate,
            'A non-month-end raw end date (2026-09-14) should be normalized forward to the last day of that same month, never into an earlier or later month.');
    }

    /**
     * ContractDateTransitionQueueable always chains at least one more queueable
     * job from its execute() method (the finalize phase, or the bridge phase).
     * A real `update contract` that changes StartDate - even alone, even
     * without an explicit Test.stopTest() - gets its enqueued job flushed by
     * the test framework, and that job's own attempt to chain a second job
     * throws "Maximum stack depth has been reached". So the real end-to-end
     * path (trigger -> queueable -> queueable) cannot be exercised inside an
     * Apex test at all for this class.
     *
     * These tests instead insert the Contract directly at its POST-change
     * StartDate/EndDate (so no real update ever changes Contract.StartDate,
     * and finalizeDates' own internal `update` never looks like a real
     * StartDate change to the trigger), put the PRE-change bounds only on
     * the Order/OrderItemGroup/OrderItem fixtures, and call the handler's
     * phases directly and synchronously - exactly the arguments
     * ContractDateTransitionQueueable.execute() would pass at each phase.
     */
    @isTest
    static void startDateMovedLater_widensOrderBeforeCascadingToGroupedAndUngroupedItems() {
        Account acc = getAccount();
        Id pbeId = getPricebookEntryId();

        Date newStart = BASE_START.addMonths(1);
        Date expectedEnd = newStart.addMonths(TERM_MONTHS).addDays(-1);
        Date originalEnd = BASE_START.addMonths(TERM_MONTHS).addDays(-1);

        // Contract and its order family start out fully consistent at the
        // original (earlier) bounds - an Order can never be created with
        // dates before its contract's current start date.
        Contract contract = TestDataFactory.createContract(acc.Id, BASE_START, TERM_MONTHS);
        contract = [SELECT Id, StartDate, EndDate FROM Contract WHERE Id = :contract.Id];

        Order ord = TestDataFactory.createOrder(acc.Id, contract.Id, BASE_START, originalEnd);
        OrderItemGroup itemGroup = TestDataFactory.createOrderItemGroup(ord.Id, 'Full Term Group', BASE_START, originalEnd);
        OrderItem groupedItem = TestDataFactory.createOrderItem(ord.Id, itemGroup.Id, pbeId, BASE_START, originalEnd);
        OrderItem ungroupedItem = TestDataFactory.createOrderItem(ord.Id, null, pbeId, BASE_START, originalEnd);

        // Real DML so handleBeforeUpdate's recalculation is exercised for
        // real. This does enqueue a real ContractDateTransitionQueueable via
        // the trigger, but we abort it immediately - letting it run would
        // have it discover the orders above and chain a second job, which
        // throws "Maximum stack depth has been reached" in test context (see
        // the class-level comment). Aborting leaves the contract safely
        // transitioned for real, with nothing left to auto-flush.
        contract.StartDate = newStart;
        update contract;
        Id pendingJobId = [
            SELECT Id FROM AsyncApexJob
            WHERE ApexClass.Name = 'ContractDateTransitionQueueable' AND Status IN ('Queued', 'Preparing', 'Holding')
            ORDER BY CreatedDate DESC LIMIT 1
        ].Id;
        System.abortJob(pendingJobId);

        Contract updatedContract = [SELECT Id, StartDate, EndDate FROM Contract WHERE Id = :contract.Id];
        System.assertEquals(expectedEnd, updatedContract.EndDate, 'Contract EndDate should extend to match the new term.');

        Map<Id, Contract> oldContracts = new Map<Id, Contract>{
            contract.Id => new Contract(Id = contract.Id, StartDate = BASE_START)
        };
        Map<Id, Date> targetEndDates = new Map<Id, Date>{ contract.Id => updatedContract.EndDate };

        ContractTriggerHandler.handleAfterUpdate(
            new List<Contract>{ updatedContract }, oldContracts, targetEndDates, false
        );
        ContractTriggerHandler.finalizeDates(
            new List<Contract>{ new Contract(Id = contract.Id, StartDate = updatedContract.StartDate) }, targetEndDates
        );

        Order updatedOrder = [SELECT Id, EffectiveDate, EndDate FROM Order WHERE Id = :ord.Id];
        OrderItemGroup updatedGroup = [SELECT Id, StartDate, EndDate FROM OrderItemGroup WHERE Id = :itemGroup.Id];
        OrderItem updatedGroupedItem = [SELECT Id, ServiceDate, EndDate FROM OrderItem WHERE Id = :groupedItem.Id];
        OrderItem updatedUngroupedItem = [SELECT Id, ServiceDate, EndDate FROM OrderItem WHERE Id = :ungroupedItem.Id];

        System.assertEquals(newStart, updatedOrder.EffectiveDate, 'Order EffectiveDate should track the contract start.');
        System.assertEquals(expectedEnd, updatedOrder.EndDate,
            'Order EndDate must be widened to the contract end before child records grow into it (the reported bug).');

        System.assertEquals(newStart, updatedGroup.StartDate, 'Order item group StartDate should shift with the contract.');
        System.assertEquals(expectedEnd, updatedGroup.EndDate, 'Order item group EndDate should extend to the new contract end.');

        System.assertEquals(newStart, updatedGroupedItem.ServiceDate, 'Grouped order item should inherit its group start date.');
        System.assertEquals(expectedEnd, updatedGroupedItem.EndDate, 'Grouped order item should inherit its group end date.');

        System.assertEquals(newStart, updatedUngroupedItem.ServiceDate, 'Ungrouped order item ServiceDate should shift with the contract.');
        System.assertEquals(expectedEnd, updatedUngroupedItem.EndDate, 'Ungrouped order item EndDate should extend to the new contract end.');
    }

    /**
     * Regression test: an item whose own end date isn't already aligned with
     * the contract's end date (so it never gets clamped/snapped to the
     * contract's authoritative end date, and instead relies purely on the
     * delta shift) used to be shifted by the exact number of DAYS the
     * contract's start date moved. That number of days is only "one calendar
     * month" for the specific month the contract happened to start in - here
     * the contract moves from March (31 days) to April, so the old fixed
     * +31-day shift pushed a 2026-05-31 end date to 2026-07-01 (a whole month
     * too far), which month-end normalization then rounded up to 2026-07-31
     * instead of the correct 2026-06-30.
     */
    @isTest
    static void startDateMovedLater_partialLengthItemShiftsByCalendarMonthsNotFixedDays() {
        Account acc = getAccount();
        Id pbeId = getPricebookEntryId();

        Date oldStart = Date.newInstance(2026, 3, 1);
        Date newStart = Date.newInstance(2026, 4, 1); // March has 31 days: old fixed-day delta was +31
        Integer term = 12;
        Date originalContractEnd = oldStart.addMonths(term).addDays(-1); // 2027-02-28
        Date expectedContractEnd = newStart.addMonths(term).addDays(-1); // 2027-03-31

        Contract contract = TestDataFactory.createContract(acc.Id, oldStart, term);
        contract = [SELECT Id, StartDate, EndDate FROM Contract WHERE Id = :contract.Id];

        Order ord = TestDataFactory.createOrder(acc.Id, contract.Id, oldStart, originalContractEnd);
        // Partial-length item: its own end date (2026-05-31) has nothing to
        // do with the contract's end date, so it's never clamped/snapped to
        // it - it only ever gets there via the delta shift being tested.
        Date partialEnd = Date.newInstance(2026, 5, 31);
        OrderItem item = TestDataFactory.createOrderItem(ord.Id, null, pbeId, oldStart, partialEnd);

        contract.StartDate = newStart;
        update contract;
        Id pendingJobId = [
            SELECT Id FROM AsyncApexJob
            WHERE ApexClass.Name = 'ContractDateTransitionQueueable' AND Status IN ('Queued', 'Preparing', 'Holding')
            ORDER BY CreatedDate DESC LIMIT 1
        ].Id;
        System.abortJob(pendingJobId);

        Contract updatedContract = [SELECT Id, StartDate, EndDate FROM Contract WHERE Id = :contract.Id];
        System.assertEquals(expectedContractEnd, updatedContract.EndDate, 'Sanity check on the contract end date.');

        Map<Id, Contract> oldContracts = new Map<Id, Contract>{
            contract.Id => new Contract(Id = contract.Id, StartDate = oldStart)
        };
        Map<Id, Date> targetEndDates = new Map<Id, Date>{ contract.Id => updatedContract.EndDate };

        ContractTriggerHandler.handleAfterUpdate(
            new List<Contract>{ updatedContract }, oldContracts, targetEndDates, false
        );
        ContractTriggerHandler.finalizeDates(
            new List<Contract>{ new Contract(Id = contract.Id, StartDate = updatedContract.StartDate) }, targetEndDates
        );

        OrderItem updatedItem = [SELECT Id, ServiceDate, EndDate FROM OrderItem WHERE Id = :item.Id];
        System.assertEquals(Date.newInstance(2026, 6, 30), updatedItem.EndDate,
            'A partial-length item should shift by the same number of calendar months the contract moved (May -> June), not by a fixed day count that can overshoot into the wrong month.');
    }

    @isTest
    static void startDateMovedEarlier_shortOrderShrinksWithoutNeedingABridge() {
        Account acc = getAccount();
        Id pbeId = getPricebookEntryId();

        Date newStart = BASE_START.addMonths(-1); // 2026-01-01
        Integer delta = BASE_START.daysBetween(newStart); // negative
        Date expectedContractEnd = newStart.addMonths(TERM_MONTHS).addDays(-1);

        Contract contract = TestDataFactory.createContract(acc.Id, newStart, TERM_MONTHS);
        contract = [SELECT Id, StartDate, EndDate FROM Contract WHERE Id = :contract.Id];
        System.assertEquals(expectedContractEnd, contract.EndDate, 'Sanity check on the contract fixture end date.');

        // Order/group/item reflect the contract's pre-change (later, shorter) bounds -
        // a short order well inside the original contract, so no bridge is needed.
        Date orderEffective = BASE_START.addMonths(1); // 2026-03-01
        Date orderEnd = orderEffective.addMonths(3).addDays(-1); // 2026-05-31
        Order ord = TestDataFactory.createOrder(acc.Id, contract.Id, orderEffective, orderEnd);

        Date groupStart = orderEffective.addDays(9); // 2026-03-10
        Date groupEnd = groupStart.addMonths(1); // 2026-04-10
        OrderItemGroup itemGroup = TestDataFactory.createOrderItemGroup(ord.Id, 'Short Group', groupStart, groupEnd);
        OrderItem item = TestDataFactory.createOrderItem(ord.Id, itemGroup.Id, pbeId, groupStart, groupEnd);

        Map<Id, Contract> oldContracts = new Map<Id, Contract>{
            contract.Id => new Contract(Id = contract.Id, StartDate = BASE_START)
        };
        Map<Id, Date> targetEndDates = new Map<Id, Date>{ contract.Id => expectedContractEnd };

        ContractTriggerHandler.handleAfterUpdate(
            new List<Contract>{ contract }, oldContracts, targetEndDates, false
        );
        ContractTriggerHandler.finalizeDates(
            new List<Contract>{ new Contract(Id = contract.Id, StartDate = contract.StartDate) }, targetEndDates
        );

        Order updatedOrder = [SELECT Id, EffectiveDate, EndDate FROM Order WHERE Id = :ord.Id];
        OrderItemGroup updatedGroup = [SELECT Id, StartDate, EndDate FROM OrderItemGroup WHERE Id = :itemGroup.Id];
        OrderItem updatedItem = [SELECT Id, ServiceDate, EndDate FROM OrderItem WHERE Id = :item.Id];

        System.assertEquals(newStart, updatedOrder.EffectiveDate, 'Order EffectiveDate should move earlier immediately with the contract.');
        System.assertEquals(expectedContractEnd, updatedOrder.EndDate, 'Order EndDate is finalized to the contract end once the cascade completes.');

        // End dates are always normalized forward to the last day of their
        // calendar month, so the delta-shifted 2026-03-10 becomes 2026-03-31.
        Date shiftedGroupEnd = groupEnd.addDays(delta);
        Date expectedGroupEnd = Date.newInstance(shiftedGroupEnd.year(), shiftedGroupEnd.month(), 1).addMonths(1).addDays(-1);

        System.assertEquals(groupStart.addDays(delta), updatedGroup.StartDate, 'Order item group StartDate should shift earlier by the same delta.');
        System.assertEquals(expectedGroupEnd, updatedGroup.EndDate, 'Order item group EndDate should shift earlier by the same delta and normalize to month-end.');
        System.assertEquals(updatedGroup.StartDate, updatedItem.ServiceDate, 'Grouped order item should inherit its group start date.');
        System.assertEquals(updatedGroup.EndDate, updatedItem.EndDate, 'Grouped order item should inherit its group end date.');
    }

    @isTest
    static void startDateMovedEarlier_fullLengthOrderTriggersEndDateBridge() {
        Account acc = getAccount();

        Date newStart = BASE_START.addMonths(-1);
        Date shrunkTarget = newStart.addMonths(TERM_MONTHS).addDays(-1);
        Date originalEnd = BASE_START.addMonths(TERM_MONTHS).addDays(-1);
        System.assert(shrunkTarget < originalEnd, 'Test setup should genuinely shrink the contract end date.');

        Contract contract = TestDataFactory.createContract(acc.Id, BASE_START, TERM_MONTHS);
        contract = [SELECT Id, StartDate, EndDate FROM Contract WHERE Id = :contract.Id];

        // Order spans the full original contract length, so shrinking the
        // contract's target end date below the order's current EndDate
        // requires the bridge (temporarily widen, then narrow in finalize).
        Order ord = TestDataFactory.createOrder(acc.Id, contract.Id, contract.StartDate, contract.EndDate);

        Map<Id, Contract> oldContracts = new Map<Id, Contract>{
            contract.Id => new Contract(Id = contract.Id, StartDate = BASE_START)
        };
        Map<Id, Date> targetEndDates = new Map<Id, Date>{ contract.Id => shrunkTarget };

        // Simulate the committed state right after a real before-update on a
        // shrink: StartDate already moved, EndDate is untouched (still wide).
        Contract contractAfterBeforeUpdate = new Contract(
            Id = contract.Id, StartDate = newStart, EndDate = originalEnd, ContractTerm = TERM_MONTHS
        );

        ContractTriggerHandler.handleAfterUpdate(
            new List<Contract>{ contractAfterBeforeUpdate }, oldContracts, targetEndDates, false
        );

        Contract bridgedContract = [SELECT Id, EndDate FROM Contract WHERE Id = :contract.Id];
        System.assertEquals(originalEnd, bridgedContract.EndDate,
            'When bridgeComplete is false and the order already extends past the new target, the contract end date should be bridged (held wide) rather than narrowed early.');
    }

    @isTest
    static void handleAfterUpdate_bulkContractsProcessWithoutErrors() {
        Account acc = getAccount();
        Id pbeId = getPricebookEntryId();

        Date newStart = BASE_START.addMonths(1);
        Date expectedEnd = newStart.addMonths(TERM_MONTHS).addDays(-1);

        List<Contract> contracts = new List<Contract>();
        for (Integer i = 0; i < 20; i++) {
            contracts.add(new Contract(
                AccountId = acc.Id,
                Status = 'Draft',
                StartDate = BASE_START,
                ContractTerm = TERM_MONTHS
            ));
        }
        insert contracts;
        contracts = [SELECT Id, StartDate, EndDate FROM Contract WHERE Id IN :contracts];

        Map<Id, Id> orderIdByContractId = new Map<Id, Id>();
        for (Contract contract : contracts) {
            Order ord = TestDataFactory.createOrder(
                acc.Id, contract.Id, BASE_START, BASE_START.addMonths(TERM_MONTHS).addDays(-1)
            );
            orderIdByContractId.put(contract.Id, ord.Id);
            TestDataFactory.createOrderItem(
                ord.Id, null, pbeId, BASE_START, BASE_START.addMonths(TERM_MONTHS).addDays(-1)
            );
        }

        // Real bulk DML so handleBeforeUpdate's recalculation runs for real
        // across all 20; the resulting job is aborted before it can flush and
        // chain a second one (see the class-level comment / the single-contract
        // growth test above for why).
        for (Contract contract : contracts) {
            contract.StartDate = newStart;
        }
        update contracts;
        List<AsyncApexJob> pendingJobs = [
            SELECT Id FROM AsyncApexJob
            WHERE ApexClass.Name = 'ContractDateTransitionQueueable' AND Status IN ('Queued', 'Preparing', 'Holding')
        ];
        for (AsyncApexJob job : pendingJobs) {
            System.abortJob(job.Id);
        }
        contracts = [SELECT Id, StartDate, EndDate FROM Contract WHERE Id IN :contracts];

        Map<Id, Contract> oldContracts = new Map<Id, Contract>();
        Map<Id, Date> targetEndDates = new Map<Id, Date>();
        List<Contract> finalizeContracts = new List<Contract>();
        for (Contract contract : contracts) {
            oldContracts.put(contract.Id, new Contract(Id = contract.Id, StartDate = BASE_START));
            targetEndDates.put(contract.Id, contract.EndDate);
            finalizeContracts.add(new Contract(Id = contract.Id, StartDate = contract.StartDate));
        }

        ContractTriggerHandler.handleAfterUpdate(contracts, oldContracts, targetEndDates, false);
        ContractTriggerHandler.finalizeDates(finalizeContracts, targetEndDates);

        List<Order> updatedOrders = [SELECT Id, EffectiveDate, EndDate FROM Order WHERE ContractId IN :orderIdByContractId.keySet()];
        System.assertEquals(20, updatedOrders.size(), 'All 20 orders should have been processed.');
        for (Order updatedOrder : updatedOrders) {
            System.assertEquals(newStart, updatedOrder.EffectiveDate, 'Every order in the bulk update should shift to the new start date.');
            System.assertEquals(expectedEnd, updatedOrder.EndDate, 'Every order in the bulk update should widen to the new end date.');
        }
    }

    @isTest
    static void queueAfterUpdate_realQueueableRunsEndToEndWhenContractHasNoOrders() {
        // The only scenario where the real trigger -> queueable chain can
        // safely flush inside a test: with no orders under the contract,
        // handleAfterUpdate returns after updating the contract without
        // enqueueing a further phase, so there's nothing to chain into and
        // no "Maximum stack depth" risk. This is the one test that exercises
        // ContractDateTransitionQueueable.execute() for real end-to-end.
        Account acc = getAccount();
        // Deliberately not month-aligned (15th, 6-month term -> a raw
        // StartDate + Term - 1 day formula lands mid-month) so this also
        // proves queueAfterUpdate's target end date is normalized for real.
        Date midMonthStart = Date.newInstance(2026, 3, 15);
        Contract contract = TestDataFactory.createContract(acc.Id, midMonthStart, 6);
        contract = [SELECT Id, StartDate, EndDate FROM Contract WHERE Id = :contract.Id];

        Date newStart = Date.newInstance(2026, 4, 10); // raw target would be 2026-10-09
        Date expectedEnd = Date.newInstance(2026, 10, 31);

        Test.startTest();
        contract.StartDate = newStart;
        update contract;
        Test.stopTest();

        Contract updatedContract = [SELECT Id, StartDate, EndDate FROM Contract WHERE Id = :contract.Id];
        System.assertEquals(expectedEnd, updatedContract.EndDate,
            'The real trigger -> queueable chain should still correctly extend the contract end date (normalized to month-end) when there are no orders to cascade to.');
    }

    @isTest
    static void handleAfterUpdate_nonStartDateChange_leavesDatesUntouched() {
        Account acc = getAccount();
        Contract contract = TestDataFactory.createContract(acc.Id, BASE_START, TERM_MONTHS);
        contract = [SELECT Id, StartDate, EndDate, Description FROM Contract WHERE Id = :contract.Id];
        Date originalEndDate = contract.EndDate;

        Test.startTest();
        contract.Description = 'Unrelated update';
        update contract;
        Test.stopTest();

        Contract unchangedContract = [SELECT Id, StartDate, EndDate FROM Contract WHERE Id = :contract.Id];
        System.assertEquals(BASE_START, unchangedContract.StartDate, 'StartDate should be untouched.');
        System.assertEquals(originalEndDate, unchangedContract.EndDate, 'EndDate should be untouched when StartDate does not change.');
    }

    @isTest
    static void finalizeDates_directlySyncsOrdersAndResetsBypassFlag() {
        Account acc = getAccount();

        Contract contract = TestDataFactory.createContract(acc.Id, BASE_START, TERM_MONTHS);
        contract = [SELECT Id, StartDate, EndDate FROM Contract WHERE Id = :contract.Id];
        Order ord = TestDataFactory.createOrder(acc.Id, contract.Id, contract.StartDate, contract.EndDate);

        update new Contract(Id = contract.Id, Bypass_Contract_Dates_Flow__c = true);

        // finalizeDates assumes the contract's own EndDate has already been
        // synced by the caller (before-update, or the bridge/cascade phases);
        // it just needs to match what's already committed on the contract.
        Date targetEnd = contract.EndDate;
        Map<Id, Date> targetEndDates = new Map<Id, Date>{ contract.Id => targetEnd };

        Test.startTest();
        ContractTriggerHandler.finalizeDates(
            new List<Contract>{ new Contract(Id = contract.Id, StartDate = contract.StartDate) },
            targetEndDates
        );
        Test.stopTest();

        Contract finalizedContract = [SELECT Id, EndDate, Bypass_Contract_Dates_Flow__c FROM Contract WHERE Id = :contract.Id];
        Order finalizedOrder = [SELECT Id, EffectiveDate, EndDate FROM Order WHERE Id = :ord.Id];

        System.assertEquals(targetEnd, finalizedContract.EndDate, 'finalizeDates should stamp the contract with the final target end date.');
        System.assertEquals(false, finalizedContract.Bypass_Contract_Dates_Flow__c, 'finalizeDates should clear the bypass flag.');
        System.assertEquals(contract.StartDate, finalizedOrder.EffectiveDate, 'finalizeDates should sync the order effective date.');
        System.assertEquals(targetEnd, finalizedOrder.EndDate, 'finalizeDates should sync the order end date to the final target.');
    }
}