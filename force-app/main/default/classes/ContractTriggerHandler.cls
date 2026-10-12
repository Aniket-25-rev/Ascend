public without sharing class ContractTriggerHandler {
    public static Boolean bypassEndDateNormalization = false;
    public static Map<String, Date> realStartDatesMap = new Map<String, Date>();

    public static void handleBeforeUpdate(List<Contract> contracts, Map<Id, Contract> oldContracts) {
        if (bypassEndDateNormalization) {
            return;
        }

        for (Contract contract : contracts) {
            Contract oldContract = oldContracts.get(contract.Id);
            if (oldContract == null || contract.StartDate == oldContract.StartDate ||
                contract.StartDate == null || contract.ContractTerm == null) {
                continue;
            }

            Date expectedEndDate = normalizeToMonthEnd(contract.StartDate
                .addMonths(contract.ContractTerm)
                .addDays(-1));
            if (oldContract.EndDate == null || expectedEndDate >= oldContract.EndDate) {
                contract.EndDate = expectedEndDate;
            }
            if (oldContract.StartDate < contract.StartDate) {
                // Capture the NEW start date BEFORE reverting, so the forward
                // delta survives into the async sync. The revert protects the
                // Contract Dates Flow from seeing a forward start change.
                realStartDatesMap.put(contract.Id, contract.StartDate);
                contract.StartDate = oldContract.StartDate;
            }
        }
    }

    public static void queueAfterUpdate(List<Contract> contracts, Map<Id, Contract> oldContracts) {
        if (bypassEndDateNormalization) {
            return;
        }

        Map<Id, Date> oldStartDates = new Map<Id, Date>();
        Map<Id, Date> targetEndDates = new Map<Id, Date>();
        Map<Id, Date> realNewStartDates = new Map<Id, Date>();
        for (Contract contract : contracts) {
            Contract oldContract = oldContracts.get(contract.Id);
            if (oldContract == null || contract.StartDate == null || contract.ContractTerm == null) {
                continue;
            }

            // A forward move was reverted in before-update, so the start date
            // looks unchanged here. Detect it via the map so the queueable is
            // enqueued for BOTH directions.
            Boolean startChanged = contract.StartDate != oldContract.StartDate
                || realStartDatesMap.containsKey(contract.Id);
            if (!startChanged) {
                continue;
            }

            oldStartDates.put(contract.Id, oldContract.StartDate);

            // Compute the target end from the REAL new start date (for forward
            // moves the persisted start is the reverted old one).
            Date effectiveStartDate = realStartDatesMap.containsKey(contract.Id)
                ? realStartDatesMap.get(contract.Id)
                : contract.StartDate;
            targetEndDates.put(
                contract.Id,
                normalizeToMonthEnd(effectiveStartDate.addMonths(oldContract.ContractTerm).addDays(-1))
            );

            // Carry the real (un-reverted) new start date into the async job.
            if (realStartDatesMap.containsKey(contract.Id)) {
                realNewStartDates.put(contract.Id, realStartDatesMap.get(contract.Id));
            }
        }
        if (!oldStartDates.isEmpty()) {
            System.enqueueJob(new ContractDateTransitionQueueable(
                oldStartDates,
                targetEndDates,
                realNewStartDates,
                false,
                false,
                0
            ));
        }
    }

    /**
     * Temporarily expands each order to the union of its before/after window
     * so that moving the order items/groups to their final dates can never
     * violate the cross-record validation rules:
     *   - order start can't be later than any item start
     *   - item end can't be later than order end
     *   - order end can't be later than its contract's end date
     *
     * The contract is expanded FIRST (see expandContractsForTransition) and
     * persisted with Bypass_Contract_Dates_Flow__c = true, so the order's
     * expanded end (max of before/after) is always <= the contract's expanded
     * end. The order is contracted back to its final dates in finalizeDates.
     */
    public static void expandOrdersForTransition(
        List<Order> orders,
        Map<Id, Date> oldOrderStarts,
        Map<Id, Date> oldOrderEnds,
        Map<Id, Date> newOrderStarts,
        Map<Id, Date> newOrderEnds
    ) {
        for (Order order : orders) {
            Date oldStart = oldOrderStarts.get(order.Id);
            Date oldEnd   = oldOrderEnds.get(order.Id);
            Date newStart = newOrderStarts.get(order.Id);
            Date newEnd   = newOrderEnds.get(order.Id);

            // Earliest of before/after start.
            if (oldStart != null && newStart != null) {
                order.EffectiveDate = oldStart <= newStart ? oldStart : newStart;
            } else if (newStart != null) {
                order.EffectiveDate = newStart;
            }

            // Latest of before/after end.
            if (oldEnd != null && newEnd != null) {
                order.EndDate = oldEnd >= newEnd ? oldEnd : newEnd;
            } else if (newEnd != null) {
                order.EndDate = newEnd;
            }
        }
    }

    /**
     * Temporarily expands each contract to the union of its before/after end
     * window and persists it with Bypass_Contract_Dates_Flow__c = true so the
     * Contract Dates Flow cannot recalculate (and reset) the end date while
     * the order/items are being moved.
     *
     * The contract start is already at its minimum (the before-update revert
     * keeps the old start for forward moves; backward moves persist the new
     * earlier start), so only the END needs expanding here.
     */
    public static void expandContractsForTransition(
        List<Contract> contracts,
        Map<Id, Date> oldContractEnds,
        Map<Id, Date> newContractEnds
    ) {
        List<Contract> contractsToExpand = new List<Contract>();
        for (Contract contract : contracts) {
            Date oldEnd = oldContractEnds.get(contract.Id);
            Date newEnd = newContractEnds.get(contract.Id);
            Date expandedEnd = null;
            if (oldEnd != null && newEnd != null) {
                expandedEnd = oldEnd >= newEnd ? oldEnd : newEnd;
            } else if (newEnd != null) {
                expandedEnd = newEnd;
            } else if (oldEnd != null) {
                expandedEnd = oldEnd;
            }
            if (expandedEnd != null) {
                contractsToExpand.add(new Contract(
                    Id = contract.Id,
                    EndDate = normalizeToMonthEnd(expandedEnd),
                    Bypass_Contract_Dates_Flow__c = true
                ));
            }
        }
        if (!contractsToExpand.isEmpty()) {
            update contractsToExpand;
        }
    }

    public static void handleAfterUpdate(
        List<Contract> contracts,
        Map<Id, Contract> oldContracts,
        Map<Id, Date> targetEndDates,
        Map<Id, Date> realNewStartDates,
        Boolean bridgeComplete
    ) {
        Map<Id, Contract> changedContracts = new Map<Id, Contract>();
        Map<Id, Integer> startDateDeltas = new Map<Id, Integer>();
        Map<Id, Date> persistedContractEndDates = new Map<Id, Date>();

        for (Contract contract : contracts) {
            Contract oldContract = oldContracts.get(contract.Id);
            if (oldContract == null) {
                continue;
            }

            // For a forward move the persisted start equals the old start
            // (reverted in before-update), so also treat contracts present in
            // realNewStartDates as changed.
            Boolean startChanged = contract.StartDate != oldContract.StartDate
                || realNewStartDates.containsKey(contract.Id);
            if (!startChanged) {
                continue;
            }

            changedContracts.put(contract.Id, contract);
            persistedContractEndDates.put(contract.Id, contract.EndDate);
            contract.EndDate = targetEndDates.get(contract.Id);
            Date startDate = realNewStartDates.get(contract.Id) != null
                ? realNewStartDates.get(contract.Id)
                : contract.StartDate;
            if (contract.StartDate != null && oldContract.StartDate != null) {
                startDateDeltas.put(
                    contract.Id,
                    oldContract.StartDate.daysBetween(startDate)
                );
            }
        }

        if (changedContracts.isEmpty()) {
            return;
        }

        // FOR UPDATE: lock the orders for the duration of this transaction so
        // concurrent chains (other queueables touching the same orders) block
        // instead of throwing UNABLE_TO_LOCK_ROW.
        List<Order> ordersToUpdate = [
            SELECT Id, ContractId, EffectiveDate, EndDate
            FROM Order
            WHERE ContractId IN :changedContracts.keySet()
            FOR UPDATE
        ];
        if (ordersToUpdate.isEmpty()) {
            List<Contract> contractsToUpdate = changedContracts.values();
            normalizeContractEndDates(contractsToUpdate);
            update contractsToUpdate;
            return;
        }

        // ---- Compute the FINAL order dates first (needed for the expansion).
        Map<Id, Date> newOrderStartByOrderId = new Map<Id, Date>();
        Map<Id, Date> newOrderEndByOrderId = new Map<Id, Date>();
        Map<Id, Date> oldOrderStartByOrderId = new Map<Id, Date>();
        Map<Id, Date> oldOrderEndByOrderId = new Map<Id, Date>();
        Map<Id, Date> oldContractEndByContractId = new Map<Id, Date>();
        for (Order order : ordersToUpdate) {
            Contract contract = changedContracts.get(order.ContractId);
            oldOrderStartByOrderId.put(order.Id, order.EffectiveDate);
            oldOrderEndByOrderId.put(order.Id, order.EndDate);
            newOrderStartByOrderId.put(
                order.Id,
                realNewStartDates.get(contract.Id) != null
                    ? realNewStartDates.get(contract.Id)
                    : contract.StartDate
            );
            newOrderEndByOrderId.put(order.Id, targetEndDates.get(contract.Id));
            oldContractEndByContractId.put(contract.Id, contract.EndDate);
        }

        // ---- Bridge: if an order's CURRENT end is later than the target
        // contract end, the contract end must be temporarily extended to the
        // order's end (the max) so "order end can't be later than contract
        // end" holds while the order is still at its old (later) end. The
        // order end is contracted back to the target in finalizeDates.
        Map<Id, Date> bridgeEndDatesByContract = new Map<Id, Date>();
        for (Order order : ordersToUpdate) {
            Contract contract = changedContracts.get(order.ContractId);
            Date targetEndDate = targetEndDates.get(contract.Id);
            if (targetEndDate != null && order.EndDate != null &&
                order.EndDate > targetEndDate &&
                (!bridgeEndDatesByContract.containsKey(contract.Id) ||
                 order.EndDate > bridgeEndDatesByContract.get(contract.Id))) {
                bridgeEndDatesByContract.put(contract.Id, order.EndDate);
            }
        }
        if (!bridgeComplete && !bridgeEndDatesByContract.isEmpty()) {
            List<Contract> contractsForBridge = new List<Contract>();
            for (Id contractId : bridgeEndDatesByContract.keySet()) {
                contractsForBridge.add(new Contract(
                    Id = contractId,
                    EndDate = bridgeEndDatesByContract.get(contractId)
                ));
            }
            normalizeContractEndDates(contractsForBridge);
            bypassEndDateNormalization = true;
            try {
                update contractsForBridge;
            } finally {
                bypassEndDateNormalization = false;
            }
            Map<Id, Date> oldStartDates = new Map<Id, Date>();
            for (Contract contract : contracts) {
                oldStartDates.put(contract.Id, oldContracts.get(contract.Id).StartDate);
            }
            System.enqueueJob(new ContractDateTransitionQueueable(
                oldStartDates,
                targetEndDates,
                realNewStartDates,
                true,
                false,
                0
            ));
            return;
        }

        if (bridgeComplete && !bridgeEndDatesByContract.isEmpty()) {
            List<Contract> contractsForBridge = new List<Contract>();
            for (Id contractId : bridgeEndDatesByContract.keySet()) {
                if (persistedContractEndDates.get(contractId) == null ||
                    persistedContractEndDates.get(contractId) <
                    bridgeEndDatesByContract.get(contractId)) {
                    contractsForBridge.add(new Contract(
                        Id = contractId,
                        EndDate = bridgeEndDatesByContract.get(contractId),
                        Bypass_Contract_Dates_Flow__c = true
                    ));
                }
            }
            if (!contractsForBridge.isEmpty()) {
                normalizeContractEndDates(contractsForBridge);
                bypassEndDateNormalization = true;
                try {
                    update contractsForBridge;
                } finally {
                    bypassEndDateNormalization = false;
                }
            }
        }

        // ===================================================================
        // SEQUENTIAL DML - CPQ field-integrity exceptions validate against
        // the DATABASE-persisted parent value, NOT the in-memory batch value.
        // The contract must be expanded and persisted BEFORE the order, and
        // the order BEFORE the items. Five steps total:
        //   DML 1 (here):      contract -> expanded end (Bypass = true)
        //   DML 2 (here):      order    -> expanded (min start, max end)
        //   DML 3 (here):      items + groups -> final dates
        //   DML 4 (finalize):  order    -> final dates
        //   DML 5 (finalize):  contract -> final end (Bypass = false)
        // ===================================================================

        // ---- DML 1: expand the CONTRACT end to max(old, new) and persist
        // with Bypass_Contract_Dates_Flow__c = true so the flow cannot reset
        // it. The contract start is already at its minimum (reverted in
        // before-update for forward moves).
        expandContractsForTransition(
            changedContracts.values(),
            oldContractEndByContractId,
            targetEndDates
        );

        // ---- DML 2: expand the ORDER to the union window (min start, max
        // end). Valid now because the contract's expanded end (>= order's
        // expanded end) is persisted in the DB.
        expandOrdersForTransition(
            ordersToUpdate,
            oldOrderStartByOrderId,
            oldOrderEndByOrderId,
            newOrderStartByOrderId,
            newOrderEndByOrderId
        );
        update ordersToUpdate;

        Map<Id, Order> ordersById = new Map<Id, Order>(ordersToUpdate);
        Set<Id> orderIds = ordersById.keySet();
        List<OrderItem> orderItemsToUpdate = [
            SELECT Id, OrderId, OrderItemGroupId, ServiceDate, EndDate
            FROM OrderItem
            WHERE OrderId IN :orderIds
        ];
        // Ordered so groups belonging to the same order are contiguous and
        // sorted by their original start date - required for the sequential
        // chaining pass below to see each order's groups in the right sequence.
        List<OrderItemGroup> orderItemGroupsToUpdate = [
            SELECT Id, OrderId, StartDate, EndDate
            FROM OrderItemGroup
            WHERE OrderId IN :orderIds
            ORDER BY OrderId, StartDate ASC
        ];

        // Captured before anything below mutates .StartDate/.EndDate, so the
        // end date math always has the true "before" values to preserve each
        // record's original term against.
        Map<Id, Date> originalGroupStarts = new Map<Id, Date>();
        Map<Id, Date> originalGroupEnds = new Map<Id, Date>();
        for (OrderItemGroup orderItemGroup : orderItemGroupsToUpdate) {
            originalGroupStarts.put(orderItemGroup.Id, orderItemGroup.StartDate);
            originalGroupEnds.put(orderItemGroup.Id, orderItemGroup.EndDate);
        }
        Map<Id, Date> originalItemStarts = new Map<Id, Date>();
        Map<Id, Date> originalItemEnds = new Map<Id, Date>();
        for (OrderItem orderItem : orderItemsToUpdate) {
            originalItemStarts.put(orderItem.Id, orderItem.ServiceDate);
            originalItemEnds.put(orderItem.Id, orderItem.EndDate);
        }

        // Compute every group's final Start/End in one sequential pass per
        // order: the first group anchors to its own (day-shifted) start;
        // every group after that starts the day after the PREVIOUS group's
        // already-finalized end date. Its own end date is derived by
        // preserving that group's original span (in whole calendar months)
        // against whichever start date it actually ends up with - this has
        // to happen AFTER chaining decides the start, in the same pass, or a
        // chained group's end gets computed against the wrong start (the
        // group's own independently-shifted one, not its chained one).
        Map<Id, OrderItemGroup> orderItemGroupsById = new Map<Id, OrderItemGroup>();
        Id currentGroupOrderId = null;
        Date previousGroupEndDate = null;
        for (OrderItemGroup orderItemGroup : orderItemGroupsToUpdate) {
            Order order = ordersById.get(orderItemGroup.OrderId);
            Contract contract = changedContracts.get(order.ContractId);
            Integer startDateDelta = startDateDeltas.get(order.ContractId);
            Date originalStart = originalGroupStarts.get(orderItemGroup.Id);
            Date originalEnd = originalGroupEnds.get(orderItemGroup.Id);

            if (orderItemGroup.OrderId != currentGroupOrderId) {
                currentGroupOrderId = orderItemGroup.OrderId;
                previousGroupEndDate = null;
            }

            Date newStart = previousGroupEndDate != null
                ? previousGroupEndDate.addDays(1)
                : adjustedDate(originalStart, startDateDelta, contract.StartDate, contract.EndDate);
            if (contract.StartDate != null && (newStart == null || newStart < contract.StartDate)) {
                newStart = contract.StartDate;
            }

            Date newEnd = shiftEndDatePreservingTerm(originalStart, originalEnd, newStart);
            if (contract.EndDate != null && newEnd != null && newEnd > contract.EndDate) {
                newEnd = contract.EndDate;
            }
            newEnd = matchOrderEndDateIfOneDayBefore(newEnd, contract.EndDate);

            orderItemGroup.StartDate = newStart;
            orderItemGroup.EndDate = newEnd;
            orderItemGroupsById.put(orderItemGroup.Id, orderItemGroup);

            previousGroupEndDate = newEnd;
        }

        // ---- Invariant: a group's StartDate and EndDate must never be the
        // same. If the date math collapsed them (e.g. a one-time group, or a
        // start clamped onto the contract's last day), push the end to the
        // next month-end so the group spans at least one full month. This runs
        // BEFORE the item loop so grouped items inherit valid dates.
        for (OrderItemGroup orderItemGroup : orderItemGroupsToUpdate) {
            if (orderItemGroup.StartDate != null && orderItemGroup.EndDate != null &&
                orderItemGroup.StartDate == orderItemGroup.EndDate) {
                orderItemGroup.EndDate = normalizeToMonthEnd(
                    orderItemGroup.StartDate.addMonths(1)
                );
            }
        }

        // Compute every item's final dates. The item end is clamped to the
        // EXPANDED order end (the safe upper bound), so "item end can't be
        // later than order end" can never fire during the transition.
        for (OrderItem orderItem : orderItemsToUpdate) {
            Order order = ordersById.get(orderItem.OrderId);
            Contract contract = changedContracts.get(order.ContractId);
            Integer startDateDelta = startDateDeltas.get(order.ContractId);
            OrderItemGroup orderItemGroup = orderItemGroupsById.get(orderItem.OrderItemGroupId);

            if (orderItemGroup != null) {
                orderItem.ServiceDate = orderItemGroup.StartDate;
                if (contract.StartDate != null &&
                    (orderItem.ServiceDate == null ||
                     orderItem.ServiceDate < contract.StartDate)) {
                    orderItem.ServiceDate = contract.StartDate;
                }
                if (orderItem.EndDate != null) {
                    orderItem.EndDate = orderItemGroup.EndDate;
                }
            } else {
                orderItem.ServiceDate = adjustedDate(
                    orderItem.ServiceDate,
                    startDateDelta,
                    contract.StartDate,
                    contract.EndDate
                );
                if (contract.StartDate != null &&
                    (orderItem.ServiceDate == null ||
                     orderItem.ServiceDate < contract.StartDate)) {
                    orderItem.ServiceDate = contract.StartDate;
                }
                if (orderItem.EndDate != null) {
                    orderItem.EndDate = shiftEndDatePreservingTerm(
                        originalItemStarts.get(orderItem.Id),
                        originalItemEnds.get(orderItem.Id),
                        orderItem.ServiceDate
                    );
                    if (contract.EndDate != null && orderItem.EndDate != null &&
                        orderItem.EndDate > contract.EndDate) {
                        orderItem.EndDate = contract.EndDate;
                    }
                    orderItem.EndDate = matchOrderEndDateIfOneDayBefore(
                        orderItem.EndDate,
                        contract.EndDate
                    );
                }
            }

            // Clamp the item's end to the expanded order end (tightest bound).
            if (order.EndDate != null && orderItem.EndDate != null &&
                orderItem.EndDate > order.EndDate) {
                orderItem.EndDate = order.EndDate;
            }
        }

        // ---- Invariant: an item's ServiceDate and EndDate must never be the
        // same. If the date math collapsed them, push the end to the next
        // month-end so the item spans at least one full month.
        for (OrderItem orderItem : orderItemsToUpdate) {
            if (orderItem.ServiceDate != null && orderItem.EndDate != null &&
                orderItem.ServiceDate == orderItem.EndDate) {
                orderItem.EndDate = normalizeToMonthEnd(
                    orderItem.ServiceDate.addMonths(1)
                );
            }
        }

        // ---- DML 3: move items + groups to their final dates. Valid now
        // because the order's expanded end (>= final item end) is persisted.
        if (!orderItemsToUpdate.isEmpty()) {
            update orderItemsToUpdate;
        }
        if (!orderItemGroupsToUpdate.isEmpty()) {
            update orderItemGroupsToUpdate;
        }

        Map<Id, Date> oldStartDates = new Map<Id, Date>();
        for (Contract contract : contracts) {
            oldStartDates.put(contract.Id, oldContracts.get(contract.Id).StartDate);
        }
        System.enqueueJob(new ContractDateTransitionQueueable(
            oldStartDates,
            targetEndDates,
            realNewStartDates,
            true,
            true,
            0
        ));
    }

    /**
     * Preserves a record's original span, in whole calendar months, against
     * a new start date - the same relationship Contract.EndDate has to
     * Contract.StartDate + ContractTerm, just derived from the record's own
     * prior start/end instead of an explicit term field.
     *
     * Because normalizeToMonthEnd only cares about the END month (never the
     * exact day), a start date of the 1st "eats" one fewer month than a
     * start date later in the month before landing in the same end month
     * (StartDate.addMonths(T).addDays(-1) lands in the month BEFORE
     * StartDate+T when StartDate's day is 1, but stays IN that month
     * otherwise - see the day==1 correction below). That's why a contract
     * starting 2026-08-01 with a 36-month term ends 2029-07-31 (July) while
     * the same term starting 2026-08-05 ends 2029-08-31 (August). Preserving
     * a record's span under a new start date has to account for the same
     * effect, or the result can land a full month off from what a fresh
     * StartDate+Term calculation would produce.
     */
    private static Date shiftEndDatePreservingTerm(Date originalStartDate, Date originalEndDate, Date newStartDate) {
        if (originalStartDate == null || originalEndDate == null || newStartDate == null) {
            return originalEndDate;
        }
        Integer monthIndexDelta = monthIndex(newStartDate) - monthIndex(originalStartDate);
        Integer dayOneCorrection = (originalStartDate.day() == 1 ? 1 : 0) - (newStartDate.day() == 1 ? 1 : 0);
        Date firstOfOriginalEndMonth = Date.newInstance(originalEndDate.year(), originalEndDate.month(), 1);
        Date firstOfNewEndMonth = firstOfOriginalEndMonth.addMonths(monthIndexDelta + dayOneCorrection);
        return firstOfNewEndMonth.addMonths(1).addDays(-1);
    }

    private static Integer monthIndex(Date d) {
        return d.year() * 12 + d.month();
    }

    public static void finalizeDates(
        List<Contract> contracts,
        Map<Id, Date> targetEndDates,
        Map<Id, Date> realNewStartDates
    ) {
        Map<Id, Contract> contractsById = new Map<Id, Contract>(contracts);
        // FOR UPDATE: lock the orders so concurrent chains serialize here too.
        List<Order> ordersToUpdate = [
            SELECT Id, ContractId, EffectiveDate, EndDate
            FROM Order
            WHERE ContractId IN :contractsById.keySet()
            FOR UPDATE
        ];

        // ---- DML 4: contract the order back to its FINAL dates. The
        // items/groups are already at their final dates (moved in
        // handleAfterUpdate), so both cross-record rules hold here.
        Map<Id, Date> earliestItemStartByOrder = new Map<Id, Date>();
        if (!ordersToUpdate.isEmpty()) {
            Set<Id> orderIds = new Set<Id>();
            for (Order order : ordersToUpdate) {
                orderIds.add(order.Id);
            }
            for (OrderItem item : [
                SELECT OrderId, ServiceDate
                FROM OrderItem
                WHERE OrderId IN :orderIds AND ServiceDate != null
            ]) {
                Date earliest = earliestItemStartByOrder.get(item.OrderId);
                if (earliest == null || item.ServiceDate < earliest) {
                    earliestItemStartByOrder.put(item.OrderId, item.ServiceDate);
                }
            }
        }

        for (Order order : ordersToUpdate) {
            Contract contract = contractsById.get(order.ContractId);
            // Use the real new start date for forward moves so the order start
            // doesn't snap back to the reverted (old) contract start.
            order.EffectiveDate = realNewStartDates.get(contract.Id) != null
                ? realNewStartDates.get(contract.Id)
                : contract.StartDate;
            // Defensive: the order start can never be later than the earliest
            // item start (validation rule).
            Date earliestItemStart = earliestItemStartByOrder.get(order.Id);
            if (earliestItemStart != null && order.EffectiveDate > earliestItemStart) {
                order.EffectiveDate = earliestItemStart;
            }
            order.EndDate = targetEndDates.get(contract.Id);
        }
        if (!ordersToUpdate.isEmpty()) {
            update ordersToUpdate;
        }

        // ---- DML 5: contract the CONTRACT to its final end date and clear
        // the bypass flag so the flow resumes normal behavior.
        for (Contract contract : contracts) {
            contract.EndDate = normalizeToMonthEnd(targetEndDates.get(contract.Id));
            contract.Bypass_Contract_Dates_Flow__c = false;
            System.Debug('NORMALIZED CONTRACT END DATE: ' + contract.EndDate);
        }
        update contracts;

        List<String> orderIdsToReprice = new List<String>();
        for (Order order : ordersToUpdate) {
            orderIdsToReprice.add(String.valueOf(order.Id));
        }
        if (!orderIdsToReprice.isEmpty()) {
            RepriceOrdersUtility.repriceOrders(orderIdsToReprice);
        }
    }

    private static Date adjustedDate(
        Date currentDate,
        Integer startDateDelta,
        Date contractStartDate,
        Date contractEndDate
    ) {
        if (currentDate == null) {
            return null;
        }

        Date adjustedDate = startDateDelta == null
            ? currentDate
            : currentDate.addDays(startDateDelta);

        if (contractStartDate != null && adjustedDate < contractStartDate) {
            adjustedDate = contractStartDate;
        }
        if (contractEndDate != null && adjustedDate > contractEndDate) {
            adjustedDate = contractEndDate;
        }
        return adjustedDate;
    }

    /**
     * The last step of every OrderItemGroup/OrderItem end date computation in
     * this class: snap to the order's end date if only a day off, then
     * normalize to month-end (contract.EndDate, passed in as orderEndDate
     * here, is already month-end by the time this runs, so snapping never
     * fights the normalization below).
     */
    private static Date matchOrderEndDateIfOneDayBefore(
        Date childEndDate,
        Date orderEndDate
    ) {
        Date resolvedEndDate = childEndDate;
        if (childEndDate != null && orderEndDate != null &&
            childEndDate.addDays(1) == orderEndDate) {
            resolvedEndDate = orderEndDate;
        }
        return normalizeToMonthEnd(resolvedEndDate);
    }

    /**
     * Contract, OrderItemGroup, and OrderItem end dates must always land on
     * the last day of their calendar month. Rounding up (never down) means a
     * date is only ever pushed later within its own month, never pulled back
     * into an earlier month.
     */
    private static Date normalizeToMonthEnd(Date d) {
        if (d == null) {
            return null;
        }
        return Date.newInstance(d.year(), d.month(), 1).addMonths(1).addDays(-1);
    }

    private static void normalizeContractEndDates(List<Contract> contractsToNormalize) {
        for (Contract contract : contractsToNormalize) {
            contract.EndDate = normalizeToMonthEnd(contract.EndDate);
        }
    }
}