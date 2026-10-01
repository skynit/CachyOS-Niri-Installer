#!/usr/bin/env bash

# 运行 tests/ 下所有 *-test.sh。单个文件失败不阻断其余文件，最后汇总。
# 仓库没有 CI，这个脚本是唯一的统一入口，改动后请手动执行。

set -uo pipefail

# 先赋值再 readonly：readonly 会掩盖命令替换的失败。
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR

failures=()

for test_file in "$TEST_DIR"/*-test.sh; do
    [[ -f $test_file ]] || continue
    printf '\n=== %s ===\n' "${test_file##*/}"
    if ! bash "$test_file"; then
        failures+=("${test_file##*/}")
    fi
done

printf '\n'
if ((${#failures[@]} > 0)); then
    printf '失败 %d 个测试文件：\n' "${#failures[@]}"
    printf '  %s\n' "${failures[@]}"
    exit 1
fi

printf '全部测试通过。\n'
