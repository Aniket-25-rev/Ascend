/**
 * QuoteLineItemUpliftTrigger
 *
 * Fires after insert/update on QuoteLineItem to apply custom uplift/markup
 * pricing when Custom_Uplift_Price_Amount__c or Custom_Uplift_Price_Percentage__c
 * is populated. This trigger acts as the bridge between the custom uplift fields
 * and the Revenue Cloud pricing procedure outputs (NetUnitPrice, NetTotalPrice).
 *
 * Integration point: runs after the NGP Revenue Management Pricing Procedure has
 * computed the base NetUnitPrice, then applies the uplift delta on top.
 * A negative field value = markup (price goes up).
 * A positive field value = additional discount (price goes down).
 */
trigger QuoteLineItemUpliftTrigger on QuoteLineItem (after insert, after update) {
    QuoteLineItemUpliftHandler.handleUplift(Trigger.new, Trigger.oldMap);
}