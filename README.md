# duckdb-dp — differential-privacy function family for DuckDB

**(ε,0)-differential-privacy publishing, straight in SQL.** Classic Laplace mechanism,
deterministic reproducible noise, zero native per-row work. Verified on DuckDB
v2.0.0-alpha39998 and v1.5.6.

> [中文版](README_CN.md)

## What it is

The privacy math is **pure SQL macros** (`dp.sql`, zero dependencies). The bundled
Rust extension is a **thin load shim** — it exists only so the community registry
can build a loadable `.duckdb_extension` binary: on `LOAD` it executes `dp.sql`
and registers the `dp_*` macros. There is no per-row native code.

`INSTALL dp FROM community;` — or just `.read dp.sql` directly.

## Functions

| function | mechanism | sensitivity |
|---|---|---|
| `dp_count(x, eps, salt := 'dp')` | count + Laplace(1/eps) | 1 |
| `dp_sum(x, eps, lb, ub, salt := 'dp')` | clipped sum + Laplace((ub-lb)/eps) | ub−lb |
| `dp_mean(x, eps, lb, ub, salt := 'dp')` | clipped mean + Laplace((ub-lb)/(2n·eps)) | (ub-lb)/(2n) |
| `dp_noise_lap(b, salt)` / `dp_noise_gauss(sigma, salt)` | noise primitives | — |
| `dp_u(salt)` / `dp_v(salt)` | deterministic uniform (internal) | — |

Aggregates take a **LIST** (house convention, same as `duckdb_stats`):

```sql
.read ./dp.sql

SELECT dp_count(array_agg(age), 0.1, 'pub_2026q4')       AS dp_n,
       dp_mean(array_agg(age), 0.1, 0, 100, 'pub_2026q4') AS dp_age
FROM patients;
```

- **eps** = privacy budget; `eps <= 0` returns NULL (nothing published).
- **salt** = publication identifier. Same salt → same noise on re-run (reproducible
  dashboards); different salt → independent noise (assign a fresh salt per
  publication when budget is tracked per release). Must be one constant across rows.
- **lb / ub** = clipping bounds — semantically core, not optional: the noise scale
  is `ub - lb`, so no clip means no sensitivity guarantee.
- NULL rows are not counted (matches COUNT/AVG); `ub <= lb` → NULL.

End-to-end demo: `test/demo.sql` (300-patient synthetic cohort, eps 0.1 vs 0.01,
reproducible re-run).

## Testing

```bash
bash test/run_tests.sh     # 12 assertions, all green → exit 0
python3 test/verify_dp.py  # moment checks: noise vs theory (N=2000, ±10%)
```

## Honest scope (prototype)

1. **Single-query mechanism, no composition accounting.** Publishing several
   `dp_*` values back-to-back — you sum the budgets yourself (basic composition,
   Σeps) or use advanced composition (Dwork-Roth Thm 3.7).
2. **Non-adaptive.** Noise derived from one salt is correlated across calls;
   reusing a salt across independent publications shares noise and breaks additivity.
3. **Numerics.** 48-bit deterministic uniform; the log domain is clamped to
   `[2^-20, 1−2^-20]` (a 48-bit value within 2^-48 of 1 would otherwise round
   `1-V` to 0 → `ln(0)` → ±inf; regression-locked by the test suite).
4. **Upgrade path.** For RDP / ledger accounting / complex queries, move to a C++
   extension over **OpenDP** (MIT / Rust / C ABI).

## Relation to the registry

Registry 370-extension rescan (2026-10-18): no differential-privacy coverage.
(`differential` = database versioning / time travel; `table_guard` = table-level
access control; `semantic_profile` = PII detection only — none implement a DP
mechanism.) `duckdb_stats` is the statistics layer (inference / hypothesis tests);
this is the publishing layer (privacy budget) — no overlap.

## Repository layout

```
dp.sql              # the privacy math — pure SQL macros (the product)
src/                # thin Rust load shim (registers dp.sql at LOAD)
  lib.rs            #   entry_point_v2! + statement splitter
  engine.rs         #   persistent secondary connection
test/               # demo.sql, dp_test.sql (assertions), verify_dp.py (moments)
Makefile            # build (community-ci-tools scaffold)
extension-ci-tools/ # submodule → duckdb/extension-ci-tools @ v1.5-variegata
```
