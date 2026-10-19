#!/usr/bin/env bash
# run_tests.sh — dp.sql 断言测试 (任一 FAIL → 退出 1)
# 本脚本在 test/ 子目录, cd 到仓库根 (dp.sql 在根)
set -euo pipefail
cd "$(dirname "$0")/.."
DB="${DUCKDB:-duckdb}"
out=$("$DB" -unsigned -csv -c ".read ./dp.sql" -c ".read ./test/dp_test.sql" 2>&1) || {
  echo "$out"; echo "ERROR: duckdb execution failed (syntax/runtime error)"; exit 1; }
echo "$out"
n_fail=$(echo "$out" | grep -c '^FAIL' || true)
n_pass=$(echo "$out" | grep -c '^PASS' || true)
echo "----"
echo "PASS=$n_pass FAIL=$n_fail"
if [ "$n_fail" -gt 0 ]; then exit 1; fi
