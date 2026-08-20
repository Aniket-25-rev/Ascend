trigger AssetChangeLogTrigger on Asset(after update) {
    ContractAssetChangeHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
}
