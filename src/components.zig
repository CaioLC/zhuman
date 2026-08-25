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
    /// Work time, in in-game hours (`res.hours_to_secs` converts; a day = 24h). Time is
    /// a price like the others — under the metabolism, hours are food — so it lives in
    /// the price shape and every presentation shows it. No default on purpose: adding a
    /// duration to a new action is a decision, not an omission.
    hours: f32,
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

// -- Innate actions: the bare-handed verbs every agent spawns with -----------------------
// (`actions.innate_actions_bundle`). Each action owns a distinct *risk texture* — the
// dist kind is content, not decoration, and all five kinds are in play across the roster.

/// Forage: glean the greenbelt. The safe calorie baseline — normal, steady.
pub const ActionForage = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 0.0, .hours = 4 },
    yields: Yields = .{
        .food = .{ .kind = .normal, .s = 2.0 },
        .materials = .{ .kind = .fixed, .s = 0 },
    },
};

/// Scavenge: pick through the derelict edge of town. The day-one *materials* verb —
/// exponential on both yields: mostly scraps, occasionally a jackpot find, and sometimes
/// a forgotten can of food. This is what bootstraps the first tool.
pub const ActionScavenge = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 0.0, .hours = 5 },
    yields: Yields = .{
        .food = .{ .kind = .exponential, .s = 0.5 },
        .materials = .{ .kind = .exponential, .s = 3.0 },
    },
};

// -- Unlocked actions: granted by capital, never spawned innate ---------------------------
// Each arrives with its Unlocker good (`capital.finish_build` adds the component); the
// type's defaults *are* the with-tool stats.

/// Fish: unlocked by the Fishing rod. Better mean than Forage but poisson-lumpy —
/// feast or famine; wants a larder buffer under the metabolism.
pub const ActionFish = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 0.0, .hours = 5 },
    yields: Yields = .{
        .food = .{ .kind = .poisson, .s = 3.0 },
        .materials = .{ .kind = .fixed, .s = 0 },
    },
};

/// Split wood: unlocked by the Hatchet — you cannot split logs bare-handed. Steady
/// materials: beats Scavenge's mean but never jackpots.
pub const ActionChopWood = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 0.0, .hours = 6 },
    yields: Yields = .{
        .food = .{ .kind = .fixed, .s = 0 },
        .materials = .{ .kind = .normal, .s = 5.0 },
    },
};

/// Check traps: unlocked by Wire snares. The first stock-consuming verb — the bait is
/// materials — converting m→f cheaply in both energy and hours; a bad draw eats the
/// bait anyway.
pub const ActionCheckTraps = struct {
    requires: Requires = .{ .energy = 1.0, .materials = 1.0, .hours = 2 },
    yields: Yields = .{
        .food = .{ .kind = .uniform, .s = 3.0 },
        .materials = .{ .kind = .fixed, .s = 0 },
    },
};

/// Hunt: unlocked by the Air rifle. The best food-per-energy in Act One, priced in the
/// two currencies that bite: deep vigor and a whole working day — plus ammo.
pub const ActionHunt = struct {
    requires: Requires = .{ .energy = 4.0, .materials = 1.0, .hours = 8 },
    yields: Yields = .{
        .food = .{ .kind = .poisson, .s = 6.0 },
        .materials = .{ .kind = .fixed, .s = 0 },
    },
};

/// The one act in progress — an agent holds at most one (one body, one act at a time;
/// `actions.begin_labor` refuses while it exists). Costs are paid at start; the yield
/// resolves at *completion* (`systems.resolve_busy` dispatches on `doing`). `quality` is
/// locked at the click — the band the tile advertised is the band the draw uses, even if
/// the metabolism drains the body mid-work. Death mid-task loses the work: the component
/// despawns with the agent, paid and undelivered.
pub const Busy = struct {
    /// Every act that can occupy the one body — labor verbs and capital builds alike.
    /// Manual, like `actions_bundle`/`generator_bundle`: a fact about types, not entities
    /// (`actions.doing_of` / `capital.doing_of_good` map the comptime type to its name,
    /// and `systems.resolve_busy` dispatches back).
    pub const Doing = enum {
        // labor
        forage,
        scavenge,
        fish,
        chop_wood,
        check_traps,
        hunt,
        // capital builds
        build_fish_rod,
        build_hatchet,
        build_wire_snares,
        build_air_rifle,
        build_boots,
        build_work_gloves,
        build_bicycle,
        build_cookpot,
        build_root_cellar,
        build_chainsaw,
        build_bed,
        build_pantry,
        build_medicine_chest,
        build_garden_bed,
        build_chicken_coop,
    };
    doing: Doing,
    /// Total work time and what's left of it, in game-seconds (see `res.hours_to_secs`).
    total: f32,
    remaining: f32,
    /// Labor quality locked at begin (see `actions.yield_factor`).
    quality: f32,
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

// ============================ Capital goods ==================================
// Every buildable good carries `requires` — its **build price**, `hours` included, paid
// once by `capital.begin_build`. What the good *does* once built is its category (see
// capital.zig): an Unlocker grants a verb, an ActionModifier mutates a margin, a
// Generator starts running. One per agent, backed by the sparse-set's structural
// guarantee. Prices ladder from ~3 Scavenge draws (Boots) to a multi-day save (Chainsaw)
// — that ladder *is* the time-preference lesson.

// -- Unlockers: owning the tool is what makes the verb possible at all --------------------

/// Fishing rod → `ActionFish`.
pub const FishRod = struct {
    requires: Requires = .{ .energy = 3.0, .materials = 8.0, .hours = 12 },
};

/// Hatchet → `ActionChopWood`. The first step off bare hands into steady materials.
pub const Hatchet = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 6.0, .hours = 10 },
};

/// Wire snares → `ActionCheckTraps`.
pub const WireSnares = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 5.0, .hours = 8 },
};

/// Air rifle → `ActionHunt`. The long save of the labor roster.
pub const AirRifle = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 25.0, .hours = 16 },
};

// -- ActionModifiers: a margin on a verb you already have ---------------------------------

/// Boots: Forage costs less body.
pub const Boots = struct {
    requires: Requires = .{ .energy = 1.0, .materials = 4.0, .hours = 6 },
};

/// Work gloves: splitting wood costs less body.
pub const WorkGloves = struct {
    requires: Requires = .{ .energy = 1.0, .materials = 3.0, .hours = 5 },
};

/// Bicycle: distance gets cheap — both roaming verbs at once.
pub const Bicycle = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 15.0, .hours = 14 },
};

/// Cookpot: consumption-side capital — cooking raises the larder's `quality`, so every
/// stored unit of food converts to more vigor under the metabolism.
pub const Cookpot = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 7.0, .hours = 8 },
};

/// Root cellar: storage capital — halves spoilage. Worth exactly what your surpluses are.
pub const RootCellar = struct {
    requires: Requires = .{ .energy = 4.0, .materials = 10.0, .hours = 12 },
};

/// Chainsaw: the Act One capstone and the Act II teaser — the first substitution of
/// *external* energy for muscle. Splitting wood stops pricing the body and starts
/// pricing fuel.
pub const Chainsaw = struct {
    requires: Requires = .{ .energy = 3.0, .materials = 60.0, .hours = 30 },
};

// -- Health goods: capacity capital ------------------------------------------------------
// Sleeps well / eats better / patched up properly ⟹ actually healthier: each raises the
// vigor *ceiling* by 2 (see `capital.health_apply`). A future aging component decrementing
// `max` composes underneath, since every mutation here is relative.

/// Bed.
pub const Bed = struct {
    requires: Requires = .{ .energy = 3.0, .materials = 10.0, .hours = 12 },
};

/// Pantry.
pub const Pantry = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 14.0, .hours = 14 },
};

/// Medicine chest.
pub const MedicineChest = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 20.0, .hours = 16 },
};

// -- Generators: capital that runs itself ------------------------------------------------
// Two prices, not one: `requires` is the build order (paid once, hours included) and
// `upkeep` is the per-tick drain `capital.run_generator` must keep affording. `yields`
// and `upkeep` are authored **per in-game day** and scaled by the frame's dt, so the
// flow reads as a trickle rather than a lump (a discrete daily harvest is a later
// refinement). `upkeep.hours` is 0: affordability is not a work order.

/// Garden bed: a lump of materials becomes a perpetual food trickle (uniform: weather),
/// for a little upkeep (water, stakes).
pub const GardenBed = struct {
    requires: Requires = .{ .energy = 4.0, .materials = 12.0, .hours = 16 },
    upkeep: Requires = .{ .energy = 0.0, .materials = 0.1, .hours = 0 },
    yields: Yields = .{
        .food = .{ .kind = .uniform, .s = 1.5 },
        .materials = .{ .kind = .fixed, .s = 0 },
    },
};

/// Chicken coop: a bigger flow than the garden (poisson: eggs) for real upkeep (feed).
pub const ChickenCoop = struct {
    requires: Requires = .{ .energy = 3.0, .materials = 18.0, .hours = 20 },
    upkeep: Requires = .{ .energy = 0.0, .materials = 0.3, .hours = 0 },
    yields: Yields = .{
        .food = .{ .kind = .poisson, .s = 2.5 },
        .materials = .{ .kind = .fixed, .s = 0 },
    },
};
