#!/usr/bin/env python3
"""选择明确的电脑端测试入口；手机产品构建不调用本模块。"""
import argparse
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def desktop_repository(value=None):
    selected = value or os.environ.get('WEQ_DESKTOP_REPO') or ROOT.parent / 'WeQ-upstream'
    repo = Path(selected).expanduser().resolve()
    entry = repo / 'scripts/remote-integration-server.ts'
    try:
        name = json.loads((repo / 'package.json').read_text()).get('name')
    except (OSError, ValueError) as error:
        raise ValueError('请用 --desktop-repo 或 WEQ_DESKTOP_REPO 指定 WeQ 电脑端仓库。') from error
    if name != 'weq' or not entry.is_file():
        raise ValueError('电脑端仓库缺少约定的 Remote 测试入口，请更新 WeQ 或检查路径。')
    return repo


def fixture_command(repo):
    return ['pnpm', 'exec', 'tsx', str(repo / 'scripts/remote-integration-server.ts')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--desktop-repo')
    parser.add_argument('--network-config', type=Path)
    parser.add_argument('--lan', action='store_true')
    args = parser.parse_args()
    try:
        repo = desktop_repository(args.desktop_repo)
    except ValueError as error:
        parser.error(str(error))
    env = dict(os.environ, WEQ_REMOTE_LAN_TEST='1' if args.lan else '0')
    if args.network_config:
        env['WEQ_REMOTE_TEST_CONFIG'] = str(args.network_config.resolve())
    os.chdir(repo)
    command = fixture_command(repo)
    os.execvpe(command[0], command, env)


if __name__ == '__main__':
    main()
