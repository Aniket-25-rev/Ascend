// Session capture: reuse the sid cookie of an org the user is already logged into.
// This is the same approach Salesforce Inspector uses. No OAuth round-trip, but it
// only works for orgs open in this browser profile. See README for the OAuth path.

const ORG_DOMAINS = ['salesforce.com', 'force.com'];

function hostToOrgKey(host) {
    // my.salesforce.com is the API host; lightning.force.com is the UI host.
    return host.replace(/\.lightning\.force\.com$/, '.my.salesforce.com');
}

export async function sessionForHost(uiHost) {
    const apiHost = hostToOrgKey(uiHost);
    const cookie = await chrome.cookies.get({
        url: `https://${apiHost}/`,
        name: 'sid',
        storeId: undefined
    });
    if (!cookie || !cookie.value.includes('!')) {
        throw new Error(`No active session for ${apiHost}. Log into the org in this browser first.`);
    }
    return { instanceUrl: `https://${apiHost}`, accessToken: cookie.value };
}

export async function listKnownOrgs() {
    const cookies = await chrome.cookies.getAll({ name: 'sid' });
    const hosts = new Set();
    for (const c of cookies) {
        const d = c.domain.replace(/^\./, '');
        if (!ORG_DOMAINS.some((x) => d.endsWith(x))) continue;
        if (!d.includes('.my.salesforce.com')) continue;
        hosts.add(d);
    }
    return [...hosts].sort();
}
