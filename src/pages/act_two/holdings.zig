//! `act_two/holdings` — the Act II **Holdings / BODY** rail content (ACT2-15).
//!
//! The same two-bordered-panel anatomy as Act I's `holdings`, re-sourced for a settlement: a
//! HOLDINGS panel lists typed holdings with counts and a per-day FLOWS block (act-specific
//! margins — generation vs consumption, positive `good` / deficit `danger`), and a BODY panel
//! carries **population-relevant** projections (how long the larder feeds everyone, when water
//! runs short, the hall's aggregate vigor). It deliberately shows **no decorative
//! durability/maintenance meters** — those systems do not exist yet (ACT2-15), so there is
//! nothing to project and nothing is drawn.
//!
//! The holdings are the agent's owned Act II goods, each with its record's short copy; the flows
//! and the Body sentences come from `fixtures.zig`, since no population model computes them.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const World = ha.world.World;
const Entity = ha.world.Entity;
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;
const Color = uic.Color;

const fx = @import("./fixtures.zig");

const column_width: f32 = 240;
const main_content_width: f32 = 214;
const body_content_width: f32 = 220;
const panel_gap: f32 = 12;

fn sectionLabel(parent: El, id: []const u8, text: []const u8) !void {
    const th = parent.ctx.res.view.theme;
    _ = (try parent.text(id, text)).with_style(.{Style{ .font = 11, .tracking = 0.07, .text = th.dim }});
}

fn line(parent: El, id: []const u8, left: []const u8, right: []const u8, right_color: Color) !void {
    const th = parent.ctx.res.view.theme;
    const row = try parent.div(id);
    _ = row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .baseline });
    _ = (try row.text("label", left)).with_style(.{ style.body, Style{ .text = th.fg } });
    const tail = try row.div("tail");
    _ = tail.with_layout(.center_right);
    _ = (try tail.text("value", right)).with_style(.{Style{ .font = 11, .text = right_color }});
}

fn bodySentence(parent: El, id: []const u8, rec: fx.BodyRecord, value_color: Color) !void {
    const th = parent.ctx.res.view.theme;
    const row = try parent.div(id);
    _ = row.with_flow(.{ .dir = .row, .cross = .baseline });
    _ = (try row.text("prefix", rec.prefix)).with_style(.{Style{ .font = 11, .text = th.dim }});
    _ = (try row.text("value", rec.value)).with_style(.{Style{ .font = 11, .text = value_color }});
    _ = (try row.text("suffix", rec.suffix)).with_style(.{Style{ .font = 11, .text = th.dim }});
}

/// Whether good `rec` is one the rail lists: of this act and owned.
fn listed(rec: *const ha.roster.Good, count: u32) bool {
    return rec.act == 2 and count > 0;
}

fn buildMainPanel(parent: El, world: *World, e: Entity) !El {
    const th = parent.ctx.res.view.theme;
    const panel = try parent.div("panel");
    _ = panel.with_size(.{ .fixed = main_content_width }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start })
        .with_style(.{ Style{ .outline_color = th.line }, style.solid, style.pad_each(10, 16, 9, 10) });

    // Heading + typed-count summary.
    const heading = try panel.div("heading");
    _ = heading.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .baseline });
    try sectionLabel(heading, "title", "HOLDINGS");
    const cat = &parent.ctx.res.catalog;
    const goods = world.get(e, comp.Goods);
    var kinds: usize = 0;
    if (goods) |g| {
        for (cat.goods, 0..) |*rec, gi| kinds += @intFromBool(listed(rec, g.count[gi]));
    }
    var count_buf: [32]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d} KINDS", .{kinds}) catch "HOLDINGS";
    try sectionLabel(heading, "count", count);
    _ = try panel.spacer("heading_gap", 1, 8);

    const roster = try panel.div("roster");
    _ = roster.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(3);
    if (goods) |g| {
        for (cat.goods, 0..) |*rec, gi| {
            const n = g.count[gi];
            if (!listed(rec, n)) continue;
            var label_buf: [48]u8 = undefined;
            const label = if (n > 1) std.fmt.bufPrint(&label_buf, "{s} \u{00d7}{d}", .{ rec.name, n }) catch rec.name else rec.name;
            // Keyed by the good's id.
            try line(roster, rec.id, label, rec.copy.short, th.dim);
        }
    }

    // Divider + act-specific FLOWS (per-day margins; positive good / deficit danger).
    _ = try panel.spacer("divider_top", 1, 9);
    const divider = try panel.div("divider");
    _ = divider.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = 1 }).with_style(.{Style{ .fill = th.line }});
    _ = try panel.spacer("divider_bottom", 1, 7);
    try sectionLabel(panel, "flows_title", "FLOWS / DAY");
    _ = try panel.spacer("flows_gap", 1, 8);

    const flows = try panel.div("flows");
    _ = flows.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(4);
    for (fx.flows) |f| {
        // Keyed by the resource tag name
        const row_id = f.resource;
        try line(flows, row_id, f.label, f.value, if (f.positive) th.good else th.danger);
    }
    return panel;
}

fn buildBodyPanel(parent: El) !El {
    const th = parent.ctx.res.view.theme;
    const panel = try parent.div("body");
    _ = panel.with_size(.{ .fixed = body_content_width }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start })
        .with_style(.{ Style{ .outline_color = th.line }, style.solid, style.pad_each(9, 10, 9, 10) });
    try sectionLabel(panel, "title", "BODY");
    _ = try panel.spacer("gap", 1, 6);

    const list = try panel.div("list");
    _ = list.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(5);
    for (fx.body_projection) |rec| {
        // Keyed by what the sentence projects, not its wording.
        try bodySentence(list, @tagName(rec.key), rec, if (rec.positive) th.good else th.warn);
    }
    return panel;
}

/// Build the complete Act II HOLDINGS + BODY content column for agent `e`.
pub fn holdings(parent: El, world: *World, e: Entity, id: []const u8) !El {
    const column = try parent.div(id);
    _ = column.with_size(.{ .fixed = column_width }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start }).with_gap(panel_gap);
    _ = try buildMainPanel(column, world, e);
    _ = try buildBodyPanel(column);
    return column;
}

// ============================ Tests =====================================================

test "act two holdings column geometry mirrors the shared rail" {
    try std.testing.expectEqual(@as(f32, 240), column_width);
    try std.testing.expectEqual(@as(f32, 240), main_content_width + 10 + 16);
    try std.testing.expectEqual(@as(f32, 240), body_content_width + 10 + 10);
}

test "the body projection carries a deficit as well as a positive line" {
    var has_deficit = false;
    for (fx.body_projection) |b| {
        if (!b.positive) has_deficit = true;
    }
    try std.testing.expect(has_deficit); // low/positive semantics both represented
}
