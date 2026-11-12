#!/usr/bin/env python3
"""Validate an unsigned device IPA, then publish to an installed local source."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'apps/ios/scripts'))
from package_unsigned import validate_macho


def validate(path):
    with zipfile.ZipFile(path) as archive:
        prefix = 'Payload/WeQRemote.app/'
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        if info.get('CFBundleIdentifier') != 'io.github.weqdevs.remote' or info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
            raise ValueError('Expected WeQ Remote for a physical device')
        for name in archive.namelist():
            if name.endswith(('.p12', '.p8', '.mobileprovision')) or '_CodeSignature' in name:
                raise ValueError('Expected an unsigned IPA without signing material')
            if not name.endswith('/'):
                with archive.open(name) as stream:
                    header = stream.read(4)
                if header == b'\xcf\xfa\xed\xfe':
                    validate_macho(archive.read(name))
        validate_macho(archive.read(prefix + info['CFBundleExecutable']))
        validate_macho(archive.read(prefix + 'Frameworks/TailscaleKit.framework/TailscaleKit'))
        return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', type=Path, required=True)
    args = parser.parse_args()
    info = validate(args.ipa)
    publisher = Path(os.environ.get('IOS_APP_DISTRIBUTION', Path.home() / 'Projects/ios-app-distribution/distribution.py'))
    if not publisher.is_file():
        parser.error('Install ios-app-distribution or set IOS_APP_DISTRIBUTION to its CLI')
    version = info.get('WeQReleaseVersion', info['CFBundleShortVersionString'])
    subprocess.run([sys.executable, str(publisher), 'publish', '--ipa', str(args.ipa.resolve()),
                    '--icon', str(ROOT / 'resources/brand/weq.png'),
                    '--notes', f'{version}：本机 SideStore 安装与更新。'], check=True)


if __name__ == '__main__':
    main()
