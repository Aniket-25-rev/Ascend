public class GetRampTotalDuration {

    /* 
    public class Request {
        @InvocableVariable(required=true)
        public String rampScheduleSegmentsJson;  // raw JSON from guidedRampPreview
    }

    
    public class Result {
        @InvocableVariable
        public Integer totalDurationMonths;  // sum of all ramp segment durations
    }

    
    @InvocableMethod(
        label       = 'Get Ramp Schedule Total Duration (Months)'
        description = 'Parses rampScheduleSegmentsJson from guidedRampPreview and returns total ramp duration in months.'
    )
    public static List<Result> execute(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            if (String.isNotBlank(req.rampScheduleSegmentsJson)) {
                res.totalDurationMonths = calcTotalDuration(req.rampScheduleSegmentsJson);
            }
            results.add(res);
        }
        return results;
    }

    
    private static final List<String> START_KEYS = new List<String>{
        'startDate', 'StartDate', 'effectiveFrom', 'EffectiveFrom',
        'segmentStartDate', 'SegmentStartDate', 'start_date'
    };

    
    private static final List<String> END_KEYS = new List<String>{
        'endDate', 'EndDate', 'effectiveTo', 'EffectiveTo',
        'segmentEndDate', 'SegmentEndDate', 'end_date'
    };

     
    private static Integer calcTotalDuration(String jsonStr) {
        try {
            Object parsed = JSON.deserializeUntyped(jsonStr);
            List<Date[]> segments = collectSegments(parsed);
            Integer total = 0;
            for (Date[] seg : segments) {
                Date startDate = seg[0];
                Date nextDay   = seg[1].addDays(1); // inclusive EndDate → exclusive upper bound
                Integer months = (nextDay.year()  - startDate.year())  * 12
                               + (nextDay.month() - startDate.month());
                total += months;
            }
            return total;
        } catch (Exception e) {
            System.debug('==GetRampTotalDuration error== ' + e.getMessage());
            return null;
        }
    }

    private static List<Date[]> collectSegments(Object obj) {
        List<Date[]> segs = new List<Date[]>();
        if (obj instanceof List<Object>) {
            // Array node — recurse into every element
            for (Object item : (List<Object>) obj) {
                segs.addAll(collectSegments(item));
            }
        } else if (obj instanceof Map<String, Object>) {
            Map<String, Object> m = (Map<String, Object>) obj;
            Date sd = findDate(m, START_KEYS);
            Date ed = findDate(m, END_KEYS);
            if (sd != null && ed != null) {
                // Leaf segment — collect and stop (do not recurse further)
                segs.add(new Date[]{ sd, ed });
            } else {
                // Not a complete segment — recurse into child lists and maps
                for (String key : m.keySet()) {
                    Object val = m.get(key);
                    if (val instanceof List<Object> || val instanceof Map<String, Object>) {
                        segs.addAll(collectSegments(val));
                    }
                }
            }
        }
        return segs;
    }

    private static Date findDate(Map<String, Object> m, List<String> keys) {
        for (String key : keys) {
            if (m.containsKey(key) && m.get(key) != null) {
                try { return Date.valueOf(String.valueOf(m.get(key))); } catch (Exception e) {}
            }
        }
        return null;
    }
*/
}