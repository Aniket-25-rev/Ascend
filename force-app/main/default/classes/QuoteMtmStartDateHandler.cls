// Test Class: QuoteMtmStartDateHandlerTest
//
// Month-to-Month AMENDMENT quotes: Quote.StartDate must equal the linked
// Contract's EndDate. Runs BEFORE UPDATE on Quote so it applies on every
// header save — the Amend flow's own update (which sets Month_to_Month__c),
// Revenue Cloud's header write at the end of each pricing pass, and any
// manual edit — and can never be overwritten by a later header write.
//
// The pricing pre-hook (JTLPreHook) already aligns every quote LINE to the
// same date during the pricing pass. Writing the header attribute through
// the transaction context from the pre-hook was accepted by the platform
// but never persisted to Quote.StartDate, hence this trigger-side rule.
public without sharing class QuoteMtmStartDateHandler {

    public static void beforeUpdate(List<Quote> newQuotes) {
        Set<Id> contractIds = new Set<Id>();
        for (Quote q : newQuotes) {
            if (isMtmAmend(q)) contractIds.add(q.ContractId);
        }
        if (contractIds.isEmpty()) return;

        Map<Id, Date> contractEndDates = new Map<Id, Date>();
        for (Contract c : [SELECT Id, EndDate FROM Contract WHERE Id IN :contractIds]) {
            contractEndDates.put(c.Id, c.EndDate);
        }
        applyContractEndDate(newQuotes, contractEndDates);
    }

    // Pure logic — mutates the in-memory (Trigger.new) records, returns how many changed.
    @TestVisible
    private static Integer applyContractEndDate(List<Quote> quotes, Map<Id, Date> contractEndDates) {
        Integer changed = 0;
        for (Quote q : quotes) {
            if (!isMtmAmend(q)) continue;
            Date target = contractEndDates.get(q.ContractId);
            if (target == null) continue;               // no contract end date → rule not applied
            if (q.StartDate == target) continue;
            q.StartDate = target;
            changed++;
        }
        return changed;
    }

    @TestVisible
    private static Boolean isMtmAmend(Quote q) {
        return q != null
            && 'Amend'.equalsIgnoreCase(q.OriginalActionType)
            && q.Month_to_Month__c == true
            && q.ContractId != null;
    }
}