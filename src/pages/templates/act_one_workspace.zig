//! `act_one_workspace` — the complete Act I page-grid composition: a persistent, collapsible
//! HOLDINGS rail beside the reusable tabbed action/build surface. The rail owns its collapse
//! memory and width tween; this outer composition synchronizes the inter-column gap with the
//! same 120ms policy (22px expanded, 12px collapsed) and keeps one surface alive across both.

const std = @import("std");
const ha = @import("ha");
const World = ha.world.World;
const Entity = ha.world.Entity;

const uic = ha.ui_client;
const el = uic.elements;
const UiCtx = uic.UiCtx;
const El = el.El;

const rail_mod = @import("./rail.zig");
const holdings_mod = @import("./holdings.zig");
const surface_mod = @import("./act_one_surface.zig");

const expanded_gap: f32 = 22;
const collapsed_gap: f32 = 12;

pub const Options = surface_mod.Options;

pub const Result = struct {
    el: El,
    rail: rail_mod.Rail,
    surface: surface_mod.Result,
};

fn targetGap(collapsed: bool) f32 {
    return if (collapsed) collapsed_gap else expanded_gap;
}

/// Compose the left HOLDINGS rail and right tabbed content as one responsive workspace.
pub fn act_one_workspace(ctx: *UiCtx, parent: El, world: *World, e: Entity, id: []const u8, opts: Options) !Result {
    const workspace = try el.div(ctx, parent, id);
    _ = workspace.with_size(.{ .pct_of_parent = 1.0 }, .{ .pct_of_parent = 1.0 })
        .with_flow(.{ .dir = .row, .cross = .start })
        .with_overflow(.clip);

    const rail_lane = try el.div(ctx, workspace, "rail");
    _ = rail_lane.with_size(.fit_children, .{ .pct_of_parent = 1.0 });
    const built_rail = try rail_mod.rail(ctx, rail_lane, .{
        .id = "holdings_rail",
        .label = "HOLDINGS",
    });
    if (built_rail.body) |body| {
        _ = try holdings_mod.holdings(ctx, body, world, e, "holdings");
    }

    // The width and gap move together, matching `.page-grid.is-holdings-collapsed` rather than
    // letting the content jump after the rail's 120ms width transition.
    const gap_target = targetGap(built_rail.collapsed);
    ctx.res.tween.retarget(workspace.get().key, gap_target, ha.tokens.dur_rail_s);
    _ = workspace.with_gap(ctx.res.tween.value(workspace.get().key, gap_target));

    const content = try el.div(ctx, workspace, "content");
    _ = content.with_size(.grow, .{ .pct_of_parent = 1.0 })
        .with_overflow(.clip);
    const surface = try surface_mod.act_one_surface(ctx, content, world, e, "surface", opts);

    return .{ .el = workspace, .rail = built_rail, .surface = surface };
}

test "workspace column gaps mirror expanded and collapsed prototype states" {
    try std.testing.expectEqual(@as(f32, 22), targetGap(false));
    try std.testing.expectEqual(@as(f32, 12), targetGap(true));
}
