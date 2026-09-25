import { SfClient } from './api.js';
import { planFor } from './rcaPlan.js';

const chunk = (arr, n) =>
    arr.reduce((out, x, i) => (i % n ? out[out.length - 1].push(x) : out.push([x]), out), []);

// Fields differ between orgs by release and licence, so never blind-query a plan
// field: intersect it with what the org actually exposes.
async function describeFields(client, node, cache) {
    if (!cache.has(node.object)) {
        const d = await client.describe(node.object);
        cache.set(node.object, new Map(d.fields.map((f) => [f.name, f])));
    }
    const meta = cache.get(node.object);
    const wanted = [node.key, ...node.fields];
    return {
        present: wanted.filter((f) => meta.has(f)),
        missing: wanted.filter((f) => !meta.has(f)),
        writable: new Set(
            [...meta.values()].filter((f) => f.createable || f.updateable).map((f) => f.name)
        )
    };
}

/**
 * Read RCA config out of the source org into a portable bundle.
 * Lookups are rewritten from Ids to the referenced record's external key, so the
 * bundle carries no org-specific Ids at all.
 */
export async function retrieve(session, { objects, where = {}, onProgress = () => {} } = {}) {
    const client = new SfClient(session);
    const nodes = planFor(objects);
    const describeCache = new Map();
    const raw = {};
    const idToKey = new Map(); // "Object:Id" -> external key

    for (const node of nodes) {
        onProgress({ phase: 'retrieve', object: node.object });
        const { present, missing } = await describeFields(client, node, describeCache);
        const filter = where[node.object] ? ` WHERE ${where[node.object]}` : '';
        const cols = present.filter((f) => f !== 'Id').join(', ');
        const records = await client.query(`SELECT Id, ${cols} FROM ${node.object}${filter}`);
        for (const r of records) {
            if (r[node.key]) idToKey.set(`${node.object}:${r.Id}`, r[node.key]);
        }
        raw[node.object] = { records, skippedFields: missing };
    }

    // Second pass: swap lookup Ids for keys now that every map is populated.
    const bundle = { apiVersion: 'v66.0', exportedAt: new Date().toISOString(), objects: {} };
    const warnings = [];
    for (const node of nodes) {
        const out = [];
        for (const r of raw[node.object].records) {
            if (!r[node.key]) {
                warnings.push(`${node.object} ${r.Id} has no ${node.key} value and was skipped.`);
                continue;
            }
            const rec = { [node.key]: r[node.key] };
            for (const f of node.fields) {
                if (!(f in r) || r[f] === null) continue;
                const target = node.refs[f];
                if (!target) {
                    rec[f] = r[f];
                    continue;
                }
                const key = idToKey.get(`${target}:${r[f]}`);
                if (!key) {
                    warnings.push(
                        `${node.object} ${r[node.key]}: ${f} points at ${target} ${r[f]}, which is outside the export scope.`
                    );
                    continue;
                }
                rec[f] = { $ref: target, key };
            }
            out.push(rec);
        }
        bundle.objects[node.object] = out;
        if (raw[node.object].skippedFields.length) {
            warnings.push(
                `${node.object}: fields absent in source org, omitted — ${raw[node.object].skippedFields.join(', ')}`
            );
        }
    }
    bundle.warnings = warnings;
    return bundle;
}

/**
 * Write a bundle into the target org. Runs the plan in order; self-referencing
 * objects go in two passes (upsert flat, then link) so parents always exist.
 * `dryRun` resolves and validates everything without issuing writes.
 */
export async function deploy(session, bundle, { objects, dryRun = false, onProgress = () => {} } = {}) {
    const client = new SfClient(session);
    const nodes = planFor(objects).filter((n) => (bundle.objects[n.object] || []).length);
    const describeCache = new Map();
    const keyToId = new Map(); // "Object:key" -> target Id
    const log = [];

    for (const node of nodes) {
        const records = bundle.objects[node.object];
        onProgress({
            phase: dryRun ? 'validate' : 'deploy',
            object: node.object,
            count: records.length
        });
        const { missing, writable } = await describeFields(client, node, describeCache);
        if (missing.length) {
            log.push({
                object: node.object,
                level: 'warn',
                message: `Fields absent in target org, skipped: ${missing.join(', ')}`
            });
        }

        const deferred = [];
        const payload = records.map((r) => {
            const rec = { [node.key]: r[node.key] };
            for (const [f, v] of Object.entries(r)) {
                if (f === node.key || !writable.has(f)) continue;
                if (!v || typeof v !== 'object' || !v.$ref) {
                    rec[f] = v;
                    continue;
                }
                const id = keyToId.get(`${v.$ref}:${v.key}`);
                if (id) {
                    rec[f] = id;
                } else if (v.$ref === node.object) {
                    // Same-object parent not upserted yet: handle on the linking pass.
                    deferred.push({ key: r[node.key], field: f, ref: v });
                } else {
                    log.push({
                        object: node.object,
                        level: 'error',
                        message: `${r[node.key]}.${f} → missing ${v.$ref} "${v.key}" in target org.`
                    });
                }
            }
            return rec;
        });

        if (dryRun) {
            // Resolve records already in the target so later nodes can validate refs.
            const existing = await client.query(
                `SELECT Id, ${node.key} FROM ${node.object} WHERE ${node.key} != null`
            );
            for (const e of existing) keyToId.set(`${node.object}:${e[node.key]}`, e.Id);
            log.push({
                object: node.object,
                level: 'info',
                message: `${payload.length} record(s) would be upserted.`
            });
            continue;
        }

        for (const batch of chunk(payload, 200)) {
            const results = await client.upsert(node.object, node.key, batch, false);
            results.forEach((res, i) => {
                if (res.success) {
                    keyToId.set(`${node.object}:${batch[i][node.key]}`, res.id);
                } else {
                    log.push({
                        object: node.object,
                        level: 'error',
                        message: `${batch[i][node.key]}: ${res.errors.map((e) => e.message).join('; ')}`
                    });
                }
            });
        }

        // Linking pass for hierarchies (category trees, nested component groups).
        if (deferred.length) {
            const links = deferred
                .map(({ key, field, ref }) => {
                    const id = keyToId.get(`${ref.$ref}:${ref.key}`);
                    return id ? { [node.key]: key, [field]: id } : null;
                })
                .filter(Boolean);
            for (const batch of chunk(links, 200)) {
                await client.upsert(node.object, node.key, batch, false);
            }
            log.push({
                object: node.object,
                level: 'info',
                message: `${links.length} hierarchy link(s) resolved.`
            });
        }
    }
    return { log, errors: log.filter((l) => l.level === 'error').length };
}
