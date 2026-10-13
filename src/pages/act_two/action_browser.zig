//! `act_two/action_browser` — the Act II **action browser** (ACT2-11): every verb of the act the
//! agent holds, as Act I's `action_tile`s in a two-column collection under the shared
//! `catalog_controls` bar (search + disclosed Sort-by/Direction).
//!
//! The rows are the catalog's Act II verbs on the surface that the agent holds — through a good
//! that grants one, or its researched technology — and each tile formats and gates from the same
//! quote `actions.begin` reads. Unlike BUILD, ACTIONS has **no default in-reach filter**: a blank
//! query lists every held verb in authored order, the ones that cannot begin now dimmed. The
//! shared `query` parser answers `in:`/`out:` from the verb's lines, `state:` from its standing
//! (ready, busy, short) and free text from its name. Default sort is `none` (authored order,
//! Direction disabled); ready/time/energy/name sort in both directions. The summary reads
//! `{visible} of {held} actions shown`.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const actions = ha.actions;
const roster = ha.roster;
const query = ha.query;
const World = ha.world.World;
const Entity = ha.world.Entity;

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;

const tile_mod = @import("../templates/action_tile.zig");
const cc = @import("../templates/catalog_controls.zig");

const Direction = uic.UiState.CatalogState.Direction;

/// Sort-by labels. `none` is index 0 (authored order; Direction disabled), matching the spec.
const sort_kinds = [_][]const u8{ "none", "ready", "time", "energy", "name" };
const Sort = enum(usize) { none = 0, ready = 1, time = 2, energy = 3, name = 4 };

const tile_content_height: f32 = 81;
const grid_gap: f32 = 10;

/// The act this browser lists.
const act: u8 = 2;
/// The most verbs one frame lists; the act authors twenty.
const max_verbs = 64;

/// One held verb this frame: its catalog index and record, the standing and price its sort
/// keys read, and its line items joined for `in:`/`out:`.
pub const Entry = struct {
    ai: u16,
    rec: *const roster.Action,
    standing: actions.Standing,
    hours: f32,
    energy: f32,
    in_buf: [64]u8 = undefined,
    in_len: usize = 0,
    out_buf: [64]u8 = undefined,
    out_len: usize = 0,

    pub fn ready(self: *const Entry) bool {
        return self.standing == .ready;
    }

    fn ins(self: *const Entry) []const u8 {
        return self.in_buf[0..self.in_len];
    }

    fn outs(self: *const Entry) []const u8 {
        return self.out_buf[0..self.out_len];
    }
};

/// The word `state:` answers with. Energy and inputs both read as short: either way the body
/// cannot begin it now.
fn stateWord(s: actions.Standing) []const u8 {
    return switch (s) {
        .ready => "ready",
        .busy => "busy",
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

/// Every held verb of the act on the surface, in authored order, into `buf`.
pub fn entries(world: *World, e: Entity, cat: *const roster.Catalog, cfg: ha.res.Config, buf: []Entry) []Entry {
    var n: usize = 0;
    for (cat.actions, 0..) |*rec, i| {
        if (rec.act != act or !rec.on_surface) continue;
        if (n == buf.len) break;
        const ai: u16 = @intCast(i);
        const q = actions.quote(world, e, cat, cfg, ai) orelse continue;
        buf[n] = .{
            .ai = ai,
            .rec = rec,
            .standing = q.standing,
            .hours = q.verb.requires.hours,
            .energy = q.verb.requires.energy,
        };
        buf[n].in_len = join(&buf[n].in_buf, q.verb.input.slice());
        buf[n].out_len = join(&buf[n].out_buf, q.verb.output.slice());
        n += 1;
    }
    return buf[0..n];
}

/// The row-facing `query` contract: `in:`/`out:` match the verb's line items, `state:` its
/// standing; `is:` folds over both; `type` and `tech` always miss. Free text is the name.
/// `inReach` is ready, so `state:in-reach` works though ACTIONS does not filter by it.
const ActionRow = struct {
    e: *const Entry,
    pub fn text(self: ActionRow, f: query.Field) []const u8 {
        return switch (f) {
            .in => self.e.ins(),
            .out => self.e.outs(),
            .state => stateWord(self.e.standing),
            else => "",
        };
    }
    pub fn haystack(self: ActionRow) []const u8 {
        return self.e.rec.name;
    }
    pub fn inReach(self: ActionRow) bool {
        return self.e.ready();
    }
};

/// The rows that survive the query, in sort order, as indices into the entry list.
const Shown = struct {
    idx: [max_verbs]usize = undefined,
    len: usize = 0,
};

fn classify(list: []const Entry, controls: cc.Catalog) Shown {
    const q = query.parse(controls.query_text);
    const blank = controls.query_text.len == 0;
    var out: Shown = .{};
    for (list, 0..) |*ent, i| {
        // No default in-reach filter: blank keeps every held verb; a query runs the parser.
        if (blank or query.matches(&q, ActionRow{ .e = ent })) {
            out.idx[out.len] = i;
            out.len += 1;
        }
    }

    // `none` keeps authored order and ignores Direction; the rest apply the chosen key with the
    // shared name tie-break and direction semantics.
    const eff_sort: Sort = @enumFromInt(controls.sort);
    if (eff_sort != .none) {
        const Ctx = struct { sort: Sort, dir: Direction, list: []const Entry };
        const dir: Direction = if (controls.dir != .none) controls.dir else .ascending;
        const Cmp = struct {
            fn less(c: Ctx, a: usize, b: usize) bool {
                const ea = &c.list[a];
                const eb = &c.list[b];
                var pl = false;
                var pe = true;
                switch (c.sort) {
                    .none, .name => {},
                    .ready => {
                        // Ready first: a ready verb sorts before one that cannot begin.
                        pl = @intFromBool(ea.ready()) > @intFromBool(eb.ready());
                        pe = ea.ready() == eb.ready();
                    },
                    .time => {
                        pl = ea.hours < eb.hours;
                        pe = ea.hours == eb.hours;
                    },
                    .energy => {
                        pl = ea.energy < eb.energy;
                        pe = ea.energy == eb.energy;
                    },
                }
                return cc.lessThan(c.dir, pl, pe, ea.rec.name, eb.rec.name);
            }
        };
        std.sort.insertion(usize, out.idx[0..out.len], Ctx{ .sort = eff_sort, .dir = dir, .list = list }, Cmp.less);
    }
    return out;
}

/// Build the browser into `parent` for agent `e`. Returns the catalog index of the verb whose
/// ready tile was clicked this frame, else null — the caller begins it.
pub fn action_browser(
    parent: El,
    world: *World,
    e: Entity,
    id: []const u8,
    catalog_state: ?*uic.UiState.CatalogState,
    search_owner: ?El,
) !?u16 {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;

    var buf: [max_verbs]Entry = undefined;
    const list = entries(world, e, &ctx.res.catalog, ctx.res.config, &buf);

    const outer = try parent.div(id);
    _ = outer.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(ha.tokens.gap.stack);

    // Heading + the count of verbs held.
    const heading = try outer.div("heading");
    _ = heading.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .baseline });
    const copy = try heading.div("copy");
    _ = copy.with_flow(.{ .dir = .column, .cross = .start });
    _ = (try copy.text("title", "ACTIONS")).with_style(.{ style.h3, Style{ .text = th.fg } });
    _ = (try copy.text("subtitle", "What will the settlement do now?"))
        .with_style(.{Style{ .font = 11, .text = th.dim }});
    var count_buf: [16]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d} VERBS", .{list.len}) catch "VERBS";
    _ = (try heading.text("count", count)).with_style(.{ style.eyebrow, Style{ .text = th.dim } });

    // Controls bar + classification/sort.
    const controls = try cc.catalog_controls(outer, "a2_actions_ctl", &sort_kinds, catalog_state, search_owner);
    const shown = classify(list, controls);

    var sbuf: [40]u8 = undefined;
    const summary = std.fmt.bufPrint(&sbuf, "{d} of {d} actions shown", .{ shown.len, list.len }) catch "?";
    _ = (try outer.text("summary", summary)).with_style(.{ style.small, Style{ .text = th.dim } });

    // Two-column compact grid (one column at the compact breakpoint).
    const compact = ctx.res.view.metrics.width_class.atMost(.w440);
    const grid = try outer.div("grid");
    _ = grid.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
    const lanes: [2]El = if (compact) blk: {
        _ = grid.with_flow(.{ .dir = .column, .cross = .start }).with_gap(grid_gap);
        break :blk .{ grid, grid };
    } else blk: {
        _ = grid.with_flow(.{ .dir = .row, .cross = .start }).with_gap(grid_gap);
        const left = try grid.div("left");
        _ = left.with_size(.grow, .fit_children).with_flow(.{ .dir = .column, .cross = .start }).with_gap(grid_gap);
        const right = try grid.div("right");
        _ = right.with_size(.grow, .fit_children).with_flow(.{ .dir = .column, .cross = .start }).with_gap(grid_gap);
        break :blk .{ left, right };
    };

    if (shown.len == 0) {
        const msg = if (list.len == 0) "No action is open yet. Build or research one." else "No action matches your search.";
        _ = (try grid.text("empty", msg)).with_style(.{ style.body, Style{ .text = th.line2 } });
        return null;
    }

    var activated: ?u16 = null;
    for (shown.idx[0..shown.len], 0..) |i, pos| {
        const ent = &list[i];
        // Keyed by the verb's id, so focus and selection follow it through a re-sort or filter.
        if (try tile_mod.action_tile(lanes[pos % 2], world, e, ent.ai, ent.rec.id)) |t| {
            _ = t.el.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = tile_content_height })
                .with_flow(.{ .dir = .column, .main = .center });
            if (t.clicked) activated = ent.ai;
        }
    }
    return activated;
}

// ============================ Tests =====================================================

const testing = std.testing;

/// An agent carried across the curtain: holding the Act I starting goods and none of Act II's.
fn settler(w: *World, cat: *const roster.Catalog) Entity {
    const e = w.spawn(.{
        comp.Vigor{ .v = 15, .max = 15 },
        comp.InventoryFood{ .v = 20, .quality = 1, .spoils = 0 },
        comp.InventoryMaterial{ .v = 30 },
        comp.Goods{},
        comp.Granted{},
    });
    _ = ha.migration.migrate_to_act_two(w, e, cat);
    return e;
}

/// Research every technology and own the three goods that grant a verb.
fn establishAll(w: *World, e: Entity, cat: *const roster.Catalog) void {
    const research = w.get(e, comp.Research).?;
    for (research.state[0..cat.technologies.len]) |*s| s.* = .researched;
    const goods = w.get(e, comp.Goods).?;
    for ([_][]const u8{ "firepit", "spring_well", "forge" }) |id| goods.count[cat.goodIndex(id).?] = 1;
}

fn countAct(cat: *const roster.Catalog) usize {
    var n: usize = 0;
    for (cat.actions) |a| n += @intFromBool(a.act == act and a.on_surface);
    return n;
}

test "the curtain opens only the verbs its researched tiles establish" {
    var w = World.init();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat);
    var buf: [max_verbs]Entry = undefined;
    const list = entries(&w, e, &cat, .{}, &buf);
    // Foraging and Woodcutting arrive researched; every verb listed is one of theirs.
    try testing.expect(list.len > 0 and list.len < countAct(&cat));
    for (list) |ent| {
        const t = ent.rec.tech orelse return error.UntaggedVerb;
        try testing.expect(std.mem.eql(u8, t, "foraging") or std.mem.eql(u8, t, "woodcutting"));
    }
}

test "an established settlement lists every verb of the act in authored order" {
    var w = World.init();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat);
    establishAll(&w, e, &cat);
    var buf: [max_verbs]Entry = undefined;
    const list = entries(&w, e, &cat, .{}, &buf);
    try testing.expectEqual(countAct(&cat), list.len);
    const shown = classify(list, .{ .query_text = "", .sort = 0, .dir = .none });
    try testing.expectEqual(list.len, shown.len);
    for (shown.idx[0..shown.len], 0..) |i, k| try testing.expectEqual(k, i);
    // `none` ignores Direction.
    const reversed = classify(list, .{ .query_text = "", .sort = @intFromEnum(Sort.none), .dir = .descending });
    try testing.expectEqual(@as(usize, 0), reversed.idx[0]);
}

test "in: and out: match the verb's lines; state: its standing" {
    var w = World.init();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat);
    establishAll(&w, e, &cat);
    var buf: [max_verbs]Entry = undefined;
    const list = entries(&w, e, &cat, .{}, &buf);

    const water = classify(list, .{ .query_text = "out:water", .sort = 0, .dir = .none });
    try testing.expect(water.len > 0 and water.len < list.len);
    for (water.idx[0..water.len]) |i| try testing.expect(std.mem.indexOf(u8, list[i].outs(), "water") != null);

    const fuel_in = classify(list, .{ .query_text = "in:fuel", .sort = 0, .dir = .none });
    try testing.expect(fuel_in.len > 0);
    for (fuel_in.idx[0..fuel_in.len]) |i| try testing.expect(std.mem.indexOf(u8, list[i].ins(), "fuel") != null);

    // The settlement holds no fuel yet, so nothing that burns it can begin.
    const ready_fuel = classify(list, .{ .query_text = "in:fuel state:ready", .sort = 0, .dir = .none });
    try testing.expectEqual(@as(usize, 0), ready_fuel.len);
}

test "sort by energy ascending orders by the effective price" {
    var w = World.init();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat);
    establishAll(&w, e, &cat);
    var buf: [max_verbs]Entry = undefined;
    const list = entries(&w, e, &cat, .{}, &buf);
    const shown = classify(list, .{ .query_text = "", .sort = @intFromEnum(Sort.energy), .dir = .ascending });
    var prev: f32 = -1;
    for (shown.idx[0..shown.len]) |i| {
        try testing.expect(list[i].energy >= prev);
        prev = list[i].energy;
    }
}
