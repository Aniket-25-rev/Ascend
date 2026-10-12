// Month-to-Month AMENDMENT quotes: keep Quote.StartDate = Contract.EndDate on
// every header save (Amend flow's MTM update, Revenue Cloud's header write
// after each pricing pass, manual edits). Kept separate from QuoteTrigger,
// which is intentionally Inactive in this org.
trigger QuoteMtmStartDateTrigger on Quote (before update) {
    QuoteMtmStartDateHandler.beforeUpdate(Trigger.new);
}