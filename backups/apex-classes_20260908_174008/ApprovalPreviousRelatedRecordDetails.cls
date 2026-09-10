// This is wrapper class to get getPreviousRelaRecDetails results
// Disabled pending resolution of the Advance_Approvals trigger-version issue - see backup / git history for original implementation.
public class ApprovalPreviousRelatedRecordDetails {

    /*
    static final String ACTION_NAME = 'getPreviousRelaRecDetails';
    static final String ACTION_INPUT_PARAM_FOI_ID = 'flowOrchestrationInstanceId';
    static final String ACTION_INPUT_PARAM_STEP_API_NAMES = 'stepApiNamesList';
    static final String ACTION_OUTPUT_PARAM_PREVIOUS_RECORD_DETAILS = 'previousRelatedRecordDetails';

    @InvocableMethod(label='Get Previous Related Record Details' description='Gets the related record details submitted for approval prior to the current approval submission, which is required for approval steps that use custom logic for auto-approvals.')
    // This method gets the previous related record details for the passed flow orchestration instance ID and the step api names.
    public static List<List<SObject>> getPreviousRelaRecDetails(List<FlowInputs> flowInputs) {
        List<List<SObject>> response = new List<List<SObject>>();
        List<SObject> allPreviousRelatedRecordDetails = new List<SObject>();

        // Set the action as the getPreviousRelaRecDetails which fetches related record details from the previous submission.
        Invocable.Action action = Invocable.Action.createStandardAction(ACTION_NAME);
        action.setInvocationParameter(ACTION_INPUT_PARAM_FOI_ID, flowInputs[0].flowOrchestrationInstanceId);
        action.setInvocationParameter(ACTION_INPUT_PARAM_STEP_API_NAMES, flowInputs[0].stepApiNamesList);

        // Run the invocable action.
        List<Invocable.Action.Result> results = action.invoke();

        // Get all the previous related record details. They are retrieved in the same order as the order of the input step API names.
        if (results.size() > 0 && results[0].isSuccess()) {
            allPreviousRelatedRecordDetails = (List<SObject>) results[0].getOutputParameters().get(ACTION_OUTPUT_PARAM_PREVIOUS_RECORD_DETAILS);
            response.add(allPreviousRelatedRecordDetails);
        } else if (!results[0].isSuccess()) {
            // If there are no results returned, consider it as a failure.
            // Based upon the use case, this can also be success with 0 records.
            for (Invocable.Action.Error error : results[0].getErrors()) {
                // throw new InvocableActionException(error.getMessage());
            }
        }
        return response;
    }

    // This inner class sets invocable action input variables
    public class FlowInputs {
        @InvocableVariable
        public String flowOrchestrationInstanceId;

        @InvocableVariable(required=false)
        public List<String> stepApiNamesList;
    }

    // This inner class is to handle any invocable action related exceptions
    public class InvocableActionException extends Exception {
    }
    */
}