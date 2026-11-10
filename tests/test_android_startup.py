import json
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'apps/android/src/io/github/weqdevs/remote'


class AndroidStartupTests(unittest.TestCase):
    def test_subscribe_before_page_finished(self):
        source = (SOURCE / 'MainActivity.java').read_text()
        committed = source.split('@Override public void onPageCommitVisible', 1)[1].split('@Override', 1)[0]
        self.assertIn('webFeatures.observeStartup()', committed)
        # 前台核验不能用“尚未就绪”代替“本地代理丢失”。
        verify = source.split('private void verify()', 1)[1].split('private void openWeb()', 1)[0]
        self.assertIn('WebStartup.shouldOpenWeb(restoring, webView != null, webReady)', verify)

    def test_multi_route_updates_network_label(self):
        source = (SOURCE / 'MainActivity.java').read_text()
        start = source.split('private void startMulti(', 1)[1].split('private void updateConnection(', 1)[0]
        self.assertIn('networkState.setText("网络：正在探测连接入口")', start)
        self.assertIn('boolean embedded = client.usesEmbeddedNetwork();', start)
        self.assertIn('networkState.setText(embedded ? "网络：已连接（内嵌 Tailscale）" : "网络：已连接（系统网络）")', start)
        self.assertLess(start.index('client.connectRoutes();'), start.index('boolean embedded ='))
        # 网络状态在 worker 读取，UI 回调使用快照，避免在主线程查询 Go 客户端。
        self.assertLess(start.index('boolean embedded ='), start.index('main.post(', start.index('client.connectRoutes();')))

    def test_bridge_reads_early_state_and_later_events_without_duplicate_listeners(self):
        source = (SOURCE / 'WebFeatures.java').read_text()
        script = re.search(r'view.evaluateJavascript\(("[^\n]*weqRemoteStartup[^\n]*"), null\);', source)
        self.assertIsNotNone(script)
        subprocess.run(['node', '-e', r'''
const vm = require('node:vm');
const assert = require('node:assert/strict');
const script = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
for (const early of [undefined, {state:'ready'}, {state:'loading', message:'preparing'}]) {
  const calls = [], listeners = [];
  const window = {weqRemoteStartup:early, addEventListener:(name, fn) => listeners.push(fn)};
  const context = vm.createContext({window, weqRemoteLinks:{startup:(...args) => calls.push(args)}});
  vm.runInContext(script, context);
  assert.equal(calls.length, early ? 1 : 0);
  if (early) assert.equal(calls[0][0], early.state);
  vm.runInContext(script, context);
  assert.equal(listeners.length, 1);
  window.weqRemoteStartup = {state:'ready'};
  listeners[0]();
  assert.equal(calls.at(-1)[0], 'ready');
}
'''], input=json.dumps(json.loads(script.group(1))), text=True, check=True)


if __name__ == '__main__':
    unittest.main()
