import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class IOSConnectionHealthTests(unittest.TestCase):
    def test_injected_bridge_preserves_requests_and_filters_unrelated_failures(self):
        source = (ROOT / 'apps/ios/Sources/WebContainer.swift').read_text()
        script = source.split('static let connectionHealthScript = """', 1)[1].split('"""', 1)[0]
        subprocess.run(['node', '-e', r'''
const vm = require('node:vm');
const assert = require('node:assert/strict');
const calls = [], requests = [];
let now = 0, failure;
class Socket {
  static OPEN = 1;
  constructor(...args) { this.args = args; this.events = {}; }
  addEventListener(name, fn) { this.events[name] = fn; }
}
const context = {
  URL, location:{href:'https://computer.invalid/chat',origin:'https://computer.invalid'},
  performance:{now:()=>now},
  window:{WebSocket:Socket,
    fetch(...args){requests.push(args);return failure?Promise.reject(failure):Promise.resolve({status:200});},
    webkit:{messageHandlers:{weqConnection:{postMessage:value=>calls.push(value)}}}},
};
vm.createContext(context);
vm.runInContext(process.argv[1], context);
const wrapped = context.window.fetch;
vm.runInContext(process.argv[1], context);
assert.equal(context.window.fetch, wrapped);
(async()=>{
  const options = {method:'POST',body:'untouched'};
  assert.equal((await wrapped('/trpc',options)).status,200);
  assert.equal(requests[0][1], options);
  assert.equal(calls.length,0);
  failure = {name:'TypeError'};
  const reject = async input => {
    await assert.rejects(wrapped(input), error=>error===failure);
  };
  await reject('https://external.invalid/file');
  assert.equal(calls.length,0);
  failure = {name:'AbortError'};
  await reject('/trpc');
  assert.equal(calls.length,0);
  failure = {name:'TypeError'};
  await reject({url:'https://computer.invalid/trpc'});
  assert.equal(calls.length,1);
  await reject(new URL('https://computer.invalid/trpc'));
  assert.equal(calls.length,1);
  now = 1001;
  await reject('/trpc');
  assert.equal(calls.length,2);
  const ws = new context.window.WebSocket('wss://computer.invalid/trpc-ws',['protocol']);
  assert.ok(ws instanceof Socket);
  assert.equal(context.window.WebSocket.OPEN,Socket.OPEN);
  assert.deepEqual(ws.args,['wss://computer.invalid/trpc-ws',['protocol']]);
  now = 2002;
  ws.events.close({wasClean:true});
  assert.equal(calls.length,2);
  ws.events.close({wasClean:false});
  assert.equal(calls.length,3);
  const external = new context.window.WebSocket('wss://external.invalid/ws');
  assert.equal(external.events.error,undefined);
})().catch(error=>{console.error(error);process.exitCode=1;});
''', script], check=True)


if __name__ == '__main__':
    unittest.main()
