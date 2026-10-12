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

/// Build the section. `catalog` and `search_owner` pass through to `build_list`: the catalog
/// state and the node holding the search editor when an always-built owner keeps them.
pub fn build_section(parent: El, world: *World, e: Entity, id: []const u8, catalog: ?*uic.UiState.CatalogState, search_owner: ?El) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const width = row_mod.tableWidth(ctx);

    const section = try parent.div(id);
    _ = section.with_size(.{ .fixed = width }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start }).with_gap(7);

    const heading = try section.div("heading");
    _ = heading.with_size(.{ .fixed = width }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .baseline }).with_gap(12);
    const copy = try heading.div("copy");
    _ = copy.with_flow(.{ .dir = .column, .cross = .start });
    _ = (try copy.text("title", "BUILD"))
        .with_style(.{ style.h3, Style{ .text = th.fg } });
    _ = (try copy.text("subtitle", "Find the next useful recipe your own hands can raise."))
        .with_style(.{Style{ .font = 11, .text = th.dim }});

    var count_buf: [24]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d} RECIPES", .{build_list_mod.authoredTotal(&ctx.res.catalog)}) catch "RECIPES";
    _ = (try heading.text("count", count))
        .with_style(.{ style.eyebrow, Style{ .text = th.dim } });

    _ = try build_list_mod.build_list(section, world, e, "buildlist", catalog, search_owner);
    return section;
}
