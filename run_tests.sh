#!/usr/bin/env bash
# run_tests.sh — dp.sql 断言测试 (任一 FAIL → 退出 1)
set -euo pipefail
cd "$(dirname "$0")"
DB="${DUCKDB:-duckdb}"
out=$("$DB" -unsigned -csv -c ".read ./dp.sql" -c ".read ./dp_test.sql" 2>&1) || {
  echo "$out"; echo "ERROR: duckdb 执行失败 (语法/运行错误, ON_ERROR 未开所以看输出)"; exit 1; }
echo "$out"
n_fail=$(echo "$out" | grep -c '^FAIL' || true)
n_pass=$(echo "$out" | grep -c '^PASS' || true)
echo "----"
echo "PASS=$n_pass FAIL=$n_fail"
if [ "$n_fail" -gt 0 ]; then exit 1; fi
