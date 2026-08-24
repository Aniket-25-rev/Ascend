trigger QuoteTrigger on Quote (after update) {
    QuoteRampUpliftHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
}