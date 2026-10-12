/**
 * ============================================================================
 * PS_EstimateRatingCalculator4
 * ============================================================================
 *
 * PURPOSE
 * -------
 * Recalculate Professional Services pricing for all Feature Line Items
 * belonging to the Estimate associated with the submitted FLI.
 *
 * FLOW INPUT
 * ----------
 * ONE Flow-visible input:
 *
 *      Feature Line Item Id
 *
 * PERCENT FIELD RULE
 * ------------------
 * Salesforce Percent fields store values as whole percentages:
 *
 *      5  = 5%
 *      10 = 10%
 *      25 = 25%
 *
 * Therefore Apex converts percentages to decimals only when performing math:
 *
 *      5 / 100  = .05
 *      10 / 100 = .10
 *      25 / 100 = .25
 *
 * The whole percentage value is stored on the FLI for transparency.
 *
 * TOTALS
 * ------
 * Total_Hours__c and Total_Cost__c are Formula fields and are NOT updated
 * by Apex.
 *
 * ROLLUPS
 * -------
 * Apex updates only Feature Line Item component fields.
 *
 * Example:
 *
 * FLI.Project_Management_Hours__c
 *      ->
 * Feature.PS_Project_Management_Hours__c
 *      ->
 * Estimate.Project_Management_Hours__c
 *
 * Salesforce rollups handle the Feature and Estimate totals.
 * ============================================================================
 */
public with sharing class PS_EstimateRatingCalculator4 {

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
        description='Receives one Feature Line Item Id and recalculates all Professional Services FLIs on the associated Estimate.'
    )
    public static List<Response> rateFeatureLineItems(
        List<Request> requests
    ) {

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
                triggerLineItemIds.add(
                    request.featureLineItemId
                );
            }
        }


        // No valid Ids supplied.
        if (triggerLineItemIds.isEmpty()) {

            for (Request request : requests) {

                Response response = new Response();

                response.success = false;
                response.message =
                    'Feature Line Item Id is required.';

                response.lineItemsCalculated = 0;
                response.lineItemsUpdated = 0;
                response.lineItemsFailed = 0;

                responses.add(response);
            }

            return responses;
        }


        CalculationResult result;


        try {

            result =
                calculateEstimates(
                    triggerLineItemIds
                );

        } catch (Exception ex) {

            result = new CalculationResult();

            result.success = false;

            result.message =
                'Professional Services pricing failed: '
                + ex.getMessage();
        }


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
    // MAIN CALCULATION METHOD
    // ========================================================================

    private static CalculationResult calculateEstimates(
        Set<Id> triggerLineItemIds
    ) {

        CalculationResult result =
            new CalculationResult();


        // ====================================================================
        // 1. FIND ESTIMATE(S) FROM SUBMITTED FLI(S)
        // ====================================================================

        List<Project_Estimate_Feature_Line_Item__c>
            triggeringLineItems = [

                SELECT
                    Id,
                    Estimate__c

                FROM
                    Project_Estimate_Feature_Line_Item__c

                WHERE
                    Id IN :triggerLineItemIds
            ];


        if (triggeringLineItems.isEmpty()) {

            result.success = false;

            result.message =
                'No Feature Line Item was found for the supplied Id.';

            return result;
        }


        Set<Id> estimateIds =
            new Set<Id>();


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

            estimateIds.add(
                lineItem.Estimate__c
            );
        }


        // ====================================================================
        // 2. QUERY ESTIMATE ASSUMPTIONS
        //
        // IMPORTANT:
        // Percent fields contain WHOLE percent values.
        //
        // 5  = 5%
        // 10 = 10%
        // ====================================================================

        Map<Id, Project_Estimate__c> estimatesById =
            new Map<Id, Project_Estimate__c>([

                SELECT
                    Id,
                    Hypercare_Percent__c,
                    Documentation_Percent__c,
                    Risk_Percent__c,
                    PM_Percent__c

                FROM
                    Project_Estimate__c

                WHERE
                    Id IN :estimateIds
            ]);


        // ====================================================================
        // 3. QUERY ALL FLIs FOR THE ESTIMATE(S)
        //
        // We intentionally recalculate all FLIs because a newly added or
        // edited FLI can push the Estimate into a different PM tier.
        // ====================================================================

        List<Project_Estimate_Feature_Line_Item__c>
            allLineItems = [

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

                FROM
                    Project_Estimate_Feature_Line_Item__c

                WHERE
                    Estimate__c IN :estimateIds
            ];


        // ====================================================================
        // 4. CALCULATE TOTAL BASE HOURS BY ESTIMATE
        //
        // Estimate_Hrs__c is the canonical FLI Base Hours field.
        // ====================================================================

        Map<Id, Decimal> baseHoursByEstimate =
            new Map<Id, Decimal>();


        for (
            Project_Estimate_Feature_Line_Item__c lineItem :
            allLineItems
        ) {

            if (
                lineItem.Include_in_Estimate__c != true
            ) {
                continue;
            }


            Decimal currentHours = 0;


            if (
                baseHoursByEstimate.containsKey(
                    lineItem.Estimate__c
                )
            ) {

                currentHours =
                    baseHoursByEstimate.get(
                        lineItem.Estimate__c
                    );
            }


            currentHours +=
                nullToZero(
                    lineItem.Estimate_Hrs__c
                );


            baseHoursByEstimate.put(
                lineItem.Estimate__c,
                currentHours
            );
        }


        // ====================================================================
        // 5. DETERMINE PROJECT MANAGEMENT PERCENT
        //
        // Values here are WHOLE Salesforce percentages.
        //
        // Example:
        // 20 means 20%
        // ====================================================================

        Map<Id, Decimal> pmPercentByEstimate =
            new Map<Id, Decimal>();


        for (Id estimateId : estimateIds) {

            Project_Estimate__c estimate =
                estimatesById.get(
                    estimateId
                );


            if (estimate == null) {

                throw new PSRatingException(
                    'Estimate '
                    + estimateId
                    + ' could not be found.'
                );
            }


            Decimal baseHours =
                baseHoursByEstimate.containsKey(
                    estimateId
                )
                ? baseHoursByEstimate.get(
                    estimateId
                )
                : 0;


            Decimal pmPercent;


            // ---------------------------------------------------------------
            // PM OVERRIDE
            //
            // If PM_Percent__c contains a value, use it as a whole percentage.
            //
            // Example:
            // PM_Percent__c = 25 means 25%.
            // ---------------------------------------------------------------

            if (
                estimate.PM_Percent__c != null
            ) {

                pmPercent =
                    estimate.PM_Percent__c;

            } else {

                pmPercent =
                    calculateStandardPMPercent(
                        baseHours
                    );
            }


            pmPercentByEstimate.put(
                estimateId,
                pmPercent
            );
        }


        // ====================================================================
        // 6. COLLECT RESOURCE ROLES
        // ====================================================================

        Set<String> resourceRoles =
            new Set<String>();


        for (
            Project_Estimate_Feature_Line_Item__c lineItem :
            allLineItems
        ) {

            if (
                lineItem.Include_in_Estimate__c == true &&
                String.isNotBlank(
                    lineItem.Resource_Role__c
                )
            ) {

                resourceRoles.add(
                    lineItem.Resource_Role__c
                );
            }
        }


        // ====================================================================
        // 7. RETRIEVE RESOURCE RATES
        // ====================================================================

        Map<String, Decimal> rateByResourceRole =
            new Map<String, Decimal>();


        if (!resourceRoles.isEmpty()) {

            List<PS_Resource_Rate__c> resourceRates = [

                SELECT
                    Id,
                    Resource__c,
                    Standard_Rate__c

                FROM
                    PS_Resource_Rate__c

                WHERE
                    Resource__c IN :resourceRoles
            ];


            for (
                PS_Resource_Rate__c resourceRate :
                resourceRates
            ) {

                if (
                    String.isBlank(
                        resourceRate.Resource__c
                    )
                ) {
                    continue;
                }


                if (
                    rateByResourceRole.containsKey(
                        resourceRate.Resource__c
                    )
                ) {

                    throw new PSRatingException(
                        'Multiple PS Resource Rate records '
                        + 'were found for Resource Role '
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


                rateByResourceRole.put(
                    resourceRate.Resource__c,
                    resourceRate.Standard_Rate__c
                );
            }
        }


        // ====================================================================
        // 8. CALCULATE EACH FLI
        // ====================================================================

        List<Project_Estimate_Feature_Line_Item__c>
            lineItemsToUpdate =
                new List<Project_Estimate_Feature_Line_Item__c>();


        for (
            Project_Estimate_Feature_Line_Item__c lineItem :
            allLineItems
        ) {


            // ================================================================
            // EXCLUDED FLI
            // ================================================================

            if (
                lineItem.Include_in_Estimate__c != true
            ) {

                Project_Estimate_Feature_Line_Item__c
                    updateLineItem =
                        new Project_Estimate_Feature_Line_Item__c(
                            Id = lineItem.Id
                        );


                updateLineItem.Resource_Rate__c =
                    null;

                updateLineItem.Base_Cost__c =
                    0;


                updateLineItem.Project_Management_Percent__c =
                    0;

                updateLineItem.Project_Management_Hours__c =
                    0;

                updateLineItem.Project_Management_Cost__c =
                    0;


                updateLineItem.Hypercare_Percent__c =
                    0;

                updateLineItem.Hypercare_Hours__c =
                    0;

                updateLineItem.Hypercare_Cost__c =
                    0;


                updateLineItem.Documentation_Percent__c =
                    0;

                updateLineItem.Documentation_Hours__c =
                    0;

                updateLineItem.Documentation_Cost__c =
                    0;


                updateLineItem.Risk_Percent__c =
                    0;

                updateLineItem.Risk_Hours__c =
                    0;

                updateLineItem.Risk_Cost__c =
                    0;


                lineItemsToUpdate.add(
                    updateLineItem
                );


                result.lineItemsCalculated++;

                continue;
            }


            // ================================================================
            // VALIDATE RESOURCE ROLE
            // ================================================================

            if (
                String.isBlank(
                    lineItem.Resource_Role__c
                )
            ) {

                throw new PSRatingException(
                    'Feature Line Item '
                    + lineItem.Id
                    + ' is included in the Estimate '
                    + 'but does not have a Resource Role.'
                );
            }


            // ================================================================
            // VALIDATE RATE
            // ================================================================

            if (
                !rateByResourceRole.containsKey(
                    lineItem.Resource_Role__c
                )
            ) {

                throw new PSRatingException(
                    'No PS Resource Rate was found for '
                    + 'Resource Role '
                    + lineItem.Resource_Role__c
                    + ' on Feature Line Item '
                    + lineItem.Id
                    + '.'
                );
            }


            Project_Estimate__c estimate =
                estimatesById.get(
                    lineItem.Estimate__c
                );


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
                baseHours
                * resourceRate;


            // ================================================================
            // PROJECT MANAGEMENT
            //
            // pmPercentStored:
            //      Whole Salesforce percent.
            //      Example: 20 = 20%
            //
            // pmRate:
            //      Decimal used for calculation.
            //      Example: .20
            // ================================================================

            Decimal pmPercentStored =
                nullToZero(
                    pmPercentByEstimate.get(
                        lineItem.Estimate__c
                    )
                );


            Decimal pmRate =
                percentToDecimal(
                    pmPercentStored
                );


            Decimal pmHours;


            // ---------------------------------------------------------------
            // Spreadsheet Kickoff special rule.
            //
            // Kickoff gets 2 PM hours when engineering hours exist.
            // ---------------------------------------------------------------

            Decimal totalEstimateBaseHours =
                baseHoursByEstimate.containsKey(
                    lineItem.Estimate__c
                )
                ? baseHoursByEstimate.get(
                    lineItem.Estimate__c
                )
                : 0;


            if (
                String.isNotBlank(lineItem.Name) &&
                lineItem.Name.trim().toLowerCase() == 'kickoff' &&
                totalEstimateBaseHours > 0
            ) {

                pmHours = 2;

            } else {

                pmHours =
                    baseHours
                    * pmRate;
            }


            Decimal pmCost =
                pmHours
                * resourceRate;


            // ================================================================
            // HYPERCARE
            //
            // Estimate stores:
            //      5
            //
            // Math uses:
            //      .05
            // ================================================================

            Decimal hypercarePercentStored =
                nullToZero(
                    estimate.Hypercare_Percent__c
                );


            Decimal hypercareRate =
                percentToDecimal(
                    hypercarePercentStored
                );


            Decimal hypercareHours =
                baseHours
                * hypercareRate;


            Decimal hypercareCost =
                hypercareHours
                * resourceRate;


            // ================================================================
            // DOCUMENTATION
            // ================================================================

            Decimal documentationPercentStored =
                nullToZero(
                    estimate.Documentation_Percent__c
                );


            Decimal documentationRate =
                percentToDecimal(
                    documentationPercentStored
                );


            Decimal documentationHours =
                baseHours
                * documentationRate;


            Decimal documentationCost =
                documentationHours
                * resourceRate;


            // ================================================================
            // STAFFED HOURS BEFORE RISK
            //
            // Risk is calculated after Base, PM, Hypercare and Documentation.
            // ================================================================

            Decimal staffedHoursBeforeRisk =
                baseHours
                + pmHours
                + hypercareHours
                + documentationHours;


            // ================================================================
            // RISK
            // ================================================================

            Decimal riskPercentStored =
                nullToZero(
                    estimate.Risk_Percent__c
                );


            Decimal riskRate =
                percentToDecimal(
                    riskPercentStored
                );


            Decimal riskHours =
                staffedHoursBeforeRisk
                * riskRate;


            Decimal riskCost =
                riskHours
                * resourceRate;


            // ================================================================
            // MONEY SCALE
            //
            // Component hours are intentionally not rounded here.
            //
            // Rounding individual FLIs before aggregation can overstate
            // Hypercare, Documentation and Risk when an Estimate contains
            // multiple FLIs.
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
            // BUILD UPDATE RECORD
            // ================================================================

            Project_Estimate_Feature_Line_Item__c
                updateLineItem =
                    new Project_Estimate_Feature_Line_Item__c(
                        Id = lineItem.Id
                    );


            // ---------------------------------------------------------------
            // RESOURCE / BASE
            // ---------------------------------------------------------------

            updateLineItem.Resource_Rate__c =
                resourceRate;


            updateLineItem.Base_Cost__c =
                baseCost;


            // ---------------------------------------------------------------
            // PROJECT MANAGEMENT
            //
            // Store WHOLE percent on Salesforce record.
            // ---------------------------------------------------------------

            updateLineItem.Project_Management_Percent__c =
                pmPercentStored;


            updateLineItem.Project_Management_Hours__c =
                pmHours;


            updateLineItem.Project_Management_Cost__c =
                pmCost;


            // ---------------------------------------------------------------
            // HYPERCARE
            // ---------------------------------------------------------------

            updateLineItem.Hypercare_Percent__c =
                hypercarePercentStored;


            updateLineItem.Hypercare_Hours__c =
                hypercareHours;


            updateLineItem.Hypercare_Cost__c =
                hypercareCost;


            // ---------------------------------------------------------------
            // DOCUMENTATION
            // ---------------------------------------------------------------

            updateLineItem.Documentation_Percent__c =
                documentationPercentStored;


            updateLineItem.Documentation_Hours__c =
                documentationHours;


            updateLineItem.Documentation_Cost__c =
                documentationCost;


            // ---------------------------------------------------------------
            // RISK
            // ---------------------------------------------------------------

            updateLineItem.Risk_Percent__c =
                riskPercentStored;


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
        // 9. UPDATE FLIs
        // ====================================================================

        if (
            !lineItemsToUpdate.isEmpty()
        ) {

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

                    result.success =
                        false;


                    String errorMessage =
                        '';


                    for (
                        Database.Error error :
                        saveResult.getErrors()
                    ) {

                        if (
                            errorMessage != ''
                        ) {

                            errorMessage +=
                                ' | ';
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
        // 10. RESPONSE
        // ====================================================================

        if (
            result.lineItemsFailed > 0
        ) {

            result.success =
                false;


            result.message =
                'Professional Services pricing completed with '
                + result.lineItemsFailed
                + ' failed update(s). '
                + String.join(
                    result.errors,
                    ' | '
                );

        } else {

            result.success =
                true;


            result.message =
                'Professional Services pricing completed. '
                + result.lineItemsUpdated
                + ' Feature Line Item(s) recalculated.';
        }


        return result;
    }


    // ========================================================================
    // PM TIER
    //
    // IMPORTANT:
    // Returns WHOLE Salesforce percentage values.
    //
    // 10 = 10%
    // 15 = 15%
    // 20 = 20%
    // 25 = 25%
    // ========================================================================

    private static Decimal calculateStandardPMPercent(
        Decimal totalBaseHours
    ) {

        Decimal hours =
            nullToZero(
                totalBaseHours
            );


        // 0 - 7 hours
        if (
            hours < 8
        ) {
            return 0;
        }


        // 8 - 19 hours
        if (
            hours < 20
        ) {
            return 10;
        }


        // 20 - 39 hours
        if (
            hours < 40
        ) {
            return 15;
        }


        // 40 - 119 hours
        if (
            hours < 120
        ) {
            return 20;
        }


        // 120+ hours
        return 25;
    }


    // ========================================================================
    // PERCENT CONVERSION
    //
    // Salesforce Percent field:
    //
    //      5
    //
    // becomes:
    //
    //      .05
    //
    // for mathematical calculations.
    // ========================================================================

    private static Decimal percentToDecimal(
        Decimal percentValue
    ) {

        if (
            percentValue == null
        ) {
            return 0;
        }


        return percentValue / 100;
    }


    // ========================================================================
    // NULL HANDLER
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

        Boolean success = true;

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