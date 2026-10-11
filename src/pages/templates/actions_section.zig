//! `actions_section` — the complete fluid Act I actions surface: heading, five-verb count,
//! equal action columns, and Eating Policy. The section owns 100% of its parent surface, so
//! collapsing the HOLDINGS rail expands both columns while compact screens retain one column.

const std = @import("std");
const ha = @import("ha");
const comp = ha.comp;
const actions = ha.actions;
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

/// The five Act I verbs in reading order: the action component, the tile id and label, and
/// the simulation operation the section calls when the tile reports its activation. The
/// section is the game adapter; the tile is presentation and takes no domain function.
const verbs = .{
    .{ comp.ActionForage, "forage", "Forage", actions.action_forage },
    .{ comp.ActionScavenge, "scavenge", "Scavenge", actions.action_scavenge },
    .{ comp.ActionChopWood, "split_wood", "Split wood", actions.action_chop_wood },
    .{ comp.ActionFish, "fish", "Fish", actions.action_fish },
    .{ comp.ActionCheckTraps, "check_traps", "Check traps", actions.action_check_traps },
};

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
    _ = (try heading.text("count", "5 VERBS"))
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

    inline for (verbs, 0..) |verb, i| {
        if (try action_tile_mod.action_tile(lanes[i % 2], world, e, verb[0], verb[1], verb[2])) |t| {
            placeTile(t.el);
            if (t.clicked) verb[3](world, e, ctx.res);
        }
    }
    try placePolicy(lanes[1], world, e);

    return section;
}

test "actions grid uses one compact column and two fluid wide columns" {
    try std.testing.expectEqual(@as(u8, 1), gridColumns(true));
    try std.testing.expectEqual(@as(u8, 2), gridColumns(false));
    try std.testing.expectEqual(@as(f32, 81), tile_content_height);
}
