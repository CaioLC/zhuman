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

fn placeTile(tile: ?El) void {
    if (tile) |t| {
        _ = t.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = tile_content_height })
            .with_flow(.{ .dir = .column, .main = .center });
    }
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

/// Build the complete actions section. Action execution remains delegated to `action_tile`;
/// every card fills its equal column and the policy value remains live simulation state.
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

    if (gridColumns(compact) == 1) {
        _ = grid.with_flow(.{ .dir = .column, .cross = .start }).with_gap(grid_gap);
        placeTile(try action_tile_mod.action_tile(grid, world, e, comp.ActionForage, "forage", "Forage", actions.action_forage));
        placeTile(try action_tile_mod.action_tile(grid, world, e, comp.ActionScavenge, "scavenge", "Scavenge", actions.action_scavenge));
        placeTile(try action_tile_mod.action_tile(grid, world, e, comp.ActionChopWood, "split_wood", "Split wood", actions.action_chop_wood));
        placeTile(try action_tile_mod.action_tile(grid, world, e, comp.ActionFish, "fish", "Fish", actions.action_fish));
        placeTile(try action_tile_mod.action_tile(grid, world, e, comp.ActionCheckTraps, "check_traps", "Check traps", actions.action_check_traps));
        try placePolicy(grid, world, e);
    } else {
        // Two equal grow columns preserve row-major reading order visually:
        // Forage/Scavenge, Split wood/Fish, Check traps/Eating Policy.
        _ = grid.with_flow(.{ .dir = .row, .cross = .start }).with_gap(grid_gap);
        const left = try grid.div("left");
        _ = left.with_size(.grow, .fit_children)
            .with_flow(.{ .dir = .column, .cross = .start }).with_gap(grid_gap);
        const right = try grid.div("right");
        _ = right.with_size(.grow, .fit_children)
            .with_flow(.{ .dir = .column, .cross = .start }).with_gap(grid_gap);

        placeTile(try action_tile_mod.action_tile(left, world, e, comp.ActionForage, "forage", "Forage", actions.action_forage));
        placeTile(try action_tile_mod.action_tile(right, world, e, comp.ActionScavenge, "scavenge", "Scavenge", actions.action_scavenge));
        placeTile(try action_tile_mod.action_tile(left, world, e, comp.ActionChopWood, "split_wood", "Split wood", actions.action_chop_wood));
        placeTile(try action_tile_mod.action_tile(right, world, e, comp.ActionFish, "fish", "Fish", actions.action_fish));
        placeTile(try action_tile_mod.action_tile(left, world, e, comp.ActionCheckTraps, "check_traps", "Check traps", actions.action_check_traps));
        try placePolicy(right, world, e);
    }

    return section;
}

test "actions grid uses one compact column and two fluid wide columns" {
    try std.testing.expectEqual(@as(u8, 1), gridColumns(true));
    try std.testing.expectEqual(@as(u8, 2), gridColumns(false));
    try std.testing.expectEqual(@as(f32, 81), tile_content_height);
}
