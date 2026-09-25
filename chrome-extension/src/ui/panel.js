const $ = (id) => document.getElementById(id);

const send = (msg) =>
    chrome.runtime.sendMessage(msg).then((res) => {
        if (!res?.ok) throw new Error(res?.error || 'Extension worker did not respond.');
        return res.data;
    });

const log = (line, cls = '') => {
    const el = document.createElement('div');
    el.textContent = line;
    if (cls) el.className = cls;
    $('log').appendChild(el);
    $('log').scrollTop = $('log').scrollHeight;
};

const clear = () => ($('log').textContent = '');
const selectedLanes = () => [...document.querySelectorAll('#lanes input:checked')].map((i) => i.value);

const run = (fn) => async () => {
    clear();
    try {
        await fn();
    } catch (e) {
        log(e.message, 'err');
    }
};

function renderCounts(counts) {
    const parts = [];
    for (const [lane, objects] of Object.entries(counts)) {
        const inner = Object.entries(objects)
            .filter(([, n]) => n)
            .map(([o, n]) => `${o} ${n}`)
            .join(', ');
        if (inner) parts.push(`${lane}: ${inner}`);
    }
    $('counts').textContent = parts.length ? parts.join(' | ') : 'Bundle is empty.';
}

const STATUS_CLASS = {
    ok: 'ok',
    partial: 'warn',
    'key-corrected': 'warn',
    'wrong-api': 'warn',
    absent: 'err',
    'no-key': 'err',
    'no-describe': 'err'
};

async function probeOrg(which) {
    const host = $(which).value;
    log(`Probing ${host}…`);
    const report = await send({ type: 'probe', host });
    for (const lane of report) {
        log(`${lane.label} — ${lane.usable}/${lane.objects.length} object(s) usable`);
        for (const o of lane.objects) {
            const ro = o.createable === false ? ' [read-only]' : '';
            log(`   ${o.status.padEnd(14)} ${o.object}${ro} ${o.detail || ''}`, STATUS_CLASS[o.status]);
        }
    }
    log('Probe complete. The plan is now pruned to this org.', 'ok');
}

async function init() {
    const [orgs, lanes] = await Promise.all([send({ type: 'listOrgs' }), send({ type: 'lanes' })]);
    if (!orgs.length) {
        log('No Salesforce sessions found. Log into both orgs in this browser, then reopen.', 'err');
    }
    for (const sel of [$('sourceOrg'), $('targetOrg')]) {
        sel.innerHTML = orgs.map((o) => `<option>${o}</option>`).join('');
    }
    $('lanes').innerHTML = lanes
        .map(
            (l) =>
                `<label><input type="checkbox" value="${l.id}" checked /> ${l.label}<span class="muted"> · ${l.objects} objects</span></label>`
        )
        .join('');
    const bundle = await send({ type: 'exportBundle' });
    if (bundle) {
        renderCounts(
            Object.fromEntries(
                Object.entries(bundle.lanes).map(([k, v]) => [
                    k,
                    Object.fromEntries(Object.entries(v).map(([o, rs]) => [o, rs.length]))
                ])
            )
        );
    }
}

chrome.runtime.onMessage.addListener((msg) => {
    if (msg.type !== 'progress') return;
    log(`  ${msg.phase} ${msg.object}${msg.count === undefined ? '' : ` (${msg.count})`}`);
});

$('probeSource').onclick = run(() => probeOrg('sourceOrg'));
$('probeTarget').onclick = run(() => probeOrg('targetOrg'));

$('retrieve').onclick = run(async () => {
    log(`Retrieving from ${$('sourceOrg').value}…`);
    const { counts, warnings } = await send({
        type: 'retrieve',
        host: $('sourceOrg').value,
        lanes: selectedLanes()
    });
    warnings.forEach((w) => log(`warn: ${w}`, 'warn'));
    renderCounts(counts);
    log('Retrieve complete.', 'ok');
});

$('deploy').onclick = run(async () => {
    const dryRun = $('dryRun').checked;
    log(`${dryRun ? 'Validating against' : 'Deploying to'} ${$('targetOrg').value}…`);
    const { log: entries, errors } = await send({
        type: 'deploy',
        host: $('targetOrg').value,
        lanes: selectedLanes(),
        dryRun,
        activate: $('activate').checked
    });
    entries.forEach((e) =>
        log(`${e.level}: ${e.object} — ${e.message}`, e.level === 'error' ? 'err' : e.level)
    );
    log(errors ? `Finished with ${errors} error(s).` : 'Finished cleanly.', errors ? 'err' : 'ok');
});

$('download').onclick = run(async () => {
    const bundle = await send({ type: 'exportBundle' });
    if (!bundle) return log('Nothing to download.', 'err');
    const blob = new Blob([JSON.stringify(bundle, null, 2)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `rca-metadata-${Date.now()}.json`;
    a.click();
});

$('upload').onchange = run(async () => {
    const bundle = JSON.parse(await $('upload').files[0].text());
    const { counts } = await send({ type: 'importBundle', bundle });
    renderCounts(counts);
    log('Bundle loaded.', 'ok');
});

init().catch((e) => log(e.message, 'err'));
