//! `build_section` — the complete BUILD pane, the same on every act: heading/count, the search
//! field, live summary, sortable recipe table, and the act's milestone. Only the content
//! differs per act (`build_list.Shelf`). Domain filtering, sorting, and build lifecycle remain
//! in `build_list`; this template owns the section-level composition.

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
const browser_mod = @import("./browser.zig");

pub const Shelf = build_list_mod.Shelf;

/// Build the section. `catalog` and `search_owner` pass through to `build_list`: the catalog
/// state and the node holding the search editor when an always-built owner keeps them;
/// `scroll` likewise keeps the table's scroll offset across tab switches. `shelf` is the act's
/// content (its recipes, subtitle, milestone, lane widths).
///
/// The section fills its parent's height, which must be definite: the heading, search,
/// summary and column header stay put, and only the table's rows scroll — the milestone stays
/// pinned below them.
pub fn build_section(parent: El, world: *World, e: Entity, id: []const u8, shelf: build_list_mod.Shelf, catalog: ?*uic.UiState.CatalogState, search_owner: ?El, scroll: ?*uic.UiState.ScrollState) !El {
    const ctx = parent.ctx;
    const width = row_mod.tableWidth(ctx, shelf.widths);

    const section = try parent.div(id);
    // The table plus its reserved scroll gutter, so the track never covers a lane.
    _ = section.with_size(.{ .fixed = width + row_mod.scroll_gutter }, .{ .pct_of_parent = 1.0 })
        .with_flow(.{ .dir = .column, .cross = .start }).with_gap(7);

    var count_buf: [24]u8 = undefined;
    const count = std.mem.print(&count_buf, "{d} RECIPES", .{build_list_mod.shelfTotal(world, e, &ctx.res.catalog, shelf)}) catch "RECIPES";
    const heading_box = try section.div("heading_box");
    _ = heading_box.with_size(.{ .fixed = width }, .fit_children);
    _ = try browser_mod.browser_heading(heading_box, "heading", "BUILD", shelf.subtitle, count);

    _ = try build_list_mod.build_list(section, world, e, "buildlist", shelf, catalog, search_owner, scroll);
    return section;
}
