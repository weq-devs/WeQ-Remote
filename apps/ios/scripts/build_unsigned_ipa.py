#!/usr/bin/env python3
"""完整构建未签名真机 IPA；不接触证书、设备或模拟器。"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import tempfile

from build_tailscale import ROOT, SUPPORT, build_framework, capture, run
from package_unsigned import package_app


def relocate_spec(spec, root):
    for target in spec['targets'].values():
        sources = []
        for item in target.get('sources', []):
            item = {'path': item} if isinstance(item, str) else dict(item)
            item['path'] = str(root / item['path'])
            sources.append(item)
        target['sources'] = sources
        for dependency in target.get('dependencies', []):
            if 'framework' in dependency:
                dependency['framework'] = str(root / dependency['framework'])
        for key, value in target.get('settings', {}).get('base', {}).items():
            if key in ('INFOPLIST_FILE', 'CODE_SIGN_ENTITLEMENTS'):
                target['settings']['base'][key] = str(root / value)
    return spec


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--publish-local', action='store_true', help='Publish the completed IPA to the local SideStore source')
    args = parser.parse_args()
    dependency = json.loads((SUPPORT / 'tailscale-dependency.json').read_text())
    if capture(['xcodegen', '--version']) != 'Version: ' + dependency['xcodegenVersion']:
        raise ValueError('Use the XcodeGen version pinned in tailscale-dependency.json')
    build = ROOT / '.build'
    destination = args.output_dir or build / 'unsigned-ipa' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    destination = destination.resolve()
    if destination.exists() and (not destination.is_dir() or any(destination.iterdir())):
        raise ValueError('Output directory must be empty; existing files were preserved')
    framework = build_framework()
    with tempfile.TemporaryDirectory(prefix='unsigned-', dir=build) as directory:
        temporary = Path(directory)
        environment = dict(os.environ, WEQ_TAILSCALE_FRAMEWORK=str(framework))
        project = temporary / 'project'
        project.mkdir()
        isolated_spec = project / 'project.json'
        run(['xcodegen', 'dump', '--spec', ROOT / 'project.yml', '--type', 'json', '--file', isolated_spec], env=environment)
        spec = relocate_spec(json.loads(isolated_spec.read_text()), ROOT)
        isolated_spec.write_text(json.dumps(spec))
        run(['xcodegen', 'generate', '--spec', isolated_spec, '--project', project], env=environment)
        derived = temporary / 'derived'
        run(['xcodebuild', '-project', project / 'WeQRemote.xcodeproj', '-scheme', 'WeQRemote',
             '-configuration', 'Release', '-destination', 'generic/platform=iOS', '-derivedDataPath', derived,
             'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO', 'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO',
             'CODE_SIGN_IDENTITY=', 'DEVELOPMENT_TEAM=', 'build'])
        app = derived / 'Build/Products/Release-iphoneos/WeQRemote.app'
        destination.mkdir(parents=True, exist_ok=True)
        if any(destination.iterdir()):
            raise ValueError('Output directory changed during build; existing files were preserved')
        artifact = package_app(app, destination / 'weq-remote-unsigned.ipa')
        provenance = {'artifact': artifact, 'sourceCommit': capture(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']),
                      'sourceDirty': bool(capture(['git', '-C', str(ROOT), 'status', '--porcelain'])),
                      'framework': json.loads((framework.parent / 'build.json').read_text()),
                      'xcodegen': dependency['xcodegenVersion'], 'builtAt': datetime.now(timezone.utc).isoformat()}
        (destination / 'build.json').write_text(json.dumps(provenance, indent=2) + '\n')
        (destination / 'SHA256SUMS').write_text(artifact['sha256'] + '  ' + artifact['filename'] + '\n')
    ipa = destination / artifact['filename']
    if args.publish_local:
        run([os.sys.executable, ROOT.parents[1] / 'scripts/publish_local_ios.py', '--ipa', ipa])
    print(ipa)


if __name__ == '__main__':
    main()
