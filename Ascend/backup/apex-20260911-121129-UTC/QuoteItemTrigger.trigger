trigger QuoteItemTrigger on QuoteLineItem (before insert, before update) {

    // ── Existing Before Insert Logic ─────────────────────────
    if (Trigger.isInsert) {
        QuoteItemTriggerHandler.onBeforeInsert(Trigger.new);
    }
}