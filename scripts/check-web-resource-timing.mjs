import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { gzipSync } from 'node:zlib';

// 使用外部已安装的 Playwright，不给手机产品引入 Node 依赖。
const { chromium, webkit } = await import(process.env.WEQ_PLAYWRIGHT_IMPORT ?? 'playwright');
const progress = await readFile(new URL('../resources/web-startup-progress.js', import.meta.url), 'utf8');
const assets = new Map([
  ['/assets/large-Abcd1234.js', gzipSync('window.largeLoaded=true;/*' + 'large-fixture-'.repeat(10000) + '*/')],
  ['/assets/small-Abcd1234.js', gzipSync('window.smallLoaded=1;')],
  ['/assets/small-Efgh5678.js', gzipSync('window.smallLoaded=2;')],
]);
let revision = 1;
let nativeProxy = false, chunked = false;
const requests = [];
const server = createServer((req, res) => {
  const path = new URL(req.url, 'http://fixture.invalid').pathname;
  if (assets.has(path)) {
    requests.push(path);
    res.writeHead(200, { 'Content-Type': 'text/javascript', 'Content-Encoding': 'gzip',
      ...(chunked ? { 'Transfer-Encoding': 'chunked' } : { 'Content-Length': assets.get(path).length }),
      'Cache-Control': 'public, max-age=31536000, immutable',
      ...(nativeProxy ? { 'Server-Timing': 'weq-remote-source;desc="network"' } : {}) });
    res.end(assets.get(path));
    return;
  }
  const paths = ['/assets/large-Abcd1234.js', revision === 1 ? '/assets/small-Abcd1234.js' : '/assets/small-Efgh5678.js']
    .map(path => chunked ? path + '?chunked' : path);
  const meta = JSON.stringify({ version: 1, resources: paths.map(path => ({ path, size: assets.get(new URL(path, 'http://fixture.invalid').pathname).length })) });
  res.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
  res.end(`<meta name="weq-startup-resources" content='${meta}'><script>window.weqRemoteResourceLoads={};</script>` +
    paths.map(path => `<script src="${path}" onload="weqRemoteResourceLoads['${path}']=true;window.dispatchEvent(new Event('weq-remote-resource-load'))"></script>`).join(''));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
try {
  for (const [name, engine, executablePath] of [['chromium', chromium, process.env.WEQ_CHROMIUM_EXECUTABLE], ['webkit', webkit, process.env.WEQ_WEBKIT_EXECUTABLE]]) {
    const browser = await engine.launch({ headless: true, executablePath });
    try {
      for (const platform of ['ios', 'android']) {
        const context = await browser.newContext();
        try {
          const bridge = platform === 'ios'
            ? 'window.webkit={messageHandlers:{weqResources:{postMessage:value=>window.reports.push(value)}}};'
            : 'window.weqRemoteLinks={resources:text=>window.reports.push(JSON.parse(text))};';
          await context.addInitScript({ content: "window.reports=[];window.weqRemoteStartup={state:'loading'};" + bridge + progress });
          revision = 1;
          nativeProxy = platform === 'android';
          const page = await context.newPage();
          for (const scenario of ['cold', 'unchanged', 'changed', 'chunked']) {
            if (scenario === 'changed') revision = 2;
            chunked = scenario === 'chunked';
            const before = requests.length;
            await page.goto(origin + '/?scenario=' + scenario, { waitUntil: 'load' });
            const result = await page.evaluate(() => {
              window.weqRemoteStartup = { state: 'ready' };
              window.dispatchEvent(new Event('weq-remote-startup'));
              return { value: window.reports.at(-1), timing: performance.getEntriesByType('resource').map(e => ({
                name: e.name, transferSize: e.transferSize, encodedBodySize: e.encodedBodySize,
                decodedBodySize: e.decodedBodySize, deliveryType: e.deliveryType, serverTiming: e.serverTiming,
                fetchStart: e.fetchStart, requestStart: e.requestStart, responseStart: e.responseStart, responseEnd: e.responseEnd,
                responseStatus: e.responseStatus, workerStart: e.workerStart,
              })) };
            });
            console.log(JSON.stringify({ engine: name, platform, scenario, requests: requests.length - before, ...result }));
            assert.equal(result.value.completed, 2);
            assert.equal(requests.length - before, scenario === 'cold' || chunked ? 2 : scenario === 'unchanged' ? 0 : 1);
            const large = assets.get('/assets/large-Abcd1234.js').length;
            const small = assets.get(revision === 1 ? '/assets/small-Abcd1234.js' : '/assets/small-Efgh5678.js').length;
            if (chunked) {
              // 部分 WebKit 版本的响应体计量包含 HTTP/1.1 单块帧；不拿清单值覆盖观测。
              const framed = large + small + large.toString(16).length + small.toString(16).length + 18;
              assert.ok(result.value.downloadedBytes === large + small || (name === 'webkit' && result.value.downloadedBytes === framed));
            } else assert.equal(result.value.downloadedBytes, scenario === 'cold' ? large + small : scenario === 'unchanged' ? 0 : small);
            assert.equal(result.value.cachedBytes, scenario === 'cold' || chunked ? 0 : scenario === 'unchanged' ? large + small : large);
            assert.equal(result.value.unknownBytes, 0);
          }
          await page.close();
        } finally { await context.close(); }
      }
    } finally { await browser.close(); }
  }
} finally { await new Promise(resolve => server.close(resolve)); }
