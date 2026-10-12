/**
 * ============================================================================
 * PS_EstimateRatingCalculator
 * ============================================================================
 *
 * PURPOSE
 * -------
 * Recalculate Professional Services Feature Line Items for one or more
 * Project Estimates.
 *
 * This class is designed to be called directly from Salesforce Flow using
 * the invocable action:
 *
 *      Recalculate Professional Services Estimate
 *
 *
 * ============================================================================
 * DATA MODEL
 * ============================================================================
 *
 * Estimate:
 *      Project_Estimate__c
 *
 * Feature:
 *      Project_Estimate_Feature__c
 *
 * Feature -> Estimate:
 *      Estimate__c
 *
 * Feature Line Item:
 *      Project_Estimate_Feature_Line_Item__c
 *
 * Feature Line Item -> Feature:
 *      Feature__c
 *
 *
 * ============================================================================
 * FEATURE LINE ITEM FIELDS
 * ============================================================================
 *
 * Estimate Hours:
 *      Estimate_Hrs__c
 *
 * Include in Estimate:
 *      Include_in_Estimate__c
 *
 * Resource Role:
 *      Resource_Role__c
 *
 * Resource Rate:
 *      Resource_Rate__c
 *
 * Base Cost:
 *      Base_Cost__c
 *
 * Risk Cost:
 *      Risk_Cost__c
 *
 * HyperCare Cost:
 *      Hypercare_Cost__c
 *
 * Project Management Cost:
 *      Project_Management_Cost__c
 *
 * Total Cost:
 *      Total_Cost__c
 *
 *
 * ============================================================================
 * RESOURCE RATE SOURCE
 * ============================================================================
 *
 * Resource Rate Object:
 *      PS_Resource_Rate__c
 *
 * Resource:
 *      Resource__c
 *
 * Standard Rate:
 *      Standard_Rate__c
 *
 *
 * ============================================================================
 * CURRENT CALCULATION
 * ============================================================================
 *
 * Resource Rate =
 *      PS_Resource_Rate__c.Standard_Rate__c
 *
 * Base Cost =
 *      Estimate_Hrs__c * Resource_Rate__c
 *
 * Total Cost =
 *      Base_Cost__c
 *      + Risk_Cost__c
 *      + Hypercare_Cost__c
 *      + Project_Management_Cost__c
 *
 *
 * ============================================================================
 * FIXED STANDARD COSTS
 * ============================================================================
 *
 * Risk, HyperCare, and Project Management are treated as fixed standard costs.
 *
 * CURRENT IMPLEMENTATION:
 *      This class reads those values from the Feature Line Item.
 *
 *      Risk_Cost__c
 *      Hypercare_Cost__c
 *      Project_Management_Cost__c
 *
 * FUTURE CHANGE:
 *      When the authoritative Salesforce source of those standard costs is
 *      identified, amend the section labeled:
 *
 *          FIXED STANDARD COST COMPONENTS
 *
 *      Retrieve the values from the source object/configuration and populate
 *      the Feature Line Item fields there.
 *
 * Do not hard-code dollar values directly into this class.
 *
 *
 * ============================================================================
 * FEATURE TOTALS
 * ============================================================================
 *
 * This class DOES NOT update Feature totals.
 *
 * Feature totals should be handled by native Salesforce Roll-Up Summary fields.
 *
 *
 * ============================================================================
 * DISCOUNT
 * ============================================================================
 *
 * Discount is intentionally not implemented in this class yet.
 *
 * It is expected to be an Estimate-level calculation and should be added only
 * after the API fields and exact calculation basis are confirmed.
 *
 *
 * ============================================================================
 * FLOW USAGE
 * ============================================================================
 *
 * Flow should:
 *
 *  1. Save the Feature Line Item.
 *  2. Call the Apex action "Recalculate Professional Services Estimate".
 *  3. Pass the Estimate Id.
 *  4. Optionally pass Feature Id, changed Feature Line Item Id, and reason.
 *  5. Check the Success output.
 *
 * Flow does NOT need to:
 *
 *  - Query all Feature Line Items
 *  - Loop through Feature Line Items
 *  - Query resource rates
 *  - Calculate costs
 *  - Update Feature totals
 *
 *
 * ============================================================================
 * RECURSION WARNING
 * ============================================================================
 *
 * If this class is called from a record-triggered Flow on the Feature Line
 * Item object, configure Flow entry criteria so it reacts to rating INPUT
 * changes, such as:
 *
 *      Estimate_Hrs__c
 *      Resource_Role__c
 *      Include_in_Estimate__c
 *      Feature__c
 *
 * Do not cause the Flow to re-run simply because Apex updated:
 *
 *      Resource_Rate__c
 *      Base_Cost__c
 *      Total_Cost__c
 *
 * ============================================================================
 */
public with sharing class PS_EstimateRatingCalculator {


    // ========================================================================
    // FLOW REQUEST
    // ========================================================================

    public class Request {

        @InvocableVariable(
            required=true
            label='Estimate Id'
        )
        public Id estimateId;

        @InvocableVariable(
            label='Feature Id'
        )
        public Id featureId;

        @InvocableVariable(
            label='Changed Feature Line Item Id'
        )
        public Id changedFeatureLineItemId;

        @InvocableVariable(
            label='Calculation Reason'
        )
        public String calculationReason;
    }


    // ========================================================================
    // FLOW RESPONSE
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
        label='Recalculate Professional Services Estimate'
        description='Recalculates Professional Services Feature Line Items for the supplied Project Estimate.'
    )
    public static List<Response> recalculateEstimate(List<Request> requests) {

        List<Response> responses = new List<Response>();

        if (requests == null || requests.isEmpty()) {
            return responses;
        }


        // Collect Estimate Ids so the class remains bulk-safe.
        Set<Id> estimateIds = new Set<Id>();

        for (Request request : requests) {

            if (request != null && request.estimateId != null) {
                estimateIds.add(request.estimateId);
            }
        }


        // Return a Flow-friendly error when no Estimate Id was supplied.
        if (estimateIds.isEmpty()) {

            for (Request request : requests) {

                Response response = new Response();

                response.success = false;
                response.message = 'Estimate Id is required.';
                response.lineItemsCalculated = 0;
                response.lineItemsUpdated = 0;
                response.lineItemsFailed = 0;

                responses.add(response);
            }

            return responses;
        }


        Map<Id, CalculationResult> resultsByEstimateId;

        try {

            resultsByEstimateId = calculateEstimates(estimateIds);

        } catch (Exception ex) {

            // Return calculation failures to Flow instead of failing silently.
            for (Request request : requests) {

                Response response = new Response();

                response.success = false;
                response.message =
                    'Professional Services estimate calculation failed: '
                    + ex.getMessage();

                response.lineItemsCalculated = 0;
                response.lineItemsUpdated = 0;
                response.lineItemsFailed = 0;

                responses.add(response);
            }

            return responses;
        }


        // Convert internal results to Flow responses.
        for (Request request : requests) {

            Response response = new Response();

            if (
                request == null ||
                request.estimateId == null ||
                !resultsByEstimateId.containsKey(request.estimateId)
            ) {

                response.success = false;
                response.message = 'Estimate could not be recalculated.';
                response.lineItemsCalculated = 0;
                response.lineItemsUpdated = 0;
                response.lineItemsFailed = 0;

            } else {

                CalculationResult result =
                    resultsByEstimateId.get(request.estimateId);

                response.success = result.success;
                response.message = result.message;
                response.lineItemsCalculated = result.lineItemsCalculated;
                response.lineItemsUpdated = result.lineItemsUpdated;
                response.lineItemsFailed = result.lineItemsFailed;
            }

            responses.add(response);
        }


        return responses;
    }


    // ========================================================================
    // MAIN CALCULATION SERVICE
    // ========================================================================

    private static Map<Id, CalculationResult> calculateEstimates(
        Set<Id> estimateIds
    ) {

        Map<Id, CalculationResult> resultsByEstimateId =
            new Map<Id, CalculationResult>();


        // Initialize one result container per Estimate.
        for (Id estimateId : estimateIds) {

            CalculationResult result = new CalculationResult();

            result.success = true;
            result.message =
                'No Feature Line Items required calculation.';

            resultsByEstimateId.put(
                estimateId,
                result
            );
        }


        // ====================================================================
        // STEP 1 - RETRIEVE FEATURES
        // ====================================================================

        List<Project_Estimate_Feature__c> features = [
            SELECT
                Id,
                Estimate__c
            FROM Project_Estimate_Feature__c
            WHERE Estimate__c IN :estimateIds
        ];


        if (features.isEmpty()) {
            return resultsByEstimateId;
        }


        Set<Id> featureIds = new Set<Id>();

        Map<Id, Id> featureToEstimateId =
            new Map<Id, Id>();


        for (Project_Estimate_Feature__c feature : features) {

            featureIds.add(feature.Id);

            featureToEstimateId.put(
                feature.Id,
                feature.Estimate__c
            );
        }


        // ====================================================================
        // STEP 2 - RETRIEVE FEATURE LINE ITEMS
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
            WHERE Feature__c IN :featureIds
        ];


        if (lineItems.isEmpty()) {
            return resultsByEstimateId;
        }


        // ====================================================================
        // STEP 3 - COLLECT RESOURCE ROLES
        // ====================================================================
        //
        // Collect first, then query rates once.
        // Never perform a rate query inside the line-item loop.
        // ====================================================================

        Set<Id> resourceRoleIds = new Set<Id>();


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
        // STEP 4 - RETRIEVE RESOURCE RATES
        // ====================================================================
        //
        // If future rate selection depends on date, division, customer,
        // geography, etc., this is the main section to amend.
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


            for (PS_Resource_Rate__c resourceRate : resourceRates) {

                if (resourceRate.Resource__c == null) {
                    continue;
                }


                // Multiple rates for one Resource are ambiguous.
                if (
                    rateByResourceId.containsKey(
                        resourceRate.Resource__c
                    )
                ) {

                    throw new PSRatingException(
                        'Multiple PS Resource Rate records were found '
                        + 'for Resource '
                        + resourceRate.Resource__c
                        + '. Each Resource must resolve to one standard rate.'
                    );
                }


                if (resourceRate.Standard_Rate__c == null) {

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
        // STEP 5 - CALCULATE FEATURE LINE ITEMS
        // ====================================================================

        List<Project_Estimate_Feature_Line_Item__c> lineItemsToUpdate =
            new List<Project_Estimate_Feature_Line_Item__c>();


        // Parallel list so each SaveResult can be tied back to its Estimate.
        List<Id> updateEstimateIds = new List<Id>();


        for (
            Project_Estimate_Feature_Line_Item__c lineItem :
            lineItems
        ) {

            Id estimateId =
                featureToEstimateId.get(lineItem.Feature__c);


            if (estimateId == null) {
                continue;
            }


            CalculationResult estimateResult =
                resultsByEstimateId.get(estimateId);


            // ----------------------------------------------------------------
            // EXCLUDED LINE ITEM
            // ----------------------------------------------------------------
            //
            // Excluded lines should not contribute cost to Feature roll-ups.
            // Fixed cost fields are preserved for possible later re-inclusion.
            // ----------------------------------------------------------------

            if (lineItem.Include_in_Estimate__c != true) {

                Project_Estimate_Feature_Line_Item__c updateRecord =
                    new Project_Estimate_Feature_Line_Item__c(
                        Id = lineItem.Id,
                        Resource_Rate__c = null,
                        Base_Cost__c = 0,
                        Total_Cost__c = 0
                    );


                lineItemsToUpdate.add(updateRecord);
                updateEstimateIds.add(estimateId);

                estimateResult.lineItemsCalculated++;

                continue;
            }


            // ----------------------------------------------------------------
            // VALIDATE RESOURCE ROLE
            // ----------------------------------------------------------------

            if (lineItem.Resource_Role__c == null) {

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


            // ----------------------------------------------------------------
            // BASE COST
            // ----------------------------------------------------------------
            //
            // Base Cost = Estimate Hours * Resource Rate
            // ----------------------------------------------------------------

            Decimal baseCost =
                estimateHours * resourceRate;


            // ----------------------------------------------------------------
            // FIXED STANDARD COST COMPONENTS
            // ----------------------------------------------------------------
            //
            // CURRENT:
            // Read fixed costs already stored on the Feature Line Item.
            //
            // FUTURE:
            // Replace this section when the authoritative standard-cost source
            // is identified.
            //
            // Do not hard-code standard dollar amounts here.
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
            // TOTAL COST
            // ----------------------------------------------------------------

            Decimal totalCost =
                baseCost
                + riskCost
                + hypercareCost
                + projectManagementCost;


            // Round currency values.
            resourceRate = resourceRate.setScale(2);
            baseCost = baseCost.setScale(2);
            totalCost = totalCost.setScale(2);


            // ----------------------------------------------------------------
            // BUILD UPDATE RECORD
            // ----------------------------------------------------------------
            //
            // Only update fields owned by this calculation.
            // Do not overwrite user-entered hours or Resource Role.
            // ----------------------------------------------------------------

            Project_Estimate_Feature_Line_Item__c updateRecord =
                new Project_Estimate_Feature_Line_Item__c(
                    Id = lineItem.Id,
                    Resource_Rate__c = resourceRate,
                    Base_Cost__c = baseCost,
                    Total_Cost__c = totalCost
                );


            lineItemsToUpdate.add(updateRecord);
            updateEstimateIds.add(estimateId);

            estimateResult.lineItemsCalculated++;
        }


        // ====================================================================
        // STEP 6 - BULK UPDATE FEATURE LINE ITEMS
        // ====================================================================
        //
        // allOrNone=false lets us capture individual failures.
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

                Id estimateId =
                    updateEstimateIds[i];

                CalculationResult estimateResult =
                    resultsByEstimateId.get(estimateId);


                if (saveResult.isSuccess()) {

                    estimateResult.lineItemsUpdated++;

                } else {

                    estimateResult.lineItemsFailed++;
                    estimateResult.success = false;


                    String errorMessage = '';


                    for (
                        Database.Error error :
                        saveResult.getErrors()
                    ) {

                        if (errorMessage != '') {
                            errorMessage += ' | ';
                        }

                        errorMessage += error.getMessage();
                    }


                    estimateResult.errors.add(
                        'Feature Line Item '
                        + lineItemsToUpdate[i].Id
                        + ': '
                        + errorMessage
                    );
                }
            }
        }


        // ====================================================================
        // STEP 7 - FINALIZE FLOW RESPONSE
        // ====================================================================
        //
        // Feature totals recalculate through native Roll-Up Summary fields.
        // Do not add Feature total DML here unless a future rule genuinely
        // cannot be handled natively.
        // ====================================================================

        for (Id estimateId : resultsByEstimateId.keySet()) {

            CalculationResult result =
                resultsByEstimateId.get(estimateId);


            if (result.lineItemsFailed > 0) {

                result.success = false;

                result.message =
                    'Estimate recalculation completed with '
                    + result.lineItemsFailed
                    + ' failed Feature Line Item update(s). '
                    + String.join(
                        result.errors,
                        ' | '
                    );

            } else if (result.lineItemsCalculated > 0) {

                result.success = true;

                result.message =
                    'Professional Services Estimate recalculated. '
                    + result.lineItemsUpdated
                    + ' Feature Line Item(s) updated.';

            } else {

                result.success = true;

                result.message =
                    'No Feature Line Items required calculation.';
            }
        }


        return resultsByEstimateId;
    }


    // ========================================================================
    // NULL-TO-ZERO HELPER
    // ========================================================================

    private static Decimal nullToZero(Decimal value) {

        if (value == null) {
            return 0;
        }

        return value;
    }


    // ========================================================================
    // INTERNAL RESULT CONTAINER
    // ========================================================================

    private class CalculationResult {

        Boolean success;
        String message;

        Integer lineItemsCalculated = 0;
        Integer lineItemsUpdated = 0;
        Integer lineItemsFailed = 0;

        List<String> errors = new List<String>();
    }


    // ========================================================================
    // BUSINESS CALCULATION EXCEPTION
    // ========================================================================

    public class PSRatingException extends Exception {}
}