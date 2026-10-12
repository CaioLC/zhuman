//! `build_list` — the BUILD tab: a searched, sorted list of recipes over the **live catalog**.
//!
//! It is built from the shared catalog surface: a `catalog_controls` bar (one search field +
//! a disclosed Sort-by/Direction, a count-only summary) driving `capital_row`s filtered by
//! the one `query` parser. The axis belongs to the player: type to search, or sort by reach,
//! inputs, or time.
//!
//! **What the blank list shows vs a search.** With no query the list answers *what can I act on
//! now* — ready recipes plus everything with reach ≥ `0.5`, excluding what you already own, sorted
//! by reach descending so the top is always the next thing. The moment you type, the question
//! widens to *what does the catalog hold* — the search runs over **every non-locked** record,
//! including owned and far-off ones, so the field is a way to find a specific recipe, not just to
//! narrow the ready set. **Prerequisite-locked recipes stay absent** in both modes (a row you
//! cannot even attempt is noise); a **build in progress is always visible and pinned to the top**
//! (you need the way out). The summary always reads `{visible} of {authored total} recipes shown`,
//! where the total is the **full authored catalog** count (every buildable good but the milestone),
//! even though locked recipes contribute no row.
//!
//! **Build lifecycle:** starting a ready/owned row pays through `capital.begin`; the live
//! `Busy` row renders its own progress/time and a cancel corner that calls
//! `capital.cancel_build` (the refund path); completion is the simulation's — no UI-local timers.
//!
//! **Shelter milestone:** the milestone good is not a row. It is a `milestone_goal` pinned
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

const Direction = uic.UiState.CatalogState.Direction;

/// The act this surface serves. A record of a later act is neither a row nor part of the
/// total; the Act II shell lists its own.
const act: u8 = 1;

/// Whether a record is one of this act's recipes: buildable, of this act or earlier, and not
/// the milestone (which is the goal, not a row).
fn isRecipe(g: *const roster.Good) bool {
    return g.buildable and g.milestone == null and g.act <= act;
}

/// This act's recipes. This is the **authored total** the summary reports against — a locked
/// recipe still counts even when it contributes no row.
pub fn authoredTotal(cat: *const roster.Catalog) usize {
    var n: usize = 0;
    for (cat.goods) |*g| {
        if (isRecipe(g)) n += 1;
    }
    return n;
}

/// The Sort-by option labels the controls disclose. Reach is the default (index 0), so the blank
/// list opens sorted by how close each recipe is to affordable, descending.
const sort_kinds = [_][]const u8{ "reach", "inputs", "time", "name" };
const Sort = enum(usize) { reach = 0, inputs = 1, time = 2, name = 3 };

/// One classified recipe for this frame: its quote (which carries the catalog index and the
/// record), its display `kind`, the inputs/hours it sorts by, and the `name`/`type_word`/
/// `state_word` used to answer `query` fields. Everything is a record string or a live number —
/// no allocation.
const Entry = struct {
    q: capital.Quote,
    kind: Kind,
    inputs: f32,
    hours: f32,
    name: []const u8,
    type_word: []const u8,
    state_word: []const u8,
};

/// The row-facing `query` contract: answers a `Field` with this recipe's text, a free-
/// text `haystack` (the name), and the `state:in-reach` fact. Recipes expose `type`/`state`
/// (and `is:` folds over both); `in`/`out`/`tech` are always-miss here (BUILD costs are uniform
/// energy+materials, and Act I recipes carry no research links).
const RecipeRow = struct {
    e: *const Entry,
    pub fn text(self: RecipeRow, f: query.Field) []const u8 {
        return switch (f) {
            .type => self.e.type_word,
            .state => self.e.state_word,
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

/// The state word a recipe answers `state:` / `is:` with — the same word the row's colour says.
fn stateWord(kind: Kind) []const u8 {
    return switch (kind) {
        .ready => "ready",
        .reach => "reach",
        .building => "building",
        .blocked => "blocked",
        .locked => "locked",
        .owned => "owned",
    };
}

/// The tier word a recipe answers `type:` with.
pub fn tierWord(rec: *const roster.Good) []const u8 {
    return if (rec.tier == .crude) "crude" else "made";
}

/// The units in a build order, for the `inputs` sort.
fn orderTotal(rec: *const roster.Good) f32 {
    var n: f32 = 0;
    for (rec.input) |l| if (l.per == .once) {
        n += l.n;
    };
    return n;
}

/// Build the list. `catalog_state` and `search_owner` are the catalog state and the node holding the
/// search editor when the caller owns them (the always-built surface, so a hidden BUILD tab
/// keeps its query and sort); null lets the controls keep their own.
pub fn build_list(parent: El, world: *World, e: Entity, id: []const u8, catalog_state: ?*uic.UiState.CatalogState, search_owner: ?El) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const cat = &ctx.res.catalog;

    const outer = try parent.div(id);
    _ = outer.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(6);

    // --- the controls bar: search + disclosed sort ------------------------------
    const controls = try cc.catalog_controls(outer, "build_ctl", &sort_kinds, catalog_state, search_owner);
    const q = query.parse(controls.query_text);
    const blank = controls.query_text.len == 0;

    // --- classify every non-milestone recipe, then filter by mode + query --------------------
    var buf: [roster.max_goods]Entry = undefined;
    var n: usize = 0;
    const busy = world.get(e, comp.Busy);

    for (cat.goods, 0..) |*rec, i| {
        if (!isRecipe(rec)) continue;
        const gi: u16 = @intCast(i);
        const quote = capital.quote(world, e, cat, gi) orelse continue;
        const doing_this = busy != null and busy.?.isBuild(gi);

        const kind: Kind = if (doing_this) .building else if (quote.count > 0) .owned else switch (quote.standing) {
            .tech, .needs => .blocked,
            .unlock => .locked,
            .ready => .ready,
            .busy, .energy, .short => .reach,
        };

        const ent = Entry{
            .q = quote,
            .kind = kind,
            .inputs = orderTotal(rec),
            .hours = rec.requires.?.hours,
            .name = rec.name,
            .type_word = tierWord(rec),
            .state_word = stateWord(kind),
        };

        // A build in progress is never filtered away — the corner is the way out.
        const pinned = kind == .building;
        // Prerequisite-locked recipes stay absent under every mode: a row you cannot even
        // attempt is noise, not information.
        const attemptable = kind != .blocked;

        const keep = pinned or (attemptable and if (blank)
            // Blank: ready plus reach ≥ 0.5, excluding what you already own.
            ((kind == .ready or quote.reach >= 0.5) and kind != .owned)
        else
            // A search runs over every non-locked record — owned and far-off included.
            query.matches(&q, RecipeRow{ .e = &ent }));

        if (keep) {
            buf[n] = ent;
            n += 1;
        }
    }

    const entries = buf[0..n];

    // --- sort: the disclosed key + direction, building pinned to the top -------------------
    const SortCtx = struct { sort: Sort, dir: Direction };
    const Cmp = struct {
        fn less(ctxt: SortCtx, a: Entry, b: Entry) bool {
            // The build in progress pins above everything, under every sort/direction.
            if ((a.kind == .building) != (b.kind == .building)) return a.kind == .building;
            var pl = false; // primary-less (ascending semantics; direction is applied by lessThan)
            var pe = true; // primary-equal
            switch (ctxt.sort) {
                .reach => {
                    pl = a.q.reach < b.q.reach;
                    pe = a.q.reach == b.q.reach;
                },
                .inputs => {
                    pl = a.inputs < b.inputs;
                    pe = a.inputs == b.inputs;
                },
                .time => {
                    pl = a.hours < b.hours;
                    pe = a.hours == b.hours;
                },
                .name => {}, // name is the tie-break itself → defer to it (pl=false, pe=true)
            }
            return cc.lessThan(ctxt.dir, pl, pe, a.name, b.name);
        }
    };
    // Default sort is reach descending. `CatalogState` opens with dir `none`; we read `none` as
    // "the sort's natural direction" — reach descending (nearest first), the others ascending
    // (cheapest/quickest/alphabetical first) — so the blank list opens usefully without a pool
    // default that the state pool would not honour anyway.
    const eff_sort: Sort = @enumFromInt(controls.sort);
    const eff_dir: Direction = if (controls.dir != .none)
        controls.dir
    else if (eff_sort == .reach) .descending else .ascending;
    std.sort.insertion(Entry, entries, SortCtx{ .sort = eff_sort, .dir = eff_dir }, Cmp.less);

    // --- summary + aligned table header ----------------------------------------------------
    var sbuf: [40]u8 = undefined;
    const summary = std.fmt.bufPrint(&sbuf, "{d} of {d} recipes shown", .{ n, authoredTotal(cat) }) catch "?";
    _ = (try outer.text("summary", summary))
        .with_style(.{ style.small, Style{ .text = th.dim } });

    // --- the rows --------------------------------------------------------------------------
    const rows = try outer.div("rows");
    _ = rows.with_flow(.{ .dir = .column });
    _ = try capital_header(rows, "header");

    if (n == 0) {
        const msg = if (blank) "Nothing is within reach yet. Gather materials." else "No recipe matches your search.";
        _ = (try rows.text("empty", msg))
            .with_style(.{ style.body, Style{ .text = th.line2 } });
    }

    for (entries) |ent| {
        // Keyed by the recipe's catalog index (inside the quote), not its sorted position, so a
        // row's focus and state follow the recipe through a re-sort or a filter change.
        const r = try capital_row(rows, world, e, ent.q, ent.kind);
        // The lifecycle is the simulation's. A ready/owned click pays through `begin`; the
        // cancel corner runs the existing refund path. No UI timers.
        if (r.clicked_build) capital.begin(world, e, ctx.res, ent.q.gi);
        if (r.clicked_cancel) _ = capital.cancel_build(world, e, ctx.res);
    }

    // --- the milestone, pinned below and outside the filter ------------------------------
    try shelter_goal(outer, world, e, "goal");
    return outer;
}

/// The act's milestone good as a `milestone_goal` — outside the recipe filtering/sorting
/// because it is the act's ending, not an item in it. Its lifecycle and requirements
/// recompute live.
fn shelter_goal(parent: El, world: *World, e: Entity, id: []const u8) !void {
    const ctx = parent.ctx;
    const cat = &ctx.res.catalog;
    if (capital.ownsMilestone(world, e, cat, .act_one)) return; // owning it raises the curtain — the act is over
    var found: ?u16 = null;
    for (cat.goods, 0..) |g, i| {
        if (g.milestone == .act_one) found = @intCast(i);
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
            cw.print("{d:.0}{s} ", .{ l.n, @import("./action_info.zig").letterOf(l.item) }) catch {};
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
        const word = ha.actions.itemWord(cat, l.item);
        const label = std.ascii.upperString(&order_labels[li], word[0..@min(word.len, order_labels[li].len)]);
        requirements[nreq] = .{ .label = label, .value = std.fmt.bufPrint(&order_bufs[li], "{d:.0}/{d:.0}", .{ have, l.n }) catch "?", .met = have >= l.n };
        nreq += 1;
        if (li == 0) compact = std.fmt.bufPrint(&compact_buf, "{s} {d:.0}/{d:.0}", .{ word, have, l.n }) catch word;
        li += 1;
    }
    const readiness = switch (state) {
        .locked => "not ready",
        .unfunded => "inputs short",
        .ready => "ready to raise",
        .done => unreachable,
    };
    const action = if (state == .ready) "RAISE SHELTER" else "NOT READY";

    const m = try milestone_mod.milestone_goal(parent, id, .{
        .state = state,
        .title = rec.name,
        .summary = compact,
        .readiness = readiness,
        .kicker = "A PLACE FOR OTHERS",
        .cost = cost_txt,
        .copy = "a roof with room for four. you're not alone anymore.",
        .requirements = requirements[0..nreq],
        .explanation = "Hold 60 materials with a settled body and four kinds of goods.",
        .action = action,
    });
    // Raising the shelter is the same begin lifecycle; the transition itself happens when
    // the build completes in the simulation (no UI-local shortcut).
    if (m.clicked) capital.begin(world, e, ctx.res, gi);
}

test "the authored total counts this act's recipes only" {
    var cat = try roster.load(std.testing.allocator, .{
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
    try std.testing.expectEqual(@as(usize, 1), authoredTotal(&cat));
}
