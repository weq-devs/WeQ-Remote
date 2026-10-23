import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
IDENTITY = 'io.github.weqdevs.remote'


class ProjectIdentityTests(unittest.TestCase):
    def test_android_namespace_and_source_paths_agree(self):
        manifest = ET.parse(ROOT / 'apps/android/AndroidManifest.xml').getroot()
        self.assertEqual(manifest.get('package'), IDENTITY)
        android = '{http://schemas.android.com/apk/res/android}'
        for activity in manifest.findall('application/activity'):
            self.assertTrue(activity.get(android + 'name').startswith(IDENTITY + '.'))
        for folder in ('src', 'testsrc'):
            paths = list((ROOT / 'apps/android' / folder).rglob('*.java'))
            self.assertTrue(paths)
            for path in paths:
                self.assertEqual(path.parent.relative_to(ROOT / 'apps/android' / folder).as_posix(), IDENTITY.replace('.', '/'))
                self.assertTrue(path.read_text().startswith('package ' + IDENTITY + ';'))
        for name in ('build.py', 'check-protocol.sh', 'integration.py'):
            self.assertIn(IDENTITY, (ROOT / 'apps/android/scripts' / name).read_text())

    def test_ios_bundle_keychain_and_url_identity_agree(self):
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER: ' + IDENTITY, (ROOT / 'apps/ios/project.yml').read_text())
        self.assertIn('"' + IDENTITY + '.connection"', (ROOT / 'apps/ios/Sources/RemoteProtocol.swift').read_text())
        import plistlib
        info = plistlib.loads((ROOT / 'apps/ios/Support/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleURLTypes'][0]['CFBundleURLName'], IDENTITY + '.pair')

    def test_framework_must_be_explicit_and_existing(self):
        script = ROOT / 'apps/ios/scripts/generate-project.sh'
        env = dict(os.environ)
        env.pop('WEQ_TAILSCALE_FRAMEWORK', None)
        missing = subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn('WEQ_TAILSCALE_FRAMEWORK', missing.stderr)
        with tempfile.TemporaryDirectory(prefix='remote framework ') as directory:
            env['WEQ_TAILSCALE_FRAMEWORK'] = str(Path(directory) / 'missing.xcframework')
            invalid = subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn('statusJSON()', invalid.stderr)


if __name__ == '__main__':
    unittest.main()
