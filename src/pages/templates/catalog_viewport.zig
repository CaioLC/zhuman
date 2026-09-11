//! `catalog_viewport` (KIT-16) — the one scroll region a catalog's **results** live in, so the
//! surrounding chrome (the KIT-15 controls, the EatingPolicy/milestone, the footer log) stays
//! **fixed** while only the rows scroll. At desktop widths it is a fixed-height clipped
//! viewport with an `8px` logical scrollbar **gutter** (the prototype's inset thumb); at `≤760`
//! it collapses to *no nested scroll* — the rows flow into the one shell/page scroll region
//! instead (a nested scroll inside a page scroll is the mobile anti-pattern the prototype
//! avoids). It **persists and clamps** wheel + draggable-thumb state by key (`ScrollState`),
//! and **resets to the top** when the caller signals a data change (the KIT-15 `changed` flag),
//! so a new query/sort starts at row one.
//!
//! Placement contract: the caller builds the *fixed* chrome as siblings **outside** the
//! returned content box (that is how BUILD's heading stays visually fixed — it lives outside
//! the moving result content, no generic sticky positioning needed), and appends the scrolling
//! rows **into** `content`. Opening an inline detail (Exchange) adds height to `content`, which
//! the viewport clips/scrolls — so it consumes result-viewport height rather than growing the
//! terminal's total height.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const drag = uic.drag;

/// The prototype's result scrollbar gutter, logical px (KIT-16). Wider than the generic
/// `scroll_view`'s 6px track — the catalog reserves a roomier inset gutter.
pub const gutter: f32 = 8;
/// Wheel px per tick and the minimum thumb height (logical), mirroring the generic scroll view.
const scroll_speed: f32 = 24;
const min_thumb: f32 = 16;

/// The built viewport: `content` is the box the caller appends scrolling rows into (a
/// `fit_children` column), and `scrolled` says whether a nested scroll region was created
/// (false at ≤760, where rows flow into the page scroll region instead).
pub const Viewport = struct {
    content: El,
    scrolled: bool,
};

/// Build a results viewport into `parent`. `height` is the desktop viewport height (logical
/// px); `reset` (the KIT-15 `changed` flag) snaps the offset to the top this frame. At `≤760`
/// no nested scroll is created — `parent` is returned as the content box (one page scroll).
pub fn catalog_viewport(ctx: *UiCtx, parent: El, id: []const u8, height: f32, reset: bool) !Viewport {
    const th = ctx.res.view.theme;
    const scale = ctx.res.view.scale;

    // ≤760: no nested result scroll — rows flow into the shell/page scroll region (KIT-16).
    if (ctx.res.view.metrics.width_class.atMost(.w760)) {
        const flow = try el.div(ctx, parent, id);
        _ = flow.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
            .with_flow(.{ .dir = .column }).with_gap(ha.tokens.gap.tight);
        return .{ .content = flow, .scrolled = false };
    }

    // Desktop: a fixed-height clipped viewport beside an 8px gutter track.
    const outer = try el.div(ctx, parent, id);
    _ = outer.with_flow(.{ .dir = .row }).with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = height });

    const viewport = try el.div(ctx, outer, "viewport");
    _ = viewport.with_size(.grow, .{ .pct_of_parent = 1.0 }).with_overflow(.clip);

    const content = try el.div(ctx, viewport, "content");
    _ = content.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(ha.tokens.gap.tight);
    // Read last frame's content height for clamping (prior-frame rect, the scroll_view pattern).
    const content_h = if (content.get().rect(ctx)) |r| r.h else 0;
    ctx.setPassThrough(content.get().key, true); // geometry probe only — never the hit
    _ = content.query(); // keep the slot alive so `content.rect` resolves next frame

    const state = outer.get().state(ctx, uic.UiState.ScrollState);
    if (reset) state.offset = 0; // KIT-16: reset-to-top on a requested data change.

    // height is logical; the stamped content height is device px — clamp in device px.
    const view_h_dev = uic.view.dp(height, scale);
    const max_offset = @max(0, content_h - view_h_dev);
    if (viewport.query().wheel and ctx.res.input.pointer.wheel.y != 0) {
        state.offset -= ctx.res.input.pointer.wheel.y * uic.view.dp(scroll_speed, scale);
    }
    state.offset = std.math.clamp(state.offset, 0, max_offset);

    // The 8px gutter with an inset thumb, only while the results overflow.
    if (max_offset > 0) {
        const track = try el.div(ctx, outer, "track");
        _ = track.with_size(.{ .fixed = uic.view.dp(gutter, scale) }, .{ .pct_of_parent = 1.0 })
            .with_flow(.{ .dir = .column })
            .with_style(.{Style{ .fill = th.line }});

        const thumb_h = @min(view_h_dev, @max(uic.view.dp(min_thumb, scale), view_h_dev * view_h_dev / content_h));
        const thumb_travel = view_h_dev - thumb_h;

        const spacer = try el.div(ctx, track, "above");
        const thumb_y = (state.offset / max_offset) * thumb_travel;
        _ = spacer.with_size_px(.{ .fixed = uic.view.dp(gutter, scale) }, .{ .fixed = thumb_y });

        const thumb = try el.div(ctx, track, "thumb");
        // Inset thumb: slightly narrower than the gutter, so it reads as sitting *in* the track.
        _ = thumb.with_size_px(.{ .fixed = uic.view.dp(gutter - 2, scale) }, .{ .fixed = thumb_h })
            .with_style(.{Style{ .fill = th.line2 }});
        const tq = thumb.query();
        drag.updateScrollThumb(ctx, state, thumb.get().key, tq.pressed, max_offset, thumb_travel);
        if (state.dragging) ctx.res.cursor.request(.grabbing) else if (tq.hovering) ctx.res.cursor.request(.grab);
    } else if (state.dragging) {
        drag.cancelScrollThumb(ctx, state);
    }

    content.get().layout.scroll_y = state.offset;
    return .{ .content = content, .scrolled = true };
}
