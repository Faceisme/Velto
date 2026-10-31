#!/usr/bin/env bash
# 提交前检查:主程序不能有编译告警,全量测试串行通过。
# 增量构建只报本次编译到的文件,想看全部告警先 `rm -rf .build`。
set -euo pipefail
cd "$(dirname "$0")/.."

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

swift build --scratch-path .build 2>&1 | tee "$log" | tail -1
if sed $'s/\x1b\\[[0-9;]*m//g' "$log" | grep -E '/Sources/.*: warning:'; then
    echo "检查失败:Sources/ 有编译告警" >&2
    exit 1
fi

swift test --no-parallel --scratch-path .build
