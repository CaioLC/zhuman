//! `browser` — the chrome a **catalog browser** shares above its `catalog_controls` bar and
//! around its results: the heading (an h3 title with an 11px subtitle under it and an eyebrow
//! count on the right, on one baseline) and the responsive tile lanes (two growing columns
//! side by side, or one column at the compact breakpoint). Act II's action browser composes
//! these over `action_tile`s.

const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;

/// The heading over a browser: `title` with `count` as an eyebrow on its right, sharing the
/// title's baseline (the prototype's `.surface-heading`), and `subtitle` under both. The
/// heading fills its parent's width, so the count sits at the parent's right edge.
pub fn browser_heading(parent: El, id: []const u8, title: []const u8, subtitle: []const u8, count: []const u8) !El {
    const th = parent.ctx.res.view.theme;
    const heading = try parent.div(id);
    _ = heading.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start });
    const top = try heading.div("top");
    _ = top.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .baseline }).with_gap(12);
    _ = (try top.text("title", title)).with_style(.{ style.h3, Style{ .text = th.fg } });
    _ = (try top.text("count", count)).with_style(.{ style.eyebrow, Style{ .text = th.dim } });
    _ = (try heading.text("subtitle", subtitle)).with_style(.{Style{ .font = 11, .text = th.dim }});
    return heading;
}

/// The grid a collection of tiles flows into and the two lanes inside it. When `compact`,
/// both lanes are the grid itself, so a caller alternating tiles between `lanes[0]` and
/// `lanes[1]` lays them in one column without a branch.
pub const Lanes = struct { grid: El, lanes: [2]El };

/// Two growing columns `gap` apart, or one column at the compact breakpoint. The grid fills
/// the parent's width; `gap` also spaces the tiles within a lane.
pub fn tile_lanes(parent: El, id: []const u8, compact: bool, gap: f32) !Lanes {
    const grid = try parent.div(id);
    _ = grid.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
    if (compact) {
        _ = grid.with_flow(.{ .dir = .column, .cross = .start }).with_gap(gap);
        return .{ .grid = grid, .lanes = .{ grid, grid } };
    }
    _ = grid.with_flow(.{ .dir = .row, .cross = .start }).with_gap(gap);
    const left = try grid.div("left");
    _ = left.with_size(.grow, .fit_children).with_flow(.{ .dir = .column, .cross = .start }).with_gap(gap);
    const right = try grid.div("right");
    _ = right.with_size(.grow, .fit_children).with_flow(.{ .dir = .column, .cross = .start }).with_gap(gap);
    return .{ .grid = grid, .lanes = .{ left, right } };
}
