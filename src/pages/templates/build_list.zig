//! `build_list` — the BUILD pane's searched, sorted recipe table over the **live catalog**,
//! shared by every act. Only the content differs between acts (`Shelf`: which records are
//! recipes, the subtitle, the milestone card's copy); the behavior is one.
//!
//! It is built from the shared catalog surface: a `catalog_controls` search field and a
//! count-only summary driving `capital_row`s filtered by the one `query` parser. The axis
//! belongs to the player: type to search, or click a column header (RECIPE, COST, TIME, STATE)
//! to sort on it — again to flip the direction — with the arrow on the column in force.
//!
//! **What the list shows.** With no query the list shows the act's complete shelf, including
//! owned, unaffordable, prerequisite-short, and research-gated rows; those rows stay visible and
//! disabled instead of disappearing. Search only narrows that shelf. A **build in progress is
//! always visible and pinned to the top** (you need the way out). The summary reports the
//! shelf's authored total; the milestone remains outside it because it is the act goal rather
//! than an ordinary recipe.
//!
//! **Build lifecycle:** starting a ready/owned row pays through `capital.begin`; the live
//! `Busy` row renders its own progress/time and a cancel corner that calls
//! `capital.cancel_build` (the refund path); completion is the simulation's — no UI-local timers.
//!
//! **Milestone:** the act's milestone good is not a row. It is a `milestone_goal` pinned
//! below the list, **outside** the filter/sort, because it is how the act ends rather than an
//! item in it. Its lifecycle and every requirement recompute from authoritative state each frame.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const capital = ha.capital;
const roster = ha.roster;
const ledger = ha.ledger;
const query = ha.query;
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const World = ha.world.World;
const Entity = ha.world.Entity;

const row_mod = @import("./capital_row.zig");
const capital_row = row_mod.capital_row;
const capital_header = row_mod.capital_header;
const Kind = row_mod.Kind;
const cc = @import("./catalog_controls.zig");
const milestone_mod = @import("./milestone_goal.zig");
const scroll_view_mod = @import("./scroll_view.zig");

const Direction = uic.UiState.CatalogState.Direction;

/// The milestone card's authored copy. The requirements and lifecycle are computed from the
/// record's `unlock` and live state; only the words are the act's.
pub const MilestoneCopy = struct {
    which: roster.Milestone,
    kicker: []const u8,
    copy: []const u8,
    explanation: []const u8,
    /// The CTA once the milestone can be raised (`RAISE SHELTER`).
    action: []const u8,
};

/// One act's BUILD content: which records are its recipes, the heading's subtitle, and the
/// milestone pinned below the list (null while the act authors none).
pub const Shelf = struct {
    act: u8,
    /// Act I personal crafting lists only the crude tier.
    crude_only: bool = false,
    subtitle: []const u8,
    milestone: ?MilestoneCopy = null,
    /// How the act splits the table's lane (`capital_row.Widths`); the default is Act I's.
    widths: row_mod.Widths = .{},
    /// Whether goods the agent already owns from an earlier act stay on the shelf. Anything can
    /// be built again (a second unit is stock to sell, its effect does not compound), so Act II
    /// keeps the Act I goods the settlement carried — unless the act authors its own recipe of
    /// the same name, which then stands for it.
    carry_owned: bool = false,

    /// Whether a record is one of this shelf's recipes: buildable, of this act, of an allowed
    /// tier, and not a milestone (which is the goal, not a row).
    pub fn holds(self: Shelf, g: *const roster.Good) bool {
        return g.buildable and g.milestone == null and g.act == self.act and
            (!self.crude_only or g.tier == .crude);
    }
};

/// This shelf's recipes. This is the **authored total** the summary reports against.
pub fn authoredTotal(cat: *const roster.Catalog, shelf: Shelf) usize {
    var n: usize = 0;
    for (cat.goods) |*g| n += @intFromBool(shelf.holds(g));
    return n;
}

/// Whether the act authors a recipe named `name` (an earlier act's good of that name is then
/// shadowed by it rather than listed twice).
fn authorsName(cat: *const roster.Catalog, shelf: Shelf, name: []const u8) bool {
    for (cat.goods) |*g| if (shelf.holds(g) and std.mem.eql(u8, g.name, name)) return true;
    return false;
}

/// Whether good `gi` is on agent `e`'s shelf: one of the act's recipes, or — with
/// `carry_owned` — a buildable earlier-act good the agent owns that the act does not shadow.
pub fn onShelf(world: *World, e: Entity, cat: *const roster.Catalog, shelf: Shelf, gi: usize) bool {
    const rec = &cat.goods[gi];
    if (shelf.holds(rec)) return true;
    if (!shelf.carry_owned or !rec.buildable or rec.milestone != null or rec.act >= shelf.act) return false;
    const goods = world.get(e, comp.Goods) orelse return false;
    return goods.count[gi] > 0 and !authorsName(cat, shelf, rec.name);
}

/// The shelf's total for agent `e`: the authored recipes plus the carried goods it owns —
/// the heading's count and the summary's denominator.
pub fn shelfTotal(world: *World, e: Entity, cat: *const roster.Catalog, shelf: Shelf) usize {
    var n: usize = 0;
    for (cat.goods, 0..) |_, gi| n += @intFromBool(onShelf(world, e, cat, shelf, gi));
    return n;
}

/// The first of the shelf's recipes whose build order would elide in the act's COST lane, or
/// null when every one fits — what each act's own test holds its `widths` to.
pub fn costOverflow(cat: *const roster.Catalog, shelf: Shelf) ?*const roster.Good {
    for (cat.goods) |*g| {
        if (shelf.holds(g) and !shelf.widths.costFits(row_mod.orderChars(shelf.act, g))) return g;
    }
    return null;
}

/// The sort keys, one per sortable column: STATE sorts by the row's state, COST by the order's
/// units, TIME by hours, RECIPE by name. STATE is the default (index 0), so the blank list opens
/// on what you can build now, nearest first.
pub const Sort = enum(usize) { state = 0, inputs = 1, time = 2, name = 3 };
const sort_count = @typeInfo(Sort).@"enum".field_names.len;

/// How near a state is to "build it now" — the STATE sort's groups, highest first when
/// descending: ready, then in reach (ordered by reach inside the group), owned, blocked on a
/// prerequisite or research, and locked behind conditions. A build in progress is pinned
/// above every group regardless.
fn stateRank(kind: Kind) u8 {
    return switch (kind) {
        .building => 6,
        .ready => 5,
        .busy => 4,
        .reach => 3,
        .owned => 2,
        .blocked => 1,
        .locked => 0,
    };
}

/// The direction a column sorts in when first clicked: nearest first for STATE, otherwise
/// cheapest/quickest/A–Z.
fn naturalDir(s: Sort) Direction {
    return if (s == .state) .descending else .ascending;
}

/// One classified recipe for this frame: its quote (which carries the catalog index and the
/// record), its display `kind`, the inputs/hours it sorts by, and the words it answers `query`
/// fields with. Everything is a record string or a live number — no allocation.
pub const Entry = struct {
    q: capital.Quote,
    kind: Kind,
    inputs: f32,
    hours: f32,
    name: []const u8,
    type_word: []const u8,
    state_word: []const u8,
    /// The items the build order spends and the recipe yields, space-separated, for `in:`/`out:`.
    in_buf: [64]u8 = undefined,
    in_len: usize = 0,
    out_buf: [64]u8 = undefined,
    out_len: usize = 0,
    /// The name of the technology the recipe waits on, "" when none.
    tech: []const u8,
};

/// The row-facing `query` contract: `type`/`state`/`tech` fields (and `is:` folds over state
/// and type), free text over the name, and the `state:in-reach` fact.
const RecipeRow = struct {
    e: *const Entry,
    pub fn text(self: RecipeRow, f: query.Field) []const u8 {
        return switch (f) {
            .type => self.e.type_word,
            .state => self.e.state_word,
            .in => self.e.in_buf[0..self.e.in_len],
            .out => self.e.out_buf[0..self.e.out_len],
            .tech => self.e.tech,
            else => "",
        };
    }
    pub fn haystack(self: RecipeRow) []const u8 {
        return self.e.name;
    }
    pub fn inReach(self: RecipeRow) bool {
        return self.e.kind == .ready or self.e.q.reach >= 0.5;
    }
};

/// The state word a recipe answers `state:` / `is:` with — the same word the row's color says.
fn stateWord(kind: Kind) []const u8 {
    return switch (kind) {
        .ready => "ready",
        .busy => "busy",
        .reach => "reach",
        .building => "building",
        .blocked => "blocked",
        .locked => "locked",
        .owned => "owned",
    };
}

/// The items of `lines`, space-separated, into `out`; returns the length written.
fn joinItems(out: []u8, lines: []const roster.Line) usize {
    var w = std.Io.Writer.fixed(out);
    for (lines, 0..) |l, i| {
        if (i > 0) w.writeByte(' ') catch break;
        w.writeAll(l.item) catch break;
    }
    return w.buffered().len;
}

/// The units in a build order, for the COST sort.
fn orderTotal(rec: *const roster.Good) f32 {
    var n: f32 = 0;
    for (rec.input) |l| if (l.per == .once) {
        n += l.n;
    };
    return n;
}

fn kindOf(q: capital.Quote, building: bool) Kind {
    if (building) return .building;
    if (q.count > 0) return .owned;
    return switch (q.standing) {
        .tech, .needs => .blocked,
        .unlock => .locked,
        .ready => .ready,
        // Hands taken by other work: `busy` when the order is otherwise on hand, so the row
        // says what actually stands in the way instead of a full reach meter.
        .busy => if (q.reach >= 1) .busy else .reach,
        .energy, .short => .reach,
    };
}

/// Classify the shelf for agent `e` and keep the rows `query_text` admits, into `buf`. Pure
/// over world + catalog, so it is unit-testable. A build in progress is never filtered away.
pub fn collect(world: *World, e: Entity, cat: *const roster.Catalog, shelf: Shelf, query_text: []const u8, buf: []Entry) []Entry {
    const q = query.parse(query_text);
    const blank = query_text.len == 0;
    const busy = world.get(e, comp.Busy);
    var n: usize = 0;
    for (cat.goods, 0..) |*rec, i| {
        if (!onShelf(world, e, cat, shelf, i)) continue;
        if (n == buf.len) break;
        const gi: u16 = @intCast(i);
        const quote = capital.quote(world, e, cat, gi) orelse continue;
        const kind = kindOf(quote, busy != null and busy.?.isBuild(gi));
        var ent = Entry{
            .q = quote,
            .kind = kind,
            .inputs = orderTotal(rec),
            .hours = rec.requires.?.hours,
            .name = rec.name,
            .type_word = row_mod.recipeType(rec),
            .state_word = stateWord(kind),
            .tech = if (rec.tech) |t| (if (cat.technology(t)) |tr| tr.name else t) else "",
        };
        ent.in_len = joinItems(&ent.in_buf, rec.input);
        // A recipe with no product lines yields itself; `out:` then reads its effect copy.
        ent.out_len = if (rec.output.len > 0) joinItems(&ent.out_buf, rec.output) else blk: {
            const n_copy = @min(rec.copy.effect.len, ent.out_buf.len);
            @memcpy(ent.out_buf[0..n_copy], rec.copy.effect[0..n_copy]);
            break :blk n_copy;
        };
        // The blank view is the complete shelf and a query only narrows it.
        if (kind == .building or blank or query.matches(&q, RecipeRow{ .e = &ent })) {
            buf[n] = ent;
            n += 1;
        }
    }
    return buf[0..n];
}

/// Order the rows by `sort`/`dir` (never `none` here), the build in progress pinned on top
/// under every key and direction, equal keys broken by name.
pub fn sortEntries(entries: []Entry, sort: Sort, dir: Direction) void {
    const Ctx = struct { sort: Sort, dir: Direction };
    const Cmp = struct {
        fn less(c: Ctx, a: Entry, b: Entry) bool {
            if ((a.kind == .building) != (b.kind == .building)) return a.kind == .building;
            var pl = false; // primary-less (ascending semantics; `lessThan` applies the direction)
            var pe = true; // primary-equal
            switch (c.sort) {
                .state => {
                    // The state groups first; within the in-reach group, nearest first.
                    const ra = stateRank(a.kind);
                    const rb = stateRank(b.kind);
                    if (ra != rb) {
                        pl = ra < rb;
                        pe = false;
                    } else if (a.kind == .reach) {
                        pl = a.q.reach < b.q.reach;
                        pe = a.q.reach == b.q.reach;
                    }
                },
                .inputs => {
                    pl = a.inputs < b.inputs;
                    pe = a.inputs == b.inputs;
                },
                .time => {
                    pl = a.hours < b.hours;
                    pe = a.hours == b.hours;
                },
                .name => {}, // name is the tie-break itself
            }
            return cc.lessThan(c.dir, pl, pe, a.name, b.name);
        }
    };
    std.sort.insertion(Entry, entries, Ctx{ .sort = sort, .dir = dir }, Cmp.less);
}

/// Build the list. `catalog_state` and `search_owner` are the catalog state and the node holding the
/// search editor when the caller owns them (an always-built owner, so a hidden BUILD tab
/// keeps its query and sort); null lets the controls keep their own. `scroll` is the rows'
/// scroll offset on the same terms. The list fills its parent's remaining height.
pub fn build_list(parent: El, world: *World, e: Entity, id: []const u8, shelf: Shelf, catalog_state: ?*uic.UiState.CatalogState, search_owner: ?El, scroll: ?*uic.UiState.ScrollState) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const cat = &ctx.res.catalog;

    const outer = try parent.div(id);
    _ = outer.with_size(.{ .pct_of_parent = 1.0 }, .grow)
        .with_flow(.{ .dir = .column }).with_gap(6);

    // --- the controls bar: search only; the table's column headers sort -------------------
    const controls = try cc.catalog_controls(outer, "build_ctl", cc.recipes_placeholder, catalog_state, search_owner);
    const blank = controls.query_text.len == 0;

    var buf: [roster.max_goods]Entry = undefined;
    const entries = collect(world, e, cat, shelf, controls.query_text, &buf);

    // --- summary + aligned, sortable table header ------------------------------------------
    // Built before sorting so a header click re-sorts this same frame.
    var sbuf: [40]u8 = undefined;
    const summary = std.fmt.bufPrint(&sbuf, "{d} of {d} recipes shown", .{ entries.len, shelfTotal(world, e, cat, shelf) }) catch "?";
    _ = (try outer.text("summary", summary))
        .with_style(.{ style.small, Style{ .text = th.dim } });

    // `CatalogState` opens with sort 0 (state) and dir `none`; `none` reads as the sort's
    // natural direction, so the blank list opens on STATE ↓ (nearest first).
    const st = controls.state;
    if (st.sort >= sort_count) st.sort = 0;
    const cur_sort: Sort = @enumFromInt(st.sort);
    const cur_dir: Direction = if (st.dir != .none) st.dir else naturalDir(cur_sort);
    // The column header stays put above the scrolling rows.
    const header = try capital_header(outer, "header", shelf.widths, .{
        .keys = .{ @intFromEnum(Sort.name), @intFromEnum(Sort.inputs), @intFromEnum(Sort.time), null, @intFromEnum(Sort.state), null },
        .active = st.sort,
        .dir = if (cur_dir == .descending) .descending else .ascending,
    });
    var eff_sort = cur_sort;
    var eff_dir = cur_dir;
    if (header.clicked) |k| {
        const next = cc.nextSort(st.sort, cur_dir, k, naturalDir(@enumFromInt(k)));
        st.sort = next.sort;
        st.dir = next.dir;
        eff_sort = @enumFromInt(next.sort);
        eff_dir = next.dir;
    }
    sortEntries(entries, eff_sort, eff_dir);

    // --- the rows: the only part that scrolls ----------------------------------------------
    // The view takes what the controls, summary, header and milestone leave; the track sits in
    // the gutter right of the table, so it never covers a lane and appears only on overflow.
    const view = try outer.div("rows_view");
    _ = view.with_size(.{ .pct_of_parent = 1.0 }, .grow);
    const sv = try scroll_view_mod.scroll_view(view, "scroll", .{
        .width = row_mod.tableWidth(ctx, shelf.widths),
        .height = 0,
        .framed = false,
        .gap = 0,
    }, scroll);
    const rows = sv.content;

    if (entries.len == 0) {
        const msg = if (blank) try std.fmt.allocPrint(ctx.arena, "Nothing is within reach yet. Gather {s}.", .{roster.Resource.biomass.wordIn(ha.migration.actOf(world, e))}) else "No recipe matches your search.";
        _ = (try rows.text("empty", msg))
            .with_style(.{ style.body, Style{ .text = th.line2 } });
    }

    for (entries) |ent| {
        // Keyed by the recipe's id, not its sorted position, so a row's focus and state follow
        // the recipe through a re-sort or a filter change.
        const r = try capital_row(rows, world, e, shelf.widths, ent.q, ent.kind);
        // The lifecycle is the simulation's. A ready/owned click pays through `begin`; the
        // cancel corner runs the existing refund path. No UI timers.
        if (r.clicked_build) capital.begin(world, e, ctx.res, ent.q.gi);
        if (r.clicked_cancel) _ = capital.cancel_build(world, e, ctx.res);
    }

    // --- the milestone, pinned below and outside the filter ------------------------------
    if (shelf.milestone) |m| try milestone_goal(outer, world, e, "goal", m);
    return outer;
}

/// The act's milestone good as a `milestone_goal` — outside the recipe filtering/sorting
/// because it is the act's ending, not an item in it. Its lifecycle and requirements
/// recompute live from the record's `unlock`; `words` is the act's copy.
fn milestone_goal(parent: El, world: *World, e: Entity, id: []const u8, words: MilestoneCopy) !void {
    const ctx = parent.ctx;
    const cat = &ctx.res.catalog;
    if (capital.ownsMilestone(world, e, cat, words.which)) return; // owning it raises the curtain — the act is over
    var found: ?u16 = null;
    for (cat.goods, 0..) |g, i| {
        if (g.milestone == words.which) found = @intCast(i);
    }
    const gi = found orelse return;
    const quote = capital.quote(world, e, cat, gi) orelse return;
    const rec = quote.rec;
    const price = rec.requires.?;
    const u = rec.unlock orelse return;
    const vigor = world.get(e, comp.Vigor).?;
    const food = ledger.balance(world, e, .food);
    const kinds = capital.goodsOwned(world, e, cat);

    // Lifecycle from authoritative state: locked until the standing conditions hold, then
    // unfunded until the order and energy are on hand and hands are free, then ready.
    const state: milestone_mod.Lifecycle = switch (quote.standing) {
        .tech, .needs, .unlock => .locked,
        .busy, .energy, .short => .unfunded,
        .ready => .ready,
    };

    // Cost/copy: `60m 6e · 6.0d` — the order, energy, days.
    var cbuf: [48]u8 = undefined;
    const cost_txt = blk: {
        var cw = std.Io.Writer.fixed(&cbuf);
        for (rec.input) |l| if (l.per == .once) {
            cw.print("{d:.0}{s} ", .{ l.n, @import("./action_info.zig").letterOf(ha.migration.actOf(world, e), l.item) }) catch {};
        };
        cw.print("{d:.0}e \u{00B7} {d:.1}d", .{ price.energy, price.hours / 24.0 }) catch {};
        break :blk cw.buffered();
    };

    // The compact bar and expanded requirement row read the same authoritative checks. Values
    // are separate strings so the shared card can color each met/unmet output like the HTML.
    const vigor_met = vigor.v >= u.vigor_abs;
    const food_met = food >= u.food;
    const recipes_met = kinds >= u.goods;
    var compact_buf: [32]u8 = undefined;
    var vigor_buf: [24]u8 = undefined;
    var food_buf: [24]u8 = undefined;
    var recipes_buf: [16]u8 = undefined;
    var order_bufs: [roster.max_lines][24]u8 = undefined;
    var order_labels: [roster.max_lines][24]u8 = undefined;
    var requirements: [3 + roster.max_lines]milestone_mod.Requirement = undefined;
    var nreq: usize = 0;
    requirements[nreq] = .{ .label = "VIGOR", .value = std.fmt.bufPrint(&vigor_buf, "{d:.0}/{d:.0}", .{ vigor.v, u.vigor_abs }) catch "?", .met = vigor_met };
    nreq += 1;
    requirements[nreq] = .{ .label = "FOOD", .value = std.fmt.bufPrint(&food_buf, "{d:.1}/{d:.0}", .{ food, u.food }) catch "?", .met = food_met };
    nreq += 1;
    requirements[nreq] = .{ .label = "RECIPES", .value = std.fmt.bufPrint(&recipes_buf, "{d}/{d}", .{ kinds, u.goods }) catch "?", .met = recipes_met };
    nreq += 1;
    var compact: []const u8 = "";
    var li: usize = 0;
    for (rec.input) |l| {
        if (l.per != .once) continue;
        const have = ledger.held(world, e, cat, l);
        const word = ha.actions.itemWord(cat, l.item, ha.migration.actOf(world, e));
        const label = std.ascii.upperString(&order_labels[li], word[0..@min(word.len, order_labels[li].len)]);
        requirements[nreq] = .{ .label = label, .value = std.fmt.bufPrint(&order_bufs[li], "{d:.0}/{d:.0}", .{ have, l.n }) catch "?", .met = have >= l.n };
        nreq += 1;
        if (li == 0) compact = std.fmt.bufPrint(&compact_buf, "{s} {d:.0}/{d:.0}", .{ word, have, l.n }) catch word;
        li += 1;
    }
    // Locked counts the standing conditions still unmet (`locked · 1 condition`), as the
    // Exchange card does.
    const unmet: u32 = @as(u32, @intFromBool(!vigor_met)) + @intFromBool(!food_met) + @intFromBool(!recipes_met);
    var ready_buf: [32]u8 = undefined;
    const readiness = switch (state) {
        .locked => std.fmt.bufPrint(&ready_buf, "locked \u{00B7} {d} condition{s}", .{ unmet, if (unmet == 1) "" else "s" }) catch "locked",
        .unfunded => "inputs short",
        .ready => "ready to raise",
        .done => unreachable,
    };
    // The CTA names the state it waits on (the Exchange card's `LOCKED`), then the act's verb.
    const action = switch (state) {
        .locked => "LOCKED",
        .unfunded => "NEEDS INPUTS",
        .ready => words.action,
        .done => unreachable,
    };

    const m = try milestone_mod.milestone_goal(parent, id, .{
        .state = state,
        .title = rec.name,
        .summary = compact,
        .readiness = readiness,
        .kicker = words.kicker,
        .cost = cost_txt,
        .copy = words.copy,
        .requirements = requirements[0..nreq],
        .explanation = words.explanation,
        .action = action,
    });
    // Raising the milestone is the same begin lifecycle; the transition itself happens when
    // the build completes in the simulation (no UI-local shortcut).
    if (m.clicked) capital.begin(world, e, ctx.res, gi);
}

// ============================ Tests =====================================================

const testing = std.testing;

const act_one_test = Shelf{ .act = 1, .crude_only = true, .subtitle = "" };
const act_two_test = Shelf{ .act = 2, .subtitle = "" };

test "the authored total counts this shelf's recipes only" {
    var cat = try roster.load(testing.allocator, .{
        .actions =
        \\.{ .{ .id = "forage", .name = "Forage", .innate = true, .requires = .{ .energy = 1.0, .hours = 1.0 } } }
        ,
        .goods =
        \\.{
        \\    .{ .id = "rod", .name = "Rod", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 } },
        \\    .{ .id = "hut", .name = "Hut", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 }, .milestone = .act_one },
        \\    .{ .id = "net", .name = "Net", .buildable = false },
        \\    .{ .id = "kiln", .name = "Kiln", .act = 2, .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 } },
        \\}
        ,
    }, null);
    defer cat.deinit();
    try testing.expectEqual(@as(usize, 1), authoredTotal(&cat, act_one_test));
    try testing.expectEqual(@as(usize, 1), authoredTotal(&cat, act_two_test));
}

/// An agent carried across the curtain, holding the given stocks of biomass and minerals.
fn settler(w: *World, cat: *const roster.Catalog, biomass: f32, minerals: f32) Entity {
    const e = w.spawn(.{
        comp.Vigor{ .v = 15, .max = 15 },
        comp.InventoryFood{ .v = 20, .quality = 1, .spoils = 0 },
        comp.InventoryBiomass{ .v = biomass },
        comp.Goods{},
        comp.Granted{},
    });
    _ = ha.migration.migrate_to_act_two(w, e, cat);
    _ = ha.ledger.move(w, e, .minerals, minerals);
    return e;
}

test "Act II: the blank shelf is every authored recipe, research-gated rows included" {
    var w = World.init();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat, 0, 0);
    try testing.expectEqual(@as(usize, 50), authoredTotal(&cat, act_two_test));
    var buf: [roster.max_goods]Entry = undefined;
    const list = collect(&w, e, &cat, act_two_test, "", &buf);
    try testing.expectEqual(@as(usize, 50), list.len);
}

test "Act II carries owned Act I goods onto its shelf, unless it authors a recipe of that name" {
    var w = World.init();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat, 0, 0);
    const carrying = Shelf{ .act = 2, .subtitle = "", .carry_owned = true };
    const goods = w.get(e, comp.Goods).?;
    goods.count[cat.goodIndex("leaf_bed").?] = 1; // no Act II recipe of that name
    goods.count[cat.goodIndex("garden_bed").?] = 1; // shadowed by Act II's Garden bed
    try testing.expect(onShelf(&w, e, &cat, carrying, cat.goodIndex("leaf_bed").?));
    try testing.expect(!onShelf(&w, e, &cat, carrying, cat.goodIndex("garden_bed").?));
    try testing.expect(!onShelf(&w, e, &cat, act_two_test, cat.goodIndex("leaf_bed").?));
    try testing.expectEqual(authoredTotal(&cat, carrying) + 1, shelfTotal(&w, e, &cat, carrying));
    var buf: [roster.max_goods]Entry = undefined;
    const list = collect(&w, e, &cat, carrying, "", &buf);
    var found: ?Kind = null;
    for (list) |ent| if (std.mem.eql(u8, ent.name, "Leaf bed")) {
        found = ent.kind;
    };
    try testing.expectEqual(@as(?Kind, .owned), found);
}

test "Act II: tech: finds recipes by technology; a build in progress pins first under every sort" {
    var w = World.init();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat, 40, 40);
    var buf: [roster.max_goods]Entry = undefined;
    const loom = collect(&w, e, &cat, act_two_test, "tech:loom", &buf);
    try testing.expect(loom.len > 0);
    for (loom) |ent| try testing.expectEqualStrings("loom_ropewalk", ent.q.rec.tech.?);

    // Establish the loom and begin the ropewalk: it is pinned above everything.
    w.get(e, comp.Research).?.state[cat.techIndex("loom_ropewalk").?] = .researched;
    const ropewalk = cat.goodIndex("ropewalk").?;
    const total = ha.res.hours_to_secs(cat.goods[ropewalk].requires.?.hours, 20);
    w.add(e, comp.Busy{ .doing = .{ .build = ropewalk }, .total = total, .remaining = total, .quality = 1 });
    for ([_]Sort{ .state, .inputs, .time, .name }) |s| {
        for ([_]Direction{ .ascending, .descending }) |d| {
            const list = collect(&w, e, &cat, act_two_test, "", &buf);
            sortEntries(list, s, d);
            try testing.expectEqual(Kind.building, list[0].kind);
        }
    }
}

test "sortEntries: STATE groups by state (ready, reach, owned, blocked, locked) in either direction" {
    var w = World.init();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat, 14, 0);
    // Own a firepit and a spring well, so the shelf carries owned rows beside ready, in-reach
    // and research-gated ones — the mix a reach-only sort used to interleave.
    w.get(e, comp.Goods).?.count[cat.goodIndex("firepit").?] = 1;
    w.get(e, comp.Goods).?.count[cat.goodIndex("spring_well").?] = 1;
    var buf: [roster.max_goods]Entry = undefined;
    const list = collect(&w, e, &cat, act_two_test, "", &buf);

    var seen: [6]bool = @splat(false);
    for (list) |ent| seen[stateRank(ent.kind)] = true;
    try testing.expect(seen[stateRank(.owned)] and seen[stateRank(.blocked)]);
    try testing.expect(seen[stateRank(.ready)] or seen[stateRank(.reach)]);

    sortEntries(list, .state, .descending);
    for (list[1..], 0..) |ent, i| {
        const prev = list[i];
        try testing.expect(stateRank(ent.kind) <= stateRank(prev.kind));
        // Inside the in-reach group, nearest first.
        if (ent.kind == .reach and prev.kind == .reach) try testing.expect(ent.q.reach <= prev.q.reach);
    }
    try testing.expect(list[0].kind != .owned and list[0].kind != .blocked);

    sortEntries(list, .state, .ascending);
    for (list[1..], 0..) |ent, i| try testing.expect(stateRank(ent.kind) >= stateRank(list[i].kind));
}

test "sortEntries: name ascending is A–Z" {
    var w = World.init();
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    const e = settler(&w, &cat, 10, 0);
    var buf: [roster.max_goods]Entry = undefined;
    const list = collect(&w, e, &cat, act_two_test, "", &buf);
    sortEntries(list, .name, .ascending);
    for (list[1..], 0..) |ent, i| try testing.expect(std.ascii.lessThanIgnoreCase(list[i].name, ent.name) or std.ascii.eqlIgnoreCase(list[i].name, ent.name));
}
