//! Component definitions.
//!
//! WARNING: only `pub const <Name> = struct { ... };` type declarations
//! may live in this file. The ECS world enumerates every public decl
//! here at comptime and generates one SparseSet per type. Any non-type
//! decl (functions, consts, imports of types you don't want registered)
//! will fail compilation.
const ha = @import("ha");
const dist = ha.dist;

// TODO: these are private structs and only used as pieces of larger components. not to be generated as a SparseSet
const Requires = struct {
    energy: f32,
    materials: f32,
};

const Yields = struct {
    food: dist.Dist,
    materials: dist.Dist,
};

// NOTE: These are components
pub const Label = struct { v: []const u8 };

/// Vigor: human energy source
pub const Vigor = struct {
    v: f32,
    max: f32,
};

pub const InventoryFood = struct {
    v: f32,
    quality: u8,
    spoils: f32,
};

pub const InventoryMaterial = struct {
    v: f32,
};

pub const ActionForage = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 0.0 },
    yields: Yields = .{
        .food = .{ .kind = .normal, .s = 2.0 },
        .materials = .{ .kind = .fixed, .s = 0 },
    },
};

pub const ActionFish = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 0.0 },
    yields: Yields = .{
        .food = .{ .kind = .poisson, .s = 2.0 },
        .materials = .{ .kind = .fixed, .s = 0 },
    },
};

pub const ActionChopWood = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 0.0 },
    yields: Yields = .{
        .food = .{ .kind = .fixed, .s = 0 },
        .materials = .{ .kind = .normal, .s = 5.0 },
    },
};

/// The continuous eating policy: an agent consumes its own larder every tick — eating
/// happens regardless of action (see `systems.metabolize`); what the player controls is
/// the *rate*. `setting` is that standing choice: ration (stretch the larder, stay
/// weak), normal, or feast (restore fast, burn the stock). `base_rate` is food/day at
/// `normal`; ration halves it, feast doubles it.
pub const Metabolism = struct {
    pub const Setting = enum { ration, normal, feast };
    setting: Setting = .normal,
    base_rate: f32 = 1.5,
};

/// **Unlocker** capital: owning the rod is what makes fishing possible at all —
/// `capital.build_fish_rod` pays `requires` once and grants the agent its `ActionFish`
/// component; `break_fish_rod` revokes the verb with the tool (reachable once
/// durability lands). One per agent, backed by the sparse-set's structural guarantee.
pub const FishRod = struct {
    requires: Requires = .{ .energy = 3.0, .materials = 8.0 },
};

// Generator capital: same Requires/Yields shape as an action, but drained/deposited
// every tick by capital.run_generator rather than on a player click. Placeholder scale
// — real numbers depend on how often "a tick" actually is, still unsettled.
pub const Fireplace = struct {
    requires: Requires = .{ .energy = 0.1, .materials = 0.2 },
    yields: Yields = .{
        .food = .{ .kind = .fixed, .s = 0.1 },
        .materials = .{ .kind = .fixed, .s = 0 },
    },
};
