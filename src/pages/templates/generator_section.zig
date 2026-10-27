//! `generator_section` — owned collectable capital as action-like tiles.
//!
//! Generators mature on simulation time without occupying `Busy`. A ready tile collects its
//! complete cycle immediately; the lower-right ON/OFF control pauses accumulation while preserving
//! progress. All readiness, cost, output, and progress comes from `capital.generator_quote`.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const capital = ha.capital;
const roster = ha.roster;
const World = ha.world.World;
const Entity = ha.world.Entity;

const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const El = uic.elements.El;

const action_tile = @import("./action_tile.zig");
const browser = @import("./browser.zig");
const info = @import("./action_info.zig");
const fmt = @import("../fmt.zig");

const section_gap: f32 = 12;
const grid_gap: f32 = 10;

fn isActOneGenerator(rec: roster.Good) bool {
    return rec.act <= 1 and rec.generator != null;
}

fn ownedCount(world: *World, e: Entity, cat: *const roster.Catalog) usize {
    const goods = world.get(e, comp.Goods) orelse return 0;
    var count: usize = 0;
    for (cat.goods, 0..) |rec, gi| {
        if (isActOneGenerator(rec) and goods.count[gi] > 0) count += 1;
    }
    return count;
}

fn cycleCost(act: u8, buf: []u8, q: capital.GeneratorQuote) []const u8 {
    var wr = std.Io.Writer.fixed(buf);
    var ebuf: [8]u8 = undefined;
    wr.print("\u{2212}{s}e", .{fmt.fmt_amount(&ebuf, q.spec.energy)}) catch {};
    for (q.rec.input) |line| {
        if (line.per != .day) continue;
        var nbuf: [8]u8 = undefined;
        wr.print(" \u{2212}{s}{s}", .{ fmt.fmt_amount(&nbuf, line.n * q.cycle_days), info.letterOf(act, line.item) }) catch {};
    }
    return wr.buffered();
}

const Yield = struct {
    kind: ha.dist.Kind = .fixed,
    text: []const u8,
};

fn cycleYield(act: u8, buf: []u8, q: capital.GeneratorQuote) Yield {
    var best: ?roster.Line = null;
    var best_mean: f32 = -1;
    for (q.rec.output) |line| {
        if (line.per != .day) continue;
        const mean = ha.dist.stats(line.asDist()).mean * q.cycle_days;
        if (mean > best_mean) {
            best = line;
            best_mean = mean;
        }
    }
    if (best) |line| {
        const stats = ha.dist.stats(line.asDist());
        const lo = @round(stats.p10 * q.cycle_days);
        const hi = @round(stats.p90 * q.cycle_days);
        const text = if (lo == hi)
            std.mem.print(buf, "+{d:.0}{s}", .{ hi, info.letterOf(act, line.item) }) catch "+?"
        else
            std.mem.print(buf, "+{d:.0}\u{2013}{d:.0}{s}", .{ lo, hi, info.letterOf(act, line.item) }) catch "+?";
        return .{ .kind = line.kind, .text = text };
    }
    return .{ .text = std.mem.print(buf, "+{d:.1}v", .{q.spec.vigor}) catch "+?v" };
}

fn stateWord(q: capital.GeneratorQuote) []const u8 {
    return switch (q.standing) {
        .charging => "accumulating",
        .off => "off",
        .ready => "ready — collect",
        .energy => "needs vigor",
        .short => "needs input",
    };
}

fn generatorTile(parent: El, world: *World, e: Entity, act: u8, gi: u16) !void {
    const ctx = parent.ctx;
    const cat = &ctx.res.catalog;
    const q = capital.generator_quote(world, e, cat, ctx.res.config, gi) orelse return;

    var cost_buf: [40]u8 = undefined;
    var duration_buf: [12]u8 = undefined;
    var yield_buf: [20]u8 = undefined;
    const duration = std.mem.print(&duration_buf, "{d:.0}h", .{q.spec.hours}) catch "?";
    const yield = cycleYield(act, &yield_buf, q);
    const progress: ?f32 = if (q.standing == .charging) q.fraction() else null;
    const display_name = if (q.spec.label.len > 0) q.spec.label else q.rec.name;
    const tile = try action_tile.tile(
        parent,
        q.rec.id,
        display_name,
        stateWord(q),
        cycleCost(act, &cost_buf, q),
        duration,
        yield.kind,
        yield.text,
        q.ready(),
        progress,
        .regular,
    );
    _ = tile.el.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);

    // Nested control, anchored out of flow in the lower-right corner so it never grows the tile.
    // Right/bottom padding mirror the tile's inner padding (12 x 6, with the box's 1px bottom
    // inset), aligning the label with the content edge. Pointer hit testing selects this topmost
    // child rather than also collecting the parent tile.
    const toggle = try tile.el.div("toggle");
    _ = toggle.with_layout(.bottom_right)
        .with_size(.fit_children, .fit_children)
        .with_flow(.{ .dir = .row })
        .with_style(.{style.pad_each(12, 12, 5, 6)});
    if (toggle.query().clicked) capital.toggle_generator(world, e, cat, gi);
    const is_on = !world.get(e, comp.Generators).?.off[gi];
    const tq = toggle.control(.{
        .name = if (is_on) "Turn generator off" else "Turn generator on",
        .role = .checkbox,
        .checked = is_on,
    });
    const toggle_color = if (tq.hovering or tq.held or tq.focused) ctx.res.view.theme.acc else if (is_on) ctx.res.view.theme.good else ctx.res.view.theme.dim;
    _ = (try toggle.text("label", if (is_on) "● ON" else "○ OFF"))
        .with_style(.{ style.small, Style{ .text = toggle_color } });

    if (tile.clicked) _ = capital.collect_generator(world, e, ctx.res, gi);
}

/// Build the Act I generator shelf in authored good order.
pub fn generator_section(parent: El, world: *World, e: Entity, id: []const u8) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const cat = &ctx.res.catalog;
    const compact = ctx.res.view.metrics.width_class.atMost(.w440);
    const count = ownedCount(world, e, cat);
    const act = ha.migration.actOf(world, e);

    const section = try parent.div(id);
    _ = section.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start }).with_gap(section_gap);

    var count_buf: [24]u8 = undefined;
    const count_text = std.mem.print(&count_buf, "{d} OWNED", .{count}) catch "OWNED";
    _ = try browser.browser_heading(section, "heading", "GENERATORS", "Let time accumulate, then collect without stopping your work.", count_text);

    if (count == 0) {
        _ = (try section.text("empty", "Build a generator to begin accumulating."))
            .with_style(.{ style.body, Style{ .text = th.line2 } });
        return section;
    }

    const grid = try section.div("grid");
    _ = grid.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
    const lanes: [2]El = if (compact) blk: {
        _ = grid.with_flow(.{ .dir = .column, .cross = .start }).with_gap(grid_gap);
        break :blk .{ grid, grid };
    } else blk: {
        _ = grid.with_flow(.{ .dir = .row, .cross = .start }).with_gap(grid_gap);
        const left = try grid.div("left");
        _ = left.with_size(.grow, .fit_children).with_flow(.{ .dir = .column }).with_gap(grid_gap);
        const right = try grid.div("right");
        _ = right.with_size(.grow, .fit_children).with_flow(.{ .dir = .column }).with_gap(grid_gap);
        break :blk .{ left, right };
    };

    const goods = world.get(e, comp.Goods).?;
    var lane: usize = 0;
    for (cat.goods, 0..) |rec, gi| {
        if (!isActOneGenerator(rec) or goods.count[gi] == 0) continue;
        try generatorTile(lanes[lane % 2], world, e, act, @intCast(gi));
        lane += 1;
    }
    return section;
}
