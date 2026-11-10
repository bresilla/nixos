const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {chromium}=require(process.env.SITE_PLAYWRIGHT);
const {PNG}=require(path.join(process.env.SITE_PLAYWRIGHT,'lib/utilsBundle.js'));

(async()=>{
  const directory=path.resolve('artifacts/live');fs.mkdirSync(directory,{recursive:true,mode:0o700});
  const manifest=JSON.parse(fs.readFileSync('artifacts/public/manifest.json')).filter(s=>['build','cache','git','id'].includes(s.name));
  const browser=await chromium.launch({channel:'chromium',args:['--disable-gpu']});
  let pairs=0;
  try {
    for(const specimen of manifest) for(const colorScheme of ['light','dark']) for(const width of [1280,390]) {
      const contexts=[],pages=[];
      for(const live of [false,true]) {
        const context=await browser.newContext({viewport:{width,height:900},colorScheme});contexts.push(context);
        await context.addInitScript(()=>{localStorage.setItem('accent-hue','137');Math.random=()=>137/360;});
        if(!live) await context.routeFromHAR(path.resolve('artifacts/public',specimen.name+'.har'),{notFound:'abort'});
        const page=await context.newPage();pages.push(page);
        const errors=[];page.on('pageerror',e=>errors.push(e.message));
        await page.goto(live?specimen.url:specimen.finalURL,{waitUntil:'networkidle'});
        await page.waitForURL(specimen.finalURL,{waitUntil:'networkidle'});
        await page.waitForTimeout(300);
        assert.deepEqual(errors,[],specimen.name);
        if(live) {
          assert.equal(await page.evaluate(()=>typeof BresillaUI),'object',specimen.name);
          assert.equal(await page.evaluate(()=>getComputedStyle(document.documentElement).getPropertyValue('--site-header-height').trim()),'49px');
        }
      }
      const selector=specimen.name==='git'?'#navbar':specimen.name==='id'?'header.site':'header';
      const shots=[],links=[];
      for(const [i,page] of pages.entries()) {
        shots.push(PNG.sync.read(await page.locator(selector).screenshot({path:path.join(directory,`${specimen.name}-${colorScheme}-${width}-${i}.png`),animations:'disabled'})));
        links.push(await page.locator(selector+' a').evaluateAll(list=>list.map(a=>({text:a.textContent.trim(),href:a.getAttribute('href')}))));
      }
      assert.deepEqual(links[0],links[1],specimen.name+' account/navigation');
      assert.equal(shots[0].width,shots[1].width);assert.equal(shots[0].height,shots[1].height);
      assert(shots[0].data.equals(shots[1].data),'live header mismatch '+specimen.name+' '+colorScheme+' '+width);pairs++;
      if(width===1280 && colorScheme==='light' && specimen.name!=='id') {
        const page=pages[1];
        await page.locator(selector+' a').filter({hasText:/Sign [Ii]n/}).click();
        await page.waitForURL(url=>url.hostname==='id.bresilla.com',{waitUntil:'networkidle'});
        assert.equal(new URL(page.url()).hostname,'id.bresilla.com');
      }
      for(const context of contexts) await context.close();
    }
    const request=await browser.newContext();
    for(const host of ['build','cache']) {
      const response=await request.request.get(`https://${host}.bresilla.com/-/settings`,{headers:{'X-Forwarded-Preferred-Username':'bresilla','X-Forwarded-Groups':'admin'},maxRedirects:0});
      assert([302,303,401,403].includes(response.status()),host+' trusted proxy isolation');
    }
    await request.close();
    fs.writeFileSync(path.join(directory,'report.json'),JSON.stringify({identicalLiveHeaderPairs:pairs,sites:4,signInRedirects:3,spoofedAdminHeaders:'rejected',humanSSORoundtrip:'not performed'},null,2));
    console.log(`SHARED_UI_LIVE_OK ${pairs} identical headers; native sign-in redirects and proxy isolation passed`);
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
