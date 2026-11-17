import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class WebDownloadProgressTests(unittest.TestCase):
    def test_source_classification_covers_proxy_cache_revalidation_and_unknown(self):
        subprocess.run(['node', '-e', r'''
const vm=require('node:vm'),assert=require('node:assert/strict');
const script=require('node:fs').readFileSync(process.argv[1],'utf8');
for(const fixture of [
  {name:'proxy-cache',entry:{transferSize:1300,encodedBodySize:1000,serverTiming:[{name:'weq-remote-source',description:'cache'}]},cached:1000,downloaded:0,unknown:0},
  {name:'proxy-network',entry:{transferSize:1100,encodedBodySize:800,serverTiming:[{name:'weq-remote-source',description:'network'}]},cached:0,downloaded:800,unknown:0},
  {name:'old-proxy',entry:{transferSize:1300,encodedBodySize:1000},cached:0,downloaded:0,unknown:1000},
  {name:'zero-cache-timing',entry:{transferSize:0,encodedBodySize:0,decodedBodySize:0,deliveryType:'cache'},cached:1000,downloaded:0,unknown:0},
  {name:'webkit-memory-cache',entry:{transferSize:0,encodedBodySize:0,decodedBodySize:0,fetchStart:7,requestStart:7,responseStart:0,responseEnd:7,workerStart:0},cached:1000,downloaded:0,unknown:0},
  {name:'opaque-redirect',entry:{transferSize:0,encodedBodySize:0,decodedBodySize:0,fetchStart:7,requestStart:0,responseStart:0,responseEnd:8,workerStart:0},cached:0,downloaded:0,unknown:1000},
  {name:'zero-unknown-timing',entry:{transferSize:0,encodedBodySize:0,decodedBodySize:0},cached:0,downloaded:0,unknown:1000},
  {name:'small-revalidated',entry:{transferSize:300,encodedBodySize:100},cached:1000,downloaded:0,unknown:0},
  {name:'status-revalidated',entry:{transferSize:300,encodedBodySize:100,responseStatus:304},cached:1000,downloaded:0,unknown:0},
  {name:'service-worker',entry:{transferSize:1300,encodedBodySize:1000,workerStart:1},cached:0,downloaded:0,unknown:1000},
]) {
  const path='/assets/index-Abcd1234.js',calls=[];
  const entry={name:'http://computer.invalid'+path,responseStatus:200,...fixture.entry};
  const context={URL,Map,Set,Number,JSON,Array,
    location:{href:'http://computer.invalid/',origin:'http://computer.invalid'},
    performance:{getEntriesByType:()=>[entry,entry]},
    document:{querySelector:()=>({content:JSON.stringify({version:1,resources:[{path,size:1000}]})}),addEventListener(){},removeEventListener(){}},
    MutationObserver:class{observe(){}disconnect(){}},clearTimeout(){},
    window:{weqRemoteStartup:{state:'ready'},weqRemoteResourceLoads:{[path]:true},weqRemoteLinks:{resources:v=>calls.push(JSON.parse(v))},addEventListener(){},removeEventListener(){}},
  };
  vm.runInNewContext(script,context);
  const value=calls.at(-1);
  assert.equal(value.loadedBytes,1000,fixture.name);
  assert.equal(value.cachedBytes,fixture.cached,fixture.name);
  assert.equal(value.downloadedBytes,fixture.downloaded,fixture.name);
  assert.equal(value.unknownBytes,fixture.unknown,fixture.name);
}
''', str(ROOT / 'resources/web-startup-progress.js')], check=True)

    def test_real_observer_with_early_cache_failed_and_duplicate_entries(self):
        subprocess.run(['node', '-e', r'''
const vm = require('node:vm');
const assert = require('node:assert/strict');
const script = require('node:fs').readFileSync(process.argv[1], 'utf8');
for (const platform of ['ios', 'android']) {
  let meta, callback, mutations, disconnected = 0;
  const calls = [], timers = new Map(), events = {}, resourceEntries = [];
  const context = {
    URL, Map, Set, Number, JSON, Array,
    location: {href:'https://computer.invalid/', origin:'https://computer.invalid'},
    performance: {getEntriesByType:() => resourceEntries},
    document: {querySelector:() => meta, addEventListener:(n,f) => {events[n]=f}, removeEventListener:n => {delete events[n]}},
    setTimeout:f => {timers.set(timers.size+1, f); return timers.size}, clearTimeout:id => timers.delete(id),
    PerformanceObserver:class {constructor(fn){callback=fn} observe(){} disconnect(){disconnected++}},
    MutationObserver:class {constructor(fn){mutations=fn} observe(){} disconnect(){disconnected++}},
  };
  context.window = {addEventListener:(n,f) => {events[n]=f}, removeEventListener:n => {delete events[n]}};
  if(platform==='ios') context.window.webkit = {messageHandlers:{weqResources:{postMessage:v => calls.push(JSON.parse(JSON.stringify(v)))}}};
  else context.window.weqRemoteLinks = {resources:v => calls.push(JSON.parse(v))};
  vm.createContext(context);
  vm.runInContext(script,context);
  assert.equal(calls.length, 0); // 旧网页没有清单时不猜总大小。
  meta={content:JSON.stringify({version:1,resources:[{path:'/assets/small-12345678.css',size:1000},{path:'/assets/large-12345678.js',size:9000}]})};
  const flush=()=>{const jobs=[...timers.values()];timers.clear();jobs.forEach(f=>f())};
  mutations(); flush();
  assert.deepEqual(calls.at(-1),{completed:0,total:2,loadedBytes:0,totalBytes:10000,downloadedBytes:0,cachedBytes:0,unknownBytes:0});
  const small={name:'https://computer.invalid/assets/small-12345678.css',transferSize:0,encodedBodySize:1000,decodedBodySize:3000};
  resourceEntries.push(small); // 缓存命中、没有 responseStatus 的 WebKit 也算资源已加载。
  callback({getEntries:()=>[small,small,{name:'https://external.invalid/assets/large-12345678.js',encodedBodySize:9000}]});flush();
  assert.deepEqual(calls.at(-1),{completed:1,total:2,loadedBytes:1000,totalBytes:10000,downloadedBytes:0,cachedBytes:1000,unknownBytes:0});
  assert.equal(calls.at(-1).cachedBytes,1000);
  assert.equal(calls.at(-1).downloadedBytes,0);
  const failed={name:'https://computer.invalid/assets/large-12345678.js',responseStatus:404,encodedBodySize:20};
  const aborted={name:failed.name,responseStatus:0,encodedBodySize:0,decodedBodySize:0};
  callback({getEntries:()=>[failed,aborted]});flush();
  assert.equal(calls.at(-1).completed,1);
  // WebKit 内存缓存的 timing 尺寸可能全为零，采用在标签加载前记录的 load/error 回执。
  context.window.weqRemoteResourceLoads={'/assets/large-12345678.js':true};
  events['weq-remote-resource-load']();flush();
  assert.equal(calls.at(-1).completed,2);
  assert.equal(calls.at(-1).unknownBytes,9000); // load 成功不等于已知来自网络或缓存。
  context.window.weqRemoteResourceLoads={'/assets/large-12345678.js':false};
  events['weq-remote-resource-load']();flush();
  assert.equal(calls.at(-1).completed,1);
  context.window.weqRemoteResourceLoads={};
  const before=calls.length;
  vm.runInContext(script,context); mutations();flush();assert.equal(calls.length,before);
  const large={name:failed.name,responseStatus:200,transferSize:9300,encodedBodySize:9000,decodedBodySize:80000,
    serverTiming:[{name:'weq-remote-source',description:'network'}]};
  callback({getEntries:()=>[large]});flush();
  assert.deepEqual(calls.at(-1),{completed:2,total:2,loadedBytes:10000,totalBytes:10000,downloadedBytes:9000,cachedBytes:1000,unknownBytes:0});
  mutations();flush();assert.equal(calls.at(-1).downloadedBytes,9000); // 补读 timing 不重复累计。
  context.window.weqRemoteStartup={state:'ready'};events['weq-remote-startup']();
  assert.equal(disconnected,2);assert.equal(events['weq-remote-startup'],undefined);
}
''', str(ROOT / 'resources/web-startup-progress.js')], check=True)


if __name__ == '__main__':
    unittest.main()
