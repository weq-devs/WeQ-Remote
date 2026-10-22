import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('desktop_fixture', ROOT / 'scripts/desktop_fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class RepositoryBoundaryTests(unittest.TestCase):
    def test_explicit_repository_with_spaces(self):
        with tempfile.TemporaryDirectory(prefix='remote desktop fixture ') as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'package.json').write_text(json.dumps({'name': 'weq'}))
            (root / 'scripts/remote-integration-server.ts').write_text('// synthetic fixture')
            self.assertEqual(fixture.desktop_repository(root), root.resolve())
            self.assertEqual(fixture.fixture_command(root), ['pnpm', 'exec', 'tsx', str(root / 'scripts/remote-integration-server.ts')])
            with patch.dict(os.environ, {'WEQ_DESKTOP_REPO': str(root)}):
                self.assertEqual(fixture.desktop_repository(), root.resolve())

    def test_missing_or_unrelated_repository_fails_without_creating_it(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / 'missing'
            with self.assertRaises(ValueError):
                fixture.desktop_repository(missing)
            self.assertFalse(missing.exists())
            root = Path(directory)
            (root / 'package.json').write_text(json.dumps({'name': 'other'}))
            with self.assertRaises(ValueError):
                fixture.desktop_repository(root)

    def test_current_source_does_not_import_desktop_private_modules(self):
        for folder in ('apps/ios', 'apps/android'):
            for directory, folders, names in os.walk(ROOT / folder):
                folders[:] = [name for name in folders if not name.startswith('.') and not name.endswith('.xcodeproj') and name != '__pycache__']
                for name in names:
                    path = Path(directory) / name
                    if path.suffix not in ('.swift', '.go', '.java', '.py', '.ts'):
                        continue
                    source = path.read_text()
                    self.assertNotIn('../../desktop/src/', source, str(path))
                    self.assertNotIn('WeQ-upstream/apps/', source, str(path))

    def test_product_builds_do_not_require_desktop_repository(self):
        for name in ('apps/android/scripts/build.py', 'apps/ios/scripts/generate-project.sh', 'apps/ios/project.yml'):
            source = (ROOT / name).read_text()
            self.assertNotIn('WEQ_DESKTOP_REPO', source)
            self.assertNotIn('WeQ-upstream', source)


if __name__ == '__main__':
    unittest.main()
