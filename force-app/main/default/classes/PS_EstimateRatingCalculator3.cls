/**
 * ============================================================================
 * PS_EstimateRatingCalculator1
 * ============================================================================
 *
 * PURPOSE
 * -------
 * Recalculate Professional Services pricing for an Estimate after a Feature
 * Line Item is created or edited.
 *
 * FLOW INPUT
 * ----------
 * ONE Flow-visible input:
 *
 *      Feature Line Item Id
 *
 * PROCESS
 * -------
 * 1. Find the triggering Feature Line Item.
 * 2. Find its Estimate.
 * 3. Query ALL included FLIs for that Estimate.
 * 4. Calculate total Base / Engineering Hours.
 * 5. Determine the applicable Project Management percentage.
 * 6. Retrieve Resource Rates.
 * 7. Calculate and populate each FLI:
 *
 *      Resource Rate
 *      Base Cost
 *
 *      Project Management %
 *      Project Management Hours
 *      Project Management Cost
 *
 *      Hypercare %
 *      Hypercare Hours
 *      Hypercare Cost
 *
 *      Documentation %
 *      Documentation Hours
 *      Documentation Cost
 *
 *      Risk %
 *      Risk Hours
 *      Risk Cost
 *
 * 8. Salesforce Formula fields calculate FLI Total Hours / Total Cost.
 * 9. Salesforce Roll-Up Summary fields aggregate FLI -> Feature -> Estimate.
 *
 * IMPORTANT
 * ---------
 * Total_Cost__c and Total_Hours__c are NOT updated by Apex.
 * They should be Formula fields.
 *
 * PM LOGIC
 * --------
 * Total Estimate Base Hours:
 *
 *      0 - 7       = 0%
 *      8 - 19      = 10%
 *      20 - 39     = 15%
 *      40 - 119    = 20%
 *      120+        = 25%
 *
 * If Estimate.PM_Percent__c contains a value, that value is used as an
 * override. This gives the business a way to apply the spreadsheet's
 * complexity adjustment without hard-coding complexity-question fields
 * into this class.
 *
 * KICKOFF
 * -------
 * An FLI whose Name is "Kickoff" receives 2 PM hours when the Estimate has
 * engineering hours.
 * ============================================================================
 */
public with sharing class PS_EstimateRatingCalculator3 {

    // ========================================================================
    // FLOW INPUT
    // ========================================================================

    public class Request {

        @InvocableVariable(
            label='Feature Line Item Id'
            description='Id of the saved Professional Services Feature Line Item.'
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
        description='Receives one Feature Line Item Id and recalculates Professional Services pricing for all included FLIs on the Estimate.'
    )
    public static List<Response> rateFeatureLineItems(List<Request> requests) {

        List<Response> responses = new List<Response>();

        if (requests == null || requests.isEmpty()) {
            return responses;
        }

        Set<Id> triggerLineItemIds = new Set<Id>();

        for (Request request : requests) {

            if (
                request != null &&
                request.featureLineItemId != null
            ) {
                triggerLineItemIds.add(request.featureLineItemId);
            }
        }

        if (triggerLineItemIds.isEmpty()) {

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

            result = calculateEstimates(triggerLineItemIds);

        } catch (Exception ex) {

            result = new CalculationResult();

            result.success = false;
            result.message =
                'Professional Services pricing failed: '
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
    // MAIN CALCULATION SERVICE
    // ========================================================================

    private static CalculationResult calculateEstimates(
        Set<Id> triggerLineItemIds
    ) {

        CalculationResult result = new CalculationResult();
        result.success = true;


        // ====================================================================
        // STEP 1
        // FIND THE ESTIMATE(S) FOR THE TRIGGERING FEATURE LINE ITEM(S)
        // ====================================================================

        List<Project_Estimate_Feature_Line_Item__c> triggeringLineItems = [
            SELECT
                Id,
                Estimate__c
            FROM Project_Estimate_Feature_Line_Item__c
            WHERE Id IN :triggerLineItemIds
        ];


        if (triggeringLineItems.isEmpty()) {

            result.success = false;
            result.message =
                'No Feature Line Item was found for the supplied Id.';

            return result;
        }


        Set<Id> estimateIds = new Set<Id>();

        for (
            Project_Estimate_Feature_Line_Item__c lineItem :
            triggeringLineItems
        ) {

            if (lineItem.Estimate__c == null) {

                throw new PSRatingException(
                    'Feature Line Item '
                    + lineItem.Id
                    + ' does not have an Estimate.'
                );
            }

            estimateIds.add(lineItem.Estimate__c);
        }


        // ====================================================================
        // STEP 2
        // QUERY ESTIMATE PRICING ASSUMPTIONS
        // ====================================================================

        Map<Id, Project_Estimate__c> estimatesById =
            new Map<Id, Project_Estimate__c>([
                SELECT
                    Id,
                    Hypercare_Percent__c,
                    Documentation_Percent__c,
                    Risk_Percent__c,
                    PM_Percent__c
                FROM Project_Estimate__c
                WHERE Id IN :estimateIds
            ]);


        // ====================================================================
        // STEP 3
        // QUERY ALL FLIs FOR THE ESTIMATE
        //
        // We query all FLIs because adding/editing one FLI may change the
        // Estimate's PM tier and therefore require every included FLI to be
        // recalculated.
        // ====================================================================

        List<Project_Estimate_Feature_Line_Item__c> allLineItems = [
            SELECT
                Id,
                Name,
                Feature__c,
                Estimate__c,
                Estimate_Hrs__c,
                Include_in_Estimate__c,
                Resource_Role__c,

                Resource_Rate__c,
                Base_Cost__c,

                Project_Management_Percent__c,
                Project_Management_Hours__c,
                Project_Management_Cost__c,

                Hypercare_Percent__c,
                Hypercare_Hours__c,
                Hypercare_Cost__c,

                Documentation_Percent__c,
                Documentation_Hours__c,
                Documentation_Cost__c,

                Risk_Percent__c,
                Risk_Hours__c,
                Risk_Cost__c

            FROM Project_Estimate_Feature_Line_Item__c

            WHERE Estimate__c IN :estimateIds
        ];


        // ====================================================================
        // STEP 4
        // CALCULATE TOTAL BASE / ENGINEERING HOURS PER ESTIMATE
        // ====================================================================

        Map<Id, Decimal> baseHoursByEstimate =
            new Map<Id, Decimal>();

        for (
            Project_Estimate_Feature_Line_Item__c lineItem :
            allLineItems
        ) {

            if (lineItem.Include_in_Estimate__c != true) {
                continue;
            }

            Decimal currentTotal =
                baseHoursByEstimate.containsKey(lineItem.Estimate__c)
                ? baseHoursByEstimate.get(lineItem.Estimate__c)
                : 0;

            currentTotal += nullToZero(lineItem.Estimate_Hrs__c);

            baseHoursByEstimate.put(
                lineItem.Estimate__c,
                currentTotal
            );
        }


        // ====================================================================
        // STEP 5
        // DETERMINE PM PERCENTAGE PER ESTIMATE
        // ====================================================================

        Map<Id, Decimal> pmPercentByEstimate =
            new Map<Id, Decimal>();

        for (Id estimateId : estimateIds) {

            Project_Estimate__c estimate =
                estimatesById.get(estimateId);

            if (estimate == null) {

                throw new PSRatingException(
                    'Estimate '
                    + estimateId
                    + ' could not be found.'
                );
            }


            Decimal baseHours =
                baseHoursByEstimate.containsKey(estimateId)
                ? baseHoursByEstimate.get(estimateId)
                : 0;


            Decimal pmPercent;


            // ---------------------------------------------------------------
            // MANUAL / COMPLEXITY OVERRIDE
            // ---------------------------------------------------------------
            //
            // If PM_Percent__c is populated on the Estimate, use it.
            // Otherwise determine the percentage from the standard hours tier.
            // ---------------------------------------------------------------

            if (estimate.PM_Percent__c != null) {

                pmPercent = estimate.PM_Percent__c;

            } else {

                pmPercent = calculateStandardPMPercent(baseHours);
            }


            pmPercentByEstimate.put(
                estimateId,
                pmPercent
            );
        }


        // ====================================================================
        // STEP 6
        // COLLECT RESOURCE ROLES
        // ====================================================================

        Set<String> resourceRoles = new Set<String>();

        for (
            Project_Estimate_Feature_Line_Item__c lineItem :
            allLineItems
        ) {

            if (
                lineItem.Include_in_Estimate__c == true &&
                String.isNotBlank(lineItem.Resource_Role__c)
            ) {

                resourceRoles.add(
                    lineItem.Resource_Role__c
                );
            }
        }


        // ====================================================================
        // STEP 7
        // RETRIEVE STANDARD RESOURCE RATES
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
        // STEP 8
        // CALCULATE EACH FEATURE LINE ITEM
        // ====================================================================

        List<Project_Estimate_Feature_Line_Item__c> lineItemsToUpdate =
            new List<Project_Estimate_Feature_Line_Item__c>();


        for (
            Project_Estimate_Feature_Line_Item__c lineItem :
            allLineItems
        ) {


            // ================================================================
            // EXCLUDED LINE ITEM
            // ================================================================

            if (lineItem.Include_in_Estimate__c != true) {

                Project_Estimate_Feature_Line_Item__c updateLineItem =
                    new Project_Estimate_Feature_Line_Item__c(
                        Id = lineItem.Id
                    );

                updateLineItem.Resource_Rate__c = null;
                updateLineItem.Base_Cost__c = 0;

                updateLineItem.Project_Management_Percent__c = 0;
                updateLineItem.Project_Management_Hours__c = 0;
                updateLineItem.Project_Management_Cost__c = 0;

                updateLineItem.Hypercare_Percent__c = 0;
                updateLineItem.Hypercare_Hours__c = 0;
                updateLineItem.Hypercare_Cost__c = 0;

                updateLineItem.Documentation_Percent__c = 0;
                updateLineItem.Documentation_Hours__c = 0;
                updateLineItem.Documentation_Cost__c = 0;

                updateLineItem.Risk_Percent__c = 0;
                updateLineItem.Risk_Hours__c = 0;
                updateLineItem.Risk_Cost__c = 0;

                lineItemsToUpdate.add(updateLineItem);

                result.lineItemsCalculated++;

                continue;
            }


            // ================================================================
            // VALIDATE RESOURCE ROLE
            // ================================================================

            if (String.isBlank(lineItem.Resource_Role__c)) {

                throw new PSRatingException(
                    'Feature Line Item '
                    + lineItem.Id
                    + ' is included in the Estimate but does not have '
                    + 'a Resource Role.'
                );
            }


            // ================================================================
            // VALIDATE RESOURCE RATE
            // ================================================================

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


            Project_Estimate__c estimate =
                estimatesById.get(lineItem.Estimate__c);


            Decimal resourceRate =
                rateByResourceRole.get(
                    lineItem.Resource_Role__c
                );


            Decimal baseHours =
                nullToZero(
                    lineItem.Estimate_Hrs__c
                );


            // ================================================================
            // BASE COST
            // ================================================================

            Decimal baseCost =
                baseHours * resourceRate;


            // ================================================================
            // PROJECT MANAGEMENT
            // ================================================================

            Decimal pmPercent =
                pmPercentByEstimate.get(
                    lineItem.Estimate__c
                );


            Decimal pmHours;


            /*
             * Spreadsheet special rule:
             *
             * Kickoff receives 2 PM hours when the project contains
             * engineering hours.
             */
            if (
                String.isNotBlank(lineItem.Name) &&
                lineItem.Name.trim().toLowerCase() == 'kickoff' &&
                baseHoursByEstimate.get(lineItem.Estimate__c) > 0
            ) {

                pmHours = 2;

            } else {

                pmHours =
                    baseHours * pmPercent;
            }


            Decimal pmCost =
                pmHours * resourceRate;


            // ================================================================
            // HYPERCARE
            // ================================================================

            Decimal hypercarePercent =
                nullToZero(
                    estimate.Hypercare_Percent__c
                );


            Decimal hypercareHours =
                baseHours * hypercarePercent;


            Decimal hypercareCost =
                hypercareHours * resourceRate;


            // ================================================================
            // DOCUMENTATION
            // ================================================================

            Decimal documentationPercent =
                nullToZero(
                    estimate.Documentation_Percent__c
                );


            Decimal documentationHours =
                baseHours * documentationPercent;


            Decimal documentationCost =
                documentationHours * resourceRate;


            // ================================================================
            // STAFFED HOURS
            //
            // Risk is applied AFTER the other staffing components.
            // ================================================================

            Decimal staffedHours =
                baseHours
                + pmHours
                + hypercareHours
                + documentationHours;


            // ================================================================
            // RISK
            // ================================================================

            Decimal riskPercent =
                nullToZero(
                    estimate.Risk_Percent__c
                );


            Decimal riskHours =
                staffedHours * riskPercent;


            Decimal riskCost =
                riskHours * resourceRate;


            // ================================================================
            // ROUND MONEY ONLY
            //
            // Hours are intentionally not rounded here because rounding each
            // FLI would distort aggregate Hypercare / Documentation / Risk.
            // ================================================================

            resourceRate =
                resourceRate.setScale(2);


            baseCost =
                baseCost.setScale(2);


            pmCost =
                pmCost.setScale(2);


            hypercareCost =
                hypercareCost.setScale(2);


            documentationCost =
                documentationCost.setScale(2);


            riskCost =
                riskCost.setScale(2);


            // ================================================================
            // BUILD SPARSE UPDATE
            // ================================================================

            Project_Estimate_Feature_Line_Item__c updateLineItem =
                new Project_Estimate_Feature_Line_Item__c(
                    Id = lineItem.Id
                );


            updateLineItem.Resource_Rate__c =
                resourceRate;


            updateLineItem.Base_Cost__c =
                baseCost;


            // PM
            updateLineItem.Project_Management_Percent__c =
                pmPercent;

            updateLineItem.Project_Management_Hours__c =
                pmHours;

            updateLineItem.Project_Management_Cost__c =
                pmCost;


            // Hypercare
            updateLineItem.Hypercare_Percent__c =
                hypercarePercent;

            updateLineItem.Hypercare_Hours__c =
                hypercareHours;

            updateLineItem.Hypercare_Cost__c =
                hypercareCost;


            // Documentation
            updateLineItem.Documentation_Percent__c =
                documentationPercent;

            updateLineItem.Documentation_Hours__c =
                documentationHours;

            updateLineItem.Documentation_Cost__c =
                documentationCost;


            // Risk
            updateLineItem.Risk_Percent__c =
                riskPercent;

            updateLineItem.Risk_Hours__c =
                riskHours;

            updateLineItem.Risk_Cost__c =
                riskCost;


            lineItemsToUpdate.add(
                updateLineItem
            );


            result.lineItemsCalculated++;
        }


        // ====================================================================
        // STEP 9
        // UPDATE FLIs
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
        // STEP 10
        // BUILD FLOW RESPONSE
        // ====================================================================

        if (result.lineItemsFailed > 0) {

            result.success = false;

            result.message =
                'Professional Services pricing completed with '
                + result.lineItemsFailed
                + ' failed update(s). '
                + String.join(
                    result.errors,
                    ' | '
                );

        } else {

            result.success = true;

            result.message =
                'Professional Services pricing completed. '
                + result.lineItemsUpdated
                + ' Feature Line Item(s) recalculated.';
        }


        return result;
    }


    // ========================================================================
    // PM TIER CALCULATION
    // ========================================================================

    private static Decimal calculateStandardPMPercent(
        Decimal totalBaseHours
    ) {

        Decimal hours =
            nullToZero(totalBaseHours);


        if (hours < 8) {
            return 0;
        }


        if (hours < 20) {
            return 0.10;
        }


        if (hours < 40) {
            return 0.15;
        }


        if (hours < 120) {
            return 0.20;
        }


        return 0.25;
    }


    // ========================================================================
    // HELPERS
    // ========================================================================

    private static Decimal nullToZero(
        Decimal value
    ) {

        return value == null
            ? 0
            : value;
    }


    private class CalculationResult {

        Boolean success;
        String message;

        Integer lineItemsCalculated = 0;
        Integer lineItemsUpdated = 0;
        Integer lineItemsFailed = 0;

        List<String> errors =
            new List<String>();
    }


    public class PSRatingException extends Exception {
    }
}