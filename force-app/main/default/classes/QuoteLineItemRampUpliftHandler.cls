/**
 * QuoteLineItemRampUpliftHandler
 *
 * PURPOSE:
 * For multi-year ramp quotes, sets the UnitPrice (base/sales price) of
 * Year 2, Year 3... lines to:
 *
 *   Prior Year NetUnitPrice × (1 + Annual_Increase__c%)
 *
 * This ensures:
 * 1. Prior year's NET price is used as the new base (not list price)
 * 2. Annual increase % is applied on top of that base
 * 3. Full pricing waterfall (term discount, volume discount, manual
 *    discounts) then runs on top of this new UnitPrice
 *
 
 * "Set the previous year's NetUnitPrice as the ListPrice for Year 2+
 *  so all discounts apply on top of it correctly."
 *
 * EXAMPLE (6% Annual Increase, 4% term discount):
 * Year 1: UnitPrice=$67.00 → 4% discount → NetUnitPrice=$64.32
 * Year 2: UnitPrice=$64.32×1.06=$68.18 → 4% discount → NetUnitPrice=$65.45
 * Year 3: UnitPrice=$65.45×1.06=$69.38 → 4% discount → NetUnitPrice=$66.60
 *
 * KEY DESIGN DECISIONS:
 * 1. BEFORE trigger — sets UnitPrice before pricing procedure runs
 * 2. Uses RampIdentifier to group same product across segments
 * 3. Queries Annual_Increase__c fresh from Quote every time
 * 4. Directly modifies Trigger.new — no DML, no recursion
 */
public class QuoteLineItemRampUpliftHandler {

    // =========================================================
    // MAIN ENTRY POINT
    // Called from BEFORE trigger — modifies Trigger.new directly
    // =========================================================
    public static void handleRampUplift(
        List<QuoteLineItem> newLines,
        Map<Id, QuoteLineItem> oldMap
    ) {
        try {

            // -------------------------------------------------------
            // STEP 1: Collect Quote IDs from ramp Year 2+ lines only
            // -------------------------------------------------------
            Set<Id> relevantQuoteIds = new Set<Id>();

            for (QuoteLineItem qli : newLines) {
                if (String.isBlank(qli.RampIdentifier)) continue;
                if (qli.SegmentName == 'Year 1') continue;
                relevantQuoteIds.add(qli.QuoteId);
            }

            if (relevantQuoteIds.isEmpty()) {
                System.debug('==RampUplift== No relevant quotes — skipping');
                return;
            }

            // -------------------------------------------------------
            // STEP 2: Get Annual_Increase__c per Quote
            // -------------------------------------------------------
            Map<Id, Decimal> quoteAnnualIncreaseMap = new Map<Id, Decimal>();

            for (Quote q : [
                SELECT Id, Annual_Increase__c
                FROM   Quote
                WHERE  Id IN :relevantQuoteIds
                AND    Annual_Increase__c != null
                AND    Annual_Increase__c > 0
            ]) {
                quoteAnnualIncreaseMap.put(q.Id, q.Annual_Increase__c);
                System.debug('==RampUplift== Quote=' + q.Id
                    + ' Annual_Increase__c=' + q.Annual_Increase__c);
            }

            if (quoteAnnualIncreaseMap.isEmpty()) {
                System.debug('==RampUplift== No quotes with Annual_Increase__c > 0 — skipping');
                return;
            }

            // -------------------------------------------------------
            // STEP 3: Query ALL ramp lines from DB
            // Need Year 1 NetUnitPrice as base
            // Need Year 2+ NetUnitPrice for Year 3+ calculations
            // Order by SegmentName ASC: Year 1 → Year 2 → Year 3
            // -------------------------------------------------------
            List<QuoteLineItem> allRampLines = [
                SELECT Id,
                       QuoteId,
                       Product2.Name,
                       Product2.StockKeepingUnit,
                       RampIdentifier,
                       SegmentName,
                       NetUnitPrice,
                       UnitPrice
                FROM   QuoteLineItem
                WHERE  QuoteId IN :quoteAnnualIncreaseMap.keySet()
                AND    RampIdentifier != null
                ORDER  BY QuoteId, RampIdentifier, SegmentName ASC
            ];

            System.debug('==RampUplift== Total ramp lines from DB: ' + allRampLines.size());

            // -------------------------------------------------------
            // STEP 4: Build Map of NetUnitPrice per
            //         RampIdentifier → SegmentName → NetUnitPrice
            // -------------------------------------------------------
            Map<String, Map<String, Decimal>> rampSegmentNetMap =
                new Map<String, Map<String, Decimal>>();

            for (QuoteLineItem qli : allRampLines) {
                if (String.isBlank(qli.RampIdentifier)) continue;

                if (!rampSegmentNetMap.containsKey(qli.RampIdentifier)) {
                    rampSegmentNetMap.put(
                        qli.RampIdentifier,
                        new Map<String, Decimal>()
                    );
                }

                rampSegmentNetMap.get(qli.RampIdentifier)
                    .put(qli.SegmentName, qli.NetUnitPrice);

                System.debug('==RampUplift== DB Map: RampId=' + qli.RampIdentifier
                    + ' Product=' + qli.Product2?.Name
                    + ' Segment=' + qli.SegmentName
                    + ' NetUnitPrice=' + qli.NetUnitPrice);
            }

            // -------------------------------------------------------
            // STEP 5: For each Year 2+ line in Trigger.new
            //         Set UnitPrice = prior year NetUnitPrice
            //                       × (1 + Annual_Increase__c%)
            //
            // Directly modifies Trigger.new — no DML needed
            // Pricing procedure then applies waterfall on this base
            // -------------------------------------------------------
            for (QuoteLineItem qli : newLines) {

                // Skip non-ramp lines
                if (String.isBlank(qli.RampIdentifier)) continue;

                // Skip Year 1
                if (qli.SegmentName == 'Year 1') continue;

                // Skip if quote has no annual increase
                if (!quoteAnnualIncreaseMap.containsKey(qli.QuoteId)) continue;

                // Get prior segment name
                String priorSegment = getPriorSegmentName(qli.SegmentName);
                if (String.isBlank(priorSegment)) {
                    System.debug('==RampUplift== Cannot determine prior segment for '
                        + qli.SegmentName + ' — skipping');
                    continue;
                }

                // Get prior year NetUnitPrice
                Map<String, Decimal> segNetMap =
                    rampSegmentNetMap.get(qli.RampIdentifier);

                if (segNetMap == null) {
                    System.debug('==RampUplift== No segment map for RampId='
                        + qli.RampIdentifier + ' — skipping');
                    continue;
                }

                Decimal priorYearNet = segNetMap.get(priorSegment);

                if (priorYearNet == null || priorYearNet == 0) {
                    System.debug('==RampUplift== Prior year net is null/zero '
                        + 'RampId=' + qli.RampIdentifier
                        + ' PriorSegment=' + priorSegment + ' — skipping');
                    continue;
                }

                // Get Annual Increase % for this quote
                Decimal annualIncrease   = quoteAnnualIncreaseMap.get(qli.QuoteId);
                Decimal upliftFactor     = 1 + (annualIncrease / 100);

                // Calculate new UnitPrice
                // = Prior Year NetUnitPrice × (1 + Annual_Increase__c%)
                Decimal newUnitPrice = (priorYearNet * upliftFactor)
                    .setScale(10, RoundingMode.HALF_UP);

                System.debug('==RampUplift== Setting UnitPrice:'
                    + ' RampId=' + qli.RampIdentifier
                    + ' Product=' + qli.Product2?.Name
                    + ' Segment=' + qli.SegmentName
                    + ' PriorSegment=' + priorSegment
                    + ' PriorNet=' + priorYearNet
                    + ' AnnualIncrease=' + annualIncrease + '%'
                    + ' UpliftFactor=' + upliftFactor
                    + ' NewUnitPrice=' + newUnitPrice
                    + ' OldUnitPrice=' + qli.UnitPrice);

                // ✅ Directly modify Trigger.new — no DML needed
                // Pricing procedure uses this as the new base price
                qli.UnitPrice = newUnitPrice;
            }

        } catch (Exception e) {
            System.debug('==RampUpliftHandler EXCEPTION== ' + e.getMessage());
            System.debug('==RampUpliftHandler STACK==     ' + e.getStackTraceString());
            // Fail gracefully — never block pricing
        }
    }

    // =========================================================
    // HELPER: Get prior segment name
    // Supports Year 1 through Year 6
    // =========================================================
    private static String getPriorSegmentName(String currentSegment) {
        if (String.isBlank(currentSegment)) return null;

        Map<String, String> segmentOrder = new Map<String, String>{
            'Year 2' => 'Year 1',
            'Year 3' => 'Year 2',
            'Year 4' => 'Year 3',
            'Year 5' => 'Year 4',
            'Year 6' => 'Year 5'
        };

        return segmentOrder.get(currentSegment);
    }
}