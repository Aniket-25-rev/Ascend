trigger AssetActionTrigger on AssetAction (before insert, after insert) {

    if (Trigger.isBefore && Trigger.isInsert) {
        AssetActionTriggerHandler.beforeInsert(Trigger.new);
    }

    if (Trigger.isAfter && Trigger.isInsert) {
        AssetActionTriggerHandler.afterInsert(Trigger.new);
    }
}