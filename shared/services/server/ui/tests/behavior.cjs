const assert = require('node:assert/strict');
const fs = require('node:fs');
const {chromium} = require(process.env.SITE_PLAYWRIGHT);

(async()=>{
  const browser=await chromium.launch({channel:'chromium'});
  try {
    const pages=JSON.parse(fs.readFileSync('artifacts/pages.json'));
    const specimen=pages.find(p=>p.name==='cache-admin-caches').after;
    const context=await browser.newContext({permissions:['clipboard-read','clipboard-write']});
    await context.addInitScript(()=>{Math.random=()=>0.25;});
    await context.route('https://ui.test/**',r=>r.fulfill({contentType:'text/html',body:specimen}));
    const page=await context.newPage();
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.goto('https://ui.test/');
    const hue=()=>page.evaluate(()=>localStorage.getItem('accent-hue'));
    assert.equal(await hue(),'90');
    await page.evaluate(()=>localStorage.setItem('accent-hue','137'));
    await page.goto('https://ui.test/next');
    assert.equal(await hue(),'137');
    assert.equal(await page.evaluate(()=>BresillaUI.accent()),'hsl(137 65% 50%)');
    await page.reload();
    assert.equal(await hue(),'90');
    assert.equal(await page.evaluate(()=>BresillaUI.accent()),'hsl(90 65% 50%)');
    const result=await page.evaluate(()=>{
      const header=BresillaUI.header({logo:'<svg></svg>',name:'<&>',home:'/?a="<&',className:'site" onmouseover="x'});
      return {name:header.querySelector('a').textContent,home:header.querySelector('a').getAttribute('href'),handler:header.getAttribute('onmouseover')};
    });
    assert.deepEqual(result,{name:'<&>',home:'/?a="<&',handler:null});
    await page.evaluate(()=>{
      const text=document.createElement('pre');text.id='copy-fixture';text.textContent='nix copy --from example';
      const button=document.createElement('button');button.dataset.copy=text.id;button.textContent='Copy';
      document.querySelector('main').append(text,button);
    });
    await page.getByRole('button',{name:'Copy',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('[data-copy]').classList.contains('done'));
    assert.equal(await page.evaluate(()=>navigator.clipboard.readText()),'nix copy --from example');
    assert.deepEqual(errors,[]);
    await context.close();
    const logo=fs.readFileSync('result/logo.svg','utf8').split('?>').pop().replace(/fill="#[0-9a-fA-F]+"/g,'fill="currentColor"');
    for(const role of ['anonymous','viewer','admin']) {
      const headers=[];
      for(const changed of [false,true]) {
        const context=await browser.newContext();
        await context.addInitScript(()=>{localStorage.setItem('accent-hue','137');});
        let adapter=fs.readFileSync(changed?'../id/hue.js':'artifacts/reference/shared/services/server/id/hue.js','utf8');
        adapter=adapter.replaceAll('@VERSION@','fixture').replaceAll('@LOGO@',JSON.stringify(logo));
        const script=(changed?fs.readFileSync('result/theme.js','utf8'):'')+adapter;
        const nav=role==='anonymous'?'':`<nav class="navbar"><div class="navbar-nav"><a class="nav-link" href="/ui/apps"><i data-feather="grid"></i>Applications</a><a class="nav-link" href="/ui/profile">Profile</a>${role==='admin'?'<a class="nav-link" href="/ui/admin">Administration</a>':''}</div><div class="navbar-nav ms-md-auto"><a class="nav-link" href="/ui/logout">Sign out</a></div></nav>`;
        await context.route('https://id.test/**',r=>{
          if(new URL(r.request().url()).pathname==='/v1/self') return r.fulfill({json:{youare:{attrs:{name:['alice <&>']}}}});
          if(new URL(r.request().url()).pathname==='/pkg/override.css') return r.fulfill({contentType:'text/css',body:''});
          return r.fulfill({contentType:'text/html',body:`<!doctype html><head><link rel="icon" href="data:image/svg+xml,"></head><body>${nav}<script>${script}</script></body>`});
        });
        const page=await context.newPage();
        const errors=[];page.on('pageerror',e=>errors.push(e.message));
        await page.goto('https://id.test/ui/apps');
        if(role!=='anonymous') await page.locator('header.site .who span').waitFor();
        headers.push(await page.locator('header.site').evaluate(e=>e.outerHTML.replace(/>\s+</g,'><')));
        assert.equal(await page.locator('nav.navbar').count(),0);
        assert.deepEqual(errors,[]);
        await context.close();
      }
      assert.equal(headers[0],headers[1],role+' native identity navigation/account');
    }
    fs.writeFileSync('artifacts/behavior-report.json',JSON.stringify({navigationHue:'preserved',reloadHue:'renewed',escapedHeader:'passed',clipboard:'passed',identityRoleAdapters:3}));
    console.log('SHARED_UI_BEHAVIOR_OK');
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
