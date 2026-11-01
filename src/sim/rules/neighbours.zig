//! `neighbours` — a **stub** Act II neighbour economy behind the MARKET view (`market.html`),
//! standing in for population, per-agent ledgers, valuation and trade evidence until
//! ACT2-01..09 land. It is deterministic: `seed` builds the same neighbours every run from a
//! fixed LCG, as the prototype does.
//!
//! Each neighbour has a trade (what it makes, what it buys), finite stocks it sells, wants it
//! buys, its own asking and bidding prices, and coin. The player posts sells and buys at its
//! own prices; `buyersFor`/`sellersFor` read how many neighbours would take a post. A proposed
//! deal is judged in the neighbour's own valuation (`verdict`), and an accepted one settles both
//! sides of the neighbour's books (`settle`) and leaves evidence (`evidence`). The player's side
//! of a settlement is the caller's: it moves the real ledger and goods.
//!
//! Items are the six resources and six Act II goods, by catalog id.

const std = @import("std");

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

pub const Market = struct {
    agents: [max_agents]Agent = @splat(.{}),
    n: u8 = 0,
    sell_posts: [item_count]Post = @splat(.{}),
    buy_posts: [item_count]Post = @splat(.{}),
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
    /// Nothing on one side yet.
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

test "posts read who would take them" {
    var m: Market = .{};
    m.seed(24);
    try testing.expect(m.buyersFor(0, 1) >= m.buyersFor(0, 50));
    try testing.expect(m.sellersFor(5, 50) >= m.sellersFor(5, 1));
}
