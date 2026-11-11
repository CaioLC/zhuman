//! `market_view` — Act II's MARKET tab, the neighbours (`market.html`). A view, not a dialog,
//! and its primitive is a person, not a good. With few neighbours the list reads as people in
//! sentences; with many it collapses to goods in notation, each with a price range drawn only
//! from trades that happened. A deal composes both sides on the deal slip and is judged in the
//! counterparty's own valuation. INVENTORY posts the player's offers and wants at its own
//! prices, and each post says how many would take it.
//!
//! The neighbours are `ha.sim.rules.neighbours` (a stand-in, `docs/roadmap.md`);
//! the player's holdings arrive as numbers. The view edits the player's posts on the neighbour
//! book and reports a proposed deal the neighbour accepts, which the page writes as a
//! `NeighbourDeal` intent; the handler settles both sides.
//!
//! Act I's MARKET is the same view with nobody in it (`Player.own`): no neighbours and no coin,
//! so no PRICE column and no coin wording. Its INVENTORY lists what the lone actor holds, keyed
//! by holding; a stepped offer is reported (`Result.offer`) and the surface writes it as a
//! `PostOffer` intent, which the handler caps at the spare.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const vd = style.verdict;
const Style = style.Style;
const El = uic.elements.El;
const nb = ha.sim.rules.neighbours;
const MarketState = uic.UiState.MarketState;

const stepper_mod = @import("./quantity_stepper.zig");
const paginator_mod = @import("./paginator.zig");
const book_mod = @import("./trade_book.zig");

comptime {
    std.debug.assert(@typeInfo(@FieldType(MarketState, "give")).array.len == nb.bundle_len);
}

const pad_x: f32 = 15;
const slip_w: f32 = 262;
const slip_inner: f32 = slip_w - 2 * pad_x;
const per_page: usize = 8;
/// Up to this many neighbours, the list reads as people; beyond it, as goods.
const natural_people: usize = 12;

/// One thing the lone actor holds in Act I: what it is, how much is held and how much of it
/// is spare (`nb.spareOf`).
pub const Own = struct { item: nb.Holding, held: f32, spare: f32 };

/// The player's side, as numbers by item (`nb.items`), plus coin.
pub const Player = struct {
    trade: []const u8,
    held: [nb.item_count]f32,
    reserved: [nb.item_count]f32,
    coin: f32,
    /// Act I's inventory, in its order: food, materials, then each good owned. Set, the view is
    /// Act I's: the INVENTORY lists these with no price, the offers are the book's `act_one`
    /// and change through `Result.offer`, and no line speaks of coin.
    own: ?[]const Own = null,

    pub fn spare(self: Player, i: usize) f32 {
        return @max(0, self.held[i] - self.reserved[i]);
    }
    fn spares(self: Player) [nb.item_count]f32 {
        var out: [nb.item_count]f32 = undefined;
        for (&out, 0..) |*s, i| s.* = self.spare(i);
        return out;
    }
};

pub const Settled = struct {
    neighbour: u8,
    give: [nb.bundle_len]u16,
    take: [nb.bundle_len]u16,
};

/// An Act I offer stepped this frame: the quantity `item` should stand at.
pub const Offered = struct { item: nb.Holding, qty: u16 };

pub const Result = struct {
    /// A deal proposed this frame that the neighbour accepts; the page writes it as an intent.
    settled: ?Settled = null,
    /// An Act I offer stepped this frame; the caller writes it as a `PostOffer` intent.
    offer: ?Offered = null,
};

const Group = enum { person, good };

fn activeGroup(st: *const MarketState, n: usize) Group {
    return switch (st.group) {
        1 => .person,
        2 => .good,
        else => if (n <= natural_people) .person else .good,
    };
}

/// The player's word for item `i` (`food`, `cut stone`).
fn word(ctx: *uic.UiCtx, i: usize) ![]const u8 {
    const cat = &ctx.res.game.catalog;
    if (ha.sim.data.roster.Catalog.resource(nb.items[i])) |r| return r.wordIn(2);
    if (cat.good(nb.items[i])) |g| return std.ascii.allocLowerString(ctx.arena, g.name);
    return nb.items[i];
}

/// The catalog's short effect for item `i` (`nets fish`), or empty for a resource or a good
/// without one.
fn shortEffect(ctx: *uic.UiCtx, i: usize) []const u8 {
    const g = ctx.res.game.catalog.good(nb.items[i]) orelse return "";
    return g.copy.short;
}

/// The player's word for an Act I holding (`food`, `materials`, `wire snares`).
fn ownWord(ctx: *uic.UiCtx, h: nb.Holding) ![]const u8 {
    return switch (h) {
        .food => ha.sim.data.roster.Resource.food.wordIn(1),
        .biomass => ha.sim.data.roster.Resource.biomass.wordIn(1),
        .good => |gi| std.ascii.allocLowerString(ctx.arena, ctx.res.game.catalog.goods[gi].name),
    };
}

/// The catalog's short effect for an Act I holding, or empty for a stock.
fn ownShort(ctx: *uic.UiCtx, h: nb.Holding) []const u8 {
    return switch (h) {
        .food, .biomass => "",
        .good => |gi| ctx.res.game.catalog.goods[gi].copy.short,
    };
}

/// `{n} offer(s) · {m} want(s)`: the market's standing total (`nb.Market.standing`).
pub fn standingLine(a: std.mem.Allocator, m: *const nb.Market) ![]const u8 {
    const s = m.standing();
    return a.print("{d} offer{s} \u{00b7} {d} want{s}", .{ s.offers, if (s.offers == 1) "" else "s", s.wants, if (s.wants == 1) "" else "s" });
}

fn hrule(parent: El, id: []const u8) !void {
    try parent.leaf(id, .{ .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = 1 } }, .{style.rule_fill});
}

/// A full-width list row with 15px side insets: `outer` is the interactive box (a `pct` width
/// sizes the border box, so the padding comes out of the list's width), `inner` the content
/// column.
fn listRow(parent: El, id: []const u8, index: ?usize, pad_y: f32) !struct { outer: El, inner: El } {
    const outer = if (index) |i| try parent.item(id, i) else try parent.div(id);
    outer.set(.{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .row, .cross = .start },
    }, .{style.pad_each(pad_y, pad_x, pad_y, pad_x)});
    const inner = try outer.box("inner", .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start }, .gap = 2 }, .{});
    return .{ .outer = outer, .inner = inner };
}

/// A padded full-width band (15px side insets inside its `pct` border box). Returns the inner row.
fn band(parent: El, id: []const u8, up: f32, down: f32) !El {
    const b = try parent.box(id, .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center },
    }, .{style.pad_each(up, pad_x, down, pad_x)});
    const inner = try b.box("inner", .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center }, .gap = 10 }, .{});
    return inner;
}

/// One run of inline text pieces: `(text, color)` in a row. A `fill` run takes its parent's
/// width and clips at its edge (a person's one-line sentence); otherwise it fits its text.
fn runFit(parent: El, id: []const u8, font: f32, fill: bool, pieces: []const struct { []const u8, uic.Color }) !void {
    const row = try parent.box(id, .{
        .w = if (fill) .{ .pct_of_parent = 1.0 } else .fit_children, .h = .fit_children,
        .flow = .{ .dir = .row, .cross = .center }, .overflow = .clip,
    }, .{});
    for (pieces, 0..) |p, i| {
        try (try row.item("p", i)).label("t", p[0], .{Style{ .font = font, .text = p[1] }});
    }
}

fn run(parent: El, id: []const u8, font: f32, pieces: []const struct { []const u8, uic.Color }) !void {
    return runFit(parent, id, font, true, pieces);
}

/// A `.seg` button's chrome: a line2 edge and fg label while pressed (published as
/// `selected`), the fg label alone on hover or visible focus, else a ground edge and dim label.
pub const seg_outline = Style{ .outline_ink = .bg, .on = &.{.{ .when = .selected, .outline_ink = .line2 }} };
pub const seg_label = Style{ .ink = .dim, .on = &.{ .{ .when = .selected, .ink = .fg }, .{ .when = .hover_focus, .ink = .fg } } };

/// A `.seg` button. Returns its click.
fn segButton(parent: El, id: []const u8, label: []const u8, pressed: bool) !bool {
    const b = try parent.box(id, .{ .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row } }, .{});
    const q = b.control(.{ .name = label, .role = .radio, .checked = pressed, .selected = pressed, .ring = false });
    b.set(.{}, .{seg_outline});
    try b.label("t", label, .{ Style{ .font = 11 }, seg_label, style.pad_sym(7, 3) });
    return q.clicked;
}

// ---- the query, the same grammar as BUILD ------------------------------------------------

fn agentMatches(ctx: *uic.UiCtx, a: nb.Agent, words: []const []const u8, spares: [nb.item_count]f32, query: []const u8) !bool {
    if (std.mem.trim(u8, query, " ").len == 0) return true;
    var it = std.mem.tokenizeScalar(u8, query, ' ');
    while (it.next()) |raw| {
        const token = try std.ascii.allocLowerString(ctx.arena, raw);
        const neg = token.len > 1 and token[0] == '-';
        const t = if (neg) token[1..] else token;
        const colon = std.mem.findScalar(u8, t, ':');
        const key = if (colon) |c| t[0..c] else "";
        const value = if (colon) |c| t[c + 1 ..] else t;
        const hit = blk: {
            if (std.mem.eql(u8, key, "needs")) {
                for (0..nb.item_count) |i| if (a.buys[i] > 0 and std.mem.startsWith(u8, words[i], value)) break :blk true;
                break :blk false;
            }
            if (std.mem.eql(u8, key, "has")) {
                for (0..nb.item_count) |i| if (a.sells[i] > 0 and std.mem.startsWith(u8, words[i], value)) break :blk true;
                break :blk false;
            }
            if (std.mem.eql(u8, key, "trade")) break :blk std.mem.startsWith(u8, @tagName(a.trade), value);
            if (std.mem.eql(u8, key, "is")) {
                if (std.mem.eql(u8, value, "match")) break :blk nb.wantsAny(a, spares);
                break :blk std.mem.startsWith(u8, @tagName(a.trade), value);
            }
            var hay: std.ArrayList(u8) = .empty;
            try hay.appendSlice(ctx.arena, try std.ascii.allocLowerString(ctx.arena, a.firstName()));
            try hay.append(ctx.arena, ' ');
            try hay.appendSlice(ctx.arena, try std.ascii.allocLowerString(ctx.arena, a.lastName()));
            try hay.append(ctx.arena, ' ');
            try hay.appendSlice(ctx.arena, @tagName(a.trade));
            for (0..nb.item_count) |i| if (a.sells[i] > 0) {
                try hay.append(ctx.arena, ' ');
                try hay.appendSlice(ctx.arena, words[i]);
            };
            break :blk std.mem.find(u8, hay.items, value) != null;
        };
        if (hit == neg) return false;
    }
    return true;
}

/// Whether an INVENTORY row matches the query: its kind (`resource` or `crafted`), whether it
/// is posted, or its word.
fn stallMatches(ctx: *uic.UiCtx, crafted: bool, name: []const u8, qty: u16, query: []const u8) !bool {
    if (std.mem.trim(u8, query, " ").len == 0) return true;
    const kind = if (crafted) "crafted" else "resource";
    var it = std.mem.tokenizeScalar(u8, query, ' ');
    while (it.next()) |raw| {
        const token = try std.ascii.allocLowerString(ctx.arena, raw);
        const neg = token.len > 1 and token[0] == '-';
        const t = if (neg) token[1..] else token;
        const colon = std.mem.findScalar(u8, t, ':');
        const key = if (colon) |c| t[0..c] else "";
        const value = if (colon) |c| t[c + 1 ..] else t;
        const hit = if (std.mem.eql(u8, key, "type") or std.mem.eql(u8, key, "kind"))
            std.mem.startsWith(u8, kind, value)
        else if (std.mem.eql(u8, key, "is"))
            (if (std.mem.eql(u8, value, "posted")) qty > 0 else if (std.mem.eql(u8, value, "idle")) qty == 0 else std.mem.startsWith(u8, kind, value))
        else
            std.mem.find(u8, name, value) != null;
        if (hit == neg) return false;
    }
    return true;
}

// ---- the list ---------------------------------------------------------------------------

fn sellSummary(ctx: *uic.UiCtx, a: nb.Agent, words: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..nb.item_count) |i| if (a.sells[i] > 0) {
        if (out.items.len > 0) try out.appendSlice(ctx.arena, ", ");
        try out.appendSlice(ctx.arena, try ctx.arena.print("{s} \u{00d7}{d}", .{ try book_mod.title(ctx.arena, words[i]), a.sells[i] }));
    };
    return out.items;
}

fn buyWords(ctx: *uic.UiCtx, a: nb.Agent, words: []const []const u8, with_qty: bool, sep: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..nb.item_count) |i| if (a.buys[i] > 0) {
        if (out.items.len > 0) try out.appendSlice(ctx.arena, sep);
        try out.appendSlice(ctx.arena, if (with_qty) try ctx.arena.print("{s} {d}", .{ words[i], a.buys[i] }) else words[i]);
    };
    return out.items;
}

/// The pinned You row: the player's live posts. Returns its click (it opens the stall).
fn youRow(parent: El, m: *const nb.Market, p: Player, words: []const []const u8) !bool {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const lr = try listRow(parent, "you", null, 8);
    const row = lr.inner;
    lr.outer.set(.{}, .{Style{ .fill_ink = .panel, .outline_ink = .line2 }});
    const q = lr.outer.control(.{ .name = "Your inventory", .role = .button, .ring = false });
    var offered: u32 = 0;
    var wanted: u32 = 0;
    var sells: std.ArrayList(u8) = .empty;
    var buys: std.ArrayList(u8) = .empty;
    // Act I's offers carry no price.
    if (p.own) |own| for (own) |o| {
        const qty = m.act_one.of(o.item);
        if (qty == 0) continue;
        offered += 1;
        if (sells.items.len > 0) try sells.appendSlice(ctx.arena, ", ");
        try sells.appendSlice(ctx.arena, try ctx.arena.print("{s} \u{00d7}{d}", .{ try book_mod.title(ctx.arena, try ownWord(ctx, o.item)), qty }));
    };
    for (0..nb.item_count) |i| {
        if (m.sell_posts[i].qty > 0) {
            offered += 1;
            if (sells.items.len > 0) try sells.appendSlice(ctx.arena, ", ");
            try sells.appendSlice(ctx.arena, try ctx.arena.print("{s} \u{00d7}{d} at {d}", .{ try book_mod.title(ctx.arena, words[i]), m.sell_posts[i].qty, m.sell_posts[i].price }));
        }
        if (m.buy_posts[i].qty > 0) {
            wanted += 1;
            if (buys.items.len > 0) try buys.appendSlice(ctx.arena, ", ");
            try buys.appendSlice(ctx.arena, try ctx.arena.print("{s} \u{00d7}{d} at {d}", .{ words[i], m.buy_posts[i].qty, m.buy_posts[i].price }));
        }
    }
    const top = try row.box("top", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center },
        .gap = 8,
    }, .{});
    const live = offered + wanted;
    try top.label("name", "You", .{Style{ .font = 13, .ink = .acc }});
    if (p.trade.len > 0) try top.label("trade", try std.ascii.allocUpperString(ctx.arena, p.trade), .{Style{ .font = 10, .tracking = 0.06, .ink = .dim }});
    const right = try top.box("right", .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .row, .main = .end } }, .{});
    const posts = if (live > 0) try ctx.arena.print("{d} OFFERED \u{00b7} {d} WANTED", .{ offered, wanted }) else "NOTHING POSTED";
    try right.label("posts", posts, .{Style{ .font = 10, .tracking = 0.06, .ink = .dim, .verdict = vd.when(live == 0, .attention) }});
    if (live > 0) {
        try run(row, "line", 11, &.{
            .{ "Offers ", th.dim },
            .{ if (sells.items.len > 0) sells.items else "nothing", th.fg },
            .{ ". Wants ", th.dim },
            .{ if (buys.items.len > 0) buys.items else "nothing", th.dim },
            .{ ".", th.dim },
        });
    } else {
        const text = if (m.n > 0) "Nothing posted. Neighbours cannot trade with you." else "Nothing posted.";
        try run(row, "line", 11, &.{.{ text, th.dim }});
    }
    return q.clicked;
}

/// A person or good row's chrome: the panel fill on hover or visible focus with a panel edge,
/// and while chosen (published as `selected`) the panel fill with a line2 edge.
pub const row_look = Style{ .fill_ink = .bg, .outline_ink = .bg, .on = &.{
    .{ .when = .hover_focus, .fill_ink = .panel, .outline_ink = .panel },
    .{ .when = .selected, .fill_ink = .panel, .outline_ink = .line2 },
} };
/// A good row's name: accent while chosen, else fg.
pub const good_name = Style{ .ink = .fg, .on = &.{.{ .when = .selected, .ink = .acc }} };
/// PROPOSE: fg at rest, accent while hot, `line`/`line2` while the offer cannot be proposed.
pub const propose_outline = Style{ .outline_ink = .fg, .on = &.{ .{ .when = .hot, .outline_ink = .acc }, .{ .when = .disabled, .outline_ink = .line } } };
pub const propose_label = Style{ .ink = .fg, .on = &.{ .{ .when = .hot, .ink = .acc }, .{ .when = .disabled, .ink = .line2 } } };
/// INVENTORY: accent edge and label on hover or visible focus and while the inventory is open
/// (published as `selected`), which also fills it with the panel; else a line2 edge, dim label.
pub const stall_outline = Style{ .outline_ink = .line2, .fill_ink = .bg, .on = &.{
    .{ .when = .hover_focus, .outline_ink = .acc },
    .{ .when = .selected, .outline_ink = .acc, .fill_ink = .panel },
} };
pub const stall_label = Style{ .ink = .dim, .on = &.{ .{ .when = .hover_focus, .ink = .acc }, .{ .when = .selected, .ink = .acc } } };
/// THE DEAL's `← BACK`: a line2 edge and dim label, both accent on hover or visible focus.
pub const back_outline = Style{ .outline_ink = .line2, .on = &.{.{ .when = .hover_focus, .outline_ink = .acc }} };
pub const back_label = Style{ .ink = .dim, .on = &.{.{ .when = .hover_focus, .ink = .acc }} };

fn personRow(parent: El, i: usize, a: nb.Agent, chosen: bool, spares: [nb.item_count]f32, words: []const []const u8) !bool {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const match = nb.wantsAny(a, spares);
    const lr = try listRow(parent, "person", i, 8);
    const row = lr.inner;
    const name = try ctx.arena.print("{s} {s}", .{ a.firstName(), a.lastName() });
    const q = lr.outer.control(.{ .name = name, .role = .button, .selected = chosen, .ring = false });
    lr.outer.set(.{}, .{row_look});
    const top = try row.box("top", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center },
        .gap = 8,
    }, .{});
    // fg, dim (`inactive`) for a person who wants nothing you hold, accent while chosen.
    try top.label("name", name, .{Style{ .font = 13, .ink = .fg, .verdict = vd.when(!match, .inactive), .on = &.{.{ .when = .selected, .ink = .acc }} }});
    try top.label("trade", try std.ascii.allocUpperString(ctx.arena, @tagName(a.trade)), .{Style{ .font = 10, .tracking = 0.06, .ink = .dim }});
    const right = try top.box("right", .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .row, .main = .end } }, .{});
    try right.label("match", if (match) "WANTS WHAT YOU HOLD" else "nothing you hold", .{Style{ .font = 10, .tracking = 0.06, .verdict = vd.of(match, .met, .absent) }});
    try run(row, "line", 11, &.{
        .{ "Offers ", th.dim },
        .{ try sellSummary(ctx, a, words), th.fg },
        .{ try ctx.arena.print(". Wants {s}.", .{try buyWords(ctx, a, words, false, ", ")}), th.dim },
    });
    return q.clicked;
}

/// The goods list's columns (`.good-row`): `11ch minmax(0, 1fr)`, gap 10. Every good row lays
/// out by one set, declared on the list.
const good_tracks = [_]uic.Track{
    .{ .basis = .{ .px = 11 * 8.6 } },
    .{ .basis = .{ .fr = 1 } },
};
const good_gap: f32 = 10;

fn goodRow(parent: El, tracks: *uic.TrackSet, m: *const nb.Market, i: usize, chosen: bool, p: Player, words: []const []const u8) !bool {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const a = ctx.arena;
    const lr = try listRow(parent, "good", i, 7);
    const row = lr.inner;
    row.set(.{ .flow = .{ .dir = .row, .cross = .start }, .in_tracks = tracks }, .{});
    const q = lr.outer.control(.{ .name = words[i], .role = .button, .selected = chosen, .ring = false });
    lr.outer.set(.{}, .{row_look});
    try row.label_fit("name", try std.ascii.allocUpperString(a, words[i]), .{ .cell_fill = .clip }, .{ Style{ .font = 13, .tracking = 0.04 }, good_name });
    const col = try row.box("col", .{ .flow = .{ .dir = .column, .cross = .start }, .gap = 2 }, .{});
    const off = m.offered(i);
    const want = m.wanted(i);
    const my_sell = m.sell_posts[i].qty;
    const my_buy = m.buy_posts[i].qty;
    try run(col, "stats", 11, &.{
        .{ try a.print("{}", .{off.units + my_sell}), th.fg },
        .{ try a.print(" offered \u{00b7} {d} selling", .{off.by + @intFromBool(my_sell > 0)}), th.dim },
        .{ "  \u{00b7}  ", th.line2 },
        .{ try a.print("{}", .{want.units + my_buy}), th.fg },
        .{ try a.print(" wanted \u{00b7} {d} buying", .{want.by + @intFromBool(my_buy > 0)}), th.dim },
    });
    const mine = p.spare(i);
    if (m.evidence(i)) |ev| {
        const range = if (ev.lo == ev.hi) try a.print("{}", .{ev.lo}) else try a.print("{}\u{2013}{}", .{ ev.lo, ev.hi });
        if (mine >= 1) {
            try run(col, "meta", 11, &.{ .{ range, th.fg }, .{ try a.print(" coin \u{00b7} last {d}", .{ev.last}), th.dim }, .{ "  \u{00b7}  ", th.line2 }, .{ try a.print("you spare {d:.0}", .{mine}), th.good } });
        } else {
            try run(col, "meta", 11, &.{ .{ range, th.fg }, .{ try a.print(" coin \u{00b7} last {d}", .{ev.last}), th.dim } });
        }
    } else if (mine >= 1) {
        try run(col, "meta", 11, &.{ .{ "not yet traded", th.line2 }, .{ "  \u{00b7}  ", th.line2 }, .{ try a.print("you spare {d:.0}", .{mine}), th.good } });
    } else {
        try run(col, "meta", 11, &.{.{ "not yet traded", th.line2 }});
    }
    return q.clicked;
}

/// An Act I good row: what the lone actor offers of it, with nobody else to offer or want it,
/// keyed by its holding. Returns its click.
fn ownGoodRow(parent: El, tracks: *uic.TrackSet, m: *const nb.Market, o: Own, chosen: bool) !bool {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const a = ctx.arena;
    const name = try ownWord(ctx, o.item);
    const lr = try listRow(parent, "own_good", o.item.key(), 7);
    const row = lr.inner;
    row.set(.{ .flow = .{ .dir = .row, .cross = .start }, .in_tracks = tracks }, .{});
    const q = lr.outer.control(.{ .name = name, .role = .button, .selected = chosen, .ring = false });
    lr.outer.set(.{}, .{row_look});
    try row.label_fit("name", try std.ascii.allocUpperString(a, name), .{ .cell_fill = .clip }, .{ Style{ .font = 13, .tracking = 0.04 }, good_name });
    const col = try row.box("col", .{ .flow = .{ .dir = .column, .cross = .start }, .gap = 2 }, .{});
    const mine = m.act_one.of(o.item);
    try run(col, "stats", 11, &.{
        .{ try a.print("{}", .{mine}), th.fg },
        .{ try a.print(" offered \u{00b7} {d} selling", .{@intFromBool(mine > 0)}), th.dim },
        .{ "  \u{00b7}  ", th.line2 },
        .{ "0", th.fg },
        .{ " wanted \u{00b7} 0 buying", th.dim },
    });
    if (o.spare >= 1) {
        try run(col, "meta", 11, &.{ .{ "not yet traded", th.line2 }, .{ "  \u{00b7}  ", th.line2 }, .{ try a.print("you spare {d:.0}", .{o.spare}), th.good } });
    } else {
        try run(col, "meta", 11, &.{.{ "not yet traded", th.line2 }});
    }
    return q.clicked;
}

/// The stall table's columns (`.stall-head`/`.stall-row`): `minmax(0, 1fr) 86px 86px 143px`,
/// gap 10. The head and every row lay out by one set, declared on the list.
const stall_tracks = [_]uic.Track{
    .{ .basis = .{ .fr = 1 } },
    .{ .basis = .{ .px = 86 } },
    .{ .basis = .{ .px = 86 } },
    .{ .basis = .{ .px = 143 } },
};
/// Act I's stall has no PRICE column (`.is-moneyless`): `minmax(0, 1fr) 86px 143px`.
const own_tracks = [_]uic.Track{
    .{ .basis = .{ .fr = 1 } },
    .{ .basis = .{ .px = 86 } },
    .{ .basis = .{ .px = 143 } },
};
const stall_gap: f32 = 10;

/// The stall's table head (`.stall-head`), with its PRICE column when `priced`.
fn stallHead(parent: El, tracks: *uic.TrackSet, selling: bool, priced: bool) !void {
    const lr = try listRow(parent, "stall_head", null, 0);
    lr.outer.set(.{}, .{style.pad_each(9, pad_x, 7, pad_x)});
    const row = lr.inner;
    row.set(.{ .flow = .{ .dir = .row, .cross = .center }, .in_tracks = tracks }, .{});
    const s = style.eyebrow_dim;
    const item = try row.div("item");
    try item.label("t", "ITEM", .{s});
    const qty = try row.box("qty", .{ .flow = .{ .dir = .row, .main = .center } }, .{});
    try qty.label("t", if (selling) "OFFERED" else "WANTED", .{s});
    if (priced) {
        const price = try row.box("price", .{ .flow = .{ .dir = .row, .main = .center } }, .{});
        try price.label("t", "PRICE", .{s});
    }
    const who = try row.box("who", .{ .flow = .{ .dir = .row, .main = .end } }, .{});
    try who.label("t", if (selling) "WHO WOULD BUY" else "WHO WOULD SELL", .{s});
}

fn stallRow(parent: El, tracks: *uic.TrackSet, m: *nb.Market, i: usize, selling: bool, p: Player, words: []const []const u8) !void {
    const ctx = parent.ctx;
    const a = ctx.arena;
    const post = if (selling) &m.sell_posts[i] else &m.buy_posts[i];
    if (post.price == 0) post.price = nb.base[i];
    const lr = try listRow(parent, "stall", i, 6);
    lr.outer.set(.{}, .{Style{ .fill_ink = if (post.qty > 0) .panel else .bg }});
    const row = lr.inner;
    row.set(.{ .flow = .{ .dir = .row, .cross = .center }, .in_tracks = tracks }, .{});
    const item = try row.box("item", .{ .flow = .{ .dir = .column, .cross = .start }, .gap = 1 }, .{});
    try item.label("name", try book_mod.title(a, words[i]), .{Style{ .font = 13, .ink = .acc, .verdict = vd.when(post.qty == 0, .inactive) }});
    const sub = if (selling) blk: {
        const short = shortEffect(ctx, i);
        const held = try a.print("{d:.0} spare of {d:.0} held", .{ p.spare(i), p.held[i] });
        break :blk if (short.len > 0) try a.print("{s} \u{00b7} {s}", .{ held, short }) else held;
    } else blk: {
        const off = m.offered(i);
        break :blk try a.print("{d} offered by {d}", .{ off.units, off.by });
    };
    // `.stall-sub` ellipsizes: the line takes the item cell's width and never widens it.
    (try item.text_fit("sub", sub, .{ .cell_fill = .ellipsis })).set(.{ .w = .{ .pct_of_parent = 1.0 }, .h = .content }, .{style.caption_faint});
    const cap: u32 = if (selling) @intFromFloat(@floor(p.spare(i))) else 99;
    const qty_cell = try row.box("qty", .{ .flow = .{ .dir = .row, .main = .center } }, .{});
    post.qty = @intCast(try stepper_mod.quantity_stepper(qty_cell, "stepper", post.qty, 0, cap, .{ .less = "Fewer", .more = "More" }));
    const price_cell = try row.box("price", .{ .flow = .{ .dir = .row, .main = .center } }, .{});
    post.price = @intCast(try stepper_mod.quantity_stepper(price_cell, "stepper", post.price, 1, 99, .{ .less = "Lower price", .more = "Raise price" }));
    const takers = if (selling) m.buyersFor(i, post.price) else m.sellersFor(i, post.price);
    const who = try row.box("who", .{ .flow = .{ .dir = .row, .main = .end } }, .{});
    const text = if (post.qty == 0) "not posted" else try a.print("{d} {s}", .{ takers, if (selling) "would buy" else "would sell" });
    try who.label("t", text, .{Style{ .font = 10, .verdict = vd.of(post.qty > 0 and takers > 0, .met, .absent) }});
}

/// An Act I INVENTORY row, keyed by its holding: what is held and spare, and the quantity
/// offered, which steps up to the spare. Returns the quantity a step asks for, if one did.
fn ownStallRow(parent: El, tracks: *uic.TrackSet, m: *const nb.Market, o: Own) !?u16 {
    const ctx = parent.ctx;
    const a = ctx.arena;
    const posted = m.act_one.of(o.item);
    const name = try ownWord(ctx, o.item);
    const lr = try listRow(parent, "own", o.item.key(), 6);
    lr.outer.set(.{}, .{Style{ .fill_ink = if (posted > 0) .panel else .bg }});
    const row = lr.inner;
    row.set(.{ .flow = .{ .dir = .row, .cross = .center }, .in_tracks = tracks }, .{});
    const item = try row.box("item", .{ .flow = .{ .dir = .column, .cross = .start }, .gap = 1 }, .{});
    try item.label("name", try book_mod.title(a, name), .{Style{ .font = 13, .ink = .acc, .verdict = vd.when(posted == 0, .inactive) }});
    const short = ownShort(ctx, o.item);
    const held = try a.print("{s} spare of {s} held", .{ try book_mod.fmtNum(a, o.spare), try book_mod.fmtNum(a, o.held) });
    const sub = if (short.len > 0) try a.print("{s} \u{00b7} {s}", .{ held, short }) else held;
    (try item.text_fit("sub", sub, .{ .cell_fill = .ellipsis })).set(.{ .w = .{ .pct_of_parent = 1.0 }, .h = .content }, .{style.caption_faint});
    const cap: u32 = @intFromFloat(@floor(@max(0, o.spare)));
    const qty_cell = try row.box("qty", .{ .flow = .{ .dir = .row, .main = .center } }, .{});
    const names = stepper_mod.Names{ .less = try a.print("Fewer {s}", .{name}), .more = try a.print("More {s}", .{name}) };
    const stepped: u16 = @intCast(try stepper_mod.quantity_stepper(qty_cell, "stepper", posted, 0, cap, names));
    // Nobody else exists to buy.
    const who = try row.box("who", .{ .flow = .{ .dir = .row, .main = .end } }, .{});
    try who.label("t", if (posted == 0) "not posted" else "0 would buy", .{Style{ .font = 10, .verdict = .absent }});
    return if (stepped != posted) stepped else null;
}

// ---- the slip -----------------------------------------------------------------------------

fn slipHeading(parent: El, text: []const u8) !void {
    try parent.label("heading", text, .{ style.eyebrow, style.muted });
}

/// THE DEAL's heading line (`.slip-head`): the heading, and `← BACK` on its right. `name` is
/// the button's accessible name. Returns the button's click.
fn dealHeading(parent: El, name: []const u8) !bool {
    const row = try parent.box("head", .{
        .w = .{ .fixed = slip_inner }, .h = .fit_children,
        .flow = .{ .dir = .row, .main = .space_between, .cross = .center }, .gap = 8,
    }, .{});
    try row.label("heading", "THE DEAL", .{ style.eyebrow, style.muted });
    const b = try row.box("back", .{ .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row } }, .{});
    const q = b.control(.{ .name = name, .role = .button, .ring = false });
    b.set(.{}, .{back_outline});
    try b.label("t", "\u{2190} BACK", .{ Style{ .font = 10, .tracking = 0.07 }, back_label, style.pad_sym(6, 1) });
    return q.clicked;
}

fn placeholder(parent: El, id: []const u8, text: []const u8) !void {
    try parent.label_fit(id, text, .fill, .{style.note});
}

fn sideHead(parent: El, left: []const u8, right: []const u8) !void {
    const row = try parent.box("side_head", .{
        .w = .{ .fixed = slip_inner }, .h = .fit_children, .flow = .{ .dir = .row, .main = .space_between },
    }, .{});
    try row.label("l", left, .{style.eyebrow_dim});
    try row.label("r", right, .{style.caption_faint});
}

/// A `.line`: a name, then a value or a stepper. Returns the name's click.
fn line(parent: El, i: usize, name: []const u8, value: []const u8, clickable: bool) !bool {
    const row = try parent.boxi("line", i, .{
        .w = .{ .fixed = slip_inner }, .h = .fit_children,
        .flow = .{ .dir = .row, .main = .space_between, .cross = .center }, .gap = 6,
    }, .{});
    var clicked = false;
    const n = try row.div("name");
    if (clickable) {
        const q = n.control(.{ .name = name, .role = .button, .ring = false });
        clicked = q.clicked;
        try n.label("t", name, .{Style{ .font = 12, .ink = .fg, .on = &.{.{ .when = .hover_focus, .ink = .acc }} }});
    } else {
        try n.label("t", name, .{Style{ .font = 12, .ink = .fg }});
    }
    try row.label("v", value, .{Style{ .font = 12, .ink = .fg }});
    return clicked;
}

fn goodSlip(slip: El, m: *const nb.Market, i: usize, st: *MarketState, p: Player, words: []const []const u8) !void {
    const ctx = slip.ctx;
    const a = ctx.arena;
    try slipHeading(slip, try std.ascii.allocUpperString(a, words[i]));
    // The four cheapest selling and the four paying most; a name opens a deal with them.
    var sellers: std.ArrayList(usize) = .empty;
    var buyers: std.ArrayList(usize) = .empty;
    for (m.people(), 0..) |n, k| {
        if (n.sells[i] > 0) try sellers.append(a, k);
        if (n.buys[i] > 0) try buyers.append(a, k);
    }
    const people = m.people();
    sortBy(sellers.items, people, i, true);
    sortBy(buyers.items, people, i, false);
    inline for (.{ .{ "sell", "CHEAPEST SELLING", true }, .{ "buy", "PAYING MOST", false } }) |side| {
        const list = if (side[2]) sellers.items else buyers.items;
        const box = try slip.box(side[0], .{
            .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
            .gap = 4,
        }, .{});
        try sideHead(box, side[1], try a.print("{}", .{list.len}));
        if (list.len == 0) try placeholder(box, "none", if (side[2]) "Nobody is selling." else "Nobody is buying.");
        for (list[0..@min(4, list.len)], 0..) |k, j| {
            const n = people[k];
            const name = if (side[2])
                try a.print("{s} {s} \u{00d7}{d}", .{ n.firstName(), n.lastName(), n.sells[i] })
            else
                try a.print("{s} {s} wants {d}", .{ n.firstName(), n.lastName(), n.buys[i] });
            const price = try a.print("{d} coin", .{if (side[2]) n.ask[i] else n.bid[i]});
            if (try line(box, j, name, price, true)) pickAgent(st, m, k, p, @intCast(i));
        }
    }
    try placeholder(slip, "hint", "Pick a name to open a deal.");
}

/// An Act I good's detail: nobody sells it or buys it yet.
fn ownGoodSlip(slip: El, h: nb.Holding) !void {
    const ctx = slip.ctx;
    try slipHeading(slip, try std.ascii.allocUpperString(ctx.arena, try ownWord(ctx, h)));
    inline for (.{ .{ "sell", "CHEAPEST SELLING", "Nobody is selling." }, .{ "buy", "PAYING MOST", "Nobody is buying." } }) |side| {
        const box = try slip.box(side[0], .{
            .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
            .gap = 4,
        }, .{});
        try sideHead(box, side[1], "0");
        try placeholder(box, "none", side[2]);
    }
    try placeholder(slip, "hint", "Pick a name to open a deal.");
}

fn sortBy(list: []usize, people: []const nb.Agent, item: usize, ascending_ask: bool) void {
    const Ctx = struct { ps: []const nb.Agent, item: usize, asc: bool };
    std.mem.sort(usize, list, Ctx{ .ps = people, .item = item, .asc = ascending_ask }, struct {
        fn lt(c: Ctx, x: usize, y: usize) bool {
            return if (c.asc) c.ps[x].ask[c.item] < c.ps[y].ask[c.item] else c.ps[x].bid[c.item] > c.ps[y].bid[c.item];
        }
    }.lt);
}

/// Open a deal with neighbour `k`: what it wants that the player has spare, against its first
/// good, the way the prototype seeds the slip. `from` is the good whose detail named it, where
/// the deal's back button returns.
fn pickAgent(st: *MarketState, m: *const nb.Market, k: usize, p: Player, from: ?u8) void {
    st.pick_kind = 1;
    st.pick = @intCast(k);
    st.from = from;
    st.give = @splat(0);
    st.take = @splat(0);
    const a = m.agents[k];
    for (0..nb.item_count) |i| if (a.buys[i] > 0 and p.spare(i) >= 1) {
        st.give[i] = @intCast(@min(@as(u32, @intFromFloat(@floor(p.spare(i)))), a.buys[i]));
        break;
    };
    for (0..nb.item_count) |i| if (a.sells[i] > 0) {
        st.take[i] = @min(a.sells[i], 4);
        break;
    };
}

/// Back out of the deal: to the good's detail it was opened from, or to nothing picked.
fn closeDeal(st: *MarketState) void {
    if (st.from) |g| {
        st.pick_kind = 2;
        st.pick = g;
    } else st.pick_kind = 0;
    st.from = null;
    st.give = @splat(0);
    st.take = @splat(0);
}

fn agentSlip(slip: El, m: *const nb.Market, k: usize, st: *MarketState, p: Player, words: []const []const u8) !?Settled {
    const ctx = slip.ctx;
    const th = ctx.res.view.theme;
    const a = ctx.arena;
    const agent = m.agents[k];
    const back_name = if (st.from) |g| try a.print("Back to {s}", .{words[g]}) else "Close the deal";
    if (try dealHeading(slip, back_name)) closeDeal(st);
    const who = try slip.div("who");
    // Full slip width, so the wrapped line below fills it (a fitted column would not wrap it).
    who.set(.{ .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start }, .gap = 3 }, .{});
    try who.label("name", try a.print("{s} {s}", .{ agent.firstName(), agent.lastName() }), .{Style{ .font = 14, .ink = .fg }});
    try who.label_fit("small", try a.print("{s} \u{00b7} wants {s}", .{ @tagName(agent.trade), try buyWords(ctx, agent, words, true, ", ") }), .fill, .{style.caption});

    // YOU GIVE (spare only): what it buys that the player has spare, and coin.
    inline for (.{ .{ "give", "YOU GIVE", "spare only" }, .{ "take", "YOU RECEIVE", "theirs" } }) |side| {
        const giving = comptime std.mem.eql(u8, side[0], "give");
        const box = try slip.box(side[0], .{
            .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
            .gap = 4,
        }, .{});
        try sideHead(box, side[1], side[2]);
        var any = false;
        for (0..nb.bundle_len) |i| {
            const is_coin = i == nb.coin;
            const cap: u32 = if (giving)
                (if (is_coin) @intFromFloat(@floor(p.coin)) else if (agent.buys[i] > 0) @intFromFloat(@floor(p.spare(i))) else 0)
            else
                (if (is_coin) agent.coin else agent.sells[i]);
            if (cap == 0) continue;
            any = true;
            const bundle = if (giving) &st.give else &st.take;
            const row = try box.boxi("line", i, .{
                .w = .{ .fixed = slip_inner }, .h = .fit_children,
                .flow = .{ .dir = .row, .main = .space_between, .cross = .center }, .gap = 6,
            }, .{});
            const name = if (is_coin) "Coin" else try book_mod.title(a, words[i]);
            try row.label("n", name, .{Style{ .font = 12, .ink = .fg, .verdict = vd.when(bundle[i] == 0, .absent) }});
            bundle[i] = @intCast(try stepper_mod.quantity_stepper(row, "stepper", bundle[i], 0, cap, .{ .less = "Less", .more = "More" }));
        }
        if (!any) try placeholder(box, "none", if (giving) "Nothing spare they want." else "Nothing to receive.");
    }

    // The verdict, in the neighbour's own valuation.
    const v = nb.verdict(agent, st.give, st.take, p.spares());
    const first = agent.firstName();
    const text: []const u8, const color: uic.Color, const line_color: uic.Color = switch (v) {
        .idle => .{ "Put something on both sides.", th.dim, th.line },
        .refuse => .{ try a.print("{s} wants {s} \u{2014} nothing you have spare. Coin would still work.", .{ first, try buyWords(ctx, agent, words, false, " or ") }), th.danger, th.danger },
        .accept => .{ try a.print("{s} would take this.", .{first}), th.good, th.good },
        .counter => |c| .{ try a.print("{s} would want about {d} more {s}.", .{ first, c.more, words[c.item] }), th.warn, th.warn },
    };
    const box = try slip.box("verdict", .{
        .w = .{ .fixed = slip_inner - 16 }, .h = .fit_children,
    }, .{ Style{ .outline_color = line_color }, style.pad_sym(8, 7) });
    try box.label_fit("t", text, .fill, .{Style{ .font = 11, .text = color }});

    // AFTER: before → after on what the deal touches.
    var rows = false;
    for (0..nb.bundle_len) |i| rows = rows or st.give[i] > 0 or st.take[i] > 0;
    if (rows) {
        const after = try slip.box("after", .{
            .w = .{ .fixed = slip_inner }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
            .gap = 3,
        }, .{});
        try after.leaf("rule", .{ .w = .{ .fixed = slip_inner }, .h = .{ .fixed = 1 } }, .{style.rule_fill});
        try after.label("head", "AFTER", .{style.eyebrow_dim});
        for (0..nb.bundle_len) |i| {
            if (st.give[i] == 0 and st.take[i] == 0) continue;
            const before: f32 = if (i == nb.coin) p.coin else p.held[i];
            const value = before - @as(f32, @floatFromInt(st.give[i])) + @as(f32, @floatFromInt(st.take[i]));
            const r = try after.boxi("row", i, .{
                .w = .{ .fixed = slip_inner }, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center },
                .gap = 5,
            }, .{});
            const key = try r.box("key", .{ .w = .grow, .h = .fit_children }, .{});
            try key.label("k", try std.ascii.allocUpperString(a, if (i == nb.coin) "coin" else words[i]), .{Style{ .font = 12, .tracking = 0.04, .ink = .dim }});
            try r.label("from", try book_mod.fmtNum(a, before), .{Style{ .font = 12, .ink = .line2 }});
            try r.label("arrow", "\u{2192}", .{Style{ .font = 12, .ink = .line2 }});
            try r.label("to", try book_mod.fmtNum(a, value), .{Style{ .font = 12, .verdict = vd.trade(value, before) }});
        }
    }

    try slip.leaf("push", .{ .w = .{ .fixed = 1 }, .h = .grow }, .{});
    const accept = v == .accept;
    const b = try slip.box("propose", .{
        .w = .{ .fixed = slip_inner }, .h = .fit_children, .flow = .{ .dir = .row, .main = .center },
    }, .{});
    const q = b.control(.{ .enabled = accept, .name = "Propose", .role = .button, .ring = false });
    b.set(.{}, .{propose_outline});
    try b.label("t", "PROPOSE \u{2192}", .{ style.body, propose_label, style.pad_sym(8, 7) });
    if (accept and q.clicked) {
        const deal = Settled{ .neighbour = @intCast(k), .give = st.give, .take = st.take };
        st.give = @splat(0);
        st.take = @splat(0);
        return deal;
    }
    return null;
}

fn stallSlip(slip: El, m: *const nb.Market, p: Player, words: []const []const u8) !void {
    const ctx = slip.ctx;
    const a = ctx.arena;
    try slipHeading(slip, "INVENTORY");
    var sell_items: u32 = 0;
    var sell_units: u32 = 0;
    var buy_items: u32 = 0;
    var committed: u32 = 0;
    for (0..nb.item_count) |i| {
        if (m.sell_posts[i].qty > 0) {
            sell_items += 1;
            sell_units += m.sell_posts[i].qty;
        }
        if (m.buy_posts[i].qty > 0) {
            buy_items += 1;
            committed += @as(u32, m.buy_posts[i].qty) * m.buy_posts[i].price;
        }
    }
    // Act I's offers: no price, so no coin.
    const moneyless = p.own != null;
    if (moneyless) {
        sell_items += m.act_one.count();
        sell_units += m.act_one.units();
    }
    const over = !moneyless and @as(f32, @floatFromInt(committed)) > p.coin;
    const who = try slip.box("who", .{ .flow = .{ .dir = .column, .cross = .start }, .gap = 3 }, .{});
    try who.label("n", try a.print("{d} offered \u{00b7} {d} wanted", .{ sell_items, buy_items }), .{Style{ .font = 14, .ink = .fg }});
    try who.label("s", if (m.n > 0) "neighbours trade against these prices" else "no neighbours yet", .{style.caption});
    const tally = try slip.box("tally", .{ .flow = .{ .dir = .column, .cross = .start }, .gap = 3 }, .{});
    inline for (.{ .{ "sell", "OFFERED", false }, .{ "buy", "WANTED", true } }) |r| {
        const row = try tally.box(r[0], .{
            .w = .{ .fixed = slip_inner }, .h = .fit_children,
            .flow = .{ .dir = .row, .main = .space_between },
        }, .{});
        try row.label("l", r[1], .{style.note});
        const value = if (r[2] and moneyless)
            try a.print("{d} items", .{buy_items})
        else if (r[2])
            try a.print("{d} items \u{00b7} {d} of {d:.0} coin", .{ buy_items, committed, p.coin })
        else
            try a.print("{d} items \u{00b7} {d} units", .{ sell_items, sell_units });
        try row.label("v", value, .{Style{ .font = 11, .ink = .fg, .verdict = vd.when(r[2] and over, .over) }});
    }
    if (over) {
        try slip.label_fit("warn", try a.print("Your wants commit {d} coin and you hold {d:.0}. The shortfall will not fill.", .{ committed, p.coin }), .fill, .{Style{ .font = 10, .ink = .danger }});
    }
    inline for (.{ .{ "posted_sell", "OFFERED", true }, .{ "posted_buy", "WANTED", false } }) |side| {
        const posts = if (side[2]) &m.sell_posts else &m.buy_posts;
        const box = try slip.box(side[0], .{
            .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
            .gap = 4,
        }, .{});
        const count: u32 = if (side[2]) sell_items else buy_items;
        try sideHead(box, side[1], try a.print("{}", .{count}));
        if (count == 0) try placeholder(box, "none", if (side[2]) "Nothing offered." else "Nothing wanted.");
        for (posts, 0..) |post, i| {
            if (post.qty == 0) continue;
            _ = try line(box, i, try a.print("{s} \u{00d7}{d}", .{ try book_mod.title(a, words[i]), post.qty }), try a.print("{d} coin", .{post.price}), false);
        }
        // Act I's offered lines, keyed by holding, with no price.
        if (side[2]) if (p.own) |own| for (own) |o| {
            const qty = m.act_one.of(o.item);
            if (qty == 0) continue;
            _ = try line(box, o.item.key(), try a.print("{s} \u{00d7}{d}", .{ try book_mod.title(a, try ownWord(ctx, o.item)), qty }), "", false);
        };
    }
}

// ---- the view -----------------------------------------------------------------------------

/// Build the MARKET view filling `parent` (whose height must be definite). `query` and
/// `stall_query` are the two search editors' owners (kept on always-built nodes).
pub fn market_view(parent: El, id: []const u8, m: *nb.Market, st: *MarketState, p: Player, query_owner: El, stall_owner: El) !Result {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const a = ctx.arena;
    var result: Result = .{};

    var words: [nb.item_count][]const u8 = undefined;
    for (&words, 0..) |*w, i| w.* = try word(ctx, i);
    const spares = p.spares();

    const view = try parent.box(id, .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .{ .pct_of_parent = 1.0 },
        .flow = .{ .dir = .column, .cross = .start },
    }, .{});

    // --- head: the tab's own, whichever view is open ----------------------------------------
    const head = try band(view, "head", 11, 9);
    head.set(.{ .flow = .{ .dir = .row, .main = .space_between, .cross = .start }, .gap = 12 }, .{});
    const title = try head.box("title", .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start }, .gap = 2 }, .{});
    try title.label("h", "MARKET", .{ style.heading, style.ink(.fg) });
    try title.label("line", "Neighbours, what they offer and what they want.", .{Style{ .font = 11, .ink = .dim }});
    // `.market-sub` shares the heading's baseline: a 10px line set down to the 21px one.
    try head.label("sub", try standingLine(a, m), .{ Style{ .font = 10, .tracking = 0.07, .ink = .dim }, style.pad_each(8, 0, 0, 0) });
    try hrule(view, "head_rule");

    // --- controls: INVENTORY, apart; then search and the segment, a group ------------------
    const controls = try band(view, "controls", 9, 9);
    // `.stall-open { margin-right: 14px }`: 24px to the search field against the row's 10.
    const stall_slot = try controls.box("stall_slot", .{ .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row } }, .{style.pad_each(0, 14, 0, 0)});
    const stall_button = try stall_slot.box("stall", .{ .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row } }, .{});
    const sq = stall_button.control(.{ .name = "Inventory", .role = .button, .selected = st.stall, .ring = false });
    stall_button.set(.{}, .{stall_outline});
    try stall_button.label("t", "INVENTORY", .{ Style{ .font = 10, .tracking = 0.07 }, stall_label, style.pad_sym(8, 3) });
    var toggle_stall = sq.clicked;
    const owner = if (st.stall) stall_owner else query_owner;
    // Act I names no trades, so its search offers none.
    const hint = if (st.stall)
        "search items  \u{00b7}  type:crafted  is:posted"
    else if (p.own != null)
        "search  \u{00b7}  needs:materials  has:food"
    else
        "search  \u{00b7}  needs:materials  has:food  trade:fisher";
    const field = try uic.text_input_look(controls, if (st.stall) "stall_search" else "search", hint, 80, owner, .{ .font = 11, .placeholder = th.line2 });
    field.set(.{ .w = .grow, .h = .fit_children }, .{});
    const query = owner.state(uic.UiState.TextInputState).text();
    const seg = try controls.box("seg", .{ .flow = .{ .dir = .row, .cross = .center }, .gap = 2 }, .{});
    const mode = activeGroup(st, m.n);
    if (st.stall) {
        try seg.label("label", "SIDE", .{ style.eyebrow_dim, style.pad_each(0, 4, 0, 0) });
        if (try segButton(seg, "selling", "OFFERS", st.side == 0)) {
            st.side = 0;
            st.page = 0;
        }
        if (try segButton(seg, "buying", "WANTS", st.side == 1)) {
            st.side = 1;
            st.page = 0;
        }
    } else {
        try seg.label("label", "BY", .{ style.eyebrow_dim, style.pad_each(0, 4, 0, 0) });
        if (try segButton(seg, "person", "PERSON", mode == .person)) {
            st.group = 1;
            st.page = 0;
        }
        if (try segButton(seg, "good", "GOOD", mode == .good)) {
            st.group = 2;
            st.page = 0;
        }
    }
    try hrule(view, "controls_rule");

    // --- body: the list | the slip -----------------------------------------------------------
    const body = try view.box("body", .{ .w = .{ .pct_of_parent = 1.0 }, .h = .grow, .flow = .{ .dir = .row, .cross = .start } }, .{});
    const list = try body.box("list", .{
        .w = .grow, .h = .{ .pct_of_parent = 1.0 }, .flow = .{ .dir = .column, .cross = .start },
    }, .{style.pad_each(3, 0, 8, 0)});
    try body.leaf("divider", .{ .w = .{ .fixed = 1 }, .h = .{ .pct_of_parent = 1.0 } }, .{style.rule_fill});
    // The slip's 10/15/13 insets are padding inside border-box extents (the box's percentage
    // height, the row's percentage width), so its foot (PROPOSE) stays inside the body.
    const slip_box = try body.box("slip_box", .{
        .w = .{ .fixed = slip_w }, .h = .{ .pct_of_parent = 1.0 }, .flow = .{ .dir = .column },
    }, .{style.pad_each(10, 0, 13, 0)});
    const slip_row = try slip_box.box("row", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .grow, .flow = .{ .dir = .row },
    }, .{style.pad_each(0, 0, 0, pad_x)});
    const slip = try slip_row.box("slip", .{
        .w = .{ .fixed = slip_inner }, .h = .{ .pct_of_parent = 1.0 },
        .flow = .{ .dir = .column, .cross = .start }, .gap = 10,
    }, .{});

    // The rows the active list holds, before paging.
    var total: usize = 0;
    var visible_people: usize = 0;
    var idle_people: usize = 0;
    // The rows the active list holds: in Act I's INVENTORY and goods, positions in `p.own`.
    var rows: std.ArrayList(usize) = .empty;
    if (p.own) |own| {
        // What the lone actor holds or offers; nobody offers anything for it to want.
        for (own, 0..) |o, k| {
            const posted = m.act_one.of(o.item);
            const in_pool = if (st.stall)
                st.side == 0 and (o.held > 0 or posted > 0) and try stallMatches(ctx, o.item == .good, try ownWord(ctx, o.item), posted, query)
            else
                mode == .good and posted > 0;
            if (in_pool) try rows.append(a, k);
        }
    } else if (st.stall) {
        const selling = st.side == 0;
        for (0..nb.item_count) |i| {
            const post = if (selling) m.sell_posts[i] else m.buy_posts[i];
            const in_pool = if (selling) p.held[i] >= 1 or post.qty > 0 else m.offered(i).by > 0 or post.qty > 0;
            if (in_pool and try stallMatches(ctx, i >= nb.first_crafted, words[i], post.qty, query)) try rows.append(a, i);
        }
    } else {
        for (m.people(), 0..) |agent, k| {
            if (!try agentMatches(ctx, agent, &words, spares, query)) continue;
            visible_people += 1;
            if (!nb.wantsAny(agent, spares)) idle_people += 1;
            if (mode == .person) try rows.append(a, k);
        }
        if (mode == .good) {
            for (0..nb.item_count) |i| {
                const off = m.offered(i);
                const want = m.wanted(i);
                if (off.units + want.units + m.sell_posts[i].qty + m.buy_posts[i].qty > 0) try rows.append(a, i);
            }
        }
    }
    total = rows.items.len;
    const n_pages = paginator_mod.pages(total, per_page);
    if (st.page >= n_pages) st.page = @intCast(n_pages - 1);
    const start = @as(usize, st.page) * per_page;
    const slice = rows.items[start..@min(total, start + per_page)];

    // A deal with a neighbour the book no longer has closes.
    if (st.pick_kind == 1 and st.pick >= m.n) closeDeal(st);
    if (st.stall) {
        if (slice.len == 0) {
            const empty = if (m.n == 0 and st.side == 1 and std.mem.trim(u8, query, " ").len == 0) "Nobody is offering anything yet." else "Nothing matches that search.";
            try list.label("empty", empty, .{ style.note, style.pad_sym(pad_x, 16) });
        } else if (p.own) |own| {
            const tracks = try uic.tracks(ctx, &own_tracks, stall_gap);
            list.set(.{ .tracks = tracks }, .{});
            try stallHead(list, tracks, true, false);
            for (slice) |k| if (try ownStallRow(list, tracks, m, own[k])) |qty| {
                result.offer = .{ .item = own[k].item, .qty = qty };
            };
        } else {
            // One column set for the head and every row (`grid-template-columns` on both).
            const tracks = try uic.tracks(ctx, &stall_tracks, stall_gap);
            list.set(.{ .tracks = tracks }, .{});
            try stallHead(list, tracks, st.side == 0, true);
            for (slice) |i| try stallRow(list, tracks, m, i, st.side == 0, p, &words);
        }
        try stallSlip(slip, m, p, &words);
    } else {
        if (total == 0) {
            // Nobody to list: your own row and why; a search that matched nobody, only that.
            if (m.n == 0) {
                if (mode == .person and try youRow(list, m, p, &words)) toggle_stall = true;
                try list.label("empty", "No neighbours yet.", .{ style.note, style.pad_sym(pad_x, 16) });
            } else try list.label("empty", "Nothing matches that search.", .{ style.note, style.pad_sym(pad_x, 16) });
        } else if (mode == .person) {
            if (try youRow(list, m, p, &words)) toggle_stall = true;
            for (slice) |k| {
                if (try personRow(list, k, m.agents[k], st.pick_kind == 1 and st.pick == k, spares, &words)) {
                    if (st.pick_kind == 1 and st.pick == k) closeDeal(st) else pickAgent(st, m, k, p, null);
                }
            }
        } else if (p.own) |own| {
            // Act I's goods: what the lone actor offers, picked by holding.
            const tracks = try uic.tracks(ctx, &good_tracks, good_gap);
            list.set(.{ .tracks = tracks }, .{});
            for (slice) |k| {
                const key: u8 = @intCast(own[k].item.key());
                const chosen = st.pick_kind == 2 and st.pick == key;
                if (try ownGoodRow(list, tracks, m, own[k], chosen)) {
                    st.pick_kind = if (chosen) 0 else 2;
                    st.pick = key;
                }
            }
        } else {
            // One column set for every good row (`grid-template-columns` on `.good-row`).
            const tracks = try uic.tracks(ctx, &good_tracks, good_gap);
            list.set(.{ .tracks = tracks }, .{});
            for (slice) |i| {
                // A good stays chosen while the deal its detail opened is on the slip.
                const chosen = (st.pick_kind == 2 and st.pick == i) or (st.pick_kind == 1 and st.from == @as(u8, @intCast(i)));
                if (try goodRow(list, tracks, m, i, chosen, p, &words)) {
                    st.pick_kind = if (chosen) 0 else 2;
                    st.pick = @intCast(i);
                    st.from = null;
                    st.give = @splat(0);
                    st.take = @splat(0);
                }
            }
        }
        switch (st.pick_kind) {
            1 => result.settled = try agentSlip(slip, m, st.pick, st, p, &words),
            2 => if (p.own != null) try ownGoodSlip(slip, nb.Holding.ofKey(st.pick)) else try goodSlip(slip, m, st.pick, st, p, &words),
            else => {
                try slipHeading(slip, "THE DEAL");
                try placeholder(slip, "placeholder", if (m.n > 0) "Pick a neighbour, or a good, on the left." else "No deal open.");
            },
        }
    }

    // --- foot: friction and pages ------------------------------------------------------------
    try hrule(view, "foot_rule");
    const foot = try band(view, "foot", 8, 8);
    foot.set(.{ .flow = .{ .dir = .row, .main = .space_between, .cross = .center } }, .{});
    if (st.stall) {
        var offered: u32 = 0;
        var wanted: u32 = 0;
        for (m.sell_posts, m.buy_posts) |s, b| {
            offered += @intFromBool(s.qty > 0);
            wanted += @intFromBool(b.qty > 0);
        }
        if (p.own != null) offered += m.act_one.count();
        try runFit(foot, "friction", 11, false, &.{
            .{ try a.print("{}", .{offered}), th.warn },
            .{ " offered \u{00b7} ", th.dim },
            .{ try a.print("{}", .{wanted}), th.warn },
            .{ if (m.n > 0) " wanted \u{00b7} neighbours trade against them while you work." else " wanted \u{00b7} no neighbours yet.", th.dim },
        });
    } else if (m.n == 0) {
        try runFit(foot, "friction", 11, false, &.{.{ "A passerby trades from the strip.", th.dim }});
    } else {
        const severe = visible_people > 0 and idle_people * 10 >= visible_people * 6;
        try runFit(foot, "friction", 11, false, &.{ .{ try a.print("{d} of {d}", .{ idle_people, visible_people }), if (severe) th.danger else th.warn }, .{ " neighbours want nothing you hold spare.", th.dim } });
    }
    st.page = @intCast(try paginator_mod.paginator(foot, "pages", st.page, total, per_page));

    if (toggle_stall) {
        st.stall = !st.stall;
        st.page = 0;
    }
    return result;
}
