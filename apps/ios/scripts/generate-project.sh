#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 只读复用本机已有的同版本构建，不执行外部依赖工程的构建或修改其文件。
export WEQ_TAILSCALE_FRAMEWORK="${WEQ_TAILSCALE_FRAMEWORK:?Set WEQ_TAILSCALE_FRAMEWORK}"
if [[ ! -d "$WEQ_TAILSCALE_FRAMEWORK" ]]; then
  printf '%s\n' '请用 WEQ_TAILSCALE_FRAMEWORK 指定带 statusJSON() 的 TailscaleKit.xcframework。' >&2
  exit 1
fi
exec xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
