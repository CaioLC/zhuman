//! `browser` — the chrome a **catalog browser** shares above its `catalog_controls` bar and
//! around its results: the heading (an h3 title with an 11px subtitle under it and an eyebrow
//! on the right, on one baseline: a count, or an eyebrow the caller builds) and the responsive
//! tile lanes (two growing columns side by side, or one column at the compact breakpoint). Act
//! II's action browser composes these over `action_tile`s.

const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const El = el.El;

/// A heading built by `browser_heading_bare`: the whole heading, and its top row, where the
/// caller places its eyebrow after the title.
pub const Heading = struct { el: El, top: El };

/// The heading over a browser with no eyebrow: `title` on a top row that fills the parent's
/// width and lays its children on one baseline, `space_between` (the prototype's
/// `.surface-heading`), and `subtitle` under it. The caller builds its eyebrow into `top`, so
/// the eyebrow sits at the parent's right edge on the title's baseline.
pub fn browser_heading_bare(parent: El, id: []const u8, title: []const u8, subtitle: []const u8) !Heading {
    const heading = try parent.box(id, .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
    }, .{});
    const top = try heading.box("top", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children,
        .flow = .{ .dir = .row, .main = .space_between, .cross = .baseline }, .gap = 12,
    }, .{});
    try top.label("title", title, .{ style.h3, style.ink(.fg) });
    try heading.label("subtitle", subtitle, .{style.note});
    return .{ .el = heading, .top = top };
}

/// The heading over a browser: `title` with `count` as an eyebrow on its right, sharing the
/// title's baseline, and `subtitle` under both (`browser_heading_bare` with a muted eyebrow).
pub fn browser_heading(parent: El, id: []const u8, title: []const u8, subtitle: []const u8, count: []const u8) !El {
    const h = try browser_heading_bare(parent, id, title, subtitle);
    try h.top.label("count", count, .{ style.eyebrow, style.muted });
    return h.el;
}

/// The grid a collection of tiles flows into and the two lanes inside it. When `compact`,
/// both lanes are the grid itself, so a caller alternating tiles between `lanes[0]` and
/// `lanes[1]` lays them in one column without a branch.
pub const Lanes = struct { grid: El, lanes: [2]El };

/// Two growing columns `gap` apart, or one column at the compact breakpoint. The grid fills
/// the parent's width; `gap` also spaces the tiles within a lane.
pub fn tile_lanes(parent: El, id: []const u8, compact: bool, gap: f32) !Lanes {
    const grid = try parent.box(id, .{ .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children }, .{});
    if (compact) {
        grid.set(.{ .flow = .{ .dir = .column, .cross = .start }, .gap = gap }, .{});
        return .{ .grid = grid, .lanes = .{ grid, grid } };
    }
    grid.set(.{ .flow = .{ .dir = .row, .cross = .start }, .gap = gap }, .{});
    const left = try grid.box("left", .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start }, .gap = gap }, .{});
    const right = try grid.box("right", .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start }, .gap = gap }, .{});
    return .{ .grid = grid, .lanes = .{ left, right } };
}
