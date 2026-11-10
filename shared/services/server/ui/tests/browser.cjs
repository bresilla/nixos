const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require(process.env.SITE_PLAYWRIGHT);
const {PNG} = require(path.join(process.env.SITE_PLAYWRIGHT,'lib/utilsBundle.js'));
const artifacts = path.resolve('artifacts');

(async () => {
  const browser = await chromium.launch({channel:'chromium',args:['--disable-gpu']});
  let pairs = 0;
  try {
    const cases = JSON.parse(fs.readFileSync(path.join(artifacts,'pages.json')));
    for (const specimen of cases.filter(c=>!process.env.CASE_FILTER || c.name.includes(process.env.CASE_FILTER))) for (const colorScheme of ['light','dark']) for (const width of [1280,390]) {
      const context = await browser.newContext({colorScheme,viewport:{width,height:900}});
      await context.addInitScript(() => {localStorage.setItem('accent-hue','137'); Math.random=()=>137/360;});
      const pages = [];
      for (const version of ['before','after']) {
        const page = await context.newPage();
        const errors = [];
        page.on('pageerror', e=>errors.push(e.message));
        await page.route('https://ui.test/**',r=>r.fulfill({status:200,contentType:'text/html',body:specimen[version]}));
        await page.goto('https://ui.test/test');
        await page.locator('link[rel=icon]').waitFor({state:'attached'});
        assert.deepEqual(errors,[]);
        pages.push(page);
      }
      for (const state of ['normal','hover','focus']) {
        for (const page of pages) {
          if (state === 'hover') await page.locator('header nav a').first().hover();
          if (state === 'focus') await page.locator('header .who a').focus();
        }
        const stem = `${specimen.name}-${colorScheme}-${width}-${state}`;
        const screenshots = [];
        for (const [i,page] of pages.entries()) screenshots.push(PNG.sync.read(await page.screenshot({path:path.join(artifacts,stem+`-${i}.png`),fullPage:true})));
        assert.equal(screenshots[0].width,screenshots[1].width,stem);
        assert.equal(screenshots[0].height,screenshots[1].height,stem);
        assert(screenshots[0].data.equals(screenshots[1].data),'pixel mismatch '+stem);
        assert.equal(await pages[0].locator('link[rel=icon]').getAttribute('href'),await pages[1].locator('link[rel=icon]').getAttribute('href'));
        pairs++;
      }
      await context.close();
    }
    const context = await browser.newContext();
    await context.addInitScript(() => {Object.defineProperty(window,'localStorage',{get(){throw Error('blocked');}});});
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror',e=>errors.push(e.message));
    await page.route('https://ui.test/**',r=>r.fulfill({contentType:'text/html',body:cases[0].after}));
    await page.goto('https://ui.test/');
    await page.locator('link[rel=icon]').waitFor({state:'attached'});
    assert.deepEqual(errors,[]);
    await context.close();
    fs.writeFileSync(path.join(artifacts,'python-report.json'),JSON.stringify({identicalPixelPairs:pairs,roles:3,themes:2,widths:2,states:3,blockedStorage:'passed'},null,2));
    console.log(`SHARED_PYTHON_UI_OK ${pairs} identical pixel pairs`);
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
