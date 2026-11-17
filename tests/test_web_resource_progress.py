import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class WebResourceProgressTests(unittest.TestCase):
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
  assert.deepEqual(calls.at(-1),{completed:0,total:2});
  const small={name:'https://computer.invalid/assets/small-12345678.css',transferSize:0,encodedBodySize:1000,decodedBodySize:3000};
  resourceEntries.push(small); // 缓存命中、没有 responseStatus 的 WebKit 也算资源已加载。
  callback({getEntries:()=>[small,small,{name:'https://external.invalid/assets/large-12345678.js',encodedBodySize:9000}]});flush();
  assert.deepEqual(calls.at(-1),{completed:1,total:2});
  const failed={name:'https://computer.invalid/assets/large-12345678.js',responseStatus:404,encodedBodySize:20};
  const aborted={name:failed.name,responseStatus:0,encodedBodySize:0,decodedBodySize:0};
  callback({getEntries:()=>[failed,aborted]});flush();
  assert.equal(calls.at(-1).completed,1);
  // WebKit 内存缓存的 timing 尺寸可能全为零，采用在标签加载前记录的 load/error 回执。
  context.window.weqRemoteResourceLoads={'/assets/large-12345678.js':true};
  events['weq-remote-resource-load']();flush();
  assert.equal(calls.at(-1).completed,2);
  context.window.weqRemoteResourceLoads={'/assets/large-12345678.js':false};
  events['weq-remote-resource-load']();flush();
  assert.equal(calls.at(-1).completed,1);
  context.window.weqRemoteResourceLoads={};
  const before=calls.length;
  vm.runInContext(script,context); mutations();flush();assert.equal(calls.length,before);
  const large={name:failed.name,responseStatus:200,encodedBodySize:9000,decodedBodySize:80000};
  callback({getEntries:()=>[large]});flush();
  assert.deepEqual(calls.at(-1),{completed:2,total:2});
  context.window.weqRemoteStartup={state:'ready'};events['weq-remote-startup']();
  assert.equal(disconnected,2);assert.equal(events['weq-remote-startup'],undefined);
}
''', str(ROOT / 'resources/web-startup-progress.js')], check=True)

    def test_unchanged_cached_and_partly_changed_resources_report_only_readiness(self):
        subprocess.run(['node', '-e', r'''
const vm = require('node:vm');
const assert = require('node:assert/strict');
const script = require('node:fs').readFileSync(process.argv[1], 'utf8');
for (const source of ['all-cached', 'mixed', 'all-network']) {
  const calls = [];
  const paths = ['/assets/small-12345678.css', '/assets/large-12345678.js'];
  const context = {
    URL, Set, JSON, Array,
    location:{href:'https://computer.invalid/',origin:'https://computer.invalid'},
    document:{querySelector:()=>({content:JSON.stringify({version:1,resources:paths.map((path,i)=>({path,size:i?9000000:1000}))})}),addEventListener(){},removeEventListener(){}},
    performance:{getEntriesByType:()=>paths.map((path,i)=>({name:'https://computer.invalid'+path,
      transferSize:source==='all-cached'||(source==='mixed'&&i===0)?0:9000300,
      encodedBodySize:source==='all-cached'?0:9000000,decodedBodySize:source==='all-cached'?0:20000000}))},
    MutationObserver:class {observe(){} disconnect(){}}, clearTimeout(){},
    window:{weqRemoteStartup:{state:'ready'},weqRemoteResourceLoads:Object.fromEntries(paths.map(path=>[path,true])),
      webkit:{messageHandlers:{weqResources:{postMessage:value=>calls.push(value)}}},addEventListener(){},removeEventListener(){}},
  };
  vm.runInNewContext(script,context);
  assert.deepEqual(JSON.parse(JSON.stringify(calls)),[{completed:2,total:2}]);
  assert.equal(context.window.weqRemoteStartup.state,'ready');
}
''', str(ROOT / 'resources/web-startup-progress.js')], check=True)


if __name__ == '__main__':
    unittest.main()
