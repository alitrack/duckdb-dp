-- ============================================================================
-- dp.sql — 差分隐私 (Differential Privacy) 函数族 · DuckDB SQL 宏
-- #2026101901 · 2026-10-19 · DuckDB v2.0.0-alpha39998 实测 (1.5.6 兼容, 无 2.0 新语法)
--
-- 机制 (标准 (ε,0)-差分隐私, 经典 Laplace 机制; 与 differential 扩展的
-- 数据库版本管理/时间旅行无关):
--   dp_count  : 计数 + Laplace(1/eps)              [sensitivity = 1]
--   dp_sum    : 截断和 + Laplace((ub-lb)/eps)      [sensitivity = ub-lb]
--   dp_mean   : 截断均值 + Laplace((ub-lb)/(2n·eps)) [n 为公共知识]
--   dp_noise_lap / dp_noise_gauss : 噪声原语 (Laplace 逆 CDF / Box-Muller)
--
-- 调用约定 (与 duckdb_stats/stats_fill.sql 一致, 聚合收 LIST):
--   SELECT dp_count(array_agg(age), 0.1) FROM t;
--   SELECT dp_sum(array_agg(salary), 0.01, 0, 300000) FROM t;
--   * eps := 隐私预算, 必须 > 0 (否则返回 NULL)
--   * salt := 发布标识 (VARCHAR, 默认 'dp'): 噪声从 md5(salt) 确定性派生。
--     同一 salt 重跑得到同一噪声 = 可复现发布; 不同 salt = 独立噪声
--     (按发布单元分配独立预算时用不同 salt)。salt 必须对所有行是同一常量。
--   * lower_bound/upper_bound 是截断边界 (clipping): 噪声尺度由 ub-lb 决定,
--     不截断就没有敏感度保证 —— 语义核心, 不是可选项。
--   * NULL 行不计入 (对齐 COUNT/AVG 语义); 截断在 NULL 过滤之后进行。
--
-- 已知边界 (原型, 诚实声明):
--   * 单查询机制, 不做组合记账; 多个 dp_* 串联发布要自己按基本组合 (Σeps)
--     或高级组合 (Dwork-Roth Theorem 3.7) 算总预算。
--   * 非自适应安全: 同一 salt 派生的多路噪声相关 —— 一次发布内部可以,
--     跨发布复用同一 salt = 共享噪声, 预算不可加。
--   * 数值: 均匀数 48 位精度, 噪声绝对精度 ~1e-4·scale, 对 DP 用途足够。
--   * 升级路线: 机制是经典 Laplace, 零依赖; 要 RDP / 账本 / 复杂查询时
--     迁 C++ 扩展 + OpenDP (MIT/Rust/C ABI) 做地基。
-- ============================================================================

-- ===== 噪声原语 =====

-- 确定性均匀数 U ∈ (0,1): md5 → hash → mod 2^48 取低 48 位, 中点法开区间
-- (unhex 返回 BLOB 不可转整数, 2.0 无 bit_not, 故走 hash+mod)
-- 1.5.x hash 返回 signed BIGINT: ((h%m)+m)%m 防负数; 2.0 返回 UBIGINT 同样安全
CREATE OR REPLACE MACRO dp_u(salt) AS
  ((hash(md5(salt::VARCHAR)) % 281474976710656 + 281474976710656) % 281474976710656 + 0.5) / 281474976710656.0;

-- 对数安全版: 裁剪到 [2^-20, 1-2^-20]。
-- 必要性 (实测抓到的真 bug): U 由 48 位整数 / 2^48 得, 最接近 1 的 1-V ≈ 2^-48
-- 低于 double 精度, 1-V 舍入为 0 → ln(0)=-inf → 噪声 ±inf。裁剪后
-- ln(1-V) ∈ [-13.8, 13.8], Laplace 噪声 |L| ≤ b·13.8, 与理论 Laplace 尾部
-- (超过 e-fold 区间的概率 ~e^-14) 在数值上等价, 且杜绝 inf。
CREATE OR REPLACE MACRO dp_v(salt) AS
  CASE
    WHEN dp_u(salt) < 9.5367431640625e-07 THEN 9.5367431640625e-07
    WHEN dp_u(salt) > 0.9999990463256836 THEN 0.9999990463256836
    ELSE dp_u(salt)
  END;

-- Laplace 噪声, 尺度 b > 0 (标准差 = b·sqrt(2))
-- 逆 CDF: 符号一个均匀数定, 幅度 |L| = b·(-ln(1-V)) 另一个定
-- (Laplace 逆 CDF 是 |L| = s·b·ln(1/(1-V)), 乘 b 非除 b —— 除以 b 会把噪声
--  放大 b^-2 倍, T10 实测抓出: 尺度 0.05 的噪声出了 ±9.3)
CREATE OR REPLACE MACRO dp_noise_lap(b, salt) AS
  CASE
    WHEN b IS NULL OR b <= 0 THEN NULL
    ELSE (CASE WHEN dp_u(salt) >= 0.5 THEN -1.0 ELSE 1.0 END)
         * b * ln(1.0 / (1.0 - dp_v(salt || '#1')))
  END;

-- 高斯噪声, 标准差 sigma > 0 (Box-Muller, cos 分支)
CREATE OR REPLACE MACRO dp_noise_gauss(sigma, salt) AS
  CASE
    WHEN sigma IS NULL OR sigma <= 0 THEN NULL
    ELSE sqrt(-2.0 * ln(dp_v(salt)))
         * cos(2.0 * 3.14159265358979323846 * dp_u(salt || '#1')) * sigma
  END;

-- ===== 内部: NULL 过滤 + 截断 (对齐 COUNT/AVG 语义) =====

CREATE OR REPLACE MACRO dp_non_null(x) AS list_filter(x, lambda v: v IS NOT NULL);

CREATE OR REPLACE MACRO dp_clip(x, lower_bound, upper_bound) AS
  list_transform(dp_non_null(x), lambda v: least(greatest(v, lower_bound), upper_bound));

-- ===== DP 聚合 (收 LIST) =====

-- 计数 + Laplace(1/eps)。sensitivity = 1 (单行进出至多改计数 1)。
CREATE OR REPLACE MACRO dp_count(x, eps, salt := 'dp') AS
  CASE
    WHEN eps IS NULL OR eps <= 0 OR len(x) = 0 THEN NULL
    ELSE len(dp_non_null(x)) + dp_noise_lap(1.0 / eps, salt || '#count')
  END;

-- 截断和 + Laplace((ub-lb)/eps)。
CREATE OR REPLACE MACRO dp_sum(x, eps, lower_bound, upper_bound, salt := 'dp') AS
  CASE
    WHEN eps IS NULL OR eps <= 0 OR upper_bound <= lower_bound OR len(dp_non_null(x)) = 0
      THEN NULL
    ELSE list_sum(dp_clip(x, lower_bound, upper_bound))
         + dp_noise_lap((upper_bound - lower_bound) / eps, salt || '#sum')
  END;

-- 截断均值 + Laplace((ub-lb)/(2n·eps)) (Dwork-Roth Ch.7: 均值敏感度 ≤ (ub-lb)/(2n))。
-- n = 非空行数, 假设公共知识 (发布时行数通常可见); 若 n 本身敏感, 用 dp_count 另行发布。
CREATE OR REPLACE MACRO dp_mean(x, eps, lower_bound, upper_bound, salt := 'dp') AS
  CASE
    WHEN eps IS NULL OR eps <= 0 OR upper_bound <= lower_bound OR len(dp_non_null(x)) = 0
      THEN NULL
    ELSE list_sum(dp_clip(x, lower_bound, upper_bound)) * 1.0
         / len(dp_non_null(x))
         + dp_noise_lap((upper_bound - lower_bound) / (2.0 * len(dp_non_null(x)) * eps),
                        salt || '#mean')
  END;
