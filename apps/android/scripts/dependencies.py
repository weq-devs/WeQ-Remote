#!/usr/bin/env python3
"""准备并校验 Java 协议测试与 APK 构建共用的固定依赖。"""
import hashlib
import os
from pathlib import Path
import tempfile
from urllib.error import HTTPError
import urllib.request


BUILD = Path(__file__).resolve().parents[1] / '.build'
ZXING_VERSION = '3.5.3'
ZXING_HASH = '8d8064c1636fdaef7189dd9055c7d59950a8940a12f2293956446ec3c109fd82'
ZXING_ARTIFACT = f'com/google/zxing/core/{ZXING_VERSION}/core-{ZXING_VERSION}.jar'
ZXING_URL = f'https://repo.maven.apache.org/maven2/{ZXING_ARTIFACT}'
ZXING_FALLBACK_URL = f'https://repo1.maven.org/maven2/{ZXING_ARTIFACT}'
MAX_DOWNLOAD = 1_048_576


def ensure_zxing(build=BUILD):
    target = build / 'deps' / f'zxing-core-{ZXING_VERSION}.jar'
    if target.exists():
        if hashlib.sha256(target.read_bytes()).hexdigest() != ZXING_HASH:
            raise ValueError('本地 ZXing 文件与固定版本不符；未覆盖现有文件。')
        return target
    try:
        response = urllib.request.urlopen(ZXING_URL, timeout=60)
    except HTTPError as error:
        if error.code != 429:
            raise
        error.close()
        response = urllib.request.urlopen(ZXING_FALLBACK_URL, timeout=60)
    with response:
        data = response.read(MAX_DOWNLOAD + 1)
    if len(data) > MAX_DOWNLOAD or hashlib.sha256(data).hexdigest() != ZXING_HASH:
        raise ValueError('ZXing 下载大小或 SHA-256 校验失败；未保存文件。')
    target.parent.mkdir(parents=True, exist_ok=True)
    # 仅在校验成功后原子发布依赖，避免中断留下看似可复用的半个 JAR。
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as output:
            temporary = Path(output.name)
            output.write(data)
        try:
            os.link(temporary, target)
        except FileExistsError:
            if hashlib.sha256(target.read_bytes()).hexdigest() != ZXING_HASH:
                raise ValueError('并发写入的 ZXing 文件校验失败；未覆盖现有文件。')
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return target


if __name__ == '__main__':
    print(ensure_zxing())
