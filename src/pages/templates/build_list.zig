//! `build_list` — the BUILD tab: a searched, sorted list of recipes over the **live catalog**.
//!
//! ACT1-09 replaced the hand-rolled SORT/SHOW/TIER/built chips (a second fixed taxonomy) with
//! the shared catalog surface: a `catalog_controls` bar (KIT-15 — one search field + a disclosed
//! Sort-by/Direction, a count-only summary) driving `capital_row`s (KIT-18) filtered by the one
//! `query` parser (KIT-14). The axis belongs to the player: type to search, or sort by reach,
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
//! where the total is the **full authored catalog** count (every buildable good but the Shelter),
//! even though locked recipes contribute no row.
//!
//! **ACT1-10 (build lifecycle):** starting a ready/owned row pays through `capital.begin_build`;
//! the live `Busy` row renders its own progress/time and a cancel corner that calls
//! `capital.cancel_build` (the refund path); completion is the simulation's — no UI-local timers.
//!
//! **ACT1-11 (Shelter milestone):** the Shelter is not a row. It is a `milestone_goal` (KIT-20)
//! pinned below the list, **outside** the filter/sort, because it is how the act ends rather than
//! an item in it. Its lifecycle (locked/unfunded/ready) and every requirement recompute from
//! authoritative state each frame.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const capital = ha.capital;
const catalog = ha.catalog;
const query = ha.query;
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const World = ha.world.World;
const Entity = ha.world.Entity;

const gt = @import("./good_text.zig");
const row_mod = @import("./capital_row.zig");
const capital_row = row_mod.capital_row;
const Kind = row_mod.Kind;
const cc = @import("./catalog_controls.zig");
const milestone_mod = @import("./milestone_goal.zig");

const Direction = uic.UiState.CatalogState.Direction;

/// The buildable goods, minus the Shelter (which is the milestone, not a row). This is the
/// **authored total** the summary reports against — a locked recipe still counts even when it
/// contributes no row.
const authored_total = capital.buildable_bundle.len - 1;

/// The Sort-by option labels the controls disclose. Reach is the default (index 0), so the blank
/// list opens sorted by how close each recipe is to affordable, descending.
const sort_kinds = [_][]const u8{ "reach", "inputs", "time", "name" };
const Sort = enum(usize) { reach = 0, inputs = 1, time = 2, name = 3 };

/// One classified recipe for this frame: the comptime index into `buildable_bundle`, its display
/// `kind`, reach fraction, materials/hours cost, and the `name`/`type_word`/`state_word` used to
/// answer `query` fields. Everything is a comptime-known string or a live number — no allocation.
const Entry = struct {
    i: usize,
    kind: Kind,
    reach: f32,
    mats: f32,
    hours: f32,
    name: []const u8,
    type_word: []const u8,
    state_word: []const u8,
};

/// The row-facing `query` contract (KIT-14): answers a `Field` with this recipe's text, a free-
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
        return self.e.kind == .ready or self.e.reach >= 0.5;
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

pub fn build_list(ctx: *UiCtx, parent: El, world: *World, e: Entity, id: []const u8) !El {
    const th = ctx.res.view.theme;

    const outer = try el.div(ctx, parent, id);
    _ = outer.with_flow(.{ .dir = .column }).with_gap(6);

    // --- the controls bar (KIT-15): search + disclosed sort, its own state keyed by id ------
    const controls = try cc.catalog_controls(ctx, outer, "build_ctl", &sort_kinds);
    const q = query.parse(controls.query_text);
    const blank = controls.query_text.len == 0;

    // --- classify every non-Shelter good, then filter by mode + query ----------------------
    var buf: [authored_total]Entry = undefined;
    var n: usize = 0;
    const stock = world.get(e, comp.InventoryMaterial).?;
    const vigor = world.get(e, comp.Vigor).?;
    const busy = world.get(e, comp.Busy);

    inline for (capital.buildable_bundle, 0..) |G, i| {
        if (G != comp.Shelter) {
            const cost = (G{}).requires;
            const owned = world.has(e, G);
            const doing_this = busy != null and busy.?.doing == capital.doing_of_good(G);
            const affordable = cost.energy < vigor.v and cost.materials <= stock.v;
            const reach = if (cost.materials <= 0) 1.0 else @min(1.0, stock.v / cost.materials);

            const kind: Kind = if (doing_this) .building else if (owned)
                .owned
            else if (!capital.prereq_met(world, e, G))
                .blocked
            else if (!capital.unlock_met(world, e, G))
                .locked
            else if (affordable and busy == null) .ready else .reach;

            const ent = Entry{
                .i = i,
                .kind = kind,
                .reach = reach,
                .mats = cost.materials,
                .hours = cost.hours,
                .name = gt.display_name(G),
                .type_word = if (capital.is_crude(G)) "crude" else "made",
                .state_word = stateWord(kind),
            };

            // A build in progress is never filtered away — the corner is the way out.
            const pinned = kind == .building;
            // Prerequisite-locked recipes stay absent under every mode: a row you cannot even
            // attempt is noise, not information.
            const attemptable = kind != .blocked;

            const keep = pinned or (attemptable and if (blank)
                // Blank: ready plus reach ≥ 0.5, excluding what you already own.
                ((kind == .ready or reach >= 0.5) and kind != .owned)
            else
                // A search runs over every non-locked record — owned and far-off included.
                query.matches(&q, RecipeRow{ .e = &ent }));

            if (keep) {
                buf[n] = ent;
                n += 1;
            }
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
                    pl = a.reach < b.reach;
                    pe = a.reach == b.reach;
                },
                .inputs => {
                    pl = a.mats < b.mats;
                    pe = a.mats == b.mats;
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

    // --- the rows --------------------------------------------------------------------------
    const rows = try el.div(ctx, outer, "rows");
    _ = rows.with_flow(.{ .dir = .column });

    if (n == 0) {
        const msg = if (blank) "Nothing is within reach yet. Gather materials." else "No recipe matches your search.";
        _ = (try el.text(ctx, rows, "empty", msg))
            .with_style(.{ style.body, Style{ .text = th.line2 } });
    }

    for (entries, 0..) |ent, slot| {
        var idbuf: [8]u8 = undefined;
        const rid = std.fmt.bufPrint(&idbuf, "r{d}", .{slot}) catch "r";
        inline for (capital.buildable_bundle, 0..) |G, i| {
            if (G != comp.Shelter and i == ent.i) {
                const r = try capital_row(ctx, rows, world, e, G, rid, ent.kind, ent.reach);
                // ACT1-10: the lifecycle is the simulation's. A ready/owned click pays through
                // begin_build; the cancel corner runs the existing refund path. No UI timers.
                if (r.clicked_build) capital.begin_build(world, e, ctx.res, G);
                if (r.clicked_cancel) _ = capital.cancel_build(world, e, ctx.res);
            }
        }
    }

    // --- the count-only summary: {visible} of {authored total} recipes shown ---------------
    var sbuf: [40]u8 = undefined;
    const summary = std.fmt.bufPrint(&sbuf, "{d} of {d} recipes shown", .{ n, authored_total }) catch "?";
    _ = (try el.text(ctx, outer, "summary", summary))
        .with_style(.{ style.small, Style{ .text = th.dim } });

    // --- the Shelter milestone (ACT1-11), pinned below and outside the filter --------------
    try shelter_goal(ctx, outer, world, e, "goal");
    return outer;
}

/// The Shelter as a `milestone_goal` (KIT-20) — outside the recipe filtering/sorting because it
/// is the act's ending, not an item in it. Its lifecycle and requirements recompute live.
fn shelter_goal(ctx: *UiCtx, parent: El, world: *World, e: Entity, id: []const u8) !void {
    const G = comp.Shelter;
    if (world.has(e, G)) return; // owning it raises the curtain — the act is over

    const cost = (G{}).requires;
    const u = (G{}).unlock;
    const stock = world.get(e, comp.InventoryMaterial).?;
    const vigor = world.get(e, comp.Vigor).?;
    const food = world.get(e, comp.InventoryFood).?;
    const kinds = capital.goods_owned(world, e);
    const busy = world.get(e, comp.Busy);

    // Lifecycle from authoritative state: locked until the standing conditions hold, then
    // unfunded until materials/energy are on hand and hands are free, then ready.
    const unlocked = capital.unlock_met(world, e, G);
    const funded = cost.materials <= stock.v and cost.energy < vigor.v and busy == null;
    const state: milestone_mod.Lifecycle = if (!unlocked) .locked else if (!funded) .unfunded else .ready;

    // Cost/copy: `60m 6e · 6.0d` — materials, energy, days.
    var cbuf: [40]u8 = undefined;
    const cost_txt = std.fmt.bufPrint(&cbuf, "{d:.0}m {d:.0}e \u{00B7} {d:.1}d", .{ cost.materials, cost.energy, cost.hours / 24.0 }) catch "?";

    // The requirement row shows every live check as `label current/req`, so an unmet condition
    // is a fact the player can read, not a hidden predicate.
    var rbuf: [96]u8 = undefined;
    const req = std.fmt.bufPrint(&rbuf, "vigor {d:.0}/{d:.0} \u{00B7} food {d:.0}/{d:.0} \u{00B7} goods {d}/{d} \u{00B7} materials {d:.0}/{d:.0}", .{
        vigor.v, u.vigor_abs,
        food.v,  u.food,
        kinds,   u.goods,
        stock.v, cost.materials,
    }) catch "?";

    const m = try milestone_mod.milestone_goal(ctx, parent, id, .{
        .state = state,
        .title = gt.display_name(G),
        .summary = "a roof with room for four",
        .kicker = "THE END OF ACT I",
        .cost = cost_txt,
        .copy = "A shelter is how Act I ends \u{2014} it houses others, and opens what comes next.",
        .requirement = req,
        .explanation = gt.effect(G),
        .action = "Raise the shelter",
    });
    // ACT1-10/11: raising the shelter is the same begin_build lifecycle; the transition itself
    // happens when the build completes in the simulation (no UI-local shortcut).
    if (m.clicked) capital.begin_build(world, e, ctx.res, G);
}
