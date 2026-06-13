//! Component definitions.
//!
//! WARNING: only `pub const <Name> = struct { ... };` type declarations
//! may live in this file. The ECS world enumerates every public decl
//! here at comptime and generates one SparseSet per type. Any non-type
//! decl (functions, consts, imports of types you don't want registered)
//! will fail compilation.

// acumulates infinitely
pub const Counter = struct {
    v: f32,
    multiplier: f32, // seconds per +1 unit; v advances continuously, rounded at render
};

/// Counts `v` up from `start` toward `end` and stops there (no wrap)
pub const CounterFill = struct {
    v: f32,
    start: f32,
    end: f32,
    multiplier: f32,
};

/// Counts `v` up from `start` toward `end` and wraps
pub const CounterWrap = struct {
    v: f32,
    start: f32,
    end: f32,
    multiplier: f32,
};

// reduces infinitely
pub const Timer = struct {
    v: f32,
    multiplier: f32, // seconds per -1 unit; v advances continuously, rounded at render
};

/// reduces `v` up from `start` toward `end` and stops there (no wrap)
pub const TimerFill = struct {
    v: f32,
    start: f32,
    end: f32,
    multiplier: f32,
};

// counts from start toward end, wrapping
pub const TimerWrap = struct {
    v: f32,
    start: f32,
    end: f32,
    multiplier: f32,
};

/// Life: a one-shot drain toward zero — a `TimerFill` whose `end` is implicitly 0.
/// `v` is current life, `start` the max (for a life bar: `v / start`). `multiplier`
/// is seconds-per-unit. At `v == 0` the entity is dead.
pub const Life = struct {
    v: f32,
    start: f32,
    multiplier: f32,
};
