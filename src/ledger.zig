//! `ledger` — where a `roster.Line` meets an agent's holdings.
//!
//! A line names an item: a resource, held on that resource's inventory component, or a
//! good, held as a count on `comp.Goods`. This module is the one switch over `Resource` to
//! those components, so the labor, build, generator and barter paths can check, pay and
//! deposit a list of lines without naming a stock. An item may be spent to exactly zero —
//! the strict gate is energy's, and energy is a price, not a line.

const std = @import("std");
const ha = @import("ha");
const comp = ha.comp;
const dist = ha.dist;
const roster = ha.roster;

const World = ha.world.World;
const Entity = ha.world.Entity;
const Catalog = roster.Catalog;
const Line = roster.Line;
const Resource = roster.Resource;

/// The inventory component that holds a resource's balance, or null while the resource has
/// no component — an agent then holds none of it. Coin has none until the simulation
/// recognizes a medium of exchange (`docs/roadmap.md`, "ACT2-09").
pub fn Stock(comptime r: Resource) ?type {
    return switch (r) {
        .food => comp.InventoryFood,
        .materials => comp.InventoryMaterial,
        .biomass => comp.InventoryBiomass,
        .water => comp.InventoryWater,
        .fuel => comp.InventoryFuel,
        .metal => comp.InventoryMetal,
        .minerals => comp.InventoryMinerals,
        .coin => null,
    };
}

/// An agent's balance of `r`; zero when it holds no stock of it.
pub fn balance(w: *World, e: Entity, r: Resource) f32 {
    switch (r) {
        inline else => |rr| {
            if (comptime Stock(rr)) |T| {
                const s = w.get(e, T) orelse return 0;
                return s.v;
            }
            return 0;
        },
    }
}

/// Move `amount` of `r` into the agent's balance (negative to take). Returns false, and
/// moves nothing, when the agent holds no stock of `r`.
pub fn move(w: *World, e: Entity, r: Resource, amount: f32) bool {
    switch (r) {
        inline else => |rr| {
            if (comptime Stock(rr)) |T| {
                const s = w.get(e, T) orelse return false;
                s.v += amount;
                return true;
            }
            return false;
        },
    }
}

/// An item a line can name: a resource, or a good by catalog index.
pub const Item = union(enum) {
    resource: Resource,
    good: u16,
};

/// Resolve an item id against the catalog.
pub fn item(cat: *const Catalog, id: []const u8) ?Item {
    if (Catalog.resource(id)) |r| return .{ .resource = r };
    if (cat.goodIndex(id)) |gi| return .{ .good = gi };
    return null;
}

/// How much of a line's item the agent holds.
pub fn held(w: *World, e: Entity, cat: *const Catalog, l: Line) f32 {
    switch (item(cat, l.item) orelse return 0) {
        .resource => |r| return balance(w, e, r),
        .good => |gi| {
            const g = w.get(e, comp.Goods) orelse return 0;
            return @floatFromInt(g.count[gi]);
        },
    }
}

/// The first line the agent cannot pay at `scale`, or null when every line is affordable.
pub fn short(w: *World, e: Entity, cat: *const Catalog, lines: []const Line, scale: f32) ?Line {
    for (lines) |l| if (held(w, e, cat, l) < l.n * scale) return l;
    return null;
}

/// Pay every line at `scale`. The caller has checked `short`.
pub fn pay(w: *World, e: Entity, cat: *const Catalog, lines: []const Line, scale: f32) void {
    for (lines) |l| _ = give(w, e, cat, l.item, -(l.n * scale));
}

/// Deposit `amount` of `id` (negative to take). A good moves in whole units, rounded, and
/// never below zero. Returns false, moving nothing, for an item the agent cannot hold.
pub fn give(w: *World, e: Entity, cat: *const Catalog, id: []const u8, amount: f32) bool {
    switch (item(cat, id) orelse return false) {
        .resource => |r| return move(w, e, r, amount),
        .good => |gi| {
            const g = w.get(e, comp.Goods) orelse return false;
            const units: i64 = @intFromFloat(@round(amount));
            g.count[gi] = @intCast(@max(0, @as(i64, g.count[gi]) + units));
            return true;
        },
    }
}

/// One deposited amount, for a receipt line.
pub const Deposit = struct {
    item: []const u8,
    amount: f32,
};

pub const Receipt = struct {
    items: [roster.max_lines]Deposit = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Receipt) []const Deposit {
        return self.items[0..self.len];
    }
};

/// Draw every line at `quality` and `scale` and deposit what comes up. Returns what landed,
/// in line order, so the caller can write the receipt.
pub fn draw(w: *World, e: Entity, cat: *const Catalog, lines: []const Line, rng: std.Random, quality: f32, scale: f32) Receipt {
    var r = Receipt{};
    for (lines) |l| {
        const amount = quality * dist.sample(l.asDist(), rng) * scale;
        _ = give(w, e, cat, l.item, amount);
        r.items[r.len] = .{ .item = l.item, .amount = amount };
        r.len += 1;
    }
    return r;
}

// ============================ Tests =====================================================

const testing = std.testing;

fn fixture() !Catalog {
    return roster.load(testing.allocator, roster.shipped, null);
}

test "a resource line reads and moves the inventory component; a missing stock holds nothing" {
    var w = World.init();
    const e = w.spawn(.{ comp.InventoryFood{ .v = 3, .quality = 1, .spoils = 0 }, comp.InventoryMaterial{ .v = 2 } });
    try testing.expectEqual(@as(f32, 3), balance(&w, e, .food));
    try testing.expectEqual(@as(f32, 2), balance(&w, e, .materials));
    try testing.expectEqual(@as(f32, 0), balance(&w, e, .water)); // no component yet
    try testing.expect(move(&w, e, .food, 1.5));
    try testing.expectEqual(@as(f32, 4.5), balance(&w, e, .food));
    try testing.expect(!move(&w, e, .water, 1)); // nowhere to put it
    const bare = w.spawn(.{comp.Vigor{}});
    try testing.expectEqual(@as(f32, 0), balance(&w, bare, .food));
    try testing.expect(!move(&w, bare, .food, 1));
}

test "short names the first unpayable line; an item may be spent to exactly zero" {
    var cat = try fixture();
    defer cat.deinit();
    var w = World.init();
    const e = w.spawn(.{ comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 }, comp.InventoryMaterial{ .v = 5 } });
    const lines = [_]Line{
        .{ .item = "materials", .n = 5 },
        .{ .item = "food", .n = 1 },
    };
    const s = short(&w, e, &cat, &lines, 1).?;
    try testing.expectEqualStrings("food", s.item); // materials are exactly affordable
    try testing.expect(short(&w, e, &cat, lines[0..1], 1) == null);
    pay(&w, e, &cat, lines[0..1], 1);
    try testing.expectEqual(@as(f32, 0), balance(&w, e, .materials));
    // Scaled: a tenth of a day's upkeep.
    const upkeep = [_]Line{.{ .item = "materials", .n = 1, .per = .day }};
    try testing.expect(short(&w, e, &cat, &upkeep, 0.1) != null);
}

test "a good line counts units on Goods, rounded and never negative" {
    var cat = try fixture();
    defer cat.deinit();
    var w = World.init();
    const e = w.spawn(.{comp.Goods{}});
    const gi = cat.goodIndex("sandals").?;
    try testing.expect(give(&w, e, &cat, "sandals", 2.4));
    try testing.expectEqual(@as(u32, 2), w.get(e, comp.Goods).?.count[gi]);
    try testing.expectEqual(@as(f32, 2), held(&w, e, &cat, .{ .item = "sandals", .n = 1 }));
    try testing.expect(give(&w, e, &cat, "sandals", -5));
    try testing.expectEqual(@as(u32, 0), w.get(e, comp.Goods).?.count[gi]);
    try testing.expect(!give(&w, e, &cat, "nothing", 1)); // unknown item
}

test "draw samples each line at quality and scale and reports what landed" {
    var cat = try fixture();
    defer cat.deinit();
    var w = World.init();
    var prng = std.Random.DefaultPrng.init(5);
    const e = w.spawn(.{ comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 }, comp.InventoryMaterial{ .v = 0 } });
    const lines = [_]Line{
        .{ .item = "food", .n = 4 }, // fixed: exact
        .{ .item = "materials", .n = 2, .kind = .uniform },
    };
    const r = draw(&w, e, &cat, &lines, prng.random(), 0.5, 1);
    try testing.expectEqual(@as(usize, 2), r.slice().len);
    try testing.expectEqual(@as(f32, 2), r.slice()[0].amount); // 4 × 0.5 quality
    try testing.expectEqual(@as(f32, 2), balance(&w, e, .food));
    try testing.expect(balance(&w, e, .materials) > 0);
    try testing.expectEqualStrings("materials", r.slice()[1].item);
}
