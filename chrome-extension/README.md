# RCA Metadata Bridge — Chrome extension

Moves the Revenue Cloud components that `sf project deploy` won't carry between orgs: **Context Definitions**, **Expression Sets / pricing procedures**, and **Decision Matrix row data**.

## What the Metadata API actually does and doesn't cover

Verified against Salesforce docs, September 2026:

| Component | Metadata API | The gap this extension fills |
| --- | --- | --- |
| `ExpressionSetDefinition` | Retrieves and deploys | **Individual versions do not migrate.** A pricing procedure's logic lives in its version, so the definition lands empty. Version deploys via CLI are also a known failure mode ([forcedotcom/cli#2823](https://github.com/forcedotcom/cli/issues/2823)). |
| `ExpressionSetDefinitionVersion` | Documented, unreliable in practice | Moved record-wise here, with steps, then activated. |
| `DecisionMatrixDefinition` / `DecisionTableDefinition` | Deploys the definition | **Row data never deploys.** Salesforce's own guidance is to re-import rows by CSV and re-activate by hand. |
| `ContextDefinition` | Documented type, partial in practice | Nodes, attributes and mappings moved record-wise. |

Salesforce's official position on the matrix case: *"Migrating a decision matrix or decision table deploys the metadata of the component and not the data."* That manual step, plus the missing expression-set versions, is the whole reason this tool exists.

So the deploy path here is **not** a Metadata API zip. These components all have record representations on the Tooling API and standard objects, so the extension moves them by natural key (`ApiName` / `DeveloperName`) — query source, rewrite lookups to keys, match-or-create in the target, link hierarchies, then activate.

## Probe first — this is the important part

Revenue Cloud object and field availability swings by release, licence and enabled pilots, and the exact object graph for Context Service is not stable across versions. **The plan in `src/sf/mdPlan.js` is a starting hypothesis, not gospel.** Nodes marked `unverified: true` are best guesses.

Click **Probe** on each org before doing anything. It calls `describeGlobal` plus a describe per object and reports, per object:

- `ok` / `partial` — usable, with any absent fields named
- `wrong-api` — present, but on the Data API rather than Tooling (or vice versa); the plan self-corrects
- `key-corrected` — the natural key differs in your org; a substitute was chosen
- `absent` / `no-key` — not movable this way, move it by hand
- `[read-only]` — not createable via API; deploy the definition with the CLI first, then run this to fill it

The probe result prunes the plan and is cached per org host. Correct `mdPlan.js` from what the probe tells you — that file is meant to be edited.

## Order of operations for a real migration

1. `sf project deploy start --metadata ExpressionSetDefinition:<Name>` — get the definitions and matrix shells in via the supported path.
2. **Probe** both orgs in the extension.
3. **Retrieve** from source (Context lane first — expression sets reference context definitions).
4. **Deploy** to target with *Validate only* on. Read every `error` line; unresolved `$ref`s mean something upstream is missing.
5. Re-run with validate off, then with **Activate versions** on. Activation is deliberately last: a version cannot go Active while its steps or attributes are still missing.

Versions land as `Draft` unless you tick activate — `Status` and `IsActive` are stripped on create because they are lifecycle-managed, not writable fields.

## Files

| Path | Role |
| --- | --- |
| `src/sf/mdPlan.js` | The three lanes and their object graphs — **edit this from your probe output** |
| `src/sf/tooling.js` | Tooling + Data API client, and the org probe |
| `src/sf/mdEngine.js` | Retrieve / deploy: natural-key match, ref rewriting, hierarchy linking, activation |
| `src/sf/session.js` | `sid` cookie capture and org discovery |
| `src/sf/api.js` | Base REST client |
| `src/background.js` | MV3 worker; routes UI messages, caches the pruned plan per org |
| `src/ui/panel.*` | Side panel |
| `src/sf/rcaPlan.js`, `src/sf/engine.js` | Optional second lane for catalog/product/pricing **data** (see below) |

## Install

`chrome://extensions` → Developer mode → **Load unpacked** → select `chrome-extension/`. Log into both orgs in the same browser profile, click the toolbar icon.

Auth is the `sid` cookie of orgs you are already logged into — no Connected App needed, but it only works in this browser profile and runs as your user. To distribute it, swap `sessionForHost` for a `chrome.identity.launchWebAuthFlow` PKCE flow; nothing else changes, since the clients only need `{ instanceUrl, accessToken }`.

## The optional data lane

`rcaPlan.js` / `engine.js` move catalog **data** (ProductCatalog, ProductCategory, Product2, attributes, bundle structure, price books) by External Id. Not what you asked for — standard metadata deploys fine for you — but it is wired and working if you ever need the records too. It requires `Ascend_Key__c` on each object:

```bash
node chrome-extension/scripts/bootstrap-external-ids.mjs
sf project deploy start --source-dir force-app/main/default/objects
```

## Known limits

- Deploys are record-at-a-time, not transactional; a mid-run failure leaves the target partially updated. Always validate first.
- Some Tooling objects reject `POST` outright. The probe flags these as `[read-only]` — those need the CLI for the definition, with this tool filling the children.
- Decision matrix rows live in a per-matrix Big Object whose name the probe must resolve; the `MATRIX_LANE` row handling is the least-proven part of the plan.

Sources: [Expression Set Migration Using Salesforce CLI](https://help.salesforce.com/s/articleView?id=sf.migrate_expression_with_sfcli.htm&language=en_US&type=5) · [ContextDefinition metadata type](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_contextdefinition.htm) · [ExpressionSetVersion object](https://developer.salesforce.com/docs/atlas.en-us.industries_reference.meta/industries_reference/sforce_api_objects_expressionsetversion.htm) · [ExpressionSetDefinitionVersion (Tooling)](https://developer.salesforce.com/docs/atlas.en-us.industries_reference.meta/industries_reference/tooling_api_objects_expressionsetdefinitionversion.htm)
