//! `actions_section` — the ACTIONS pane, the same template on every act: the heading with the
//! act's verb count, one search field, a count-only summary, and the held verbs as
//! `action_tile`s in two growing columns (one at the compact breakpoint). Only the content
//! differs per act (`Shelf`: which verbs, the subtitle, whether the eating policy rides in the
//! grid); the behavior is one.
//!
//! **No sorting.** Verbs read in authored order. A blank query lists every held verb, the ones
//! that cannot begin now dimmed; the shared `query` parser answers `in:`/`out:` from a verb's
//! lines, `state:` from its standing (ready, busy, short) and free text from its name.

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
const El = el.El;

const action_tile_mod = @import("./action_tile.zig");
const eating_policy_mod = @import("./eating_policy.zig");
const cc = @import("./catalog_controls.zig");
const browser = @import("./browser.zig");
const copy = @import("./copy.zig");

const tile_content_height: f32 = 81; // 82px outer height including action_tile's 1px inset
const section_gap: f32 = 12;
const grid_gap: f32 = 10;
/// The most verbs one frame lists.
const max_verbs = 64;

/// One act's ACTIONS content.
pub const Shelf = struct {
    act: u8,
    subtitle: []const u8,
    /// Act I's body eats by a standing policy; its slider rides at the foot of the grid.
    eating_policy: bool = false,

    /// Whether a verb record is one of this shelf's: on the surface and of this act.
    pub fn holds(self: Shelf, rec: *const roster.Action) bool {
        return rec.on_surface and rec.act == self.act;
    }
};

/// The verbs the act authors on its surface: the heading's count.
pub fn authoredTotal(cat: *const roster.Catalog, shelf: Shelf) usize {
    var n: usize = 0;
    for (cat.actions) |*rec| n += @intFromBool(shelf.holds(rec));
    return n;
}

/// One held verb this frame: its catalog index and record, its standing, and its line items
/// joined for `in:`/`out:`.
pub const Entry = struct {
    ai: u16,
    rec: *const roster.Action,
    standing: actions.Standing,
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

/// The word `state:` answers with. Energy and inputs both read as short.
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

/// The row-facing `query` contract.
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
        return self.e.standing == .ready;
    }
};

/// Every held verb of the shelf in authored order. Pure over world + catalog.
pub fn held(world: *World, e: Entity, cat: *const roster.Catalog, cfg: ha.res.Config, shelf: Shelf, buf: []Entry) []Entry {
    var n: usize = 0;
    for (cat.actions, 0..) |*rec, i| {
        if (!shelf.holds(rec)) continue;
        if (n == buf.len) break;
        const ai: u16 = @intCast(i);
        const q = actions.quote(world, e, cat, cfg, ai) orelse continue;
        buf[n] = .{ .ai = ai, .rec = rec, .standing = q.standing };
        buf[n].in_len = join(&buf[n].in_buf, q.verb.input.slice());
        buf[n].out_len = join(&buf[n].out_buf, q.verb.output.slice());
        n += 1;
    }
    return buf[0..n];
}

/// Keep the entries `query_text` admits, in place and in order; returns the kept prefix.
pub fn filter(list: []Entry, query_text: []const u8) []Entry {
    if (query_text.len == 0) return list;
    const q = query.parse(query_text);
    var n: usize = 0;
    for (list) |ent| {
        if (query.matches(&q, ActionRow{ .e = &ent })) {
            list[n] = ent;
            n += 1;
        }
    }
    return list[0..n];
}

fn placePolicy(parent: El, world: *World, e: Entity) !void {
    if (world.get(e, comp.Metabolism)) |met| {
        const value = try eating_policy_mod.eating_policy(parent, "eating_policy", ha.eating.valueFromRate(met.rate), true);
        met.rate = ha.eating.rate(value);
    } else {
        _ = try eating_policy_mod.eating_policy(parent, "eating_policy", 50, false);
    }
}

/// Build the pane for agent `e`. A ready tile's click begins its verb. `catalog_state` and
/// `search_owner` keep the query on an always-built owner when given.
pub fn actions_section(parent: El, world: *World, e: Entity, id: []const u8, shelf: Shelf, catalog_state: ?*uic.UiState.CatalogState, search_owner: ?El) !El {
    const ctx = parent.ctx;
    const cat = &ctx.res.catalog;

    const section = try parent.div(id);
    _ = section.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start }).with_gap(section_gap);

    // The heading counts the verbs the actor holds — the same set the summary counts against.
    var buf: [max_verbs]Entry = undefined;
    const all = held(world, e, cat, ctx.res.config, shelf, &buf);
    var count_buf: [16]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d} VERBS", .{all.len}) catch "VERBS";
    _ = try browser.browser_heading(section, "heading", "ACTIONS", shelf.subtitle, count);

    const controls = try cc.catalog_controls(section, "actions_ctl", catalog_state, search_owner);
    const shown = filter(all, controls.query_text);

    var sbuf: [40]u8 = undefined;
    const summary = std.fmt.bufPrint(&sbuf, "{d} of {d} actions shown", .{ shown.len, all.len }) catch "?";
    _ = try copy.summary_line(section, "summary", summary);

    const compact = ctx.res.view.metrics.width_class.atMost(.w440);
    const grid = try browser.tile_lanes(section, "grid", compact, grid_gap);
    if (shown.len == 0) {
        const msg = if (all.len == 0) "No action is open yet. Build or research one." else "No action matches your search.";
        _ = try copy.empty_line(grid.grid, "empty", msg);
    }
    // Keyed by the verb's id, so focus follows it as the query changes.
    for (shown, 0..) |ent, pos| {
        if (try action_tile_mod.action_tile(grid.lanes[pos % 2], world, e, ent.ai, ent.rec.id)) |tl| {
            _ = tl.el.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = tile_content_height })
                .with_flow(.{ .dir = .column, .main = .center });
            if (tl.clicked) actions.begin(world, e, ctx.res, ent.ai);
        }
    }
    if (shelf.eating_policy) try placePolicy(grid.lanes[1], world, e);
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

test "the curtain opens only the verbs its researched tiles establish" {
    var w = World.init();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat);
    var buf: [max_verbs]Entry = undefined;
    const list = held(&w, e, &cat, .{}, act_two_test, &buf);
    try testing.expect(list.len > 0 and list.len < authoredTotal(&cat, act_two_test));
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
    const list = held(&w, e, &cat, .{}, act_two_test, &buf);
    try testing.expectEqual(authoredTotal(&cat, act_two_test), list.len);
    for (list[1..], 0..) |ent, i| try testing.expect(ent.ai > list[i].ai);
}

test "in: and out: match the verb's lines; state: its standing" {
    var w = World.init();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat);
    establishAll(&w, e, &cat);
    var buf: [max_verbs]Entry = undefined;
    const n = held(&w, e, &cat, .{}, act_two_test, &buf).len;

    var work: [max_verbs]Entry = undefined;
    @memcpy(work[0..n], buf[0..n]);
    const water = filter(work[0..n], "out:water");
    try testing.expect(water.len > 0 and water.len < n);
    for (water) |ent| try testing.expect(std.mem.indexOf(u8, ent.outs(), "water") != null);

    @memcpy(work[0..n], buf[0..n]);
    const fuel_in = filter(work[0..n], "in:fuel");
    try testing.expect(fuel_in.len > 0);
    for (fuel_in) |ent| try testing.expect(std.mem.indexOf(u8, ent.ins(), "fuel") != null);

    // The settlement holds no fuel yet, so nothing that burns it can begin.
    @memcpy(work[0..n], buf[0..n]);
    try testing.expectEqual(@as(usize, 0), filter(work[0..n], "in:fuel state:ready").len);
}

test "actions tiles keep their height" {
    try testing.expectEqual(@as(f32, 81), tile_content_height);
}
