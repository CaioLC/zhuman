//! `scroll_view` — the one scroll component: a clipped viewport over a column the caller
//! appends rows to, with a wheel-scrolled, thumb-dragged offset persisted in `ScrollState`.
//! The viewport is either a fixed `height` high or, at 0, as high as its parent, whose height
//! must then be definite; and either a fixed `width` wide or, at 0, as wide as its parent.
//!
//! The clamp needs the content height, but this frame's rows are not laid out yet, so the
//! content box reads its own prior-frame rect — a pass-through geometry probe, `track`ed so
//! its rect is stamped for next frame. A parent-high viewport reads its own height the same
//! way. One frame stale, invisible at 60fps. Every quantity is
//! in device px: the stamped rect is device px, so the authored heights are scaled once here.
//! The thumb captures primary input and keeps dragging outside its narrow track,
//! with grab/grabbing cursors. This component is an approved reader of prior-frame geometry.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const ScrollState = uic.UiState.ScrollState;

/// Wheel delta → logical px scrolled per tick.
const scroll_speed: f32 = 24.0;
/// The smallest thumb, logical px.
const min_thumb: f32 = 16.0;
/// Scrollbar track/thumb width, logical px. Pub so a caller sizing "viewport + track" to a
/// total width (`log_view`'s footer) can reserve the gutter.
pub const scrollbar_w: f32 = 6.0;
/// Vertical gap between the content column's rows, logical px. Pub so a caller sizing the
/// viewport in rows (`log_view`'s N-lines height) counts the gaps it gets.
pub const content_gap: f32 = 4.0;

pub const Options = struct {
    /// Viewport width in logical px; `0` fills the parent's width.
    width: f32 = 0,
    /// Viewport height in logical px; `0` fills the parent's height.
    height: f32,
    /// Draw the viewport's hairline frame. A catalog region inside a surface goes without.
    framed: bool = true,
    /// Vertical gap between content rows, logical px. A dense feed (the footer log) uses 0.
    gap: f32 = content_gap,
};

pub const ScrollView = struct {
    /// The viewport and track side by side.
    outer: El,
    /// The clipped viewport.
    viewport: El,
    /// The column the caller appends rows into.
    content: El,
};

/// Build the view. `state` is the scroll state when the caller owns it (an always-built
/// owner's slot keeps the offset while the view is hidden); null means the view keeps its own.
pub fn scroll_view(parent: El, id: []const u8, opts: Options, state: ?*ScrollState) !ScrollView {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const scale = ctx.res.view.scale;

    const fill = opts.width <= 0;
    const fill_h = opts.height <= 0;
    const outer = try parent.div(id);
    // Top-aligned: the default baseline cross-alignment would place the viewport by its
    // content's first baseline and shift it against the track.
    _ = outer.with_flow(.{ .dir = .row, .cross = .start });
    _ = outer.with_size(
        if (fill) .{ .pct_of_parent = 1.0 } else .fit_children,
        if (fill_h) .{ .pct_of_parent = 1.0 } else if (fill) .{ .fixed = opts.height } else .fit_children,
    );

    const viewport = try outer.div("viewport");
    // Top-anchored column: the default row/baseline flow would align an overflowing content
    // column by its baseline and start it part-way scrolled.
    _ = viewport.with_overflow(.clip).with_flow(.{ .dir = .column, .cross = .start });
    if (opts.framed) _ = viewport.with_style(.{Style{ .outline_color = th.line2 }});
    _ = viewport.with_size(
        if (fill) .grow else .{ .fixed = opts.width },
        if (fill or fill_h) .{ .pct_of_parent = 1.0 } else .{ .fixed = opts.height },
    );

    const content = try viewport.div("content");
    _ = content.with_flow(.{ .dir = .column }).with_gap(opts.gap);
    if (fill) _ = content.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
    // The probe covers the viewport, so it must not take the hit; tracked so its rect resolves.
    const content_h = if (content.get().rect(ctx)) |r| r.h else 0;
    _ = content.pass_through().track();

    const st = state orelse outer.state(ScrollState);

    // A parent-high viewport knows its height only from the prior frame; until then it does
    // not scroll.
    const view_h = if (fill_h)
        (if (viewport.get().rect(ctx)) |r| r.h else 0)
    else
        uic.view.dp(opts.height, scale);
    const max_offset = if (view_h <= 0) 0 else @max(0.0, content_h - view_h);
    if (viewport.query().wheel and ctx.res.input.pointer.wheel.y != 0) {
        st.offset -= ctx.res.input.pointer.wheel.y * uic.view.dp(scroll_speed, scale); // wheel up ⇒ toward the top
    }
    st.offset = std.math.clamp(st.offset, 0, max_offset);

    if (max_offset > 0) {
        const gutter = uic.view.dp(scrollbar_w, scale);
        const track = try outer.div("track");
        _ = track.with_flow(.{ .dir = .column })
            .with_size_px(.{ .fixed = gutter }, .{ .fixed = view_h })
            .with_style(.{Style{ .fill = th.line }});

        const thumb_h = @min(view_h, @max(uic.view.dp(min_thumb, scale), view_h * view_h / content_h));
        const thumb_travel = view_h - thumb_h;
        const thumb_y = (st.offset / max_offset) * thumb_travel;

        const above = try track.div("above");
        _ = above.with_size_px(.{ .fixed = gutter }, .{ .fixed = thumb_y });
        const thumb = try track.div("thumb");
        _ = thumb.with_size_px(.{ .fixed = gutter }, .{ .fixed = thumb_h });
        const thumb_q = thumb.query();
        uic.updateScrollThumb(ctx, st, thumb.get().key, thumb_q.pressed, max_offset, thumb_travel);
        if (st.dragging) {
            ctx.res.cursor.request(.grabbing);
        } else if (thumb_q.hovering) {
            ctx.res.cursor.request(.grab);
        }
        _ = thumb.with_style(.{Style{ .fill = if (st.dragging) th.acc else th.line2 }});
    } else if (st.dragging) {
        uic.cancelScrollThumb(ctx, st);
    }

    content.get().layout.scroll_y = st.offset; // translate the content's children, no second pass
    return .{ .outer = outer, .viewport = viewport, .content = content };
}
