/**
 * ============================================================================
 * PS_EstimateRatingCalculator2
 * ============================================================================
 *
 * PURPOSE
 * -------
 * Rate a Professional Services Feature Line Item after Flow has created or
 * updated it.
 *
 * FLOW INPUT
 * ----------
 * Flow supplies ONE input only:
 *
 *      Feature Line Item Id
 *
 * Apex then:
 *
 *      1. Queries the Feature Line Item
 *      2. Reads its Resource Role
 *      3. Finds the applicable PS Resource Rate
 *      4. Calculates Resource Rate, Base Cost and Total Cost
 *      5. Updates the Feature Line Item
 *
 * Flow must save the Feature Line Item BEFORE calling this Apex action.
 *
 * NOTE ABOUT INVOCABLE METHODS
 * ----------------------------
 * Salesforce requires an @InvocableMethod to receive a List<Request>.
 * That does NOT mean Flow needs to provide multiple input fields.
 *
 * The Request wrapper below contains exactly ONE Flow-visible input:
 *
 *      featureLineItemId
 *
 * Salesforce may technically invoke the action with more than one Request
 * wrapper in a bulk transaction, so the implementation remains bulk-safe.
 * Each Request, however, contains only one Feature Line Item Id.
 * ============================================================================
 */
public with sharing class PS_EstimateRatingCalculator2 {

    // ========================================================================
    // FLOW INPUT — ONE INPUT ONLY
    // ========================================================================

    public class Request {

        @InvocableVariable(
            label='Feature Line Item Id'
            description='Id of the saved Professional Services Feature Line Item to rate.'
            required=true
        )
        public Id featureLineItemId;
    }


    // ========================================================================
    // FLOW OUTPUT
    // ========================================================================

    public class Response {

        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Message')
        public String message;

        @InvocableVariable(label='Line Items Calculated')
        public Integer lineItemsCalculated;

        @InvocableVariable(label='Line Items Updated')
        public Integer lineItemsUpdated;

        @InvocableVariable(label='Line Items Failed')
        public Integer lineItemsFailed;
    }


    // ========================================================================
    // FLOW ENTRY POINT
    // ========================================================================

    @InvocableMethod(
        label='Rate Professional Services Feature Line Item'
        description='Accepts one Feature Line Item Id per request, retrieves its rate, calculates pricing, and updates the Feature Line Item.'
    )
    public static List<Response> rateFeatureLineItems(List<Request> requests) {

        List<Response> responses = new List<Response>();

        if (requests == null || requests.isEmpty()) {
            return responses;
        }

        Set<Id> lineItemIds = new Set<Id>();

        for (Request request : requests) {
            if (request != null && request.featureLineItemId != null) {
                lineItemIds.add(request.featureLineItemId);
            }
        }

        if (lineItemIds.isEmpty()) {

            for (Request request : requests) {

                Response response = new Response();

                response.success = false;
                response.message = 'Feature Line Item Id is required.';
                response.lineItemsCalculated = 0;
                response.lineItemsUpdated = 0;
                response.lineItemsFailed = 0;

                responses.add(response);
            }

            return responses;
        }

        CalculationResult result;

        try {

            result = calculateAndUpdateLineItems(lineItemIds);

        } catch (Exception ex) {

            result = new CalculationResult();

            result.success = false;
            result.message =
                'Professional Services Feature Line Item rating failed: '
                + ex.getMessage();
        }

        for (Request request : requests) {

            Response response = new Response();

            response.success = result.success;
            response.message = result.message;
            response.lineItemsCalculated = result.lineItemsCalculated;
            response.lineItemsUpdated = result.lineItemsUpdated;
            response.lineItemsFailed = result.lineItemsFailed;

            responses.add(response);
        }

        return responses;
    }


    // ========================================================================
    // MAIN RATING SERVICE
    // ========================================================================

    private static CalculationResult calculateAndUpdateLineItems(
        Set<Id> lineItemIds
    ) {

        CalculationResult result = new CalculationResult();

        result.success = true;


        // ====================================================================
        // STEP 1 — QUERY FEATURE LINE ITEMS
        // ====================================================================

        List<Project_Estimate_Feature_Line_Item__c> lineItems = [
            SELECT
                Id,
                Feature__c,
                Estimate__c,
                Estimate_Hrs__c,
                Include_in_Estimate__c,
                Resource_Role__c,
                Resource_Rate__c,
                Base_Cost__c,
                Risk_Cost__c,
                Hypercare_Cost__c,
                Project_Management_Cost__c,
                Total_Cost__c
            FROM Project_Estimate_Feature_Line_Item__c
            WHERE Id IN :lineItemIds
        ];

        if (lineItems.isEmpty()) {

            result.success = false;
            result.message =
                'No Feature Line Item record was found for the supplied Id.';

            return result;
        }


        // ====================================================================
        // STEP 2 — COLLECT RESOURCE ROLES
        // ====================================================================

        Set<String> resourceRoles = new Set<String>();

        for (Project_Estimate_Feature_Line_Item__c lineItem : lineItems) {

            if (
                lineItem.Include_in_Estimate__c == true &&
                String.isNotBlank(lineItem.Resource_Role__c)
            ) {
                resourceRoles.add(lineItem.Resource_Role__c);
            }
        }


        // ====================================================================
        // STEP 3 — QUERY RESOURCE RATES
        // ====================================================================

        Map<String, Decimal> rateByResourceRole =
            new Map<String, Decimal>();

        if (!resourceRoles.isEmpty()) {

            List<PS_Resource_Rate__c> resourceRates = [
                SELECT
                    Id,
                    Resource__c,
                    Standard_Rate__c
                FROM PS_Resource_Rate__c
                WHERE Resource__c IN :resourceRoles
            ];

            for (PS_Resource_Rate__c resourceRate : resourceRates) {

                if (String.isBlank(resourceRate.Resource__c)) {
                    continue;
                }

                if (
                    rateByResourceRole.containsKey(
                        resourceRate.Resource__c
                    )
                ) {

                    throw new PSRatingException(
                        'Multiple PS Resource Rate records were found for '
                        + 'Resource Role '
                        + resourceRate.Resource__c
                        + '.'
                    );
                }

                if (resourceRate.Standard_Rate__c == null) {

                    throw new PSRatingException(
                        'PS Resource Rate '
                        + resourceRate.Id
                        + ' does not contain a Standard Rate.'
                    );
                }

                rateByResourceRole.put(
                    resourceRate.Resource__c,
                    resourceRate.Standard_Rate__c
                );
            }
        }


        // ====================================================================
        // STEP 4 — CALCULATE FEATURE LINE ITEMS
        // ====================================================================

        List<Project_Estimate_Feature_Line_Item__c> lineItemsToUpdate =
            new List<Project_Estimate_Feature_Line_Item__c>();

        for (Project_Estimate_Feature_Line_Item__c lineItem : lineItems) {


            // ----------------------------------------------------------------
            // EXCLUDED FROM ESTIMATE
            // ----------------------------------------------------------------

            if (lineItem.Include_in_Estimate__c != true) {

                lineItemsToUpdate.add(
                    new Project_Estimate_Feature_Line_Item__c(
                        Id = lineItem.Id,
                        Resource_Rate__c = null,
                        Base_Cost__c = 0,
                        Total_Cost__c = 0
                    )
                );

                result.lineItemsCalculated++;

                continue;
            }


            // ----------------------------------------------------------------
            // VALIDATE RESOURCE ROLE
            // ----------------------------------------------------------------

            if (String.isBlank(lineItem.Resource_Role__c)) {

                throw new PSRatingException(
                    'Feature Line Item '
                    + lineItem.Id
                    + ' is included in the Estimate but does not have '
                    + 'a Resource Role.'
                );
            }


            // ----------------------------------------------------------------
            // VALIDATE RESOURCE RATE
            // ----------------------------------------------------------------

            if (
                !rateByResourceRole.containsKey(
                    lineItem.Resource_Role__c
                )
            ) {

                throw new PSRatingException(
                    'No PS Resource Rate was found for Resource Role '
                    + lineItem.Resource_Role__c
                    + ' on Feature Line Item '
                    + lineItem.Id
                    + '.'
                );
            }


            // ----------------------------------------------------------------
            // GET RATE
            // ----------------------------------------------------------------

            Decimal resourceRate =
                rateByResourceRole.get(
                    lineItem.Resource_Role__c
                );


            // ----------------------------------------------------------------
            // CALCULATE BASE COST
            // ----------------------------------------------------------------

            Decimal estimateHours =
                nullToZero(
                    lineItem.Estimate_Hrs__c
                );

            Decimal baseCost =
                estimateHours * resourceRate;


            // ----------------------------------------------------------------
            // ADD OTHER COSTS
            // ----------------------------------------------------------------

            Decimal riskCost =
                nullToZero(
                    lineItem.Risk_Cost__c
                );

            Decimal hypercareCost =
                nullToZero(
                    lineItem.Hypercare_Cost__c
                );

            Decimal projectManagementCost =
                nullToZero(
                    lineItem.Project_Management_Cost__c
                );


            // ----------------------------------------------------------------
            // TOTAL
            // ----------------------------------------------------------------

            Decimal totalCost =
                baseCost
                + riskCost
                + hypercareCost
                + projectManagementCost;


            // ----------------------------------------------------------------
            // ROUND VALUES
            // ----------------------------------------------------------------

            resourceRate =
                resourceRate.setScale(2);

            baseCost =
                baseCost.setScale(2);

            totalCost =
                totalCost.setScale(2);


            // ----------------------------------------------------------------
            // PREPARE UPDATE
            // ----------------------------------------------------------------

            lineItemsToUpdate.add(
                new Project_Estimate_Feature_Line_Item__c(
                    Id = lineItem.Id,
                    Resource_Rate__c = resourceRate,
                    Base_Cost__c = baseCost,
                    Total_Cost__c = totalCost
                )
            );

            result.lineItemsCalculated++;
        }


        // ====================================================================
        // STEP 5 — UPDATE FEATURE LINE ITEMS
        // ====================================================================

        if (!lineItemsToUpdate.isEmpty()) {

            Database.SaveResult[] saveResults =
                Database.update(
                    lineItemsToUpdate,
                    false
                );

            for (
                Integer i = 0;
                i < saveResults.size();
                i++
            ) {

                Database.SaveResult saveResult =
                    saveResults[i];

                if (saveResult.isSuccess()) {

                    result.lineItemsUpdated++;

                } else {

                    result.lineItemsFailed++;
                    result.success = false;

                    String errorMessage = '';

                    for (
                        Database.Error error :
                        saveResult.getErrors()
                    ) {

                        if (errorMessage != '') {
                            errorMessage += ' | ';
                        }

                        errorMessage +=
                            error.getMessage();
                    }

                    result.errors.add(
                        'Feature Line Item '
                        + lineItemsToUpdate[i].Id
                        + ': '
                        + errorMessage
                    );
                }
            }
        }


        // ====================================================================
        // STEP 6 — BUILD RESPONSE
        // ====================================================================

        if (result.lineItemsFailed > 0) {

            result.success = false;

            result.message =
                'Feature Line Item rating completed with '
                + result.lineItemsFailed
                + ' failed update(s). '
                + String.join(
                    result.errors,
                    ' | '
                );

        } else {

            result.success = true;

            result.message =
                'Professional Services rating completed. '
                + result.lineItemsUpdated
                + ' Feature Line Item(s) updated.';
        }

        return result;
    }


    // ========================================================================
    // HELPER — NULL DECIMALS TO ZERO
    // ========================================================================

    private static Decimal nullToZero(
        Decimal value
    ) {

        return value == null
            ? 0
            : value;
    }


    // ========================================================================
    // INTERNAL RESULT
    // ========================================================================

    private class CalculationResult {

        Boolean success;
        String message;

        Integer lineItemsCalculated = 0;
        Integer lineItemsUpdated = 0;
        Integer lineItemsFailed = 0;

        List<String> errors =
            new List<String>();
    }


    // ========================================================================
    // CUSTOM EXCEPTION
    // ========================================================================

    public class PSRatingException
        extends Exception {
    }
}