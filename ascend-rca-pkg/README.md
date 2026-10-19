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

1. **37 CD mappings point to fields that don't exist in pilot.** Examples: `Quote.Cybersecurity_Margin__c`, `QuoteLineItem.LOB_Margin__c`, `QuoteLineItem.Assumed_Cost__c`. Either remove those mappings from the packaged CD or add the fields; otherwise a clean-org deploy will fail.
2. **10 hardcoded pilot Ids in the pricing procedure** (v40):
   - 8 decision table `LookUpId`s (`0lDVF…`)
   - `VolumePASIdConstant` = `84XVF000000iuEb2AI`
   - `AttributePASIdConstant` = `84XVF000000iuEc2AI`

   These are invalid in any other org. Packaging needs a by-name lookup, or a post-install step to re-point them.
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
