import importlib.util
import io
import os
from pathlib import Path
import plistlib
import struct
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'apps/ios/scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


package = load('package_unsigned')
builder = load('build_tailscale')
with patch.dict('sys.modules', {'build_tailscale': builder, 'package_unsigned': package}):
    unsigned = load('build_unsigned_ipa')


def macho(platform=2, signature=False, cpu=0x0100000C):
    commands = struct.pack('<6I', 0x32, 24, platform, 0x110000, 0x1B0000, 0)
    if signature:
        commands += struct.pack('<4I', 0x1D, 16, 0, 8)
    return struct.pack('<8I', 0xFEEDFACF, cpu, 0, 2, 2 if signature else 1, len(commands), 0, 0) + commands


class UnsignedIPATests(unittest.TestCase):
    def app(self, root):
        app = root / 'WeQRemote.app'
        app.mkdir()
        (app / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'io.github.weqdevs.remote', 'CFBundleExecutable': 'WeQRemote',
            'CFBundleSupportedPlatforms': ['iPhoneOS'], 'DTPlatformName': 'iphoneos',
            'CFBundleShortVersionString': '0.3.2', 'CFBundleVersion': '5'}))
        executable = app / 'WeQRemote'
        executable.write_bytes(macho())
        executable.chmod(0o755)
        return app

    def test_device_binary_and_zip_payload_permissions(self):
        with tempfile.TemporaryDirectory(prefix='unsigned ipa ') as directory:
            root = Path(directory)
            app = self.app(root)
            (app / 'linked-resource').symlink_to('Info.plist')
            output = root / 'unsigned.ipa'
            result = package.package_app(app, output)
            self.assertFalse(result['signed'])
            with zipfile.ZipFile(output) as archive:
                self.assertIn('Payload/WeQRemote.app/Info.plist', archive.namelist())
                self.assertEqual(archive.read('Payload/WeQRemote.app/linked-resource'), b'Info.plist')
                self.assertTrue((archive.getinfo('Payload/WeQRemote.app/WeQRemote').external_attr >> 16) & 0o111)

    def test_rejects_simulator_signed_wrong_architecture_and_truncated_binary(self):
        for data in (macho(platform=7), macho(signature=True), macho(cpu=0x01000007), b'fake', macho()[:-1]):
            with self.subTest(data=data):
                with self.assertRaises(ValueError):
                    package.validate_macho(data)

    def test_embedded_framework_signature_is_rejected(self):
        for binary in (macho(signature=True), b'\xca\xfe\xba\xbf' + b'\0' * 28):
            with self.subTest(binary=binary), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app = self.app(root)
                framework = app / 'Frameworks/TailscaleKit.framework'
                framework.mkdir(parents=True)
                (framework / 'TailscaleKit').write_bytes(binary)
                with self.assertRaises(ValueError):
                    package.package_app(app, root / 'bad.ipa')
                self.assertFalse((root / 'bad.ipa').exists())

    def test_signing_material_and_external_symlinks_are_rejected(self):
        for name in ('embedded.mobileprovision', '_CodeSignature', 'private.p12', 'escape'):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app = self.app(root)
                if name == 'escape':
                    outside = root / 'outside'
                    outside.write_text('must not package')
                    (app / name).symlink_to(outside)
                else:
                    (app / name).write_text('must not package')
                with self.assertRaises(ValueError):
                    package.package_app(app, root / 'bad.ipa')
                self.assertFalse((root / 'bad.ipa').exists())

    def test_existing_ipa_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = self.app(root)
            output = root / 'original.ipa'
            output.write_bytes(b'original data')
            with self.assertRaises(FileExistsError):
                package.package_app(app, output)
            self.assertEqual(output.read_bytes(), b'original data')
            self.assertEqual(set(root.iterdir()), {app, output})


class FrameworkSourceTests(unittest.TestCase):
    def test_existing_output_fails_before_native_build(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path(directory) / 'original'
            original.write_text('preserve')
            with patch('sys.argv', ['build_unsigned_ipa.py', '--output-dir', directory]), \
                 patch.object(unsigned, 'capture', return_value='Version: 2.46.0'), \
                 patch.object(unsigned, 'build_framework', side_effect=AssertionError('must not start build')):
                with self.assertRaises(ValueError):
                    unsigned.main()
            self.assertEqual(original.read_text(), 'preserve')

    def test_isolated_project_relocates_all_local_inputs(self):
        root = Path('/project with spaces/ios')
        spec = {'targets': {'App': {
            'sources': ['Sources', {'path': 'Support/LICENSE', 'buildPhase': 'resources'}],
            'dependencies': [{'framework': '/external path/TailscaleKit.xcframework'}],
            'settings': {'base': {'INFOPLIST_FILE': 'Support/Info.plist',
                                  'CODE_SIGN_ENTITLEMENTS': 'Support/App.entitlements',
                                  'PRODUCT_BUNDLE_IDENTIFIER': 'io.github.weqdevs.remote'}}}}}
        target = unsigned.relocate_spec(spec, root)['targets']['App']
        self.assertEqual(target['sources'][0]['path'], str(root / 'Sources'))
        self.assertEqual(target['sources'][1], {'path': str(root / 'Support/LICENSE'), 'buildPhase': 'resources'})
        self.assertEqual(target['dependencies'][0]['framework'], '/external path/TailscaleKit.xcframework')
        self.assertEqual(target['settings']['base']['INFOPLIST_FILE'], str(root / 'Support/Info.plist'))
        self.assertEqual(target['settings']['base']['CODE_SIGN_ENTITLEMENTS'], str(root / 'Support/App.entitlements'))
        self.assertEqual(target['settings']['base']['PRODUCT_BUNDLE_IDENTIFIER'], 'io.github.weqdevs.remote')

    def test_extract_pinned_layout_with_executable_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'source.tar.gz'
            with tarfile.open(archive, 'w:gz') as stream:
                member = tarfile.TarInfo('libtailscale-test/script.sh')
                member.mode = 0o755
                member.size = 2
                stream.addfile(member, io.BytesIO(b'hi'))
            builder.extract_source(archive, root / 'source', 'test')
            self.assertEqual((root / 'source/script.sh').read_bytes(), b'hi')
            self.assertTrue(os.access(root / 'source/script.sh', os.X_OK))

    def test_source_archive_traversal_links_and_wrong_revision_fail(self):
        for name, link in (('libtailscale-test/../../escape', False), ('libtailscale-other/file', False),
                           ('/absolute', False), ('libtailscale-test/link', True)):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive = root / 'source.tar.gz'
                with tarfile.open(archive, 'w:gz') as stream:
                    member = tarfile.TarInfo(name)
                    if link:
                        member.type = tarfile.SYMTYPE
                        member.linkname = '/outside'
                    stream.addfile(member)
                with self.assertRaises(ValueError):
                    builder.extract_source(archive, root / 'source', 'test')
                self.assertFalse((root / 'source').exists())

    def test_compiler_arguments_with_spaces_are_quoted_for_go(self):
        self.assertEqual(builder.quote_go_argument('/tool path/clang'), "'/tool path/clang'")
        self.assertEqual(builder.quote_go_argument('arm64'), 'arm64')
        with self.assertRaises(ValueError):
            builder.quote_go_argument('/both\' and"/clang')


if __name__ == '__main__':
    unittest.main()
