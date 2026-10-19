.read ./dp.sql
-- 端到端 demo: 合成医疗队列 (300 患者, 年龄 20-80, 收入 3-30k/年)
CREATE OR REPLACE TEMP TABLE patients AS
SELECT
  range(300) AS patient_id,
  20 + (hash('age' || range::VARCHAR) % 60) AS age,
  (hash('inc' || range::VARCHAR) % 27000) + 3000 AS annual_income
FROM range(300);

-- 真值 (内部参考, 不会发布)
SELECT
  count(age) AS true_n,
  avg(age) AS true_age,
  sum(annual_income) AS true_income
FROM patients;

-- DP 发布 (eps=0.1, salt='pub_2026q4' 固定 → 可复现)
SELECT
  dp_count(array_agg(age), 0.1, 'pub_2026q4') AS dp_n,
  dp_mean(array_agg(age), 0.1, 0, 100, 'pub_2026q4') AS dp_age_mean,
  dp_sum(array_agg(annual_income), 0.1, 0, 100000, 'pub_2026q4') AS dp_income_sum
FROM patients;

-- 重跑一次: 同 salt → 同噪声 (可复现发布)
SELECT
  dp_count(array_agg(age), 0.1, 'pub_2026q4') AS dp_n_rerun,
  dp_mean(array_agg(age), 0.1, 0, 100, 'pub_2026q4') AS dp_age_mean_rerun
FROM patients;

-- 更紧预算 eps=0.01 → 噪声更大
SELECT
  dp_count(array_agg(age), 0.01, 'pub_2026q4') AS dp_n_eps001,
  dp_mean(array_agg(age), 0.01, 0, 100, 'pub_2026q4') AS dp_age_eps001
FROM patients;
