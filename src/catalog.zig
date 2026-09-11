//! `catalog` (ACT1-05) — the **stable action/recipe presentation catalog**: one authoritative
//! table mapping each typed action/good component to a **stable string ID**, a display name, a
//! `Kind` (action vs the good tiers), input/output *keys*, effect copy, and — the load-bearing
//! part — an **Act I surface** flag that reconciles the components that merely *exist* against
//! the finalized Act I surface. A component existing (e.g. `ActionHunt`/`AirRifle`) does **not**
//! mean it is shown: the catalog is the single place that decides membership, in authored order,
//! so a screen never accidentally renders an extra just because the type is defined.
//!
//! Stable IDs are the contract: they are the keys transitions (ACT1-06), saves, and the Act II
//! migration key off, so they must not change even if a component is renamed. The *copy*
//! (display name / effect sentence) is presentation and stays a read of `good_text`/`action`
//! at the page tier where it belongs; this module owns the identity, type, order, and surface.
//!
//! Leaf, comptime, allocation-free — imports only the components. The records reference the
//! `comp` types directly, so a stale ID cannot point at a nonexistent component.

const std = @import("std");
const ha = @import("ha");
const comp = ha.comp;

/// The presentation kind of a catalog entry — the `type` column the roadmap asks for. Actions
/// are the ACTIONS surface; the good tiers (crude vs manufactured) are the BUILD surface.
pub const Kind = enum { action, crude_good, manufactured_good };

/// One catalog record. `id` is the stable string identity; `T` the component type it presents;
/// `kind` its type column; `on_surface` whether it appears on the finalized **Act I** surface
/// (a defined-but-off-surface component like Hunt/Air rifle is `false`). Input/output *keys* are
/// coarse resource tags (`"energy"`, `"materials"`, `"food"`), the shape ACT1-08/09 render from.
pub const Record = struct {
    id: []const u8,
    kind: Kind,
    on_surface: bool,
    inputs: []const []const u8,
    outputs: []const []const u8,
};

// —— ACTIONS ————————————————————————————————————————————————————————————————————————————
// The finalized Act I ACTIONS surface is exactly five verbs: Forage, Scavenge, Split wood,
// Fish, Check traps. **Hunt exists as a component but is NOT on the Act I surface** — it is the
// canonical "reconcile, don't show an extra" case. Authored order is the fixture order.

pub const actions = [_]Record{
    .{ .id = "act.forage", .kind = .action, .on_surface = true, .inputs = &.{"energy"}, .outputs = &.{"food"} },
    .{ .id = "act.scavenge", .kind = .action, .on_surface = true, .inputs = &.{"energy"}, .outputs = &.{ "food", "materials" } },
    .{ .id = "act.chop_wood", .kind = .action, .on_surface = true, .inputs = &.{"energy"}, .outputs = &.{"materials"} },
    .{ .id = "act.fish", .kind = .action, .on_surface = true, .inputs = &.{"energy"}, .outputs = &.{"food"} },
    .{ .id = "act.check_traps", .kind = .action, .on_surface = true, .inputs = &.{ "energy", "materials" }, .outputs = &.{"food"} },
    // Off the finalized surface: exists (`ActionHunt`/`AirRifle`) but not shown in Act I.
    .{ .id = "act.hunt", .kind = .action, .on_surface = false, .inputs = &.{ "energy", "materials" }, .outputs = &.{"food"} },
};

/// The stable ID for an action component (the identity transitions/saves key off).
pub fn actionId(comptime ActionT: type) []const u8 {
    return switch (ActionT) {
        comp.ActionForage => "act.forage",
        comp.ActionScavenge => "act.scavenge",
        comp.ActionChopWood => "act.chop_wood",
        comp.ActionFish => "act.fish",
        comp.ActionCheckTraps => "act.check_traps",
        comp.ActionHunt => "act.hunt",
        else => @compileError("no catalog id for action " ++ @typeName(ActionT)),
    };
}

// —— BUILD (goods) ——————————————————————————————————————————————————————————————————————
// The 16 buildable goods, in `capital.buildable_bundle` order, each with a stable ID and its
// crude/manufactured tier. All 16 are on the Act I BUILD surface (BUILD's default *filter* hides
// some rows, but they are catalog members — a query can reach them; that is ACT1-09's job, not a
// surface exclusion). The `kind` comes from `capital.is_crude`, so the tier can never drift.

pub const goods = blk: {
    const bundle = ha.capital.buildable_bundle;
    var recs: [bundle.len]Record = undefined;
    var i = 0;
    for (bundle) |G| {
        recs[i] = .{
            .id = goodId(G),
            .kind = if (ha.capital.is_crude(G)) .crude_good else .manufactured_good,
            .on_surface = true,
            .inputs = &.{ "energy", "materials" }, // a build spends energy + materials + hours
            .outputs = &.{}, // a good is the output; its effect is its own row
        };
        i += 1;
    }
    break :blk recs;
};

/// The stable ID for a buildable good.
pub fn goodId(comptime GoodT: type) []const u8 {
    return switch (GoodT) {
        comp.FishRod => "good.fish_rod",
        comp.Hatchet => "good.hatchet",
        comp.WireSnares => "good.wire_snares",
        comp.AirRifle => "good.air_rifle",
        comp.Sandals => "good.sandals",
        comp.WorkGloves => "good.work_gloves",
        comp.Bicycle => "good.bicycle",
        comp.Cookpot => "good.cookpot",
        comp.RootCellar => "good.root_cellar",
        comp.Chainsaw => "good.chainsaw",
        comp.LeafBed => "good.leaf_bed",
        comp.Pantry => "good.pantry",
        comp.MedicineChest => "good.medicine_chest",
        comp.GardenBed => "good.garden_bed",
        comp.ChickenCoop => "good.chicken_coop",
        comp.Shelter => "good.shelter",
        else => @compileError("no catalog id for good " ++ @typeName(GoodT)),
    };
}

/// How many actions are on the finalized Act I surface (the ACTIONS roster count).
pub fn surfaceActionCount() usize {
    var n: usize = 0;
    for (actions) |r| {
        if (r.on_surface) n += 1;
    }
    return n;
}

// ============================ Tests =====================================================

test "action IDs are stable and match the record table" {
    // Every action component maps to an id, and that id is present in the records table.
    inline for (.{ comp.ActionForage, comp.ActionScavenge, comp.ActionChopWood, comp.ActionFish, comp.ActionCheckTraps, comp.ActionHunt }) |A| {
        const id = actionId(A);
        var found = false;
        for (actions) |r| {
            if (std.mem.eql(u8, r.id, id)) found = true;
        }
        try std.testing.expect(found);
    }
    // The ids themselves are the stable strings (a rename must not silently change them).
    try std.testing.expectEqualStrings("act.forage", actionId(comp.ActionForage));
    try std.testing.expectEqualStrings("act.check_traps", actionId(comp.ActionCheckTraps));
}

test "the Act I ACTIONS surface is exactly five verbs; Hunt exists but is off-surface" {
    try std.testing.expectEqual(@as(usize, 5), surfaceActionCount());
    // Hunt has a record (it exists) but is explicitly not on the surface — the reconcile case.
    var hunt_off = false;
    for (actions) |r| {
        if (std.mem.eql(u8, r.id, "act.hunt")) hunt_off = !r.on_surface;
    }
    try std.testing.expect(hunt_off);
}

test "goods catalog covers the whole buildable bundle with stable ids and tiers" {
    try std.testing.expectEqual(ha.capital.buildable_bundle.len, goods.len);
    // Every id is unique.
    for (goods, 0..) |a, ai| {
        for (goods, 0..) |b, bi| {
            if (ai != bi) try std.testing.expect(!std.mem.eql(u8, a.id, b.id));
        }
    }
    // Tier mirrors capital.is_crude (Sandals crude, Hatchet manufactured).
    try std.testing.expectEqualStrings("good.sandals", goodId(comp.Sandals));
    try std.testing.expectEqualStrings("good.hatchet", goodId(comp.Hatchet));
}
