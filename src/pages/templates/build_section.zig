//! `build_section` — the complete BUILD pane, the same on every act: heading/count, the search
//! field, live summary, sortable recipe table, and the act's milestone. Only the content
//! differs per act (`build_list.Shelf`). Domain filtering, sorting, and build lifecycle remain
//! in `build_list`; this template owns the section-level composition.

const std = @import("std");
const ha = @import("ha");
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;
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
///
/// It spans its parent's width, which must be definite too, held to the table's bounds
/// (`capital_row.Extent`) plus the scroll gutter: framed that is the 594px lane; stacked, the
/// page's surface. Everything inside takes its width from the section, and the engine solves
/// the tracks against the rows' own width.
pub fn build_section(parent: El, world: *World, e: Entity, id: []const u8, shelf: build_list_mod.Shelf, catalog: ?*uic.UiState.CatalogState, search_owner: ?El, scroll: ?*uic.UiState.ScrollState) !El {
    const ctx = parent.ctx;
    // The table's tracks at this width class; the list below lays out by them.
    const set = try row_mod.tableTracks(ctx, shelf.widths);
    const ext = row_mod.tableExtent(ctx, shelf.widths);
    const gutter = row_mod.scroll_gutter;

    const section = try parent.div(id);
    // The table plus its reserved scroll gutter, so the track never covers a lane. A wider
    // parent leaves its slack outside the section; a narrower one than the lanes' floors is
    // overflowed.
    section.set(.{
        .w = .{ .pct_of_parent = 1.0 }, .h = @import("./terminal.zig").fill_h(ctx),
        .min = .{ .w = ext.min + gutter }, .max = .{ .w = ext.max + gutter },
        .flow = .{ .dir = .column, .cross = .start }, .gap = 7,
    }, .{});

    var count_buf: [24]u8 = undefined;
    const count = std.mem.print(&count_buf, "{d} RECIPES", .{build_list_mod.shelfTotal(world, e, &ctx.res.game.catalog, shelf)}) catch "RECIPES";
    const heading_box = try section.div("heading_box");
    // Over the table: the count ends where the lanes do.
    heading_box.set(.{ .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .pct_less = .{ .w = gutter } }, .{});
    _ = try browser_mod.browser_heading(heading_box, "heading", "BUILD", shelf.subtitle, count);

    _ = try build_list_mod.build_list(section, world, e, "buildlist", shelf, set, catalog, search_owner, scroll);
    return section;
}
