//! Component definitions.
//!
//! WARNING: only `pub const <Name> = struct { ... };` type declarations
//! may live in this file. The ECS world enumerates every public decl
//! here at comptime and generates one SparseSet per type. Any non-type
//! decl (functions, consts, imports of types you don't want registered)
//! will fail compilation.

pub const Counter = struct {
    v: f32,
    multiplier: f32,
    buffer: f32,
};

pub const Timer = struct {
    v: f32,
    start: f32,
    end: f32,
    multiplier: f32,
};

/// Counts `v` up from `start` toward `end` and stops there (no wrap). Drives a
/// fill-up progress bar; userland resets `v` to `start` (e.g. on click).
pub const FillTimer = struct {
    v: f32,
    start: f32,
    end: f32,
    multiplier: f32,
};
