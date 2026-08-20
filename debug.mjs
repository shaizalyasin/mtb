import { chromium } from 'playwright';

const PORTAL = process.env.PORTAL_URL || 'http://localhost:8090';
const STUDY = process.env.STUDY_ID || 'lgg_ucsf_2014';
const PATIENT = process.env.PATIENT_ID || 'P01';

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1500, height: 1000 } });

page.on('console', m => console.log(`[console.${m.type()}]`, m.text().slice(0, 400)));
page.on('pageerror', e => console.log('[pageerror]', String(e).slice(0, 500)));
page.on('requestfailed', r =>
    console.log('[requestfailed]', r.url().slice(0, 160), r.failure()?.errorText)
);
page.on('response', r => {
    if (/mtb-tools/.test(r.url())) console.log('[bundle response]', r.status(), r.url());
});
page.on('dialog', async d => {
    console.log('[dialog]', d.type(), d.message());
    await d.dismiss();
});

await page.goto(`${PORTAL}/patient?studyId=${STUDY}&caseId=${PATIENT}`, {
    waitUntil: 'domcontentloaded',
});

const tab = page.locator('.msk-tabs a').filter({ hasText: /^MTB Demo$/ }).first();
await tab.waitFor({ timeout: 90000 });
console.log('URL before click:', page.url());
console.log('anchor html:', await tab.evaluate(n => n.outerHTML));
console.log('containers before click:', await page.evaluate(() => ({
    mskTabs: document.querySelectorAll('.msk-tabs').length,
    tabContent: document.querySelectorAll('.tab-content').length,
})));
await tab.click();
await page.waitForTimeout(12000);
console.log('URL after click:', page.url());
console.log('containers after click:', await page.evaluate(() => ({
    mskTabs: document.querySelectorAll('.msk-tabs').length,
    tabContent: document.querySelectorAll('.tab-content').length,
    activeNav: [...document.querySelectorAll('.msk-tabs li')]
        .filter(li => /active/.test(li.className))
        .map(li => li.textContent.trim()),
})));

console.log('\n--- window.renderMtbDemoTab ---');
console.log(await page.evaluate(() => typeof window.renderMtbDemoTab));

console.log('\n--- .mtb-demo count ---');
console.log(await page.locator('.mtb-demo').count());

console.log('\n--- tab content html (first 1200 chars) ---');
console.log(
    await page.evaluate(() => {
        const c = document.querySelector('.tab-content');
        return c ? c.innerHTML.slice(0, 1200) : 'NO .tab-content';
    })
);

console.log('\n--- scripts referencing mtb-tools ---');
console.log(
    await page.evaluate(() =>
        [...document.querySelectorAll('script[src], link[href]')]
            .map(n => n.src || n.href)
            .filter(u => /mtb-tools/.test(u))
            .join('\n') || 'NONE'
    )
);

await page.screenshot({ path: 'debug-page.png', fullPage: true });
await browser.close();
