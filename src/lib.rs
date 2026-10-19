//! duckdb-dp — differential-privacy function family (DuckDB, Rust shim).
//!
//! The privacy math is pure SQL (see dp.sql). This shim exists only so the
//! community registry can build a loadable .duckdb binary: on LOAD it
//! executes dp.sql against the database, registering the dp_* macros.
//!
//! Functions (all in dp.sql):
//!   dp_count(x, eps, salt)     — count + Laplace(1/eps)
//!   dp_sum(x, eps, lb, ub, salt) — clipped sum + Laplace((ub-lb)/eps)
//!   dp_mean(x, eps, lb, ub, salt) — clipped mean + Laplace((ub-lb)/(2n·eps))
//!   dp_noise_lap / dp_noise_gauss — noise primitives
//!   dp_u / dp_v                — deterministic uniform (internal)
//!
//! Zero per-row Rust work: registration is a one-time SQL script at load.

mod engine;

use quack_rs::connection::Connection;
use quack_rs::entry_point_v2;
use quack_rs::prelude::*;

/// The privacy SQL, embedded at compile time (single source of truth).
const DP_SQL: &str = include_str!("../dp.sql");

/// Split dp.sql into individual statements (each CREATE MACRO ends with ';').
/// Strip '--' line comments first — some dp.sql comments contain ';' (Chinese
/// punctuation), which would otherwise split inside the comment. dp.sql has no
/// string literals containing '--', so comment-stripping is safe here.
fn statements(sql: &str) -> Vec<String> {
    let no_comments: String = sql
        .lines()
        .map(|l| match l.find("--") {
            Some(i) => l[..i].to_string(),
            None => l.to_string(),
        })
        .collect::<Vec<_>>()
        .join("\n");
    no_comments
        .split(';')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

fn register(con: &Connection) -> Result<(), ExtensionError> {
    // Persistent secondary connection (required on macOS ARM64 where the
    // init-callback database handle goes invalid after the closure returns).
    engine::init_early(con);

    let stmts = statements(DP_SQL);
    if stmts.is_empty() {
        return Err(ExtensionError::from("dp: dp.sql produced no statements".to_string()));
    }
    for stmt in &stmts {
        engine::run_exec(stmt).map_err(|e| {
            ExtensionError::from(format!("dp: failed to register macro: {e}"))
        })?;
    }
    Ok(())
}

entry_point_v2!(dp_init_c_api, |con| register(con));