//! `actions_section` — the ACTIONS pane, the same template on every act: the heading with the
//! act's kind counts as two toggles, one search field, a count-only summary, and the held verbs
//! then the owned generators in two growing columns (one at the compact breakpoint). A verb is
//! an `action_tile`, a generator a `generator_tile`. Only the content differs per act (`Shelf`:
//! which verbs and generators, the subtitle, the density); the behavior is one.
//!
//! **No sorting.** Verbs read in authored order, then the generators in authored good order. A
//! blank query lists every entry, the ones that cannot run now dimmed; the shared `query` parser
//! answers `type:` with `verb` or `generator`, `in:`/`out:` from a verb's lines or a
//! generator's daily lines, `state:` from the standing (a verb: ready, busy, short; a
//! generator: ready, accumulating, off, short) and free text from the name. The standing is the
//! agent's `comp.Quotes`; a verb's lines are its terms (`actions.verbOf`).
//!
//! **Kind toggles.** The eyebrow `{n} VERBS · {m} GENERATORS` is two toggles: pressing one shows
//! that kind alone, pressing it again shows every kind. The kind lives in the catalog state's
//! `kind` (`Show`), beside the view's query.

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
/// The most entries one frame lists: the verbs and every good.
const max_entries = max_verbs + roster.max_goods;

/// One act's ACTIONS content.
pub const Shelf = struct {
    act: u8,
    subtitle: []const u8,
    /// The tiles' type scale: Act II's long catalog lists its tiles compact.
    density: action_tile_mod.Density = .regular,

    /// Whether a verb record is one of this shelf's: on the surface and of this act.
    pub fn holds(self: Shelf, rec: *const roster.Action) bool {
        return rec.on_surface and rec.act == self.act;
    }

    /// Whether a good is one of this shelf's generators: a generator of this act or an earlier
    /// one (the settlement keeps what the household built).
    pub fn holdsGenerator(self: Shelf, rec: *const roster.Good) bool {
        return rec.generator != null and rec.act <= self.act;
    }
};

/// The verbs the act authors on its surface.
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

/// One entry this frame, a held verb or an owned generator: its kind and catalog index, its id
/// and name, its standing, and its line items joined for `in:`/`out:`.
pub const Entry = struct {
    kind: Kind,
    /// The verb's index in `cat.actions`, or the generator's in `cat.goods`.
    index: u16,
    /// The tile's key: the verb's or the good's id. Actions and goods share one id space, which
    /// the roster loader holds unique.
    id: []const u8,
    /// What free text searches: the verb's name, the generator's label or its good's name.
    name: []const u8,
    /// The word `state:` answers with.
    state: []const u8,
    /// Whether it can run now: the verb can begin, the generator can be collected.
    ready: bool,
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

/// The items of `lines`, space-separated, into `out`; returns the length written.
fn join(out: []u8, lines: []const roster.Line) usize {
    var w = std.Io.Writer.fixed(out);
    for (lines, 0..) |l, i| {
        if (i > 0) w.writeByte(' ') catch break;
        w.writeAll(l.item) catch break;
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
/// then the owned generators it quotes in authored good order. Pure over world + catalog.
pub fn held(world: *const World, e: Entity, cat: *const roster.Catalog, shelf: Shelf, buf: []Entry) []Entry {
    const quotes = world.get(e, comp.Quotes) orelse return buf[0..0];
    var n: usize = 0;
    for (cat.actions, 0..) |*rec, i| {
        if (!shelf.holds(rec)) continue;
        if (n == buf.len) break;
        const ai: u16 = @intCast(i);
        const q = quotes.verbs[ai] orelse continue;
        const verb = actions.verbOf(world, e, cat, ai) orelse continue;
        buf[n] = .{ .kind = .verb, .index = ai, .id = rec.id, .name = rec.name, .state = verbState(q.standing), .ready = q.standing == .ready };
        buf[n].in_len = join(&buf[n].in_buf, verb.input.slice());
        buf[n].out_len = join(&buf[n].out_buf, verb.output.slice());
        n += 1;
    }
    const goods = world.get(e, comp.Goods) orelse return buf[0..n];
    for (cat.goods, 0..) |*rec, i| {
        if (!shelf.holdsGenerator(rec) or goods.count[i] == 0) continue;
        if (n == buf.len) break;
        const gi: u16 = @intCast(i);
        const q = quotes.generators[gi] orelse continue;
        const label = rec.generator.?.label;
        buf[n] = .{ .kind = .generator, .index = gi, .id = rec.id, .name = if (label.len > 0) label else rec.name, .state = generatorState(q), .ready = q.ready() };
        const ins = roster.Lines.only(rec.input, .day);
        const outs = roster.Lines.only(rec.output, .day);
        buf[n].in_len = join(&buf[n].in_buf, ins.slice());
        buf[n].out_len = join(&buf[n].out_buf, outs.slice());
        n += 1;
    }
    return buf[0..n];
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
/// search and summary stay put and only the tiles scroll (Act II's long catalog). Without it
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
    const shown = filter(all, controls.query_text, Show.of(st.kind));

    var sbuf: [40]u8 = undefined;
    const summary = std.mem.print(&sbuf, "{d} of {d} actions shown", .{ shown.len, all.len }) catch "?";
    _ = try copy.summary_line(section, "summary", summary);

    const compact = ctx.res.view.metrics.width_class.atMost(.w440);
    // The tiles' host: the pane itself, or a scroll viewport filling the height left under
    // the summary.
    const host = if (scroll) |sc| blk: {
        const area = try section.box("results", .{ .w = .{ .pct_of_parent = 1.0 }, .h = @import("./terminal.zig").grow_h(ctx) }, .{});
        const sv = try scroll_view_mod.scroll_view(area, "scroll", .{ .height = 0, .framed = false, .name = "Available actions; scroll for more" }, sc);
        break :blk sv.content;
    } else section;
    const grid = try browser.tile_lanes(host, "grid", compact, if (shelf.density == .compact) compact_grid_gap else grid_gap);
    if (shown.len == 0) {
        const msg = if (all.len == 0) "No action is open yet. Build or research one." else "No action matches your search.";
        _ = try copy.empty_line(grid.grid, "empty", msg);
    }
    const act = ha.sim.data.migration.actOf(world, e);
    // Keyed by the verb's or the good's id, so focus follows it as the query changes.
    for (shown, 0..) |ent, pos| {
        const lane = grid.lanes[pos % 2];
        switch (ent.kind) {
            .generator => try generator_tile.generatorTile(lane, world, e, act, ent.index, shelf.density),
            .verb => if (try action_tile_mod.action_tile(lane, world, e, ent.index, ent.id, shelf.density)) |tl| {
                tl.el.set(.{
                    .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = action_tile_mod.height(shelf.density) },
                    .flow = .{ .dir = .column, .main = .center },
                }, .{});
                if (tl.clicked) _ = ctx.res.game.events.writer(ha.sim.events.BeginLabor).push(.{ .agent = e, .ai = ent.index });
            },
        }
    }
    return section;
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

/// Research every technology and own the three goods that grant a verb.
fn establishAll(w: *World, e: Entity, cat: *const roster.Catalog) void {
    const research = w.get(e, comp.Research).?;
    for (research.state[0..cat.technologies.len]) |*s| s.* = .researched;
    const goods = w.get(e, comp.Goods).?;
    for ([_][]const u8{ "firepit", "spring_well", "forge" }) |id| goods.count[cat.goodIndex(id).?] = 1;
    requote(w, e, cat);
}

/// Own the snares, a ready garden bed and the settlement's bed switched off: one generator of
/// each act, accumulating, ready and off.
fn ownGenerators(w: *World, e: Entity, cat: *const roster.Catalog) void {
    const goods = w.get(e, comp.Goods).?;
    const gens = w.get(e, comp.Generators).?;
    for ([_][]const u8{ "wire_snares", "garden_bed", "garden_bed_two" }) |id| goods.count[cat.goodIndex(id).?] = 1;
    gens.progress[cat.goodIndex("garden_bed").?] = 1e9;
    gens.mode[cat.goodIndex("garden_bed_two").?] = .off;
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
        const t = cat.actions[ent.index].tech orelse return error.UntaggedVerb;
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

test "the list is the verbs, then the owned generators of the act and earlier ones" {
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
    const want = [_][]const u8{ "wire_snares", "garden_bed", "garden_bed_two" };
    for (list[verbs..], want) |ent, id| {
        try testing.expectEqual(Kind.generator, ent.kind);
        try testing.expectEqualStrings(id, ent.id);
        try testing.expectEqualStrings(id, cat.goods[ent.index].id);
    }
    // The snares search by their label; Act I lists only its own generators.
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

test "a generator answers in: and out: from its daily lines, state: from its standing" {
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

    // Every generator eats biomass and yields food by the day.
    try testing.expectEqual(@as(usize, 3), filtered(&work, list, "type:generator in:biomass out:food", .all).len);

    const ready = filtered(&work, list, "type:generator state:ready", .all);
    try testing.expectEqual(@as(usize, 1), ready.len);
    try testing.expectEqualStrings("garden_bed", ready[0].id);
    const off = filtered(&work, list, "state:off", .all);
    try testing.expectEqual(@as(usize, 1), off.len);
    try testing.expectEqualStrings("garden_bed_two", off[0].id);
    const accumulating = filtered(&work, list, "state:accumulating", .all);
    try testing.expectEqual(@as(usize, 1), accumulating.len);
    try testing.expectEqualStrings("wire_snares", accumulating[0].id);
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
}
