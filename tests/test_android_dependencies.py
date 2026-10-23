import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('android_dependencies', ROOT / 'apps/android/scripts/dependencies.py')
dependencies = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dependencies)


class AndroidDependenciesTests(unittest.TestCase):
    def test_known_fixture_digest_is_not_derived_from_the_download(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # 固定的 SHA-256('abc') 是独立已知值，不复用被测实现计算预期。
            digest = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
            with patch.object(dependencies, 'ZXING_HASH', digest), patch.object(dependencies.urllib.request, 'urlopen', return_value=io.BytesIO(b'abc')):
                target = dependencies.ensure_zxing(root)
            self.assertEqual(target.read_bytes(), b'abc')
            self.assertEqual(list(target.parent.iterdir()), [target])
            with patch.object(dependencies, 'ZXING_HASH', digest), patch.object(dependencies.urllib.request, 'urlopen', side_effect=AssertionError('cached file must not download')):
                self.assertEqual(dependencies.ensure_zxing(root), target)

    def test_corrupt_cache_fails_without_replacement_or_network(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / 'deps' / 'zxing-core-3.5.3.jar'
            target.parent.mkdir()
            target.write_bytes(b'corrupt original')
            with patch.object(dependencies.urllib.request, 'urlopen', side_effect=AssertionError('must preserve corrupt cache')):
                with self.assertRaises(ValueError):
                    dependencies.ensure_zxing(root)
            self.assertEqual(target.read_bytes(), b'corrupt original')

    def test_invalid_or_oversized_download_is_not_saved(self):
        for payload in (b'not a JAR', b'x' * (dependencies.MAX_DOWNLOAD + 1)):
            with self.subTest(size=len(payload)), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with patch.object(dependencies.urllib.request, 'urlopen', return_value=io.BytesIO(payload)):
                    with self.assertRaises(ValueError):
                        dependencies.ensure_zxing(root)
                self.assertEqual(list(root.iterdir()), [])

    def test_network_failure_does_not_create_a_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(dependencies.urllib.request, 'urlopen', side_effect=TimeoutError):
                with self.assertRaises(TimeoutError):
                    dependencies.ensure_zxing(root)
            self.assertEqual(list(root.iterdir()), [])

    def test_concurrent_cache_is_verified_and_never_overwritten(self):
        digest = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        for content in (b'abc', b'other process data'):
            with self.subTest(content=content), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                target = root / 'deps' / 'zxing-core-3.5.3.jar'

                def download(*args, **kwargs):
                    target.parent.mkdir()
                    target.write_bytes(content)
                    return io.BytesIO(b'abc')

                with patch.object(dependencies, 'ZXING_HASH', digest), patch.object(dependencies.urllib.request, 'urlopen', side_effect=download):
                    if content == b'abc':
                        self.assertEqual(dependencies.ensure_zxing(root), target)
                    else:
                        with self.assertRaises(ValueError):
                            dependencies.ensure_zxing(root)
                self.assertEqual(target.read_bytes(), content)
                self.assertEqual(list(target.parent.iterdir()), [target])


if __name__ == '__main__':
    unittest.main()
