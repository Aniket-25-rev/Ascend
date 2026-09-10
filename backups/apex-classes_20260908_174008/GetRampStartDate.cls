public class GetRampStartDate {

    public class Request {
        @InvocableVariable(required=true)
        public String rampScheduleSegmentsJson;
    }

    public class Result {
        @InvocableVariable
        public Date firstSegmentStartDate;
    }

    @InvocableMethod(
        label       = 'Get First Ramp Segment Start Date'
        description = 'Parses rampScheduleSegmentsJson from guidedRampPreview and returns the earliest segment start date.'
    )
    public static List<Result> execute(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            if (String.isNotBlank(req.rampScheduleSegmentsJson)) {
                res.firstSegmentStartDate = parseFirstStartDate(req.rampScheduleSegmentsJson);
            }
            results.add(res);
        }
        return results;
    }

    // Keys Revenue Cloud may use for a segment's start date
    private static final List<String> DATE_KEYS = new List<String>{
        'startDate', 'StartDate', 'effectiveFrom', 'EffectiveFrom',
        'segmentStartDate', 'SegmentStartDate', 'start_date'
    };

    private static Date parseFirstStartDate(String jsonStr) {
        try {
            Object parsed = JSON.deserializeUntyped(jsonStr);
            return findEarliestStartDate(parsed);
        } catch (Exception e) {
            System.debug('==GetRampStartDate parse error== ' + e.getMessage());
            return null;
        }
    }

    // Recursively walks the JSON tree collecting values from known start-date
    // keys and returns the minimum (= Year 1 / first segment).
    private static Date findEarliestStartDate(Object obj) {
        Date earliest = null;
        if (obj instanceof List<Object>) {
            for (Object item : (List<Object>) obj) {
                Date d = findEarliestStartDate(item);
                if (d != null && (earliest == null || d < earliest)) {
                    earliest = d;
                }
            }
        } else if (obj instanceof Map<String, Object>) {
            Map<String, Object> m = (Map<String, Object>) obj;
            for (String key : DATE_KEYS) {
                if (m.containsKey(key) && m.get(key) != null) {
                    try {
                        Date d = Date.valueOf(String.valueOf(m.get(key)));
                        if (earliest == null || d < earliest) earliest = d;
                    } catch (Exception e) {}
                }
            }
            for (String key : m.keySet()) {
                Object val = m.get(key);
                if (val instanceof List<Object> || val instanceof Map<String, Object>) {
                    Date d = findEarliestStartDate(val);
                    if (d != null && (earliest == null || d < earliest)) earliest = d;
                }
            }
        }
        return earliest;
    }
}