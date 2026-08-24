public class UpdateOrderProductEndDate {

    public class Request {
        @InvocableVariable(required=true)
        public Id contractId;
        @InvocableVariable(required=false)
        public Date newEndDate;
        @InvocableVariable(required=false)
        public Date newStartDate;
    }

    @InvocableMethod(
        label       = 'Update Order Product End Dates from Contract'
        description = 'Cascades Contract date changes to related Orders and OrderItems.'
    )
    public static void execute(List<Request> requests) {
        Map<Id, Date> contractToEndDate   = new Map<Id, Date>();
        Map<Id, Date> contractToStartDate = new Map<Id, Date>();

        Set<Id> needsDates = new Set<Id>();
        for (Request req : requests) {
            if (req.newEndDate == null || req.newStartDate == null)
                needsDates.add(req.contractId);
        }
        Map<Id, Contract> contractMap = new Map<Id, Contract>();
        if (!needsDates.isEmpty()) {
            for (Contract c : [SELECT Id, StartDate, EndDate FROM Contract WHERE Id IN :needsDates])
                contractMap.put(c.Id, c);
        }
        for (Request req : requests) {
            Date endDate   = req.newEndDate;
            Date startDate = req.newStartDate;
            if ((endDate == null || startDate == null) && contractMap.containsKey(req.contractId)) {
                Contract c = contractMap.get(req.contractId);
                if (endDate   == null) endDate   = c.EndDate;
                if (startDate == null) startDate = c.StartDate;
            }
            contractToEndDate.put(req.contractId, endDate);
            contractToStartDate.put(req.contractId, startDate);
        }
        processContracts(contractToEndDate, contractToStartDate);
    }

    // =========================================================
    // CORE LOGIC — runs synchronously in the AfterSave transaction.
    //
    // Per-order sequence:
    //   Step A  raise Order.EndDate ceiling (V14 flow may already do this)
    //   Step B  update OrderItem.ServiceDate + EndDate  ← primary goal
    //   Step C  update Order.EffectiveDate
    //
    // RCA Instant Pricing recalculates EndDate from PricingTermCount when
    // any OrderItem field is written. To prevent it from overriding our new
    // EndDate, we also write the correctly-derived decimal PricingTermCount.
    //
    // OneTime products must never have EndDate set (platform rule).
    // =========================================================
    @TestVisible
    private static void processContracts(
        Map<Id, Date> contractToEndDate,
        Map<Id, Date> contractToStartDate
    ) {
        List<Order> orders = [
            SELECT Id, Status, ContractId, EffectiveDate, EndDate
            FROM   Order
            WHERE  ContractId IN :contractToEndDate.keySet()
            AND    Status IN ('Activated', 'Draft')
        ];
        if (orders.isEmpty()) return;

        List<Id>      activatedOrderIds    = new List<Id>();
        List<Order>   toDeactivate         = new List<Order>();
        List<Id>      allOrderIds          = new List<Id>();
        Map<Id, Id>   orderToContract      = new Map<Id, Id>();
        Map<Id, Date> currentEffectiveDate = new Map<Id, Date>();
        Map<Id, Date> currentEndDate       = new Map<Id, Date>();

        for (Order o : orders) {
            allOrderIds.add(o.Id);
            orderToContract.put(o.Id, o.ContractId);
            currentEffectiveDate.put(o.Id, o.EffectiveDate);
            currentEndDate.put(o.Id, o.EndDate);
            if (o.Status == 'Activated') {
                activatedOrderIds.add(o.Id);
                toDeactivate.add(new Order(Id = o.Id, Status = 'Draft'));
            }
        }
        if (!toDeactivate.isEmpty()) {
            try { update toDeactivate; }
            catch (DmlException e) {
                System.debug('UpdateOrderProductEndDate: deactivate failed — ' + e.getMessage());
            }
        }

        List<OrderItem> allItems = [
            SELECT Id, ServiceDate, EndDate, PricingTermCount, OrderId, ProductSellingModelId
            FROM   OrderItem
            WHERE  OrderId IN :allOrderIds
        ];

        Map<Id, List<OrderItem>> orderIdToItems = new Map<Id, List<OrderItem>>();
        Set<Id> psmIds = new Set<Id>();
        for (OrderItem oi : allItems) {
            if (!orderIdToItems.containsKey(oi.OrderId))
                orderIdToItems.put(oi.OrderId, new List<OrderItem>());
            orderIdToItems.get(oi.OrderId).add(oi);
            if (oi.ProductSellingModelId != null) psmIds.add(oi.ProductSellingModelId);
        }

        Map<Id, String> psmTypeMap = new Map<Id, String>();
        if (!psmIds.isEmpty()) {
            for (ProductSellingModel psm : [
                SELECT Id, SellingModelType FROM ProductSellingModel WHERE Id IN :psmIds
            ]) psmTypeMap.put(psm.Id, psm.SellingModelType);
        }

        for (Id orderId : allOrderIds) {
            Id   contractId   = orderToContract.get(orderId);
            Date newEndDate   = contractToEndDate.get(contractId);
            Date newStartDate = contractToStartDate.get(contractId);

            // Step A: raise Order.EndDate ceiling (may already be set by V14 flow)
            if (newEndDate != currentEndDate.get(orderId)) {
                try { update new Order(Id = orderId, EndDate = newEndDate); }
                catch (DmlException e) {
                    System.debug('UpdateOrderProductEndDate: Step A EndDate failed orderId='
                        + orderId + ' — ' + e.getMessage());
                    // No continue — V14 may have already updated Order.EndDate in this
                    // transaction, so Step B may still succeed even if Step A fails here.
                }
            }

            // Step B: update OrderItems — primary goal.
            // PricingTermCount is set alongside EndDate so RCA Instant Pricing
            // derives the same EndDate and does not override our new value.
            List<OrderItem> orderItems = orderIdToItems.containsKey(orderId)
                ? orderIdToItems.get(orderId) : new List<OrderItem>();
            if (!orderItems.isEmpty()) {
                List<OrderItem> toUpdate = new List<OrderItem>();
                for (OrderItem oi : orderItems) {
                    String  modelType = oi.ProductSellingModelId != null
                        ? psmTypeMap.get(oi.ProductSellingModelId) : null;
                    Boolean isOneTime = 'OneTime'.equalsIgnoreCase(modelType);
                    boolean changed   = false;

                    if (oi.ServiceDate != newStartDate) {
                        oi.ServiceDate = newStartDate;
                        changed = true;
                    }
                    if (!isOneTime && oi.EndDate != newEndDate) {
                        oi.EndDate = newEndDate;
                        Date sd = (oi.ServiceDate != null) ? oi.ServiceDate : newStartDate;
                        oi.PricingTermCount = calcPTC(sd, newEndDate);
                        changed = true;
                    }
                    if (changed) toUpdate.add(oi);
                }
                if (!toUpdate.isEmpty()) {
                    Database.SaveResult[] results = Database.update(toUpdate, false);
                    for (Integer i = 0; i < results.size(); i++) {
                        if (!results[i].isSuccess()) {
                            System.debug('UpdateOrderProductEndDate: Step B item failed id='
                                + toUpdate[i].Id + ' errors='
                                + results[i].getErrors()[0].getMessage());
                        }
                    }
                }
            }

            // Step C: update Order.EffectiveDate (isolated — must not block Step B)
            if (newStartDate != currentEffectiveDate.get(orderId)) {
                try { update new Order(Id = orderId, EffectiveDate = newStartDate); }
                catch (DmlException e) {
                    System.debug('UpdateOrderProductEndDate: Step C EffectiveDate failed orderId='
                        + orderId + ' — ' + e.getMessage());
                }
            }
        }

        // Re-activate orders that were originally Activated
        List<Order> toReactivate = new List<Order>();
        for (Id oId : activatedOrderIds)
            toReactivate.add(new Order(Id = oId, Status = 'Activated'));
        if (!toReactivate.isEmpty()) {
            try { update toReactivate; }
            catch (DmlException e) {
                System.debug('UpdateOrderProductEndDate: reactivate failed — ' + e.getMessage());
            }
        }
    }

    // Calculates a decimal PricingTermCount matching Salesforce RCA's formula:
    //   fullMonths + (daysInPartialMonth / daysInThatCalendarMonth)
    // where daysInPartialMonth counts inclusively to endDate (daysBetween to endDate+1).
    // Verified against live data: serviceDate=08/13/2026, endDate=07/31/2027 → 11.612903...
    @TestVisible
    private static Decimal calcPTC(Date serviceDate, Date endDate) {
        if (serviceDate == null || endDate == null) return null;
        Integer fullMonths = serviceDate.monthsBetween(endDate);
        Date    baseDate   = serviceDate.addMonths(fullMonths);
        while (fullMonths > 0 && baseDate > endDate) {
            fullMonths--;
            baseDate = serviceDate.addMonths(fullMonths);
        }
        Integer remainDays  = baseDate.daysBetween(endDate.addDays(1));
        Date    monthStart  = Date.newInstance(baseDate.year(), baseDate.month(), 1);
        Integer daysInMonth = monthStart.daysBetween(monthStart.addMonths(1));
        return fullMonths + (Decimal) remainDays / daysInMonth;
    }
}