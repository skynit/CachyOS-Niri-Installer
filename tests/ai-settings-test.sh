#!/usr/bin/env bash

# 自动进入 run-all.sh 的 *-test.sh 入口；所有系统交互都由 Python 用例隔离和 stub。
set -euo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$TEST_DIR/ai_settings_test.py"
