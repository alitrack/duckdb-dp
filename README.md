# duckdb-dp — 差分隐私函数族 (DuckDB SQL 宏)

**#2026101901** · DuckDB v2.0.0-alpha39998 / v1.5.6 实测 · 零依赖, 纯 SQL 宏

在 DuckDB 里做 (ε,0)-差分隐私发布: 经典 Laplace 机制, 噪声确定性派生 (可复现),
聚合直接嵌在 SQL 里, 不需要 Python/扩展二进制。

## 函数

| 函数 | 机制 | 敏感度 |
|---|---|---|
| `dp_count(x, eps, salt := 'dp')` | 计数 + Laplace(1/eps) | 1 |
| `dp_sum(x, eps, lb, ub, salt := 'dp')` | 截断和 + Laplace((ub-lb)/eps) | ub−lb |
| `dp_mean(x, eps, lb, ub, salt := 'dp')` | 截断均值 + Laplace((ub-lb)/(2n·eps)) | (ub-lb)/(2n) |
| `dp_noise_lap(b, salt)` / `dp_noise_gauss(sigma, salt)` | 噪声原语 | — |
| `dp_u(salt)` / `dp_v(salt)` | 确定性均匀数 (内部) | — |

调用约定 (聚合收 LIST, 对齐 `duckdb_stats/stats_fill.sql`):

```sql
.read ./dp.sql

SELECT dp_count(array_agg(age), 0.1, 'pub_2026q4')            AS dp_n,
       dp_mean(array_agg(age), 0.1, 0, 100, 'pub_2026q4')     AS dp_age
FROM patients;
```

- **eps** = 隐私预算, `<=0` 返回 NULL (不发布)
- **salt** = 发布标识: 同 salt 重跑同噪声 (dashboard 不漂移); 不同 salt 独立噪声
  (按发布单元分预算)。必须对所有行是同一常量。
- **lb/ub** = 截断边界, 语义核心不是可选项 (不截断就没有敏感度保证)
- NULL 行不计入 (对齐 COUNT/AVG 语义); `ub <= lb` 返回 NULL

端到端 demo: `demo.sql` (300 患者合成队列, eps 0.1/0.01 对比, 可复现重跑)。

## 测试

```bash
bash run_tests.sh        # 12 项断言, 全绿退出 0
python3 verify_dp.py     # 统计校验: 噪声矩 vs 理论值 (N=2000, ±10%)
```

## 已知边界 (原型, 诚实声明)

1. **单查询机制, 不做组合记账** — 多个 dp_* 串联发布要自己按基本组合 (Σeps)
   或高级组合 (Dwork-Roth Thm 3.7) 算总预算。
2. **非自适应** — 同 salt 派生的多路噪声相关; 跨发布复用 salt = 共享噪声,
   预算不可加。
3. **数值** — 均匀数 48 位, 对数域裁剪 [2^-20, 1−2^-20] (2^-48 低于 double 精度,
   不裁剪会 ln(0)→inf, T11 回归锁住)。
4. **升级路线** — 要 RDP/账本/复杂查询时迁 C++ 扩展 + OpenDP (MIT/Rust/C ABI)。

## 与已有生态的关系

- 注册表 370 扩展 (2026-10-18 重扫): 无 DP 覆盖 (`differential` 扩展 = 版本管理/
  时间旅行, 无关; `table_guard` = 表级访问控制, 非脱敏; `semantic_profile`
  只做 PII 检测)。
- `duckdb_stats`: 统计层 (推断/假设检验), 本包是发布层 (隐私预算), 不重叠。
