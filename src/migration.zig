//! `migration` — the **versioned Act I → II curtain migration** (`ACT1-18`). The one place
//! that carries an agent across the act boundary, and the one writer of the Act II balance and
//! research-state components. It is content, not engine: it composes existing ECS operations
//! (`World.add`/`get`/`has`/`remove`) over the components in `components.zig`, the same way
//! `capital.zig` composes build steps — no `src/ui/` or `src/ui_client/` architecture is touched.
//!
//! The curtain rules (from `docs/roadmap.md` "Non-negotiable product invariants" and
//! `docs/hex_tech_board_spec.md`):
//!
//!  1. **Food carries unchanged.** The larder is identical across the curtain — migration never
//!     reads or writes `InventoryFood`.
//!  2. **Unspent generic Materials → Biomass, `1:1`.** The whole `InventoryMaterial.v` becomes
//!     `InventoryBiomass.v`; the exchange rate is exactly one, and the parity test below holds
//!     every recipe the two acts share by name to equal Act I material and Act II biomass costs.
//!  3. **Generic Materials leaves active accounting.** After migration the `InventoryMaterial`
//!     component is removed — it "cannot be earned or spent in Act II".
//!  4. **Goods/counts/effects are preserved.** Goods are counts on `comp.Goods`, and what they
//!     grant derives from those counts (`effects.zig`); migration touches neither, so two fishing
//!     rods and the Fish verb they grant cross unchanged. (A test asserts this.)
//!  5. **Seed Foraging/Woodcutting Researched; the other four ring-1 techs Available.** Act I
//!     already established the personal-scale foundations of Forage and Split wood, so their
//!     ring-1 counterparts start Researched rather than unlocking a verb a second time.
//!  6. **Run exactly once.** A `Migrated` stamp is written; a second call is a no-op. This is the
//!     idempotence `ACT1-18` asks to unit-test, and the version field is the save-version
//!     boundary a future migration step keys off.
//!
//! Population/capacity/market initialization "exactly once" is noted as a migration
//! responsibility by `ACT1-18`, but its home is the Act II population system
//! (`ACT2-01`, which is told to reuse the shelter record's `capacity`) and the market `Encounter`
//! state — neither of which has an Act II shape yet. Rather than invent a second ceiling or a
//! second market grammar here (which the roadmap explicitly forbids), this migration owns the
//! balance/research transition and leaves a single documented seam, `population_seeded`, so the
//! "exactly once" guarantee is already expressed and tested at the version boundary.

const std = @import("std");
const ha = @import("ha");
const comp = ha.comp;
const capital = ha.capital;
const world = @import("./world.zig");

const World = world.World;
const Entity = world.Entity;

/// The current migration schema version. Bumped whenever the migration gains a step, so an
/// agent stamped at an older version can be carried forward by a future `migrate_to_act_two`
/// without re-running the steps it already has. The first (and current) schema is `1`.
pub const current_version: u32 = 1;

/// The `1:1` Materials→Biomass rate. Named rather than inlined so the parity test can reference
/// the exact constant it depends on — a change here is a change to the invariant, not a silent
/// re-tuning.
pub const materials_to_biomass: f32 = 1.0;

/// The Act II stocks besides Biomass, opened empty at the curtain.
const act_two_stocks = .{ comp.InventoryWater, comp.InventoryFuel, comp.InventoryMetal, comp.InventoryMinerals };

/// Whether `e` has already crossed the curtain — the presence of the `Migrated` stamp.
pub fn is_migrated(w: *World, e: Entity) bool {
    return w.has(e, comp.Migrated);
}

/// Carry `e` from Act I to Act II. Idempotent: if the agent already carries a `Migrated` stamp at
/// `current_version`, this returns immediately having changed nothing — so calling it twice (or on
/// an already-Act-II agent) is safe, which is the `ACT1-18` idempotence requirement. On the first
/// call it:
///
///  - converts the whole unspent `InventoryMaterial` balance to a new `InventoryBiomass` at `1:1`
///    and removes `InventoryMaterial` from accounting;
///  - opens the other Act II stocks (water, fuel, metal, minerals) at zero;
///  - leaves `InventoryFood` and `comp.Goods` untouched, so every good, its count, and what it
///    grants cross unchanged;
///  - seeds the Act II research board as a single `comp.Research`, seeded by `Research.entry(cat)`
///    from every tile's authored `initial` state (Foraging/Woodcutting Researched, the other four
///    ring-1 tiles Available, the rest Locked) if not already present;
///  - stamps `Migrated{ .version = current_version }`.
///
/// Returns whether it performed the migration (`true` on the first call, `false` when it no-ops).
pub fn migrate_to_act_two(w: *World, e: Entity, cat: *const ha.roster.Catalog) bool {
    // Idempotence gate: already carried to the current version ⇒ nothing owed.
    if (w.get(e, comp.Migrated)) |stamp| {
        if (stamp.version >= current_version) return false;
        // A future save-version step would run here (older stamp → bring forward). With only
        // schema 1 today, reaching this branch means the stamp is from a pre-release build; bring
        // it to current without re-converting a balance that no longer exists.
        stamp.version = current_version;
        return true;
    }

    // 1 + 2 + 3. Materials → Biomass, 1:1, then Materials leaves accounting. Guard on presence so
    // an agent that somehow lacks the Act I balance still migrates (carrying 0 biomass) rather
    // than panicking.
    const carried: f32 = if (w.get(e, comp.InventoryMaterial)) |m| m.v else 0;
    if (!w.has(e, comp.InventoryBiomass)) {
        w.add(e, comp.InventoryBiomass{ .v = carried * materials_to_biomass });
    } else {
        // Defensive: if a biomass balance already exists (it should not pre-migration), add into
        // it rather than clobbering, so no stock is silently destroyed.
        w.get(e, comp.InventoryBiomass).?.v += carried * materials_to_biomass;
    }
    if (w.has(e, comp.InventoryMaterial)) w.remove(e, comp.InventoryMaterial);
    // The other Act II stocks open at zero, so the first yield of water or metal lands.
    inline for (act_two_stocks) |Stock| {
        if (!w.has(e, Stock)) w.add(e, Stock{});
    }

    // 4. Goods/counts/effects: nothing to do — the counts live on `comp.Goods` and what they
    // grant derives from them. The test asserts the no-op explicitly.

    // 5. Seed the Act II research board. One `comp.Research` carries every tile's state by
    // catalog index, seeded from each tile's authored `initial` (Foraging/Woodcutting
    // Researched, the other four ring-1 tiles Available, the rest Locked — see
    // `data/technologies.zon`). The `has` guard keeps a re-seed from clobbering a board a
    // prior step already wrote.
    if (!w.has(e, comp.Research)) w.add(e, comp.Research.entry(cat));

    // 6. Stamp the version — the idempotence marker and the save-version boundary.
    w.add(e, comp.Migrated{ .version = current_version });
    return true;
}

/// Whether the one-time Act II population/capacity/market initialization is owed for `e`. The
/// shelter the agent built in Act I carries the capacity (its record's `capacity`, summed by
/// `capital.capacity` — the single ceiling `ACT2-01` is told to reuse); "seeded" here means the
/// agent has crossed the curtain and
/// therefore that initialization has already been accounted exactly once. Exposed as the single
/// documented seam for the population/market init so the "exactly once" guarantee is testable at
/// the version boundary before the Act II systems exist.
pub fn population_seeded(w: *World, e: Entity) bool {
    return is_migrated(w, e);
}

// ============================ Tests =====================================================

/// A migrated-eligible Act I agent: Food, generic Materials, and empty holdings — a test builds
/// what it needs, so each curtain rule is asserted independently.
fn spawn_act_one_agent(w: *World, materials: f32) Entity {
    const e = w.spawn(.{
        comp.Vigor{ .v = 8, .max = 10 },
        comp.InventoryFood{ .v = 7, .quality = 2, .spoils = 0.03 },
        comp.InventoryMaterial{ .v = materials },
        comp.Goods{},     // Required for catalog ownership
        comp.Granted{},   // Required for effects
    });
    return e;
}

test "migration converts Materials to Biomass 1:1 and drops Materials from accounting" {
    var w = World.init();
    var cat = try test_catalog();
    defer cat.deinit();
    const e = spawn_act_one_agent(&w, 42);

    try std.testing.expect(!is_migrated(&w, e));
    const did = migrate_to_act_two(&w, e, &cat);
    try std.testing.expect(did);

    // Biomass equals the unspent Materials, exactly 1:1; generic Materials is gone.
    try std.testing.expect(w.has(e, comp.InventoryBiomass));
    try std.testing.expectEqual(@as(f32, 42), w.get(e, comp.InventoryBiomass).?.v);
    try std.testing.expect(!w.has(e, comp.InventoryMaterial));
    // The other Act II stocks are open and empty, so the ledger can pay into them.
    inline for (act_two_stocks) |Stock| try std.testing.expectEqual(@as(f32, 0), w.get(e, Stock).?.v);
    try std.testing.expect(ha.ledger.move(&w, e, .water, 4));
    try std.testing.expectEqual(@as(f32, 4), ha.ledger.balance(&w, e, .water));
    try std.testing.expect(is_migrated(&w, e));
    try std.testing.expectEqual(current_version, w.get(e, comp.Migrated).?.version);
}

test "migration carries Food unchanged (never read or written)" {
    var w = World.init();
    var cat = try test_catalog();
    defer cat.deinit();
    const e = spawn_act_one_agent(&w, 10);
    const food_before = w.get(e, comp.InventoryFood).?.*;

    _ = migrate_to_act_two(&w, e, &cat);

    const food_after = w.get(e, comp.InventoryFood).?.*;
    try std.testing.expectEqual(food_before.v, food_after.v);
    try std.testing.expectEqual(food_before.quality, food_after.quality);
    try std.testing.expectEqual(food_before.spoils, food_after.spoils);
}

test "migration preserves built goods, their counts, and their granted effects" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_act_one_agent(&w, 0);
    
    // Get catalog indices
    const fish_rod_gi = res.catalog.goodIndex("fish_rod").?;
    const fish_ai = res.catalog.actionIndex("fish").?;
    
    // Build a fish rod (it grants Fish), then stock a second as a spare so count==2: two build
    // orders of materials.
    const fish_rod_cost = res.catalog.goods[fish_rod_gi].input[0].n * 2;
    w.get(e, comp.InventoryMaterial).?.v = fish_rod_cost;
    
    // Build using catalog index API
    capital.begin(&w, e, &res, fish_rod_gi);
    capital.finish(&w, e, &res, fish_rod_gi);
    if (w.has(e, comp.Busy)) w.remove(e, comp.Busy);
    
    // Build second one
    capital.begin(&w, e, &res, fish_rod_gi);
    capital.finish(&w, e, &res, fish_rod_gi);
    
    // Check counts in Goods component and effects.held
    const goods = w.get(e, comp.Goods).?;
    try std.testing.expectEqual(@as(u32, 2), goods.count[fish_rod_gi]);
    try std.testing.expect(ha.effects.held(&res.catalog, goods, fish_ai)); // the granted effect

    _ = migrate_to_act_two(&w, e, &res.catalog);

    // The good count and granted effect cross the curtain untouched.
    try std.testing.expectEqual(@as(u32, 2), w.get(e, comp.Goods).?.count[fish_rod_gi]);
    try std.testing.expect(ha.effects.held(&res.catalog, w.get(e, comp.Goods).?, fish_ai));
}

test "migration seeds the research board from the authored initial states" {
    var w = World.init();
    var cat = try test_catalog();
    defer cat.deinit();
    const e = spawn_act_one_agent(&w, 5);
    // No board before the curtain.
    try std.testing.expect(!w.has(e, comp.Research));

    _ = migrate_to_act_two(&w, e, &cat);

    // One `comp.Research` now carries every tile's state by catalog index, seeded from each
    // tile's authored `initial` (`data/technologies.zon`).
    const research = w.get(e, comp.Research).?;
    const S = ha.roster.TechState;
    // Foraging and Woodcutting carried over from Act I as Researched.
    try std.testing.expectEqual(S.researched, research.state[cat.techIndex("foraging").?]);
    try std.testing.expectEqual(S.researched, research.state[cat.techIndex("woodcutting").?]);
    // The other four ring-1 tiles Available.
    try std.testing.expectEqual(S.available, research.state[cat.techIndex("spring_well").?]);
    try std.testing.expectEqual(S.available, research.state[cat.techIndex("firepit").?]);
    try std.testing.expectEqual(S.available, research.state[cat.techIndex("surface_ore").?]);
    try std.testing.expectEqual(S.available, research.state[cat.techIndex("quarry_pit").?]);
}

test "migration is idempotent: a second call changes nothing" {
    var w = World.init();
    var cat = try test_catalog();
    defer cat.deinit();
    const e = spawn_act_one_agent(&w, 30);

    try std.testing.expect(migrate_to_act_two(&w, e, &cat)); // first: performs it
    const biomass_after_first = w.get(e, comp.InventoryBiomass).?.v;

    // Second call: no-op. Biomass is not re-added, Materials stays gone, version unchanged.
    try std.testing.expect(!migrate_to_act_two(&w, e, &cat));
    try std.testing.expectEqual(biomass_after_first, w.get(e, comp.InventoryBiomass).?.v);
    try std.testing.expect(!w.has(e, comp.InventoryMaterial));
    try std.testing.expectEqual(current_version, w.get(e, comp.Migrated).?.version);

    // And a third call, for good measure — still stable (no biomass drift, no board reseed).
    try std.testing.expect(!migrate_to_act_two(&w, e, &cat));
    try std.testing.expectEqual(biomass_after_first, w.get(e, comp.InventoryBiomass).?.v);
}

test "an older save-version stamp is brought forward without re-converting a balance" {
    var w = World.init();
    var cat = try test_catalog();
    defer cat.deinit();
    const e = w.spawn(.{
        comp.InventoryBiomass{ .v = 15 }, // already an Act II agent
        comp.Migrated{ .version = 0 }, // but stamped at a pre-release schema
        comp.Goods{},     // Required for catalog
        comp.Granted{},   // Required for effects
    });
    // No InventoryMaterial exists; the version-boundary branch must bring the stamp forward
    // without touching the balance.
    try std.testing.expect(migrate_to_act_two(&w, e, &cat));
    try std.testing.expectEqual(current_version, w.get(e, comp.Migrated).?.version);
    try std.testing.expectEqual(@as(f32, 15), w.get(e, comp.InventoryBiomass).?.v); // untouched
    // Now at current — a further call no-ops.
    try std.testing.expect(!migrate_to_act_two(&w, e, &cat));
}

test "an agent lacking the Act I materials balance still migrates, carrying 0 biomass" {
    var w = World.init();
    var cat = try test_catalog();
    defer cat.deinit();
    const e = w.spawn(.{ 
        comp.InventoryFood{ .v = 3, .quality = 1, .spoils = 0.05 },
        comp.Goods{},     // Required for catalog
        comp.Granted{},   // Required for effects
    });
    try std.testing.expect(migrate_to_act_two(&w, e, &cat));
    try std.testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryBiomass).?.v);
    try std.testing.expect(is_migrated(&w, e));
}

test "population/market init seam is accounted exactly once, at the version boundary" {
    var w = World.init();
    var cat = try test_catalog();
    defer cat.deinit();
    const e = spawn_act_one_agent(&w, 1);
    try std.testing.expect(!population_seeded(&w, e)); // owed before the curtain
    _ = migrate_to_act_two(&w, e, &cat);
    try std.testing.expect(population_seeded(&w, e)); // accounted after
    _ = migrate_to_act_two(&w, e, &cat); // idempotent: still exactly once
    try std.testing.expect(population_seeded(&w, e));
}

/// The quantity of `item` a list of lines names at cadence `per`.
fn qty(lines: []const ha.roster.Line, item: []const u8, per: ha.roster.Cadence) f32 {
    var n: f32 = 0;
    for (lines) |l| {
        if (l.per == per and std.mem.eql(u8, l.item, item)) n += l.n;
    }
    return n;
}

test "cross-act cost parity: a recipe of both acts costs in biomass what it cost in materials" {
    // The curtain converts unspent materials to biomass at `materials_to_biomass`, so a recipe
    // the two acts share by name prices each cadence identically on either side of it.
    var cat = try ha.roster.load(std.testing.allocator, ha.roster.shipped, null);
    defer cat.deinit();
    var pairs: usize = 0;
    for (cat.goods) |one| {
        if (one.act != 1) continue;
        for (cat.goods) |two| {
            if (two.act != 2 or !std.mem.eql(u8, one.name, two.name)) continue;
            for ([_]ha.roster.Cadence{ .once, .day }) |per| {
                const materials = qty(one.input, "materials", per);
                if (materials == 0) continue;
                try std.testing.expectEqual(materials * materials_to_biomass, qty(two.input, "biomass", per));
                pairs += 1;
            }
        }
    }
    try std.testing.expect(pairs > 0); // the garden bed is the canonical pair
}

/// A Resources with only the groups the build path touches initialized — the same minimal
/// fixture `capital.zig`'s tests use. Loads the shipped catalog; caller must deinit.
fn test_res() !ha.res.Resources {
    const testing = std.testing;
    var res: ha.res.Resources = undefined;
    res.sim = .{ .prng = std.Random.DefaultPrng.init(7) };
    res.time = .{ .dt = 0 };
    res.config = .{};
    res.catalog = try ha.roster.load(testing.allocator, ha.roster.shipped, null);
    return res;
}

/// The shipped roster — the technologies the curtain seeds `comp.Research` from. Loaded on its
/// own (no `Resources`) for the migration tests that only need the board; caller must deinit.
fn test_catalog() !ha.roster.Catalog {
    return ha.roster.load(std.testing.allocator, ha.roster.shipped, null);
}
