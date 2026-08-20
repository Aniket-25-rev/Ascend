trigger QuoteItemTrigger on QuoteLineItem (before insert, before update) {

    // ── Ramp Uplift ──────────────────────────────────────────
    // Sets UnitPrice for Year 2+ ramp lines BEFORE pricing runs
    // Guard prevents recursion when handler updates lines
    if (!RampUpliftTriggerHelper.isRunning) {
        QuoteLineItemRampUpliftHandler.handleRampUplift(Trigger.new, Trigger.oldMap);
    }

    // ── Existing Before Insert Logic ─────────────────────────
    if (Trigger.isInsert) {
        QuoteItemTriggerHandler.onBeforeInsert(Trigger.new);
    }
}