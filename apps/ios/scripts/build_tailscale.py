#!/usr/bin/env python3
"""从校验过的固定源码构建带共用网页入口的 arm64 TailscaleKit。"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
SUPPORT = ROOT / 'Support'


def run(command, cwd=None, env=None):
    subprocess.run([str(value) for value in command], cwd=cwd, env=env, check=True, stdout=sys.stderr)


def capture(command):
    return subprocess.check_output(command, text=True).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def extract_source(archive, destination, revision):
    prefix = 'libtailscale-' + revision
    with tarfile.open(archive, 'r:gz') as source:
        members = source.getmembers()
        if len(members) > 2000 or sum(member.size for member in members) > 32 * 1024 * 1024:
            raise ValueError('Source archive exceeds limits')
        seen = set()
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != prefix:
                raise ValueError('Unsafe source archive path')
            if not (member.isdir() or member.isfile()) or member.name in seen:
                raise ValueError('Source archive contains links or duplicate entries')
            seen.add(member.name)
        for member in members:
            relative = PurePosixPath(member.name).parts[1:]
            if not relative:
                continue
            target = destination.joinpath(*relative)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as content, target.open('xb') as output:
                    shutil.copyfileobj(content, output)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)


def quote_go_argument(value):
    if not any(char.isspace() or char in "\"'" for char in value):
        return value
    quote = "'" if "'" not in value else '"'
    if quote in value:
        raise ValueError('Compiler path contains incompatible quote characters')
    return quote + value + quote


def directory_digest(root):
    digest = hashlib.sha256()
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('Unexpected symlink in generated framework')
        if path.is_file():
            digest.update(path.relative_to(root).as_posix().encode() + b'\0')
            digest.update(bytes.fromhex(sha256(path)))
    return digest.hexdigest()


def build_framework(simulator=False):
    lock = json.loads((SUPPORT / 'tailscale-dependency.json').read_text())
    go_version = (SUPPORT / '.go-version').read_text().strip()
    if capture(['go', 'env', 'GOVERSION']) != 'go' + go_version:
        raise ValueError('Use the Go version in apps/ios/Support/.go-version')
    sdk = 'iphonesimulator' if simulator else 'iphoneos'
    scheme = 'TailscaleKit (Simulator)' if simulator else 'TailscaleKit (iOS)'
    destination = 'generic/platform=iOS Simulator' if simulator else 'generic/platform=iOS'
    archive_name = 'libtailscale_ios_sim.a' if simulator else 'libtailscale_ios.a'
    target = 'arm64-apple-ios17.0-simulator' if simulator else 'arm64-apple-ios17.0'
    toolchain = {'xcode': capture(['xcodebuild', '-version']), 'go': go_version,
                 'platform': sdk, 'sdk': capture(['xcrun', '--sdk', sdk, '--show-sdk-version'])}
    patch = SUPPORT / 'tailscale-privacy.patch'
    gateway = ROOT.parent / 'android/network/webgateway'
    gateway_files = [path for path in sorted(gateway.glob('*.go')) if not path.name.endswith('_test.go')]
    bridge = [SUPPORT / name for name in ('webgateway.go', 'webgateway.h')]
    inputs = {'dependency': lock, 'patchSHA256': sha256(patch), 'toolchain': toolchain,
              'builderSHA256': sha256(Path(__file__)),
              'webGateway': {path.name: sha256(path) for path in gateway_files + bridge}}
    fingerprint = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    build = ROOT / '.build/tailscale'
    build.mkdir(parents=True, exist_ok=True)
    product = build / fingerprint[:20]

    def cached():
        manifest = json.loads((product / 'build.json').read_text())
        if manifest['fingerprint'] != fingerprint or manifest['frameworkSHA256'] != directory_digest(product / 'TailscaleKit.xcframework'):
            raise ValueError('Generated framework cache changed; preserved for inspection')
        return product / 'TailscaleKit.xcframework'

    if product.exists():
        return cached()
    archive = build / 'source.tar.gz'
    if not archive.exists():
        url = f'https://codeload.github.com/tailscale/libtailscale/tar.gz/{lock["revision"]}'
        with urllib.request.urlopen(url, timeout=90) as response:
            data = response.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != lock['sourceArchiveSHA256']:
            raise ValueError('Source archive download checksum mismatch')
        with tempfile.NamedTemporaryFile(dir=build, delete=False) as output:
            download = Path(output.name)
            output.write(data)
        try:
            try:
                os.link(download, archive)
            except FileExistsError:
                pass
        finally:
            download.unlink(missing_ok=True)
    if sha256(archive) != lock['sourceArchiveSHA256']:
        raise ValueError('Cached source archive checksum mismatch; not overwritten')
    with tempfile.TemporaryDirectory(prefix='device-', dir=build) as directory:
        temporary = Path(directory)
        source = temporary / 'source'
        source.mkdir()
        extract_source(archive, source, lock['revision'])
        run(['patch', '--batch', '--fuzz=0', '-p1', '-i', patch], cwd=source)
        (source / 'webgateway').mkdir()
        for path in gateway_files:
            shutil.copyfile(path, source / 'webgateway' / path.name)
        shutil.copyfile(bridge[0], source / 'weq_webgateway.go')
        header = source / 'swift/TailscaleKit/TailscaleKit.h'
        with header.open('a') as output:
            output.write(bridge[1].read_text())
        environment = dict(os.environ, CGO_ENABLED='1', GOOS='ios', GOARCH='arm64', GOMAXPROCS='2',
                           GOFLAGS='-trimpath -mod=readonly -p=2')
        compiler = [capture(['xcrun', '--sdk', sdk, '--find', 'clang']), '-target', target,
                    '-isysroot', capture(['xcrun', '--sdk', sdk, '--show-sdk-path'])]
        environment['CC'] = ' '.join(quote_go_argument(value) for value in compiler)
        run(['go', 'build', '-buildmode=c-archive', '-ldflags=-w', '-tags=ios', '-o', archive_name, '.'],
            cwd=source, env=environment)
        derived = temporary / 'derived'
        run(['xcodebuild', '-project', source / 'swift/TailscaleKit.xcodeproj', '-scheme', scheme,
             '-configuration', 'Release', '-destination', destination, '-derivedDataPath', derived,
             'ARCHS=arm64', 'IPHONEOS_DEPLOYMENT_TARGET=17.0', 'BUILD_LIBRARY_FOR_DISTRIBUTION=YES',
             'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=', 'DEVELOPMENT_TEAM=',
             'OTHER_LDFLAGS=$(inherited) -Wl,-u,_WeQOpenGateway -Wl,-u,_WeQGatewayOrigin -Wl,-u,_WeQGatewayHasRelease -Wl,-u,_WeQAttachGateway -Wl,-u,_WeQSetGatewayRelease -Wl,-u,_WeQActivateGatewayRelease -Wl,-u,_WeQStoreGatewayImage -Wl,-u,_WeQCloseGateway -Wl,-u,_WeQClearGatewayCache', 'build'])
        staging = temporary / 'product'
        staging.mkdir()
        framework = staging / 'TailscaleKit.xcframework'
        run(['xcodebuild', '-create-xcframework', '-framework', derived / f'Build/Products/Release-{sdk}/TailscaleKit.framework',
             '-output', framework])
        manifest = dict(inputs, fingerprint=fingerprint, frameworkSHA256=directory_digest(framework))
        (staging / 'build.json').write_text(json.dumps(manifest, indent=2) + '\n')
        try:
            staging.rename(product)
        except OSError:
            if not product.exists():
                raise
            return cached()
    return product / 'TailscaleKit.xcframework'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', action='store_true', help='构建 ARM64 iOS 模拟器框架')
    print(build_framework(simulator=parser.parse_args().simulator))
