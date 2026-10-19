#!/usr/bin/env python3
"""verify_dp.py — 统计校验: dp 噪声的矩是否收敛到理论值。

方法: 在 SQL 里生成 N 个独立 salt 的噪声样本 (每值一行, -list 输出),
Python 算均值/标准差, 与理论值对比 (容差 ±10%, N=2000):
  Laplace(b)  : mean≈0, std≈b·sqrt(2)
  Gaussian(σ) : mean≈0, std≈σ
  Uniform     : mean≈0.5, std≈1/sqrt(12)
用法: python3 verify_dp.py [duckdb_cli]
"""
import subprocess, sys, math, statistics, os

HERE = os.path.dirname(os.path.abspath(__file__))

def fetch(db, sql):
    out = subprocess.run([db, "-unsigned", "-csv", "-noheader", "-list",
                          "-c", ".read ../dp.sql", "-c", sql],
                         capture_output=True, text=True, cwd=HERE)
    if out.returncode != 0:
        print("duckdb error:", out.stderr); sys.exit(1)
    vals = []
    for l in out.stdout.strip().splitlines():
        l = l.strip()
        if l and l.lower() != "null":
            vals.append(float(l))
    return vals

def check(name, vals, exp_mean, exp_std, tol=0.10):
    n = len(vals)
    m = statistics.fmean(vals)
    s = statistics.stdev(vals)
    m_ok = abs(m - exp_mean) <= abs(exp_std) * tol + 1e-9
    s_ok = abs(s - exp_std) / exp_std <= tol
    status = "PASS" if (m_ok and s_ok) else "FAIL"
    print(f"{status} {name}: n={n} mean={m:.4f} (exp≈{exp_mean}) std={s:.4f} (exp≈{exp_std:.4f})")
    return status == "PASS"

def main():
    db = sys.argv[1] if len(sys.argv) > 1 else "duckdb"
    n = 2000
    ok = True
    ok &= check("laplace(b=0.5)",
                fetch(db, f"SELECT dp_noise_lap(0.5, 'stat_salt_' || range::VARCHAR) FROM range({n});"),
                0.0, 0.5 * math.sqrt(2))
    ok &= check("gauss(sigma=0.5)",
                fetch(db, f"SELECT dp_noise_gauss(0.5, 'stat_salt_' || range::VARCHAR) FROM range({n});"),
                0.0, 0.5)
    us = fetch(db, f"SELECT dp_u('u_salt_' || range::VARCHAR) FROM range({n});")
    ok &= check("uniform", us, 0.5, 1.0 / math.sqrt(12))
    dups = sum(1 for a, b in zip(us, us[1:]) if a == b)
    print(("PASS" if dups == 0 else "FAIL"), f"u_uniqueness: {dups} collisions in {n-1} adjacents")
    ok &= dups == 0
    print("----")
    print("ALL PASS" if ok else "FAILURES PRESENT")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()