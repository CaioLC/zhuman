//! `bridge` — the bridge between the authored roster and the typed components it
//! transcribes: which record each typed action and good component stands for, and the tests
//! that hold the two equal, record for record. Deleted with the typed roster.

const std = @import("std");
const ha = @import("ha");
const comp = ha.comp;
const dist = ha.dist;
const roster = ha.roster;

const Catalog = roster.Catalog;
const Line = roster.Line;
const Cadence = roster.Cadence;
const Price = roster.Price;
const Tier = roster.Tier;
const Unlock = roster.Unlock;
const Lines = roster.Lines;
const World = ha.world.World;
const Entity = ha.world.Entity;

// Which record each typed component transcribes.

pub const typed_actions = .{
    .{ "forage", comp.ActionForage },
    .{ "scavenge", comp.ActionScavenge },
    .{ "fish", comp.ActionFish },
    .{ "chop_wood", comp.ActionChopWood },
    .{ "check_traps", comp.ActionCheckTraps },
    .{ "hunt", comp.ActionHunt },
};

pub const typed_goods = .{
    .{ "fish_rod", comp.FishRod },
    .{ "hatchet", comp.Hatchet },
    .{ "wire_snares", comp.WireSnares },
    .{ "air_rifle", comp.AirRifle },
    .{ "sandals", comp.Sandals },
    .{ "work_gloves", comp.WorkGloves },
    .{ "bicycle", comp.Bicycle },
    .{ "cookpot", comp.Cookpot },
    .{ "root_cellar", comp.RootCellar },
    .{ "chainsaw", comp.Chainsaw },
    .{ "leaf_bed", comp.LeafBed },
    .{ "pantry", comp.Pantry },
    .{ "medicine_chest", comp.MedicineChest },
    .{ "garden_bed", comp.GardenBed },
    .{ "chicken_coop", comp.ChickenCoop },
    .{ "shelter", comp.Shelter },
    .{ "fish_net", comp.FishNet },
    .{ "hand_axe", comp.HandAxe },
};

/// The record id a typed action component transcribes.
pub fn actionIdOf(comptime ActionT: type) []const u8 {
    inline for (typed_actions) |pair| {
        if (pair[1] == ActionT) return pair[0];
    }
    @compileError("no roster record for " ++ @typeName(ActionT));
}

/// The record id a typed good component transcribes.
pub fn goodIdOf(comptime GoodT: type) []const u8 {
    inline for (typed_goods) |pair| {
        if (pair[1] == GoodT) return pair[0];
    }
    @compileError("no roster record for " ++ @typeName(GoodT));
}

/// The catalog index of a typed action's record within this load.
pub fn actionIndexOf(cat: *const Catalog, comptime ActionT: type) ?u16 {
    return cat.actionIndex(actionIdOf(ActionT));
}

/// The catalog index of a typed good's record within this load.
pub fn goodIndexOf(cat: *const Catalog, comptime GoodT: type) ?u16 {
    return cat.goodIndex(goodIdOf(GoodT));
}

/// Mirror the derived state onto the typed components, so everything that still reads them
/// — the pages, the stable-id catalog, the migration — sees ownership and verb terms exactly
/// as the interpreter computes them. Runs after every change of ownership (`capital`).
/// Transitional: deleted with the typed roster.
pub fn shadow(w: *World, e: Entity, cat: *const Catalog) void {
    const goods = w.get(e, comp.Goods) orelse return;
    inline for (typed_goods) |pair| {
        if (cat.goodIndex(pair[0])) |gi| {
            const n = goods.count[gi];
            if (n > 0) {
                if (w.get(e, pair[1])) |held| held.count = n else w.add(e, pair[1]{ .count = n });
            } else if (w.has(e, pair[1])) {
                w.remove(e, pair[1]);
            }
        }
    }
    inline for (typed_actions) |pair| {
        if (cat.actionIndex(pair[0])) |ai| {
            if (ha.effects.verb(cat, goods, ai)) |v| {
                var typed = pair[1]{};
                typed.requires.energy = v.requires.energy;
                typed.requires.hours = v.requires.hours;
                typed.requires.materials = onceQty(&v.input, "materials");
                typed.yields.food = onceDist(&v.output, "food");
                typed.yields.materials = onceDist(&v.output, "materials");
                if (w.get(e, pair[1])) |held| held.* = typed else w.add(e, typed);
            } else if (w.has(e, pair[1])) {
                w.remove(e, pair[1]);
            }
        }
    }
}

fn onceQty(side: *const Lines, item: []const u8) f32 {
    var s = side.*;
    const l = s.find(item, .once) orelse return 0;
    return l.n;
}

fn onceDist(side: *const Lines, item: []const u8) dist.Dist {
    var s = side.*;
    const l = s.find(item, .once) orelse return .{ .kind = .fixed, .s = 0 };
    return l.asDist();
}

// ============================ Tests =====================================================

const testing = std.testing;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn loadShipped() !Catalog {
    var d = roster.Diagnostics{};
    return roster.load(testing.allocator, roster.shipped, &d) catch |err| {
        std.debug.print("{s}\n", .{d.message()});
        return err;
    };
}

fn expectQty(lines: []const Line, item: []const u8, qty: f32) !void {
    var found: ?Line = null;
    for (lines) |l| if (l.per == .once and eql(l.item, item)) {
        found = l;
    };
    if (qty == 0) {
        try testing.expect(found == null);
        return;
    }
    const l = found orelse return error.MissingLine;
    try testing.expectEqual(dist.Kind.fixed, l.kind);
    try testing.expectEqual(qty, l.n);
}

/// A line for `item` equal to the typed distribution, or none when the typed yield is the
/// `.fixed` zero placeholder that means "nothing on this side".
fn expectDist(lines: []const Line, item: []const u8, per: Cadence, d: dist.Dist) !void {
    var found: ?Line = null;
    for (lines) |l| if (l.per == per and eql(l.item, item)) {
        found = l;
    };
    if (d.kind == .fixed and d.s == 0) {
        try testing.expect(found == null);
        return;
    }
    const l = found orelse return error.MissingLine;
    try testing.expectEqual(d.kind, l.kind);
    try testing.expectEqual(d.s, l.n);
    try testing.expectEqual(d.sd, l.sd);
}

test "the shipped files load and validate" {
    var cat = try loadShipped();
    defer cat.deinit();
    try testing.expectEqual(typed_actions.len, cat.actions.len);
    try testing.expectEqual(typed_goods.len, cat.goods.len);
}

test "every typed action is one record, number for number" {
    var cat = try loadShipped();
    defer cat.deinit();
    inline for (typed_actions) |pair| {
        const rec = cat.action(pair[0]) orelse return error.MissingRecord;
        const typed = (pair[1]{});
        try testing.expectEqual(typed.requires.energy, rec.requires.energy);
        try testing.expectEqual(typed.requires.hours, rec.requires.hours);
        try expectQty(rec.input, "materials", typed.requires.materials);
        try testing.expectEqual(@as(usize, if (typed.requires.materials > 0) 1 else 0), rec.input.len);
        try expectDist(rec.output, "food", .once, typed.yields.food);
        try expectDist(rec.output, "materials", .once, typed.yields.materials);
        // Innate ⇔ spawned on every agent; on-surface ⇔ the stable-id catalog's flag; the
        // name is the one the activity strip speaks.
        var innate = false;
        inline for (ha.actions.actions_bundle) |A| {
            if (A == pair[1]) innate = true;
        }
        try testing.expectEqual(innate, rec.innate);
        var on_surface: ?bool = null;
        for (ha.catalog.actions) |r| {
            if (eql(r.id, "act." ++ pair[0])) on_surface = r.on_surface;
        }
        try testing.expectEqual(on_surface.?, rec.on_surface);
        try testing.expectEqual(@as(u8, 1), rec.act);
    }
}

test "every typed good is one record, number for number" {
    var cat = try loadShipped();
    defer cat.deinit();
    var buildable: usize = 0;
    inline for (typed_goods) |pair| {
        const G = pair[1];
        const rec = cat.good(pair[0]) orelse return error.MissingRecord;
        const typed = (G{});
        try testing.expectEqual(@as(u8, 1), rec.act);
        if (@hasField(G, "requires")) {
            // Buildable: the price, the build order, the tier, the stable id, the receipt.
            buildable += 1;
            try testing.expect(rec.buildable);
            try testing.expectEqual(typed.requires.energy, rec.requires.?.energy);
            try testing.expectEqual(typed.requires.hours, rec.requires.?.hours);
            try expectQty(rec.input, "materials", typed.requires.materials);
            try testing.expectEqual(
                if (ha.capital.is_crude(G)) Tier.crude else Tier.manufactured,
                rec.tier.?,
            );
            try testing.expectEqualStrings(ha.catalog.goodId(G), "good." ++ pair[0]);
            try testing.expectEqualStrings(ha.capital.built_msg(G), rec.copy.built);
        } else {
            try testing.expect(!rec.buildable);
            try testing.expectEqual(@as(?Price, null), rec.requires);
            try testing.expectEqual(@as(?Tier, null), rec.tier);
        }
        // The prerequisite verb is the one `needs` names.
        if (ha.capital.prereq_of(G)) |P| {
            try testing.expectEqual(@as(usize, 1), rec.needs.len);
            try testing.expectEqualStrings(actionIdOf(P), rec.needs[0]);
        } else {
            try testing.expectEqual(@as(usize, 0), rec.needs.len);
        }
        // A generator's upkeep and yield are its day lines; nothing else has any.
        if (@hasField(G, "upkeep")) {
            try expectDist(rec.input, "materials", .day, .{ .kind = .fixed, .s = typed.upkeep.materials });
            try expectDist(rec.output, "food", .day, typed.yields.food);
            try expectDist(rec.output, "materials", .day, typed.yields.materials);
        } else {
            for (rec.input) |l| try testing.expectEqual(Cadence.once, l.per);
            for (rec.output) |l| try testing.expectEqual(Cadence.once, l.per);
        }
        // The shelter's standing conditions and capacity.
        if (@hasField(G, "unlock")) {
            try testing.expectEqual(typed.unlock.vigor_abs, rec.unlock.?.vigor_abs);
            try testing.expectEqual(typed.unlock.food, rec.unlock.?.food);
            try testing.expectEqual(typed.unlock.goods, rec.unlock.?.goods);
        } else {
            try testing.expectEqual(@as(?Unlock, null), rec.unlock);
        }
        if (@hasField(G, "capacity")) {
            try testing.expectEqual(typed.capacity, rec.capacity);
        } else {
            try testing.expectEqual(@as(u32, 0), rec.capacity);
        }
    }
    try testing.expectEqual(ha.capital.buildable_bundle.len, buildable);
}

test "an unlocker's grant names the verb its typed grant adds" {
    var cat = try loadShipped();
    defer cat.deinit();
    var w = ha.world.World.init();
    const pairs = .{
        .{ "fish_rod", comp.FishRod, "fish", comp.ActionFish },
        .{ "hatchet", comp.Hatchet, "chop_wood", comp.ActionChopWood },
        .{ "wire_snares", comp.WireSnares, "check_traps", comp.ActionCheckTraps },
        .{ "air_rifle", comp.AirRifle, "hunt", comp.ActionHunt },
        .{ "fish_net", comp.FishNet, "fish", comp.ActionFish },
        .{ "hand_axe", comp.HandAxe, "chop_wood", comp.ActionChopWood },
    };
    inline for (pairs) |p| {
        const rec = cat.good(p[0]).?;
        var granted = false;
        for (rec.effects) |e| switch (e) {
            .grant => |t| if (eql(t, p[2])) {
                granted = true;
            },
            else => {},
        };
        try testing.expect(granted);
        const e = w.spawn(.{ comp.Vigor{}, comp.InventoryFood{}, comp.InventoryMaterial{} });
        w.add(e, p[1]{});
        ha.capital.grant_public(&w, e, p[1]);
        try testing.expect(w.has(e, p[3]));
    }
}

test "the two tool families rank rod under net and hatchet under hand axe" {
    var cat = try loadShipped();
    defer cat.deinit();
    try testing.expectEqualStrings("fishing", cat.good("fish_rod").?.family.?.name);
    try testing.expectEqual(@as(u8, 1), cat.good("fish_rod").?.family.?.rank);
    try testing.expectEqual(@as(u8, 2), cat.good("fish_net").?.family.?.rank);
    try testing.expectEqualStrings("chopping", cat.good("hand_axe").?.family.?.name);
    try testing.expectEqual(@as(u8, 1), cat.good("hatchet").?.family.?.rank);
    try testing.expectEqual(@as(u8, 2), cat.good("hand_axe").?.family.?.rank);
}
