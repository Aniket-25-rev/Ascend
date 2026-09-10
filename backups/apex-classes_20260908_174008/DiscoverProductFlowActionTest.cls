@isTest
private class DiscoverProductFlowActionTest {

    @isTest
    static void testGenerateJSON_singleInput() {
        DiscoverProductFlowAction.FlowInput input = new DiscoverProductFlowAction.FlowInput();
        input.objectApiName = 'QuoteLineItem';
        input.recordId = '0Q0000000000001AAA';

        List<DiscoverProductFlowAction.FlowInput> inputs =
            new List<DiscoverProductFlowAction.FlowInput>{ input };

        Test.startTest();
        List<DiscoverProductFlowAction.FlowOutput> outputs =
            DiscoverProductFlowAction.generateJSON(inputs);
        Test.stopTest();

        System.assertEquals(1, outputs.size(), 'Should return exactly one FlowOutput');

        DiscoverProductFlowAction.FlowOutput output = outputs.get(0);
        System.assertEquals(1, output.additionalContextData.size(),
            'Should contain exactly one ContextDataInput entry');

        runtime_industries_cpq.ContextDataInput contextData = output.additionalContextData.get(0);
        System.assertEquals('QuoteLineItem', contextData.nodeName);
        System.assertEquals('0Q0000000000001AAA', contextData.nodeData.get('id'));
    }

    @isTest
    static void testGenerateJSON_multipleInputs_usesLastValues() {
        // The method loops over all inputs but only keeps the last apiName/recId
        // (loop variables are overwritten each iteration), so with multiple inputs
        // the LAST input's values should be the ones reflected in the output.
        DiscoverProductFlowAction.FlowInput input1 = new DiscoverProductFlowAction.FlowInput();
        input1.objectApiName = 'Quote';
        input1.recordId = '0Q0000000000002AAA';

        DiscoverProductFlowAction.FlowInput input2 = new DiscoverProductFlowAction.FlowInput();
        input2.objectApiName = 'QuoteLineItem';
        input2.recordId = '0Q0000000000003AAA';

        List<DiscoverProductFlowAction.FlowInput> inputs =
            new List<DiscoverProductFlowAction.FlowInput>{ input1, input2 };

        Test.startTest();
        List<DiscoverProductFlowAction.FlowOutput> outputs =
            DiscoverProductFlowAction.generateJSON(inputs);
        Test.stopTest();

        DiscoverProductFlowAction.FlowOutput output = outputs.get(0);
        runtime_industries_cpq.ContextDataInput contextData = output.additionalContextData.get(0);

        System.assertEquals('QuoteLineItem', contextData.nodeName, 'Should reflect the last input processed');
        System.assertEquals('0Q0000000000003AAA', contextData.nodeData.get('id'));
    }

    @isTest
    static void testGenerateJSON_emptyInputList() {
        List<DiscoverProductFlowAction.FlowInput> inputs =
            new List<DiscoverProductFlowAction.FlowInput>();

        Test.startTest();
        List<DiscoverProductFlowAction.FlowOutput> outputs =
            DiscoverProductFlowAction.generateJSON(inputs);
        Test.stopTest();

        System.assertEquals(1, outputs.size(), 'Should still return one FlowOutput even with no inputs');

        DiscoverProductFlowAction.FlowOutput output = outputs.get(0);
        runtime_industries_cpq.ContextDataInput contextData = output.additionalContextData.get(0);

        System.assertEquals(null, contextData.nodeName, 'No inputs means apiName stays null');
        System.assertEquals(null, contextData.nodeData.get('id'), 'No inputs means recId stays null');
    }

    @isTest
    static void testGenerateJSON_blankOptionalFields() {
        DiscoverProductFlowAction.FlowInput input = new DiscoverProductFlowAction.FlowInput();
        // objectApiName and recordId left null since @invocableVariable(required=false)

        List<DiscoverProductFlowAction.FlowInput> inputs =
            new List<DiscoverProductFlowAction.FlowInput>{ input };

        Test.startTest();
        List<DiscoverProductFlowAction.FlowOutput> outputs =
            DiscoverProductFlowAction.generateJSON(inputs);
        Test.stopTest();

        DiscoverProductFlowAction.FlowOutput output = outputs.get(0);
        runtime_industries_cpq.ContextDataInput contextData = output.additionalContextData.get(0);

        System.assertEquals(null, contextData.nodeName);
        System.assertEquals(null, contextData.nodeData.get('id'));
    }
}