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
/// accumulated. `decay` is units lost per second while idle — capital upkeep (a
/// fireplace burning fuel) adds to it.
pub const Energy = struct {
    v: f32,
    max: f32,
    decay: f32,
};

/// Stamina: how rested the actor is — a bounded `0..max` capacity that gates the
/// *quality* of action outcomes (energy yield is scaled by `v / max`, so a tired
/// actor produces below standard). Acting spends it; it recovers only via the passive
/// `trickle` (units/second), which comfort capital (a bed) raises. Shown as a bar.
pub const Stamina = struct {
    v: f32,
    max: f32,
    trickle: f32,
};

/// Capital: the capital goods the actor owns — a bitset indexed by position in the
/// `capital` catalog (`main.zig`). One-time unlocks: a set bit means owned. Tool goods
/// fold into action resolution (a rod boosts fishing); comfort goods bake their effect
/// into `Stamina.trickle` / `Energy.decay` at purchase. Reset on death (fresh entity),
/// so a "start over" wipes all accumulated capital.
pub const Capital = struct {
    owned: u32 = 0,
};
