/**
 * Automated proof of the four success criteria. Run via ./verify.sh.
 *
 * The interesting one is the loading transition. Mutation data arrives fast
 * enough that by the time the tab is clicked the store is usually already
 * complete -- and a screenshot of a finished number proves nothing, because a
 * value baked in at mount time looks identical. So we hold the mutation
 * response until after the tab has mounted, then release it, and assert we saw
 * "loading..." first and a real count afterwards with no remount in between.
 * Only a live subscription to the store produces that.
 */
import { chromium } from 'playwright';

const PORTAL = process.env.PORTAL_URL || 'http://localhost:8090';
const STUDY = process.env.STUDY_ID || 'lgg_ucsf_2014';
const PATIENT = process.env.PATIENT_ID || 'P01';
const MAX_STALL_MS = 45000;

const results = [];
function check(name, ok, detail = '') {
    results.push({ name, ok, detail });
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`);
}

const PANEL = '.mtb-demo';
const tab = (page, name) =>
    page.locator('.msk-tabs a').filter({ hasText: new RegExp(`^${name}$`) }).first();

const rowText = (page, label) =>
    page.evaluate(l => {
        const labels = [...document.querySelectorAll('.mtb-demo .mtb-label')];
        return labels.find(n => n.textContent.trim() === l)
            ?.nextElementSibling?.textContent?.trim() ?? null;
    }, label);

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1500, height: 1000 } });

const consoleErrors = [];
page.on('console', m => m.type() === 'error' && consoleErrors.push(m.text()));
page.on('pageerror', e => consoleErrors.push(String(e)));

let release;
const released = new Promise(r => (release = r));
setTimeout(() => release(), MAX_STALL_MS); // never hang the run

await page.route('**/mutations/fetch**', async route => {
    await released;
    await route.continue();
});

await page.goto(`${PORTAL}/patient?studyId=${STUDY}&caseId=${PATIENT}`, {
    waitUntil: 'domcontentloaded',
});

// --- 1. the tab exists and mounts ---------------------------------------
await tab(page, 'MTB Demo').waitFor({ timeout: 90000 });
check('Custom tab appears in the Patient View tab bar', true);

await tab(page, 'MTB Demo').click();
await page.waitForSelector(PANEL, { timeout: 60000 });
check('Bundle loaded from :8081 and mountCallbackName resolved off window', true);

// --- 2. pending -> real value, within one continuous mount ---------------
const pendingSeen = await page
    .waitForFunction(
        () => {
            const labels = [...document.querySelectorAll('.mtb-demo .mtb-label')];
            const m = labels.find(n => n.textContent.trim() === 'Mutations');
            return m?.nextElementSibling?.classList.contains('mtb-pending') ?? false;
        },
        { timeout: 15000 }
    )
    .then(() => true)
    .catch(() => false);
check('Mutation count shows a pending state while the store is fetching', pendingSeen);

release();

await page.waitForFunction(
    () => {
        const labels = [...document.querySelectorAll('.mtb-demo .mtb-label')];
        const m = labels.find(n => n.textContent.trim() === 'Mutations');
        return /^\d+$/.test(m?.nextElementSibling?.textContent?.trim() ?? '');
    },
    { timeout: 90000 }
);

const mutationText = await rowText(page, 'Mutations');
const mutationCount = Number(mutationText);

// Cross-check against the REST API, so the number is corroborated by something
// other than the store we are testing.
const apiCount = await page.evaluate(
    async ({ portal, study, patient }) => {
        const samples = await (
            await fetch(`${portal}/api/studies/${study}/patients/${patient}/samples`)
        ).json();
        const res = await fetch(
            `${portal}/api/molecular-profiles/${study}_mutations/mutations/fetch?projection=ID`,
            {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ sampleIds: samples.map(s => s.sampleId) }),
            }
        );
        return (await res.json()).length;
    },
    { portal: PORTAL, study: STUDY, patient: PATIENT }
);

check(
    'Mutation count went pending -> real number, and matches the REST API',
    pendingSeen && mutationCount > 0 && mutationCount === apiCount,
    `rendered ${mutationCount}, API reports ${apiCount}`
);

// --- 3. identifiers come from the store ---------------------------------
const studyId = await rowText(page, 'Study');
const patientId = await rowText(page, 'Patient');
const samples = await rowText(page, 'Samples');
check(
    'Study / patient / sample identifiers read from the live store',
    studyId === STUDY && patientId === PATIENT && !!samples,
    `study=${studyId} patient=${patientId} samples=${samples}`
);

await page.screenshot({ path: 'verify-mounted.png' });

// --- 4. clean lifecycle across tab switches -----------------------------
const panelsBefore = await page.locator(PANEL).count();

for (let i = 0; i < 3; i++) {
    await tab(page, 'Summary').click();
    await page.waitForTimeout(800);
    await tab(page, 'MTB Demo').click();
    await page.waitForSelector(PANEL, { timeout: 30000 });
    await page.waitForTimeout(800);
}

const panelsAfter = await page.locator(PANEL).count();
check(
    'No duplicate content after switching tabs away and back 3x',
    panelsBefore === 1 && panelsAfter === 1,
    `${panelsBefore} panel before, ${panelsAfter} after`
);

const mountLabel = await page.locator(`${PANEL} .mtb-note`).last().innerText();
const finalMutation = await rowText(page, 'Mutations');
check(
    'Remounted tab still reads the store',
    finalMutation === mutationText,
    `mutations=${finalMutation}; ${mountLabel.replace(/\s+/g, ' ').trim().slice(0, 60)}`
);

await page.screenshot({ path: 'verify-after-tab-switch.png' });

const mtbErrors = consoleErrors.filter(e => /mtb|Callback for tab/i.test(e));
check('No MTB-related console errors', mtbErrors.length === 0, mtbErrors.join(' | '));

await browser.close();

const failed = results.filter(r => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
process.exit(failed.length === 0 ? 0 : 1);
