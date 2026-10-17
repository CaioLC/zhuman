//! `capital_row` — one buildable good as a **row**, replacing the tile.
//!
//! A tile held two short strings, which is why its consequence column decayed into
//! notation. A row holds a sentence, a reach meter, a verb and a corner — and it is the
//! shape that lets a build in progress keep its place in the list instead of becoming a
//! 3px underbar on a dim box.
//!
//! Six fixed columns so every row's fields line up down the list. The last two carry the
//! row's *state*: an affordable good shows `Build →`, one out of reach shows how far
//! (`31/48m`), one in progress shows time left and a `×` in the corner that abandons it,
//! and one whose prerequisite is missing says which verb it wants.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const capital = ha.capital;
const ledger = ha.ledger;
const roster = ha.roster;
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const World = ha.world.World;
const Entity = ha.world.Entity;
const Color = uic.Color;

const info = @import("./action_info.zig");
const table = @import("./table.zig");

/// The table's lanes, in order. The header and every row iterate this one array, so their
/// lanes cannot drift apart. `hidden_at` is the widest width class at which the lane is
/// dropped — the lower-priority lanes go first as the terminal narrows. Lane **widths** are the
/// act's (`Widths`): the shelf decides how its content splits the lane.
const Column = struct {
    id: []const u8,
    label: []const u8,
    hidden_at: ?uic.view.WidthClass = null,

    fn visible(self: Column, ctx: *UiCtx) bool {
        const at = self.hidden_at orelse return true;
        return !ctx.res.view.metrics.width_class.atMost(at);
    }
};

pub const Lane = enum(usize) { recipe, cost, time, effect, state, corner };

/// Room the BUILD scroll view keeps on the right for its track: the track itself plus a 2px
/// breath, so the table never runs under the scrollbar (and never shifts when it appears).
pub const scroll_gutter: f32 = @import("./scroll_view.zig").scrollbar_w + 2;

const columns = [_]Column{
    .{ .id = "recipe", .label = "RECIPE" },
    .{ .id = "cost", .label = "COST" },
    .{ .id = "time", .label = "TIME", .hidden_at = .w560 },
    .{ .id = "effect", .label = "WHAT CHANGES", .hidden_at = .w440 },
    .{ .id = "state", .label = "STATE" },
    .{ .id = "corner", .label = "" },
};

fn col(lane: Lane) Column {
    return columns[@intFromEnum(lane)];
}

/// One act's lane widths in logical px. Every act fills the canonical 594px expanded content
/// lane (`lane_width`) less the BUILD view's always-reserved scroll gutter: the six cells, five
/// 8px gaps and 12px of row padding (`laneTotal`). The defaults are Act I's — a slim COST for its
/// one-material orders and a wide WHAT CHANGES; an act with longer orders (Act II's three
/// materials) trades WHAT CHANGES width for COST.
pub const Widths = struct {
    recipe: f32 = 118,
    cost: f32 = 74,
    time: f32 = 42,
    effect: f32 = 178 - scroll_gutter,
    state: f32 = 76,
    corner: f32 = 54,

    pub fn of(self: Widths, lane: Lane) f32 {
        return switch (lane) {
            .recipe => self.recipe,
            .cost => self.cost,
            .time => self.time,
            .effect => self.effect,
            .state => self.state,
            .corner => self.corner,
        };
    }

    /// Every lane plus the gaps, row padding and scroll gutter: the content lane it fills.
    pub fn laneTotal(self: Widths) f32 {
        var cells: f32 = 0;
        for (0..columns.len) |i| cells += self.of(@enumFromInt(i));
        return cells + (columns.len - 1) * row_gap + 2 * row_pad_x + scroll_gutter;
    }

    /// Whether a build order of `chars` characters fits the COST lane without eliding. The
    /// body font is monospace, about `glyph_w` px per character.
    pub fn costFits(self: Widths, chars: usize) bool {
        return @as(f32, @floatFromInt(chars)) * glyph_w <= self.cost;
    }
};

/// The body font's advance per character, logical px (monospace) — the measure `costFits`
/// holds a shelf's longest order to.
const glyph_w: f32 = 8;

/// The content lane every act's widths fill (see `Widths`).
pub const lane_width: f32 = 594;

const row_gap: f32 = 8;
const row_pad_x: f32 = 6;

/// The visible lanes plus the gaps between them, logical px.
fn contentWidth(ctx: *UiCtx, lw: Widths) f32 {
    var width: f32 = 0;
    var shown: f32 = 0;
    for (columns, 0..) |c, i| {
        if (c.visible(ctx)) {
            width += lw.of(@enumFromInt(i));
            shown += 1;
        }
    }
    return width + (shown - 1) * row_gap;
}

pub fn tableWidth(ctx: *UiCtx, lw: Widths) f32 {
    return contentWidth(ctx, lw) + row_pad_x * 2;
}

/// How the header sorts: the caller's sort key for each lane (in `columns` order; null for a
/// lane that does not sort), the active key, and the direction in force.
pub const HeaderSort = struct {
    keys: [columns.len]?usize,
    active: usize,
    dir: table.SortShown,
};

pub const Header = struct {
    el: El,
    /// The sort key of the column header clicked this frame, if any.
    clicked: ?usize,
};

/// Column labels aligned to the exact same responsive lanes as every capital row: the
/// table's header row and cells, sized to the lanes visible at this width. With `sort`, each
/// sortable lane's label is a sort control wearing the active column's arrow, and the header
/// row is their roving group (one Tab stop). `lw` is the act's lane widths.
pub fn capital_header(parent: El, id: []const u8, lw: Widths, sort: ?HeaderSort) !Header {
    const ctx = parent.ctx;
    const header = try table.table_row(parent, id, row_gap, row_pad_x, 4);
    _ = header.with_size(.{ .fixed = contentWidth(ctx, lw) }, .fit_children);
    const group = header.get().key;
    var clicked: ?usize = null;
    var members: [columns.len]u64 = undefined;
    var nmembers: usize = 0;
    for (columns, 0..) |c, i| {
        if (!c.visible(ctx)) continue;
        const w = lw.of(@enumFromInt(i));
        const key = if (sort) |s| s.keys[i] else null;
        if (key) |k| {
            const shown: table.SortShown = if (k == sort.?.active) sort.?.dir else .none;
            const cell_r = try table.sort_header_cell(header, c.id, w, c.label, shown, group);
            if (cell_r.clicked) clicked = k;
            members[nmembers] = cell_r.key;
            nmembers += 1;
        } else {
            try table.header_cell(header, c.id, w, c.label);
        }
    }
    if (nmembers > 0) {
        ctx.res.semantics.publish(uic.semantic.describeGroup(group, "sort by column", members[0..nmembers]));
    }
    return .{ .el = header, .clicked = clicked };
}

/// What a row is showing, which is the one thing the flat grey never said. `busy` is a recipe
/// whose order is on hand but whose builder's hands are taken by other work.
pub const Kind = enum { ready, busy, reach, building, blocked, locked, owned };

pub const Row = struct { kind: Kind, reach: f32, clicked_build: bool, clicked_cancel: bool };

/// A row's plain cell is the table's.
const cell = table.cell;

/// A catalog **name** cell: the label is an ellipsis cell of exactly the column
/// width, so a long good name is elided (`Reinforced Timber Fra…`) instead of stretching the
/// row and knocking every downstream column out of its lane. The box and hit geometry stay
/// the allocated `width`; only the visible glyphs are bounded. A **secondary type** sub-label
/// rides under the name in dim/small — the crude/manufactured tier word.
fn name_cell(parent: El, id: []const u8, width: f32, text: []const u8, secondary: []const u8, color: Color) !void {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const box = try parent.div(id);
    _ = box.with_size(.{ .fixed = width }, .fit_children).with_flow(.{ .dir = .column, .cross = .start });
    _ = (try box.text_fit("t", text, .{ .cell = .{ .mode = .ellipsis, .width = width } }))
        .with_style(.{ style.body, Style{ .text = color } });
    if (secondary.len > 0) {
        _ = (try box.text_fit("ty", secondary, .{ .cell = .{ .mode = .ellipsis, .width = width } }))
            .with_style(.{ style.small, Style{ .text = th.dim } });
    }
}

/// The verb or tool a recipe's first `needs` names, in the player's words.
fn needsName(cat: *const roster.Catalog, rec: *const roster.Good) []const u8 {
    if (rec.needs.len == 0) return "a tool";
    const id = rec.needs[0];
    if (cat.action(id)) |a| return a.name;
    if (cat.good(id)) |g| return g.name;
    return "a tool";
}

/// The technology a research-gated recipe waits on, in the player's words.
fn techName(cat: *const roster.Catalog, rec: *const roster.Good) []const u8 {
    const t = rec.tech orelse return "research";
    return if (cat.technology(t)) |tr| tr.name else t;
}

/// `36me 24fu 20mi` — the build order's once-lines, the COST cell's first line. "" when the
/// recipe takes no materials.
fn orderText(buf: []u8, rec: *const roster.Good) []const u8 {
    var cw = std.Io.Writer.fixed(buf);
    var first = true;
    for (rec.input) |l| if (l.per == .once) {
        cw.print("{s}{d:.0}{s}", .{ if (first) "" else " ", l.n, info.letterOf(l.item) }) catch {};
        first = false;
    };
    return cw.buffered();
}

/// `10e` — the energy, the COST cell's second line.
fn energyText(buf: []u8, rec: *const roster.Good) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.0}e", .{rec.requires.?.energy}) catch "?";
}

/// The build order's length in characters — what an act's COST width must hold
/// (`Widths.costFits`).
pub fn orderChars(rec: *const roster.Good) usize {
    var buf: [64]u8 = undefined;
    return orderText(&buf, rec).len;
}

/// The COST cell: the order on the first line and the energy under it, small and dim — the
/// same two-line shape as the name cell beside it, so a three-material Act II order fits
/// without eliding and the row grows no taller.
fn cost_cell(parent: El, id: []const u8, width: f32, rec: *const roster.Good, color: Color) !void {
    const th = parent.ctx.res.view.theme;
    const box = try parent.div(id);
    _ = box.with_size(.{ .fixed = width }, .fit_children).with_flow(.{ .dir = .column, .cross = .start });
    var obuf: [48]u8 = undefined;
    var ebuf: [12]u8 = undefined;
    const order = orderText(&obuf, rec);
    const energy = energyText(&ebuf, rec);
    // An energy-only recipe reads its energy on the first line.
    _ = (try box.text_fit("t", if (order.len > 0) order else energy, .{ .cell = .{ .mode = .ellipsis, .width = width } }))
        .with_style(.{ style.body, Style{ .text = color } });
    if (order.len > 0) {
        _ = (try box.text_fit("e", energy, .{ .cell = .{ .mode = .ellipsis, .width = width } }))
            .with_style(.{ style.small, Style{ .text = th.dim } });
    }
}

/// One row over a recipe's quote. `kind` decides the colors and what the last two columns
/// say; the caller has already decided the row belongs on screen at all (see `build_list`).
pub fn capital_row(
    parent: El,
    world: *World,
    e: Entity,
    lw: Widths,
    q: capital.Quote,
    kind: Kind,
) !Row {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const cat = &ctx.res.catalog;
    const rec = q.rec;

    // Keyed by the recipe's id: the row's identity across re-sorts, filters and a reloaded
    // roster that moves it to another index.
    const row = try parent.div(rec.id);
    const hot = kind == .ready;
    const row_key = row.get().key;
    // The row is a composite tile: the good's name is its accessible name and `hot` is the
    // same enabled fact the build click gates on.
    const ctl = row.control(.{ .enabled = hot, .name = rec.name, .role = .tile });
    const lit: Color = switch (kind) {
        .ready => if (ctl.held or ctl.hovering or ctl.focused) th.acc else th.fg,
        .building => th.fg,
        .owned => th.dim,
        .reach, .busy, .blocked, .locked => th.dim,
    };
    const faint: Color = if (kind == .ready or kind == .building) th.dim else th.line2;

    // The row's lanes are the header's: the same columns, widths and visibility.
    _ = row.with_size(.{ .fixed = contentWidth(ctx, lw) }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center }).with_gap(row_gap)
        .with_style(.{ style.pad_sym(row_pad_x, 5), Style{ .fill = if (kind == .ready and (ctl.held or ctl.hovering or ctl.focused)) th.panel else null } });

    // Name + secondary type (crude vs manufactured — the row's type sub-label).
    const type_word = if (rec.tier == .crude) "crude" else "manufactured";
    try name_cell(row, "nm", lw.of(.recipe), rec.name, type_word, lit);

    try cost_cell(row, "co", lw.of(.cost), rec, faint);

    if (col(.time).visible(ctx)) {
        var dbuf: [16]u8 = undefined;
        const days_txt = std.fmt.bufPrint(&dbuf, "{d:.1}d", .{rec.requires.?.hours / 24.0}) catch "?";
        try cell(row, "dy", lw.of(.time), days_txt, faint, false);
    }

    if (col(.effect).visible(ctx)) {
        try cell(row, "sa", lw.of(.effect), rec.copy.effect, if (kind == .ready) th.fg else faint, false);
    }

    // --- state column: readiness, reach/materials, ownership, or live progress ------------
    const state = try row.div("st");
    _ = state.with_size(.{ .fixed = lw.of(.state) }, .fit_children);
    const state_in = try state.div("i");
    _ = state_in.with_layout(.center_left).with_flow(.{ .dir = .row, .cross = .center }).with_gap(6);

    switch (kind) {
        .ready => _ = (try state_in.text("ready", "ready"))
            .with_style(.{ style.body, Style{ .text = th.acc } }),
        .owned => _ = (try state_in.text("owned", "owned"))
            .with_style(.{ style.body, Style{ .text = th.line2 } }),
        // The order is on hand; only the hands are taken. Says so instead of a full meter.
        .busy => _ = (try state_in.text("busy", "hands busy"))
            .with_style(.{ style.body, Style{ .text = th.warn } }),
        .blocked => {
            var nbuf: [40]u8 = undefined;
            // Waiting on research names the technology; otherwise the verb or tool it needs.
            const wants = if (q.standing == .tech) techName(cat, rec) else needsName(cat, rec);
            const txt = std.fmt.bufPrint(&nbuf, "needs {s}", .{wants}) catch "needs a tool";
            // A technology name can outrun the lane. A blocked row has no corner action, so the
            // text may run on over that empty lane before it elides.
            const room = lw.of(.state) + row_gap + lw.of(.corner);
            _ = (try state_in.text_fit("blocked", txt, .{ .cell = .{ .mode = .ellipsis, .width = room } }))
                .with_style(.{ style.body, Style{ .text = th.danger } });
        },
        .locked => _ = (try state_in.text("locked", "conditions"))
            .with_style(.{ style.body, Style{ .text = th.danger } }),
        .building => {
            const busy = world.get(e, comp.Busy).?;
            var bbuf: [20]u8 = undefined;
            const left = busy.remaining / ctx.res.config.secs_per_day;
            const txt = std.fmt.bufPrint(&bbuf, "{d:.1}d left", .{left}) catch "?";
            try meter(state_in, "meter", 1.0 - busy.remaining / busy.total, th.acc);
            _ = (try state_in.text("time", txt)).with_style(.{ style.body, Style{ .text = th.fg } });
        },
        .reach => {
            // How far the first line of the order is: `31/48m`.
            var rbuf: [24]u8 = undefined;
            var txt: []const u8 = "";
            for (rec.input) |l| {
                if (l.per != .once) continue;
                txt = std.fmt.bufPrint(&rbuf, "{d:.0}/{d:.0}{s}", .{ ledger.held(world, e, cat, l), l.n, info.letterOf(l.item) }) catch "?";
                break;
            }
            try reach_meter(state_in, "meter", q.reach, th.line2);
            _ = (try state_in.text("materials", txt)).with_style(.{ style.body, Style{ .text = faint } });
        },
    }

    // --- right-side action column: Build → / Build +1 / cancel -----------------------------
    const action = try row.div("ac");
    _ = action.with_size(.{ .fixed = lw.of(.corner) }, .fit_children);
    const action_in = try action.div("i");
    _ = action_in.with_layout(.center_right);

    var build_more = false;
    var cancelled = false;
    var cancel_key: ?u64 = null;
    switch (kind) {
        .ready => _ = (try action_in.text("build", "Build \u{2192}"))
            .with_style(.{ style.body, Style{ .text = lit } }),
        .owned => {
            // Another unit is stock; offered whenever the quote would accept it.
            if (q.ready()) {
                const more = try action_in.div("more");
                const mq = more.control(.{ .name = "Build +1", .role = .button });
                _ = (try more.text("t", "Build +1"))
                    .with_style(.{ style.body, Style{ .text = if (mq.held or mq.hovering or mq.focused) th.acc else th.dim } });
                build_more = more.consume(.clicked);
            }
        },
        .building => {
            const x = try action_in.div("cancel");
            const xq = x.control(.{ .name = "Cancel build", .role = .icon_button });
            _ = (try x.text("t", "\u{00d7}"))
                .with_style(.{ style.h3, Style{ .text = if (xq.held or xq.hovering or xq.focused) th.danger else th.line2 } });
            cancelled = x.consume(.clicked);
            cancel_key = x.get().key;
        },
        .reach, .busy, .blocked, .locked => {},
    }

    // The row controls its cancel sub-action when one exists. The sub-action's key is
    // known only once it is built, so the row's published node is updated in place with the
    // relation (same key, first-seen paint order preserved).
    if (cancel_key) |ck| {
        ctx.res.semantics.publish(uic.semantic.describeTile(row_key, rec.name, hot, ctl.focused, &[_]u64{ck}));
    }

    return .{
        .kind = kind,
        .reach = q.reach,
        // The corner sits inside the row, so hover still bubbles and keeps the row lit.
        // Its activation is consumed above; re-query after descendants for the action.
        // `clicked_build` fires for a ready row's whole-box click OR an owned row's `Build +1`.
        .clicked_build = (hot and row.query().clicked) or build_more,
        .clicked_cancel = cancelled,
    };
}

/// A thin progress bar (a build in progress) — continuous fill. Fixed width so the numbers
/// beside it stay in a column.
fn meter(parent: El, id: []const u8, frac: f32, color: Color) !void {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const track = try parent.div(id);
    _ = track.with_size(.{ .fixed = 34 }, .{ .fixed = 3 })
        .with_style(.{Style{ .fill = th.line }});
    const fill = try track.div("f");
    _ = fill.with_layout(.top_left)
        .with_size(.{ .fixed = 34 * std.math.clamp(frac, 0, 1) }, .{ .fixed = 3 })
        .with_style(.{Style{ .fill = color }});
}

/// The **3-segment reach meter**: three fixed cells that light in sequence as `frac`
/// crosses 1/3, 2/3, 3/3 — a coarse "how close to affordable" read that quantizes the reach
/// into thirds rather than a smooth bar, matching the prototype's segmented treatment. A lit
/// segment takes `color`; an unlit one the inactive `line`.
fn reach_meter(parent: El, id: []const u8, frac: f32, color: Color) !void {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const track = try parent.div(id);
    _ = track.with_size(.{ .fixed = 34 }, .{ .fixed = 4 }).with_flow(.{ .dir = .row }).with_gap(2);
    const lit_segments = reachSegments(frac);
    var s: usize = 0;
    while (s < 3) : (s += 1) {
        const seg = try track.item("s", s);
        _ = seg.with_size(.{ .fixed = 10 }, .{ .fixed = 4 })
            .with_style(.{Style{ .fill = if (s < lit_segments) color else th.line }});
    }
}

/// How many of the 3 reach segments are lit for a fraction — pure, tested. `>= 1/3` lights one,
/// `>= 2/3` two, `>= 1` all three; below `1/3` none.
pub fn reachSegments(frac: f32) usize {
    if (frac >= 1.0) return 3;
    if (frac >= 2.0 / 3.0) return 2;
    if (frac >= 1.0 / 3.0) return 1;
    return 0;
}

test "reachSegments quantizes reach into thirds" {
    try std.testing.expectEqual(@as(usize, 0), reachSegments(0.0));
    try std.testing.expectEqual(@as(usize, 0), reachSegments(0.32));
    try std.testing.expectEqual(@as(usize, 1), reachSegments(0.34));
    try std.testing.expectEqual(@as(usize, 1), reachSegments(0.5));
    try std.testing.expectEqual(@as(usize, 2), reachSegments(0.67));
    try std.testing.expectEqual(@as(usize, 3), reachSegments(1.0));
    try std.testing.expectEqual(@as(usize, 3), reachSegments(1.5));
}

test "Act I's default lane widths fill the expanded content lane" {
    try std.testing.expectEqual(lane_width, (Widths{}).laneTotal());
}

test "the cost cell is the order, then the energy under it" {
    var cat = try roster.load(std.testing.allocator, roster.shipped, null);
    defer cat.deinit();
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("10m", orderText(&buf, cat.good("spear").?));
    try std.testing.expectEqualStrings("5e", energyText(&buf, cat.good("spear").?));
    try std.testing.expectEqualStrings("36me 24fu 20mi", orderText(&buf, cat.good("cold_store").?));
    try std.testing.expectEqualStrings("Split wood", needsName(&cat, cat.good("work_gloves").?));
    try std.testing.expectEqualStrings("a tool", needsName(&cat, cat.good("sandals").?));
}
