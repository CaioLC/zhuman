//! `trade_book` — the trade dialog's lots and the player's balances as numbers, and every state
//! the dialog shows derived from them: how many lots the
//! player could take, what they are short, which of the three refusals applies, the short and
//! long bundle notation, and the search. Pure: no nodes, no world. The page builds a `Book`
//! from its venue (the passerby's quotes, the merchant's lots) and settles through its own
//! authority; nothing here moves a stock.

const std = @import("std");

/// One line of a bundle: `n` of the thing named `key` (the player's word for it: `food`,
/// `materials`, `coin`, `fishing rod`). `stock` marks a resource balance rather than a good,
/// which changes the notation (`2fo` / `Food +6` against `Fishing rod ×1`).
pub const Term = struct {
    key: []const u8,
    n: f32,
    stock: bool = true,
};

pub const Mode = enum { buy, sell };

pub const Lot = struct {
    /// Stable identity, nonzero (0 is "nothing selected").
    id: u32,
    mode: Mode,
    /// The lot's name as the ledger shows it (`Fishing rod ×1`, `Water ×6`).
    lot: []const u8,
    effect: []const u8,
    /// What the player gives for one lot.
    price: []const Term,
    /// What the player receives for one lot.
    receive: []const Term,
    /// Lots the counterparty still has (a buy), or still can pay for (a sell); null for a sell
    /// bounded by holdings alone.
    stock: ?u32 = null,
    /// What owning the lot changes, shown in the slip.
    consequence: []const u8 = "",
};

/// The player's balance of one key.
pub const Balance = struct { key: []const u8, held: f32 };

/// One signed movement in the visit ledger.
pub const Delta = struct { key: []const u8, n: f32 };

/// The venue's notation: Act I abbreviates its two stocks (`2fo 8ma`); Act II writes them out.
pub const Notation = struct {
    abbrev: []const Abbrev = &.{},
    pub const Abbrev = struct { key: []const u8, letter: []const u8 };

    fn letter(self: Notation, key: []const u8) ?[]const u8 {
        for (self.abbrev) |a| if (std.mem.eql(u8, a.key, key)) return a.letter;
        return null;
    }
};

pub const Book = struct {
    lots: []const Lot,
    /// In the order the slip's AFTER rows and the visit ledger list them.
    balances: []const Balance,
    notation: Notation = .{},

    pub fn held(self: Book, key: []const u8) f32 {
        for (self.balances) |b| if (std.mem.eql(u8, b.key, key)) return b.held;
        return 0;
    }

    pub fn byId(self: Book, id: u32) ?*const Lot {
        for (self.lots) |*l| if (l.id == id) return l;
        return null;
    }

    /// Whole lots the player's holdings cover.
    pub fn affordable(self: Book, lot: *const Lot) u32 {
        var least: f32 = std.math.inf(f32);
        for (lot.price) |t| {
            if (t.n <= 0) continue;
            least = @min(least, @floor(self.held(t.key) / t.n));
        }
        if (std.math.isInf(least)) return 999;
        return @intFromFloat(@max(0, least));
    }

    /// The most lots one settlement can take.
    pub fn maxLots(self: Book, lot: *const Lot) u32 {
        const can = self.affordable(lot);
        return if (lot.mode == .buy) @min(lot.stock orelse 0, can) else @min(lot.stock orelse can, can);
    }

    /// The first price line the player cannot cover for one lot, and by how much.
    pub fn shortfall(self: Book, lot: *const Lot) ?struct { key: []const u8, amount: f32, count: usize } {
        var first: ?struct { key: []const u8, amount: f32 } = null;
        var count: usize = 0;
        for (lot.price) |t| {
            const have = self.held(t.key);
            if (have < t.n) {
                count += 1;
                if (first == null) first = .{ .key = t.key, .amount = t.n - have };
            }
        }
        const f = first orelse return null;
        return .{ .key = f.key, .amount = f.amount, .count = count };
    }

    /// Why the lot cannot be taken, or null. A quote that cannot be taken says which of the
    /// three reasons it is: sold out, held too little to sell, or short of the price.
    pub fn refusal(self: Book, arena: std.mem.Allocator, lot: *const Lot) !?Refusal {
        if (lot.mode == .buy and (lot.stock orelse 0) == 0) return .{
            .short = "sold out",
            .long = "Sold out.",
        };
        if (lot.mode == .sell and (lot.stock orelse 1) == 0) return .{
            .short = "can't pay",
            .long = "The counterparty has nothing left to pay for this lot.",
        };
        const missing = self.shortfall(lot) orelse return null;
        if (lot.mode == .sell) {
            const have = self.held(missing.key);
            var need: f32 = 0;
            for (lot.price) |t| if (std.mem.eql(u8, t.key, missing.key)) {
                need = t.n;
            };
            return .{
                .short = try arena.print("you hold {s}", .{try fmtNum(arena, have)}),
                .long = try arena.print("You hold {s} {s}; this lot needs {s}.", .{ try fmtNum(arena, have), missing.key, try fmtNum(arena, need) }),
            };
        }
        var words: std.ArrayList(u8) = .empty;
        var first = true;
        for (lot.price) |t| {
            const have = self.held(t.key);
            if (have >= t.n) continue;
            if (!first) try words.appendSlice(arena, " and ");
            first = false;
            try words.appendSlice(arena, try arena.print("{s} more {s}", .{ try fmtNum(arena, t.n - have), t.key }));
        }
        return .{
            .short = try arena.print("needs {s} more {s}", .{ try fmtNum(arena, missing.amount), missing.key }),
            .long = try arena.print("You need {s} before you can take this.", .{words.items}),
        };
    }

    /// The lot's ledger corner: `×{max lots}`.
    pub fn lotsCorner(self: Book, arena: std.mem.Allocator, lot: *const Lot) ![]const u8 {
        return arena.print("\u{00d7}{d}", .{self.maxLots(lot)});
    }

    /// The thing the lot moves, and how much of it the player already holds — the ledger's
    /// derived sub-line (`you can fish · you hold 0 fishing rod`; `you hold 31 materials` for a
    /// lot with no effect).
    pub fn subLine(self: Book, arena: std.mem.Allocator, lot: *const Lot) ![]const u8 {
        const side = if (lot.mode == .buy) lot.receive else lot.price;
        if (side.len == 0) return lot.effect;
        const subject = side[0].key;
        const have = try fmtNum(arena, self.held(subject));
        if (lot.effect.len == 0) return arena.print("you hold {s} {s}", .{ have, subject });
        return arena.print("{s} \u{00b7} you hold {s} {s}", .{ lot.effect, have, subject });
    }

    /// The counterpart bundle the ledger's price column carries: what they want for a buy,
    /// what they give for a sell.
    pub fn counterpart(lot: *const Lot) []const Term {
        return if (lot.mode == .buy) lot.price else lot.receive;
    }

    /// Short notation (`2fo 8ma`, `5 coin`, `Fishing rod ×1`).
    pub fn fmtShort(self: Book, arena: std.mem.Allocator, terms: []const Term) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (terms, 0..) |t, i| {
            if (i > 0) try out.append(arena, ' ');
            const n = try fmtNum(arena, t.n);
            if (std.mem.eql(u8, t.key, "coin")) {
                try out.appendSlice(arena, try arena.print("{s} coin", .{n}));
            } else if (self.notation.letter(t.key)) |l| {
                try out.appendSlice(arena, try arena.print("{s}{s}", .{ n, l }));
            } else {
                try out.appendSlice(arena, try arena.print("{s} \u{00d7}{s}", .{ try title(arena, t.key), n }));
            }
        }
        return out.items;
    }

    /// Long notation for the slip, scaled by `lots` (`2 food + 8 materials`, `Water +6`).
    pub fn fmtLong(arena: std.mem.Allocator, terms: []const Term, lots: u32, receiving: bool) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const k: f32 = @floatFromInt(lots);
        for (terms, 0..) |t, i| {
            if (i > 0) try out.appendSlice(arena, " + ");
            const n = try fmtNum(arena, t.n * k);
            if (!t.stock) {
                try out.appendSlice(arena, try arena.print("{s} \u{00d7}{s}", .{ try title(arena, t.key), n }));
            } else if (std.mem.eql(u8, t.key, "coin")) {
                try out.appendSlice(arena, try arena.print("{s} coin", .{n}));
            } else if (receiving) {
                try out.appendSlice(arena, try arena.print("{s} +{s}", .{ try title(arena, t.key), n }));
            } else {
                try out.appendSlice(arena, try arena.print("{s} {s}", .{ n, t.key }));
            }
        }
        return out.items;
    }

    /// Before → after on only the stocks `lots` of the lot touches, in balance order.
    pub fn after(self: Book, arena: std.mem.Allocator, lot: *const Lot, lots: u32) ![]AfterRow {
        var rows: std.ArrayList(AfterRow) = .empty;
        const k: f32 = @floatFromInt(lots);
        for (self.balances) |b| {
            var delta: f32 = 0;
            var touched = false;
            for (lot.price) |t| if (std.mem.eql(u8, t.key, b.key)) {
                delta -= t.n * k;
                touched = true;
            };
            for (lot.receive) |t| if (std.mem.eql(u8, t.key, b.key)) {
                delta += t.n * k;
                touched = true;
            };
            if (!touched) continue;
            try rows.append(arena, .{ .key = b.key, .before = b.held, .after = b.held + delta });
        }
        return rows.items;
    }

    /// Whether the lot answers the ledger's search: plain text over the lot, its effect and the
    /// counterpart, `is:available` / `is:refused` by state, tokens ANDed, `-` negating.
    pub fn matches(self: Book, arena: std.mem.Allocator, lot: *const Lot, query: []const u8) !bool {
        const hay = try std.ascii.allocLowerString(arena, try arena.print("{s} {s} {s}", .{ lot.lot, lot.effect, try self.fmtShort(arena, counterpart(lot)) }));
        const refused = (try self.refusal(arena, lot)) != null;
        var it = std.mem.tokenizeScalar(u8, query, ' ');
        while (it.next()) |raw| {
            const token = try std.ascii.allocLowerString(arena, raw);
            const neg = token.len > 1 and token[0] == '-';
            const term = if (neg) token[1..] else token;
            const hit = if (std.mem.startsWith(u8, term, "is:")) blk: {
                const v = term[3..];
                if (std.mem.eql(u8, v, "available")) break :blk !refused;
                if (std.mem.eql(u8, v, "refused")) break :blk refused;
                break :blk std.mem.find(u8, hay, v) != null;
            } else std.mem.find(u8, hay, term) != null;
            if (hit == neg) return false;
        }
        return true;
    }
};

pub const Refusal = struct { short: []const u8, long: []const u8 };

pub const AfterRow = struct {
    key: []const u8,
    before: f32,
    after: f32,
};

/// A whole number without decimals, else one decimal (`11.6`, `8`).
pub fn fmtNum(arena: std.mem.Allocator, n: f32) ![]const u8 {
    if (@abs(n - @round(n)) < 0.05) return arena.print("{d:.0}", .{n});
    return arena.print("{d:.1}", .{n});
}

/// `fishing rod` → `Fishing rod`.
pub fn title(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    if (key.len == 0) return key;
    const out = try arena.dupe(u8, key);
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

// ============================ Tests =====================================================

const testing = std.testing;

const rod = Lot{
    .id = 1,
    .mode = .buy,
    .lot = "Fishing rod \u{00d7}1",
    .effect = "you can fish",
    .price = &.{ .{ .key = "food", .n = 2 }, .{ .key = "materials", .n = 8 } },
    .receive = &.{.{ .key = "fishing rod", .n = 1, .stock = false }},
    .stock = 1,
};
const axe = Lot{
    .id = 2,
    .mode = .buy,
    .lot = "Hand axe \u{00d7}1",
    .effect = "splitting wood costs less and yields more",
    .price = &.{ .{ .key = "food", .n = 6 }, .{ .key = "materials", .n = 40 } },
    .receive = &.{.{ .key = "hand axe", .n = 1, .stock = false }},
    .stock = 1,
};
const sell_mat = Lot{
    .id = 3,
    .mode = .sell,
    .lot = "Materials \u{00d7}10",
    .effect = "",
    .price = &.{.{ .key = "materials", .n = 10 }},
    .receive = &.{.{ .key = "food", .n = 3 }},
};
const balances = [_]Balance{ .{ .key = "food", .held = 11.6 }, .{ .key = "materials", .held = 31 }, .{ .key = "fishing rod", .held = 0 } };
const book = Book{
    .lots = &.{ rod, axe, sell_mat },
    .balances = &balances,
    .notation = .{ .abbrev = &.{ .{ .key = "food", .letter = "fo" }, .{ .key = "materials", .letter = "ma" } } },
};

test "max lots are bounded by stock on a buy and by holdings on a sell" {
    try testing.expectEqual(@as(u32, 1), book.maxLots(&rod));
    try testing.expectEqual(@as(u32, 0), book.maxLots(&axe));
    try testing.expectEqual(@as(u32, 3), book.maxLots(&sell_mat)); // 31 / 10
}

test "refusals name which of the three reasons applies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try book.refusal(a, &rod)) == null);
    const short = (try book.refusal(a, &axe)).?;
    try testing.expectEqualStrings("needs 9 more materials", short.short);
    try testing.expectEqualStrings("You need 9 more materials before you can take this.", short.long);
    var gone = rod;
    gone.stock = 0;
    try testing.expectEqualStrings("sold out", (try book.refusal(a, &gone)).?.short);
    try testing.expectEqualStrings("Sold out.", (try book.refusal(a, &gone)).?.long);
}

test "notation and AFTER rows follow the prototype" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("2fo 8ma", try book.fmtShort(a, Book.counterpart(&rod)));
    try testing.expectEqualStrings("4 food + 16 materials", try Book.fmtLong(a, rod.price, 2, false));
    try testing.expectEqualStrings("Fishing rod \u{00d7}1", try Book.fmtLong(a, rod.receive, 1, true));
    const rows = try book.after(a, &rod, 1);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expect(rows[0].after < rows[0].before);
    try testing.expect(rows[2].after > rows[2].before);
    try testing.expectEqualStrings("you can fish \u{00b7} you hold 0 fishing rod", try book.subLine(a, &rod));
    try testing.expectEqualStrings("you hold 31 materials", try book.subLine(a, &sell_mat));
}

test "search ANDs tokens, negates with -, and filters by is:" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try book.matches(a, &rod, "fish"));
    try testing.expect(!try book.matches(a, &rod, "fish -rod"));
    try testing.expect(try book.matches(a, &axe, "is:refused"));
    try testing.expect(!try book.matches(a, &axe, "is:available"));
}
