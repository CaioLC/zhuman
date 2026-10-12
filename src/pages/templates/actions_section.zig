//! `actions_section` — the complete fluid Act I actions surface: heading, five-verb count,
//! equal action columns, and Eating Policy. The section owns 100% of its parent surface, so
//! collapsing the HOLDINGS rail expands both columns while compact screens retain one column.

const std = @import("std");
const ha = @import("ha");
const comp = ha.comp;
const actions = ha.actions;
const roster = ha.roster;
const World = ha.world.World;
const Entity = ha.world.Entity;

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;

const action_tile_mod = @import("./action_tile.zig");
const eating_policy_mod = @import("./eating_policy.zig");

const tile_content_height: f32 = 81; // 82px outer height including action_tile's 1px inset
const section_gap: f32 = 12;
const grid_gap: f32 = 10;

fn gridColumns(compact: bool) u8 {
    return if (compact) 1 else 2;
}

fn placeTile(tile: El) void {
    _ = tile.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = tile_content_height })
        .with_flow(.{ .dir = .column, .main = .center });
}

fn placePolicy(parent: El, world: *World, e: Entity) !void {
    if (world.get(e, comp.Metabolism)) |met| {
        const policy_value = ha.eating.valueFromRate(met.rate);
        const new_policy = try eating_policy_mod.eating_policy(parent, "eating_policy", policy_value, true);
        met.rate = ha.eating.rate(new_policy);
    } else {
        _ = try eating_policy_mod.eating_policy(parent, "eating_policy", 50, false);
    }
}

/// Whether a verb record is on the Act I ACTIONS surface: flagged on-surface and of this
/// act. The roster's order is the reading order; the section is the game adapter, the tile
/// is presentation and takes no domain function.
fn onSurface(rec: roster.Action) bool {
    return rec.on_surface and rec.act <= 1;
}

/// How many verbs the surface lists.
pub fn surfaceCount(cat: *const roster.Catalog) usize {
    var n: usize = 0;
    for (cat.actions) |rec| {
        if (onSurface(rec)) n += 1;
    }
    return n;
}

/// Build the complete actions section. Every card fills its equal column and the policy
/// value remains live simulation state.
pub fn actions_section(parent: El, world: *World, e: Entity, id: []const u8) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const compact = ctx.res.view.metrics.width_class.atMost(.w440);

    const section = try parent.div(id);
    _ = section.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start }).with_gap(section_gap);

    const heading = try section.div("heading");
    _ = heading.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .baseline }).with_gap(12);
    const heading_copy = try heading.div("copy");
    _ = heading_copy.with_flow(.{ .dir = .column, .cross = .start });
    _ = (try heading_copy.text("title", "ACTIONS"))
        .with_style(.{ style.h3, Style{ .text = th.fg } });
    _ = (try heading_copy.text("subtitle", "What will this body do now?"))
        .with_style(.{Style{ .font = 11, .text = th.dim }});
    const cat = &ctx.res.catalog;
    var count_buf: [16]u8 = undefined;
    const count_txt = std.fmt.bufPrint(&count_buf, "{d} VERBS", .{surfaceCount(cat)}) catch "VERBS";
    _ = (try heading.text("count", count_txt))
        .with_style(.{ style.eyebrow, Style{ .text = th.dim } });

    const grid = try section.div("grid");
    _ = grid.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);

    // One column at the compact breakpoint; otherwise two equal grow columns that preserve
    // row-major reading order visually: Forage/Scavenge, Split wood/Fish, Check traps/Eating
    // Policy. `lanes` is the column each verb lands in by its index parity.
    const lanes: [2]El = if (gridColumns(compact) == 1) blk: {
        _ = grid.with_flow(.{ .dir = .column, .cross = .start }).with_gap(grid_gap);
        break :blk .{ grid, grid };
    } else blk: {
        _ = grid.with_flow(.{ .dir = .row, .cross = .start }).with_gap(grid_gap);
        const left = try grid.div("left");
        _ = left.with_size(.grow, .fit_children)
            .with_flow(.{ .dir = .column, .cross = .start }).with_gap(grid_gap);
        const right = try grid.div("right");
        _ = right.with_size(.grow, .fit_children)
            .with_flow(.{ .dir = .column, .cross = .start }).with_gap(grid_gap);
        break :blk .{ left, right };
    };

    // A surface verb takes a lane whether or not the agent holds it yet, so the grid keeps
    // its reading order as verbs arrive.
    var lane: usize = 0;
    for (cat.actions, 0..) |rec, i| {
        if (!onSurface(rec)) continue;
        const ai: u16 = @intCast(i);
        if (try action_tile_mod.action_tile(lanes[lane % 2], world, e, ai, rec.id)) |tl| {
            placeTile(tl.el);
            if (tl.clicked) actions.begin(world, e, ctx.res, ai);
        }
        lane += 1;
    }
    try placePolicy(lanes[1], world, e);

    return section;
}

test "actions grid uses one compact column and two fluid wide columns" {
    try std.testing.expectEqual(@as(u8, 1), gridColumns(true));
    try std.testing.expectEqual(@as(u8, 2), gridColumns(false));
    try std.testing.expectEqual(@as(f32, 81), tile_content_height);
}
