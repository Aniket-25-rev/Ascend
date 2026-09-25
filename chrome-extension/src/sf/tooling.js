import { SfClient, API_VERSION } from './api.js';
import { LANES } from './mdPlan.js';

// Tooling and the normal Data API differ only by base path, so one client serves both.
export const basePath = (api) =>
    api === 'tooling'
        ? `/services/data/${API_VERSION}/tooling`
        : `/services/data/${API_VERSION}`;

export class OrgClient extends SfClient {
    queryOn(api, soql) {
        return this.pagedQuery(`${basePath(api)}/query/?q=${encodeURIComponent(soql)}`);
    }

    async pagedQuery(path) {
        const records = [];
        let next = path;
        while (next) {
            const page = await this.request(next);
            records.push(...page.records);
            next = page.done ? null : page.nextRecordsUrl;
        }
        return records;
    }

    describeOn(api, sobject) {
        return this.request(`${basePath(api)}/sobjects/${sobject}/describe`);
    }

    describeGlobal(api) {
        return this.request(`${basePath(api)}/sobjects/`);
    }

    create(api, sobject, record) {
        return this.request(`${basePath(api)}/sobjects/${sobject}`, {
            method: 'POST',
            body: record
        });
    }

    async update(api, sobject, id, record) {
        await this.request(`${basePath(api)}/sobjects/${sobject}/${id}`, {
            method: 'PATCH',
            body: record
        });
        return { id, success: true };
    }
}

/**
 * Ask the org what it actually supports before trusting the plan.
 *
 * Revenue Cloud object and field availability swings by release, licence and which
 * pilot flags are on, so every lane is checked against describeGlobal and each
 * object's describe. Returns a report plus a pruned plan safe to run.
 */
export async function probe(session) {
    const client = new OrgClient(session);
    const global = {};
    for (const api of ['data', 'tooling']) {
        const res = await client.describeGlobal(api);
        global[api] = new Map(res.sobjects.map((s) => [s.name, s]));
    }

    const report = [];
    const pruned = [];

    for (const lane of LANES) {
        const laneReport = { lane: lane.id, label: lane.label, objects: [] };
        const laneNodes = [];

        for (const node of lane.nodes) {
            const known = global[node.api].get(node.object);
            if (!known) {
                // It may simply live on the other API than the plan assumes.
                const otherApi = node.api === 'tooling' ? 'data' : 'tooling';
                const elsewhere = global[otherApi].get(node.object);
                laneReport.objects.push({
                    object: node.object,
                    status: elsewhere ? 'wrong-api' : 'absent',
                    detail: elsewhere
                        ? `Not on ${node.api} API, but present on ${otherApi} — plan corrected.`
                        : 'Not present in this org.'
                });
                if (elsewhere) laneNodes.push({ ...node, api: otherApi });
                continue;
            }

            let fields;
            try {
                fields = await client.describeOn(node.api, node.object);
            } catch (e) {
                laneReport.objects.push({
                    object: node.object,
                    status: 'no-describe',
                    detail: e.message
                });
                continue;
            }

            const byName = new Map(fields.fields.map((f) => [f.name, f]));
            const present = [node.key, ...node.fields].filter((f) => byName.has(f));
            const missing = [node.key, ...node.fields].filter((f) => !byName.has(f));

            if (!byName.has(node.key)) {
                // Without a natural key there is nothing to match on across orgs.
                const candidate = ['ApiName', 'DeveloperName', 'Name', 'MasterLabel'].find((f) =>
                    byName.has(f)
                );
                laneReport.objects.push({
                    object: node.object,
                    status: candidate ? 'key-corrected' : 'no-key',
                    detail: candidate
                        ? `Key "${node.key}" absent; using "${candidate}".`
                        : `No usable natural key — this object must be moved by hand.`
                });
                if (!candidate) continue;
                laneNodes.push({ ...node, key: candidate, fields: present });
                continue;
            }

            laneReport.objects.push({
                object: node.object,
                status: missing.length ? 'partial' : 'ok',
                createable: fields.createable,
                updateable: fields.updateable,
                detail: missing.length ? `Fields not in this org: ${missing.join(', ')}` : ''
            });
            laneNodes.push({ ...node, fields: present.filter((f) => f !== node.key) });
        }

        laneReport.usable = laneNodes.length;
        report.push(laneReport);
        if (laneNodes.length) pruned.push({ ...lane, nodes: laneNodes });
    }

    return { report, plan: pruned };
}
