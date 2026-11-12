import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('swiftc') and shutil.which('javac'), '需要 Swift 和 JDK')
class ConnectionHealthParityTests(unittest.TestCase):
    def test_both_production_state_machines_match_the_same_timeline_vectors(self):
        vectors = json.loads((ROOT / 'tests/connection-health-vectors.json').read_text())
        with tempfile.TemporaryDirectory(prefix='health-parity-', dir=ROOT / 'tests') as directory:
            work = Path(directory)
            subprocess.run(['swiftc', str(ROOT / 'apps/ios/Sources/ConnectionHealth.swift'),
                            str(ROOT / 'tests/health_parity/main.swift'), '-o', str(work / 'health')], check=True)
            subprocess.run(['javac', '--release', '8', '-d', str(work),
                            str(ROOT / 'apps/android/src/io/github/weqdevs/remote/ConnectionHealth.java'),
                            str(ROOT / 'tests/health_parity/HealthParity.java')], check=True)
            commands = [[str(work / 'health')], ['java', '-cp', str(work), 'io.github.weqdevs.remote.HealthParity']]
            for vector in vectors:
                timeline = ''.join(f'{op}\t{now}\t{arg}\n' for op, now, arg, _ in vector['steps'])
                expected = ['\t'.join(map(str, step[3])) for step in vector['steps']]
                for command in commands:
                    with self.subTest(case=vector['name'], platform=command[0]):
                        output = subprocess.run(command, input=timeline, text=True, capture_output=True, check=True)
                        self.assertEqual(output.stdout.splitlines(), expected)
