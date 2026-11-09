//! `ledger` — where a record's amounts meet an agent's holdings.
//!
//! A resource is held on that resource's inventory component; a good, as a count on
//! `comp.Goods`. This module is the one switch over `Resource` to those components, so the
//! labor, build, generator and barter paths can check, pay and deposit a `roster.Requires` or a
//! `roster.Output` without naming a stock. An amount may be spent to exactly zero — the strict
//! gate is energy's, and energy is the body's, not the ledger's.

const std = @import("std");
const comp = @import("../components.zig");
const dist = @import("../kernel/dist.zig");
const roster = @import("../data/roster.zig");

const World = @import("../ecs.zig").World;
const Entity = @import("../ecs.zig").Entity;
const Catalog = roster.Catalog;
const Resource = roster.Resource;

/// The inventory component that holds a resource's balance, or null when the resource has
/// no component: an agent then holds none of it. Coin's is a stand-in (`docs/roadmap.md`).
pub fn Stock(comptime r: Resource) ?type {
    return switch (r) {
        .food => comp.InventoryFood,
        .biomass => comp.InventoryBiomass,
        .water => comp.InventoryWater,
        .fuel => comp.InventoryFuel,
        .metal => comp.InventoryMetal,
        .minerals => comp.InventoryMinerals,
        .coin => comp.InventoryCoin,
    };
}

/// An agent's balance of `r`; zero when it holds no stock of it.
pub fn balance(w: *const World, e: Entity, r: Resource) f32 {
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

/// An item a trade or a receipt can name: a resource, or a good by catalog index.
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

/// How much of an item the agent holds: a resource's balance, a good's count.
pub fn heldItem(w: *const World, e: Entity, it: Item) f32 {
    switch (it) {
        .resource => |r| return balance(w, e, r),
        .good => |gi| {
            const g = w.get(e, comp.Goods) orelse return 0;
            return @floatFromInt(g.count[gi]);
        },
    }
}

/// The first resource, in `Resource` order, whose amount in `req` at `scale` the agent cannot
/// pay, or null when every one is affordable. An amount may be spent to exactly zero.
pub fn short(w: *const World, e: Entity, req: *const roster.Requires, scale: f32) ?Resource {
    for (std.enums.values(Resource)) |r| {
        const n = req.get(r);
        if (n > 0 and balance(w, e, r) < n * scale) return r;
    }
    return null;
}

/// Pay every resource amount of `req` at `scale`. The caller has checked `short`.
pub fn pay(w: *World, e: Entity, req: *const roster.Requires, scale: f32) void {
    for (std.enums.values(Resource)) |r| {
        const n = req.get(r);
        if (n > 0) _ = move(w, e, r, -(n * scale));
    }
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

/// What a payment, a draw or a refund moved: one line per item, in `Resource` order, at most
/// one per resource. Plain fixed-size data naming items by `Item`, so a fact event can carry
/// it (`sim/events.zig`).
pub const Receipt = struct {
    lines: [@typeInfo(Resource).@"enum".field_names.len]Deposit = undefined,
    len: u8 = 0,

    /// One moved amount of one item.
    pub const Deposit = struct {
        item: Item,
        qty: f32,
    };

    /// Append a line; a line past the capacity is dropped (no record has one).
    pub fn add(self: *Receipt, it: Item, qty: f32) void {
        if (self.len == self.lines.len) return;
        self.lines[self.len] = .{ .item = it, .qty = qty };
        self.len += 1;
    }

    pub fn slice(self: *const Receipt) []const Deposit {
        return self.lines[0..self.len];
    }

    /// The sum of every line's quantity.
    pub fn total(self: *const Receipt) f32 {
        var t: f32 = 0;
        for (self.slice()) |d| t += d.qty;
        return t;
    }
};

/// `req`'s resource amounts at `scale` as a receipt, in `Resource` order.
pub fn receiptOf(req: *const roster.Requires, scale: f32) Receipt {
    var r = Receipt{};
    for (std.enums.values(Resource)) |res| {
        const n = req.get(res);
        if (n > 0) r.add(.{ .resource = res }, n * scale);
    }
    return r;
}

/// Give back `req`'s resource amounts at `scale` — a cancelled build's salvage — and return
/// what came back.
pub fn refund(w: *World, e: Entity, req: *const roster.Requires, scale: f32) Receipt {
    const r = receiptOf(req, scale);
    for (r.slice()) |d| _ = move(w, e, d.item.resource, d.qty);
    return r;
}

/// Draw every yield of `out` at `quality` and `scale` and deposit what comes up. Returns what
/// landed, in `Resource` order, so the caller can write the receipt. `out.vigor` is the
/// caller's.
pub fn draw(w: *World, e: Entity, out: *const roster.Output, rng: std.Random, quality: f32, scale: f32) Receipt {
    var r = Receipt{};
    for (std.enums.values(Resource)) |res| {
        const d = out.get(res) orelse continue;
        const amount = quality * dist.sample(d.asDist(), rng) * scale;
        _ = move(w, e, res, amount);
        r.add(.{ .resource = res }, amount);
    }
    return r;
}

// ============================ Tests =====================================================

const testing = std.testing;

fn fixture() !Catalog {
    return roster.load(testing.allocator, roster.shipped, null);
}

test "a resource reads and moves the inventory component; a missing stock holds nothing" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{ comp.InventoryFood{ .v = 3, .quality = 1, .spoils = 0 }, comp.InventoryBiomass{ .v = 2 } });
    try testing.expectEqual(@as(f32, 3), balance(&w, e, .food));
    try testing.expectEqual(@as(f32, 2), balance(&w, e, .biomass));
    try testing.expectEqual(@as(f32, 0), balance(&w, e, .water)); // no component
    try testing.expect(move(&w, e, .food, 1.5));
    try testing.expectEqual(@as(f32, 4.5), balance(&w, e, .food));
    try testing.expect(!move(&w, e, .water, 1)); // nowhere to put it
    const bare = w.spawn(.{comp.Vigor{}});
    try testing.expectEqual(@as(f32, 0), balance(&w, bare, .food));
    try testing.expect(!move(&w, bare, .food, 1));
}

test "short names the first unpayable resource; an amount may be spent to exactly zero" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{ comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 }, comp.InventoryBiomass{ .v = 5 } });
    const both = roster.Requires{ .biomass = 5, .food = 1 };
    try testing.expectEqual(Resource.food, short(&w, e, &both, 1).?); // materials are exactly affordable
    const materials = roster.Requires{ .energy = 9, .biomass = 5 };
    try testing.expect(short(&w, e, &materials, 1) == null); // energy is not the ledger's
    pay(&w, e, &materials, 1);
    try testing.expectEqual(@as(f32, 0), balance(&w, e, .biomass));
    try testing.expectEqual(Resource.biomass, short(&w, e, &.{ .biomass = 1 }, 0.1).?); // scaled
    const r = receiptOf(&both, 0.5);
    try testing.expectEqual(@as(usize, 2), r.slice().len);
    try testing.expectEqual(Item{ .resource = .food }, r.slice()[0].item); // `Resource` order
    try testing.expectEqual(@as(f32, 2.5), r.slice()[1].qty);
}

test "a good item counts units on Goods, rounded and never negative" {
    var cat = try fixture();
    defer cat.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{comp.Goods{}});
    const gi = cat.goodIndex("sandals").?;
    try testing.expect(give(&w, e, &cat, "sandals", 2.4));
    try testing.expectEqual(@as(u32, 2), w.get(e, comp.Goods).?.count[gi]);
    try testing.expectEqual(@as(f32, 2), heldItem(&w, e, .{ .good = gi }));
    try testing.expect(give(&w, e, &cat, "sandals", -5));
    try testing.expectEqual(@as(u32, 0), w.get(e, comp.Goods).?.count[gi]);
    try testing.expect(!give(&w, e, &cat, "nothing", 1)); // unknown item
}

test "draw samples each yield at quality and scale and reports what landed" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var prng = std.Random.DefaultPrng.init(5);
    const e = w.spawn(.{ comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 }, comp.InventoryBiomass{ .v = 0 } });
    const out = roster.Output{ .food = .{ .fixed = 4 }, .biomass = .{ .uniform = 2 } };
    const r = draw(&w, e, &out, prng.random(), 0.5, 1);
    try testing.expectEqual(@as(usize, 2), r.slice().len);
    try testing.expectEqual(@as(f32, 2), r.slice()[0].qty); // 4 × 0.5 quality
    try testing.expectEqual(@as(f32, 2), balance(&w, e, .food));
    try testing.expect(balance(&w, e, .biomass) > 0);
    try testing.expectEqual(Item{ .resource = .biomass }, r.slice()[1].item);
}
