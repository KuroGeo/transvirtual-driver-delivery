// Run from any directory with Playwright and marked available to Node.
// Optional: README_PLAYWRIGHT_MODULE / README_MARKED_MODULE select installed tools.
const fs = require('node:fs/promises');
const http = require('node:http');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require(process.env.README_PLAYWRIGHT_MODULE || 'playwright');

const root = path.resolve(__dirname, '../../..');
const reviewDir = path.join(root, 'harness/runs/readme-promo');
const types = { '.html': 'text/html', '.png': 'image/png', '.svg': 'image/svg+xml', '.ttf': 'font/ttf' };

async function main() {
  const { marked } = await import(pathToFileURL(require.resolve(process.env.README_MARKED_MODULE || 'marked')).href);
  const markdown = await fs.readFile(path.join(root, 'README.md'), 'utf8');
  const preview = `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Ocean Delivery README preview</title><style>
    *{box-sizing:border-box}body{margin:0;background:#fff;color:#1f2328;font:16px/1.65 -apple-system,BlinkMacSystemFont,'Segoe UI','PingFang SC',sans-serif}
    main{max-width:900px;margin:auto;padding:32px;overflow-wrap:anywhere}h1,h2,h3{line-height:1.3}h1{font-size:32px;border-bottom:1px solid #d8dee4;padding-bottom:12px}h2{font-size:24px;border-bottom:1px solid #d8dee4;padding-bottom:8px;margin-top:30px}
    a{color:#0969da;text-decoration:none}a:hover{text-decoration:underline}img{max-width:100%;height:auto}pre{overflow:auto;background:#f6f8fa;padding:16px;border-radius:6px}code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.86em}p code{background:#f6f8fa;padding:2px 4px}li{margin:6px 0}details{margin:20px 0}summary{cursor:pointer;padding:10px 0;font-weight:600}table{width:100%;border-collapse:collapse;margin:20px 0;display:block;overflow:auto}td,th{padding:12px;border:1px solid #d8dee4}td img{display:block;margin-top:10px}blockquote{color:#656d76;border-left:3px solid #d0d7de;margin:16px 0;padding-left:16px}
    @media(max-width:600px){main{padding:16px}h1{font-size:28px}h2{font-size:22px}td{padding:6px}}
  </style><main>${marked.parse(markdown)}</main></html>`;
  const server = http.createServer(async (req, res) => {
    try {
      const name = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
      if (name === '/__readme') { res.setHeader('Content-Type', 'text/html'); res.end(preview); return; }
      if (name === '/__hero') { res.setHeader('Content-Type', 'text/html'); res.end('<html><body style="margin:0"><img src="/assets/readme/hero.svg" style="display:block;width:100%;height:auto"></body></html>'); return; }
      if (!name.startsWith('/assets/readme/') && name !== '/app/assets/InterVariable.ttf') { res.writeHead(404); res.end(); return; }
      const filename = path.resolve(root, '.' + name);
      const assetRoot = path.join(root, 'assets/readme') + path.sep;
      const fontFile = path.join(root, 'app/assets/InterVariable.ttf');
      if (!filename.startsWith(assetRoot) && filename !== fontFile) { res.writeHead(404); res.end(); return; }
      const data = await fs.readFile(filename);
      res.setHeader('Content-Type', types[path.extname(filename)] || 'application/octet-stream'); res.end(data);
    } catch { res.writeHead(404); res.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  let browser;
  try {
    await fs.mkdir(reviewDir, { recursive: true });
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage({ viewport: { width: 1440, height: 2200 }, deviceScaleFactor: 1 });
    const failures = [];
    page.on('pageerror', error => failures.push(String(error)));
    page.on('response', response => { if (response.status() >= 400) failures.push(`${response.status()} ${response.url()}`); });
    await page.goto(base + '/assets/readme/source/showcase.html');
    await page.evaluate(() => document.fonts.ready);
    const board = page.locator('.board');
    await board.screenshot({ path: path.join(root, 'assets/readme/showcase.png') });
    const imageChecks = await page.locator('img').evaluateAll(images => images.map(image => ({ src: image.getAttribute('src'), complete: image.complete, width: image.naturalWidth, height: image.naturalHeight })));
    if (!imageChecks.every(image => image.complete && image.width === 1206 && image.height === 2622)) throw new Error('Missing or incorrect native screenshot');
    const layouts = [];
    for (const width of [900, 360]) {
      await page.setViewportSize({ width, height: 1600 });
      await page.goto(base + '/__readme');
      await page.screenshot({ path: path.join(reviewDir, `readme-${width}.png`) });
      layouts.push(await page.evaluate(() => ({ viewport: innerWidth, documentWidth: document.documentElement.scrollWidth, images: [...document.images].map(image => ({ src: image.getAttribute('src'), complete: image.complete, width: image.naturalWidth })) })));
      await page.goto(base + '/__hero');
      await page.screenshot({ path: path.join(reviewDir, `hero-${width}.png`), clip: { x: 0, y: 0, width, height: width / 4 } });
    }
    if (failures.length || layouts.some(layout => layout.documentWidth > layout.viewport || layout.images.some(image => !image.complete || !image.width))) throw new Error(JSON.stringify({ failures, layouts }));
    await fs.writeFile(path.join(reviewDir, 'render-validation.json'), JSON.stringify({ generator: 'deterministic HTML/CSS layout of original OS captures', imageChecks, layouts, errors: failures }, null, 2) + '\n');
    console.log('Rendered showcase PNG and 900/360px README/SVG previews; all image loads and width checks passed.');
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
