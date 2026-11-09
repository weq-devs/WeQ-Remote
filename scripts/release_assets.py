"""校验同轮构建产物，准备白名单 Release 附件；不处理认证或发布。"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'apps/ios/scripts'))
from package_unsigned import validate_macho

IDENTITY = 'io.github.weqdevs.remote'


def version_from_tag(tag):
    if not re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:b[1-9][0-9]*)?', tag):
        raise ValueError('Expected an existing vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCHbN tag')
    return tag[1:]


def check_tag(tag, root=ROOT):
    version = version_from_tag(tag)
    manifest = ET.parse(root / 'apps/android/AndroidManifest.xml').getroot()
    if manifest.get('{http://schemas.android.com/apk/res/android}versionName') != version:
        raise ValueError('Android source version does not match tag')
    if not (root / 'docs/releases' / (version + '.md')).is_file():
        raise ValueError('Missing release notes')
    return version


def checked_artifact(directory, filename):
    lines = (directory / 'SHA256SUMS').read_text().splitlines()
    if len(lines) != 1:
        raise ValueError('Expected exactly one product per platform')
    digest, name = lines[0].split(maxsplit=1)
    if name.removeprefix('./') != filename or not re.fullmatch('[0-9a-f]{64}', digest):
        raise ValueError('Unexpected checksum entry')
    path = directory / filename
    if path.is_symlink() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise ValueError('Artifact checksum mismatch')
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError('Corrupt archive')
    return path, digest


def prepare(tag, commit, artifacts, output):
    version = version_from_tag(tag)
    ios_version = version.split('b', 1)[0]
    if not re.fullmatch('[0-9a-f]{40}', commit):
        raise ValueError('Expected full source commit')
    android, android_digest = checked_artifact(artifacts / 'android', f'weq-remote-{version}-arm64.apk')
    ipa, ipa_digest = checked_artifact(artifacts / 'ios', 'weq-remote-unsigned.ipa')
    ios_record = artifacts / 'ios/build.json'
    android_record = artifacts / 'android/android-build.json'
    ios = json.loads(ios_record.read_text())
    apk = json.loads(android_record.read_text())
    for record in (ios, apk):
        if record.get('sourceCommit') != commit or record.get('sourceDirty') is not False:
            raise ValueError('Artifact source commit/cleanliness mismatch')
    if (ios['artifact'].get('version') != ios_version
            or ios['artifact'].get('releaseVersion', ios['artifact'].get('version')) != version
            or ios['artifact'].get('signed') is not False
            or ios['artifact'].get('bundleIdentifier') != IDENTITY or ios['artifact'].get('sha256') != ipa_digest):
        raise ValueError('iOS provenance mismatch')
    if (apk['identity'].get('versionName') != version or apk['identity'].get('name') != IDENTITY
            or apk.get('filename') != android.name or apk.get('sha256') != android_digest):
        raise ValueError('Android provenance mismatch')
    with zipfile.ZipFile(ipa) as archive:
        root = 'Payload/WeQRemote.app/'
        info = plistlib.loads(archive.read(root + 'Info.plist'))
        if (info.get('CFBundleIdentifier') != IDENTITY or info.get('CFBundleShortVersionString') != ios_version
                or info.get('WeQReleaseVersion', info.get('CFBundleShortVersionString')) != version
                or info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']):
            raise ValueError('IPA identity/version mismatch')
        for name in archive.namelist():
            if '_CodeSignature' in name or name.endswith(('.mobileprovision', '.p12', '.p8')):
                raise ValueError('Signing material in unsigned IPA')
        validate_macho(archive.read(root + 'WeQRemote'))
        validate_macho(archive.read(root + 'Frameworks/TailscaleKit.framework/TailscaleKit'))
    output.mkdir(parents=True, exist_ok=False)
    files = [(android, f'weq-remote-{version}-android-arm64.apk'),
             (ipa, f'weq-remote-{version}-ios-arm64-unsigned.ipa'),
             (ios_record, 'ios-build.json'), (android_record, 'android-build.json')]
    sums = []
    for source, name in files:
        destination = output / name
        shutil.copyfile(source, destination)
        sums.append(hashlib.sha256(destination.read_bytes()).hexdigest() + '  ' + name)
    (output / 'SHA256SUMS').write_text('\n'.join(sums) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('check-tag').add_argument('tag')
    command = commands.add_parser('prepare')
    for name in ('tag', 'commit', 'artifacts', 'output'):
        command.add_argument(name)
    args = parser.parse_args()
    if args.command == 'check-tag':
        print(check_tag(args.tag))
    else:
        prepare(args.tag, args.commit, Path(args.artifacts), Path(args.output))


if __name__ == '__main__':
    main()
