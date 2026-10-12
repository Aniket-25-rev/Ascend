/**
 * ============================================================================
 * PS_EstimateRatingCalculator
 * ============================================================================
 *
 * PURPOSE
 * -------
 * Rate one or more Professional Services Feature Line Items after Flow has
 * created or updated them.
 *
 * This class is designed to support two Flow paths:
 *
 * ADD PATH
 * --------
 * Flow creates one Feature Line Item and passes:
 *
 *      Feature Line Item Id
 *
 * EDIT PATH
 * ---------
 * Flow updates one or more Feature Line Items from an editable Data Table and
 * passes:
 *
 *      Feature Line Item Ids
 *
 *
 * ============================================================================
 * FLOW RESPONSIBILITY
 * ============================================================================
 *
 * Flow owns:
 *
 *      - User interaction
 *      - Creating the Feature Line Item
 *      - Updating user-entered Feature Line Item fields
 *      - Passing the saved record Id or Id collection to Apex
 *
 * Flow should save the Feature Line Item BEFORE calling this Apex class.
 *
 *
 * ============================================================================
 * APEX RESPONSIBILITY
 * ============================================================================
 *
 * Apex owns:
 *
 *      1. Querying the supplied Feature Line Item records
 *      2. Collecting the selected Resource Roles
 *      3. Retrieving the applicable Resource Rates
 *      4. Calculating Base Cost
 *      5. Including existing Risk, HyperCare and PM costs
 *      6. Calculating Total Cost
 *      7. Updating the Feature Line Item records
 *
 *
 * ============================================================================
 * DATA MODEL
 * ============================================================================
 *
 * Feature Line Item:
 *
 *      Project_Estimate_Feature_Line_Item__c
 *
 *
 * FEATURE LINE ITEM FIELDS USED
 * -----------------------------
 *
 * Estimated Hours:
 *
 *      Estimate_Hrs__c
 *
 * Include in Estimate:
 *
 *      Include_in_Estimate__c
 *
 * Resource Role:
 *
 *      Resource_Role__c
 *
 * Resource Rate:
 *
 *      Resource_Rate__c
 *
 * Base Cost:
 *
 *      Base_Cost__c
 *
 * Risk Cost:
 *
 *      Risk_Cost__c
 *
 * HyperCare Cost:
 *
 *      Hypercare_Cost__c
 *
 * Project Management Cost:
 *
 *      Project_Management_Cost__c
 *
 * Total Cost:
 *
 *      Total_Cost__c
 *
 *
 * ============================================================================
 * RESOURCE RATE SOURCE
 * ============================================================================
 *
 * Rate Object:
 *
 *      PS_Resource_Rate__c
 *
 * Resource:
 *
 *      Resource__c
 *
 * Standard Rate:
 *
 *      Standard_Rate__c
 *
 *
 * ============================================================================
 * CALCULATION
 * ============================================================================
 *
 * Resource Rate =
 *
 *      PS_Resource_Rate__c.Standard_Rate__c
 *
 *
 * Base Cost =
 *
 *      Estimate_Hrs__c * Resource_Rate__c
 *
 *
 * Total Cost =
 *
 *      Base_Cost__c
 *      + Risk_Cost__c
 *      + Hypercare_Cost__c
 *      + Project_Management_Cost__c
 *
 *
 * ============================================================================
 * IMPORTANT DESIGN NOTE
 * ============================================================================
 *
 * This class rates ONLY the Feature Line Items supplied by Flow.
 *
 * It does NOT recalculate every Feature Line Item on the Estimate.
 *
 * This is intentional:
 *
 *      ADD = rate the newly created line
 *
 *      EDIT = rate only the line(s) actually changed
 *
 * This keeps the process efficient as Estimates grow.
 *
 *
 * ============================================================================
 * FEATURE TOTALS
 * ============================================================================
 *
 * This class does NOT calculate Feature totals.
 *
 * Native Salesforce Roll-Up Summary fields should aggregate the persisted
 * Feature Line Item values.
 *
 *
 * ============================================================================
 * FIXED COST COMPONENTS
 * ============================================================================
 *
 * Risk, HyperCare and Project Management currently use the values already
 * stored on the Feature Line Item:
 *
 *      Risk_Cost__c
 *      Hypercare_Cost__c
 *      Project_Management_Cost__c
 *
 * If their authoritative source changes later, amend the section labeled:
 *
 *      FIXED COST COMPONENTS
 *
 *
 * ============================================================================
 */
public with sharing class PS_EstimateRatingCalculator1 {


    // ========================================================================
    // FLOW INPUT
    // ========================================================================
    //
    // ADD PATH:
    //
    //      featureLineItemId
    //
    // EDIT PATH:
    //
    //      featureLineItemIds
    //
    // Flow may supply either input.
    //
    // If both are supplied, Apex combines them into one unique Set<Id>.
    // ========================================================================

    public class Request {

        @InvocableVariable(
            label='Feature Line Item Id'
        )
        public Id featureLineItemId;


        @InvocableVariable(
            label='Feature Line Item Ids'
        )
        public List<Id> featureLineItemIds;
    }


    // ========================================================================
    // FLOW OUTPUT
    // ========================================================================

    public class Response {

        @InvocableVariable(
            label='Success'
        )
        public Boolean success;


        @InvocableVariable(
            label='Message'
        )
        public String message;


        @InvocableVariable(
            label='Line Items Calculated'
        )
        public Integer lineItemsCalculated;


        @InvocableVariable(
            label='Line Items Updated'
        )
        public Integer lineItemsUpdated;


        @InvocableVariable(
            label='Line Items Failed'
        )
        public Integer lineItemsFailed;
    }


    // ========================================================================
    // FLOW ENTRY POINT
    // ========================================================================

    @InvocableMethod(
        label='Rate Professional Services Feature Line Items'
        description='Rates one Feature Line Item or a collection of Feature Line Items and updates the calculated pricing fields.'
    )
    public static List<Response> rateFeatureLineItems(
        List<Request> requests
    ) {

        List<Response> responses = new List<Response>();


        if (requests == null || requests.isEmpty()) {
            return responses;
        }


        // ====================================================================
        // NORMALIZE FLOW INPUTS
        // ====================================================================
        //
        // Whether Flow sends one Id or many Ids, Apex reduces everything to
        // one unique collection for processing.
        // ====================================================================

        Set<Id> allLineItemIds = new Set<Id>();


        for (Request request : requests) {

            if (request == null) {
                continue;
            }


            // ADD PATH
            if (request.featureLineItemId != null) {

                allLineItemIds.add(
                    request.featureLineItemId
                );
            }


            // EDIT PATH
            if (
                request.featureLineItemIds != null &&
                !request.featureLineItemIds.isEmpty()
            ) {

                allLineItemIds.addAll(
                    request.featureLineItemIds
                );
            }
        }


        // ====================================================================
        // VALIDATE INPUT
        // ====================================================================

        if (allLineItemIds.isEmpty()) {

            for (Request request : requests) {

                Response response = new Response();

                response.success = false;

                response.message =
                    'A Feature Line Item Id or Feature Line Item Id collection is required.';

                response.lineItemsCalculated = 0;
                response.lineItemsUpdated = 0;
                response.lineItemsFailed = 0;

                responses.add(response);
            }

            return responses;
        }


        // ====================================================================
        // RATE THE SUPPLIED FEATURE LINE ITEMS
        // ====================================================================

        CalculationResult result;


        try {

            result =
                calculateAndUpdateLineItems(
                    allLineItemIds
                );

        } catch (Exception ex) {

            result = new CalculationResult();

            result.success = false;

            result.message =
                'Professional Services Feature Line Item rating failed: '
                + ex.getMessage();
        }


        // ====================================================================
        // RETURN FLOW RESPONSE
        // ====================================================================
        //
        // Most Screen Flow invocations will contain one Request.
        //
        // If Salesforce supplies multiple Request wrappers in the same
        // transaction, the rating operation is still performed once against
        // the combined Id set.
        // ====================================================================

        for (Request request : requests) {

            Response response = new Response();

            response.success =
                result.success;

            response.message =
                result.message;

            response.lineItemsCalculated =
                result.lineItemsCalculated;

            response.lineItemsUpdated =
                result.lineItemsUpdated;

            response.lineItemsFailed =
                result.lineItemsFailed;

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

        CalculationResult result =
            new CalculationResult();


        result.success = true;


        // ====================================================================
        // STEP 1 - QUERY ONLY THE FEATURE LINE ITEMS PASSED BY FLOW
        // ====================================================================

        List<Project_Estimate_Feature_Line_Item__c> lineItems = [

            SELECT

                Id,
                Feature__c,
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
                'No Feature Line Item records were found for the supplied Ids.';

            return result;
        }


        // ====================================================================
        // STEP 2 - COLLECT RESOURCE ROLES
        // ====================================================================
        //
        // Gather every Resource Role first so the rate object is queried once.
        // ====================================================================

        Set<Id> resourceRoleIds =
            new Set<Id>();


        for (
            Project_Estimate_Feature_Line_Item__c lineItem :
            lineItems
        ) {

            if (
                lineItem.Include_in_Estimate__c == true &&
                lineItem.Resource_Role__c != null
            ) {

                resourceRoleIds.add(
                    lineItem.Resource_Role__c
                );
            }
        }


        // ====================================================================
        // STEP 3 - QUERY RESOURCE RATES ONCE
        // ====================================================================
        //
        // The Map allows each Feature Line Item calculation to perform a fast
        // in-memory rate lookup.
        //
        // If rate selection later depends upon Effective Date, Division,
        // Customer, Rate Card, etc., amend this section.
        // ====================================================================

        Map<Id, Decimal> rateByResourceId =
            new Map<Id, Decimal>();


        if (!resourceRoleIds.isEmpty()) {

            List<PS_Resource_Rate__c> resourceRates = [

                SELECT

                    Id,
                    Resource__c,
                    Standard_Rate__c

                FROM PS_Resource_Rate__c

                WHERE Resource__c IN :resourceRoleIds
            ];


            for (
                PS_Resource_Rate__c resourceRate :
                resourceRates
            ) {

                if (resourceRate.Resource__c == null) {
                    continue;
                }


                // ------------------------------------------------------------
                // DUPLICATE RATE VALIDATION
                // ------------------------------------------------------------
                //
                // We should never arbitrarily choose between two applicable
                // rates for the same resource.
                // ------------------------------------------------------------

                if (
                    rateByResourceId.containsKey(
                        resourceRate.Resource__c
                    )
                ) {

                    throw new PSRatingException(
                        'Multiple PS Resource Rate records were found '
                        + 'for Resource '
                        + resourceRate.Resource__c
                        + '.'
                    );
                }


                if (
                    resourceRate.Standard_Rate__c == null
                ) {

                    throw new PSRatingException(
                        'PS Resource Rate '
                        + resourceRate.Id
                        + ' does not contain a Standard Rate.'
                    );
                }


                rateByResourceId.put(
                    resourceRate.Resource__c,
                    resourceRate.Standard_Rate__c
                );
            }
        }


        // ====================================================================
        // STEP 4 - CALCULATE FEATURE LINE ITEMS
        // ====================================================================

        List<Project_Estimate_Feature_Line_Item__c>
            lineItemsToUpdate =
            new List<Project_Estimate_Feature_Line_Item__c>();


        for (
            Project_Estimate_Feature_Line_Item__c lineItem :
            lineItems
        ) {


            // ----------------------------------------------------------------
            // EXCLUDED FEATURE LINE ITEM
            // ----------------------------------------------------------------
            //
            // If the Feature Line Item is not included in the Estimate,
            // calculated financial contribution is zero.
            //
            // Risk / HyperCare / PM input values are left intact.
            // ----------------------------------------------------------------

            if (
                lineItem.Include_in_Estimate__c != true
            ) {

                Project_Estimate_Feature_Line_Item__c updateRecord =
                    new Project_Estimate_Feature_Line_Item__c(

                        Id = lineItem.Id,

                        Resource_Rate__c = null,

                        Base_Cost__c = 0,

                        Total_Cost__c = 0
                    );


                lineItemsToUpdate.add(
                    updateRecord
                );


                result.lineItemsCalculated++;

                continue;
            }


            // ----------------------------------------------------------------
            // VALIDATE RESOURCE ROLE
            // ----------------------------------------------------------------

            if (
                lineItem.Resource_Role__c == null
            ) {

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
                !rateByResourceId.containsKey(
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


            Decimal resourceRate =
                rateByResourceId.get(
                    lineItem.Resource_Role__c
                );


            Decimal estimateHours =
                nullToZero(
                    lineItem.Estimate_Hrs__c
                );


            // =================================================================
            // BASE COST
            // =================================================================
            //
            // Base Cost =
            //
            //      Estimate Hours * Resource Rate
            // =================================================================

            Decimal baseCost =
                estimateHours
                * resourceRate;


            // =================================================================
            // FIXED COST COMPONENTS
            // =================================================================
            //
            // Current implementation reads these amounts directly from the
            // Feature Line Item.
            //
            // If their source changes later, amend only this section.
            // =================================================================

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


            // =================================================================
            // TOTAL COST
            // =================================================================

            Decimal totalCost =
                baseCost
                + riskCost
                + hypercareCost
                + projectManagementCost;


            // =================================================================
            // ROUND CURRENCY
            // =================================================================

            resourceRate =
                resourceRate.setScale(
                    2
                );


            baseCost =
                baseCost.setScale(
                    2
                );


            totalCost =
                totalCost.setScale(
                    2
                );


            // =================================================================
            // BUILD SPARSE UPDATE RECORD
            // =================================================================
            //
            // Only calculated fields are updated.
            //
            // Apex does not overwrite the fields that Flow/user populated.
            // =================================================================

            Project_Estimate_Feature_Line_Item__c updateRecord =
                new Project_Estimate_Feature_Line_Item__c(

                    Id = lineItem.Id,

                    Resource_Rate__c =
                        resourceRate,

                    Base_Cost__c =
                        baseCost,

                    Total_Cost__c =
                        totalCost
                );


            lineItemsToUpdate.add(
                updateRecord
            );


            result.lineItemsCalculated++;
        }


        // ====================================================================
        // STEP 5 - BULK UPDATE
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


                if (
                    saveResult.isSuccess()
                ) {

                    result.lineItemsUpdated++;

                } else {

                    result.lineItemsFailed++;

                    result.success = false;


                    String errorMessage = '';


                    for (
                        Database.Error error :
                        saveResult.getErrors()
                    ) {

                        if (
                            errorMessage != ''
                        ) {

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
        // STEP 6 - BUILD FLOW MESSAGE
        // ====================================================================

        if (
            result.lineItemsFailed > 0
        ) {

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
    // NULL-TO-ZERO HELPER
    // ========================================================================

    private static Decimal nullToZero(
        Decimal value
    ) {

        if (
            value == null
        ) {

            return 0;
        }


        return value;
    }


    // ========================================================================
    // INTERNAL RESULT OBJECT
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
    // BUSINESS EXCEPTION
    // ========================================================================

    public class PSRatingException
        extends Exception {
    }
}