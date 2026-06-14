//! Component definitions.
//!
//! WARNING: only `pub const <Name> = struct { ... };` type declarations
//! may live in this file. The ECS world enumerates every public decl
//! here at comptime and generates one SparseSet per type. Any non-type
//! decl (functions, consts, imports of types you don't want registered)
//! will fail compilation.

/// Energy: the actor's vitality stock and the game's accumulation currency. It
/// decays while idle (the actor is cold and hungry); at `v == 0` the actor perishes
/// (see the death pipeline in `systems.zig`). Unbounded above — this is the
/// "number-go-up" axis, shown as a figure, not a bar. `start` is the (starved) value
/// a fresh actor spawns at; death restarts the run from there, losing all that was
/// accumulated. `multiplier` is seconds-per-unit of idle decay.
pub const Energy = struct {
    v: f32,
    start: f32,
    multiplier: f32,
};

/// Stamina: how rested the actor is — a bounded `0..max` capacity that gates the
/// *quality* of action outcomes (energy yield is scaled by `v / max`, so a tired
/// actor produces below standard). Acting spends it; the deliberate `Rest` action
/// restores it (foregoing production to consume leisure); a tiny `trickle`
/// regenerates it passively so the actor is never hard-stuck. Shown as a bar.
pub const Stamina = struct {
    v: f32,
    max: f32,
    trickle: f32, // passive regen, units per second
};
