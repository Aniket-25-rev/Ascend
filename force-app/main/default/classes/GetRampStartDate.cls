public class GetRampStartDate {
    /*
     * Invocable class called from the Create Ramp Schedule Custom flow.
     * Receives the raw rampScheduleSegmentsJson string produced by
     * guidedRampPreview and returns the earliest segment start date,
     * which represents Year 1 / the first ramp segment.
     *
     * Entry point : execute()
     * Called from : Flow — Create Ramp Schedule Custom
     *
     * NOTE: Entire class body temporarily commented out.
     *       Remove the block comment delimiters to re-enable.
     *
     * public class Request {
     *     @InvocableVariable(required=true)
     *     public String rampScheduleSegmentsJson;
     * }
     *
     * public class Result {
     *     @InvocableVariable
     *     public Date firstSegmentStartDate;
     * }
     *
     * @InvocableMethod(
     *     label       = 'Get First Ramp Segment Start Date'
     *     description = 'Parses rampScheduleSegmentsJson from guidedRampPreview and returns the earliest segment start date.'
     * )
     * public static List<Result> execute(List<Request> requests) {
     *     List<Result> results = new List<Result>();
     *     for (Request req : requests) {
     *         Result res = new Result();
     *         if (String.isNotBlank(req.rampScheduleSegmentsJson)) {
     *             res.firstSegmentStartDate = parseFirstStartDate(req.rampScheduleSegmentsJson);
     *         }
     *         results.add(res);
     *     }
     *     return results;
     * }
     *
     * Revenue Cloud does not use a single consistent key name for the
     * segment start date across API versions. This list covers every
     * variant seen in practice so the parser remains forward-compatible.
     *
     * private static final List<String> DATE_KEYS = new List<String>{
     *     'startDate', 'StartDate', 'effectiveFrom', 'EffectiveFrom',
     *     'segmentStartDate', 'SegmentStartDate', 'start_date'
     * };
     *
     * Deserialises the JSON string and delegates to findEarliestStartDate.
     * Returns null on any parse failure so the Flow can handle it gracefully.
     *
     * private static Date parseFirstStartDate(String jsonStr) {
     *     try {
     *         Object parsed = JSON.deserializeUntyped(jsonStr);
     *         return findEarliestStartDate(parsed);
     *     } catch (Exception e) {
     *         System.debug('==GetRampStartDate parse error== ' + e.getMessage());
     *         return null;
     *     }
     * }
     *
     * Recursively walks the deserialised JSON tree.
     * Collects every value found under a known start-date key and returns
     * the minimum — the earliest date across all segments = Year 1 start.
     * Handles both array and map nodes so it works regardless of whether
     * Revenue Cloud returns a flat array of segments or a nested structure.
     *
     * private static Date findEarliestStartDate(Object obj) {
     *     Date earliest = null;
     *     if (obj instanceof List<Object>) {
     *         for (Object item : (List<Object>) obj) {
     *             Date d = findEarliestStartDate(item);
     *             if (d != null && (earliest == null || d < earliest)) {
     *                 earliest = d;
     *             }
     *         }
     *     } else if (obj instanceof Map<String, Object>) {
     *         Map<String, Object> m = (Map<String, Object>) obj;
     *         for (String key : DATE_KEYS) {
     *             if (m.containsKey(key) && m.get(key) != null) {
     *                 try {
     *                     Date d = Date.valueOf(String.valueOf(m.get(key)));
     *                     if (earliest == null || d < earliest) earliest = d;
     *                 } catch (Exception e) {}
     *             }
     *         }
     *         for (String key : m.keySet()) {
     *             Object val = m.get(key);
     *             if (val instanceof List<Object> || val instanceof Map<String, Object>) {
     *                 Date d = findEarliestStartDate(val);
     *                 if (d != null && (earliest == null || d < earliest)) earliest = d;
     *             }
     *         }
     *     }
     *     return earliest;
     * }
     */
}