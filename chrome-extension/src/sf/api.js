export const API_VERSION = 'v66.0';

export class SfClient {
    constructor({ instanceUrl, accessToken }) {
        this.instanceUrl = instanceUrl;
        this.accessToken = accessToken;
    }

    async request(path, { method = 'GET', body, headers = {} } = {}) {
        const res = await fetch(`${this.instanceUrl}${path}`, {
            method,
            headers: {
                Authorization: `Bearer ${this.accessToken}`,
                'Content-Type': 'application/json',
                ...headers
            },
            body: body === undefined ? undefined : JSON.stringify(body)
        });
        const text = await res.text();
        const parsed = text ? JSON.parse(text) : null;
        if (!res.ok) {
            const msg = Array.isArray(parsed) ? parsed.map((e) => e.message).join('; ') : text;
            throw new Error(`${res.status} ${path}: ${msg}`);
        }
        return parsed;
    }

    async query(soql) {
        let path = `/services/data/${API_VERSION}/query/?q=${encodeURIComponent(soql)}`;
        const records = [];
        while (path) {
            const page = await this.request(path);
            records.push(...page.records);
            path = page.done ? null : page.nextRecordsUrl;
        }
        return records;
    }

    describe(sobject) {
        return this.request(`/services/data/${API_VERSION}/sobjects/${sobject}/describe`);
    }

    // Upsert a batch of records on an External ID field. Max 200 per call.
    upsert(sobject, externalIdField, records, allOrNone = true) {
        return this.request(
            `/services/data/${API_VERSION}/composite/sobjects/${sobject}/${externalIdField}`,
            { method: 'PATCH', body: { allOrNone, records } }
        );
    }

    // Ordered, transactional multi-step calls with reference chaining (@{ref.id}).
    composite(compositeRequest, allOrNone = true) {
        return this.request(`/services/data/${API_VERSION}/composite`, {
            method: 'POST',
            body: { allOrNone, compositeRequest }
        });
    }
}
