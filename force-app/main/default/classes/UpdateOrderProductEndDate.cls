public class UpdateOrderProductEndDate {

    /**
     
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

        // Identify which Requests are missing dates and need a Contract query
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

        // Build final date maps — explicit request values take priority over queried values
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
                // Activated Orders must be set to Draft before OrderItems can be updated
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

        // Fetch all OrderItems and group by Order for efficient per-Order processing
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

        // Map PSM ID → SellingModelType to identify OneTime products
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

            // Step A: Raise Order.EndDate ceiling.
            // This may already have been done by the V14 Update End Date flow in
            // the same transaction. A failure here is non-fatal — Step B may still
            // succeed if Order.EndDate was already raised by the other flow.
            if (newEndDate != currentEndDate.get(orderId)) {
                try { update new Order(Id = orderId, EndDate = newEndDate); }
                catch (DmlException e) {
                    System.debug('UpdateOrderProductEndDate: Step A EndDate failed orderId='
                        + orderId + ' — ' + e.getMessage());
                }
            }

            // Step B: Update OrderItems — the primary goal of this class.
            // PricingTermCount is set alongside EndDate so Revenue Cloud's
            // Instant Pricing derives the same EndDate and does not override it.
            List<OrderItem> orderItems = orderIdToItems.containsKey(orderId)
                ? orderIdToItems.get(orderId) : new List<OrderItem>();
            if (!orderItems.isEmpty()) {
                List<OrderItem> toUpdate = new List<OrderItem>();
                for (OrderItem oi : orderItems) {
                    String  modelType = oi.ProductSellingModelId != null
                        ? psmTypeMap.get(oi.ProductSellingModelId) : null;
                    Boolean isOneTime = 'OneTime'.equalsIgnoreCase(modelType);
                    boolean changed   = false;

                    // Always update ServiceDate for all product types
                    if (oi.ServiceDate != newStartDate) {
                        oi.ServiceDate = newStartDate;
                        changed = true;
                    }
                    // EndDate and PricingTermCount must not be set on OneTime items
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

            // Step C: Update Order.EffectiveDate.
            // Isolated in its own DML so a failure here does not roll back Step B.
            if (newStartDate != currentEffectiveDate.get(orderId)) {
                try { update new Order(Id = orderId, EffectiveDate = newStartDate); }
                catch (DmlException e) {
                    System.debug('UpdateOrderProductEndDate: Step C EffectiveDate failed orderId='
                        + orderId + ' — ' + e.getMessage());
                }
            }
        }

        // Re-activate Orders that were temporarily deactivated in Step 1
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

     
    @TestVisible
    private static Decimal calcPTC(Date serviceDate, Date endDate) {
        if (serviceDate == null || endDate == null) return null;
        Integer fullMonths = serviceDate.monthsBetween(endDate);
        Date    baseDate   = serviceDate.addMonths(fullMonths);
        while (fullMonths > 0 && baseDate > endDate) {
            fullMonths--;
            baseDate = serviceDate.addMonths(fullMonths);
        }
        Integer remainDays  = baseDate.daysBetween(endDate.addDays(1)); // inclusive end
        Date    monthStart  = Date.newInstance(baseDate.year(), baseDate.month(), 1);
        Integer daysInMonth = monthStart.daysBetween(monthStart.addMonths(1));
        return fullMonths + (Decimal) remainDays / daysInMonth;
    }
  */
}