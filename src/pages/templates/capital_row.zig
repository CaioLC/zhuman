//! `capital_row` — one buildable good as a **row**, replacing the tile.
//!
//! A tile held two short strings, which is why its consequence column decayed into
//! notation. A row holds a sentence, a reach meter, a verb and a corner — and it is the
//! shape that lets a build in progress keep its place in the list instead of becoming a
//! 3px underbar on a dim box.
//!
//! Six fixed columns so every row's fields line up down the list. The last two carry the
//! row's *state*: an affordable good shows `Build →`, one out of reach shows how far
//! (`31/48m`), one in progress shows time left and a `×` in the corner that abandons it,
//! and one whose prerequisite is missing says which verb it wants.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const capital = ha.capital;
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const World = ha.world.World;
const Entity = ha.world.Entity;
const Color = uic.Color;

const gt = @import("./good_text.zig");

/// Column widths — 600px of content plus five 8px gaps is the 640 the tab already uses.
const w_name = 118;
const w_cost = 74;
const w_days = 42;
const w_says = 236;
const w_act = 110;
const w_corner = 20;

/// What a row is showing, which is the one thing the flat grey never said.
pub const Kind = enum { ready, reach, building, blocked, locked, owned };

pub const Row = struct { kind: Kind, reach: f32, clicked_build: bool, clicked_cancel: bool };

fn cell(ctx: *UiCtx, parent: El, id: []const u8, width: f32, text: []const u8, color: Color, right: bool) !void {
    const box = try el.div(ctx, parent, id);
    _ = box.with_size(.{ .fixed = width }, .fit_children);
    const inner = try el.div(ctx, box, "i");
    _ = inner.with_layout(if (right) .center_right else .center_left);
    _ = (try el.text(ctx, inner, "t", text)).with_style(.{ style.body, Style{ .text = color } });
}

/// A catalog **name** cell (TEXT-03): the label is an ellipsis cell of exactly the column
/// width, so a long good name is elided (`Reinforced Timber Fra…`) instead of stretching the
/// row and knocking every downstream column out of its lane. The box and hit geometry stay
/// the allocated `width`; only the visible glyphs are bounded. A **secondary type** sub-label
/// (KIT-18) rides under the name in dim/small — the crude/manufactured tier word.
fn name_cell(ctx: *UiCtx, parent: El, id: []const u8, width: f32, text: []const u8, secondary: []const u8, color: Color) !void {
    const th = ctx.res.view.theme;
    const box = try el.div(ctx, parent, id);
    _ = box.with_size(.{ .fixed = width }, .fit_children).with_flow(.{ .dir = .column, .cross = .start });
    _ = (try el.text(ctx, box, "t", text))
        .with_style(.{ style.body, Style{ .text = color } })
        .with_cell(.ellipsis, width);
    if (secondary.len > 0) {
        _ = (try el.text(ctx, box, "ty", secondary))
            .with_style(.{ style.small, Style{ .text = th.dim } })
            .with_cell(.ellipsis, width);
    }
}

/// One row. `state` decides the colors and what the last two columns say; the caller has
/// already decided the row belongs on screen at all (see `build_list`).
pub fn capital_row(
    ctx: *UiCtx,
    parent: El,
    world: *World,
    e: Entity,
    comptime GoodT: type,
    id: []const u8,
    kind: Kind,
    reach: f32,
) !Row {
    const th = ctx.res.view.theme;
    const cost = (GoodT{}).requires;

    const row = try el.div(ctx, parent, id);
    const hot = kind == .ready;
    const row_key = row.get().key;
    ctx.registerFocus(row_key, hot);
    const q = row.query();
    if (q.clicked and hot) _ = ctx.requestFocus(row_key);
    const focused = ctx.isFocused(row_key);
    uic.publishControlState(ctx, row_key, .{
        .disabled = !hot,
        .focused = focused,
        .focus_visible = focused,
    });
    if (q.hovering) ctx.res.cursor.request(if (hot) .pointer else .not_allowed);
    const lit: Color = switch (kind) {
        .ready => if (q.held or q.hovering or focused) th.acc else th.fg,
        .building => th.fg,
        .owned => th.dim,
        .reach, .blocked, .locked => th.dim,
    };
    const faint: Color = if (kind == .ready or kind == .building) th.dim else th.line2;

    // KIT-18: hide the lower-priority columns (days, effect) at narrow width classes, so the
    // row keeps its name/cost/state lanes when the terminal is tight (VIEW-04 pattern).
    const compact = ctx.res.view.metrics.width_class.atMost(.w560);
    const show_days = !compact;
    const show_effect = !ctx.res.view.metrics.width_class.atMost(.w440);
    // The row's fixed width sums only the columns actually shown, so the lanes stay synced.
    var row_w: f32 = w_name + w_cost + w_act + w_corner;
    var gaps: f32 = 3;
    if (show_days) {
        row_w += w_days;
        gaps += 1;
    }
    if (show_effect) {
        row_w += w_says;
        gaps += 1;
    }

    _ = row.with_size(.{ .fixed = row_w + gaps * 8 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center }).with_gap(8)
        .with_style(.{ style.pad_sym(6, 5), Style{ .fill = if (kind == .ready and (q.held or q.hovering or focused)) th.panel else null } });

    // Name + secondary type (crude vs manufactured — the row's KIT-18 type sub-label).
    const type_word = if (capital.is_crude(GoodT)) "crude" else "made";
    try name_cell(ctx, row, "nm", w_name, gt.display_name(GoodT), type_word, lit);

    var cbuf: [24]u8 = undefined;
    const cost_txt = std.fmt.bufPrint(&cbuf, "{d:.0}m {d:.0}e", .{ cost.materials, cost.energy }) catch "?";
    try cell(ctx, row, "co", w_cost, cost_txt, faint, false);

    if (show_days) {
        var dbuf: [16]u8 = undefined;
        const days_txt = std.fmt.bufPrint(&dbuf, "{d:.1}d", .{cost.hours / 24.0}) catch "?";
        try cell(ctx, row, "dy", w_days, days_txt, faint, false);
    }

    if (show_effect) {
        try cell(ctx, row, "sa", w_says, gt.effect(GoodT), if (kind == .ready) th.fg else faint, false);
    }

    // --- the state column ---------------------------------------------------------
    var build_more = false; // KIT-18: an owned good's "Build +1" click
    const act = try el.div(ctx, row, "ac");
    _ = act.with_size(.{ .fixed = w_act }, .fit_children);
    const act_in = try el.div(ctx, act, "i");
    _ = act_in.with_layout(.center_right).with_flow(.{ .dir = .row, .cross = .center }).with_gap(6);

    switch (kind) {
        .ready => _ = (try el.text(ctx, act_in, "go", "Build \u{2192}"))
            .with_style(.{ style.body, Style{ .text = lit } }),
        .owned => {
            // KIT-18: an owned good that is still affordable (materials on hand, not busy)
            // offers `Build +1` — another unit — reusing the same build action; otherwise it
            // reads "built". The +1 is a nested control, so it consumes its own click.
            const stock = world.get(e, comp.InventoryMaterial).?;
            const busy = world.get(e, comp.Busy);
            const affordable = busy == null and stock.v >= cost.materials;
            if (affordable) {
                const more = try el.div(ctx, act_in, "more");
                const more_key = more.get().key;
                ctx.registerFocus(more_key, true);
                const mq = more.query();
                if (mq.clicked) _ = ctx.requestFocus(more_key);
                const mfocused = ctx.isFocused(more_key);
                uic.publishControlState(ctx, more_key, .{ .focused = mfocused, .focus_visible = mfocused });
                if (mq.hovering) ctx.res.cursor.request(.pointer);
                _ = (try el.text(ctx, more, "t", "Build +1"))
                    .with_style(.{ style.body, Style{ .text = if (mq.held or mq.hovering or mfocused) th.acc else th.dim } });
                build_more = more.consume(.clicked);
            } else {
                _ = (try el.text(ctx, act_in, "ow", "built"))
                    .with_style(.{ style.body, Style{ .text = th.line2 } });
            }
        },
        .blocked => {
            var nbuf: [32]u8 = undefined;
            const txt = std.fmt.bufPrint(&nbuf, "needs {s}", .{gt.prereq_name(GoodT) orelse "a tool"}) catch "needs a tool";
            _ = (try el.text(ctx, act_in, "nd", txt)).with_style(.{ style.body, Style{ .text = th.danger } });
        },
        .locked => _ = (try el.text(ctx, act_in, "lk", "conditions"))
            .with_style(.{ style.body, Style{ .text = th.danger } }),
        .building => {
            const busy = world.get(e, comp.Busy).?;
            var bbuf: [20]u8 = undefined;
            const left = busy.remaining / ctx.res.config.secs_per_day;
            const txt = std.fmt.bufPrint(&bbuf, "{d:.1}d left", .{left}) catch "?";
            try meter(ctx, act_in, "bm", 1.0 - busy.remaining / busy.total, th.acc);
            _ = (try el.text(ctx, act_in, "bt", txt)).with_style(.{ style.body, Style{ .text = th.fg } });
        },
        .reach => {
            const stock = world.get(e, comp.InventoryMaterial).?;
            var rbuf: [24]u8 = undefined;
            const txt = std.fmt.bufPrint(&rbuf, "{d:.0}/{d:.0}m", .{ stock.v, cost.materials }) catch "?";
            try reach_meter(ctx, act_in, "rm", reach, th.line2); // KIT-18: 3-segment reach meter
            _ = (try el.text(ctx, act_in, "rt", txt)).with_style(.{ style.body, Style{ .text = faint } });
        },
    }

    // --- the corner: the way out of a long build ----------------------------------
    const corner = try el.div(ctx, row, "cn");
    _ = corner.with_size(.{ .fixed = w_corner }, .fit_children);
    var cancelled = false;
    var cancel_key: ?u64 = null;
    if (kind == .building) {
        const x = try el.div(ctx, corner, "x");
        _ = x.with_layout(.center_right);
        const x_key = x.get().key;
        ctx.registerFocus(x_key, true);
        const xq = x.query();
        if (xq.clicked) _ = ctx.requestFocus(x_key);
        const x_focused = ctx.isFocused(x_key);
        uic.publishControlState(ctx, x_key, .{
            .focused = x_focused,
            .focus_visible = x_focused,
        });
        if (xq.hovering) ctx.res.cursor.request(.pointer);
        _ = (try el.text(ctx, x, "t", "\u{00d7}"))
            .with_style(.{ style.h3, Style{ .text = if (xq.held or xq.hovering or x_focused) th.danger else th.line2 } });
        cancelled = x.consume(.clicked);
        cancel_key = x_key;
        // INPUT-08: the cancel corner is a button named for what it does to the build.
        ctx.res.semantics.publish(uic.semantic.describeIconButton(x_key, "Cancel build", true, x_focused));
    }

    // INPUT-08: the row is a composite tile. Its accessible name is the good's display
    // name (authoritative widget fact); `hot` is the same enabled fact the build click
    // gates on; it controls its cancel sub-action when one exists. Published after its own
    // descendants so children precede the container in paint order.
    var subs: [1]u64 = undefined;
    var subs_len: usize = 0;
    if (cancel_key) |ck| {
        subs[0] = ck;
        subs_len = 1;
    }
    ctx.res.semantics.publish(uic.semantic.describeTile(row_key, gt.display_name(GoodT), hot, focused, subs[0..subs_len]));

    return .{
        .kind = kind,
        .reach = reach,
        // The corner sits inside the row, so hover still bubbles and keeps the row lit.
        // Its activation is consumed above; re-query after descendants for the action.
        // `clicked_build` fires for a ready row's whole-box click OR an owned row's `Build +1`.
        .clicked_build = (hot and row.query().clicked) or build_more,
        .clicked_cancel = cancelled,
    };
}

/// A thin progress bar (a build in progress) — continuous fill. Fixed width so the numbers
/// beside it stay in a column.
fn meter(ctx: *UiCtx, parent: El, id: []const u8, frac: f32, color: Color) !void {
    const th = ctx.res.view.theme;
    const track = try el.div(ctx, parent, id);
    _ = track.with_size(.{ .fixed = 34 }, .{ .fixed = 3 })
        .with_style(.{Style{ .fill = th.line }});
    const fill = try el.div(ctx, track, "f");
    _ = fill.with_layout(.top_left)
        .with_size(.{ .fixed = 34 * std.math.clamp(frac, 0, 1) }, .{ .fixed = 3 })
        .with_style(.{Style{ .fill = color }});
}

/// The **3-segment reach meter** (KIT-18): three fixed cells that light in sequence as `frac`
/// crosses 1/3, 2/3, 3/3 — a coarse "how close to affordable" read that quantizes the reach
/// into thirds rather than a smooth bar, matching the prototype's segmented treatment. A lit
/// segment takes `color`; an unlit one the inactive `line`.
fn reach_meter(ctx: *UiCtx, parent: El, id: []const u8, frac: f32, color: Color) !void {
    const th = ctx.res.view.theme;
    const track = try el.div(ctx, parent, id);
    _ = track.with_size(.{ .fixed = 34 }, .{ .fixed = 4 }).with_flow(.{ .dir = .row }).with_gap(2);
    const lit_segments = reachSegments(frac);
    var s: usize = 0;
    while (s < 3) : (s += 1) {
        const seg = try el.div(ctx, track, &[_]u8{ 's', '0' + @as(u8, @intCast(s)) });
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
