/**
 * Automated proof for the Prognosis tab. Run via ./risk/verify-risk.sh.
 *
 * verify.mjs covers the injection mechanism; this covers the claims the
 * Prognosis tab itself makes, and two of them are the point of the whole
 * design:
 *
 *   - the risk service is never told which patient it is scoring, so the
 *     request body must contain no study, patient or sample identifier;
 *   - a missing input is reported as missing rather than silently treated as
 *     a normal value, which is checkable on lgg_ucsf_2014 because that study
 *     genuinely lacks MSI and fraction-genome-altered.
 *
 * A tab that renders a confident number is not evidence of either.
 */
import { chromium } from 'playwright';

const PORTAL = process.env.PORTAL_URL || 'http://localhost:9090';
const RISK = process.env.RISK_URL || 'http://localhost:9092';
const STUDY = process.env.STUDY_ID || 'lgg_ucsf_2014';
const PATIENT = process.env.PATIENT_ID || 'P01';

const results = [];
function check(name, ok, detail = '') {
    results.push({ name, ok, detail });
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`);
}

const tab = (page, name) =>
    page.locator('.msk-tabs a').filter({ hasText: new RegExp(`^${name}$`) }).first();

const browser = await chromium.launch();

// --- 1. the service itself ----------------------------------------------
let health = null;
try {
    health = await (await fetch(`${RISK}/health`)).json();
} catch (error) {
    health = { error: String(error) };
}
check(
    'Risk service is up and reports itself stateless',
    health && health.status === 'ok' && health.stateless === true && health.features > 0,
    JSON.stringify(health)
);

// --- 2. the tab mounts and scores the open patient -----------------------
const page = await browser.newPage({ viewport: { width: 1500, height: 1000 } });
const consoleErrors = [];
page.on('console', m => m.type() === 'error' && consoleErrors.push(m.text()));
page.on('pageerror', e => consoleErrors.push(String(e)));

let predictBody = null;
let prediction = null;
page.on('request', request => {
    if (request.url().includes('/predict') && request.method() === 'POST') {
        predictBody = request.postData();
    }
});
page.on('response', async response => {
    if (response.url().includes('/predict') && response.status() === 200) {
        prediction = await response.json().catch(() => null);
    }
});

await page.goto(`${PORTAL}/patient?studyId=${STUDY}&caseId=${PATIENT}`, {
    waitUntil: 'domcontentloaded',
});

await tab(page, 'Prognosis').waitFor({ timeout: 90000 });
check('Prognosis tab appears in the Patient View tab bar', true);

await tab(page, 'Prognosis').click();

// Either a verdict or an error, but never an indefinite blank panel.
await page
    .locator('.mtb-prognosis .mtb-verdict-figure strong, .mtb-prognosis .mtb-error')
    .first()
    .waitFor({ timeout: 60000 });

const figure = await page
    .locator('.mtb-prognosis .mtb-verdict-figure strong')
    .first()
    .innerText()
    .catch(() => null);
const percentile = Number(figure);
check(
    'Tab renders a percentile for the open patient',
    Number.isInteger(percentile) && percentile >= 0 && percentile <= 100,
    `rendered "${figure}"`
);

check(
    'Displayed percentile matches the service response',
    prediction !== null && percentile === prediction.percentile_within_cancer_type,
    prediction
        ? `rendered ${percentile}, service said ${prediction.percentile_within_cancer_type}`
        : 'no /predict response captured'
);

// --- 3. the privacy claim, which is the reason for the architecture ------
const forbidden = ['studyId', 'sampleId', 'patientId', STUDY, PATIENT];
const leaked = forbidden.filter(key => (predictBody || '').includes(key));
check(
    'Risk service is never sent a study, patient or sample identifier',
    predictBody !== null && leaked.length === 0,
    predictBody === null
        ? 'no POST body captured'
        : leaked.length
          ? `leaked: ${leaked.join(', ')}`
          : `${predictBody.length} byte body, none of ${forbidden.join('/')}`
);

// --- 4. missing inputs are declared, not papered over -------------------
const caveatsShown = await page.locator('.mtb-prognosis .mtb-caveats').count();
check(
    'Missing inputs are reported rather than treated as normal values',
    prediction !== null &&
        (prediction.missing_features.length > 0
            ? caveatsShown === 1
            : caveatsShown === 0),
    prediction
        ? `${prediction.missing_features.length} missing, caveats block ${
              caveatsShown ? 'shown' : 'absent'
          }`
        : 'no prediction'
);

const disclaimers = await page.locator('.mtb-prognosis .mtb-disclaimer').count();
check('Disclaimer is present and not dismissible', disclaimers === 1);

// --- 5. the attributions correspond to the response ---------------------
const bars = await page.locator('.mtb-prognosis .mtb-attr tbody tr').count();
check(
    'One attribution row per contribution returned',
    prediction !== null && bars === prediction.attributions.length,
    prediction ? `${bars} rows, ${prediction.attributions.length} attributions` : ''
);

const curves = await page.locator('.mtb-prognosis .mtb-km-svg path').count();
check(
    'Kaplan-Meier plot draws the three risk-group curves',
    curves >= 3,
    `${curves} paths`
);

// --- 6. the layout we actually shipped ---------------------------------
const boxes = async () =>
    page.locator('.mtb-prognosis .mtb-panel').evaluateAll(nodes =>
        nodes.map(n => {
            const r = n.getBoundingClientRect();
            return { x: Math.round(r.x), y: Math.round(r.y) };
        })
    );

const wide = await boxes();
await page.setViewportSize({ width: 900, height: 1000 });
const narrow = await boxes();

check(
    'Panels sit side by side on a wide page and stack on a narrow one',
    wide.length === 2 &&
        narrow.length === 2 &&
        Math.abs(wide[0].y - wide[1].y) < 20 &&
        wide[0].x !== wide[1].x &&
        narrow[0].y !== narrow[1].y &&
        narrow[0].x === narrow[1].x,
    `wide ${JSON.stringify(wide)} narrow ${JSON.stringify(narrow)}`
);

// --- 7. an unreachable service degrades visibly ------------------------
const broken = await browser.newPage({ viewport: { width: 1500, height: 1000 } });
await broken.route('**/predict', route => route.abort('connectionrefused'));
await broken.goto(`${PORTAL}/patient?studyId=${STUDY}&caseId=${PATIENT}`, {
    waitUntil: 'domcontentloaded',
});
await tab(broken, 'Prognosis').waitFor({ timeout: 90000 });
await tab(broken, 'Prognosis').click();

const errorShown = await broken
    .locator('.mtb-prognosis .mtb-error')
    .first()
    .waitFor({ timeout: 45000 })
    .then(() => true)
    .catch(() => false);
const errorText = errorShown
    ? await broken.locator('.mtb-prognosis .mtb-error').first().innerText()
    : '';
check(
    'An unreachable risk service shows an error, not a blank panel',
    errorShown && errorText.trim().length > 0,
    errorText.slice(0, 80)
);
await broken.close();

// --- 8. nothing broken in the host page --------------------------------
const mtbErrors = consoleErrors.filter(e => /mtb|prognos|Callback for tab/i.test(e));
check('No MTB-related console errors', mtbErrors.length === 0, mtbErrors.join(' | '));

await browser.close();

const failed = results.filter(r => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
process.exit(failed.length ? 1 : 0);
