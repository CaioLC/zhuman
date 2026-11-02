//! `market_view` — Act II's MARKET tab, the neighbours (`market.html`). A view, not a dialog,
//! and its primitive is a person, not a good. With few neighbours the list reads as people in
//! sentences; with many it collapses to goods in notation, each with a price range drawn only
//! from trades that happened. A deal composes both sides on the deal slip and is judged in the
//! counterparty's own valuation. YOUR STALL posts sells and buys at the player's own prices,
//! and each post says how many would take it.
//!
//! The neighbours are `ha.sim.rules.neighbours` (a stub until the population and market model exist);
//! the player's holdings arrive as numbers. The view edits the player's posts on the neighbour
//! book and reports a proposed deal the neighbour accepts, which the page writes as a
//! `NeighbourDeal` intent; the handler settles both sides.

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

/// The player's side, as numbers by item (`nb.items`), plus coin.
pub const Player = struct {
    trade: []const u8,
    held: [nb.item_count]f32,
    reserved: [nb.item_count]f32,
    coin: f32,

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

pub const Result = struct {
    /// A deal proposed this frame that the neighbour accepts; the page writes it as an intent.
    settled: ?Settled = null,
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

fn stallMatches(ctx: *uic.UiCtx, i: usize, words: []const []const u8, post: nb.Post, query: []const u8) !bool {
    if (std.mem.trim(u8, query, " ").len == 0) return true;
    const kind = if (i < nb.first_crafted) "resource" else "crafted";
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
            (if (std.mem.eql(u8, value, "posted")) post.qty > 0 else if (std.mem.eql(u8, value, "idle")) post.qty == 0 else std.mem.startsWith(u8, kind, value))
        else
            std.mem.find(u8, words[i], value) != null;
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

fn buyWords(ctx: *uic.UiCtx, a: nb.Agent, words: []const []const u8, with_qty: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..nb.item_count) |i| if (a.buys[i] > 0) {
        if (out.items.len > 0) try out.appendSlice(ctx.arena, ", ");
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
    const q = lr.outer.control(.{ .name = "Your stall", .role = .button, .ring = false });
    var live: u32 = 0;
    var sells: std.ArrayList(u8) = .empty;
    var buys: std.ArrayList(u8) = .empty;
    for (0..nb.item_count) |i| {
        if (m.sell_posts[i].qty > 0) {
            live += 1;
            if (sells.items.len > 0) try sells.appendSlice(ctx.arena, ", ");
            try sells.appendSlice(ctx.arena, try ctx.arena.print("{s} \u{00d7}{d} at {d}", .{ try book_mod.title(ctx.arena, words[i]), m.sell_posts[i].qty, m.sell_posts[i].price }));
        }
        if (m.buy_posts[i].qty > 0) {
            live += 1;
            if (buys.items.len > 0) try buys.appendSlice(ctx.arena, ", ");
            try buys.appendSlice(ctx.arena, try ctx.arena.print("{s} \u{00d7}{d} at {d}", .{ words[i], m.buy_posts[i].qty, m.buy_posts[i].price }));
        }
    }
    const top = try row.box("top", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center },
        .gap = 8,
    }, .{});
    try top.label("name", "You", .{Style{ .font = 13, .ink = .acc }});
    try top.label("trade", try std.ascii.allocUpperString(ctx.arena, p.trade), .{Style{ .font = 10, .tracking = 0.06, .ink = .dim }});
    const right = try top.box("right", .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .row, .main = .end } }, .{});
    const posts = if (live > 0) try ctx.arena.print("{d} POSTS LIVE", .{live}) else "NOTHING POSTED";
    try right.label("posts", posts, .{Style{ .font = 10, .tracking = 0.06, .ink = .dim, .verdict = vd.when(live == 0, .attention) }});
    if (live > 0) {
        try run(row, "line", 11, &.{
            .{ "Sells ", th.dim },
            .{ if (sells.items.len > 0) sells.items else "nothing", th.fg },
            .{ ". Buys ", th.dim },
            .{ if (buys.items.len > 0) buys.items else "nothing", th.dim },
            .{ ".", th.dim },
        });
    } else {
        try run(row, "line", 11, &.{.{ "Nothing posted. Neighbours cannot trade with you.", th.dim }});
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
/// YOUR STALL: accent edge and label on hover or visible focus and while the stall is open
/// (published as `selected`), which also fills it with the panel; else a line2 edge, dim label.
pub const stall_outline = Style{ .outline_ink = .line2, .fill_ink = .bg, .on = &.{
    .{ .when = .hover_focus, .outline_ink = .acc },
    .{ .when = .selected, .outline_ink = .acc, .fill_ink = .panel },
} };
pub const stall_label = Style{ .ink = .dim, .on = &.{ .{ .when = .hover_focus, .ink = .acc }, .{ .when = .selected, .ink = .acc } } };

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
        .{ "Sells ", th.dim },
        .{ try sellSummary(ctx, a, words), th.fg },
        .{ try ctx.arena.print(". Buys {s}.", .{try buyWords(ctx, a, words, false)}), th.dim },
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

/// The stall table's columns (`.stall-head`/`.stall-row`): `minmax(0, 1fr) 86px 86px 143px`,
/// gap 10. The head and every row lay out by one set, declared on the list.
const stall_tracks = [_]uic.Track{
    .{ .basis = .{ .fr = 1 } },
    .{ .basis = .{ .px = 86 } },
    .{ .basis = .{ .px = 86 } },
    .{ .basis = .{ .px = 143 } },
};
const stall_gap: f32 = 10;

/// The stall's table head (`.stall-head`).
fn stallHead(parent: El, tracks: *uic.TrackSet, selling: bool) !void {
    const lr = try listRow(parent, "stall_head", null, 0);
    lr.outer.set(.{}, .{style.pad_each(9, pad_x, 7, pad_x)});
    const row = lr.inner;
    row.set(.{ .flow = .{ .dir = .row, .cross = .center }, .in_tracks = tracks }, .{});
    const s = style.eyebrow_dim;
    const item = try row.div("item");
    try item.label("t", "ITEM", .{s});
    inline for (.{ .{ "qty", if (selling) "POSTED" else "WANTED" }, .{ "price", "PRICE" } }) |c| {
        const cell = try row.box(c[0], .{ .flow = .{ .dir = .row, .main = .center } }, .{});
        try cell.label("t", c[1], .{s});
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
    const sub = if (selling)
        try a.print("{d:.0} spare of {d:.0} held", .{ p.spare(i), p.held[i] })
    else blk: {
        const off = m.offered(i);
        break :blk try a.print("{d} offered by {d}", .{ off.units, off.by });
    };
    try item.label("sub", sub, .{style.caption_faint});
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

// ---- the slip -----------------------------------------------------------------------------

fn slipHeading(parent: El, text: []const u8) !void {
    try parent.label("heading", text, .{ style.eyebrow, style.muted });
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

fn goodSlip(slip: El, m: *const nb.Market, i: usize, st: *MarketState, words: []const []const u8) !void {
    const ctx = slip.ctx;
    const a = ctx.arena;
    try slipHeading(slip, try std.ascii.allocUpperString(a, words[i]));
    // The four cheapest selling and the four paying most; a name opens a deal with them.
    var sellers: std.ArrayList(usize) = .empty;
    var buyers: std.ArrayList(usize) = .empty;
    for (m.people(), 0..) |p, k| {
        if (p.sells[i] > 0) try sellers.append(a, k);
        if (p.buys[i] > 0) try buyers.append(a, k);
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
            const p = people[k];
            const name = if (side[2])
                try a.print("{s} {s} \u{00d7}{d}", .{ p.firstName(), p.lastName(), p.sells[i] })
            else
                try a.print("{s} {s} wants {d}", .{ p.firstName(), p.lastName(), p.buys[i] });
            const price = try a.print("{d} coin", .{if (side[2]) p.ask[i] else p.bid[i]});
            if (try line(box, j, name, price, true)) pickAgent(st, m, k, null);
        }
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

/// Open a deal with neighbour `k`: what it wants that the player has spare (when `seed` is
/// given), against its first good, the way the prototype seeds the slip.
fn pickAgent(st: *MarketState, m: *const nb.Market, k: usize, seed: ?Player) void {
    st.pick_kind = 1;
    st.pick = @intCast(k);
    st.give = @splat(0);
    st.take = @splat(0);
    const a = m.agents[k];
    if (seed) |p| {
        for (0..nb.item_count) |i| if (a.buys[i] > 0 and p.spare(i) >= 1) {
            st.give[i] = @intCast(@min(@as(u32, @intFromFloat(@floor(p.spare(i)))), a.buys[i]));
            break;
        };
    }
    for (0..nb.item_count) |i| if (a.sells[i] > 0) {
        st.take[i] = @min(a.sells[i], 4);
        break;
    };
}

fn agentSlip(slip: El, m: *const nb.Market, k: usize, st: *MarketState, p: Player, words: []const []const u8) !?Settled {
    const ctx = slip.ctx;
    const th = ctx.res.view.theme;
    const a = ctx.arena;
    const agent = m.agents[k];
    try slipHeading(slip, "THE DEAL");
    const who = try slip.div("who");
    // Full slip width, so the wrapped line below fills it (a fitted column would not wrap it).
    who.set(.{ .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start }, .gap = 3 }, .{});
    try who.label("name", try a.print("{s} {s}", .{ agent.firstName(), agent.lastName() }), .{Style{ .font = 14, .ink = .fg }});
    try who.label_fit("small", try a.print("{s} \u{00b7} buys {s}", .{ @tagName(agent.trade), try buyWords(ctx, agent, words, true) }), .fill, .{style.caption});

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
        if (!any) try placeholder(box, "none", if (giving) "Nothing spare they buy." else "Nothing to receive.");
    }

    // The verdict, in the neighbour's own valuation.
    const v = nb.verdict(agent, st.give, st.take, p.spares());
    const first = agent.firstName();
    const text: []const u8, const color: uic.Color, const line_color: uic.Color = switch (v) {
        .idle => .{ "Put something on both sides.", th.dim, th.line },
        .refuse => .{ try a.print("{s} buys {s} \u{2014} nothing you have spare. Coin would still work.", .{ first, try buyWords(ctx, agent, words, false) }), th.danger, th.danger },
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
    try slipHeading(slip, "YOUR STALL");
    var live: u32 = 0;
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
    live = sell_items + buy_items;
    const over = @as(f32, @floatFromInt(committed)) > p.coin;
    const who = try slip.box("who", .{ .flow = .{ .dir = .column, .cross = .start }, .gap = 3 }, .{});
    try who.label("n", try a.print("{d} post{s} live", .{ live, if (live == 1) "" else "s" }), .{Style{ .font = 14, .ink = .fg }});
    try who.label("s", "neighbours trade against these prices", .{style.caption});
    const tally = try slip.box("tally", .{ .flow = .{ .dir = .column, .cross = .start }, .gap = 3 }, .{});
    inline for (.{ .{ "sell", "SELLING", false }, .{ "buy", "BUYING", true } }) |r| {
        const row = try tally.box(r[0], .{
            .w = .{ .fixed = slip_inner }, .h = .fit_children,
            .flow = .{ .dir = .row, .main = .space_between },
        }, .{});
        try row.label("l", r[1], .{style.note});
        const value = if (r[2]) try a.print("{d} items \u{00b7} {d} of {d:.0} coin", .{ buy_items, committed, p.coin }) else try a.print("{d} items \u{00b7} {d} units", .{ sell_items, sell_units });
        try row.label("v", value, .{Style{ .font = 11, .ink = .fg, .verdict = vd.when(r[2] and over, .over) }});
    }
    if (over) {
        try slip.label_fit("warn", try a.print("Your buy orders commit {d} coin and you hold {d:.0}. The shortfall will not fill.", .{ committed, p.coin }), .fill, .{Style{ .font = 10, .ink = .danger }});
    }
    inline for (.{ .{ "posted_sell", "POSTED TO SELL", true }, .{ "posted_buy", "POSTED TO BUY", false } }) |side| {
        const posts = if (side[2]) &m.sell_posts else &m.buy_posts;
        const box = try slip.box(side[0], .{
            .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
            .gap = 4,
        }, .{});
        var count: u32 = 0;
        for (posts) |post| count += @intFromBool(post.qty > 0);
        try sideHead(box, side[1], try a.print("{}", .{count}));
        if (count == 0) try placeholder(box, "none", if (side[2]) "Nothing posted to sell." else "Nothing posted to buy.");
        for (posts, 0..) |post, i| {
            if (post.qty == 0) continue;
            _ = try line(box, i, try a.print("{s} \u{00d7}{d}", .{ try book_mod.title(a, words[i]), post.qty }), try a.print("{d} coin", .{post.price}), false);
        }
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

    // --- head --------------------------------------------------------------------------------
    const head = try band(view, "head", 11, 9);
    head.set(.{ .flow = .{ .dir = .row, .main = .space_between, .cross = .center } }, .{});
    try head.label("title", if (st.stall) "What will you post?" else "Who will trade with you?", .{ style.heading, style.ink(.fg) });
    const sub_slot = try head.div("sub");
    try hrule(view, "head_rule");

    // --- controls ----------------------------------------------------------------------------
    const controls = try band(view, "controls", 9, 9);
    const owner = if (st.stall) stall_owner else query_owner;
    const field = try uic.text_input_look(controls, if (st.stall) "stall_search" else "search", if (st.stall) "search items  \u{00b7}  type:crafted  is:posted" else "search  \u{00b7}  needs:biomass  has:food  trade:fisher", 80, owner, .{ .font = 11, .placeholder = th.line2 });
    field.set(.{ .w = .grow, .h = .fit_children }, .{});
    const query = owner.state(uic.UiState.TextInputState).text();
    const seg = try controls.box("seg", .{ .flow = .{ .dir = .row, .cross = .center }, .gap = 2 }, .{});
    const mode = activeGroup(st, m.n);
    if (st.stall) {
        try seg.label("label", "SIDE", .{ style.eyebrow_dim, style.pad_each(0, 4, 0, 0) });
        if (try segButton(seg, "selling", "SELLING", st.side == 0)) {
            st.side = 0;
            st.page = 0;
        }
        if (try segButton(seg, "buying", "BUYING", st.side == 1)) {
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
    const stall_button = try controls.box("stall", .{ .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row } }, .{});
    const sq = stall_button.control(.{ .name = "Your stall", .role = .button, .selected = st.stall, .ring = false });
    stall_button.set(.{}, .{stall_outline});
    try stall_button.label("t", "YOUR STALL", .{ Style{ .font = 10, .tracking = 0.07 }, stall_label, style.pad_sym(8, 3) });
    var toggle_stall = sq.clicked;
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
    var rows: std.ArrayList(usize) = .empty;
    if (st.stall) {
        const selling = st.side == 0;
        for (0..nb.item_count) |i| {
            const post = if (selling) m.sell_posts[i] else m.buy_posts[i];
            const in_pool = if (selling) p.held[i] >= 1 or post.qty > 0 else m.offered(i).by > 0 or post.qty > 0;
            if (in_pool and try stallMatches(ctx, i, &words, post, query)) try rows.append(a, i);
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

    if (st.stall) {
        // One column set for the head and every row (`grid-template-columns` on both).
        const tracks = try uic.tracks(ctx, &stall_tracks, stall_gap);
        list.set(.{ .tracks = tracks }, .{});
        try stallHead(list, tracks, st.side == 0);
        if (slice.len == 0) try placeholder(list, "empty", "No item matches that query.");
        for (slice) |i| try stallRow(list, tracks, m, i, st.side == 0, p, &words);
        try stallSlip(slip, m, p, &words);
    } else {
        if (mode == .person) {
            if (try youRow(list, m, p, &words)) toggle_stall = true;
            for (slice) |k| {
                if (try personRow(list, k, m.agents[k], st.pick_kind == 1 and st.pick == k, spares, &words)) {
                    if (st.pick_kind == 1 and st.pick == k) st.pick_kind = 0 else pickAgent(st, m, k, p);
                }
            }
        } else {
            // One column set for every good row (`grid-template-columns` on `.good-row`).
            const tracks = try uic.tracks(ctx, &good_tracks, good_gap);
            list.set(.{ .tracks = tracks }, .{});
            for (slice) |i| {
                if (try goodRow(list, tracks, m, i, st.pick_kind == 2 and st.pick == i, p, &words)) {
                    if (st.pick_kind == 2 and st.pick == i) st.pick_kind = 0 else {
                        st.pick_kind = 2;
                        st.pick = @intCast(i);
                        st.give = @splat(0);
                        st.take = @splat(0);
                    }
                }
            }
        }
        if (slice.len == 0) {
            try list.label("empty", "Nothing matches that query.", .{ style.note, style.pad_sym(pad_x, 16) });
        }
        switch (st.pick_kind) {
            1 => result.settled = try agentSlip(slip, m, st.pick, st, p, &words),
            2 => try goodSlip(slip, m, st.pick, st, &words),
            else => {
                try slipHeading(slip, "THE DEAL");
                try placeholder(slip, "placeholder", "Pick a neighbour, or a good, on the left.");
            },
        }
    }

    // The head's count line, now the rows are known.
    const sub = if (st.stall)
        try a.print("{d} item{s} \u{00b7} {s}", .{ total, if (total == 1) "" else "s", if (st.side == 0) "your inventory" else "offered by neighbours" })
    else
        try a.print("{d} of {d} neighbours \u{00b7} by {s}{s}", .{ visible_people, m.n, @tagName(mode), if (st.group == 0) " (natural)" else "" });
    try sub_slot.label("t", sub, .{style.eyebrow_dim});

    // --- foot: friction and pages ------------------------------------------------------------
    try hrule(view, "foot_rule");
    const foot = try band(view, "foot", 8, 8);
    foot.set(.{ .flow = .{ .dir = .row, .main = .space_between, .cross = .center } }, .{});
    if (st.stall) {
        var live: u32 = 0;
        for (0..nb.item_count) |i| live += @intFromBool(m.sell_posts[i].qty > 0) + @intFromBool(m.buy_posts[i].qty > 0);
        try runFit(foot, "friction", 11, false, &.{ .{ try a.print("{}", .{live}), th.warn }, .{ " posts live \u{00b7} neighbours trade against them while you work.", th.dim } });
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
