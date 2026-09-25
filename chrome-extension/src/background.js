import { sessionForHost, listKnownOrgs } from './sf/session.js';
import { probe } from './sf/tooling.js';
import { retrieveMd, deployMd } from './sf/mdEngine.js';
import { LANES } from './sf/mdPlan.js';

chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }).catch(() => {});

const progress = (evt) => chrome.runtime.sendMessage({ type: 'progress', ...evt }).catch(() => {});

const countLanes = (bundle) =>
    Object.fromEntries(
        Object.entries(bundle.lanes || {}).map(([lane, objects]) => [
            lane,
            Object.fromEntries(Object.entries(objects).map(([o, rs]) => [o, rs.length]))
        ])
    );

// The pruned plan is per-org, so cache it under the host it was probed against.
async function planFor(host) {
    const { plans = {} } = await chrome.storage.local.get('plans');
    if (plans[host]) return plans[host];
    const { plan } = await probe(await sessionForHost(host));
    plans[host] = plan;
    await chrome.storage.local.set({ plans });
    return plan;
}

const handlers = {
    listOrgs: () => listKnownOrgs(),

    lanes: () => LANES.map((l) => ({ id: l.id, label: l.label, objects: l.nodes.length })),

    probe: async ({ host }) => {
        const { report, plan } = await probe(await sessionForHost(host));
        const { plans = {} } = await chrome.storage.local.get('plans');
        plans[host] = plan;
        await chrome.storage.local.set({ plans });
        return report;
    },

    retrieve: async ({ host, lanes, filter }) => {
        const plan = (await planFor(host)).filter((l) => !lanes || lanes.includes(l.id));
        const session = await sessionForHost(host);
        const bundle = await retrieveMd(session, plan, { filter, onProgress: progress });
        await chrome.storage.local.set({ bundle });
        return { counts: countLanes(bundle), warnings: bundle.warnings };
    },

    deploy: async ({ host, lanes, dryRun, activate }) => {
        const { bundle } = await chrome.storage.local.get('bundle');
        if (!bundle) throw new Error('No bundle loaded. Retrieve from a source org first.');
        const plan = await planFor(host); // pruned against the TARGET org, not the source
        const session = await sessionForHost(host);
        return deployMd(session, bundle, plan, { lanes, dryRun, activate, onProgress: progress });
    },

    exportBundle: async () => (await chrome.storage.local.get('bundle')).bundle || null,

    importBundle: async ({ bundle }) => {
        await chrome.storage.local.set({ bundle });
        return { counts: countLanes(bundle) };
    }
};

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    const handler = handlers[msg.type];
    if (!handler) return false;
    Promise.resolve(handler(msg))
        .then((data) => sendResponse({ ok: true, data }))
        .catch((err) => sendResponse({ ok: false, error: err.message }));
    return true; // keep the channel open for the async response
});
