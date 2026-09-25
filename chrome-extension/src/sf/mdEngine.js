import { OrgClient } from './tooling.js';

// Status is derived, not writable on create: a version is born Draft and is moved
// to Active by a separate activation call once its children exist.
const LIFECYCLE_FIELDS = new Set(['Status', 'IsActive']);

const refKey = (object, key) => `${object}:${key}`;

/**
 * Pull a pruned plan's records out of the source org into a portable bundle.
 * Lookups become { $ref, key } so the bundle carries no org-specific Ids.
 */
export async function retrieveMd(session, plan, { filter = {}, onProgress = () => {} } = {}) {
    const client = new OrgClient(session);
    const idToKey = new Map();
    const raw = [];

    for (const lane of plan) {
        for (const node of lane.nodes) {
            onProgress({ phase: 'retrieve', lane: lane.id, object: node.object });
            const cols = ['Id', node.key, ...node.fields].filter((f, i, a) => a.indexOf(f) === i);
            const where = filter[node.object] ? ` WHERE ${filter[node.object]}` : '';
            const records = await client.queryOn(
                node.api,
                `SELECT ${cols.join(', ')} FROM ${node.object}${where}`
            );
            for (const r of records) {
                if (r[node.key]) idToKey.set(refKey(node.object, r.Id), r[node.key]);
            }
            raw.push({ lane: lane.id, node, records });
        }
    }

    const bundle = { kind: 'rca-metadata', exportedAt: new Date().toISOString(), lanes: {} };
    const warnings = [];

    for (const { lane, node, records } of raw) {
        const out = [];
        for (const r of records) {
            if (!r[node.key]) {
                warnings.push(`${node.object} ${r.Id}: no ${node.key}, skipped.`);
                continue;
            }
            const rec = { $key: r[node.key] };
            for (const f of node.fields) {
                if (r[f] === null || r[f] === undefined) continue;
                const target = node.refs[f];
                if (!target) {
                    rec[f] = r[f];
                    continue;
                }
                const key = idToKey.get(refKey(target, r[f]));
                if (key) rec[f] = { $ref: target, key };
                else
                    warnings.push(
                        `${node.object} "${r[node.key]}": ${f} → ${target} ${r[f]} is outside the retrieve scope.`
                    );
            }
            out.push(rec);
        }
        bundle.lanes[lane] = bundle.lanes[lane] || {};
        bundle.lanes[lane][node.object] = out;
    }

    bundle.warnings = warnings;
    return bundle;
}

/**
 * Push a bundle into the target org.
 *
 * Matching is by natural key: query the target for existing keys, PATCH those and
 * POST the rest. Activation runs last, after every child record is in place —
 * an Expression Set version cannot go Active while its steps are still missing.
 */
export async function deployMd(
    session,
    bundle,
    plan,
    { lanes, dryRun = false, activate = false, onProgress = () => {} } = {}
) {
    const client = new OrgClient(session);
    const keyToId = new Map();
    const log = [];
    const activations = [];

    const say = (object, level, message) => log.push({ object, level, message });

    for (const lane of plan) {
        if (lanes && !lanes.includes(lane.id)) continue;

        for (const node of lane.nodes) {
            const records = bundle.lanes?.[lane.id]?.[node.object] || [];
            if (!records.length) continue;
            onProgress({
                phase: dryRun ? 'validate' : 'deploy',
                lane: lane.id,
                object: node.object,
                count: records.length
            });

            // Existing target records, so we update in place rather than duplicate.
            const existing = await client.queryOn(
                node.api,
                `SELECT Id, ${node.key} FROM ${node.object}`
            );
            for (const e of existing) keyToId.set(refKey(node.object, e[node.key]), e.Id);

            if (node.readOnly) {
                const absent = records.filter((r) => !keyToId.has(refKey(node.object, r.$key)));
                if (absent.length) {
                    say(
                        node.object,
                        'error',
                        `${absent.length} definition(s) missing in target: ${absent
                            .map((r) => r.$key)
                            .join(', ')}. Deploy these with \`sf project deploy start --metadata ${node.object}\` first.`
                    );
                } else {
                    say(node.object, 'info', `${records.length} definition(s) matched in target.`);
                }
                continue;
            }

            const deferred = [];

            for (const r of records) {
                const payload = {};
                let blocked = null;

                for (const [f, v] of Object.entries(r)) {
                    if (f === '$key') continue;
                    if (LIFECYCLE_FIELDS.has(f)) continue; // handled by the activation pass
                    if (!v || typeof v !== 'object' || !v.$ref) {
                        payload[f] = v;
                        continue;
                    }
                    const id = keyToId.get(refKey(v.$ref, v.key));
                    if (id) payload[f] = id;
                    else if (v.$ref === node.object) deferred.push({ key: r.$key, field: f, ref: v });
                    else blocked = `${f} → ${v.$ref} "${v.key}" not found in target org.`;
                }

                if (blocked) {
                    say(node.object, 'error', `${r.$key}: ${blocked}`);
                    continue;
                }

                payload[node.key] = r.$key;
                const existingId = keyToId.get(refKey(node.object, r.$key));

                if (r.Status === 'Active' || r.IsActive === true) {
                    activations.push({ node, key: r.$key, field: r.Status ? 'Status' : 'IsActive' });
                }

                if (dryRun) {
                    say(
                        node.object,
                        'info',
                        `${r.$key}: would ${existingId ? 'update' : 'create'}.`
                    );
                    if (!existingId) keyToId.set(refKey(node.object, r.$key), `dry-${r.$key}`);
                    continue;
                }

                try {
                    if (existingId) {
                        const body = { ...payload };
                        delete body[node.key]; // natural keys are usually not updateable
                        await client.update(node.api, node.object, existingId, body);
                    } else {
                        const res = await client.create(node.api, node.object, payload);
                        keyToId.set(refKey(node.object, r.$key), res.id);
                    }
                } catch (e) {
                    say(node.object, 'error', `${r.$key}: ${e.message}`);
                }
            }

            // Hierarchies (nested context nodes) link once every peer exists.
            if (deferred.length && !dryRun) {
                for (const { key, field, ref } of deferred) {
                    const id = keyToId.get(refKey(node.object, key));
                    const parentId = keyToId.get(refKey(ref.$ref, ref.key));
                    if (!id || !parentId) continue;
                    try {
                        await client.update(node.api, node.object, id, { [field]: parentId });
                    } catch (e) {
                        say(node.object, 'error', `${key}: linking ${field} failed — ${e.message}`);
                    }
                }
                say(node.object, 'info', `${deferred.length} hierarchy link(s) resolved.`);
            }
        }
    }

    // Activation last: a version only goes Active once its steps/attributes exist.
    if (activate && !dryRun) {
        for (const { node, key, field } of activations) {
            const id = keyToId.get(refKey(node.object, key));
            if (!id) continue;
            try {
                await client.update(node.api, node.object, id, {
                    [field]: field === 'Status' ? 'Active' : true
                });
                say(node.object, 'info', `${key}: activated.`);
            } catch (e) {
                say(
                    node.object,
                    'warn',
                    `${key}: could not activate via API (${e.message}). Activate it in Setup.`
                );
            }
        }
    } else if (activations.length) {
        say('-', 'warn', `${activations.length} record(s) landed as Draft. Activate them in Setup or re-run with activation on.`);
    }

    return { log, errors: log.filter((l) => l.level === 'error').length };
}
