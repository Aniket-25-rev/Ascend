@IsTest
private class LineItemRelationshipContextTest {

    // =========================================================
    // HELPERS
    // =========================================================

    private static List<Object> dp(String lineId) {
        return new List<Object>{ 'ctx', 'STI', lineId };
    }

    private static Map<String, Object> buildNode(
        List<Object> dataPath,
        Boolean      isDeleted,
        String       parentContextId,
        String       endDate
    ) {
        Map<String, Object> tags = new Map<String, Object>();

        if (isDeleted) {
            tags.put('IsDeleted', new Map<String, Object>{ 'tagValue' => true });
        }
        if (parentContextId != null) {
            tags.put('ParentContextId',
                new Map<String, Object>{ 'tagValue' => parentContextId });
        }
        if (endDate != null) {
            tags.put('EndDate',
                new Map<String, Object>{ 'tagValue' => endDate });
        }

        Map<String, Object> obj = new Map<String, Object>{ 'tagValue' => tags };
        if (dataPath != null) {
            obj.put('dataPath', dataPath);
        }
        return obj;
    }

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    @IsTest
    static void constructor_initializesEmptyMaps() {
        LineItemRelationshipContext ctx = new LineItemRelationshipContext();

        System.assertEquals(0, ctx.childToParentMap.size(),
            'childToParentMap should start empty');
        System.assertEquals(0, ctx.parentEndDateMap.size(),
            'parentEndDateMap should start empty');
    }

    // =========================================================
    // build — null / empty guards
    // =========================================================

    @IsTest
    static void build_nullList_returnsEmptyContext() {
        LineItemRelationshipContext ctx = LineItemRelationshipContext.build(null);

        System.assertEquals(0, ctx.childToParentMap.size());
        System.assertEquals(0, ctx.parentEndDateMap.size());
    }

    @IsTest
    static void build_emptyList_returnsEmptyContext() {
        LineItemRelationshipContext ctx =
            LineItemRelationshipContext.build(new List<Object>());

        System.assertEquals(0, ctx.childToParentMap.size());
        System.assertEquals(0, ctx.parentEndDateMap.size());
    }

    // =========================================================
    // build — item filtering
    // =========================================================

    @IsTest
    static void build_nullDataPath_nodeSkipped() {
        // dataPath null → LineItemNodeWrapper.isValid() returns false
        List<Object> items = new List<Object>{
            buildNode(null, false, 'parent1', '2025-12-31')
        };

        LineItemRelationshipContext ctx = LineItemRelationshipContext.build(items);

        System.assertEquals(0, ctx.childToParentMap.size());
        System.assertEquals(0, ctx.parentEndDateMap.size());
    }

    @IsTest
    static void build_shortDataPath_nodeSkipped() {
        // dataPath.size() < 3 → isValid() returns false
        List<Object> items = new List<Object>{
            buildNode(new List<Object>{ 'ctx', 'STI' }, false, 'parent1', null)
        };

        LineItemRelationshipContext ctx = LineItemRelationshipContext.build(items);

        System.assertEquals(0, ctx.childToParentMap.size());
    }

    @IsTest
    static void build_deletedNode_isSkipped() {
        List<Object> items = new List<Object>{
            buildNode(dp('line1'), true, 'parent1', '2025-12-31')
        };

        LineItemRelationshipContext ctx = LineItemRelationshipContext.build(items);

        System.assertEquals(0, ctx.childToParentMap.size());
        System.assertEquals(0, ctx.parentEndDateMap.size());
    }

    // =========================================================
    // build — parentContextId population
    // =========================================================

    @IsTest
    static void build_nullParentContextId_notAddedToChildMap() {
        // parentContextId tag absent → getString returns null →
        // String.isNotBlank(null) = false → not added
        List<Object> items = new List<Object>{
            buildNode(dp('line1'), false, null, null)
        };

        LineItemRelationshipContext ctx = LineItemRelationshipContext.build(items);

        System.assertEquals(0, ctx.childToParentMap.size());
    }

    @IsTest
    static void build_nonBlankParentContextId_addedToChildMap() {
        List<Object> items = new List<Object>{
            buildNode(dp('line1'), false, 'parent1', null)
        };

        LineItemRelationshipContext ctx = LineItemRelationshipContext.build(items);

        System.assertEquals(1, ctx.childToParentMap.size());
        System.assertEquals('parent1', ctx.childToParentMap.get('line1'));
        System.assertEquals(0, ctx.parentEndDateMap.size());
    }

    // =========================================================
    // build — endDate population
    // =========================================================

    @IsTest
    static void build_nullEndDate_notAddedToEndDateMap() {
        List<Object> items = new List<Object>{
            buildNode(dp('line1'), false, null, null)
        };

        LineItemRelationshipContext ctx = LineItemRelationshipContext.build(items);

        System.assertEquals(0, ctx.parentEndDateMap.size());
    }

    @IsTest
    static void build_nonNullEndDate_addedToEndDateMap() {
        List<Object> items = new List<Object>{
            buildNode(dp('line1'), false, null, '2025-12-31')
        };

        LineItemRelationshipContext ctx = LineItemRelationshipContext.build(items);

        System.assertEquals(0, ctx.childToParentMap.size());
        System.assertEquals(1, ctx.parentEndDateMap.size());
        System.assertEquals('2025-12-31', ctx.parentEndDateMap.get('line1'));
    }

    @IsTest
    static void build_bothFields_populatesBothMaps() {
        List<Object> items = new List<Object>{
            buildNode(dp('line1'), false, 'parent1', '2025-12-31')
        };

        LineItemRelationshipContext ctx = LineItemRelationshipContext.build(items);

        System.assertEquals('parent1', ctx.childToParentMap.get('line1'));
        System.assertEquals('2025-12-31', ctx.parentEndDateMap.get('line1'));
    }

    // =========================================================
    // build — bulk / mixed items
    // =========================================================

    @IsTest
    static void build_multipleItems_mixedStates_processedCorrectly() {
        List<Object> items = new List<Object>{
            buildNode(dp('line1'), false, 'parentA', '2025-06-30'),
            buildNode(dp('line2'), false, 'parentB', '2025-12-31'),
            buildNode(dp('line3'), true,  'parentC', '2026-06-30'),  // deleted — skipped
            buildNode(null,        false, 'parentD', '2026-12-31')   // invalid — skipped
        };

        LineItemRelationshipContext ctx = LineItemRelationshipContext.build(items);

        System.assertEquals(2, ctx.childToParentMap.size());
        System.assertEquals('parentA', ctx.childToParentMap.get('line1'));
        System.assertEquals('parentB', ctx.childToParentMap.get('line2'));
        System.assertEquals(null, ctx.childToParentMap.get('line3'));

        System.assertEquals(2, ctx.parentEndDateMap.size());
        System.assertEquals('2025-06-30', ctx.parentEndDateMap.get('line1'));
        System.assertEquals('2025-12-31', ctx.parentEndDateMap.get('line2'));
    }

    // =========================================================
    // getParentEndDate
    // =========================================================

    @IsTest
    static void getParentEndDate_childNotInMap_returnsNull() {
        LineItemRelationshipContext ctx = new LineItemRelationshipContext();

        Object result = ctx.getParentEndDate('unknownChild');

        System.assertEquals(null, result);
    }

    @IsTest
    static void getParentEndDate_nullChildId_returnsNull() {
        LineItemRelationshipContext ctx = new LineItemRelationshipContext();
        ctx.childToParentMap.put('child1', 'parent1');
        ctx.parentEndDateMap.put('parent1', '2025-12-31');

        Object result = ctx.getParentEndDate(null);

        System.assertEquals(null, result);
    }

    @IsTest
    static void getParentEndDate_parentNotInEndDateMap_returnsNull() {
        LineItemRelationshipContext ctx = new LineItemRelationshipContext();
        ctx.childToParentMap.put('child1', 'parent1');
        // parent1 absent from parentEndDateMap

        Object result = ctx.getParentEndDate('child1');

        System.assertEquals(null, result);
    }

    @IsTest
    static void getParentEndDate_parentInEndDateMap_returnsEndDate() {
        LineItemRelationshipContext ctx = new LineItemRelationshipContext();
        ctx.childToParentMap.put('child1', 'parent1');
        ctx.parentEndDateMap.put('parent1', '2025-12-31');

        Object result = ctx.getParentEndDate('child1');

        System.assertEquals('2025-12-31', result);
    }

    @IsTest
    static void getParentEndDate_chainedViaBuiltContext_resolves() {
        // End-to-end: build populates maps, then getParentEndDate resolves correctly.
        // parent line (line1) has endDate; child line (line2) has parentContextId = 'line1'
        List<Object> items = new List<Object>{
            buildNode(dp('line1'), false, null,    '2026-03-31'),  // parent: has endDate
            buildNode(dp('line2'), false, 'line1', null)           // child: points to line1
        };

        LineItemRelationshipContext ctx = LineItemRelationshipContext.build(items);
        Object endDate = ctx.getParentEndDate('line2');

        System.assertEquals('2026-03-31', endDate,
            'Child line2 should resolve to parent line1\'s endDate');
    }
}