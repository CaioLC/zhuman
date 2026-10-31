//! `research_board` — Act II's RESEARCH tab (`act-ii.html` `#view-research`): the hex board of
//! the sixty technologies around the neutral foundation, a camera over it (wheel zoom about the
//! pointer, drag pan past four pixels, the − / % / + / reset controls), the filter chips and
//! the search, the hover tooltip, the detail aside for the selected tile and its RESEARCH →,
//! and the legend and hints beneath.
//!
//! The board is drawn as SVG is in the prototype: a 620-unit square fitted into the pane
//! (`meet`), with the camera `p·zoom + pan` inside it. Every tile is a square node in board
//! units carrying unit-square meshes — the fill, the stroke, the resource rails, the material
//! dots, the research marker — so the meshes stay isotropic and strokes keep their screen
//! width at any zoom (`vector-effect: non-scaling-stroke`). A tile's hit box is its hexagon.
//!
//! The states come from the agent's `comp.Research`, the costs and copy from the catalog;
//! the view never recomputes adjacency (`grid/board`). It reports a RESEARCH → press, and the
//! page pays and establishes the tile.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const El = uic.elements.El;
const Color = uic.Color;
const roster = ha.roster;
const hex = ha.grid.hex;
const ResearchState = uic.UiState.ResearchState;

// ---- the board's geometry, in board units (the prototype's 620×620 viewBox) ----------------
const board_units: f32 = 620;
const center: f32 = 310;
const hex_size: f32 = 31;
const visible_size: f32 = hex_size - 1.5;
const rail_size: f32 = visible_size - 2.6;
/// A tile's square box: twice the layout radius, so neighbours' boxes touch.
const box_units: f32 = 2 * hex_size;
const sector_radius: f32 = 274;
const sqrt3: f32 = 1.7320508;

const min_zoom: f32 = 0.75;
const max_zoom: f32 = 2.5;
const zoom_step: f32 = 0.2;
const wheel_factor: f32 = 1.12;

const detail_w: f32 = 238;
const detail_pad: f32 = 10;
const detail_inner: f32 = detail_w - detail_pad;

/// The six wedges' resources, in the board's clockwise order from 3 o'clock.
const wedge_res = [6]roster.Resource{ .food, .water, .fuel, .metal, .minerals, .biomass };
const eras = [_][]const u8{ "", "CRUDE PRODUCTION", "SETTLEMENT WORKS", "CRAFT", "EARLY INDUSTRIAL" };

// The board's own inks, outside the terminal palette (`prototype.css` `.hex-*`).
const neutral = uic.rgb(0x55, 0x5b, 0x63);
const label_default = uic.rgb(0xd4, 0xce, 0xc0);
const label_available = uic.rgb(0xf2, 0xf4, 0xf6);
const label_researched = uic.rgb(0x15, 0x18, 0x1d);
const marker_edge = uic.rgb(0x11, 0x13, 0x18);
const research_edge = uic.rgb(0xd8, 0xd0, 0xbd);
const hub_fill = uic.rgb(0xd0, 0xbd, 0x91);
const hub_edge = uic.rgb(0xf1, 0xe2, 0xc5);
const sector_ink = uic.rgb(0xab, 0xb0, 0xb8);
const pane_edge = uic.rgb(0x2d, 0x31, 0x38);
const pane_top = uic.rgb(0x19, 0x1c, 0x21);
const pane_mid = uic.rgb(0x11, 0x13, 0x18);
const pane_low = uic.rgb(0x15, 0x18, 0x1d);

/// What the board reads: the catalog, the agent's board and its research balances.
pub const Board = struct {
    cat: *const roster.Catalog,
    research: *const ha.comp.Research,
    /// Held amounts by wedge (`wedge_res` order).
    held: [6]f32,
};

pub const Result = struct {
    /// RESEARCH → was pressed on this tile (a catalog index) and it is affordable.
    research: ?u16 = null,
};

const Filter = enum(u8) { all = 0, available = 1, researched = 2 };

// ---- pure board math ---------------------------------------------------------------------

const Pt = struct { x: f32, y: f32 };

fn axialToBoard(q: i32, r: i32) Pt {
    const fq: f32 = @floatFromInt(q);
    const fr: f32 = @floatFromInt(r);
    return .{ .x = center + sqrt3 * hex_size * (fq + fr / 2), .y = center + 1.5 * hex_size * fr };
}

/// A tile's resource identity: one wedge (pure) or two adjacent (hybrid).
const Kind = struct { hybrid: bool, res: [2]u3, len: u2, ring: u32 };

fn kindOf(c: roster.Coord) Kind {
    const a = hex.Axial{ .q = c.q, .r = c.r };
    const n = hex.ring(a);
    return switch (hex.classify(a)) {
        .foundation => .{ .hybrid = false, .res = .{ 0, 0 }, .len = 0, .ring = 0 },
        .pure => |p| .{ .hybrid = false, .res = .{ @intFromEnum(p.wedge), 0 }, .len = 1, .ring = n },
        .hybrid => |h| .{ .hybrid = true, .res = .{ @intFromEnum(h.wedge), @intFromEnum(h.wedge.next()) }, .len = 2, .ring = n },
    };
}

fn wedgeColor(ctx: *uic.UiCtx, w: u3) Color {
    const r = ctx.res.view.resources;
    return switch (w) {
        0 => r.food,
        1 => r.water,
        2 => r.fuel,
        3 => r.metal,
        4 => r.minerals,
        else => r.biomass,
    };
}

fn baseStroke(ctx: *uic.UiCtx, k: Kind) Color {
    const a = wedgeColor(ctx, k.res[0]);
    return if (k.hybrid) uic.mix(a, wedgeColor(ctx, k.res[1]), 0.5) else a;
}

fn baseFill(ctx: *uic.UiCtx, k: Kind) Color {
    return uic.mix(baseStroke(ctx, k), neutral, 0.28);
}

/// A unit-square point `d` board units from the box centre at `deg` degrees.
fn polar(deg: f32, radius: f32) uic.Point {
    const a = deg * std.math.pi / 180.0;
    return .{ .x = 0.5 + @cos(a) * radius / box_units, .y = 0.5 + @sin(a) * radius / box_units };
}

/// The six vertices of a pointy-top hex of `radius`, from -30° clockwise.
fn hexPts(radius: f32) [6]uic.Point {
    var out: [6]uic.Point = undefined;
    for (&out, 0..) |*p, i| p.* = polar(-30 + 60 * @as(f32, @floatFromInt(i)), radius);
    return out;
}

fn angleDistance(a: f32, b: f32) f32 {
    return @abs(@mod(a - b + 540, 360) - 180);
}

/// The open three-edge rail on the side of a hybrid tile nearer wedge `w` (the other is `o`).
fn hybridRail(w: u3, o: u3) [4]uic.Point {
    const verts = hexPts(rail_size);
    var in_set: [6]bool = @splat(false);
    for (0..6) |e| {
        const ea: f32 = @as(f32, @floatFromInt(e)) * 60;
        in_set[e] = angleDistance(ea, @as(f32, @floatFromInt(w)) * 60) < angleDistance(ea, @as(f32, @floatFromInt(o)) * 60);
    }
    var start: usize = 0;
    for (0..6) |e| if (in_set[e] and !in_set[(e + 5) % 6]) {
        start = e;
    };
    var out: [4]uic.Point = undefined;
    for (&out, 0..) |*p, step| p.* = verts[(start + step) % 6];
    return out;
}

/// A circle of `radius` board units centred `(dx, dy)` from the box centre, as a 14-gon.
fn circlePts(dx: f32, dy: f32, radius: f32) [14]uic.Point {
    var out: [14]uic.Point = undefined;
    for (&out, 0..) |*p, i| {
        const a = @as(f32, @floatFromInt(i)) * 2 * std.math.pi / 14.0;
        p.* = .{ .x = 0.5 + (dx + @cos(a) * radius) / box_units, .y = 0.5 + (dy + @sin(a) * radius) / box_units };
    }
    return out;
}

/// The camera mapping board units to the pane's local device px: the 620 square fitted into
/// the pane, then `p·zoom + pan`.
const Camera = struct {
    k: f32,
    ox: f32,
    oy: f32,
    zoom: f32,
    pan_x: f32,
    pan_y: f32,

    fn of(w: f32, h: f32, st: *const ResearchState) Camera {
        const k = @min(w, h) / board_units;
        return .{ .k = k, .ox = (w - board_units * k) / 2, .oy = (h - board_units * k) / 2, .zoom = st.zoom, .pan_x = st.pan_x, .pan_y = st.pan_y };
    }
    fn x(c: Camera, bx: f32) f32 {
        return c.ox + (bx * c.zoom + c.pan_x) * c.k;
    }
    fn y(c: Camera, by: f32) f32 {
        return c.oy + (by * c.zoom + c.pan_y) * c.k;
    }
    /// Device px per board unit after zoom.
    fn unit(c: Camera) f32 {
        return c.k * c.zoom;
    }
};

/// A tile value that eases to `target` over `board_s` when its target changes, from where it
/// stood. `prev` holds the last target (negative: first frame, which simply sits there). A
/// finished transition gives its slot back, so the board never holds the registry's table.
fn tweened(ctx: *uic.UiCtx, id: u64, prev: *f32, target: f32) f32 {
    const reg = &ctx.res.tween;
    if (prev.* >= 0 and prev.* != target) reg.from(id, reg.value(id, prev.*), target, ha.tokens.dur_board_s);
    prev.* = target;
    const v = reg.value(id, target);
    if (v == target) reg.release(id);
    return v;
}

/// Zoom to `next` about `focus` (viewBox units), keeping that point still.
fn zoomAbout(st: *ResearchState, next: f32, fx: f32, fy: f32) void {
    const target = std.math.clamp(next, min_zoom, max_zoom);
    if (@abs(target - st.zoom) < 0.001) return;
    const ratio = target / st.zoom;
    st.pan_x = fx - (fx - st.pan_x) * ratio;
    st.pan_y = fy - (fy - st.pan_y) * ratio;
    st.zoom = target;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn ringOf(t: *const roster.Technology) u32 {
    return t.coord.ring();
}

/// The tiles on a strictly higher ring that touch `t`.
fn outward(cat: *const roster.Catalog, i: usize, out: *[6]u16) []u16 {
    const c = cat.technologies[i].coord;
    var buf: [6]hex.Axial = undefined;
    const ns = hex.neighbors(.{ .q = c.q, .r = c.r }, &buf);
    var n: usize = 0;
    for (ns) |nbr| {
        if (hex.ring(nbr) <= c.ring()) continue;
        for (cat.technologies, 0..) |t, j| if (t.coord.q == nbr.q and t.coord.r == nbr.r) {
            out[n] = @intCast(j);
            n += 1;
        };
    }
    return out[0..n];
}

fn heldOf(b: Board, r: roster.Resource) f32 {
    for (wedge_res, 0..) |wr, i| if (wr == r) return b.held[i];
    return 0;
}

fn costText(a: std.mem.Allocator, t: *const roster.Technology) ![]const u8 {
    if (t.cost.len == 0) return "CARRIED FROM ACT I";
    var out: std.ArrayList(u8) = .empty;
    for (t.cost, 0..) |line, i| {
        if (i > 0) try out.appendSlice(a, " \u{00b7} ");
        const r = roster.Catalog.resource(line.item) orelse continue;
        try out.appendSlice(a, try a.print("{} {s}", .{ @as(u32, @intFromFloat(@round(line.n))), try std.ascii.allocUpperString(a, r.labelIn(2)) }));
    }
    return out.items;
}

/// The cost of tile `t` as the log line names it (`8 FOOD · 6 BIOMASS`).
pub fn costLine(a: std.mem.Allocator, t: *const roster.Technology) ![]const u8 {
    return costText(a, t);
}

fn deficitText(a: std.mem.Allocator, b: Board, t: *const roster.Technology) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (t.cost) |line| {
        const r = roster.Catalog.resource(line.item) orelse continue;
        const need = @round(line.n);
        const have = @floor(heldOf(b, r));
        if (have >= need) continue;
        if (out.items.len > 0) try out.appendSlice(a, " \u{00b7} ");
        try out.appendSlice(a, try a.print("{} {s}", .{ @as(u32, @intFromFloat(need - have)), try std.ascii.allocUpperString(a, r.labelIn(2)) }));
    }
    return if (out.items.len == 0) null else out.items;
}

fn domainText(a: std.mem.Allocator, k: Kind, sep: []const u8, lower: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (k.res[0..k.len], 0..) |w, i| {
        if (i > 0) try out.appendSlice(a, sep);
        const name = wedge_res[w].labelIn(2);
        try out.appendSlice(a, if (lower) try std.ascii.allocLowerString(a, name) else name);
    }
    return out.items;
}

// ---- small chrome --------------------------------------------------------------------------

fn hrule(parent: El, id: []const u8, w: ui_size) !void {
    try parent.leaf(id, .{ .w = w, .h = .{ .fixed = 1 } }, .{style.rule_fill});
}
const ui_size = uic.SizeRule;

/// Centre content in `box` on both axes: a column packs it at the vertical middle (a row's
/// cross alignment only spans its line), and a full-width row centres it across.
fn centreIn(box: El) !El {
    box.set(.{ .flow = .{ .dir = .column, .main = .center, .cross = .start } }, .{});
    const row = try box.box("centre", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children,
        .flow = .{ .dir = .row, .main = .center, .cross = .center },
    }, .{});
    return row;
}

/// A text box centred on the pane-local device point `(x, y)`.
fn centred(parent: El, id: []const u8, i: usize, str: []const u8, x: f32, y: f32, font: f32, ink: Color, tracking: f32) !void {
    const scale = parent.ctx.res.view.scale;
    const w = 120 * scale;
    const h = @max(8, font * 2.4) * scale;
    const box = try parent.item(id, i);
    _ = box.with_layout(.top_left).with_offset_px(x - w / 2, y - h / 2).with_size_px(.{ .fixed = w }, .{ .fixed = h })
;
    try (try centreIn(box)).label("t", str, .{Style{ .font = font, .text = ink, .tracking = tracking }});
}

/// A `.board-view-button`. Returns its click.
fn viewButton(parent: El, id: []const u8, label: []const u8, name: []const u8, enabled: bool, min_w: f32, rest: Color, value: ?[]const u8) !bool {
    const th = parent.ctx.res.view.theme;
    const b = try parent.box(id, .{ .w = .{ .fixed = min_w }, .h = .{ .fixed = 22 } }, .{});
    const q = b.control(.{ .enabled = enabled, .name = name, .role = .button, .value = value });
    const hot = enabled and (q.hover_focus());
    b.set(.{}, .{Style{ .outline_ink = if (hot) .line2 else .bg }});
    try (try centreIn(b)).label("t", label, .{Style{ .font = 10, .text = if (hot) th.fg else rest }});
    if (!enabled) _ = b.with_opacity(0.32);
    return q.clicked and enabled;
}

/// A `.chip`. Returns its click.
fn chip(parent: El, id: []const u8, label: []const u8, pressed: bool) !bool {
    const b = try parent.box(id, .{ .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row } }, .{});
    const q = b.control(.{ .name = label, .role = .radio, .checked = pressed, .selected = pressed });
    try b.label("t", label, .{Style{ .font = 11, .ink = if (pressed) .acc else .dim, .hot = .{ .ink = .acc, .when = .hover_focus } }});
    return q.clicked;
}

fn detailRow(parent: El, i: usize, name: []const u8, value: []const u8) !void {
    const row = try parent.boxi("row", i, .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children,
        .flow = .{ .dir = .row, .main = .space_between, .cross = .baseline }, .gap = 6,
    }, .{});
    try row.label("name", name, .{Style{ .font = 9, .ink = .fg }});
    try row.label("value", value, .{style.fine_print});
}

fn detailSection(parent: El, id: []const u8, heading: []const u8) !El {
    const sec = try parent.box(id, .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
    }, .{style.pad_each(11, 0, 0, 0)});
    try hrule(sec, "rule", .{ .pct_of_parent = 1.0 });
    (try sec.text("h", heading)).set(.{ .margin = .{ .before = 8, .after = 6 } }, .{Style{ .font = 9, .tracking = 0.07, .ink = .dim }});
    const list = try sec.box("list", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
        .gap = 5,
    }, .{});
    return list;
}

/// A fixture's opening for the board: the selected tile (by id), the filter, the camera, a
/// search, and whether the board holds focus.
pub const Seed = struct {
    select: ?[]const u8 = null,
    filter: u8 = 0,
    zoom: f32 = 1,
    pan_x: f32 = 0,
    pan_y: f32 = 0,
    query: []const u8 = "",
    /// Pin the tooltip over this tile (by id), as though hovered.
    hover: ?[]const u8 = null,
    /// Give the board keyboard focus.
    focus: bool = false,
};

/// Apply `seed` to the board's state and its search (a fixture's first frame).
pub fn applySeed(cat: *const roster.Catalog, st: *ResearchState, query_owner: El, seed: Seed) void {
    st.* = .{ .seeded = true, .filter = seed.filter, .zoom = seed.zoom, .pan_x = seed.pan_x, .pan_y = seed.pan_y };
    if (seed.select) |id| st.selected = cat.techIndex(id);
    if (seed.hover) |id| st.pin_tip = cat.techIndex(id);
    st.want_focus = seed.focus;
    const ed = query_owner.state(uic.UiState.TextInputState);
    _ = ed.clear();
    if (seed.query.len > 0) _ = ed.insert(seed.query);
}

// ---- the view ------------------------------------------------------------------------------

/// Build the RESEARCH view into `parent` (it fills it). `query_owner` holds the search text
/// on an always-built node; `st` is the board's persistent state.
pub fn research_board(parent: El, id: []const u8, b: Board, st: *ResearchState, query_owner: El) !Result {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const a = ctx.arena;
    const scale = ctx.res.view.scale;
    const cat = b.cat;
    const states = b.research.state[0..cat.technologies.len];
    var result: Result = .{};

    if (!st.seeded) {
        st.* = .{ .seeded = true };
        if (cat.techIndex("gamekeeping")) |gi| {
            if (states[gi] != .locked) st.selected = gi;
        }
    }
    if (st.selected) |s| if (s >= states.len or states[s] == .locked) {
        st.selected = null;
    };

    const view = try parent.div(id);
    // Stacked (≤760) the detail drops under a 560px board and the view takes its height.
    const stack = @import("./terminal.zig").stacked(ctx);
    view.set(.{
        .w = .{ .pct_of_parent = 1.0 }, .h = if (stack) .fit_children else .{ .pct_of_parent = 1.0 },
        .flow = .{ .dir = .column, .cross = .start },
    }, .{style.pad_each(4, 0, 0, 0)});

    // --- topbar: RESEARCH and its question | the chips and the search ----------------------
    const topbar_box = try view.div("topbar_box");
    // `.structure-topbar { align-items: end }`: a column packs the row at the box's foot (a
    // row's cross alignment only spans its own line).
    topbar_box.set(.{
        .w = .{ .pct_of_parent = 1.0 },
        .h = if (ctx.res.view.metrics.width_class.atMost(.w560)) .fit_children else .{ .fixed = 44 },
        .flow = .{ .dir = .column, .main = .end, .cross = .start }, .margin = .{ .after = 8 },
    }, .{});
    const topbar = try topbar_box.div("topbar");
    // Below 560 the toolbar drops under the title and the question goes (`.structure-topbar`).
    const narrow = ctx.res.view.metrics.width_class.atMost(.w560);
    if (narrow) {
        topbar.set(.{ .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start }, .gap = 8 }, .{});
    } else {
        topbar.set(.{
            .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children,
            .flow = .{ .dir = .row, .main = .space_between, .cross = .center },
        }, .{});
    }
    const title = try topbar.div("title");
    // The title takes what the tools leave and clips its question (`.structure-title p`
    // ellipsizes), so a narrow surface never runs it under the chips.
    title.set(.{
        .w = if (narrow) .fit_children else .grow, .h = .fit_children,
        .flow = .{ .dir = .row, .cross = .baseline }, .gap = 12, .overflow = .clip,
    }, .{});
    const h = try title.text("h", "RESEARCH");
    h.set(.{}, .{ style.heading, style.ink(.fg) });
    if (!narrow) {
        // `.structure-title p { text-overflow: ellipsis }`: the question is a cell of what the
        // heading leaves. It grows into the title row's remainder after the heading and the
        // row's 12px gap, and reserves no width of its own, so it never widens the title.
        const question = "What exists, and what does it take?";
        const p_style = style.note;
        (try title.text_fit("p", question, .{ .cell_fill = .ellipsis })).set(.{ .w = .grow, .h = .content }, .{p_style});
    }
    const tools = try topbar.box("tools", .{
        .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center }, .gap = 9,
    }, .{});
    const chips = try tools.box("chips", .{
        .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center }, .gap = 8,
    }, .{});
    const filter: Filter = @enumFromInt(@min(st.filter, 2));
    if (try chip(chips, "researched", "researched", filter == .researched)) st.filter = @intFromEnum(Filter.researched);
    if (try chip(chips, "available", "available", filter == .available)) st.filter = @intFromEnum(Filter.available);
    if (try chip(chips, "all", "all", filter == .all)) st.filter = @intFromEnum(Filter.all);
    const field = try uic.text_input_look(tools, "search", "find a technology", if (narrow) 110 else 136, query_owner, .{ .font = 10, .placeholder = th.line2, .pad_x = 6, .pad_y = 5 });
    _ = field;
    const query = std.mem.trim(u8, query_owner.state(uic.UiState.TextInputState).text(), " ");
    try hrule(view, "top_rule", .{ .pct_of_parent = 1.0 });

    // --- layout: the board pane | the detail aside -----------------------------------------
    const layout = try view.box("layout", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = if (stack) .fit_children else .grow,
        .flow = .{ .dir = if (stack) .column else .row, .cross = .start }, .gap = 12,
    }, .{});
    const pane = try layout.box("pane", .{
        .w = if (stack) .{ .pct_of_parent = 1.0 } else .grow,
        .h = if (stack) .{ .fixed = 560 } else .{ .pct_of_parent = 1.0 }, .overflow = .clip,
    }, .{});
    const aside = try layout.box("aside", .{
        .w = if (stack) .{ .pct_of_parent = 1.0 } else .{ .fixed = detail_w },
        .h = if (stack) .fit_children else .{ .pct_of_parent = 1.0 },
        .flow = .{ .dir = if (stack) .column else .row, .cross = .start },
    }, .{});

    // The pane is the board's one focus stop: arrows walk the tiles, Escape clears.
    const pq = pane.control(.{ .name = "Research board", .role = .group, .cursor = .grab });
    if (st.want_focus) {
        st.want_focus = false;
        _ = ctx.requestFocus(pane.get().key);
    }
    ctx.res.commands.registerGrid(pane.get().key);
    ctx.res.commands.registerWheel(pane.get().key);
    if (pq.focused and st.selected != null) ctx.res.commands.registerEscape(pane.get().key);
    if (pq.dismissed) st.selected = null;

    (try pane.gradient("ground", .vertical, &.{
        .{ .pos = 0, .color = pane_top },
        .{ .pos = 0.56, .color = pane_mid },
        .{ .pos = 1, .color = pane_low },
    }, 1.0)).set(.{
        .anchor = .top_left, .w = .{ .pct_of_parent = 1.0 }, .h = .{ .pct_of_parent = 1.0 },
        .pass_through = true,
    }, .{});
    try pane.leaf("edge", .{
        .anchor = .top_left, .w = .{ .pct_of_parent = 1.0 }, .h = .{ .pct_of_parent = 1.0 },
    }, .{Style{ .outline_color = if (pq.focus_visible) th.acc else pane_edge }});

    // Which tiles the filter and the search leave lit.
    var faded: [roster.max_techs]bool = @splat(false);
    for (cat.technologies, 0..) |t, i| {
        const s = states[i];
        const out = switch (filter) {
            .researched => s != .researched,
            .available => s == .locked,
            .all => false,
        };
        const dim = query.len > 0 and (s == .locked or !containsIgnoreCase(t.name, query));
        faded[i] = out or dim;
    }

    // Keyboard: arrows move the selection to the best-scoring lit tile in that direction.
    const nav: ?Pt = if (pq.nav_left) .{ .x = -1, .y = 0 } else if (pq.nav_right) .{ .x = 1, .y = 0 } else if (pq.nav_up) .{ .x = 0, .y = -1 } else if (pq.nav_down) .{ .x = 0, .y = 1 } else null;
    if (nav) |d| {
        const from: Pt = if (st.selected) |s| axialToBoard(cat.technologies[s].coord.q, cat.technologies[s].coord.r) else .{ .x = center, .y = center };
        var best: ?u16 = null;
        var best_score: f32 = std.math.inf(f32);
        for (cat.technologies, 0..) |t, i| {
            if (states[i] == .locked or faded[i] or (st.selected != null and st.selected.? == i)) continue;
            const p = axialToBoard(t.coord.q, t.coord.r);
            const dx = p.x - from.x;
            const dy = p.y - from.y;
            const forward = dx * d.x + dy * d.y;
            if (forward <= 0) continue;
            const score = @abs(dx * d.y - dy * d.x) * 3 + @sqrt(dx * dx + dy * dy);
            if (score < best_score) {
                best_score = score;
                best = @intCast(i);
            }
        }
        if (best) |n| st.selected = n;
    }

    const pointer = &ctx.res.input.pointer;
    const prior = pane.prior_geometry();
    var hovered: ?u16 = null;
    if (prior) |g| {
        const r = g.rect;
        var cam = Camera.of(r.w, r.h, st);

        // Wheel zoom about the pointer.
        if (pq.wheel and pointer.wheel.y != 0) {
            const fx = (pointer.position.x - r.x - cam.ox) / cam.k;
            const fy = (pointer.position.y - r.y - cam.oy) / cam.k;
            zoomAbout(st, st.zoom * (if (pointer.wheel.y > 0) wheel_factor else 1 / wheel_factor), fx, fy);
        }
        // Drag pan past the threshold; the pressed tile does not take the click after a pan.
        if (pq.pressed and !st.drag.active) {
            st.drag.beginScaled(pointer.position, scale);
            st.drag_pan_x = st.pan_x;
            st.drag_pan_y = st.pan_y;
            _ = ctx.capturePointer(pane.get().key);
        }
        if (st.drag.active) {
            if (!pointer.buttons.primary.held or ctx.res.input.cancelled) {
                _ = st.drag.end();
                _ = ctx.releasePointerCapture(pane.get().key);
            } else {
                const upd = st.drag.update(pointer.position);
                if (upd.dragging) {
                    st.pan_x = st.drag_pan_x + (pointer.position.x - st.drag.origin.x) / cam.k;
                    st.pan_y = st.drag_pan_y + (pointer.position.y - st.drag.origin.y) / cam.k;
                    ctx.res.cursor.request(.grabbing);
                }
            }
        }
        cam = Camera.of(r.w, r.h, st);
        const panning = st.drag.active and st.drag.crossed;

        // Sector labels, then the hub, then the tiles.
        const labels = try pane.box("sectors", .{
            .anchor = .top_left, .w = .{ .pct_of_parent = 1.0 }, .h = .{ .pct_of_parent = 1.0 },
            .pass_through = true,
        }, .{});
        const sector_font = 9 * cam.unit() / scale;
        for (0..6) |w| {
            const ang = @as(f32, @floatFromInt(w)) * 60 * std.math.pi / 180.0;
            const bx = center + @cos(ang) * sector_radius;
            const by = center + @sin(ang) * sector_radius;
            try centred(labels, "s", w, try std.ascii.allocUpperString(a, wedge_res[w].labelIn(2)), cam.x(bx), cam.y(by), sector_font, sector_ink, 0.075);
        }

        const side = box_units * cam.unit();
        const px_unit = scale / side; // one screen px in a box's unit square
        const tiles = try pane.box("tiles", .{ .anchor = .top_left, .w = .{ .pct_of_parent = 1.0 }, .h = .{ .pct_of_parent = 1.0 } }, .{});
        {
            const hub = try tiles.div("hub");
            _ = hub.with_layout(.top_left).with_offset_px(cam.x(center) - side / 2, cam.y(center) - side / 2).with_size_px(.{ .fixed = side }, .{ .fixed = side }).pass_through();
            const pts = hexPts(visible_size);
            (try hub.polygon("fill", &pts, hub_fill, 1)).set(.{
                .anchor = .top_left, .w = .{ .pct_of_parent = 1.0 }, .h = .{ .pct_of_parent = 1.0 },
            }, .{});
            (try hub.polyline("edge", &pts, 0.675 * px_unit, true, .butt, hub_edge, 1)).set(.{
                .anchor = .top_left, .w = .{ .pct_of_parent = 1.0 }, .h = .{ .pct_of_parent = 1.0 },
            }, .{});
        }

        var out_buf: [6]u16 = undefined;
        const outs: []u16 = if (st.selected) |s| outward(cat, s, &out_buf) else out_buf[0..0];
        const label_font = 6.8 * cam.unit() / scale;
        const fill_pts = hexPts(visible_size);

        for (cat.technologies, 0..) |*t, i| {
            const s = states[i];
            const k = kindOf(t.coord);
            const p = axialToBoard(t.coord.q, t.coord.r);
            const tile = try tiles.item("tile", i);
            _ = tile.with_layout(.top_left).with_offset_px(cam.x(p.x) - side / 2, cam.y(p.y) - side / 2).with_size_px(.{ .fixed = side }, .{ .fixed = side });
            // The filter and search fade rides `board_s` (`.tech-tile { transition: opacity }`).
            tile.set(.{ .opacity = tweened(ctx, tile.get().key ^ 0xfade, &st.fade_prev[i], if (faded[i]) 0.11 else 1) }, .{});
            const live = s != .locked;
            var hot = false;
            if (live) {
                _ = tile.hit_test(hexHit);
                const tq = tile.query();
                hot = tq.hovering and !panning;
                if (hot) {
                    hovered = @intCast(i);
                    ctx.res.cursor.request(.pointer);
                }
                if (tq.clicked and !panning) {
                    if (st.selected == null or st.selected.? != i) st.last = null;
                    st.selected = @intCast(i);
                }
            }
            const selected = st.selected != null and st.selected.? == i;
            const is_out = live and std.mem.findScalar(u16, outs, @intCast(i)) != null;

            const fill_op: f32 = tweened(ctx, tile.get().key ^ 0xf111, &st.fill_prev[i], switch (s) {
                .locked => 0.24,
                .available => if (selected) 0.9 else if (hot) 0.84 else 0.66,
                .researched => 1,
            });
            const stroke_w: f32 = if (selected) 2 else if (hot) 1.7 else switch (s) {
                .locked => 1,
                .available => 1.25,
                .researched => 1.35,
            };
            const stroke = if (is_out) th.warn else if (selected or hot) th.fg else baseStroke(ctx, k);
            const full: uic.SizeRule = .{ .pct_of_parent = 1.0 };
            (try tile.polygon("fill", &fill_pts, baseFill(ctx, k), fill_op)).set(.{
                .anchor = .top_left, .w = full, .h = full, .pass_through = true,
            }, .{});
            if (is_out) {
                // `stroke-dasharray: 2 2`, edge by edge.
                const dashes = try tile.box("dashes", .{ .anchor = .top_left, .w = full, .h = full, .pass_through = true }, .{});
                const edge_px = visible_size * cam.unit();
                const per_edge: usize = @max(1, @as(usize, @intFromFloat(edge_px / (4 * scale))));
                var n: usize = 0;
                for (0..6) |e| {
                    const v0 = fill_pts[e];
                    const v1 = fill_pts[(e + 1) % 6];
                    for (0..per_edge) |j| {
                        const t0 = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(per_edge));
                        const t1 = t0 + 0.5 / @as(f32, @floatFromInt(per_edge));
                        const seg = [2]uic.Point{
                            .{ .x = v0.x + (v1.x - v0.x) * t0, .y = v0.y + (v1.y - v0.y) * t0 },
                            .{ .x = v0.x + (v1.x - v0.x) * t1, .y = v0.y + (v1.y - v0.y) * t1 },
                        };
                        (try (try dashes.item("d", n)).with_layout(.top_left).with_size(full, full).polyline("l", &seg, stroke_w / 2 * px_unit, false, .butt, stroke, 1)).set(.{
                            .anchor = .top_left, .w = full, .h = full,
                        }, .{});
                        n += 1;
                    }
                }
            } else {
                (try tile.polyline("edge", &fill_pts, stroke_w / 2 * px_unit, true, .butt, stroke, if (s == .locked) 0.52 else 1)).set(.{
                    .anchor = .top_left, .w = full, .h = full, .pass_through = true,
                }, .{});
            }

            // The resource rails: a full loop on a pure tile, a half on each side of a hybrid.
            const rail_op: f32 = if (selected or s == .researched) 1 else if (s == .available) 0.9 else 0.42;
            if (k.hybrid) {
                for (0..2) |ri| {
                    const pts = hybridRail(k.res[ri], k.res[1 - ri]);
                    (try (try tile.item("rail", ri)).with_layout(.top_left).with_size(full, full).polyline("l", &pts, 1.1 * px_unit, false, .butt, wedgeColor(ctx, k.res[ri]), rail_op)).set(.{
                        .anchor = .top_left, .w = full, .h = full, .pass_through = true,
                    }, .{});
                }
            } else {
                const pts = hexPts(rail_size);
                (try (try tile.item("rail", 0)).with_layout(.top_left).with_size(full, full).polyline("l", &pts, 1.1 * px_unit, true, .butt, wedgeColor(ctx, k.res[0]), rail_op)).set(.{
                    .anchor = .top_left, .w = full, .h = full, .pass_through = true,
                }, .{});
            }

            // The label: hidden on a locked silhouette.
            if (live and t.short.len > 0) {
                const lab = try tile.box("label", .{ .anchor = .top_left, .w = full, .h = full, .pass_through = true }, .{});
                try (try centreIn(lab)).label("t", t.short, .{Style{ .font = label_font, .tracking = -0.045, .text = if (s == .researched) label_researched else if (s == .available) label_available else label_default }});
            }

            // The material dots, and the research marker on an established tile.
            // The board's own rule (`grid/board.materialMarkers`), as wedge indices.
            var wbuf: [3]hex.Wedge = undefined;
            const wm = ha.grid.board.materialMarkers(t, &wbuf);
            var mat_buf: [3]u3 = undefined;
            for (wm, 0..) |w, j| mat_buf[j] = @intFromEnum(w);
            const mats = mat_buf[0..wm.len];
            const dot_op: f32 = switch (s) {
                .locked => 0.4,
                .available => 0.92,
                .researched => 1,
            };
            const spacing: f32 = 5.5;
            const start_x = -@as(f32, @floatFromInt(mats.len -| 1)) * spacing / 2;
            for (mats, 0..) |w, mi| {
                const dx = start_x + @as(f32, @floatFromInt(mi)) * spacing;
                const pts = circlePts(dx, 16, 2);
                const dot = try tile.boxi("dot", mi, .{ .anchor = .top_left, .w = full, .h = full, .pass_through = true }, .{});
                (try dot.polygon("f", &pts, wedgeColor(ctx, w), dot_op)).set(.{ .anchor = .top_left, .w = full, .h = full }, .{});
                (try dot.polyline("e", &pts, 0.375 * px_unit, true, .butt, marker_edge, dot_op)).set(.{
                    .anchor = .top_left, .w = full, .h = full,
                }, .{});
            }
            if (s == .researched) {
                const pts = circlePts(17, -16, 2.6);
                const mark = try tile.box("researched", .{ .anchor = .top_left, .w = full, .h = full, .pass_through = true }, .{});
                (try mark.polygon("f", &pts, marker_edge, 1)).set(.{ .anchor = .top_left, .w = full, .h = full }, .{});
                (try mark.polyline("e", &pts, 0.325 * px_unit, true, .butt, research_edge, 1)).set(.{
                    .anchor = .top_left, .w = full, .h = full,
                }, .{});
            }
        }

        // The tooltip follows the pointer over a lit tile (or sits over a fixture's pinned one,
        // until the pointer hovers a tile).
        if (hovered != null) st.pin_tip = null;
        const tip_at: ?u16 = hovered orelse st.pin_tip;
        if (tip_at) |hi| {
            const t = &cat.technologies[hi];
            const k = kindOf(t.coord);
            const tip = try pane.div("tooltip");
            const anchor: Pt = if (hovered != null) .{ .x = pointer.position.x - r.x, .y = pointer.position.y - r.y } else blk: {
                const p = axialToBoard(t.coord.q, t.coord.r);
                break :blk .{ .x = cam.x(p.x), .y = cam.y(p.y) };
            };
            const lx = @min(anchor.x + 12 * scale, r.w - 220 * scale);
            const ly = @max(4 * scale, anchor.y + 12 * scale);
            _ = tip.with_layout(.top_left).with_offset_px(lx, ly).with_size(.fit_children, .fit_children)
                .with_flow(.{ .dir = .column, .cross = .start })
                .with_style(.{ style.pad_sym(7, 5), Style{ .fill_ink = .panel, .outline_ink = .dim } }).pass_through();
            try tip.label("name", t.name, .{Style{ .font = 9, .ink = .acc }});
            try tip.label("line", try a.print("ring {} \u{00b7} {s} \u{00b7} {s}", .{ ringOf(t), try domainText(a, k, " + ", true), @tagName(states[hi]) }), .{Style{ .font = 9, .ink = .fg }});
        }
    }

    // The zoom controls, over the board's top-right corner.
    {
        const bar = try pane.box("camera", .{
            .anchor = .top_right, .offset = .{ .x = -7, .y = 7 }, .w = .fit_children, .h = .fit_children,
            .flow = .{ .dir = .row, .cross = .center }, .gap = 2,
        }, .{ style.pad(2), Style{ .fill_ink = .bg, .outline_ink = .line2 } });
        // The zoom buttons speak the level they leave the board at (`output aria-live`).
        const pct = try a.print("{}%", .{@as(u32, @intFromFloat(@round(st.zoom * 100)))});
        if (try viewButton(bar, "out", "-", "Zoom out", st.zoom > min_zoom + 0.001, 22, th.dim, pct)) zoomAbout(st, st.zoom - zoom_step, center, center);
        const level = try bar.box("level", .{ .w = .{ .fixed = 37 }, .h = .{ .fixed = 22 } }, .{});
        try (try centreIn(level)).label("t", pct, .{style.fine_print});
        if (try viewButton(bar, "in", "+", "Zoom in", st.zoom < max_zoom - 0.001, 22, th.dim, pct)) zoomAbout(st, st.zoom + zoom_step, center, center);
        const moved = @abs(st.zoom - 1) >= 0.001 or @abs(st.pan_x) >= 0.001 or @abs(st.pan_y) >= 0.001;
        if (try viewButton(bar, "reset", "reset", "Reset board pan and zoom", moved, 35, th.line2, null)) {
            st.zoom = 1;
            st.pan_x = 0;
            st.pan_y = 0;
        }
    }

    // --- the detail aside --------------------------------------------------------------------
    if (stack) {
        try hrule(aside, "rule", .{ .pct_of_parent = 1.0 });
    } else {
        try aside.leaf("rule", .{ .w = .{ .fixed = 1 }, .h = .{ .pct_of_parent = 1.0 } }, .{style.rule_fill});
    }
    // Stacked, the detail spans the page under the board (`.structure-detail` in one column).
    const inner = if (stack) @import("./terminal.zig").stackedWidth(ctx) else detail_inner;
    const detail = try aside.div("detail");
    // Beside the board, 9px past the 1px rule make the 10px inset; the 11px top is padding.
    detail.set(.{
        .w = .{ .fixed = inner }, .h = if (stack) .fit_children else .{ .pct_of_parent = 1.0 },
        .flow = .{ .dir = .column, .cross = .start }, .overflow = .clip,
        .margin = .{ .before = if (stack) 0 else detail_pad - 1 },
    }, .{style.pad_each(11, 0, 0, 0)});
    if (st.selected) |si| {
        const t = &cat.technologies[si];
        const k = kindOf(t.coord);
        const s = states[si];
        const ring = ringOf(t);
        (try detail.text("kicker", try a.print("RING {} \u{00b7} {s}", .{ ring, eras[@min(ring, 4)] }))).set(.{
            .margin = .{ .after = 3 },
        }, .{Style{ .font = 9, .tracking = 0.08, .ink = .dim }});
        (try detail.text("name", t.name)).set(.{ .margin = .{ .after = 8 } }, .{ style.heading, style.ink(.fg) });
        const tags = try detail.box("tags", .{
            .w = .{ .fixed = inner }, .h = .fit_children,
            .flow = .{ .dir = .row, .wrap = true, .cross = .center }, .gap = 5, .margin = .{ .after = 10 },
        }, .{});
        var tag_n: usize = 0;
        const tag_texts = [_][]const u8{
            if (k.hybrid) "HYBRID" else "PURE",
            try std.ascii.allocUpperString(a, wedge_res[k.res[0]].labelIn(2)),
            if (k.hybrid) try std.ascii.allocUpperString(a, wedge_res[k.res[1]].labelIn(2)) else "",
            try std.ascii.allocUpperString(a, @tagName(s)),
        };
        for (tag_texts) |tt| {
            if (tt.len == 0) continue;
            const tag = try tags.item("tag", tag_n);
            tag_n += 1;
            tag.set(.{ .w = .fit_children, .h = .fit_children }, .{ style.pad_sym(4, 1), Style{ .outline_ink = .line2 } });
            try tag.label("t", tt, .{Style{ .font = 8, .tracking = 0.05, .ink = .dim }});
        }

        // RESEARCH →, or what it lacks, between two rules.
        try hrule(detail, "a_rule", .{ .fixed = inner });
        const deficit = try deficitText(a, b, t);
        const can = s == .available and deficit == null;
        const label = if (s == .researched) "RESEARCHED" else if (deficit) |d| try a.print("NEEDS {s}", .{d}) else "RESEARCH \u{2192}";
        const btn = try detail.box("research", .{
            .w = .{ .fixed = inner }, .h = .{ .fixed = 34 }, .margin = .{ .before = 8, .after = 6 },
        }, .{});
        const bq = btn.control(.{ .enabled = can, .name = label, .role = .button });
        const lit = can and (bq.hot());
        btn.set(.{}, .{Style{ .outline_ink = if (!can) .line2 else if (lit) .acc else .fg }});
        try (try centreIn(btn)).label("t", label, .{ style.body, Style{ .ink = if (!can) .dim else if (lit) .acc else .fg } });
        if (can and bq.clicked) result.research = si;
        (try detail.text("cost", try costText(a, t))).set(.{ .margin = .{ .after = 9 } }, .{style.fine_print});
        try hrule(detail, "c_rule", .{ .fixed = inner });

        (try detail.text_fit("copy", t.effect, .fill)).set(.{ .margin = .{ .before = 11 } }, .{style.caption});

        const costs = try detailSection(detail, "costs", "RESEARCH COST");
        if (t.cost.len == 0) try detailRow(costs, 0, "Act I foundation", "paid");
        for (t.cost, 0..) |line, li| {
            const r = roster.Catalog.resource(line.item) orelse continue;
            try detailRow(costs, li, try a.print("{} {s}", .{ @as(u32, @intFromFloat(@round(line.n))), r.labelIn(2) }), try a.print("{} held", .{@as(i64, @intFromFloat(@floor(heldOf(b, r))))}));
        }

        const opens = try detailSection(detail, "opens", "ENABLES OUTWARD");
        var row_n: usize = 0;
        for (cat.goods) |g| if (g.tech) |gt| if (std.mem.eql(u8, gt, t.id)) {
            try detailRow(opens, row_n, try a.print("{s} \u{00b7} BUILD", .{g.name}), "enabled");
            row_n += 1;
        };
        for (cat.actions) |act| if (act.tech) |at| if (std.mem.eql(u8, at, t.id)) {
            try detailRow(opens, row_n, try a.print("{s} \u{00b7} ACTIONS", .{act.name}), "enabled");
            row_n += 1;
        };
        var ob: [6]u16 = undefined;
        const outs = outward(cat, si, &ob);
        for (outs) |o| {
            try detailRow(opens, row_n, cat.technologies[o].name, @tagName(states[o]));
            row_n += 1;
        }
        if (outs.len == 0) try detailRow(opens, row_n, "Act III frontier", "outside this board");
    } else {
        (try detail.text("kicker", "NO TECHNOLOGY SELECTED")).set(.{
            .margin = .{ .after = 3 },
        }, .{Style{ .font = 9, .tracking = 0.08, .ink = .dim }});
        (try detail.text("name", "Research board")).set(.{ .margin = .{ .after = 8 } }, .{ style.heading, style.ink(.fg) });
        try detail.label_fit("copy", "Choose an Available or Researched tile. Locked silhouettes reveal neither labels nor details.", .fill, .{style.caption});
    }

    // --- footer: the legend | the status and the hints ---------------------------------------
    try hrule(view, "foot_rule", .{ .pct_of_parent = 1.0 });
    const foot = try view.div("foot");
    // `.start`, not `space_between`: the legend grows into what the hints leave, so the hints
    // still sit flush right, and a packed run keeps the 10px gap out of the legend's share.
    // `.act-two #view-research .structure-footer { min-height: 44px }` is a border box (the
    // prototype is `box-sizing: border-box`) over its 1px top border and 6px top pad, which sit
    // outside the foot here as `foot_rule` and the foot's 6px top margin. The foot is
    // unpadded, so its floor is a content-box one: 44 - 6 = 38, as the board has always
    // reserved (strictly 37 once the border is also taken out).
    foot.set(.{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .min = .{ .h = 38 },
        .flow = .{ .dir = .row, .main = .start, .cross = .start }, .gap = 10, .margin = .{ .before = 6 },
    }, .{});
    const legend = try foot.div("legend");
    // `.structure-footer: 1fr auto`: the legend wraps in what the hints leave. Its grown width
    // is final before heights are solved, so the foot's fit height counts every legend line.
    legend.set(.{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .row, .wrap = true, .cross = .center }, .gap = 6 }, .{});
    for (wedge_res, 0..) |r, w| {
        const entry = try legend.boxi("r", w, .{
            .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center }, .gap = 4,
        }, .{});
        try entry.leaf("dot", .{
            .w = .{ .fixed = 7 }, .h = .{ .fixed = 7 }, .opacity = 0.8,
        }, .{Style{ .fill = wedgeColor(ctx, @intCast(w)) }});
        try entry.label("t", try std.ascii.allocUpperString(a, r.labelIn(2)), .{Style{ .font = 8.5, .ink = .dim }});
    }
    const hints = try foot.box("hints", .{
        .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center }, .gap = 10,
    }, .{});
    var counts = [3]u32{ 0, 0, 0 };
    for (states) |s| counts[@intFromEnum(s)] += 1;
    const status = if (st.selected) |si| blk: {
        const name = cat.technologies[si].name;
        if (st.last != null and st.last.? == si) {
            var suffix: std.ArrayList(u8) = .empty;
            var first = true;
            for (0..states.len) |i| if (st.newly & (@as(u64, 1) << @intCast(i)) != 0) {
                try suffix.appendSlice(a, if (first) " " else ", ");
                try suffix.appendSlice(a, cat.technologies[i].name);
                first = false;
            };
            if (!first) try suffix.appendSlice(a, " now available.");
            break :blk try a.print("{s} researched.{s}", .{ name, suffix.items });
        }
        break :blk try a.print("{s} selected \u{00b7} {} researched \u{00b7} {} available", .{ name, counts[2], counts[1] });
    } else "Select an available or researched technology";
    try hints.label("status", status, .{Style{ .font = 8.5, .ink = .line2 }});
    try hints.label("pan", "Wheel zoom / drag pan", .{Style{ .font = 8.5, .ink = .line2 }});
    try hints.label("keys", "Arrows move \u{00b7} Esc clears", .{Style{ .font = 8.5, .ink = .line2 }});

    return result;
}

/// A pointy-top hexagon inscribed in the tile's square box: the box is twice the layout
/// radius, the visible hex `visible_size` of it.
fn hexHit(rect: uic.Rect, x: f32, y: f32) bool {
    if (rect.w <= 0) return false;
    const radius = rect.w / 2 * (visible_size / hex_size);
    const dx = @abs(x - (rect.x + rect.w / 2));
    const dy = @abs(y - (rect.y + rect.h / 2));
    const half_w = radius * sqrt3 / 2;
    if (dx > half_w or dy > radius) return false;
    return dy <= radius - dx / sqrt3;
}

test "hybrid rails split the hex into two three-edge halves" {
    const a = hybridRail(0, 1);
    const b = hybridRail(1, 0);
    try std.testing.expect(a[0].x != b[0].x or a[0].y != b[0].y);
    // Both halves share their two end vertices, crossing between the two wedges.
    try std.testing.expectApproxEqAbs(a[3].x, b[0].x, 1e-5);
    try std.testing.expectApproxEqAbs(a[0].x, b[3].x, 1e-5);
}

test "the hexagon hit box rejects the box's corners" {
    const r = uic.Rect{ .x = 0, .y = 0, .w = 62, .h = 62 };
    try std.testing.expect(hexHit(r, 31, 31));
    try std.testing.expect(!hexHit(r, 2, 2));
    try std.testing.expect(hexHit(r, 31, 4));
}

test "zoom about a point keeps it still" {
    var st: ResearchState = .{};
    zoomAbout(&st, 2, 100, 50);
    // Board point under (100, 50) before: (100 - 0) / 1 = 100; after: (100 - pan) / 2.
    try std.testing.expectApproxEqAbs(@as(f32, 100), (100 - st.pan_x) / st.zoom, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 50), (50 - st.pan_y) / st.zoom, 1e-4);
    zoomAbout(&st, 9, 0, 0);
    try std.testing.expectEqual(max_zoom, st.zoom);
}
