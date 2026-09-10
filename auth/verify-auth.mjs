/**
 * Tests the claim that a tab mounted through custom_tabs can reach an
 * authenticated backend "without additional token handling".
 *
 * The answer turns out to be yes for tokens and no for login: the bundle never
 * constructs or sends a credential, but it does have to notice a 401 and drive
 * the login flow. Both halves are asserted below.
 */
import { chromium } from 'playwright';

const PORTAL = process.env.PORTAL_URL || 'http://localhost:9090';
const STUDY = process.env.STUDY_ID || 'lgg_ucsf_2014';
const PATIENT = process.env.PATIENT_ID || 'P01';
const KC_USER = process.env.KC_USER || 'mtbuser';
const KC_PASS = process.env.KC_PASS || 'mtbuser';

const results = [];
function check(name, ok, detail = '') {
    results.push({ name, ok, detail });
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`);
}

const rowText = (page, label) =>
    page.evaluate(l => {
        const labels = [...document.querySelectorAll('.mtb-demo .mtb-label')];
        return labels.find(n => n.textContent.trim() === l)
            ?.nextElementSibling?.textContent?.trim() ?? null;
    }, label);

// --- 1. everything is on one origin ------------------------------------
const origin = await (async () => {
    const paths = {
        'cBioPortal': '/',
        'Keycloak discovery': '/auth/realms/mtb/.well-known/openid-configuration',
        'the bundle': '/mtb-tools/mtb-tools.js',
    };
    const out = {};
    for (const [what, path] of Object.entries(paths)) {
        const res = await fetch(`${PORTAL}${path}`);
        out[what] = res.status;
    }
    return out;
})();
check(
    'Portal, Keycloak and the bundle are all served from one origin',
    Object.values(origin).every(s => s === 200),
    Object.entries(origin).map(([k, v]) => `${k}=${v}`).join(' ')
);

// --- 2. the proxy's read/write split ------------------------------------
const readRes = await fetch(`${PORTAL}/mtb/${PATIENT}`);
check('Unauthenticated GET to the MTB backend succeeds', readRes.status === 200,
    `HTTP ${readRes.status}`);

const writeRes = await fetch(`${PORTAL}/mtb/${PATIENT}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title: 'should not be saved' }),
    redirect: 'manual',
});
let writeBody = {};
try { writeBody = await writeRes.json(); } catch { /* not json */ }
check(
    'Unauthenticated POST is refused with 401 + loginUrl, not a redirect to Keycloak',
    writeRes.status === 401 && writeBody.error === 'login_required',
    `HTTP ${writeRes.status} ${writeBody.error ?? ''} loginUrl=${writeBody.loginUrl ?? '-'}`
);

// --- 3. the browser path -------------------------------------------------
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1500, height: 1100 } });

// Anything the bundle sends itself. If the claim holds, this stays empty.
const credentialHeaders = [];
page.on('request', r => {
    const h = r.headers();
    if (/\/mtb\//.test(r.url()) && (h['authorization'] || h['x-userlogin'])) {
        credentialHeaders.push(`${r.method()} ${r.url()}`);
    }
});

await page.goto(`${PORTAL}/patient?studyId=${STUDY}&caseId=${PATIENT}`, {
    waitUntil: 'domcontentloaded',
});

const tab = page.locator('.msk-tabs a').filter({ hasText: /^MTB Demo$/ }).first();
await tab.waitFor({ timeout: 90000 });
await tab.click();
await page.waitForSelector('.mtb-auth', { timeout: 60000 });
check('Tab mounted with the backend panel', true);

const before = await rowText(page, 'Signed in as');
check('Starts unauthenticated', /not signed in/.test(before || ''), before ?? '');

// --- 4. drive the login flow --------------------------------------------
const saveButton = page.getByRole('button', { name: /Save a recommendation/ });
const [popup] = await Promise.all([
    page.waitForEvent('popup', { timeout: 30000 }),
    saveButton.click(),
]);

await popup.waitForLoadState('domcontentloaded');
check(
    'The 401 opened the Keycloak login flow',
    /\/auth\/realms\/mtb\/protocol\/openid-connect\/auth/.test(popup.url()) ||
        (await popup.locator('#kc-form-login').count()) > 0,
    popup.url().slice(0, 90)
);

await popup.fill('#username', KC_USER);
await popup.fill('#password', KC_PASS);
await popup.click('#kc-login');
await popup.waitForEvent('close', { timeout: 60000 }).catch(() => {});

// --- 5. the retried write ------------------------------------------------
await page.waitForFunction(
    () => {
        const labels = [...document.querySelectorAll('.mtb-demo .mtb-label')];
        const v = labels.find(n => n.textContent.trim() === 'Signed in as')
            ?.nextElementSibling?.textContent ?? '';
        return !/not signed in/.test(v) && v.trim() !== '—';
    },
    { timeout: 60000 }
);

const identity = await rowText(page, 'Signed in as');
const roles = await rowText(page, 'Roles from Keycloak');
const cookies = await rowText(page, 'Cookies the backend saw');
const stored = await rowText(page, 'Read (GET, unauthenticated)');

check(
    'After login the write succeeded and the backend saw the Keycloak identity',
    (identity || '').includes(KC_USER),
    identity ?? ''
);
check('Client roles reached the backend', /mtb_user/.test(roles || ''), roles ?? '');
check(
    'The session cookie rode along without the bundle asking for it',
    /proxy OIDC/.test(cookies || ''),
    cookies ?? ''
);

// Reported, not asserted. cBioPortal runs here with --authenticate=false and
// issues no cookie at all, so there is no JSESSIONID to travel with the
// request. That half of the production flow -- lua_login_config.lua reusing
// cBioPortal's session to ask /api/studies what the user may see -- cannot be
// exercised until the portal itself is wired to Keycloak.
console.log(
    `NOTE  cBioPortal session cookie: ${
        /JSESSIONID/.test(cookies || '')
            ? 'present'
            : 'absent -- portal is running unauthenticated, so study-level ' +
              'permission checks are still untested'
    }`
);
check('The recommendation was persisted', /[1-9]/.test(stored || ''), stored ?? '');

check(
    'The bundle never sent a credential of its own',
    credentialHeaders.length === 0,
    credentialHeaders.join(', ') || 'no Authorization or X-USERLOGIN sent by the page'
);

await page.screenshot({ path: 'verify-auth.png' });
await browser.close();

const failed = results.filter(r => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
process.exit(failed.length === 0 ? 0 : 1);
