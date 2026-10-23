#!/usr/bin/env python3
"""校验真机 Mach-O 和未签名边界，再按 Payload 布局打包 IPA。"""
import hashlib
import os
from pathlib import Path
import plistlib
import stat
import struct
import tempfile
import zipfile


def validate_macho(data):
    if len(data) < 32:
        raise ValueError('Truncated Mach-O header')
    magic, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from('<8I', data)
    if magic != 0xFEEDFACF or cpu != 0x0100000C or subtype != 0 or kind not in (2, 6):
        raise ValueError('Expected thin arm64 iPhone executable or framework')
    if 32 + size > len(data) or count > size // 8:
        raise ValueError('Truncated Mach-O load commands')
    offset = 32
    device = False
    for _ in range(count):
        if offset + 8 > 32 + size:
            raise ValueError('Truncated load command')
        command, length = struct.unpack_from('<2I', data, offset)
        if length < 8 or offset + length > 32 + size:
            raise ValueError('Invalid load command size')
        if command == 0x32:
            if length < 24 or struct.unpack_from('<I', data, offset + 8)[0] != 2:
                raise ValueError('Not an iOS device binary')
            device = True
        if command == 0x1D:
            if length < 16 or struct.unpack_from('<I', data, offset + 12)[0] != 0:
                raise ValueError('Binary has a code signature')
        offset += length
    if not device or offset != 32 + size:
        raise ValueError('Missing device platform or inconsistent load commands')


def package_app(app, output):
    app = Path(app).resolve()
    output = Path(output)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if app.name != 'WeQRemote.app' or info.get('CFBundleIdentifier') != 'io.github.weqdevs.remote':
        raise ValueError('Unexpected application identity')
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS'] or info.get('DTPlatformName') != 'iphoneos':
        raise ValueError('Expected an iPhoneOS application, not a simulator')
    executable = info['CFBundleExecutable']
    if Path(executable).name != executable:
        raise ValueError('Invalid bundle executable name')
    validate_macho((app / executable).read_bytes())
    paths = sorted(app.rglob('*'))
    for path in paths:
        if path.name in ('_CodeSignature', 'embedded.mobileprovision') or path.suffix in ('.p12', '.p8', '.mobileprovision'):
            raise ValueError('Signing material must not be included')
        if path.is_symlink():
            try:
                path.resolve(strict=True).relative_to(app)
            except (ValueError, FileNotFoundError, RuntimeError):
                raise ValueError('Bundle symlink escapes the application or is broken')
        elif path.is_file():
            with path.open('rb') as stream:
                header = stream.read(4)
            if header in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce',
                          b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'):
                validate_macho(path.read_bytes())
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as temporary:
        staging = Path(temporary.name)
    try:
        with zipfile.ZipFile(staging, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for path in paths:
                name = 'Payload/' + app.name + '/' + path.relative_to(app).as_posix()
                if path.is_symlink():
                    entry = zipfile.ZipInfo(name)
                    entry.create_system = 3
                    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(entry, os.readlink(path))
                elif path.is_file():
                    archive.write(path, name)
        os.link(staging, output)
    finally:
        staging.unlink(missing_ok=True)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    return {'filename': output.name, 'sha256': digest, 'bundleIdentifier': info['CFBundleIdentifier'],
            'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'], 'signed': False}
