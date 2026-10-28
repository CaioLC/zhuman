//! `act_one_workspace` — the complete Act I page-grid composition: the collapsible Household
//! rail (HOLDINGS, BODY and the eating policy) beside the tabbed ACTIONS/BUILD/GENERATORS
//! surface. Each view keys its own rail, so each remembers its collapse; the rail owns its
//! width tween, and this outer composition synchronizes the inter-column gap with the same
//! 120ms policy (22px expanded, 12px collapsed) and keeps one surface alive across all three.

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
const household_mod = @import("./household.zig");
const surface_mod = @import("./act_one_surface.zig");

const expanded_gap: f32 = 22;
const collapsed_gap: f32 = 12;

/// The work surface's options, plus the rail's content (each act projects its own).
pub const Options = struct {
    surface: surface_mod.Options,
    holdings: holdings_mod.Content,
    /// Collapse (or expand) the rail on this frame only — a fixture's first frame.
    initial_collapsed: ?bool = null,
};

pub const Result = struct {
    el: El,
    rail: rail_mod.Rail,
    surface: surface_mod.Result,
};

fn targetGap(collapsed: bool) f32 {
    return if (collapsed) collapsed_gap else expanded_gap;
}

/// Compose the left HOLDINGS rail and right tabbed content as one responsive workspace.
pub fn act_one_workspace(parent: El, world: *World, e: Entity, id: []const u8, opts: Options) !Result {
    const ctx = parent.ctx;
    const workspace = try parent.div(id);
    _ = workspace.with_size(.{ .pct_of_parent = 1.0 }, .{ .pct_of_parent = 1.0 })
        .with_flow(.{ .dir = .row, .cross = .start })
        .with_overflow(.clip);

    // The rail lane comes first in the row, but its rail is built after the surface: each view
    // keys its own rail, so ACTIONS, BUILD and GENERATORS remember their collapse separately,
    // and the active view is known only once the surface's tabs are built.
    const rail_lane = try workspace.div("rail");
    _ = rail_lane.with_size(.fit_children, .{ .pct_of_parent = 1.0 });

    const content = try workspace.div("content");
    _ = content.with_size(.grow, .{ .pct_of_parent = 1.0 })
        .with_overflow(.clip);
    const surface = try surface_mod.act_one_surface(content, world, e, "surface", opts.surface);

    const rail_ids = [_][]const u8{ "rail_actions", "rail_build", "rail_generators" };
    const built_rail = try rail_mod.rail(rail_lane, .{
        .id = rail_ids[@min(surface.active, rail_ids.len - 1)],
        .label = "HOUSEHOLD",
        .initial_collapsed = opts.initial_collapsed,
    });
    if (built_rail.body) |body| {
        _ = try household_mod.household(body, world, e, "holdings", opts.holdings);
    }

    // The width and gap move together, matching `.page-grid.is-holdings-collapsed` rather than
    // letting the content jump after the rail's 120ms width transition.
    const gap_target = targetGap(built_rail.collapsed);
    ctx.res.tween.retarget(workspace.get().key, gap_target, ha.tokens.dur_rail_s);
    _ = workspace.with_gap(ctx.res.tween.value(workspace.get().key, gap_target));

    return .{ .el = workspace, .rail = built_rail, .surface = surface };
}

test "workspace column gaps mirror expanded and collapsed prototype states" {
    try std.testing.expectEqual(@as(f32, 22), targetGap(false));
    try std.testing.expectEqual(@as(f32, 12), targetGap(true));
}
