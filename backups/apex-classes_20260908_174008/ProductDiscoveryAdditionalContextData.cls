/**
 * ProductDiscoveryAdditionalContextData
 * 
 * Provides additional context data to the Product Discovery LWC,
 * enabling Qualification Procedures to read field values from the 
 * current Quote or Order record (e.g., OriginalActionType) when 
 * evaluating product qualification rules.
 *
 * Invoked by the cloned "Custom Browse Products" flow before the
 * Product List screen renders.
 * 
 * @author    Implementation Team
 * @date      2026
 * @reference https://thecloudupdate.co/implementing-qualification-disqualification-rules-in-salesforce-revenue-cloud/
 */
public with sharing class ProductDiscoveryAdditionalContextData {

    /**
     * Input wrapper for the invocable method.
     * Passed in from Flow with the source object API name and record Id.
     */
    public class FlowInput {
        @InvocableVariable(
            required=true 
            label='Object API Name' 
            description='API name of the source object, e.g., Quote or Order'
        )
        public String objectApiName;

        @InvocableVariable(
            required=true 
            label='Record Id' 
            description='Id of the current Quote or Order record'
        )
        public String recordId;
    }

    /**
     * Output wrapper containing the additional context data array
     * consumed by the Product Discovery LWC.
     */
    public class FlowOutput {
        @InvocableVariable(label='Additional Context Data')
        public runtime_industries_cpq.ContextDataInput[] additionalContextData;
    }

    /**
     * Generates a context data input array that injects the current Quote
     * (or Order) record's Id into the Product Discovery runtime context.
     *
     * @param inputs List of FlowInput records (typically a single entry).
     * @return List of FlowOutput records with populated context data array.
     */
    @InvocableMethod(
        label='Generate Product Discovery Context Data'
        description='Generates additional context data for the Product Discovery LWC, injecting the current Quote or Order recordId and qualification filter fields into the context.'
    )
    public static List<FlowOutput> generateJSON(List<FlowInput> inputs) {

        List<FlowOutput> outputs = new List<FlowOutput>();

        if (inputs == null || inputs.isEmpty()) {
            System.debug(LoggingLevel.WARN,
                'ProductDiscoveryAdditionalContextData: No inputs provided');
            outputs.add(new FlowOutput());
            return outputs;
        }

        for (FlowInput input : inputs) {
            FlowOutput output = new FlowOutput();
            List<runtime_industries_cpq.ContextDataInput> contextDataList =
                new List<runtime_industries_cpq.ContextDataInput>();

            if (String.isBlank(input.objectApiName) ||
                String.isBlank(input.recordId)) {
                System.debug(LoggingLevel.WARN,
                    'ProductDiscoveryAdditionalContextData: Skipping input with missing values. ' +
                    'objectApiName=' + input.objectApiName +
                    ', recordId=' + input.recordId);
                output.additionalContextData = contextDataList;
                outputs.add(output);
                continue;
            }

            Map<String, Object> nodeDataMap = new Map<String, Object>{
                'id' => input.recordId
            };

            // The context definition registers the Quote node as "Quote__c".
            // The context attribute for OriginalActionType is "OriginalActionType__c",
            // hydrated from the standard Quote.OriginalActionType field.
            String nodeName = (input.objectApiName == 'Quote') ? 'Quote__c' : input.objectApiName;

            try {
                if (input.objectApiName == 'Quote') {
                    Quote q = [
                        SELECT Id, OriginalActionType
                        FROM Quote
                        WHERE Id = :input.recordId
                        LIMIT 1
                    ];
                    if (q.OriginalActionType != null) {
                        nodeDataMap.put('OriginalActionType__c', q.OriginalActionType);
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'ProductDiscoveryAdditionalContextData: Could not query record fields. ' + e.getMessage());
            }

            runtime_industries_cpq.ContextDataInput contextData =
                new runtime_industries_cpq.ContextDataInput();
            contextData.nodeName = nodeName;
            contextData.nodeData = nodeDataMap;

            contextDataList.add(contextData);
            output.additionalContextData = contextDataList;
            outputs.add(output);

            System.debug(LoggingLevel.INFO,
                'ProductDiscoveryAdditionalContextData: Generated context for ' +
                input.objectApiName + ' record ' + input.recordId +
                ' nodeData=' + JSON.serialize(nodeDataMap));
        }

        return outputs;
    }
}