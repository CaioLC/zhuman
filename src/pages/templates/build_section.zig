//! `build_section` — the complete Act I BUILD surface: heading/count, catalog controls,
//! live summary, aligned recipe table, and Shelter milestone. Domain filtering, sorting, and
//! build lifecycle remain in `build_list`; this template owns the section-level composition.

const std = @import("std");
const ha = @import("ha");
const World = ha.world.World;
const Entity = ha.world.Entity;
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;

const build_list_mod = @import("./build_list.zig");
const row_mod = @import("./capital_row.zig");

pub fn build_section(ctx: *UiCtx, parent: El, world: *World, e: Entity, id: []const u8) !El {
    const th = ctx.res.view.theme;
    const width = row_mod.tableWidth(ctx);

    const section = try el.div(ctx, parent, id);
    _ = section.with_size(.{ .fixed = width }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start }).with_gap(7);

    const heading = try el.div(ctx, section, "heading");
    _ = heading.with_size(.{ .fixed = width }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .baseline }).with_gap(12);
    const copy = try el.div(ctx, heading, "copy");
    _ = copy.with_flow(.{ .dir = .column, .cross = .start });
    _ = (try el.text(ctx, copy, "title", "BUILD"))
        .with_style(.{ style.h3, Style{ .text = th.fg } });
    _ = (try el.text(ctx, copy, "subtitle", "Find the next useful recipe your own hands can raise."))
        .with_style(.{Style{ .font = 11, .text = th.dim }});

    var count_buf: [24]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d} RECIPES", .{build_list_mod.authored_total}) catch "RECIPES";
    _ = (try el.text(ctx, heading, "count", count))
        .with_style(.{ style.eyebrow, Style{ .text = th.dim } });

    _ = try build_list_mod.build_list(ctx, section, world, e, "buildlist");
    return section;
}
