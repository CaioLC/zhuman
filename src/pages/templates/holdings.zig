//! `holdings` — the standalone Act I left-column content from `prototypes/holdings.png`.
//! One bordered HOLDINGS panel contains the owned-good roster and live MARGINS; a distinct
//! bordered BODY panel sits 12px below it. Rail collapse chrome remains the rail template's
//! responsibility, so this component can be audited independently and later recomposed.

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

const gt = @import("./good_text.zig");

// CSS counterpart: a 252px rail minus 2px rail padding and 10px panel margin. The engine's
// fixed sizes are content boxes, so panel widths below subtract their authored padding.
const column_width: f32 = 240;
const main_content_width: f32 = 214; // 240 - 10 left - 16 right
const body_content_width: f32 = 220; // 240 - 10 left - 10 right
const panel_gap: f32 = 12;

// The reference gives frequently-read, body-scale goods first. The catalog remains authoritative
// for ownership/count semantics; this tuple only owns roster presentation order.
const holding_bundle = .{
    comp.Sandals,
    comp.RootCellar,
    comp.LeafBed,
    comp.Hatchet,
    comp.FishRod,
    comp.WireSnares,
    comp.AirRifle,
    comp.WorkGloves,
    comp.Bicycle,
    comp.Cookpot,
    comp.Chainsaw,
    comp.Pantry,
    comp.MedicineChest,
    comp.GardenBed,
    comp.ChickenCoop,
    comp.Shelter,
};

/// A roster/margin line: body-size primary copy and the reference's 11px right readout.
fn line(parent: El, id: []const u8, left: []const u8, right: []const u8, right_color: uic.Color) !void {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const row = try parent.div(id);
    _ = row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .baseline });
    _ = (try row.text("label", left))
        .with_style(.{ style.body, Style{ .text = th.fg } });
    const tail = try row.div("tail");
    _ = tail.with_layout(.center_right);
    _ = (try tail.text("value", right))
        .with_style(.{Style{ .font = 11, .text = right_color }});
}

fn sectionLabel(parent: El, id: []const u8, text: []const u8) !void {
    const ctx = parent.ctx;
    _ = (try parent.text(id, text)).with_style(.{
        Style{ .font = 11, .tracking = 0.07, .text = ctx.res.view.theme.dim },
    });
}

/// Compact ownership copy used by the narrow rail. BUILD keeps the longer explanatory sentence.
fn compactEffect(comptime GoodT: type) []const u8 {
    return switch (GoodT) {
        comp.FishRod => "can fish",
        comp.Hatchet => "can split wood",
        comp.WireSnares => "can check traps",
        comp.AirRifle => "can hunt",
        comp.Sandals => "forage costs less",
        comp.WorkGloves => "split wood costs less",
        comp.Bicycle => "roaming costs less",
        comp.Cookpot => "food feeds further",
        comp.RootCellar => "food keeps 2\u{00d7}",
        comp.Chainsaw => "fuel does the work",
        comp.LeafBed => "vigor ceiling +1",
        comp.Pantry => "vigor ceiling +2",
        comp.MedicineChest => "vigor ceiling +2",
        comp.GardenBed => "grows food",
        comp.ChickenCoop => "hens lay food",
        comp.Shelter => "room for four",
        else => @compileError("no compact holding effect for " ++ @typeName(GoodT)),
    };
}

fn actionMargin(parent: El, world: *World, e: Entity, comptime ActionT: type, id: []const u8, name: []const u8) !void {
    const ctx = parent.ctx;
    const live = world.get(e, ActionT) orelse return;
    const base = (ActionT{}).requires.energy;
    if (@abs(live.requires.energy - base) < 0.001) return;
    const th = ctx.res.view.theme;
    var buf: [40]u8 = undefined;
    const value = std.fmt.bufPrint(&buf, "{d:.1}e \u{2192} {d:.1}e", .{ base, live.requires.energy }) catch return;
    try line(parent, id, name, value, if (live.requires.energy < base) th.good else th.danger);
}

fn spareUnits(world: *World, e: Entity) u32 {
    var spares: u32 = 0;
    inline for (capital.buildable_bundle) |GoodT| {
        if (world.get(e, GoodT)) |held| spares += held.count -| 1;
    }
    return spares;
}

fn generatorFoodPerDay(world: *World, e: Entity) f32 {
    var per_day: f32 = 0;
    inline for (.{ comp.GardenBed, comp.ChickenCoop }) |GoodT| {
        if (world.has(e, GoodT)) per_day += (GoodT{}).yields.food.s;
    }
    return per_day;
}

/// One BODY sentence with dim prose and a foreground/semantic live value.
fn bodySentence(parent: El, id: []const u8, prefix: []const u8, value: []const u8, suffix: []const u8, value_color: uic.Color) !void {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const row = try parent.div(id);
    _ = row.with_flow(.{ .dir = .row, .cross = .baseline });
    _ = (try row.text("prefix", prefix)).with_style(.{Style{ .font = 11, .text = th.dim }});
    _ = (try row.text("value", value)).with_style(.{Style{ .font = 11, .text = value_color }});
    _ = (try row.text("suffix", suffix)).with_style(.{Style{ .font = 11, .text = th.dim }});
}

fn buildMainPanel(parent: El, world: *World, e: Entity) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const panel = try parent.div("panel");
    _ = panel.with_size(.{ .fixed = main_content_width }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start })
        .with_style(.{
        Style{ .outline_color = th.line },
        style.solid,
        style.pad_each(10, 16, 9, 10),
    });

    var units: u32 = 0;
    inline for (capital.buildable_bundle) |GoodT| {
        if (world.get(e, GoodT)) |held| units += held.count;
    }
    const kinds = capital.goods_owned(world, e);

    const heading = try panel.div("heading");
    _ = heading.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .baseline });
    try sectionLabel(heading, "title", "HOLDINGS");
    var count_buf: [32]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d} KINDS, {d}", .{ kinds, units }) catch "HOLDINGS";
    try sectionLabel(heading, "count", count);
    _ = try panel.spacer("heading_gap", 1, 8);

    const roster = try panel.div("roster");
    _ = roster.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(3);
    if (kinds == 0) {
        _ = (try roster.text("none", "nothing built yet"))
            .with_style(.{ style.body, Style{ .text = th.line2 } });
    } else {
        inline for (holding_bundle, 0..) |GoodT, i| {
            if (world.get(e, GoodT)) |held| {
                var label_buf: [48]u8 = undefined;
                const label = if (held.count > 1)
                    std.fmt.bufPrint(&label_buf, "{s} \u{00d7}{d}", .{ gt.display_name(GoodT), held.count }) catch gt.display_name(GoodT)
                else
                    gt.display_name(GoodT);
                try line(roster, std.fmt.comptimePrint("good{d}", .{i}), label, compactEffect(GoodT), th.dim);
            }
        }
    }

    _ = try panel.spacer("divider_top", 1, 9);
    const divider = try panel.div("divider");
    _ = divider.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = 1 })
        .with_style(.{Style{ .fill = th.line }});
    _ = try panel.spacer("divider_bottom", 1, 7);
    try sectionLabel(panel, "margins_title", "MARGINS");
    _ = try panel.spacer("margins_gap", 1, 8);

    const margins = try panel.div("margins");
    _ = margins.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(4);
    try actionMargin(margins, world, e, comp.ActionForage, "forage", "Forage");
    try actionMargin(margins, world, e, comp.ActionScavenge, "scavenge", "Scavenge");
    try actionMargin(margins, world, e, comp.ActionChopWood, "wood", "Split wood");
    try actionMargin(margins, world, e, comp.ActionFish, "fish", "Fish");
    try actionMargin(margins, world, e, comp.ActionCheckTraps, "traps", "Traps");
    try actionMargin(margins, world, e, comp.ActionHunt, "hunt", "Hunt");

    if (world.get(e, comp.InventoryFood)) |food| {
        if (food.quality != ha.baselines.food_quality) {
            var quality_buf: [32]u8 = undefined;
            const quality = std.fmt.bufPrint(&quality_buf, "{d} \u{2192} {d}", .{ ha.baselines.food_quality, food.quality }) catch "?";
            try line(margins, "quality", "Food quality", quality, if (food.quality > ha.baselines.food_quality) th.good else th.danger);
        }
        var spoil_buf: [40]u8 = undefined;
        const spoilage = std.fmt.bufPrint(&spoil_buf, "{d:.2} \u{2192} {d:.2}/day", .{ ha.baselines.food_spoils, food.spoils }) catch "?";
        const spoil_color = if (food.spoils < ha.baselines.food_spoils) th.good else if (food.spoils > ha.baselines.food_spoils) th.danger else th.dim;
        try line(margins, "spoilage", "Food spoilage", spoilage, spoil_color);
    }

    if (world.get(e, comp.Vigor)) |vigor| {
        var vigor_buf: [24]u8 = undefined;
        const ceiling = std.fmt.bufPrint(&vigor_buf, "{d:.0}", .{vigor.max}) catch "?";
        try line(margins, "vigor", "Vigor ceiling", ceiling, th.dim);
    }

    var spare_buf: [32]u8 = undefined;
    const spares = spareUnits(world, e);
    const spare_text = std.fmt.bufPrint(&spare_buf, "{d} spare {s}", .{ spares, if (spares == 1) "unit" else "units" }) catch "?";
    try line(margins, "trade", "Trade stock", spare_text, th.dim);

    return panel;
}

fn buildBodyPanel(parent: El, world: *World, e: Entity) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const panel = try parent.div("body");
    _ = panel.with_size(.{ .fixed = body_content_width }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start })
        .with_style(.{
        Style{ .outline_color = th.line },
        style.solid,
        style.pad_each(9, 10, 9, 10),
    });
    try sectionLabel(panel, "title", "BODY");

    const met = world.get(e, comp.Metabolism) orelse {
        _ = (try panel.text("missing", "no body projection"))
            .with_style(.{Style{ .font = 11, .text = th.dim }});
        return panel;
    };
    const food = world.get(e, comp.InventoryFood) orelse return panel;
    const vigor = world.get(e, comp.Vigor) orelse return panel;
    const rate = ctx.res.config.clampMetabolism(met.rate);
    const policy = ha.eating.word(ha.eating.valueFromRate(rate));
    try bodySentence(panel, "policy", "Eating ", policy, ".", th.fg);

    const net = ha.systems.net_food_drawdown(met.base_rate, rate, generatorFoodPerDay(world, e));
    if (net <= 0.001) {
        try bodySentence(panel, "coverage", "Larder ", "holds", ".", th.good);
    } else {
        var coverage_buf: [24]u8 = undefined;
        const coverage = std.fmt.bufPrint(&coverage_buf, "{d:.1}d", .{food.v / net}) catch "?";
        try bodySentence(panel, "coverage", "Food lasts ", coverage, ".", if (food.v / net < 2) th.danger else th.fg);
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
        .at_ceiling => try bodySentence(panel, "recovery", "Vigor is ", "full", ".", th.good),
        .no_food => try bodySentence(panel, "recovery", "Recovery: ", "starving", ".", th.danger),
        .no_quality => try bodySentence(panel, "recovery", "Recovery: ", "no vigor", ".", th.danger),
        .partial => |partial| {
            const restored = std.fmt.bufPrint(&recovery_buf, "+{d:.0} vigor", .{partial.restored}) catch "?";
            try bodySentence(panel, "recovery", "Can recover ", restored, ".", th.warn);
        },
        .recovering => |recovering| {
            const days = std.fmt.bufPrint(&recovery_buf, "{d:.1}d", .{recovering.days}) catch "?";
            try bodySentence(panel, "recovery", "Full vigor in ", days, ".", th.fg);
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
    try std.testing.expectEqual(@as(f32, 240), main_content_width + 10 + 16);
    try std.testing.expectEqual(@as(f32, 240), body_content_width + 10 + 10);
}

test "holdings uses compact rail-specific effect copy" {
    try std.testing.expectEqualStrings("forage costs less", compactEffect(comp.Sandals));
    try std.testing.expectEqualStrings("food keeps 2\u{00d7}", compactEffect(comp.RootCellar));
    try std.testing.expectEqualStrings("vigor ceiling +1", compactEffect(comp.LeafBed));
    try std.testing.expectEqualStrings("can split wood", compactEffect(comp.Hatchet));
}
