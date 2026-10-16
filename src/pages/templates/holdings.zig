//! `holdings` — the standalone Act I left-column content from `prototypes/holdings.png`.
//! One bordered HOLDINGS panel contains the owned-good roster and live MARGINS; a distinct
//! bordered BODY panel sits 12px below it. Rail collapse chrome remains the rail template's
//! responsibility, so this component can be audited independently and later recomposed.
//! The panels, labels, lines and sentences are `readout`'s; this file supplies the numbers.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const effects = ha.effects;
const roster = ha.roster;
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;
const World = ha.world.World;
const Entity = ha.world.Entity;

const readout = @import("./readout.zig");

// CSS counterpart: a 252px rail minus 2px rail padding and 10px panel margin. The engine's
// fixed sizes are content boxes, so panel widths below subtract their authored padding.
const column_width: f32 = 240;
const main_pad: readout.Pad = .{ .up = 10, .right = 16, .down = 9, .left = 10 };
const body_pad: readout.Pad = .{ .up = 9, .right = 10, .down = 9, .left = 10 };
const main_content_width: f32 = 214; // 240 - 10 left - 16 right
const body_content_width: f32 = 220; // 240 - 10 left - 10 right
const panel_gap: f32 = 12;

/// One margin line per held verb whose price the goods have moved: `1.7e → 1.4e`.
fn actionMargins(parent: El, world: *World, e: Entity) !void {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const cat = &ctx.res.catalog;
    const goods = world.get(e, comp.Goods) orelse return;
    for (cat.actions, 0..) |rec, ai| {
        const live = effects.verb(cat, goods, ai) orelse continue;
        const base = rec.requires.energy;
        if (@abs(live.requires.energy - base) < 0.001) continue;
        var buf: [40]u8 = undefined;
        const value = std.fmt.bufPrint(&buf, "{d:.1}e \u{2192} {d:.1}e", .{ base, live.requires.energy }) catch continue;
        try readout.kv_line_in(try parent.item("margin", ai), rec.name, value, if (live.requires.energy < base) th.good else th.danger);
    }
}

/// Units beyond the first of every owned good — what a trader could take.
fn spareUnits(world: *World, e: Entity, cat: *const roster.Catalog) u32 {
    const goods = world.get(e, comp.Goods) orelse return 0;
    var spares: u32 = 0;
    for (cat.goods, 0..) |_, gi| spares += goods.count[gi] -| 1;
    return spares;
}

fn buildMainPanel(parent: El, world: *World, e: Entity) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const cat = &ctx.res.catalog;
    const panel = try readout.readout_panel(parent, "panel", main_content_width, main_pad);

    var units: u32 = 0;
    var kinds: u32 = 0;
    if (world.get(e, comp.Goods)) |goods| {
        for (cat.goods, 0..) |_, gi| {
            units += goods.count[gi];
            if (goods.count[gi] > 0) kinds += 1;
        }
    }

    var count_buf: [32]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d} KINDS, {d}", .{ kinds, units }) catch "HOLDINGS";
    _ = try readout.readout_heading(panel, "heading", "HOLDINGS", count);
    _ = try panel.spacer("heading_gap", 1, 8);

    const owned = try panel.div("roster");
    _ = owned.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(3);
    if (kinds == 0) {
        _ = (try owned.text("none", "nothing built yet"))
            .with_style(.{ style.body, Style{ .text = th.line2 } });
    } else if (world.get(e, comp.Goods)) |goods| {
        // Owned goods in roster order, keyed by id so a row follows its good.
        for (cat.goods, 0..) |rec, gi| {
            const n = goods.count[gi];
            if (n == 0) continue;
            var label_buf: [48]u8 = undefined;
            const label = if (n > 1)
                std.fmt.bufPrint(&label_buf, "{s} \u{00d7}{d}", .{ rec.name, n }) catch rec.name
            else
                rec.name;
            try readout.kv_line_in(try owned.div(rec.id), label, rec.copy.short, th.dim);
        }
    }

    try readout.divider(panel, "divider", 9, 7);
    _ = try readout.section_label(panel, "margins_title", "MARGINS");
    _ = try panel.spacer("margins_gap", 1, 8);

    const margins = try panel.div("margins");
    _ = margins.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(4);
    try actionMargins(margins, world, e);

    if (world.get(e, comp.InventoryFood)) |food| {
        if (food.quality != ha.baselines.food_quality) {
            var quality_buf: [32]u8 = undefined;
            const quality = std.fmt.bufPrint(&quality_buf, "{d} \u{2192} {d}", .{ ha.baselines.food_quality, food.quality }) catch "?";
            try readout.kv_line(margins, "quality", "Food quality", quality, if (food.quality > ha.baselines.food_quality) th.good else th.danger);
        }
        var spoil_buf: [40]u8 = undefined;
        const spoilage = std.fmt.bufPrint(&spoil_buf, "{d:.2} \u{2192} {d:.2}/day", .{ ha.baselines.food_spoils, food.spoils }) catch "?";
        const spoil_color = if (food.spoils < ha.baselines.food_spoils) th.good else if (food.spoils > ha.baselines.food_spoils) th.danger else th.dim;
        try readout.kv_line(margins, "spoilage", "Food spoilage", spoilage, spoil_color);
    }

    if (world.get(e, comp.Vigor)) |vigor| {
        var vigor_buf: [24]u8 = undefined;
        const ceiling = std.fmt.bufPrint(&vigor_buf, "{d:.0}", .{vigor.max}) catch "?";
        try readout.kv_line(margins, "vigor", "Vigor ceiling", ceiling, th.dim);
    }

    var spare_buf: [32]u8 = undefined;
    const spares = spareUnits(world, e, cat);
    const spare_text = std.fmt.bufPrint(&spare_buf, "{d} spare {s}", .{ spares, if (spares == 1) "unit" else "units" }) catch "?";
    try readout.kv_line(margins, "trade", "Trade stock", spare_text, th.dim);

    return panel;
}

fn buildBodyPanel(parent: El, world: *World, e: Entity) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const panel = try readout.readout_panel(parent, "body", body_content_width, body_pad);
    _ = try readout.section_label(panel, "title", "BODY");

    const met = world.get(e, comp.Metabolism) orelse {
        _ = (try panel.text("missing", "no body projection"))
            .with_style(.{Style{ .font = 11, .text = th.dim }});
        return panel;
    };
    const food = world.get(e, comp.InventoryFood) orelse return panel;
    const vigor = world.get(e, comp.Vigor) orelse return panel;
    const rate = ctx.res.config.clampMetabolism(met.rate);
    const policy = ha.eating.word(ha.eating.valueFromRate(rate));
    try readout.sentence(panel, "policy", "Eating ", policy, ".", th.fg);

    const net = ha.systems.net_food_drawdown(met.base_rate, rate, 0);
    if (net <= 0.001) {
        try readout.sentence(panel, "coverage", "Larder ", "holds", ".", th.good);
    } else {
        var coverage_buf: [24]u8 = undefined;
        const coverage = std.fmt.bufPrint(&coverage_buf, "{d:.1}d", .{food.v / net}) catch "?";
        try readout.sentence(panel, "coverage", "Food lasts ", coverage, ".", if (food.v / net < 2) th.danger else th.fg);
    }

    const projection = ha.body.project(.{
        .food = food.v,
        .quality = food.quality,
        .vigor = vigor.v,
        .vigor_max = vigor.max,
        .base_rate = met.base_rate,
        .rate = rate,
        .vigor_per_food = ctx.res.config.vigor_per_food,
    });
    var recovery_buf: [32]u8 = undefined;
    switch (projection.recovery) {
        .at_ceiling => try readout.sentence(panel, "recovery", "Vigor is ", "full", ".", th.good),
        .no_food => try readout.sentence(panel, "recovery", "Recovery: ", "starving", ".", th.danger),
        .no_quality => try readout.sentence(panel, "recovery", "Recovery: ", "no vigor", ".", th.danger),
        .partial => |partial| {
            const restored = std.fmt.bufPrint(&recovery_buf, "+{d:.0} vigor", .{partial.restored}) catch "?";
            try readout.sentence(panel, "recovery", "Can recover ", restored, ".", th.warn);
        },
        .recovering => |recovering| {
            const days = std.fmt.bufPrint(&recovery_buf, "{d:.1}d", .{recovering.days}) catch "?";
            try readout.sentence(panel, "recovery", "Full vigor in ", days, ".", th.fg);
        },
    }
    return panel;
}

/// Build the complete standalone HOLDINGS + BODY content column.
pub fn holdings(parent: El, world: *World, e: Entity, id: []const u8) !El {
    const column = try parent.div(id);
    _ = column.with_size(.{ .fixed = column_width }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start }).with_gap(panel_gap);
    _ = try buildMainPanel(column, world, e);
    _ = try buildBodyPanel(column, world, e);
    return column;
}

test "holdings column geometry mirrors the standalone reference" {
    try std.testing.expectEqual(@as(f32, 240), column_width);
    try std.testing.expectEqual(@as(f32, 12), panel_gap);
    try std.testing.expectEqual(@as(f32, 240), main_content_width + main_pad.left + main_pad.right);
    try std.testing.expectEqual(@as(f32, 240), body_content_width + body_pad.left + body_pad.right);
}

test "every buildable good carries the rail's compact copy" {
    var cat = try roster.load(std.testing.allocator, roster.shipped, null);
    defer cat.deinit();
    for (cat.goods) |g| {
        if (g.buildable) try std.testing.expect(g.copy.short.len > 0);
    }
    try std.testing.expectEqualStrings("forage costs less", cat.good("sandals").?.copy.short);
    try std.testing.expectEqualStrings("food keeps 2\u{00d7}", cat.good("root_cellar").?.copy.short);
}

test "spare goods feed the holdings panel numbers" {
    var cat = try roster.load(std.testing.allocator, roster.shipped, null);
    defer cat.deinit();
    var w = World.init();
    const e = w.spawn(.{comp.Goods{}});
    const goods = w.get(e, comp.Goods).?;
    goods.count[cat.goodIndex("sandals").?] = 3;
    try std.testing.expectEqual(@as(u32, 2), spareUnits(&w, e, &cat));
}
