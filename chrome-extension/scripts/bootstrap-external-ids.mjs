// Generates the Ascend_Key__c External ID field for every object in RCA_PLAN,
// written into force-app so it deploys with `sf project deploy start`.
//
//   node chrome-extension/scripts/bootstrap-external-ids.mjs
//   sf project deploy start --source-dir force-app/main/default/objects
//
// Both source and target orgs need these fields before the extension can match
// records across orgs. Populate them once per org (a Flow, Data Loader, or an
// anonymous Apex pass setting Ascend_Key__c = Code/ProductCode/Name).

import { mkdir, writeFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { RCA_PLAN } from '../src/sf/rcaPlan.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

const fieldXml = (name) => `<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>${name}</fullName>
    <externalId>true</externalId>
    <label>Ascend Key</label>
    <length>255</length>
    <required>false</required>
    <trackTrending>false</trackTrending>
    <type>Text</type>
    <unique>true</unique>
</CustomField>
`;

for (const node of RCA_PLAN) {
    const dir = join(root, 'force-app', 'main', 'default', 'objects', node.object, 'fields');
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, `${node.key}.field-meta.xml`), fieldXml(node.key));
    console.log(`${node.object}/${node.key}`);
}
console.log(`\n${RCA_PLAN.length} field definitions written.`);
