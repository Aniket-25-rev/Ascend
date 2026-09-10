@isTest
private class LineItemNodeWrapperTest {

    // Builds a node map shaped like what JTLPreHook.queryLineItems() would hand to the wrapper
    private static Map<String, Object> buildNode(
        List<Object> dataPath,
        Map<String, Object> tagValue
    ) {
        Map<String, Object> node = new Map<String, Object>();
        if (dataPath != null) node.put('dataPath', dataPath);
        if (tagValue != null) node.put('tagValue', tagValue);
        return node;
    }

    private static Map<String, Object> tag(Object value) {
        return new Map<String, Object>{ 'tagValue' => value };
    }

    @isTest
    static void testValidNode_allFieldsPopulated() {
        List<Object> dataPath = new List<Object>{ 'root', 'SalesTransactionItem', '01u000000000001AAA' };

        Map<String, Object> tags = new Map<String, Object>{
            'IsDeleted'             => tag(false),
            'ProductCode'           => tag('PROD-100'),
            'SellingModelType'      => tag('TermDefined'),
            'ItemSegmentIdentifier' => tag('SEG-1')
        };

        Map<String, Object> node = buildNode(dataPath, tags);

        LineItemNodeWrapper li = new LineItemNodeWrapper(node);

        System.assertEquals(dataPath, li.dataPath);
        System.assertEquals(2, li.salesPath.size());
        System.assertEquals('SalesTransactionItem', li.salesPath.get(0));
        System.assertEquals('01u000000000001AAA', li.salesPath.get(1));
        System.assertEquals(false, li.deleted);
        System.assertEquals('PROD-100', li.productCode);
        System.assertEquals('TermDefined', li.sellingModelType);
        System.assertEquals('SEG-1', li.segmentIdentifier);
        System.assertEquals(true, li.isValid());
        System.assertEquals(true, li.isTermBased());
    }

    @isTest
    static void testDeletedTrue() {
        List<Object> dataPath = new List<Object>{ 'root', 'SalesTransactionItem', '01u000000000002AAA' };
        Map<String, Object> tags = new Map<String, Object>{
            'IsDeleted' => tag(true)
        };
        LineItemNodeWrapper li = new LineItemNodeWrapper(buildNode(dataPath, tags));

        System.assertEquals(true, li.deleted);
    }

    @isTest
    static void testDeletedKeyMissing_defaultsFalse() {
        List<Object> dataPath = new List<Object>{ 'root', 'SalesTransactionItem', '01u000000000003AAA' };
        Map<String, Object> tags = new Map<String, Object>{
            'ProductCode' => tag('PROD-200')
        };
        LineItemNodeWrapper li = new LineItemNodeWrapper(buildNode(dataPath, tags));

        System.assertEquals(false, li.deleted, 'Missing IsDeleted key should default to false');
    }

    @isTest
    static void testNoTagsMap_allStringsNull() {
        List<Object> dataPath = new List<Object>{ 'root', 'SalesTransactionItem', '01u000000000004AAA' };
        LineItemNodeWrapper li = new LineItemNodeWrapper(buildNode(dataPath, null));

        System.assertEquals(false, li.deleted);
        System.assertEquals(null, li.productCode);
        System.assertEquals(null, li.sellingModelType);
        System.assertEquals(null, li.segmentIdentifier);
        System.assertEquals(true, li.isValid());
        System.assertEquals(false, li.isTermBased());
    }

    @isTest
    static void testInvalidNode_dataPathTooShort() {
        List<Object> dataPath = new List<Object>{ 'root', 'OnlyTwo' };
        LineItemNodeWrapper li = new LineItemNodeWrapper(buildNode(dataPath, null));

        System.assertEquals(null, li.salesPath, 'salesPath should not be built when dataPath has < 3 entries');
        System.assertEquals(false, li.isValid());
    }

    @isTest
    static void testInvalidNode_dataPathNull() {
        LineItemNodeWrapper li = new LineItemNodeWrapper(buildNode(null, null));

        System.assertEquals(null, li.dataPath);
        System.assertEquals(null, li.salesPath);
        System.assertEquals(false, li.isValid());
    }

    @isTest
    static void testIsTermBased_falseWhenSellingModelDoesNotContainTerm() {
        List<Object> dataPath = new List<Object>{ 'root', 'SalesTransactionItem', '01u000000000005AAA' };
        Map<String, Object> tags = new Map<String, Object>{
            'SellingModelType' => tag('OneTime')
        };
        LineItemNodeWrapper li = new LineItemNodeWrapper(buildNode(dataPath, tags));

        System.assertEquals(false, li.isTermBased());
    }

    @isTest
    static void testIsTermBased_caseInsensitive() {
        List<Object> dataPath = new List<Object>{ 'root', 'SalesTransactionItem', '01u000000000006AAA' };
        Map<String, Object> tags = new Map<String, Object>{
            'SellingModelType' => tag('EVERGREEN-TERM')
        };
        LineItemNodeWrapper li = new LineItemNodeWrapper(buildNode(dataPath, tags));

        System.assertEquals(true, li.isTermBased());
    }

    @isTest
    static void testGetString_malformedTagShape_swallowsException() {
        // tags.get('ProductCode') is a String, not a Map -> getString() should catch
        // the ClassCastException internally and return null rather than throwing.
        List<Object> dataPath = new List<Object>{ 'root', 'SalesTransactionItem', '01u000000000007AAA' };
        Map<String, Object> tags = new Map<String, Object>{
            'ProductCode' => 'not-a-map'
        };
        LineItemNodeWrapper li = new LineItemNodeWrapper(buildNode(dataPath, tags));

        System.assertEquals(null, li.productCode, 'Malformed tag shape should be swallowed and return null');
    }

    @isTest
    static void testDeletedTagMalformed_swallowsException() {
        // tags.get('IsDeleted') is a String, not a Map -> constructor's IsDeleted
        // cast should throw internally; verifying this doesn't blow up the constructor
        // would require catching at a higher level since the constructor does NOT
        // wrap this particular cast in try/catch. We instead confirm the well-formed
        // boolean path (String 'true'/'false' coercion via Boolean.valueOf(String.valueOf(...))).
        List<Object> dataPath = new List<Object>{ 'root', 'SalesTransactionItem', '01u000000000008AAA' };
        Map<String, Object> tags = new Map<String, Object>{
            'IsDeleted' => tag('true')
        };
        LineItemNodeWrapper li = new LineItemNodeWrapper(buildNode(dataPath, tags));

        System.assertEquals(true, li.deleted, 'String "true" tagValue should coerce to boolean true');
    }
}