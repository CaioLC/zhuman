//! `neighbours` — a stand-in Act II neighbour economy behind the MARKET view (`market.html`),
//! standing in for population, per-agent ledgers, valuation and trade evidence
//! (`docs/roadmap.md`). It is deterministic: `seed` builds the same neighbours every run from a
//! fixed LCG.
//!
//! Each neighbour has a trade (what it makes, what it buys), finite stocks it sells, wants it
//! buys, its own asking and bidding prices, and coin. The player posts sells and buys at its
//! own prices; `buyersFor`/`sellersFor` read how many neighbours would take a post. A proposed
//! deal is judged in the neighbour's own valuation (`verdict`), and an accepted one settles both
//! sides of the neighbour's books (`settle`) and leaves evidence (`evidence`). The player's side
//! of a settlement is the caller's: it moves the real ledger and goods.
//!
//! Items are the six resources and six Act II goods, by catalog id.
//!
//! Before anyone else exists, the book holds the lone actor's Act I offers (`Offers`): no
//! neighbour reads them and there is no coin, so an offer is a quantity alone, keyed by what is
//! offered (`Holding`), since `items` holds no Act I good.

const std = @import("std");
const roster = @import("../data/roster.zig");

pub const items = [_][]const u8{
    "food",         "water",      "fuel",         "metal",      "minerals",   "biomass",
    "worked_stone", "clay_crock", "glass_pane",   "work_clothes", "hand_tools", "fishing_net",
};
pub const item_count = items.len;
/// The first crafted item; below it are resources.
pub const first_crafted = 6;
/// Index of coin in a deal bundle (after the items).
pub const coin = item_count;
pub const bundle_len = item_count + 1;

/// What an item is worth to a typical neighbour, in coin.
pub const base = [item_count]u16{ 4, 3, 5, 11, 7, 4, 6, 7, 14, 8, 16, 18 };

pub const Trade = enum {
    forager,
    fisher,
    carrier,
    woodcutter,
    miner,
    smith,

    pub fn makes(self: Trade) usize {
        return switch (self) {
            .forager => 5,
            .fisher => 0,
            .carrier => 1,
            .woodcutter => 2,
            .miner => 4,
            .smith => 3,
        };
    }
    pub fn buys(self: Trade) []const usize {
        return switch (self) {
            .forager => &.{ 0, 1 },
            .fisher => &.{ 5, 2 },
            .carrier => &.{ 0, 5 },
            .woodcutter => &.{ 0, 5, 3 },
            .miner => &.{ 0, 1, 2 },
            .smith => &.{ 4, 2, 0 },
        };
    }
};

const first_names = [_][]const u8{ "Mira", "Tomas", "Odd", "Hesper", "Juno", "Caspar", "Rhea", "Bram", "Linnea", "Soren", "Vesna", "Edda", "Mikal", "Thora", "Ansel", "Petra", "Dagny", "Oren", "Sable", "Lior", "Nessa", "Garrick", "Ilva", "Roth" };
const last_names = [_][]const u8{ "Halt", "Vane", "Orrick", "Bray", "Sund", "Ferrow", "Kell", "Dace", "Mord", "Lahn", "Virek", "Ost", "Crale", "Benn", "Ryne", "Thall" };

pub const max_agents = 24;

pub const Agent = struct {
    first: u8 = 0,
    last: u8 = 0,
    trade: Trade = .forager,
    /// Units it offers, by item.
    sells: [item_count]u16 = @splat(0),
    /// Units it wants, by item.
    buys: [item_count]u16 = @splat(0),
    /// Its asking price for what it sells, and its bid for what it buys, by item.
    ask: [item_count]u16 = @splat(0),
    bid: [item_count]u16 = @splat(0),
    coin: u16 = 0,

    pub fn firstName(self: Agent) []const u8 {
        return first_names[self.first];
    }
    pub fn lastName(self: Agent) []const u8 {
        return last_names[self.last];
    }
    /// What it would pay for, or take for, one unit of `item`: its bid if it buys it, else its
    /// ask, else the base value.
    pub fn value(self: Agent, item: usize) u16 {
        if (self.bid[item] > 0) return self.bid[item];
        if (self.ask[item] > 0) return self.ask[item];
        return base[item];
    }
};

pub const Post = struct { qty: u16 = 0, price: u16 = 0 };
pub const Evidence = struct { item: u8, coin: u16 };

/// One thing the lone actor holds in Act I and may offer: one of its two stocks, or a good by
/// its catalog index.
pub const Holding = union(enum) {
    food,
    biomass,
    good: u16,

    /// The holding as one number, what `Offers` and a repeated row are keyed by: food 0,
    /// materials 1, a good its catalog index plus 2.
    pub fn key(self: Holding) u16 {
        return switch (self) {
            .food => 0,
            .biomass => 1,
            .good => |gi| 2 + gi,
        };
    }

    pub fn ofKey(k: u16) Holding {
        return switch (k) {
            0 => .food,
            1 => .biomass,
            else => .{ .good = k - 2 },
        };
    }
};

/// What of `held` units of `h` the lone actor may offer: the larder and the stockpile are the
/// body's and stay whole, and a good keeps the one unit whose effect is in use, so only a second
/// pair of sandals or a second hatchet is spare (the Act I holdings' spare units read the same).
pub fn spareOf(h: Holding, held: f32) f32 {
    return switch (h) {
        .food, .biomass => 0,
        .good => @max(0, held - 1),
    };
}

/// The lone actor's offers in Act I, a quantity per holding (`Holding.key`). No price: there is
/// no coin in Act I. They do not carry into Act II: the curtain empties the book, and the Act II
/// market starts from its own seed.
pub const Offers = struct {
    pub const len = 2 + roster.max_goods;
    qty: [len]u16 = @splat(0),

    pub fn of(self: *const Offers, h: Holding) u16 {
        return self.qty[h.key()];
    }

    /// Offer `qty` of `h`, at most its whole spare units (`spareOf`). Returns what stands.
    pub fn post(self: *Offers, h: Holding, qty: u32, spare: f32) u16 {
        const cap: u32 = @intFromFloat(@floor(@max(0, spare)));
        const q: u16 = @intCast(@min(qty, cap, std.math.maxInt(u16)));
        self.qty[h.key()] = q;
        return q;
    }

    /// How many holdings are offered.
    pub fn count(self: *const Offers) u32 {
        var n: u32 = 0;
        for (self.qty) |q| n += @intFromBool(q > 0);
        return n;
    }

    /// How many units are offered, over every holding.
    pub fn units(self: *const Offers) u32 {
        var n: u32 = 0;
        for (self.qty) |q| n += q;
        return n;
    }
};

pub const Market = struct {
    agents: [max_agents]Agent = @splat(.{}),
    n: u8 = 0,
    sell_posts: [item_count]Post = @splat(.{}),
    buy_posts: [item_count]Post = @splat(.{}),
    /// The lone actor's Act I offers.
    act_one: Offers = .{},
    history: [64]Evidence = undefined,
    history_len: u8 = 0,
    seeded: bool = false,

    pub fn people(self: *const Market) []const Agent {
        return self.agents[0..self.n];
    }

    /// The lowest, highest and latest coin paid per unit of `item`, from trades that happened.
    pub fn evidence(self: *const Market, item: usize) ?struct { lo: u16, hi: u16, last: u16 } {
        var lo: u16 = std.math.maxInt(u16);
        var hi: u16 = 0;
        var last: ?u16 = null;
        for (self.history[0..self.history_len]) |h| {
            if (h.item != item) continue;
            lo = @min(lo, h.coin);
            hi = @max(hi, h.coin);
            last = h.coin;
        }
        const l = last orelse return null;
        return .{ .lo = lo, .hi = hi, .last = l };
    }

    fn record(self: *Market, item: usize, price: u16) void {
        if (self.history_len == self.history.len) {
            std.mem.copyForwards(Evidence, self.history[0 .. self.history.len - 1], self.history[1..]);
            self.history_len -= 1;
        }
        self.history[self.history_len] = .{ .item = @intCast(item), .coin = price };
        self.history_len += 1;
    }

    /// Neighbours whose bid would take a sell post of `item` at `price`.
    pub fn buyersFor(self: *const Market, item: usize, price: u16) u32 {
        var n: u32 = 0;
        for (self.people()) |a| n += @intFromBool(a.buys[item] > 0 and a.bid[item] >= price);
        return n;
    }

    /// Neighbours whose ask would fill a buy post of `item` at `price`.
    pub fn sellersFor(self: *const Market, item: usize, price: u16) u32 {
        var n: u32 = 0;
        for (self.people()) |a| n += @intFromBool(a.sells[item] > 0 and a.ask[item] <= price);
        return n;
    }

    /// Units of `item` neighbours offer, and how many offer it.
    pub fn offered(self: *const Market, item: usize) struct { units: u32, by: u32 } {
        var units: u32 = 0;
        var by: u32 = 0;
        for (self.people()) |a| if (a.sells[item] > 0) {
            units += a.sells[item];
            by += 1;
        };
        return .{ .units = units, .by = by };
    }

    /// Units of `item` neighbours want, and how many want it.
    pub fn wanted(self: *const Market, item: usize) struct { units: u32, by: u32 } {
        var units: u32 = 0;
        var by: u32 = 0;
        for (self.people()) |a| if (a.buys[item] > 0) {
            units += a.buys[item];
            by += 1;
        };
        return .{ .units = units, .by = by };
    }

    /// Every offer and want standing on the market: an offer is one neighbour selling one item,
    /// one item the player posts to sell or one holding the lone actor offers in Act I, a want
    /// one neighbour still wanting one item or one item the player posts to buy.
    pub fn standing(self: *const Market) struct { offers: u32, wants: u32 } {
        var offers: u32 = self.act_one.count();
        var wants: u32 = 0;
        for (self.people()) |a| for (0..item_count) |i| {
            offers += @intFromBool(a.sells[i] > 0);
            wants += @intFromBool(a.buys[i] > 0);
        };
        for (self.sell_posts, self.buy_posts) |s, b| {
            offers += @intFromBool(s.qty > 0);
            wants += @intFromBool(b.qty > 0);
        }
        return .{ .offers = offers, .wants = wants };
    }

    /// Settle an accepted deal on the neighbour's books: it takes `give` (the player's side),
    /// hands over `take`, and the trade leaves evidence per unit of what it sold.
    pub fn settle(self: *Market, agent: usize, give: [bundle_len]u16, take: [bundle_len]u16) void {
        const a = &self.agents[agent];
        for (0..item_count) |i| {
            a.buys[i] -|= give[i];
            a.sells[i] -|= take[i];
        }
        a.coin +|= give[coin];
        a.coin -|= take[coin];
        const paid = valueOf(a.*, give);
        for (0..item_count) |i| if (take[i] > 0) self.record(i, @intCast(@max(1, paid / take[i])));
    }

    /// Build the neighbours: `n` people, deterministic.
    pub fn seed(self: *Market, n: u8) void {
        var lcg: u32 = 20261019;
        const rnd = struct {
            fn next(s: *u32) f32 {
                s.* = s.* *% 1103515245 +% 12345;
                return @as(f32, @floatFromInt((s.* >> 8) & 0xffff)) / 65536.0;
            }
        }.next;
        self.* = .{};
        self.n = @min(n, max_agents);
        const trades = std.enums.values(Trade);
        for (self.agents[0..self.n], 0..) |*a, i| {
            const trade = trades[i % trades.len];
            a.* = .{ .first = @intCast(i % first_names.len), .last = @intCast((i * 7 + i / first_names.len) % last_names.len), .trade = trade };
            const makes = trade.makes();
            a.sells[makes] = 4 + @as(u16, @intFromFloat(rnd(&lcg) * 14));
            if (rnd(&lcg) < 0.5) {
                const g = first_crafted + @as(usize, @intFromFloat(rnd(&lcg) * (item_count - first_crafted)));
                a.sells[g] += 1 + @as(u16, @intFromFloat(rnd(&lcg) * 5));
            }
            for (trade.buys()) |b| a.buys[b] = 2 + @as(u16, @intFromFloat(rnd(&lcg) * 8));
            if (rnd(&lcg) < 0.5) {
                const g = first_crafted + @as(usize, @intFromFloat(rnd(&lcg) * (item_count - first_crafted)));
                if (a.sells[g] == 0) a.buys[g] = 1 + @as(u16, @intFromFloat(rnd(&lcg) * 4));
            }
            for (0..item_count) |it| {
                const b: f32 = @floatFromInt(base[it]);
                if (a.sells[it] > 0) a.ask[it] = @max(1, @as(u16, @intFromFloat(@round(b * (0.75 + rnd(&lcg) * 0.6)))));
                if (a.buys[it] > 0) a.bid[it] = @max(1, @as(u16, @intFromFloat(@round(b * (0.8 + rnd(&lcg) * 0.6)))));
            }
            a.coin = 10 + @as(u16, @intFromFloat(rnd(&lcg) * 40));
        }
        // A little evidence: some of the first neighbours have already sold what they make.
        for (self.agents[0..@min(self.n, 16)], 0..) |a, i| {
            if (i % 3 == 2) continue;
            const g = a.trade.makes();
            self.record(g, @max(1, @as(u16, @intFromFloat(@round(@as(f32, @floatFromInt(a.ask[g])) * (0.85 + rnd(&lcg) * 0.3))))));
        }
        self.seeded = true;
    }
};

/// What a bundle is worth to `a`, in coin: coin at face, items at the neighbour's own value.
pub fn valueOf(a: Agent, bundle: [bundle_len]u16) u32 {
    var total: u32 = bundle[coin];
    for (0..item_count) |i| total += @as(u32, bundle[i]) * a.value(i);
    return total;
}

pub const Verdict = union(enum) {
    /// Nothing on one side.
    idle,
    /// The neighbour buys none of what the player offers, and no coin is offered.
    refuse,
    accept,
    /// The neighbour would want about `more` more of `item`.
    counter: struct { item: usize, more: u32 },
};

/// Whether `a` wants any of what the player holds spare.
pub fn wantsAny(a: Agent, spare: [item_count]f32) bool {
    for (0..item_count) |i| if (a.buys[i] > 0 and spare[i] >= 1) return true;
    return false;
}

/// Judge a proposed deal in `a`'s own valuation: the player gives `give`, takes `take`.
pub fn verdict(a: Agent, give: [bundle_len]u16, take: [bundle_len]u16, spare: [item_count]f32) Verdict {
    var gives = false;
    var takes = false;
    for (give) |q| gives = gives or q > 0;
    for (take) |q| takes = takes or q > 0;
    if (!gives or !takes) return .idle;
    if (!wantsAny(a, spare) and give[coin] == 0) return .refuse;
    const gain = valueOf(a, give);
    const cost = valueOf(a, take);
    if (gain >= cost) return .accept;
    // Counter in the first item the player gives, else the first the neighbour buys.
    const item = blk: {
        for (0..item_count) |i| if (give[i] > 0) break :blk i;
        for (0..item_count) |i| if (a.buys[i] > 0) break :blk i;
        break :blk 0;
    };
    const per = @max(1, a.value(item));
    return .{ .counter = .{ .item = item, .more = (cost - gain + per - 1) / per } };
}

// ============================ Tests =====================================================

const testing = std.testing;

test "seeding is deterministic and every neighbour sells what its trade makes" {
    var a: Market = .{};
    var b: Market = .{};
    a.seed(24);
    b.seed(24);
    try testing.expectEqual(@as(u8, 24), a.n);
    for (a.people(), b.people()) |x, y| {
        try testing.expectEqual(x.sells, y.sells);
        try testing.expect(x.sells[x.trade.makes()] > 0);
        try testing.expect(x.ask[x.trade.makes()] > 0);
    }
    try testing.expect(a.history_len > 0);
}

test "a fair deal is accepted and settles both sides of the neighbour's books" {
    var m: Market = .{};
    m.seed(6);
    const a = m.agents[0]; // a forager: sells biomass, buys food and water
    var give: [bundle_len]u16 = @splat(0);
    var take: [bundle_len]u16 = @splat(0);
    take[5] = 1;
    give[coin] = a.ask[5];
    var spare: [item_count]f32 = @splat(0);
    try testing.expectEqual(Verdict.accept, verdict(a, give, take, spare));
    const before = m.agents[0].sells[5];
    m.settle(0, give, take);
    try testing.expectEqual(before - 1, m.agents[0].sells[5]);
    try testing.expect(m.evidence(5) != null);
    // Nothing spare it buys and no coin: refused in its own terms.
    give[coin] = 0;
    give[3] = 1; // metal, which a forager does not buy
    spare[3] = 5;
    try testing.expectEqual(Verdict.refuse, verdict(a, give, take, spare));
}

test "the market's standing offers and wants count the neighbours' and the player's" {
    var m: Market = .{};
    m.seed(0);
    try testing.expectEqual(@as(u32, 0), m.standing().offers);
    try testing.expectEqual(@as(u32, 0), m.standing().wants);
    m.sell_posts[5] = .{ .qty = 3, .price = 4 };
    m.buy_posts[0] = .{ .qty = 0, .price = 4 }; // priced but not posted: no want
    try testing.expectEqual(@as(u32, 1), m.standing().offers);
    try testing.expectEqual(@as(u32, 0), m.standing().wants);

    m.seed(6);
    var offers: u32 = 0;
    var wants: u32 = 0;
    for (m.people()) |a| for (0..item_count) |i| {
        offers += @intFromBool(a.sells[i] > 0);
        wants += @intFromBool(a.buys[i] > 0);
    };
    m.buy_posts[1] = .{ .qty = 2, .price = 3 };
    try testing.expectEqual(offers, m.standing().offers);
    try testing.expectEqual(wants + 1, m.standing().wants);
    // A neighbour sold out of a want no longer counts it.
    const a = &m.agents[0];
    const first = for (0..item_count) |i| {
        if (a.buys[i] > 0) break i;
    } else unreachable;
    a.buys[first] = 0;
    try testing.expectEqual(wants, m.standing().wants);
}

test "an Act I offer is keyed by its holding, capped at the spare and counted in the market's standing" {
    var m: Market = .{};
    const sandals: Holding = .{ .good = 7 };
    try testing.expectEqual(sandals, Holding.ofKey(sandals.key()));
    try testing.expectEqual(Holding.biomass, Holding.ofKey((@as(Holding, .biomass)).key()));

    // The stocks are the body's: nothing of them is spare. A good keeps one unit.
    try testing.expectEqual(@as(f32, 0), spareOf(.food, 11.6));
    try testing.expectEqual(@as(f32, 0), spareOf(.biomass, 31));
    try testing.expectEqual(@as(f32, 1), spareOf(sandals, 2));
    try testing.expectEqual(@as(f32, 0), spareOf(sandals, 1));
    try testing.expectEqual(@as(f32, 0), spareOf(sandals, 0));

    // An offer stands at most at the spare.
    try testing.expectEqual(@as(u16, 1), m.act_one.post(sandals, 3, spareOf(sandals, 2)));
    try testing.expectEqual(@as(u16, 0), m.act_one.post(.food, 2, spareOf(.food, 11.6)));
    try testing.expectEqual(@as(u16, 1), m.act_one.of(sandals));
    try testing.expectEqual(@as(u32, 1), m.act_one.count());
    try testing.expectEqual(@as(u32, 1), m.act_one.units());
    try testing.expectEqual(@as(u32, 1), m.standing().offers);
    try testing.expectEqual(@as(u32, 0), m.standing().wants);

    // Taken down, it stands no more.
    _ = m.act_one.post(sandals, 0, 1);
    try testing.expectEqual(@as(u32, 0), m.standing().offers);
}

test "posts read who would take them" {
    var m: Market = .{};
    m.seed(24);
    try testing.expect(m.buyersFor(0, 1) >= m.buyersFor(0, 50));
    try testing.expect(m.sellersFor(5, 50) >= m.sellersFor(5, 1));
}
