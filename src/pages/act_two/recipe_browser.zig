//! `act_two/recipe_browser` — the Act II **recipe browser** (ACT2-12) over the act's records.
//!
//! The rows are the catalog's Act II buildable goods, each classified from the same quote
//! `capital.begin` reads, under the shared `catalog_controls` bar. The default sort is **reach
//! descending** (nearest first). A blank query answers *what can I act on now*: ready recipes plus
//! everything with reach ≥ `0.5`, excluding what the agent already owns. Any nonblank query widens
//! to *what does the catalog hold*: it searches every record that is neither locked nor waiting on
//! research, owned and far-off included; `tech:` matches the technology a recipe waits on. A build
//! in progress is always pinned and visible. The summary always counts against the full authored
//! catalog, even though locked and research-gated records contribute no row.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const capital = ha.capital;
const roster = ha.roster;
const query = ha.query;
const World = ha.world.World;
const Entity = ha.world.Entity;

const uic = ha.ui_client;
const el = uic.elements;
const El = el.El;
const Color = uic.Color;

const cc = @import("../templates/catalog_controls.zig");
const info = @import("../templates/action_info.zig");
const build_list = @import("../templates/build_list.zig");
const table = @import("../templates/table.zig");
const copy = @import("../templates/copy.zig");
const fmt = @import("../fmt.zig");

const Direction = uic.UiState.CatalogState.Direction;

/// Sort-by labels. `reach` is index 0 (the default), so the blank list opens reach-descending.
const sort_kinds = [_][]const u8{ "reach", "inputs", "time", "name", "none" };
const Sort = enum(usize) { reach = 0, inputs = 1, time = 2, name = 3, none = 4 };

const row_gap: f32 = 8;
const row_pad_x: f32 = 6;

/// The act this browser lists.
const act: u8 = 2;

/// Where a recipe stands for this agent, in the words its row shows.
pub const Kind = enum { ready, reach, owned, building, locked, needs_tech };

/// One recipe this frame: its catalog index and record, its quote and classification, and the
/// numbers its sorts read.
pub const Entry = struct {
    gi: u16,
    rec: *const roster.Good,
    q: capital.Quote,
    kind: Kind,
    inputs: f32,
    hours: f32,
    /// The name of the technology the recipe waits on, "" when none.
    tech: []const u8,
};

/// Whether a record is one of this act's recipes.
fn isRecipe(g: *const roster.Good) bool {
    return g.act == act and g.buildable and g.milestone == null;
}

/// How many recipes the act authors: the summary's total.
pub fn authoredTotal(cat: *const roster.Catalog) usize {
    var n: usize = 0;
    for (cat.goods) |*g| n += @intFromBool(isRecipe(g));
    return n;
}

fn kindOf(q: capital.Quote, building: bool) Kind {
    if (building) return .building;
    if (q.count > 0) return .owned;
    return switch (q.standing) {
        .tech => .needs_tech,
        .needs, .unlock => .locked,
        .ready => .ready,
        .busy, .energy, .short => .reach,
    };
}

/// Every recipe of the act, classified for agent `e`, into `buf`.
pub fn entries(world: *World, e: Entity, cat: *const roster.Catalog, buf: []Entry) []Entry {
    const busy = world.get(e, comp.Busy);
    var n: usize = 0;
    for (cat.goods, 0..) |*rec, i| {
        if (!isRecipe(rec)) continue;
        if (n == buf.len) break;
        const gi: u16 = @intCast(i);
        const q = capital.quote(world, e, cat, gi) orelse continue;
        var inputs: f32 = 0;
        for (rec.input) |l| if (l.per == .once) {
            inputs += l.n;
        };
        const tech: []const u8 = if (rec.tech) |t| (if (cat.technology(t)) |tr| tr.name else t) else "";
        buf[n] = .{
            .gi = gi,
            .rec = rec,
            .q = q,
            .kind = kindOf(q, busy != null and busy.?.isBuild(gi)),
            .inputs = inputs,
            .hours = rec.requires.?.hours,
            .tech = tech,
        };
        n += 1;
    }
    return buf[0..n];
}

fn stateWord(k: Kind) []const u8 {
    return switch (k) {
        .ready => "ready",
        .reach => "reach",
        .owned => "owned",
        .building => "building",
        .locked => "locked",
        .needs_tech => "needs tech",
    };
}

/// The row-facing `query` contract: `type`/`state`/`tech`; `is:` folds over state and type;
/// free text is the recipe name. `inReach` is ready-or-reach ≥ 0.5, matching BUILD.
const RecipeRow = struct {
    e: *const Entry,
    pub fn text(self: RecipeRow, f: query.Field) []const u8 {
        return switch (f) {
            .type => build_list.tierWord(self.e.rec),
            .state => stateWord(self.e.kind),
            .tech => self.e.tech,
            else => "",
        };
    }
    pub fn haystack(self: RecipeRow) []const u8 {
        return self.e.rec.name;
    }
    pub fn inReach(self: RecipeRow) bool {
        return self.e.kind == .ready or self.e.q.reach >= 0.5;
    }
};

const Shown = struct {
    idx: [roster.max_goods]usize = undefined,
    len: usize = 0,
};

/// Classify and sort the entries for this frame. Pure, so it is unit-testable.
fn classify(list: []const Entry, controls: cc.Catalog) Shown {
    const q = query.parse(controls.query_text);
    const blank = controls.query_text.len == 0;
    var out: Shown = .{};

    for (list, 0..) |*ent, i| {
        const pinned = ent.kind == .building; // a build in progress is always visible
        // Locked and research-gated records count toward the total but never make a row.
        const attemptable = ent.kind != .locked and ent.kind != .needs_tech;
        const keep = pinned or (attemptable and if (blank)
            // Blank: ready plus reach ≥ 0.5, excluding owned.
            ((ent.kind == .ready or ent.q.reach >= 0.5) and ent.kind != .owned)
        else
            // Any query searches every attemptable record, owned and far-off included.
            query.matches(&q, RecipeRow{ .e = ent }));
        if (keep) {
            out.idx[out.len] = i;
            out.len += 1;
        }
    }

    // Building pins to the top under every key and direction; `none` keeps authored order.
    const eff_sort: Sort = @enumFromInt(controls.sort);
    const dir: Direction = if (controls.dir != .none)
        controls.dir
    else switch (eff_sort) {
        .reach => .descending, // reach defaults to nearest-first
        .none => .none,
        else => .ascending,
    };
    const Ctx = struct { sort: Sort, dir: Direction, list: []const Entry };
    const Cmp = struct {
        fn less(c: Ctx, a: usize, b: usize) bool {
            const ea = &c.list[a];
            const eb = &c.list[b];
            const ab = ea.kind == .building;
            const bb = eb.kind == .building;
            if (ab != bb) return ab;
            var pl = false;
            var pe = true;
            switch (c.sort) {
                .reach => {
                    pl = ea.q.reach < eb.q.reach;
                    pe = ea.q.reach == eb.q.reach;
                },
                .inputs => {
                    pl = ea.inputs < eb.inputs;
                    pe = ea.inputs == eb.inputs;
                },
                .time => {
                    pl = ea.hours < eb.hours;
                    pe = ea.hours == eb.hours;
                },
                .name, .none => {},
            }
            return cc.lessThan(c.dir, pl, pe, ea.rec.name, eb.rec.name);
        }
    };
    std.sort.insertion(usize, out.idx[0..out.len], Ctx{ .sort = eff_sort, .dir = dir, .list = list }, Cmp.less);
    return out;
}

fn stateColor(th: uic.Theme, k: Kind) Color {
    return switch (k) {
        .ready => th.good,
        .reach => th.warn,
        .owned => th.dim,
        .building => th.acc,
        .locked, .needs_tech => th.line2,
    };
}

/// `12mi 4me` — the build order's once-lines, in the units the header speaks.
fn inputsText(buf: []u8, rec: *const roster.Good) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    var first = true;
    for (rec.input) |l| {
        if (l.per != .once) continue;
        var nbuf: [8]u8 = undefined;
        w.print("{s}{s}{s}", .{ if (first) "" else " ", fmt.fmt_amount(&nbuf, l.n), info.letterOf(l.item) }) catch break;
        first = false;
    }
    return w.buffered();
}

const col_recipe: f32 = 150;
const col_inputs: f32 = 110;
const col_time: f32 = 54;
const col_reach: f32 = 70;
const col_state: f32 = 90;

const lanes = [_]table.Lane{
    .{ .id = "recipe", .label = "RECIPE", .w = col_recipe },
    .{ .id = "inputs", .label = "INPUTS", .w = col_inputs },
    .{ .id = "time", .label = "TIME", .w = col_time },
    .{ .id = "reach", .label = "REACH", .w = col_reach },
    .{ .id = "state", .label = "STATE", .w = col_state },
};

/// Build the browser into `parent` for agent `e`. Returns the catalog index of the recipe whose
/// ready row was clicked this frame, else null — the caller begins the build.
pub fn recipe_browser(
    parent: El,
    world: *World,
    e: Entity,
    id: []const u8,
    catalog_state: ?*uic.UiState.CatalogState,
    search_owner: ?El,
) !?u16 {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const cat = &ctx.res.catalog;

    var buf: [roster.max_goods]Entry = undefined;
    const list = entries(world, e, cat, &buf);

    const outer = try parent.div(id);
    _ = outer.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(ha.tokens.gap.inline_);

    const controls = try cc.catalog_controls(outer, "a2_build_ctl", &sort_kinds, catalog_state, search_owner);
    const shown = classify(list, controls);

    var sbuf: [40]u8 = undefined;
    const summary = std.fmt.bufPrint(&sbuf, "{d} of {d} recipes shown", .{ shown.len, authoredTotal(cat) }) catch "?";
    _ = try copy.summary_line(outer, "summary", summary);

    const rows = try outer.div("rows");
    _ = rows.with_flow(.{ .dir = .column });
    _ = try table.table_header(rows, "header", &lanes, row_gap, row_pad_x);

    if (shown.len == 0) {
        _ = try copy.empty_line(rows, "empty", "No recipe matches your search.");
        return null;
    }

    var activated: ?u16 = null;
    for (shown.idx[0..shown.len]) |i| {
        const ent = &list[i];
        // Keyed by the recipe's id, so focus follows it through a re-sort or filter.
        // The same gate `capital.begin` applies; another unit of an owned recipe is a build too.
        const enabled = ent.kind != .building and ent.q.ready();
        const r = try table.control_row(rows, ent.rec.id, row_gap, row_pad_x, 5, .{ .enabled = enabled, .name = ent.rec.name, .role = .button });
        const row = r.el;
        const q = r.q;
        const chrome: Color = if (ent.kind == .building) th.fg else if (!enabled)
            th.dim
        else if (q.hovering or q.focused)
            th.acc
        else
            th.fg;

        var ibuf: [48]u8 = undefined;
        var tbuf: [12]u8 = undefined;
        var rbuf: [8]u8 = undefined;
        const time_txt = std.fmt.bufPrint(&tbuf, "{d:.1}d", .{ent.hours / 24.0}) catch "?";
        const reach_txt = std.fmt.bufPrint(&rbuf, "{d:.0}%", .{std.math.clamp(ent.q.reach, 0, 1) * 100}) catch "?";

        try table.cell(row, "recipe", col_recipe, ent.rec.name, chrome, false);
        try table.cell(row, "inputs", col_inputs, inputsText(&ibuf, ent.rec), if (enabled) th.dim else chrome, false);
        try table.cell(row, "time", col_time, time_txt, if (enabled) th.dim else chrome, false);
        try table.cell(row, "reach", col_reach, reach_txt, if (enabled) th.dim else chrome, true);
        try table.cell(row, "state", col_state, stateWord(ent.kind), stateColor(th, ent.kind), true);

        if (enabled and q.clicked) activated = ent.gi;
    }
    return activated;
}

// ============================ Tests =====================================================

const testing = std.testing;

/// An agent carried across the curtain, holding the given stocks of biomass and minerals.
fn settler(w: *World, cat: *const roster.Catalog, biomass: f32, minerals: f32) Entity {
    const e = w.spawn(.{
        comp.Vigor{ .v = 15, .max = 15 },
        comp.InventoryFood{ .v = 20, .quality = 1, .spoils = 0 },
        comp.InventoryMaterial{ .v = biomass },
        comp.Goods{},
        comp.Granted{},
    });
    _ = ha.migration.migrate_to_act_two(w, e, cat);
    _ = ha.ledger.move(w, e, .minerals, minerals);
    return e;
}

test "the total counts every recipe of the act, though gated ones make no row" {
    var w = World.init();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat, 0, 0);
    var buf: [roster.max_goods]Entry = undefined;
    const list = entries(&w, e, &cat, &buf);
    try testing.expectEqual(authoredTotal(&cat), list.len);
    try testing.expectEqual(@as(usize, 50), authoredTotal(&cat));
    // At the curtain most recipes wait on research; none of those is ever shown blank.
    const shown = classify(list, .{ .query_text = "", .sort = 0, .dir = .none });
    for (shown.idx[0..shown.len]) |i| {
        try testing.expect(list[i].kind != .needs_tech and list[i].kind != .locked);
    }
}

test "blank shows ready plus reach of a half and more, owned excluded, nearest first" {
    var w = World.init();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat, 10, 0);
    // Own a firepit: it stays out of the blank list though the settlement could build another.
    w.get(e, comp.Goods).?.count[cat.goodIndex("firepit").?] = 1;
    var buf: [roster.max_goods]Entry = undefined;
    const list = entries(&w, e, &cat, &buf);
    const shown = classify(list, .{ .query_text = "", .sort = 0, .dir = .none });
    try testing.expect(shown.len > 0);
    var prev: f32 = 2;
    for (shown.idx[0..shown.len]) |i| {
        const ent = list[i];
        try testing.expect(ent.kind != .owned);
        try testing.expect(ent.kind == .ready or ent.q.reach >= 0.5);
        try testing.expect(ent.q.reach <= prev);
        prev = ent.q.reach;
    }
    // A query reaches the owned firepit.
    const owned = classify(list, .{ .query_text = "firepit", .sort = 0, .dir = .none });
    try testing.expectEqual(@as(usize, 1), owned.len);
    try testing.expectEqual(Kind.owned, list[owned.idx[0]].kind);
}

test "tech: finds recipes whose technology is researched; a build in progress pins first" {
    var w = World.init();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat, 40, 40);
    // Establish the loom; its recipes become attemptable and answer `tech:loom`.
    w.get(e, comp.Research).?.state[cat.techIndex("loom_ropewalk").?] = .researched;
    var buf: [roster.max_goods]Entry = undefined;
    var list = entries(&w, e, &cat, &buf);
    const loom = classify(list, .{ .query_text = "tech:loom", .sort = 0, .dir = .none });
    try testing.expect(loom.len > 0);
    for (loom.idx[0..loom.len]) |i| try testing.expectEqualStrings("loom_ropewalk", list[i].rec.tech.?);

    // Begin the ropewalk: from now on it is pinned above everything, under any sort.
    const ropewalk = cat.goodIndex("ropewalk").?;
    const total = ha.res.hours_to_secs(cat.goods[ropewalk].requires.?.hours, 20);
    w.add(e, comp.Busy{ .doing = .{ .build = ropewalk }, .total = total, .remaining = total, .quality = 1 });
    list = entries(&w, e, &cat, &buf);
    for ([_]Sort{ .reach, .inputs, .time, .name, .none }) |s| {
        const shown = classify(list, .{ .query_text = "", .sort = @intFromEnum(s), .dir = .descending });
        try testing.expectEqual(Kind.building, list[shown.idx[0]].kind);
    }
}
