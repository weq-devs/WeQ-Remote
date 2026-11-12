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

    def test_system_and_beta_version_are_not_changed(self):
        source = (ROOT / 'apps/ios/project.yml').read_text()
        self.assertIn('MARKETING_VERSION: "1.0.0"', source)
        self.assertIn('CURRENT_PROJECT_VERSION: 11', source)


if __name__ == '__main__':
    unittest.main()
