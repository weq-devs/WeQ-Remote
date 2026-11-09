import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release_assets', ROOT / 'scripts/release_assets.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
sys.path.insert(0, str(ROOT / 'apps/android/scripts'))
spec = importlib.util.spec_from_file_location('android_build', ROOT / 'apps/android/scripts/build.py')
android_build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(android_build)
COMMIT = 'a' * 40


class ReleaseAssetsTests(unittest.TestCase):
    def artifacts(self, root, ipa_version=None, version='0.1.0', ipa_release_version=None):
        ios_version = version.split('b', 1)[0]
        inputs = root / 'inputs'
        for platform in ('android', 'ios'):
            (inputs / platform).mkdir(parents=True)
        apk = inputs / 'android' / f'weq-remote-{version}-arm64.apk'
        with zipfile.ZipFile(apk, 'w') as archive:
            archive.writestr('classes.dex', b'synthetic fixture')
        ipa = inputs / 'ios/weq-remote-unsigned.ipa'
        binary = struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
        binary += struct.pack('<6I', 0x32, 24, 2, 0x110000, 0x1B0000, 0)
        with zipfile.ZipFile(ipa, 'w') as archive:
            prefix = 'Payload/WeQRemote.app/'
            archive.writestr(prefix + 'Info.plist', plistlib.dumps({
                'CFBundleIdentifier': release.IDENTITY, 'CFBundleShortVersionString': ipa_version or ios_version,
                'WeQReleaseVersion': ipa_release_version or version,
                'CFBundleSupportedPlatforms': ['iPhoneOS']}))
            archive.writestr(prefix + 'WeQRemote', binary)
            archive.writestr(prefix + 'Frameworks/TailscaleKit.framework/TailscaleKit', binary)
        for path in (apk, ipa):
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            (path.parent / 'SHA256SUMS').write_text(digest + '  ./' + path.name + '\n')
            record = {'sourceCommit': COMMIT, 'sourceDirty': False}
            if path == apk:
                record.update(identity={'name': release.IDENTITY, 'versionName': version, 'versionCode': '4'},
                              filename=apk.name, sha256=digest)
                name = 'android-build.json'
            else:
                record['artifact'] = {'version': ios_version, 'releaseVersion': version, 'signed': False,
                                      'bundleIdentifier': release.IDENTITY, 'sha256': digest}
                name = 'build.json'
            (path.parent / name).write_text(json.dumps(record))
        return inputs

    def test_beta_release_preserves_label_with_numeric_ios_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = self.artifacts(root, version='1.0.0b1')
            release.prepare('v1.0.0b1', COMMIT, inputs, root / 'release')
            self.assertTrue((root / 'release/weq-remote-1.0.0b1-ios-arm64-unsigned.ipa').is_file())
            self.assertTrue((root / 'release/weq-remote-1.0.0b1-android-arm64.apk').is_file())

    def test_beta_label_and_numeric_version_checked_independently(self):
        for overrides in ({'ipa_release_version': '1.0.0b2'}, {'ipa_version': '1.0.1'}):
            with self.subTest(overrides=overrides), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                inputs = self.artifacts(root, version='1.0.0b1', **overrides)
                with self.assertRaisesRegex(ValueError, 'IPA identity/version'):
                    release.prepare('v1.0.0b1', COMMIT, inputs, root / 'release')
                self.assertFalse((root / 'release').exists())

    def test_beta_provenance_requires_release_label(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = self.artifacts(root, version='1.0.0b1')
            path = inputs / 'ios/build.json'
            record = json.loads(path.read_text())
            del record['artifact']['releaseVersion']
            path.write_text(json.dumps(record))
            with self.assertRaisesRegex(ValueError, 'iOS provenance'):
                release.prepare('v1.0.0b1', COMMIT, inputs, root / 'release')

    def test_beta_tag_format(self):
        for tag in ('v1.0.0b1', 'v1.0.0b12'):
            self.assertEqual(release.version_from_tag(tag), tag[1:])
        for tag in ('v1.0.0b0', 'v1.0.0b01', 'v1.0.0b', 'v1.0.0b1/escape', 'v1.0.0b1;echo secret'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.version_from_tag(tag)

    def test_prepare_whitelisted_versioned_files_and_checksums(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = self.artifacts(root)
            (inputs / 'android/debug.keystore').write_text('must not publish')
            output = root / 'release'
            release.prepare('v0.1.0', COMMIT, inputs, output)
            self.assertEqual({p.name for p in output.iterdir()}, {
                'weq-remote-0.1.0-ios-arm64-unsigned.ipa', 'weq-remote-0.1.0-android-arm64.apk',
                'ios-build.json', 'android-build.json', 'SHA256SUMS'})
            for line in (output / 'SHA256SUMS').read_text().splitlines():
                digest, name = line.split()
                self.assertEqual(hashlib.sha256((output / name).read_bytes()).hexdigest(), digest)

    def test_tampered_artifact_is_rejected_before_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = self.artifacts(root)
            (inputs / 'android/weq-remote-0.1.0-arm64.apk').write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                release.prepare('v0.1.0', COMMIT, inputs, root / 'release')
            self.assertFalse((root / 'release').exists())

    def test_wrong_source_dirty_or_test_identity_is_rejected(self):
        for key, value in (('sourceCommit', 'b' * 40), ('sourceDirty', True),
                           ('identity', {'name': release.IDENTITY + '.test', 'versionName': '0.1.0'})):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                inputs = self.artifacts(root)
                path = inputs / 'android/android-build.json'
                record = json.loads(path.read_text())
                record[key] = value
                path.write_text(json.dumps(record))
                with self.assertRaises(ValueError):
                    release.prepare('v0.1.0', COMMIT, inputs, root / 'release')
                self.assertFalse((root / 'release').exists())

    def test_actual_ipa_version_checked_independently_of_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = self.artifacts(root, ipa_version='0.3.2')
            with self.assertRaisesRegex(ValueError, 'IPA identity/version'):
                release.prepare('v0.1.0', COMMIT, inputs, root / 'release')

    def test_existing_output_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = self.artifacts(root)
            output = root / 'release'
            output.mkdir()
            (output / 'original').write_text('preserve')
            with self.assertRaises(FileExistsError):
                release.prepare('v0.1.0', COMMIT, inputs, output)
            self.assertEqual((output / 'original').read_text(), 'preserve')

    def test_tags_and_source_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'apps/android').mkdir(parents=True)
            manifest = ET.Element('manifest', {'{http://schemas.android.com/apk/res/android}versionName': '0.1.0'})
            ET.ElementTree(manifest).write(root / 'apps/android/AndroidManifest.xml')
            notes = root / 'docs/releases/0.1.0.md'
            notes.parent.mkdir(parents=True)
            notes.write_text('Synthetic release notes')
            self.assertEqual(release.check_tag('v0.1.0', root), '0.1.0')
            for tag in ('dev', 'v01.1.0', 'v0.1.0/escape', 'v0.1.0;echo secret', 'v0.3.0'):
                with self.subTest(tag=tag), self.assertRaises(ValueError):
                    release.check_tag(tag, root)
            notes.unlink()
            with self.assertRaisesRegex(ValueError, 'Missing release notes'):
                release.check_tag('v0.1.0', root)

    def test_apk_badging_uses_actual_tool_output_fields(self):
        badging = "package: name='io.github.weqdevs.remote' versionCode='4' versionName='0.1.0' platformBuildVersionName='16'\nminSdkVersion:'26'\n"
        self.assertEqual(android_build.apk_identity(badging), {
            'name': release.IDENTITY, 'versionCode': '4', 'versionName': '0.1.0'})
        with self.assertRaises((KeyError, StopIteration)):
            android_build.apk_identity("package: name='io.github.weqdevs.remote'\n")


if __name__ == '__main__':
    unittest.main()
