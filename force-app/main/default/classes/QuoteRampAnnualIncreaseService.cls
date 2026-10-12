/**
 * QuoteRampAnnualIncreaseService
 *
 * AC7 - Annual % Increase populated from Ramp.
 *
 * When a ramp exists on a Quote and its SECOND segment carries a
 * Unit Price Uplift, that value is copied onto Quote.Annual_Increase__c.
 *
 * WHICH SEGMENT: the second one ordered by StartDate ascending, with
 * SortOrder and then Id only breaking ties. Ordering by SortOrder alone
 * is not safe - RCA stamps mid-term amendment segments with SortOrder
 * -999999999 and up - and segment NAMES are not reliable either: the org
 * carries "Year 2", "Segment 2" on custom ramps and "Year 2 - Amend" on
 * amendments.
 *
 * WHICH VALUE: the second segment's uplift verbatim, per AC7. Note that
 * QuoteLineGroup.UnitPriceUplift is CUMULATIVE from the base price rather
 * than a per-year step (a 4%/year ramp reads 4 / 8 / 12), so on ramps
 * whose FIRST segment also carries an uplift the copied figure is the
 * two-year total, not the annual rate. That is the literal acceptance
 * criterion; see the deploy notes for the alternative.
 *
 * SAFETY: this runs from an after-save flow on QuoteLineGroup, so an
 * uncaught exception would roll back ramp creation. Every path is wrapped
 * and DML is partial-success - the stamp must never block a ramp save.
 *
 * Test Class: QuoteRampAnnualIncreaseServiceTest
 */
public without sharing class QuoteRampAnnualIncreaseService {

    // Quotes already written in this transaction. Only WRITES are guarded,
    // never evaluations: a no-op pass (segment 2 not created yet) must not
    // stop a later segment in the same transaction from stamping.
    @TestVisible
    private static Set<Id> stampedQuoteIds = new Set<Id>();

    @TestVisible
    private static List<String> faultLog = new List<String>();

    @TestVisible
    private static List<QuoteLineGroup> segmentOverride;

    public class Request {
        @InvocableVariable(label='Quote Id' required=true)
        public Id quoteId;
    }

    @InvocableMethod(
        label='Stamp Quote Annual Percent Increase From Ramp'
        description='Copies the second ramp segment Unit Price Uplift onto the quote Annual % Increase'
        category='Revenue'
    )
    public static void run(List<Request> requests) {
        Set<Id> quoteIds = new Set<Id>();
        if (requests != null) {
            for (Request request : requests) {
                if (request != null && request.quoteId != null) {
                    quoteIds.add(request.quoteId);
                }
            }
        }
        stampFromRamp(quoteIds);
    }

    public static void stampFromRamp(Set<Id> quoteIds) {
        try {
            execute(quoteIds);
        } catch (Exception e) {
            faultLog.add('QuoteRampAnnualIncreaseService: ' + e.getMessage()
                + ' | ' + e.getStackTraceString());
        }
    }

    private static void execute(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return;
        }

        Set<Id> targets = new Set<Id>();
        for (Id quoteId : quoteIds) {
            if (quoteId != null && !stampedQuoteIds.contains(quoteId)) {
                targets.add(quoteId);
            }
        }
        if (targets.isEmpty()) {
            return;
        }

        Map<Id, List<QuoteLineGroup>> segmentsByQuoteId = loadSegments(targets);
        if (segmentsByQuoteId.isEmpty()) {
            return;
        }

        Map<Id, Quote> stored = new Map<Id, Quote>([
            SELECT Id, Annual_Increase__c
            FROM Quote
            WHERE Id IN :targets
        ]);

        List<Quote> updates = new List<Quote>();
        for (Id quoteId : segmentsByQuoteId.keySet()) {
            Quote quote = stored.get(quoteId);
            if (quote == null) {
                continue;
            }
            QuoteLineGroup second = secondSegment(segmentsByQuoteId.get(quoteId));
            // AC7 fires only when the ramp actually carries a value.
            if (second == null || second.UnitPriceUplift == null) {
                continue;
            }
            if (quote.Annual_Increase__c == second.UnitPriceUplift) {
                continue;
            }
            updates.add(new Quote(Id = quoteId, Annual_Increase__c = second.UnitPriceUplift));
        }

        commitQuotes(updates);
    }

    @TestVisible
    private static Map<Id, List<QuoteLineGroup>> loadSegments(Set<Id> quoteIds) {
        List<QuoteLineGroup> source = segmentOverride != null
            ? segmentOverride
            : [
                SELECT Id, QuoteId, Name, StartDate, SortOrder, UnitPriceUplift
                FROM QuoteLineGroup
                WHERE QuoteId IN :quoteIds
                AND IsRamped = true
            ];

        Map<Id, List<QuoteLineGroup>> byQuoteId = new Map<Id, List<QuoteLineGroup>>();
        for (QuoteLineGroup segment : source) {
            if (segment == null || segment.QuoteId == null) {
                continue;
            }
            if (!quoteIds.contains(segment.QuoteId)) {
                continue;
            }
            if (!byQuoteId.containsKey(segment.QuoteId)) {
                byQuoteId.put(segment.QuoteId, new List<QuoteLineGroup>());
            }
            byQuoteId.get(segment.QuoteId).add(segment);
        }
        return byQuoteId;
    }

    // The second segment by StartDate. Null when the ramp has fewer than
    // two segments, which is the normal state while a ramp is being built.
    @TestVisible
    private static QuoteLineGroup secondSegment(List<QuoteLineGroup> segments) {
        if (segments == null || segments.size() < 2) {
            return null;
        }
        List<SegmentOrder> ordered = new List<SegmentOrder>();
        for (QuoteLineGroup segment : segments) {
            ordered.add(new SegmentOrder(segment));
        }
        ordered.sort();
        return ordered[1].segment;
    }

    private class SegmentOrder implements Comparable {
        private final QuoteLineGroup segment;

        private SegmentOrder(QuoteLineGroup segment) {
            this.segment = segment;
        }

        public Integer compareTo(Object other) {
            SegmentOrder that = (SegmentOrder) other;
            Integer result = compareDates(this.segment.StartDate, that.segment.StartDate);
            if (result != 0) {
                return result;
            }
            result = compareIntegers(this.segment.SortOrder, that.segment.SortOrder);
            if (result != 0) {
                return result;
            }
            return compareText(String.valueOf(this.segment.Id), String.valueOf(that.segment.Id));
        }
    }

    // Nulls sort last throughout, so a segment with no StartDate can never
    // be mistaken for the start of the ramp.
    private static Integer compareDates(Date left, Date right) {
        if (left == right) {
            return 0;
        }
        if (left == null) {
            return 1;
        }
        if (right == null) {
            return -1;
        }
        return left < right ? -1 : 1;
    }

    private static Integer compareIntegers(Integer left, Integer right) {
        if (left == right) {
            return 0;
        }
        if (left == null) {
            return 1;
        }
        if (right == null) {
            return -1;
        }
        return left < right ? -1 : 1;
    }

    private static Integer compareText(String left, String right) {
        if (left == right) {
            return 0;
        }
        if (left == null) {
            return 1;
        }
        if (right == null) {
            return -1;
        }
        return left.compareTo(right);
    }

    private static void commitQuotes(List<Quote> updates) {
        if (updates == null || updates.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = Database.update(updates, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                stampedQuoteIds.add(updates[i].Id);
            } else {
                faultLog.add('Quote ' + updates[i].Id + ': ' + errorText(results[i]));
            }
        }
    }

    private static String errorText(Database.SaveResult result) {
        List<String> parts = new List<String>();
        for (Database.Error error : result.getErrors()) {
            parts.add(error.getStatusCode() + ': ' + error.getMessage() + ' ' + error.getFields());
        }
        return String.join(parts, ' | ');
    }
}