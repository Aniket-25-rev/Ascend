# Ascend RCA Pricing — managed package

2GP managed package for the RCA admin configuration: Context Definition, its default mappings, and the pricing procedure. Everything here was retrieved from **Ascendpilot** (teamascend--pilot) on 2026-10-19 at API 68.0.

## Contents

| Type | Component | Notes |
|---|---|---|
| ContextDefinition | `Ascend_SalesTransactionContext` | Extends `SalesTransactionContext__stdctx`; includes mappings (QuoteEntitiesMapping, OrderEntitiesMapping, ContractNodeMapping, …) |
| ExpressionSetDefinition | `Rev_Mgmt_Default_Pricing_Procedure1` | Stripped to the **active version only** (v40) — the pilot retrieve held 39 versions |
| DecisionTable | 7 tables used by v40 | Price_Book_Entry_v2, Price_Adjustment_Tier, Attribute_Based_Adjustment, Bundle_Based_Adjustment, Contract_Pricing_Volume_Tiers, Term_Discount, Cost_Book_Entry |
| CustomObject | `Term_Discount__c` | Source object of the Term_Discount decision table |
| CustomField | 80 fields on Quote, QuoteLineItem, Order, OrderItem, AssetStatePeriod, AssetActionSource | The fields the CD's hydration mappings read |

## Open issues before the first package version

1. ~~37 CD mappings point to fields that don't exist in pilot~~ **Fixed 2026-10-19.**
   - Removed the 37 `contextAttributeMappings` hydration entries (Quote ×17, QuoteLineItem ×20), e.g. `Quote.Cybersecurity_Margin__c`, `QuoteLineItem.LOB_Margin__c`.
   - The context *attributes* themselves are kept, so procedure references to them still resolve. They just aren't hydrated from a field.
2. ~~10 hardcoded pilot Ids in the pricing procedure~~ **Fixed 2026-10-19.** No `0lD…` or `84X…` Ids remain.
   - **Decision table lookups:** removed the 8 `LookUpId` parameters. Each lookup step still names its table by `LookUpApiName` (e.g. `Price_Book_Entry_Decision_Table_v2`). **Unverified:** confirm on the first scratch-org deploy that the platform resolves tables by API name alone. If it doesn't, the fallback is to re-select each table in the builder after install.
   - **PAS constants:** `VolumePASIdConstant` and `AttributePASIdConstant` are now blank, like `BundlePASIdConstant` already was. `PriceAdjustmentSchedule` is data, so each org must set them after install (see below). While they are blank, volume and attribute discounts silently don't apply.
3. **Namespace.** Set `"namespace"` in `sfdx-project.json` once it is registered and linked to the Dev Hub. Custom field references then become `<ns>__Field__c`.
4. **Scratch org features.** `config/project-scratch-def.json` still needs the Revenue Cloud features and settings so the package build org can compile the CD and pricing procedure.
5. **Dev Hub.** The only authenticated Dev Hub today is `Ascend Prod`. Decide which Dev Hub owns this package before running `sf package create`.

## Build order

```bash
# 1. Validate in a scratch org (CD + fields first, then decision tables, then procedure)
sf org create scratch -f config/project-scratch-def.json -a pkg-test
sf project deploy start --target-org pkg-test

# 2. Package
sf package create --name "Ascend RCA Pricing" --package-type Managed --path force-app -v <DevHub>
sf package version create -p "Ascend RCA Pricing" -x -c -w 30 -v <DevHub>
```

## After install in a subscriber org (not packageable)

1. Activate the context definition and confirm the default mapping.
2. In Salesforce Pricing Setup, set the context definition and the default pricing procedure.
3. Revenue Settings: turn on "Exclude Default and Sales Transaction Type Pricing Procedures". Set procedure plan `ContractTermEndDate`, section 2, to this procedure.
4. Refresh all 7 decision tables.
5. Re-point `VolumePASIdConstant` / `AttributePASIdConstant` to that org's `PriceAdjustmentSchedule` Ids. Activate the procedure version.

## Re-retrieving from pilot

```bash
sf project retrieve start --manifest manifest/package.xml --target-org Ascendpilot --api-version 68.0
```
The retrieve brings back every procedure version. Strip the file back to the active `<versions>` block before you commit it.
