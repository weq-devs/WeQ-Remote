#!/usr/bin/env python3
"""给 gomobile 传给 cgo 的编译器路径加引号，支持带空格的外盘 NDK。"""
import os
import re
import sys


def quote_compiler(value):
    match = re.fullmatch(r'(.*?/bin/[^ \t]+)([ \t].*)?', value)
    if match and any(char.isspace() for char in match[1]) and os.path.isfile(match[1]):
        # Go 的 quoted.Split 不解释反斜杠转义，不能用 JSON/shell 转义改写真实路径。
        quote = "'" if "'" not in match[1] else '"'
        if quote in match[1]:
            raise ValueError('Compiler path contains unsupported quote characters')
        return quote + match[1] + quote + (match[2] or '')
    return value


if __name__ == '__main__':
    for name in ('CC', 'CXX'):
        if name in os.environ:
            os.environ[name] = quote_compiler(os.environ[name])
    real = os.environ['WEQ_GO_REAL']
    os.execv(real, [real, *sys.argv[1:]])
