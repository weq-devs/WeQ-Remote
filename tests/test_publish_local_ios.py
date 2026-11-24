import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('publish_local_ios', ROOT / 'scripts/publish_local_ios.py')
publish_local_ios = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish_local_ios)


class LocalPublishTests(unittest.TestCase):
    def test_validation_failure_never_invokes_publisher(self):
        with patch.object(sys, 'argv', ['publish_local_ios.py', '--ipa', 'invalid.ipa']), \
             patch.object(publish_local_ios, 'validate', side_effect=ValueError('bad IPA')), \
             patch.object(publish_local_ios.subprocess, 'run') as command:
            with self.assertRaises(ValueError):
                publish_local_ios.main()
            command.assert_not_called()

    def test_publishes_existing_ipa_with_its_release_version(self):
        ipa = Path('remote.ipa').resolve()
        info = {'CFBundleShortVersionString': '1.2.3', 'WeQReleaseVersion': '1.2.3b2', 'CFBundleVersion': '42'}
        with patch.object(sys, 'argv', ['publish_local_ios.py', '--ipa', str(ipa)]), \
             patch.object(publish_local_ios, 'validate', return_value=info) as validate, \
             patch.object(Path, 'is_file', return_value=True), \
             patch.object(publish_local_ios.subprocess, 'run') as command:
            publish_local_ios.main()
        validate.assert_called_once_with(ipa)
        arguments = command.call_args.args[0]
        self.assertEqual(arguments[2:5], ['publish', '--ipa', str(ipa)])
        self.assertEqual(arguments[-2:], ['--notes', '1.2.3b2：本机 SideStore 安装与更新。'])


if __name__ == '__main__':
    unittest.main()
