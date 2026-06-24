//! Component definitions.
//!
//! WARNING: only `pub const <Name> = struct { ... };` type declarations
//! may live in this file. The ECS world enumerates every public decl
//! here at comptime and generates one SparseSet per type. Any non-type
//! decl (functions, consts, imports of types you don't want registered)
//! will fail compilation.

/// Vigor: the actor's human energy *source* — the muscle power that pays an action's
/// energy price. A bounded capacity; acting spends it, and it regens passively via
/// `trickle` (units/second). Two gates ride on it: action output *quality* scales by
/// `v / max` (a tired actor produces below standard), and **`v == 0` is death**. Its
/// effective ceiling is *not* `max` but `max × satiety_fraction` — hunger pulls the
/// ceiling (and so `v`) down toward zero (see `Satiety`); comfort capital (a bed) raises
/// `trickle`. Shown as a bar. (Renamed from `Stamina`, hunger-capped, 2026-06-23.)
pub const Vigor = struct {
    v: f32,
    max: f32, // base ceiling; the live ceiling is this × Satiety fraction
    trickle: f32,
};

/// Satiety: how fed the actor is — a `0..max` modifier (not a stock you spend on actions)
/// that sets `Vigor`'s live ceiling, `cap = Vigor.max × (v / max)`. It `drain`s passively
/// (units/second), faster while working, and is refilled by metabolizing `Food`. As it
/// falls the vigor ceiling falls with it; at `0` the ceiling is `0`, vigor hits `0`, and
/// the actor starves (death). The root cause of death is here; vigor is the proximate one.
pub const Satiety = struct {
    v: f32,
    max: f32,
    drain: f32,
};

/// Food: the perishable larder — a `0..max` consumable stock the body metabolizes into
/// `Satiety`. Produced by foraging/fishing actions; `spoil`s (units/second) so it can't
/// just be banked forever (storage capital will later raise `max` / cut `spoil`). Distinct
/// from `Materials`: you eat this, you build with those.
pub const Food = struct {
    v: f32,
    max: f32,
    spoil: f32,
};

/// Materials: the fungible, durable goods stockpile — the early "number-go-up" score *and*
/// the currency spent to build capital (no money yet; that emerges with the market). One
/// undifferentiated bucket on purpose — typed materials + recipes are deferred to the
/// multi-agent/market phase where division of labour makes distinct goods meaningful.
/// Unbounded, doesn't spoil (durables wear only slowly — a later refinement).
pub const Materials = struct {
    v: f32,
};

/// Capital: the capital goods the actor owns. `owned` is a bitset indexed by position in
/// the `capital` catalog (`main.zig`) — a set bit means owned (one-time unlocks). Tool goods
/// fold into action resolution (a rod boosts fishing); comfort goods bake their effect into
/// `Vigor.trickle` at purchase. `durability[i]` tracks remaining wear for *external-energy*
/// tools (a saw/engine): set to the good's capacity on build, drained as it pays an action's
/// energy price in place of vigor, and at `0` the tool breaks (its `owned` bit is cleared,
/// rebuild required). `progress[i]` is energy invested toward an *in-progress* build: a grand
/// good whose energy price exceeds one body's vigor is built across sessions, each session
/// pouring spare vigor into `progress` until it reaches the cost and the good completes.
/// All three are indexed parallel; `32` is the bitset's ceiling, so no need to import the
/// catalog's length. Reset on death (fresh entity) — "start over" wipes it.
pub const Capital = struct {
    owned: u32 = 0,
    durability: [32]f32 = [_]f32{0} ** 32,
    progress: [32]f32 = [_]f32{0} ** 32,
};
