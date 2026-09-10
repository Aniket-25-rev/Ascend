/**
 * QuoteRampUpliftHandler
 *
 * PURPOSE:
 * When Annual_Increase__c changes on a Quote, reset all Year 2+ ramp
 * QuoteLineItem UnitPrice to Year 1's NetUnitPrice so the
 * QuoteLineItem before trigger recalculates correctly with new %.
 */
public class QuoteRampUpliftHandler {

    // =========================================================
    // ENTRY POINT — called from trigger
    // Detects which quotes had Annual_Increase__c changed
    // =========================================================
    public static void handleAfterUpdate(
        List<Quote> newQuotes,
        Map<Id, Quote> oldMap
    ) {
        Set<Id> changedQuoteIds = getChangedQuoteIds(newQuotes, oldMap);

        if (changedQuoteIds.isEmpty()) {
            System.debug('==QuoteRampUplift== No Annual_Increase__c changes — skipping');
            return;
        }

        resetRampLinePrices(changedQuoteIds);
    }

    // =========================================================
    // DETECT CHANGED QUOTES
    // Returns Quote IDs where Annual_Increase__c changed
    // =========================================================
    private static Set<Id> getChangedQuoteIds(
        List<Quote> newQuotes,
        Map<Id, Quote> oldMap
    ) {
        Set<Id> changedIds = new Set<Id>();

        for (Quote q : newQuotes) {
            Quote oldQ = oldMap.get(q.Id);

            if (q.Annual_Increase__c != oldQ.Annual_Increase__c) {
                changedIds.add(q.Id);
                System.debug('==QuoteRampUplift== Annual_Increase__c changed: '
                    + 'QuoteId=' + q.Id
                    + ' Old=' + oldQ.Annual_Increase__c
                    + ' New=' + q.Annual_Increase__c);
            }
        }

        return changedIds;
    }

    // =========================================================
    // RESET RAMP LINE PRICES
    // Sets all Year 2+ UnitPrice = Year 1 NetUnitPrice
    // so QLineItem before trigger recalculates from clean base
    // =========================================================
    public static void resetRampLinePrices(Set<Id> quoteIds) {
        try {

            // Query ALL ramp lines including Year 1
            List<QuoteLineItem> allRampLines = [
                SELECT Id,
                       QuoteId,
                       Product2.Name,
                       RampIdentifier,
                       SegmentName,
                       UnitPrice,
                       NetUnitPrice
                FROM   QuoteLineItem
                WHERE  QuoteId IN :quoteIds
                AND    RampIdentifier != null
                ORDER  BY QuoteId, RampIdentifier, SegmentName ASC
            ];

            if (allRampLines.isEmpty()) {
                System.debug('==QuoteRampUplift== No ramp lines found — skipping');
                return;
            }

            // Build Map: RampIdentifier → Year 1 NetUnitPrice
            Map<String, Decimal> rampToYear1Net = new Map<String, Decimal>();

            for (QuoteLineItem qli : allRampLines) {
                if (qli.SegmentName != 'Year 1') continue;
                if (String.isBlank(qli.RampIdentifier)) continue;
                if (qli.NetUnitPrice == null || qli.NetUnitPrice == 0) continue;

                rampToYear1Net.put(qli.RampIdentifier, qli.NetUnitPrice);

                System.debug('==QuoteRampUplift== Year1 Base: RampId='
                    + qli.RampIdentifier
                    + ' Product=' + qli.Product2?.Name
                    + ' NetUnitPrice=' + qli.NetUnitPrice);
            }

            if (rampToYear1Net.isEmpty()) {
                System.debug('==QuoteRampUplift== No Year 1 net prices found — skipping');
                return;
            }

            // Reset all Year 2+ UnitPrice = Year 1 NetUnitPrice
            List<QuoteLineItem> toUpdate = new List<QuoteLineItem>();

            for (QuoteLineItem qli : allRampLines) {
                if (qli.SegmentName == 'Year 1') continue;

                Decimal year1Net = rampToYear1Net.get(qli.RampIdentifier);
                if (year1Net == null) continue;

                System.debug('==QuoteRampUplift== Resetting: Product=' + qli.Product2?.Name
                    + ' Segment=' + qli.SegmentName
                    + ' OldUnitPrice=' + qli.UnitPrice
                    + ' ResetTo=' + year1Net);

                toUpdate.add(new QuoteLineItem(
                    Id        = qli.Id,
                    UnitPrice = year1Net
                ));
            }

            if (!toUpdate.isEmpty()) {
                RampUpliftTriggerHelper.isRunning = false;
                update toUpdate;
                System.debug('==QuoteRampUplift== Reset complete — '
                    + toUpdate.size() + ' lines updated');
            }

        } catch (Exception e) {
            System.debug('==QuoteRampUpliftHandler EXCEPTION== ' + e.getMessage());
            System.debug('==QuoteRampUpliftHandler STACK==     ' + e.getStackTraceString());
        }
    }
}