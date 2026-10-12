trigger HaasPricingTrigger on QuoteLineItem (before insert, before update, before delete) {
    if (Trigger.isDelete) {
        HaasPricingTriggerHandler.validateHaasPairing(null, Trigger.oldMap, false, true);
    } else {
        HaasPricingTriggerHandler.applyHaasPricing(Trigger.new);
        HaasPricingTriggerHandler.validateHaasPairing(Trigger.new, Trigger.oldMap, Trigger.isInsert, false);
        HaasPricingTriggerHandler.validateHardwareDescription(Trigger.new);
       
    }
}