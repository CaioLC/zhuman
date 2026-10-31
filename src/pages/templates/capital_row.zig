//! `capital_row` — one buildable good as a **row**, replacing the tile.
//!
//! A tile held two short strings, which is why its consequence column decayed into
//! notation. A row holds a sentence, a reach meter, a verb and a corner — and it is the
//! shape that lets a build in progress keep its place in the list instead of becoming a
//! 3px underbar on a dim box.
//!
//! Six columns, shared by the header and every row as one set of grid tracks
//! (`tableTracks`), so every row's fields line up down the list. The last two carry the
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
        return self.shownIn(ctx.res.view.metrics.width_class);
    }

    fn shownIn(self: Column, class: uic.view.WidthClass) bool {
        const at = self.hidden_at orelse return true;
        return !class.atMost(at);
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
    return columns[@backingInt(lane)];
}

/// Which lanes show at `class`, in `columns` order.
fn shownAt(class: uic.view.WidthClass) [columns.len]bool {
    var out: [columns.len]bool = undefined;
    for (columns, &out) |c, *s| s.* = c.shownIn(class);
    return out;
}

/// Place a cell of the header or a row on its lane's track, covering `span` lanes.
fn place(cell_el: El, lane: Lane, span: u16) void {
    _ = cell_el.at_track(@intCast(@backingInt(lane)), span);
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
        for (0..columns.len) |i| cells += self.of(@fromBackingInt(@intCast(i)));
        return cells + (columns.len - 1) * row_gap + 2 * row_pad_x + scroll_gutter;
    }

    /// Whether a build order of `chars` characters fits the COST lane without eliding. The
    /// body font is monospace, about `glyph_w` px per character.
    pub fn costFits(self: Widths, chars: usize) bool {
        return @as(f32, @floatFromInt(chars)) * glyph_w <= self.cost;
    }
};

/// The row font's advance per character, logical px (monospace, 11px at 0.6em) — the
/// measure `costFits` holds a shelf's longest order to.
const glyph_w: f32 = 6.6;

/// The row's type (`.build-row`): 11px, the name 12px, its kind 8px uppercase.
const row_font: f32 = 11;
/// The state and action lanes' type: `row_font` with no other field set.
const row_type: Style = .{ .font = row_font };
const name_font: f32 = 12;
const kind_font: f32 = 8;

/// The content lane every act's widths fill (see `Widths`).
pub const lane_width: f32 = 594;

const row_gap: f32 = 8;
const row_pad_x: f32 = 6;

/// The prototype's floors for the lanes that give way (`minmax(…)` in `.build-row`): the
/// recipe name, the order, and the sentence.
const min_recipe: f32 = 88;
const min_cost: f32 = 56;
const min_effect: f32 = 70;

/// The table's column tracks, logical px, in `columns` order: each lane at the act's width
/// (`lw`), and a lane not `shown` at this width a hidden track. When the rows overflow their
/// surface the prototype's grid gives way in a fixed priority: WHAT CHANGES first, then the
/// recipe name, then the order, each down to its floor (`shrink_order` 0, 1, 2); TIME, STATE
/// and the corner keep their widths. The name and order cells elide, so nothing spills past
/// the surface's clip.
fn trackSpec(lw: Widths, shown: [columns.len]bool) [columns.len]uic.Track {
    var spec: [columns.len]uic.Track = undefined;
    for (&spec, shown, 0..) |*t, s, i| {
        const lane: Lane = @fromBackingInt(@intCast(i));
        t.* = .{ .basis = .{ .px = lw.of(lane) }, .hidden = !s };
        switch (lane) {
            .effect => {
                t.min = min_effect;
                t.shrink_order = 0;
            },
            .recipe => {
                t.min = min_recipe;
                t.shrink_order = 1;
            },
            .cost => {
                t.min = min_cost;
                t.shrink_order = 2;
            },
            .time, .state, .corner => {},
        }
    }
    return spec;
}

/// The table's border-box width bounds, logical px: the section clamps its parent's width to
/// them (the scroll gutter on top), and everything inside takes its width from the section.
/// `max` is every shown lane at its width, the gaps between them and the row padding: what the
/// tracks need before any free space. No track is `fr`, so on a wider surface (stacked at 760,
/// or Act II's 600px framed view) the slack stays outside the table, and the hairlines and the
/// hover fill stop where the lanes do. `min` is the same with the lanes that give way at their
/// floors: on a surface narrower than that the table overflows instead of pressing a lane
/// past its floor. Between the two the engine shrinks the tracks against the row's own width.
pub const Extent = struct { min: f32, max: f32 };

fn extentOf(spec: []const uic.Track) Extent {
    var max: f32 = 0;
    var min: f32 = 0;
    var shown: f32 = 0;
    for (spec) |t| if (!t.hidden) {
        max += t.basis.px;
        min += if (t.shrink_order != null) t.min else t.basis.px;
        shown += 1;
    };
    const rest = (shown - 1) * row_gap + 2 * row_pad_x;
    return .{ .min = min + rest, .max = max + rest };
}

/// The BUILD table's width bounds for the act's lane widths `lw` at this frame's width class.
pub fn tableExtent(ctx: *UiCtx, lw: Widths) Extent {
    const spec = trackSpec(lw, shownAt(ctx.res.view.metrics.width_class));
    return extentOf(&spec);
}

/// The BUILD table's column tracks for the act's lane widths `lw` at this frame's width class.
/// The header and every row lay out by them (the caller declares the set on their common
/// ancestor, `El.with_tracks`), and the engine solves them against each row's content box.
pub fn tableTracks(ctx: *UiCtx, lw: Widths) !*uic.TrackSet {
    const spec = trackSpec(lw, shownAt(ctx.res.view.metrics.width_class));
    return uic.tracks(ctx, &spec, row_gap);
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

/// Column labels on the same tracks as every capital row: the table's header row, one cell
/// per lane visible at this width. With `sort`, each sortable lane's label is a sort control
/// wearing the active column's arrow, and the header row is their roving group (one Tab
/// stop). `set` is this frame's tracks (`tableTracks`). The header spans its parent less the
/// scroll gutter, the width the rows below it get from the scroll view.
pub fn capital_header(parent: El, id: []const u8, set: *uic.TrackSet, sort: ?HeaderSort) !Header {
    const ctx = parent.ctx;
    const header = try table.table_row(parent, id, set, row_pad_x, 4);
    _ = header.with_size(.{ .pct_of_parent = 1.0 }, .fit_children).with_pct_less(scroll_gutter, null);
    const group = header.get().key;
    var clicked: ?usize = null;
    var members: [columns.len]u64 = undefined;
    var nmembers: usize = 0;
    for (columns, 0..) |c, i| {
        if (!c.visible(ctx)) continue;
        const lane: Lane = @fromBackingInt(@intCast(i));
        const key = if (sort) |s| s.keys[i] else null;
        if (key) |k| {
            const shown: table.SortShown = if (k == sort.?.active) sort.?.dir else .none;
            const cell_r = try table.sort_header_cell(header, c.id, c.label, shown, group);
            place(cell_r.el, lane, 1);
            if (cell_r.clicked) clicked = k;
            members[nmembers] = cell_r.key;
            nmembers += 1;
        } else {
            place(try table.header_cell(header, c.id, c.label), lane, 1);
        }
    }
    if (nmembers > 0) {
        ctx.res.semantics.publish(uic.semantic.describeGroup(group, "Sort by column", members[0..nmembers]));
    }
    return .{ .el = header, .clicked = clicked };
}

/// What a row is showing, which is the one thing the flat grey never said. `busy` is a recipe
/// whose order is on hand but whose builder's hands are taken by other work.
pub const Kind = enum { ready, busy, reach, building, blocked, locked, owned };

pub const Row = struct { kind: Kind, reach: f32, clicked_build: bool, clicked_cancel: bool };

/// A row's plain cell is the table's.
const cell = table.cell;

/// A catalog **name** cell: the label elides at its track's width (`.cell_fill`), so a long
/// good name is elided (`Reinforced Timber Fra…`) instead of stretching the row and knocking
/// every downstream column out of its lane. The box and hit geometry are the track; only the
/// visible glyphs are bounded. A **secondary type** sub-label rides under the name in
/// dim/small — the recipe's kind (`recipeType`).
fn name_cell(parent: El, id: []const u8, text: []const u8, secondary: []const u8, color: Color) !El {
    const box = try parent.div(id);
    _ = box.with_size(.fit_children, .fit_children).with_flow(.{ .dir = .column, .cross = .start });
    _ = box.with_gap(1);
    _ = (try box.text_fit("t", text, .{ .cell_fill = .ellipsis }))
        .with_style(.{Style{ .font = name_font, .text = color }});
    if (secondary.len > 0) {
        _ = (try box.text_fit("ty", secondary, .{ .cell_fill = .ellipsis }))
            .with_style(.{Style{ .font = kind_font, .tracking = 0.06, .transform = .upper, .ink = .line2 }});
    }
    return box;
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

/// `36me 24fu 20mi` — the build order's once-lines, the COST cell's lead. "" when the
/// recipe takes no materials.
fn orderText(act: u8, buf: []u8, rec: *const roster.Good) []const u8 {
    var cw = std.Io.Writer.fixed(buf);
    var first = true;
    for (rec.input) |l| if (l.per == .once) {
        cw.print("{s}{d:.0}{s}", .{ if (first) "" else " ", l.n, info.letterOf(act, l.item) }) catch {};
        first = false;
    };
    return cw.buffered();
}

/// `10e` — the energy, the COST cell's tail.
fn energyText(buf: []u8, rec: *const roster.Good) []const u8 {
    return std.mem.print(buf, "{d:.0}e", .{rec.requires.?.energy}) catch "?";
}

/// The build order's length in characters — what an act's COST width must hold
/// (`Widths.costFits`).
pub fn orderChars(act: u8, rec: *const roster.Good) usize {
    var buf: [64]u8 = undefined;
    return orderText(act, &buf, rec).len;
}

/// The COST cell: the order then its energy on one line (`12m 4e`, the prototype's
/// `.recipe-cost`), elided at the lane width when a long Act II order outruns it.
fn cost_cell(parent: El, id: []const u8, act: u8, rec: *const roster.Good, color: Color) !El {
    var obuf: [48]u8 = undefined;
    var ebuf: [12]u8 = undefined;
    var lbuf: [64]u8 = undefined;
    const order = orderText(act, &obuf, rec);
    const energy = energyText(&ebuf, rec);
    const line = if (order.len > 0)
        std.mem.print(&lbuf, "{s} {s}", .{ order, energy }) catch order
    else
        energy;
    return cell(parent, id, line, color, false);
}

/// The word a recipe's row names its kind with, under the name and for `type:` — what the
/// good *does*, read from its record: a generator accumulates, a shelter houses, storage keeps
/// food, comfort raises the vigor ceiling, a material is a product made for other orders, and
/// a tool grants or tunes a verb.
pub fn recipeType(rec: *const roster.Good) []const u8 {
    if (rec.generator != null) return "generator";
    if (rec.capacity > 0) return "shelter";
    for (rec.effects) |fx| switch (fx) {
        .spoil_scale, .food_quality => return "storage",
        else => {},
    };
    for (rec.effects) |fx| switch (fx) {
        .vigor_ceiling => return "comfort",
        else => {},
    };
    for (rec.output) |l| if (l.per == .once) return "material";
    if (rec.effects.len > 0) return "tool";
    return "good";
}

/// One row over a recipe's quote. `kind` decides the colors and what the last two columns
/// say; the caller has already decided the row belongs on screen at all (see `build_list`).
/// The row spans `parent` (the scroll view's content column) and lays out by `set`.
pub fn capital_row(
    parent: El,
    world: *World,
    e: Entity,
    set: *uic.TrackSet,
    q: capital.Quote,
    kind: Kind,
) !Row {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const cat = &ctx.res.catalog;
    const rec = q.rec;
    const act = ha.migration.actOf(world, e);

    // Keyed by the recipe's id: the row's identity across re-sorts, filters and a reloaded
    // roster that moves it to another index.
    // One hairline above each row (`.build-row { border-top }`), then the row.
    const wrap = try parent.div(rec.id);
    _ = wrap.with_size(.{ .pct_of_parent = 1.0 }, .fit_children).with_flow(.{ .dir = .column });
    _ = (try wrap.div("rule")).with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = 1 })
        .with_style(.{style.rule_fill});
    const row = try wrap.div("row");
    const hot = kind == .ready;
    const row_key = row.get().key;
    // The row is a composite tile: the good's name is its accessible name and `hot` is the
    // same enabled fact the build click gates on.
    const ctl = row.control(.{ .enabled = hot, .name = rec.name, .role = .tile });
    const lit: Color = switch (kind) {
        .ready => if (ctl.hot()) th.acc else th.fg,
        .building => th.fg,
        // `.build-row.blocked/.owned .good-name` dim; every other name reads fg.
        .owned, .blocked => th.dim,
        .reach, .busy, .locked => th.fg,
    };
    // The row's own ink: fg on a ready or building row, dim otherwise (`.build-row.ready`).
    const faint: Color = if (kind == .ready or kind == .building) th.fg else th.dim;

    // The row's lanes are the header's: the same tracks, so the same widths and visibility.
    _ = row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center }).in_tracks(set)
        .with_style(.{ style.pad_sym(row_pad_x, 6), Style{ .hot = .{ .fill_ink = .panel } } }); // the row is enabled only when ready

    // Name + the recipe's kind under it (`generator`, `tool`…), the row's type sub-label.
    place(try name_cell(row, "nm", rec.name, recipeType(rec), lit), .recipe, 1);

    place(try cost_cell(row, "co", act, rec, faint), .cost, 1);

    if (col(.time).visible(ctx)) {
        var dbuf: [16]u8 = undefined;
        const days_txt = std.mem.print(&dbuf, "{d:.1}d", .{rec.requires.?.hours / 24.0}) catch "?";
        place(try cell(row, "dy", days_txt, faint, false), .time, 1);
    }

    if (col(.effect).visible(ctx)) {
        place(try cell(row, "sa", rec.copy.effect, if (kind == .blocked or kind == .owned) th.dim else th.fg, false), .effect, 1);
    }

    // --- state column: readiness, reach/materials, ownership, or live progress ------------
    // A blocked row has no corner action, so its state spans the empty corner lane too (and
    // no corner cell is built): a technology name can outrun the STATE lane alone.
    const state = try row.div("st");
    _ = state.with_size(.fit_children, .fit_children);
    place(state, .state, if (kind == .blocked) 2 else 1);
    const state_in = try state.div("i");
    _ = state_in.with_layout(.center_left).with_flow(.{ .dir = .row, .cross = .center }).with_gap(6);
    // The blocked text elides at the span, so its box must be the cell's.
    if (kind == .blocked) _ = state_in.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);

    switch (kind) {
        .ready => _ = (try state_in.text("ready", "ready"))
            .with_style(.{ row_type, style.ink(.acc) }),
        .owned => _ = (try state_in.text("owned", "owned"))
            .with_style(.{ row_type, style.faint }),
        // The order is on hand; only the hands are taken. Says so instead of a full meter.
        .busy => _ = (try state_in.text("busy", "hands busy"))
            .with_style(.{ row_type, style.ink(.warn) }),
        .blocked => {
            var nbuf: [40]u8 = undefined;
            // Waiting on research names the technology; otherwise the verb or tool it needs.
            const wants = if (q.standing == .tech) techName(cat, rec) else needsName(cat, rec);
            const txt = std.mem.print(&nbuf, "needs {s}", .{wants}) catch "needs a tool";
            // Elided at the STATE + corner span.
            _ = (try state_in.text_fit("blocked", txt, .{ .cell_fill = .ellipsis }))
                .with_style(.{ row_type, style.ink(.danger) });
        },
        .locked => _ = (try state_in.text("locked", "conditions"))
            .with_style(.{ row_type, style.ink(.danger) }),
        .building => {
            const busy = world.get(e, comp.Busy).?;
            var bbuf: [20]u8 = undefined;
            const left = busy.remaining / ctx.res.config.secs_per_day;
            const txt = std.mem.print(&bbuf, "{d:.1}d left", .{left}) catch "?";
            try meter(state_in, "meter", 1.0 - busy.remaining / busy.total, th.acc);
            _ = (try state_in.text("time", txt)).with_style(.{ row_type, style.ink(.fg) });
        },
        .reach => {
            // How far the first line of the order is: `31/48m`.
            var rbuf: [24]u8 = undefined;
            var txt: []const u8 = "";
            for (rec.input) |l| {
                if (l.per != .once) continue;
                txt = std.mem.print(&rbuf, "{d:.0}/{d:.0}{s}", .{ ledger.held(world, e, cat, l), l.n, info.letterOf(act, l.item) }) catch "?";
                break;
            }
            try reach_meter(state_in, "meter", q.reach, th.line2);
            _ = (try state_in.text("biomass", txt)).with_style(.{ row_type, Style{ .text = faint } });
        },
    }

    // --- right-side action column: Build → / Build +1 / cancel -----------------------------
    // Not built on a blocked row: its state spans this lane.
    var build_more = false;
    var cancelled = false;
    var cancel_key: ?u64 = null;
    if (kind != .blocked) {
        const action = try row.div("ac");
        _ = action.with_size(.fit_children, .fit_children);
        place(action, .corner, 1);
        const action_in = try action.div("i");
        _ = action_in.with_layout(.center_right);

        switch (kind) {
            .ready => _ = (try action_in.text("build", "Build \u{2192}"))
                .with_style(.{ row_type, Style{ .text = lit } }),
            .owned => {
                // Another unit is stock; offered whenever the quote would accept it.
                if (q.ready()) {
                    const more = try action_in.div("more");
                    _ = more.control(.{ .name = "Build +1", .role = .button });
                    _ = (try more.text("t", "Build +1"))
                        .with_style(.{ Style{ .font = row_font, .ink = .dim, .hot = .{ .ink = .acc } } });
                    build_more = more.consume(.clicked);
                }
            },
            .building => {
                const x = try action_in.div("cancel");
                _ = x.control(.{ .name = "Cancel build", .role = .icon_button });
                _ = (try x.text("t", "\u{00d7}"))
                    .with_style(.{ style.h3, Style{ .ink = .line2, .hot = .{ .ink = .danger } } });
                cancelled = x.consume(.clicked);
                cancel_key = x.get().key;
            },
            .reach, .busy, .blocked, .locked => {},
        }
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
    const track = try parent.div(id);
    _ = track.with_size(.{ .fixed = 34 }, .{ .fixed = 3 })
        .with_style(.{style.rule_fill});
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

/// Act II's lane widths (`act_two/page.zig`'s BUILD shelf), for the track tests.
const act_two_widths = Widths{ .cost = 112, .effect = 140 - scroll_gutter };

/// The tracks of `spec` solved for a row on a `surface_w` surface, as the engine solves a
/// participant (its content box: the surface less the scroll gutter and the row padding).
fn solveFor(spec: []const uic.Track, surface_w: f32) [columns.len]f32 {
    var auto_max: [columns.len]f32 = @splat(0);
    var widths: [columns.len]f32 = undefined;
    var set: uic.TrackSet = .{ .tracks = spec, .col_gap = row_gap, .auto_max = &auto_max, .widths = &widths };
    set.solve(surface_w - scroll_gutter - 2 * row_pad_x);
    return widths;
}

/// A row's border box, logical px, for `widths` solved from `spec`: the visible tracks, the
/// gaps between them and the row padding.
fn rowWidth(spec: []const uic.Track, widths: [columns.len]f32) f32 {
    var sum: f32 = 0;
    var shown: f32 = 0;
    for (spec, widths) |t, w| if (!t.hidden) {
        sum += w;
        shown += 1;
    };
    return sum + (shown - 1) * row_gap + 2 * row_pad_x;
}

/// The table width the section's clamp gives on a `surface_w` surface (`Extent`): the
/// surface less the scroll gutter, held to the table's bounds.
fn clampedTable(spec: []const uic.Track, surface_w: f32) f32 {
    const ext = extentOf(spec);
    return std.math.clamp(surface_w - scroll_gutter, ext.min, ext.max);
}

/// The lane widths and table width the BUILD table had before it laid out by tracks
/// (`capital_row.fitted` and `tableWidth`, restated as the oracle): framed the act's widths;
/// stacked, the excess over the surface out of WHAT CHANGES (if shown), then the recipe name,
/// then the order, each to its floor. Hidden lanes are 0, as their tracks are.
fn oldFitted(lw: Widths, shown: [columns.len]bool, stacked: bool, surface_w: f32) struct { lanes: [columns.len]f32, table: f32 } {
    var lanes: [columns.len]f32 = undefined;
    for (&lanes, 0..) |*w, i| w.* = lw.of(@fromBackingInt(@intCast(i)));
    const tableOf = struct {
        fn f(l: [columns.len]f32, s: [columns.len]bool) f32 {
            var width: f32 = 0;
            var n: f32 = 0;
            for (l, s) |w, v| if (v) {
                width += w;
                n += 1;
            };
            return width + (n - 1) * row_gap + row_pad_x * 2;
        }
    }.f;
    var excess = tableOf(lanes, shown) + scroll_gutter - surface_w;
    if (stacked and excess > 0) {
        const effect = @backingInt(Lane.effect);
        const recipe = @backingInt(Lane.recipe);
        const cost = @backingInt(Lane.cost);
        if (shown[effect]) {
            const take = @min(excess, @max(0, lanes[effect] - min_effect));
            lanes[effect] -= take;
            excess -= take;
        }
        const from_recipe = @min(excess, @max(0, lanes[recipe] - min_recipe));
        lanes[recipe] -= from_recipe;
        excess -= from_recipe;
        lanes[cost] -= @min(excess, @max(0, lanes[cost] - min_cost));
    }
    const table_w = tableOf(lanes, shown);
    for (&lanes, shown) |*w, v| if (!v) {
        w.* = 0;
    };
    return .{ .lanes = lanes, .table = table_w };
}

test "framed, every act's tracks fill the lane exactly and nothing shrinks" {
    for ([_]Widths{ .{}, act_two_widths }) |lw| {
        try std.testing.expectEqual(lane_width, lw.laneTotal());
        const spec = trackSpec(lw, shownAt(.full));
        const want = oldFitted(lw, shownAt(.full), false, lane_width);
        try std.testing.expectEqualSlices(f32, &want.lanes, &solveFor(&spec, lane_width));
        try std.testing.expectEqual(lane_width - scroll_gutter, rowWidth(&spec, solveFor(&spec, lane_width)));
        try std.testing.expectEqual(lane_width - scroll_gutter, extentOf(&spec).max);
        try std.testing.expectEqual(lane_width - scroll_gutter, clampedTable(&spec, lane_width));
    }
}

test "stacked, the solved tracks and the clamped table width are the old fitted lanes at every surface" {
    for ([_]Widths{ .{}, act_two_widths }) |lw| {
        for ([_]uic.view.WidthClass{ .w760, .w560, .w440 }) |class| {
            const shown = shownAt(class);
            const spec = trackSpec(lw, shown);
            // From past every act's lanes (nothing shrinks) down past their floors (overflow).
            var surface_w: f32 = 260;
            while (surface_w <= 760) : (surface_w += 1) {
                const want = oldFitted(lw, shown, true, surface_w);
                const solved = solveFor(&spec, surface_w);
                try std.testing.expectEqualSlices(f32, &want.lanes, &solved);
                try std.testing.expectEqual(want.table, rowWidth(&spec, solved));
                // The section's clamp gives the row that width, so the engine's solve against
                // the row's content box is the solve above.
                try std.testing.expectEqual(want.table, clampedTable(&spec, surface_w));
            }
        }
    }
    // Spot values, Act II at 560 (window 560: the 534 surface): WHAT CHANGES gives 10.
    const spec = trackSpec(act_two_widths, shownAt(.w560));
    try std.testing.expectEqualSlices(f32, &.{ 118, 112, 0, 122, 76, 54 }, &solveFor(&spec, 534));
    try std.testing.expectEqual(@as(f32, 526), clampedTable(&spec, 534));
    // Act I at 440 (TIME and WHAT CHANGES dropped): 358 at most, the slack outside; 274 + 36
    // at the floors, which a 320 window's 294 surface cannot hold.
    const a1_440 = extentOf(&trackSpec(.{}, shownAt(.w440)));
    try std.testing.expectEqual(@as(f32, 358), a1_440.max);
    try std.testing.expectEqual(@as(f32, 310), a1_440.min);
    try std.testing.expectEqual(@as(f32, 310), clampedTable(&trackSpec(.{}, shownAt(.w440)), 294));
}

test "a lane dropped at a width class is a hidden track" {
    const at_560 = trackSpec(.{}, shownAt(.w560));
    try std.testing.expect(at_560[@backingInt(Lane.time)].hidden and !at_560[@backingInt(Lane.effect)].hidden);
    const at_440 = trackSpec(.{}, shownAt(.w440));
    try std.testing.expect(at_440[@backingInt(Lane.time)].hidden and at_440[@backingInt(Lane.effect)].hidden);
    for (trackSpec(.{}, shownAt(.full))) |t| try std.testing.expect(!t.hidden);
}

test "the cost cell is the order, then the energy" {
    var cat = try roster.load(std.testing.allocator, roster.shipped, null);
    defer cat.deinit();
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("10m", orderText(1, &buf, cat.good("spear").?));
    try std.testing.expectEqualStrings("5e", energyText(&buf, cat.good("spear").?));
    try std.testing.expectEqualStrings("36me 24fu 20mi", orderText(2, &buf, cat.good("cold_store").?));
    try std.testing.expectEqualStrings("Split wood", needsName(&cat, cat.good("work_gloves").?));
    try std.testing.expectEqualStrings("a tool", needsName(&cat, cat.good("sandals").?));
}

test "recipeType reads what the good does" {
    var cat = try roster.load(std.testing.allocator, roster.shipped, null);
    defer cat.deinit();
    try std.testing.expectEqualStrings("generator", recipeType(cat.good("garden_bed").?));
    try std.testing.expectEqualStrings("storage", recipeType(cat.good("root_cellar").?));
    try std.testing.expectEqualStrings("comfort", recipeType(cat.good("leaf_bed").?));
    try std.testing.expectEqualStrings("tool", recipeType(cat.good("sandals").?));
}
