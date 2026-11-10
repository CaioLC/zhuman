//! `actions_section` — the ACTIONS pane, the same template on every act: the heading with the
//! act's kind counts as two toggles, one search field, a toolbar with the hidden-tile summary
//! and the sort chips, and the held verbs then the held generators in two growing columns (one
//! at the compact breakpoint). A verb is an `action_tile`, a generator a `generator_tile`; the
//! tiles of one row stand as tall as its tallest (`rowHeight`), so a verb beside a regular
//! generator takes the generator's 87px, its content where an 81px verb keeps it. Only
//! the content differs per act (`Shelf`: which verbs and generators, the subtitle, the density);
//! the behavior is one.
//!
//! **Sort chips.** `SORT DEFAULT · STATE · NAME · COST · TIME` (`cc.sort_chips`, the catalog
//! state's `sort`/`dir`): a chip pressed first sorts by its key in its natural direction, and
//! pressed again flips it. `DEFAULT` is the authored order, the verbs then the generators in
//! authored verb order, and descending its reverse; `STATE` ranks ready, then working or
//! accumulating, then short, then off, ready first; `NAME`, `COST` (the entry's energy) and
//! `TIME` (its hours) ascend. Equal keys fall back to the name, A to Z in either direction. A
//! blank query lists every entry, the ones that cannot run now dimmed; the shared `query` parser
//! answers `type:` with `verb` or `generator`, `in:`/`out:` from a verb's lines (a generator's
//! are per cycle), `state:` from the standing (a verb: ready, busy, short; a
//! generator: ready, accumulating, off, short) and free text from the name. The standing is the
//! agent's `comp.Quotes`; a verb's lines are its terms (`actions.verbOf`). A generator is a verb
//! the roster marks `generator`, listed while the agent holds it.
//!
//! **Kind toggles.** The eyebrow `{n} VERBS · {m} GENERATORS` is two toggles: pressing one shows
//! that kind alone, pressing it again shows every kind. The kind lives in the catalog state's
//! `kind` (`Show`), beside the view's query.
//!
//! **Hidden tiles.** Every tile carries a `hide` corner at its top right; pressing it adds the
//! entry to the view's hidden set (`CatalogState.hidden`, numbered by the entry's action index)
//! and it leaves the grid. A hidden generator keeps
//! running; it is only out of sight. The summary is one toggle, `{n} hidden out of {N} →`, `N`
//! every entry of the pane: pressed, it opens the hidden view (`show_hidden`), which lists only
//! the hidden entries, dashed and dim with an `unhide` corner, under `← {n} hidden out of {N} ·
//! unhide all`; pressed again, it returns. With nothing hidden it is inert and only counts, and
//! a hidden view whose set empties falls back to the full grid; `unhide all` empties the set
//! and returns to the full grid. The kind, the query and the sort apply in either view.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const actions = ha.sim.rules.actions;
const roster = ha.sim.data.roster;
const query = @import("../query.zig");
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;
const CatalogState = uic.UiState.CatalogState;

const action_tile_mod = @import("./action_tile.zig");
const generator_tile = @import("./generator_tile.zig");
const scroll_view_mod = @import("./scroll_view.zig");
const cc = @import("./catalog_controls.zig");
const browser = @import("./browser.zig");
const copy = @import("./copy.zig");

const section_gap: f32 = 12;
const grid_gap: f32 = 10;
/// The compact catalog packs its tiles tighter (the prototype's `.act-two .action-grid`).
const compact_grid_gap: f32 = 6;
/// The most verbs one frame lists.
const max_verbs = 64;
/// The most entries one frame lists: the verbs and the generators share the action indices.
const max_entries = max_verbs;

/// One act's ACTIONS content.
pub const Shelf = struct {
    act: u8,
    subtitle: []const u8,
    /// The tiles' type scale: Act II's long catalog lists its tiles compact.
    density: action_tile_mod.Density = .regular,

    /// Whether a verb record is one of this shelf's labor verbs: not a generator, of this act.
    pub fn holds(self: Shelf, rec: *const roster.Action) bool {
        return !rec.generator and rec.act == self.act;
    }

    /// Whether a verb record is one of this shelf's generators: a generator of this act or an
    /// earlier one (the settlement keeps what the household built).
    pub fn holdsGenerator(self: Shelf, rec: *const roster.Action) bool {
        return rec.generator and rec.act <= self.act;
    }
};

/// The labor verbs the act authors.
pub fn authoredTotal(cat: *const roster.Catalog, shelf: Shelf) usize {
    var n: usize = 0;
    for (cat.actions) |*rec| n += @intFromBool(shelf.holds(rec));
    return n;
}

/// What an entry is: a verb or a generator.
pub const Kind = enum { verb, generator };

/// The kinds the pane shows, as `CatalogState.kind` holds it: 0 every kind, 1 the verbs alone,
/// 2 the generators alone.
pub const Show = enum(u8) {
    all = 0,
    verbs = 1,
    generators = 2,

    /// The state's `kind` read as a `Show`; an index it does not name is every kind.
    pub fn of(kind: u8) Show {
        return std.enums.fromInt(Show, kind) orelse .all;
    }

    fn admits(self: Show, kind: Kind) bool {
        return switch (self) {
            .all => true,
            .verbs => kind == .verb,
            .generators => kind == .generator,
        };
    }
};

/// One entry this frame, a held verb or a held generator: its kind and catalog index, its id
/// and name, its standing, what it sorts by, and its line items joined for `in:`/`out:`.
pub const Entry = struct {
    kind: Kind,
    /// The entry's index in `cat.actions`.
    index: u16,
    /// The tile's key: the verb's id.
    id: []const u8,
    /// What free text searches: the verb's name.
    name: []const u8,
    /// The word `state:` answers with.
    state: []const u8,
    /// Whether it can run now: the verb can begin, the generator can be collected.
    ready: bool,
    /// Its place in the authored order, the `DEFAULT` sort.
    order: u16 = 0,
    /// The energy a begin or a collection costs, the `COST` sort.
    energy: f32 = 0,
    /// The verb's hours or the generator's cycle, the `TIME` sort.
    hours: f32 = 0,
    /// The `STATE` sort's rank: ready 3, working or accumulating 2, short 1, off 0.
    rank: u8 = 0,
    in_buf: [64]u8 = undefined,
    in_len: usize = 0,
    out_buf: [64]u8 = undefined,
    out_len: usize = 0,

    fn ins(self: *const Entry) []const u8 {
        return self.in_buf[0..self.in_len];
    }
    fn outs(self: *const Entry) []const u8 {
        return self.out_buf[0..self.out_len];
    }
};

/// The `STATE` sort's rank of a standing word, the prototype's `actionStateRank`: a busy verb is
/// working, ranked with an accumulating generator.
fn stateRank(state: []const u8) u8 {
    const ranks = [_]struct { []const u8, u8 }{ .{ "ready", 3 }, .{ "busy", 2 }, .{ "accumulating", 2 }, .{ "short", 1 } };
    for (ranks) |r| if (std.mem.eql(u8, r[0], state)) return r[1];
    return 0;
}

/// The word a verb's `state:` answers with. Energy and inputs both read as short.
fn verbState(s: actions.Standing) []const u8 {
    return switch (s) {
        .ready => "ready",
        .busy => "busy",
        .energy, .short => "short",
    };
}

/// The word a generator's `state:` answers with, in the prototype's words: a charging cycle is
/// accumulating, and vigor or inputs it cannot pay read as short.
fn generatorState(q: comp.Quotes.Generator) []const u8 {
    return switch (q.standing) {
        .ready => "ready",
        .charging => "accumulating",
        .off => "off",
        .energy, .short => "short",
    };
}

/// The resources a verb spends, by name and space-separated, into `out`; returns the length
/// written.
fn joinRequires(out: []u8, req: *const roster.Requires) usize {
    var w = std.Io.Writer.fixed(out);
    for (std.enums.values(roster.Resource)) |r| {
        if (req.get(r) <= 0) continue;
        if (w.buffered().len > 0) w.writeByte(' ') catch break;
        w.writeAll(@tagName(r)) catch break;
    }
    return w.buffered().len;
}

/// The resources a verb yields, by name and space-separated, into `out`; returns the length
/// written.
fn joinOutput(out: []u8, o: *const roster.Output) usize {
    var w = std.Io.Writer.fixed(out);
    for (std.enums.values(roster.Resource)) |r| {
        if (o.get(r) == null) continue;
        if (w.buffered().len > 0) w.writeByte(' ') catch break;
        w.writeAll(@tagName(r)) catch break;
    }
    return w.buffered().len;
}

/// The row-facing `query` contract.
const ActionRow = struct {
    e: *const Entry,
    pub fn text(self: ActionRow, f: query.Field) []const u8 {
        return switch (f) {
            .in => self.e.ins(),
            .out => self.e.outs(),
            .state => self.e.state,
            .type => @tagName(self.e.kind),
            else => "",
        };
    }
    pub fn haystack(self: ActionRow) []const u8 {
        return self.e.name;
    }
    pub fn inReach(self: ActionRow) bool {
        return self.e.ready;
    }
};

/// Every entry of the shelf: the verbs the agent's `comp.Quotes` answers for in authored order,
/// then the generators it quotes in authored order. Pure over world + catalog.
pub fn held(world: *const World, e: Entity, cat: *const roster.Catalog, shelf: Shelf, buf: []Entry) []Entry {
    const quotes = world.get(e, comp.Quotes) orelse return buf[0..0];
    var n: usize = 0;
    for (cat.actions, 0..) |*rec, i| {
        if (!shelf.holds(rec)) continue;
        if (n == buf.len) break;
        const ai: u16 = @intCast(i);
        const q = quotes.verbs[ai] orelse continue;
        const verb = actions.verbOf(world, e, cat, ai) orelse continue;
        const state = verbState(q.standing);
        buf[n] = .{
            .kind = .verb, .index = ai, .id = rec.id, .name = rec.name, .state = state, .ready = q.standing == .ready,
            .order = @intCast(n), .energy = verb.requires.energy, .hours = verb.requires.hours, .rank = stateRank(state),
        };
        buf[n].in_len = joinRequires(&buf[n].in_buf, &verb.requires);
        buf[n].out_len = joinOutput(&buf[n].out_buf, &verb.output);
        n += 1;
    }
    for (cat.actions, 0..) |*rec, i| {
        if (!shelf.holdsGenerator(rec)) continue;
        if (n == buf.len) break;
        const ai: u16 = @intCast(i);
        const q = quotes.generators[ai] orelse continue;
        const verb = actions.verbOf(world, e, cat, ai) orelse continue;
        const state = generatorState(q);
        buf[n] = .{
            .kind = .generator, .index = ai, .id = rec.id, .name = rec.name, .state = state, .ready = q.ready(),
            .order = @intCast(n), .energy = verb.requires.energy, .hours = verb.requires.hours, .rank = stateRank(state),
        };
        buf[n].in_len = joinRequires(&buf[n].in_buf, &verb.requires);
        buf[n].out_len = joinOutput(&buf[n].out_buf, &verb.output);
        n += 1;
    }
    return buf[0..n];
}

/// The hidden set's number for an entry: its action index.
pub fn slot(ent: *const Entry) usize {
    return ent.index;
}

/// The hidden set's number for the verb or generator record `id`, as `slot` numbers its entry;
/// null when the catalog holds no such record.
pub fn slotOf(cat: *const roster.Catalog, id: []const u8) ?usize {
    return if (cat.actionIndex(id)) |ai| ai else null;
}

comptime {
    std.debug.assert(max_verbs >= roster.max_actions);
    std.debug.assert(max_verbs <= CatalogState.max_hidden);
}

/// Whether the view's hidden set holds `ent`.
pub fn isHidden(st: *const CatalogState, ent: *const Entry) bool {
    return st.hidden.isSet(slot(ent));
}

/// How many of `list` the view hides.
pub fn hiddenCount(list: []const Entry, st: *const CatalogState) usize {
    var n: usize = 0;
    for (list) |*ent| n += @intFromBool(isHidden(st, ent));
    return n;
}

/// Hide `ent`, or unhide it when it is hidden.
pub fn toggleHidden(st: *CatalogState, ent: *const Entry) void {
    st.hidden.toggle(slot(ent));
}

/// Empty the hidden set and return to the full grid.
pub fn unhideAll(st: *CatalogState) void {
    st.hidden = .empty;
    st.show_hidden = false;
}

/// Keep the entries of the view in force, in place and in order: the hidden ones in the hidden
/// view, the rest otherwise. A hidden view with nothing hidden falls back to the full grid.
pub fn inView(list: []Entry, st: *CatalogState) []Entry {
    if (hiddenCount(list, st) == 0) st.show_hidden = false;
    var n: usize = 0;
    for (list) |ent| {
        if (isHidden(st, &ent) == st.show_hidden) {
            list[n] = ent;
            n += 1;
        }
    }
    return list[0..n];
}

/// Keep the entries of a kind `show` admits that `query_text` admits, in place and in order;
/// returns the kept prefix.
pub fn filter(list: []Entry, query_text: []const u8, show: Show) []Entry {
    if (query_text.len == 0 and show == .all) return list;
    const q = query.parse(query_text);
    var n: usize = 0;
    for (list) |ent| {
        if (show.admits(ent.kind) and query.matches(&q, ActionRow{ .e = &ent })) {
            list[n] = ent;
            n += 1;
        }
    }
    return list[0..n];
}

/// The sort keys, in chip order; the index is `CatalogState.sort`.
pub const Sort = enum(usize) { default = 0, state = 1, name = 2, cost = 3, time = 4 };

/// The chips: each key's label and the direction it sorts in when first pressed.
pub const sort_keys = [_]cc.SortKey{
    .{ .label = "DEFAULT", .natural = .ascending },
    .{ .label = "STATE", .natural = .descending },
    .{ .label = "NAME", .natural = .ascending },
    .{ .label = "COST", .natural = .ascending },
    .{ .label = "TIME", .natural = .ascending },
};

/// Order `list` by `sort` in `dir`, stably; `none` is the key's natural direction. Equal keys
/// fall back to the name, A to Z in either direction (the prototype's `compareActionCells`).
pub fn sortEntries(list: []Entry, sort: Sort, dir: CatalogState.Direction) void {
    const Ctx = struct { sort: Sort, desc: bool };
    const Cmp = struct {
        fn less(c: Ctx, a: Entry, b: Entry) bool {
            if (c.sort == .name) return cc.lessThan(if (c.desc) .descending else .ascending, false, true, a.name, b.name);
            const x: f32, const y: f32 = switch (c.sort) {
                .default => .{ @floatFromInt(a.order), @floatFromInt(b.order) },
                .state => .{ @floatFromInt(a.rank), @floatFromInt(b.rank) },
                .cost => .{ a.energy, b.energy },
                .time => .{ a.hours, b.hours },
                .name => unreachable,
            };
            return cc.lessThan(.ascending, if (c.desc) y < x else x < y, x == y, a.name, b.name);
        }
    };
    const eff = if (dir != .none) dir else sort_keys[@intFromEnum(sort)].natural;
    std.sort.insertion(Entry, list, Ctx{ .sort = sort, .desc = eff == .descending }, Cmp.less);
}

/// A kind toggle's label: the eyebrow's dim at rest, fg while pressed, accent while hot.
pub const kind_toggle_ink = Style{ .ink = .dim, .on = &.{ .{ .when = .checked, .ink = .fg }, .{ .when = .hot, .ink = .acc } } };

/// One kind toggle, `text` in the eyebrow's type. A click presses `kind` into `st`, or releases
/// it back to every kind when it is already pressed. The state is read after the click, so the
/// label and the published `checked` are current on the click frame. The host has no
/// toggle-button role, so the two-state toggle publishes as a checkbox.
fn kindToggle(parent: El, id: []const u8, text: []const u8, name: []const u8, st: *CatalogState, kind: Show) !void {
    const b = try parent.box(id, .{ .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row } }, .{});
    const own: u8 = @intFromEnum(kind);
    if (b.query().clicked) st.kind = if (st.kind == own) @intFromEnum(Show.all) else own;
    const pressed = st.kind == own;
    _ = b.control(.{ .name = name, .role = .checkbox, .checked = pressed, .ring = false });
    try b.label("t", text, .{ style.eyebrow, kind_toggle_ink });
}

/// The summary's ink: dim at rest, fg while the hidden view is open, line2 while inert, accent
/// while hot.
pub const summary_ink = Style{ .ink = .dim, .on = &.{ .{ .when = .checked, .ink = .fg }, .{ .when = .disabled, .ink = .line2 }, .{ .when = .hot, .ink = .acc } } };

/// The summary, `{n} hidden out of {N} →`, as the hidden view's toggle: a click opens or closes
/// the view, and with nothing hidden it is disabled and only counts. The state is read after the
/// click, so the label is current on the click frame. The two-state toggle publishes as a
/// checkbox, as the kind toggles do.
fn hiddenToggle(parent: El, st: *CatalogState, hidden: usize, total: usize) !void {
    const b = try parent.box("hidden", .{ .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row } }, .{});
    const enabled = hidden > 0;
    if (enabled and b.query().clicked) st.show_hidden = !st.show_hidden;
    const open = enabled and st.show_hidden;
    var nbuf: [40]u8 = undefined;
    const name = std.mem.print(&nbuf, "{d} hidden out of {d}", .{ hidden, total }) catch "hidden";
    _ = b.control(.{ .enabled = enabled, .name = name, .role = .checkbox, .checked = open, .ring = false });
    var tbuf: [48]u8 = undefined;
    const text = if (!enabled) name else if (open)
        std.mem.print(&tbuf, "\u{2190} {s}", .{name}) catch name
    else
        std.mem.print(&tbuf, "{s} \u{2192}", .{name}) catch name;
    try b.label("t", text, .{ style.small, summary_ink });
}

/// `unhide all`, beside the summary in the hidden view: a text button in the summary's ink.
/// Returns its click.
fn unhideAllButton(parent: El) !bool {
    const b = try parent.box("unhide_all", .{ .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row } }, .{});
    const q = b.control(.{ .name = "Unhide all", .role = .button, .ring = false });
    try b.label("t", "unhide all", .{ style.small, summary_ink });
    return q.clicked;
}

/// The heading's eyebrow, `{n} VERBS · {m} GENERATORS`, into the heading's top row.
fn kindToggles(top: El, list: []const Entry, st: *CatalogState) !void {
    var verbs: usize = 0;
    for (list) |ent| verbs += @intFromBool(ent.kind == .verb);
    const row = try top.box("count", .{ .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center } }, .{});
    var vbuf: [16]u8 = undefined;
    var gbuf: [24]u8 = undefined;
    const vtext = std.mem.print(&vbuf, "{d} VERBS", .{verbs}) catch "VERBS";
    const gtext = std.mem.print(&gbuf, "{d} GENERATORS", .{list.len - verbs}) catch "GENERATORS";
    try kindToggle(row, "verbs", vtext, "Show the verbs alone", st, .verbs);
    try row.label("sep", " \u{00B7} ", .{ style.eyebrow, style.muted });
    try kindToggle(row, "generators", gtext, "Show the generators alone", st, .generators);
}

/// Build the pane for agent `e`. A ready verb tile's click writes `BeginLabor` for its verb; a
/// generator tile collects and cycles its mode itself (`generator_tile`). `catalog_state` and
/// `search_owner` keep the query and the kind on an always-built owner when given; without them
/// the pane's own node keeps the catalog state.
///
/// With `scroll` the pane fills its parent's height, which must be definite: the heading,
/// search and toolbar stay put and only the tiles scroll (Act II's long catalog). Without it
/// the pane is content-high and the caller scrolls it whole (Act I's short roster).
pub fn actions_section(parent: El, world: *const World, e: Entity, id: []const u8, shelf: Shelf, catalog_state: ?*CatalogState, search_owner: ?El, scroll: ?*uic.UiState.ScrollState) !El {
    const ctx = parent.ctx;
    const cat = &ctx.res.game.catalog;

    const section = try parent.box(id, .{
        .w = .{ .pct_of_parent = 1.0 },
        .h = if (scroll != null) @import("./terminal.zig").fill_h(ctx) else .fit_children,
        .flow = .{ .dir = .column, .cross = .start }, .gap = section_gap,
    }, .{});
    const st = catalog_state orelse section.state(CatalogState);

    // The heading counts each kind the actor holds — the same set the summary counts against.
    var buf: [max_entries]Entry = undefined;
    const all = held(world, e, cat, shelf, &buf);
    const heading = try browser.browser_heading_bare(section, "heading", "ACTIONS", shelf.subtitle);
    try kindToggles(heading.top, all, st);

    const controls = try cc.catalog_controls(section, "actions_ctl", cc.actions_placeholder, st, search_owner);

    // The toolbar: the summary toggle (and `unhide all` in the hidden view) on the left, the sort
    // chips on the right, on one baseline.
    const toolbar = try section.box("toolbar", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children,
        .flow = .{ .dir = .row, .main = .space_between, .cross = .baseline }, .gap = 12,
    }, .{});
    const hidden_n = hiddenCount(all, st);
    if (hidden_n == 0) st.show_hidden = false;
    // Centered across: a box reports no baseline, so a baseline row would hang the separator's
    // descent below the two buttons and push the toolbar's line down.
    const summary = try toolbar.box("summary", .{ .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center } }, .{});
    try hiddenToggle(summary, st, hidden_n, all.len);
    if (st.show_hidden) {
        try summary.label("sep", " \u{00B7} ", .{ style.small, style.muted });
        if (try unhideAllButton(summary)) unhideAll(st);
    }
    const sorted = try cc.sort_chips(toolbar, "sort", "Sort actions", &sort_keys, st);
    const total = all.len;
    const shown = filter(inView(all, st), controls.query_text, Show.of(st.kind));
    sortEntries(shown, @enumFromInt(sorted.sort), sorted.dir);
    const hide: action_tile_mod.Hide = if (st.show_hidden) .hidden else .shown;

    const compact = ctx.res.view.metrics.width_class.atMost(.w440);
    // The tiles' host: the pane itself, or a scroll viewport filling the height left under
    // the toolbar.
    const host = if (scroll) |sc| blk: {
        const area = try section.box("results", .{ .w = .{ .pct_of_parent = 1.0 }, .h = @import("./terminal.zig").grow_h(ctx) }, .{});
        const sv = try scroll_view_mod.scroll_view(area, "scroll", .{ .height = 0, .framed = false, .name = "Available actions; scroll for more" }, sc);
        break :blk sv.content;
    } else section;
    const grid = try browser.tile_lanes(host, "grid", compact, if (shelf.density == .compact) compact_grid_gap else grid_gap);
    if (shown.len == 0) {
        const msg = if (total == 0)
            "No action is open yet. Build or research one."
        else if (st.show_hidden)
            "No hidden action matches your search."
        else
            "No action matches your search.";
        _ = try copy.empty_line(grid.grid, "empty", msg);
    }
    const act = ha.sim.data.migration.actOf(world, e);
    // Keyed by the verb's id, so focus follows it through a re-sort or a query.
    for (shown, 0..) |*ent, pos| {
        const lane = grid.lanes[pos % 2];
        const tile: ?action_tile_mod.Tile = switch (ent.kind) {
            .generator => try generator_tile.generatorTile(lane, world, e, act, ent.index, shelf.density, hide),
            .verb => if (try action_tile_mod.action_tile(lane, world, e, ent.index, ent.id, shelf.density, hide)) |tl| blk: {
                if (tl.clicked) _ = ctx.res.game.events.writer(ha.sim.events.BeginLabor).push(.{ .agent = e, .ai = ent.index });
                break :blk tl;
            } else null,
        };
        if (tile) |tl| {
            action_tile_mod.place(tl, ownHeight(ent.kind, shelf.density), rowHeight(shown, pos, if (compact) 1 else 2, shelf.density));
            if (tl.hide_clicked) toggleHidden(st, ent);
        }
    }
    return section;
}

/// An entry's own tile height at `density`: a verb's or a generator's.
pub fn ownHeight(kind: Kind, density: action_tile_mod.Density) f32 {
    return switch (kind) {
        .verb => action_tile_mod.height(density),
        .generator => generator_tile.height(density),
    };
}

/// The height of the grid row holding `list[pos]` when the tiles alternate between `lanes`
/// columns: the tallest own height among the row's entries, so every tile of a row stands as
/// tall as the row (the prototype's stretched grid cells) and the lanes' rows line up.
pub fn rowHeight(list: []const Entry, pos: usize, lanes: usize, density: action_tile_mod.Density) f32 {
    const first = pos - pos % lanes;
    var h: f32 = 0;
    for (list[first..@min(first + lanes, list.len)]) |ent| h = @max(h, ownHeight(ent.kind, density));
    return h;
}

// ============================ Tests =====================================================

const testing = std.testing;
const act_two_test = Shelf{ .act = 2, .subtitle = "" };

/// An agent carried across the curtain: holding the Act I starting goods and none of Act II's.
fn settler(w: *World, cat: *const roster.Catalog) Entity {
    const e = w.spawn(.{
        comp.Vigor{ .v = 15, .max = 15 },
        comp.InventoryFood{ .v = 20, .quality = 1, .spoils = 0 },
        comp.InventoryBiomass{ .v = 30 },
        comp.Goods{},
        comp.Generators{},
        comp.Granted{},
        comp.Condition{},
        comp.Quotes{},
    });
    _ = ha.sim.data.migration.migrate_to_act_two(w, e, cat);
    requote(w, e, cat);
    return e;
}

/// Write the agent's quotes, as the `quotes` system does each frame.
fn requote(w: *World, e: Entity, cat: *const roster.Catalog) void {
    ha.sim.systems.quotes.fill(w, e, cat, .{}, w.get(e, comp.Quotes).?);
}

/// Research every technology and own the three goods that open a verb.
fn establishAll(w: *World, e: Entity, cat: *const roster.Catalog) void {
    const research = w.get(e, comp.Research).?;
    for (research.state[0..cat.technologies.len]) |*s| s.* = .researched;
    const goods = w.get(e, comp.Goods).?;
    for ([_][]const u8{ "firepit", "spring_well", "forge" }) |id| goods.count[cat.goodIndex(id).?] = 1;
    requote(w, e, cat);
}

/// Own the snares, a garden bed whose Tend garden is ready and the settlement's bed with its
/// Tend garden switched off: generators of each act, accumulating, ready and off.
fn ownGenerators(w: *World, e: Entity, cat: *const roster.Catalog) void {
    const goods = w.get(e, comp.Goods).?;
    const gens = w.get(e, comp.Generators).?;
    for ([_][]const u8{ "wire_snares", "garden_bed", "garden_bed_two" }) |id| goods.count[cat.goodIndex(id).?] = 1;
    gens.progress[cat.actionIndex("tend_garden").?] = 1e9;
    gens.mode[cat.actionIndex("tend_garden_two").?] = .off;
    requote(w, e, cat);
}

/// The entries `query_text` admits of `show`, over a copy of `list`.
fn filtered(work: []Entry, list: []const Entry, query_text: []const u8, show: Show) []Entry {
    @memcpy(work[0..list.len], list);
    return filter(work[0..list.len], query_text, show);
}

test "the curtain opens only the verbs its researched tiles establish" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat);
    var buf: [max_entries]Entry = undefined;
    const list = held(&w, e, &cat, act_two_test, &buf);
    try testing.expect(list.len > 0 and list.len < authoredTotal(&cat, act_two_test));
    for (list) |ent| {
        try testing.expectEqual(Kind.verb, ent.kind);
        const t = cat.actions[ent.index].requires.tech orelse return error.UntaggedVerb;
        try testing.expect(std.mem.eql(u8, t, "foraging") or std.mem.eql(u8, t, "woodcutting"));
    }
}

test "an established settlement lists every verb of the act in authored order" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat);
    establishAll(&w, e, &cat);
    var buf: [max_entries]Entry = undefined;
    const list = held(&w, e, &cat, act_two_test, &buf);
    try testing.expectEqual(authoredTotal(&cat, act_two_test), list.len);
    for (list[1..], 0..) |ent, i| try testing.expect(ent.index > list[i].index);
}

test "the list is the verbs, then the held generators of the act and earlier ones" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat);
    establishAll(&w, e, &cat);
    ownGenerators(&w, e, &cat);
    var buf: [max_entries]Entry = undefined;
    const list = held(&w, e, &cat, act_two_test, &buf);
    const verbs = authoredTotal(&cat, act_two_test);
    try testing.expectEqual(verbs + 3, list.len);
    for (list[0..verbs]) |ent| try testing.expectEqual(Kind.verb, ent.kind);
    const want = [_][]const u8{ "check_traps", "tend_garden", "tend_garden_two" };
    for (list[verbs..], want) |ent, id| {
        try testing.expectEqual(Kind.generator, ent.kind);
        try testing.expectEqualStrings(id, ent.id);
        try testing.expectEqualStrings(id, cat.actions[ent.index].id);
    }
    // The snares' round searches by its verb's name; Act I lists only its own generators.
    try testing.expectEqualStrings("Check traps", list[verbs].name);
    var one: [max_entries]Entry = undefined;
    const act_one = held(&w, e, &cat, .{ .act = 1, .subtitle = "" }, &one);
    var gens: usize = 0;
    for (act_one) |ent| gens += @intFromBool(ent.kind == .generator);
    try testing.expectEqual(@as(usize, 2), gens);
}

test "type: and the catalog state's kind keep one kind" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat);
    establishAll(&w, e, &cat);
    ownGenerators(&w, e, &cat);
    var buf: [max_entries]Entry = undefined;
    const list = held(&w, e, &cat, act_two_test, &buf);
    const verbs = authoredTotal(&cat, act_two_test);
    var work: [max_entries]Entry = undefined;

    const by_type = filtered(&work, list, "type:generator", .all);
    try testing.expectEqual(@as(usize, 3), by_type.len);
    for (by_type) |ent| try testing.expectEqual(Kind.generator, ent.kind);
    try testing.expectEqual(verbs, filtered(&work, list, "type:verb", .all).len);
    try testing.expectEqual(verbs, filtered(&work, list, "-type:generator", .all).len);

    // The pressed toggle's index in `CatalogState.kind`; 0, or an index it does not name, is
    // every kind.
    var st: CatalogState = .{};
    try testing.expectEqual(list.len, filtered(&work, list, "", Show.of(st.kind)).len);
    st.kind = @intFromEnum(Show.generators);
    const gens = filtered(&work, list, "", Show.of(st.kind));
    try testing.expectEqual(@as(usize, 3), gens.len);
    for (gens) |ent| try testing.expectEqual(Kind.generator, ent.kind);
    st.kind = @intFromEnum(Show.verbs);
    try testing.expectEqual(verbs, filtered(&work, list, "", Show.of(st.kind)).len);
    // The kind and the query both hold: no verb is a generator.
    try testing.expectEqual(@as(usize, 0), filtered(&work, list, "type:generator", Show.of(st.kind)).len);
    try testing.expectEqual(Show.all, Show.of(9));
}

test "a generator answers in: and out: from its cycle's lines, state: from its standing" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat);
    establishAll(&w, e, &cat);
    ownGenerators(&w, e, &cat);
    var buf: [max_entries]Entry = undefined;
    const list = held(&w, e, &cat, act_two_test, &buf);
    var work: [max_entries]Entry = undefined;

    // Every generator eats biomass and yields food each cycle.
    try testing.expectEqual(@as(usize, 3), filtered(&work, list, "type:generator in:biomass out:food", .all).len);

    const ready = filtered(&work, list, "type:generator state:ready", .all);
    try testing.expectEqual(@as(usize, 1), ready.len);
    try testing.expectEqualStrings("tend_garden", ready[0].id);
    const off = filtered(&work, list, "state:off", .all);
    try testing.expectEqual(@as(usize, 1), off.len);
    try testing.expectEqualStrings("tend_garden_two", off[0].id);
    const accumulating = filtered(&work, list, "state:accumulating", .all);
    try testing.expectEqual(@as(usize, 1), accumulating.len);
    try testing.expectEqualStrings("check_traps", accumulating[0].id);
    // `is:` reads the type as well as the state.
    try testing.expectEqual(@as(usize, 3), filtered(&work, list, "is:generator", .all).len);
}

test "in: and out: match the verb's lines; state: its standing" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat);
    establishAll(&w, e, &cat);
    var buf: [max_entries]Entry = undefined;
    const list = held(&w, e, &cat, act_two_test, &buf);
    const n = list.len;
    var work: [max_entries]Entry = undefined;

    const water = filtered(&work, list, "out:water", .all);
    try testing.expect(water.len > 0 and water.len < n);
    for (water) |ent| try testing.expect(std.mem.find(u8, ent.outs(), "water") != null);

    const fuel_in = filtered(&work, list, "in:fuel", .all);
    try testing.expect(fuel_in.len > 0);
    for (fuel_in) |ent| try testing.expect(std.mem.find(u8, ent.ins(), "fuel") != null);

    // The settlement holds no fuel yet, so nothing that burns it can begin.
    try testing.expectEqual(@as(usize, 0), filtered(&work, list, "in:fuel state:ready", .all).len);
}

test "actions tiles keep their height" {
    // 82px / 52px outer, including the tile's 1px bottom inset.
    try testing.expectEqual(@as(f32, 81), action_tile_mod.height(.regular));
    try testing.expectEqual(@as(f32, 51), action_tile_mod.height(.compact));
    // A regular generator adds its state line; a compact one rides it on the name row.
    try testing.expectEqual(@as(f32, 87), generator_tile.height(.regular));
    try testing.expectEqual(@as(f32, 51), generator_tile.height(.compact));
}

test "a grid row stands as tall as its tallest tile" {
    const v = sortable("Forage", 0, 3, 2, 4);
    var g = sortable("Snares", 1, 2, 1, 24);
    g.kind = .generator;
    // Two lanes: verb + generator, then verb + verb, then generator + generator, then a lone verb.
    const list = [_]Entry{ v, g, v, v, g, g, v };
    const want = [_]f32{ 87, 87, 81, 81, 87, 87, 81 };
    for (want, 0..) |h, pos| try testing.expectEqual(h, rowHeight(&list, pos, 2, .regular));
    // One lane (the compact breakpoint): every tile keeps its own height.
    for (list, 0..) |ent, pos| try testing.expectEqual(ownHeight(ent.kind, .regular), rowHeight(&list, pos, 1, .regular));
    // Compact density: a verb and a generator already share a height.
    for (0..list.len) |pos| try testing.expectEqual(@as(f32, 51), rowHeight(&list, pos, 2, .compact));
}

/// An entry with only what the sort reads: its name, its authored place and its keys.
fn sortable(name: []const u8, order: u16, rank: u8, energy: f32, hours: f32) Entry {
    return .{ .kind = .verb, .index = order, .id = name, .name = name, .state = "", .ready = false, .order = order, .energy = energy, .hours = hours, .rank = rank };
}

/// The names of `list` in order, joined by spaces, into `buf`.
fn names(buf: []u8, list: []const Entry) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    for (list, 0..) |ent, i| {
        if (i > 0) w.writeByte(' ') catch break;
        w.writeAll(ent.name) catch break;
    }
    return w.buffered();
}

/// Five entries sorted by `sort` in `dir`, as their names.
fn sortedNames(buf: []u8, sort: Sort, dir: CatalogState.Direction) []const u8 {
    // Authored order: Forage, Chop, Rest, then the generators Snares and Bed. Chop and Forage
    // tie on state and cost, Rest and Bed on time.
    var list = [_]Entry{
        sortable("Forage", 0, 3, 2, 4),
        sortable("Chop", 1, 3, 2, 6),
        sortable("Rest", 2, 1, 0, 8),
        sortable("Snares", 3, 2, 1, 24),
        sortable("Bed", 4, 0, 3, 8),
    };
    sortEntries(&list, sort, dir);
    return names(buf, &list);
}

test "each sort key orders the entries in its natural direction, equal keys by name" {
    var b: [64]u8 = undefined;
    // `none` is the key's natural direction.
    try testing.expectEqualStrings("Forage Chop Rest Snares Bed", sortedNames(&b, .default, .none));
    try testing.expectEqualStrings("Forage Chop Rest Snares Bed", sortedNames(&b, .default, .ascending));
    try testing.expectEqualStrings("Chop Forage Snares Rest Bed", sortedNames(&b, .state, .none));
    try testing.expectEqualStrings("Bed Chop Forage Rest Snares", sortedNames(&b, .name, .none));
    try testing.expectEqualStrings("Rest Snares Chop Forage Bed", sortedNames(&b, .cost, .none));
    try testing.expectEqualStrings("Forage Chop Bed Rest Snares", sortedNames(&b, .time, .none));
}

test "the flip reverses each key, and equal keys still read by name" {
    var b: [64]u8 = undefined;
    // `DEFAULT` descending is the authored order reversed.
    try testing.expectEqualStrings("Bed Snares Rest Chop Forage", sortedNames(&b, .default, .descending));
    try testing.expectEqualStrings("Bed Rest Snares Chop Forage", sortedNames(&b, .state, .ascending));
    try testing.expectEqualStrings("Snares Rest Forage Chop Bed", sortedNames(&b, .name, .descending));
    try testing.expectEqualStrings("Bed Chop Forage Snares Rest", sortedNames(&b, .cost, .descending));
    try testing.expectEqualStrings("Snares Bed Rest Chop Forage", sortedNames(&b, .time, .descending));
}

test "a chip pressed first takes its natural direction; pressed again it flips" {
    var st: CatalogState = .{};
    const press = struct {
        fn f(s: *CatalogState, key: Sort) void {
            const cur: CatalogState.Direction = if (s.dir != .none) s.dir else sort_keys[s.sort].natural;
            const next = cc.nextSort(s.sort, cur, @intFromEnum(key), sort_keys[@intFromEnum(key)].natural);
            s.sort = next.sort;
            s.dir = next.dir;
        }
    }.f;
    // A fresh state is `DEFAULT` ascending; pressing it flips to the reverse authored order.
    press(&st, .default);
    try testing.expectEqual(CatalogState.Direction.descending, st.dir);
    press(&st, .state);
    try testing.expectEqual(@as(usize, @intFromEnum(Sort.state)), st.sort);
    try testing.expectEqual(CatalogState.Direction.descending, st.dir);
    press(&st, .state);
    try testing.expectEqual(CatalogState.Direction.ascending, st.dir);
    press(&st, .cost);
    try testing.expectEqual(CatalogState.Direction.ascending, st.dir);
    press(&st, .default);
    try testing.expectEqual(@as(usize, 0), st.sort);
    try testing.expectEqual(CatalogState.Direction.ascending, st.dir);
}

test "the held entries carry their authored place, price and state rank" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat);
    establishAll(&w, e, &cat);
    ownGenerators(&w, e, &cat);
    var buf: [max_entries]Entry = undefined;
    const list = held(&w, e, &cat, act_two_test, &buf);
    for (list, 0..) |ent, i| try testing.expectEqual(@as(u16, @intCast(i)), ent.order);
    const verbs = authoredTotal(&cat, act_two_test);
    // The generators: the snares accumulating, the ready bed, the bed switched off.
    try testing.expectEqual(@as(u8, 2), list[verbs].rank);
    try testing.expectEqual(@as(u8, 3), list[verbs + 1].rank);
    try testing.expectEqual(@as(u8, 0), list[verbs + 2].rank);
    const spec = cat.actions[list[verbs].index].requires;
    try testing.expectEqual(spec.energy, list[verbs].energy);
    try testing.expectEqual(spec.hours, list[verbs].hours);
    // `STATE` puts a ready entry first and the bed that is off last.
    var work: [max_entries]Entry = undefined;
    @memcpy(work[0..list.len], list);
    sortEntries(work[0..list.len], .state, .none);
    try testing.expectEqual(@as(u8, 3), work[0].rank);
    try testing.expectEqualStrings("tend_garden_two", work[list.len - 1].id);
}

/// The view of `list` in force under `st`, filtered by `query_text` and its kind and sorted by
/// its sort, over a copy of `list`.
fn viewed(work: []Entry, list: []const Entry, st: *CatalogState, query_text: []const u8) []Entry {
    @memcpy(work[0..list.len], list);
    const shown = filter(inView(work[0..list.len], st), query_text, Show.of(st.kind));
    sortEntries(shown, @enumFromInt(st.sort), st.dir);
    return shown;
}

fn has(list: []const Entry, id: []const u8) bool {
    for (list) |ent| if (std.mem.eql(u8, ent.id, id)) return true;
    return false;
}

test "hiding moves an entry from the full grid to the hidden view; unhide all returns it" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat);
    establishAll(&w, e, &cat);
    ownGenerators(&w, e, &cat);
    var buf: [max_entries]Entry = undefined;
    const list = held(&w, e, &cat, act_two_test, &buf);
    const verbs = authoredTotal(&cat, act_two_test);
    var work: [max_entries]Entry = undefined;

    // Nothing hidden: the hidden view falls back to the full grid.
    var st: CatalogState = .{};
    st.show_hidden = true;
    try testing.expectEqual(list.len, viewed(&work, list, &st, "").len);
    try testing.expect(!st.show_hidden);

    // Hide the first verb and the first generator: both leave the grid and fill the hidden view.
    toggleHidden(&st, &list[0]);
    toggleHidden(&st, &list[verbs]);
    try testing.expectEqual(@as(usize, 2), hiddenCount(list, &st));
    const full = viewed(&work, list, &st, "");
    try testing.expectEqual(list.len - 2, full.len);
    try testing.expect(!has(full, list[0].id) and !has(full, list[verbs].id));
    st.show_hidden = true;
    const hidden = viewed(&work, list, &st, "");
    try testing.expectEqual(@as(usize, 2), hidden.len);
    try testing.expect(has(hidden, list[0].id) and has(hidden, list[verbs].id));

    // A generator is numbered by its action index, as a verb is.
    try testing.expectEqual(@as(usize, list[verbs].index), slot(&list[verbs]));

    // Unhiding one keeps the view open on the other.
    toggleHidden(&st, &list[0]);
    try testing.expectEqual(@as(usize, 1), viewed(&work, list, &st, "").len);
    try testing.expect(st.show_hidden);

    // Unhide all empties the set and returns to the full grid.
    unhideAll(&st);
    try testing.expectEqual(@as(usize, 0), hiddenCount(list, &st));
    try testing.expect(!st.show_hidden);
    try testing.expectEqual(list.len, viewed(&work, list, &st, "").len);

    // Bitwise zero, as a pooled slot starts, is nothing hidden and the full grid.
    const zero = std.mem.zeroes(CatalogState);
    try testing.expectEqual(@as(usize, 0), hiddenCount(list, &zero));
    try testing.expect(!zero.show_hidden);
}

test "the kind, the query and the sort apply in the hidden view" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat);
    establishAll(&w, e, &cat);
    ownGenerators(&w, e, &cat);
    var buf: [max_entries]Entry = undefined;
    const list = held(&w, e, &cat, act_two_test, &buf);
    const verbs = authoredTotal(&cat, act_two_test);
    var work: [max_entries]Entry = undefined;

    // Hide two verbs and the three generators, then open the hidden view.
    var st: CatalogState = .{};
    for ([_]usize{ 0, 1, verbs, verbs + 1, verbs + 2 }) |i| toggleHidden(&st, &list[i]);
    st.show_hidden = true;
    try testing.expectEqual(@as(usize, 5), viewed(&work, list, &st, "").len);

    st.kind = @intFromEnum(Show.generators);
    try testing.expectEqual(@as(usize, 3), viewed(&work, list, &st, "").len);
    st.kind = @intFromEnum(Show.verbs);
    try testing.expectEqual(@as(usize, 2), viewed(&work, list, &st, "").len);
    st.kind = @intFromEnum(Show.all);

    const off = viewed(&work, list, &st, "state:off");
    try testing.expectEqual(@as(usize, 1), off.len);
    try testing.expectEqualStrings("tend_garden_two", off[0].id);

    // `NAME` orders the hidden entries A to Z (the two Tend garden verbs share a name); `DEFAULT`
    // descending reverses the authored order.
    st.sort = @intFromEnum(Sort.name);
    st.dir = .ascending;
    const by_name = viewed(&work, list, &st, "");
    for (by_name[1..], 0..) |ent, i| try testing.expect(!std.ascii.lessThanIgnoreCase(ent.name, by_name[i].name));
    st.sort = @intFromEnum(Sort.default);
    st.dir = .descending;
    const reversed = viewed(&work, list, &st, "");
    for (reversed[1..], 0..) |ent, i| try testing.expect(ent.order < reversed[i].order);
}
