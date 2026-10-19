# duckdb-dp — DuckDB 差分隐私函数族

**在 SQL 里做 (ε,0)-差分隐私发布。** 经典 Laplace 机制，确定性可复现噪声，零原生逐行计算。
DuckDB v2.0.0-alpha39998 / v1.5.6 实测。

> [English](README.md)

## 是什么

隐私数学是**纯 SQL 宏**（`dp.sql`，零依赖）。附带那个 Rust 扩展是一个**薄加载 shim**
——它存在的唯一理由是社区注册表要能编译出一个可 LOAD 的 `.duckdb_extension` 二进制：
LOAD 时它执行 `dp.sql` 注册 `dp_*` 宏。**没有任何逐行原生代码。**

`INSTALL dp FROM community;` —— 或者直接 `.read dp.sql`。

## 函数

| 函数 | 机制 | 敏感度 |
|---|---|---|
| `dp_count(x, eps, salt := 'dp')` | 计数 + Laplace(1/eps) | 1 |
| `dp_sum(x, eps, lb, ub, salt := 'dp')` | 截断和 + Laplace((ub-lb)/eps) | ub−lb |
| `dp_mean(x, eps, lb, ub, salt := 'dp')` | 截断均值 + Laplace((ub-lb)/(2n·eps)) | (ub-lb)/(2n) |
| `dp_noise_lap(b, salt)` / `dp_noise_gauss(sigma, salt)` | 噪声原语 | — |
| `dp_u(salt)` / `dp_v(salt)` | 确定性均匀数（内部） | — |

聚合收 **LIST**（house 约定，对齐 `duckdb_stats`）：

```sql
.read ./dp.sql

SELECT dp_count(array_agg(age), 0.1, 'pub_2026q4')            AS dp_n,
       dp_mean(array_agg(age), 0.1, 0, 100, 'pub_2026q4')     AS dp_age
FROM patients;
```

- **eps** = 隐私预算，`<=0` 返回 NULL（不发布）
- **salt** = 发布标识：同 salt 重跑同噪声（dashboard 不漂移）；不同 salt 独立噪声
  （按发布单元分预算时换 salt）。必须对所有行是同一常量。
- **lb/ub** = 截断边界，语义核心不是可选项（噪声尺度 = ub-lb，不截断就没有敏感度保证）
- NULL 行不计入（对齐 COUNT/AVG）；`ub <= lb` 返回 NULL

端到端 demo：`test/demo.sql`（300 患者合成队列，eps 0.1 vs 0.01，可复现重跑）。

## 测试

```bash
bash test/run_tests.sh     # 12 项断言，全绿退出 0
python3 test/verify_dp.py  # 统计校验：噪声矩 vs 理论值 (N=2000, ±10%)
```

## 已知边界（原型，诚实声明）

1. **单查询机制，不做组合记账** —— 多个 `dp_*` 串联发布要自己按基本组合（Σeps）
   或高级组合（Dwork-Roth Thm 3.7）算总预算。
2. **非自适应** —— 同 salt 派生的多路噪声相关；跨发布复用 salt = 共享噪声，预算不可加。
3. **数值** —— 48 位确定性均匀数，对数域裁剪 `[2^-20, 1−2^-20]`（48 位数贴近 1 时
   `1-V` 会舍入为 0 → `ln(0)` → ±inf，测试套件锁住）。
4. **升级路线** —— 要 RDP / 账本 / 复杂查询时迁 C++ 扩展 + OpenDP（MIT / Rust / C ABI）。

## 与已有生态的关系

注册表 370 扩展重扫（2026-10-18）：无差分隐私覆盖（`differential` = 数据库版本管理/
时间旅行；`table_guard` = 表级访问控制；`semantic_profile` = 只做 PII 检测 ——
都不实现 DP 机制）。`duckdb_stats` 是统计层（推断 / 假设检验），本包是发布层
（隐私预算），不重叠。

## 目录结构

```
dp.sql              # 隐私数学本体 —— 纯 SQL 宏（产品）
src/                # 薄 Rust 加载 shim（LOAD 时注册 dp.sql）
  lib.rs            #   entry_point_v2! + 语句切分
  engine.rs         #   持久二级连接
test/               # demo.sql / dp_test.sql（断言）/ verify_dp.py（矩校验）
Makefile            # 构建（community-ci-tools 脚手架）
extension-ci-tools/ # submodule → duckdb/extension-ci-tools @ v1.5-variegata
```
