import json
from pathlib import Path
import re
import subprocess
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / 'apps/android/src/io/github/weqdevs/remote'


class NativeWebSurfaceTests(unittest.TestCase):
    def test_android_retains_activity_for_rotation_and_size_changes(self):
        android = '{http://schemas.android.com/apk/res/android}'
        manifest = ET.parse(ROOT / 'apps/android/AndroidManifest.xml')
        activity = next(item for item in manifest.findall('./application/activity')
                        if item.get(android + 'name').endswith('.MainActivity'))
        handled = set(activity.get(android + 'configChanges', '').split('|'))
        self.assertTrue({'orientation', 'screenSize', 'screenLayout', 'smallestScreenSize'} <= handled)
        source = (ANDROID / 'MainActivity.java').read_text()
        changed = source.split('void onConfigurationChanged(', 1)[1].split('@Override', 1)[0]
        self.assertNotIn('closeWeb()', changed)
        self.assertNotIn('stopNetwork(', changed)
        back = source.split('void onBackPressed()', 1)[1].split('private JSONObject', 1)[0]
        self.assertLess(back.index('exitFullscreen()'), back.index('evaluateJavascript'))

    def test_ios_media_bridge_preserves_options_and_forces_command_type(self):
        source = (ROOT / 'apps/ios/Sources/RemoteNativeMedia.swift').read_text()
        script = re.search(r'static let script = """\n(.*?)\n    """', source, re.S)
        self.assertIsNotNone(script)
        subprocess.run(['node', '-e', r'''
const vm = require('node:vm');
const assert = require('node:assert/strict');
const script = JSON.parse(require('node:fs').readFileSync(0,'utf8'));
const calls = [];
const window = {webkit:{messageHandlers:{weqMedia:{postMessage:value=>calls.push(value)}}}};
vm.runInNewContext(script, {window});
window.weqRemoteMedia.start({id:'fixture',audio:true,video:{width:320,height:184,fps:15},action:'stop'});
window.weqRemoteMedia.stop('fixture');
assert.equal(calls[0].action,'start');
assert.equal(calls[0].audio,true);
assert.equal(calls[0].video.width,320);
assert.deepEqual(JSON.parse(JSON.stringify(calls[1])),{action:'stop',id:'fixture'});
'''], input=json.dumps(script.group(1)), text=True, check=True)

    def test_ios_async_external_windows_use_native_bridge_without_replacing_chat(self):
        source = (ROOT / 'apps/ios/Sources/WebContainer.swift').read_text()
        script = re.search(r'static let externalLinksScript = """\n(.*?)\n    """', source, re.S)
        self.assertIsNotNone(script)
        subprocess.run(['node', '-e', r'''
const vm = require('node:vm');
const assert = require('node:assert/strict');
const script = JSON.parse(require('node:fs').readFileSync(0,'utf8'));
const calls=[], original=[];
const location={href:'https://192.168.1.8:7691/chat',origin:'https://192.168.1.8:7691'};
const window={webkit:{messageHandlers:{weqLinks:{postMessage:value=>calls.push(value)}}},
  open:function(...args){assert.equal(this,window);original.push(args);return 'original';}};
const context={window,location,URL};
vm.runInNewContext(script,context);
vm.runInNewContext(script,context);
// 没有用户激活的异步业务回调，也必须交给原生。
Promise.resolve().then(()=>{
  assert.equal(window.open('https://qzone.qq.com/login','_blank','noopener'),null);
  assert.deepEqual(calls,['https://qzone.qq.com/login']);
  assert.equal(window.open('/_download/file','_blank'),'original');
  assert.equal(window.open('blob:https://192.168.1.8:7691/id','_blank'),'original');
  assert.equal(window.open('data:text/plain,file','_blank'),'original');
  assert.equal(window.open('about:blank','work','popup'),'original');
  assert.equal(window.open(undefined),'original');
  assert.equal(calls.length,1);
  assert.equal(original.length,5);
  assert.equal(window.open('mailto:hello@example.com','_blank'),null);
  assert.equal(calls.at(-1),'mailto:hello@example.com');
}).catch(error=>{console.error(error);process.exitCode=1;});
'''], input=json.dumps(script.group(1)), text=True, check=True)


if __name__ == '__main__':
    unittest.main()
