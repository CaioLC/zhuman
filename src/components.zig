//! Component definitions.
//!
//! WARNING: only `pub const <Name> = struct { ... };` type declarations
//! may live in this file. The ECS world enumerates every public decl
//! here at comptime and generates one SparseSet per type. Any non-type
//! decl (functions, consts, imports of types you don't want registered)
//! will fail compilation.
// Relative, like `res.zig`'s imports: `test-ui` compiles this file without `ha`.
const roster = @import("./roster.zig");

// NOTE: These are components
pub const Label = struct { v: []const u8 };

/// Vigor: human energy source. Field defaults are the **authoritative starting baseline**
/// A rested agent spawns at the ceiling. `spawn_agent` spawns from these defaults
/// (and the `baselines` module names them) rather than repeating literals, so Holdings can
/// derive a current-vs-base margin against the same numbers.
pub const Vigor = struct {
    v: f32 = 10,
    max: f32 = 10,
};

pub const InventoryFood = struct {
    v: f32 = 4,
    quality: u8 = 1,
    spoils: f32 = 0.05,
};

pub const InventoryBiomass = struct {
    v: f32 = 0,
};

/// The capital goods an agent owns, as a count per catalog index of the authored roster
/// (`roster.zig`); zero is not owned. Only ownership carries an effect — a second pair of
/// sandals is stock — so what the goods *do* is derived, never stored here (`effects.zig`).
pub const Goods = struct {
    count: [roster.max_goods]u32 = @splat(0),
};

/// Passive progress and on/off state for owned collectable generators, keyed by catalog good
/// index. `off` defaults false so a newly acquired generator starts accumulating immediately;
/// toggling off preserves `progress` and consumes nothing.
pub const Generators = struct {
    progress: [roster.max_goods]f32 = @splat(0),
    off: [roster.max_goods]bool = @splat(false),
};

/// What the owned goods currently contribute to the body and the larder, so those
/// contributions can be applied as relative deltas (`effects.apply`) and anything else that
/// moves the ceiling composes underneath.
pub const Granted = struct {
    vigor_ceiling: f32 = 0,
    food_quality: u8 = 0,
    spoil_scale: f32 = 1,
};

/// Where each technology of the authored roster stands for this agent, by catalog index
/// (`roster.zig`). Seeded at the curtain from every record's `initial`; the research board
/// promotes and establishes from there, and a recipe that names a `tech` is offered only once
/// it reads `researched` here (`capital.quote`).
pub const Research = struct {
    state: [roster.max_techs]roster.TechState = @splat(.locked),

    /// The board as the act opens: every tile at its authored initial state.
    pub fn entry(cat: *const roster.Catalog) Research {
        var r = Research{};
        for (cat.technologies, 0..) |t, i| r.state[i] = t.initial;
        return r;
    }
};

// -- Additional Act II stocks: opened at the curtain, never before --------------------------
// Biomass already exists in Act I (displayed there through the Materials cover). Migration
// carries that balance unchanged and opens the remaining resource stocks at zero. Each is a
// plain balance in the `InventoryBiomass` shape, reached through `ledger.Stock`.

pub const InventoryWater = struct {
    v: f32 = 0,
};

pub const InventoryFuel = struct {
    v: f32 = 0,
};

pub const InventoryMetal = struct {
    v: f32 = 0,
};

pub const InventoryMinerals = struct {
    v: f32 = 0,
};

/// **Migration version stamp** — the versioned marker the Act I → II migration writes onto an
/// agent the one time it runs. Its presence is what makes the migration idempotent: a second
/// call sees the stamp and returns without reopening stocks or re-seeding research. The
/// `version` field is the save-version boundary — a migration authored for an older save shape
/// can read it and decide whether a further step is owed. Act I agents do not carry it; owning
/// it *is* "this agent has crossed the curtain".
pub const Migrated = struct {
    /// The migration schema version this agent was last carried to. Bumped when the migration
    /// gains a new step; `migration.current_version` is the authority.
    version: u32 = 0,
};

/// The one act in progress — an agent holds at most one (one body, one act at a time;
/// `actions.begin` refuses while it exists). Costs are paid at start; the yield
/// resolves at *completion* (`systems.resolve_busy` dispatches on `doing`). `quality` is
/// locked at the click — the band the tile advertised is the band the draw uses, even if
/// the metabolism drains the body mid-work. Death mid-task loses the work: the component
/// despawns with the agent, paid and undelivered.
pub const Busy = struct {
    /// The act that occupies the body: a labor verb or a capital build, by its index in the
    /// authored roster (`roster.Catalog`). `systems.resolve_busy` dispatches on the tag.
    pub const Doing = union(enum) {
        labor: u16,
        build: u16,
    };
    doing: Doing,
    /// Total work time and what's left of it, in game-seconds (see `res.hours_to_secs`).
    total: f32,
    remaining: f32,
    /// Labor quality locked at begin (see `actions.yield_factor`).
    quality: f32,

    pub fn isLabor(self: Busy, ai: u16) bool {
        return switch (self.doing) {
            .labor => |i| i == ai,
            .build => false,
        };
    }

    pub fn isBuild(self: Busy, gi: u16) bool {
        return switch (self.doing) {
            .build => |i| i == gi,
            .labor => false,
        };
    }
};

/// The continuous eating policy: an agent consumes its own larder every tick — eating
/// happens regardless of action (see `systems.metabolize`); what the player controls is
/// the *rate*. `rate` is a **bounded scalar multiplier** in `[0.5, 2.0]`, `1.0` at
/// normal: it scales `base_rate` continuously (ration = stretch the larder and stay weak,
/// feast = restore fast and burn the stock), replacing the old three-value ration/normal/feast
/// enum. `base_rate` is food/day at `rate = 1.0`. The `Config` owns the range/default and the
/// clamp (`Config.clampMetabolism`); this stores the persisted agent-local choice.
pub const Metabolism = struct {
    rate: f32 = 1.0,
    base_rate: f32 = 1.5,
};
