const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require(process.env.SITE_PLAYWRIGHT);
const {PNG} = require(path.join(process.env.SITE_PLAYWRIGHT,'lib/utilsBundle.js'));
const directory = path.resolve('artifacts/public');
fs.mkdirSync(directory,{recursive:true,mode:0o700});
const cases = [
  ['build','https://build.bresilla.com/'],
  ['build-run','https://build.bresilla.com/-/repo/pull_based/bresilla/nixbuildtest/1'],
  ['cache','https://cache.bresilla.com/'],
  ['cache-package','https://cache.bresilla.com/-/cache/packages'],
  ['git','https://git.bresilla.com/'],
  ['git-repository','https://git.bresilla.com/bresilla/nixos'],
  ['id','https://id.bresilla.com/ui/login'],
];
const scriptOf = page => page.match(/<script>([\s\S]*?)<\/script>/)[1];
const styleOf = page => page.match(/<style>([\s\S]*?)<\/style>/)[1];
function candidateHTML(html, service) {
  if (service === 'build' || service === 'cache') {
    const example = JSON.parse(fs.readFileSync('artifacts/pages.json')).find(p=>p.name.startsWith(service+'-')).after;
    return html.replace(/<script>[\s\S]*?<\/script>/,()=>'<script>'+scriptOf(example)+'</script>')
      .replace(/<style>[\s\S]*?<\/style>/,()=>'<style>'+styleOf(example)+'</style>');
  }
  if (service === 'git') {
    const template=fs.readFileSync('artifacts/generated/gitea/page.html','utf8');
    const generatedScript=[...template.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)].map(m=>m[1]).find(s=>s.includes('globalThis.BresillaUI'));
    const generatedStyle=[...template.matchAll(/^<style>([\s\S]*?)<\/style>/gm)].map(m=>m[1]).find(s=>s.includes('--site-font:'));
    assert(generatedScript && generatedStyle,'native template output');
    let scripts = 0, styles = 0;
    html = html.replace(/(<script\b[^>]*>)([\s\S]*?)(<\/script>)/g,(all,start,js,end)=>{
      if (!js.includes('localStorage.getItem("accent-hue")')) return all;
      const asset = JSON.parse(js.match(/fetch\(("(?:\\.|[^"\\])*")\)/)[1]);
      scripts++;
      return start+generatedScript.replace(/fetch\(("(?:\\.|[^"\\])*")\)/,`fetch(${JSON.stringify(asset)})`)+end;
    });
    html = html.replace(/^<style>([\s\S]*?)<\/style>/gm,(all,css)=>{
      if (!css.includes('--fonts-proportional: "Goku"')) return all;
      styles++;
      return '<style>'+generatedStyle+'</style>';
    });
    assert.equal(scripts,1); assert.equal(styles,1);
  }
  return html;
}
async function initialize(context, now) {
  await context.addInitScript(now => {
    localStorage.setItem('accent-hue','137'); Math.random=()=>137/360;
    const Original=Date;
    globalThis.Date=class extends Original {constructor(...args){super(...(args.length?args:[now]));} static now(){return now;}};
  },now);
}

async function stableScreenshot(page, options) {
  let previous;
  for(let attempt=0;attempt<5;attempt++) {
    const current=await page.screenshot(options);
    if(previous && current.equals(previous)) return PNG.sync.read(current);
    previous=current;
    await page.waitForTimeout(150);
  }
  throw Error('unstable screenshot '+options.path);
}

(async()=>{
  const browser=await chromium.launch({channel:'chromium',args:['--disable-gpu']});
  try {
    if(process.argv[2]==='capture') {
      const manifest=[];
      for(const [name,url] of cases) {
        const now=Date.now();
        const context=await browser.newContext({recordHar:{path:path.join(directory,name+'.har'),mode:'full',content:'embed'},viewport:{width:1280,height:900},colorScheme:'light'});
        await initialize(context,now);
        const page=await context.newPage();
        const errors=[]; page.on('pageerror',e=>errors.push(e.message));
        const documents=[];
        page.on('response',r=>{if(r.request().isNavigationRequest()) documents.push(r);});
        await page.goto(url,{waitUntil:'networkidle'});
        if(name==='git') await page.waitForURL('**/explore/repos',{waitUntil:'networkidle'});
        const response=documents.findLast(r=>r.url()===page.url());
        assert.equal(response.status(),200,name);
        await page.waitForTimeout(300);
        fs.writeFileSync(path.join(directory,name+'.html'),await response.text(),{mode:0o600});
        await page.screenshot({path:path.join(directory,name+'-baseline.png'),fullPage:true});
        const header=page.locator(name.startsWith('git')?'#navbar':name==='id'?'header.site':'header');
        manifest.push({name,url,finalURL:response.url(),now,errors,header:await header.evaluate(e=>({html:e.outerHTML,height:e.getBoundingClientRect().height,font:getComputedStyle(e).font}))});
        await context.close();
        console.log('CAPTURED '+name);
      }
      fs.writeFileSync(path.join(directory,'manifest.json'),JSON.stringify(manifest,null,2),{mode:0o600});
      return;
    }
    let pairs=0,interactionPairs=0;
    for(const specimen of JSON.parse(fs.readFileSync(path.join(directory,'manifest.json'))).filter(c=>!process.env.CASE_FILTER || c.name.includes(process.env.CASE_FILTER))) {
      const service=specimen.name.split('-')[0];
      const original=fs.readFileSync(path.join(directory,specimen.name+'.html'),'utf8');
      const entries=JSON.parse(fs.readFileSync(path.join(directory,specimen.name+'.har'))).log.entries;
      const document=entries.find(e=>e.request.url===specimen.finalURL && e.response.status===200);
      for(const colorScheme of ['light','dark']) for(const width of [1280,390]) {
        const contexts=[],pages=[];
        for(const changed of [false,true]) {
          const context=await browser.newContext({viewport:{width,height:900},colorScheme}); contexts.push(context);
          await initialize(context,specimen.now);
          await context.routeFromHAR(path.join(directory,specimen.name+'.har'),{notFound:'abort'});
          if(changed) await context.route('**/*',async route=>{
            const url=new URL(route.request().url());
            let content,source;
            if(route.request().url()===specimen.finalURL && route.request().isNavigationRequest()) {content=candidateHTML(original,service);source=document;}
            else if(service==='id' && url.pathname==='/pkg/override.css') {
              content=fs.readFileSync('artifacts/generated/id/override.css','utf8');
              source=entries.find(e=>new URL(e.request.url).pathname==='/pkg/override.css');
            } else if(service==='id' && url.pathname==='/pkg/style.js') {
              source=entries.find(e=>new URL(e.request.url).pathname==='/pkg/style.js');
              content=fs.readFileSync('artifacts/generated/id/style.js','utf8');
            }
            if(content===undefined) return route.fallback();
            assert(source,'missing reference resource '+url);
            const headers=Object.fromEntries(source.response.headers.filter(h=>!['content-length','content-encoding','transfer-encoding'].includes(h.name.toLowerCase())).map(h=>[h.name,h.value]));
            return route.fulfill({status:source.response.status,headers,body:content});
          });
          const page=await context.newPage(); pages.push(page);
          const errors=[]; page.on('pageerror',e=>{errors.push(e.message);console.error(specimen.name,changed?'candidate':'baseline',e.stack);});
          await page.goto(specimen.finalURL,{waitUntil:'networkidle'});
          await page.waitForURL(specimen.finalURL,{waitUntil:'networkidle'});
          await page.waitForTimeout(300);
          assert.deepEqual(errors,specimen.errors,specimen.name+(changed?' candidate':' baseline'));
          if(changed) assert.equal(await page.evaluate(()=>typeof BresillaUI),'object',specimen.name+' shared runtime');
        }
        const headerSelector=service==='git'?'#navbar':service==='id'?'header.site':'header';
        const links=await Promise.all(pages.map(p=>p.locator(headerSelector+' a').evaluateAll(links=>links.map(a=>({text:a.textContent.trim(),href:a.getAttribute('href'),class:a.className})))));
        assert.deepEqual(links[0],links[1],specimen.name+' native navigation');
        const icons=await Promise.all(pages.map(p=>p.evaluate(async()=>{
          const link=document.querySelector('link[rel~="icon"][type="image/svg+xml"]') || document.querySelector('link[rel~="icon"]');
          const svg=link.href.startsWith('data:')?decodeURIComponent(link.href.slice(link.href.indexOf(',')+1)):await (await fetch(link.href)).text();
          return new XMLSerializer().serializeToString(new DOMParser().parseFromString(svg,'image/svg+xml').documentElement).replace(/>\s+</g,'><');
        })));
        assert.deepEqual(icons[0],icons[1],specimen.name+' favicon');
        const states=['normal','hover',...(service==='git' && width===390?['menu']:[]),...(service==='id'?['checkbox']:[])];
        for(const state of states) {
          if(state==='hover') for(const page of pages) {
            const link=page.locator(service==='git'?'#navbar .navbar-left > a.item:not(#navbar-logo)':service==='id'?'header.site > a':'header nav a').first();
            if(await link.isVisible()) await link.hover();
          }
          if(state==='menu') for(const page of pages) {
            await page.locator('#navbar-expand-toggle').click();
            assert(await page.locator('#navbar .navbar-right a[href="/user/login"]').isVisible());
            await page.mouse.move(0,800);
            await page.waitForTimeout(500);
          }
          if(state==='checkbox') for(const page of pages) {
            await page.locator('input[type=checkbox]').check();
            assert(await page.locator('input[type=checkbox]').isChecked());
            await page.waitForTimeout(500);
          }
          const stem=`${specimen.name}-${colorScheme}-${width}-${state}`;
          const interaction=state==='menu' || state==='checkbox';
          const shots=[];
          for(const [i,page] of pages.entries()) shots.push(await stableScreenshot(page,{path:path.join(directory,stem+`-${i}.png`),fullPage:!interaction,animations:'disabled'}));
          assert.equal(shots[0].width,shots[1].width,stem);assert.equal(shots[0].height,shots[1].height,stem);
          if(state==='menu' || !shots[0].data.equals(shots[1].data)) {
            const metrics=await Promise.all(pages.map(p=>p.evaluate(()=>[...document.body.querySelectorAll('*')].filter(e=>!['SCRIPT','STYLE'].includes(e.tagName) && e.getClientRects().length).map(e=>{
              const style=getComputedStyle(e);
              return {tag:e.tagName,id:e.id,classes:e.className,box:e.getBoundingClientRect().toJSON(),style:Object.fromEntries([...style].filter(k=>!k.startsWith('--')).map(k=>[k,style.getPropertyValue(k)]))};
            }))));
            metrics.forEach((m,i)=>fs.writeFileSync(path.join(directory,stem+`-metrics-${i}.json`),JSON.stringify(m)));
            assert.deepEqual(metrics[0],metrics[1],'layout/style mismatch '+stem);
          }
          assert(shots[0].data.equals(shots[1].data),'pixel mismatch '+stem);
          if(interaction) interactionPairs++; else pairs++;
        }
        for(const context of contexts) await context.close();
      }
      console.log('MATCHED '+specimen.name);
    }
    fs.writeFileSync(path.join(directory,'report.json'),JSON.stringify({identicalFullPagePairs:pairs,identicalInteractionViewportPairs:interactionPairs,sites:4,nativeHeadersAndCSP:true},null,2));
    console.log(`SHARED_FOUR_SITE_UI_OK ${pairs} full-page and ${interactionPairs} interaction viewport pixel pairs`);
  }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
