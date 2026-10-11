//! `scroll_view` — the one scroll component: a clipped viewport over a column the caller
//! appends rows to, with a wheel-scrolled, thumb-dragged offset persisted in `ScrollState`.
//! Its options cover the two shapes the product uses: a fixed `width`×`height` framed view
//! (the log history), and a full-width results region with an inset thumb in a wider gutter
//! that resets to the top on a data change and releases its nested scroll at narrow widths so
//! the rows flow into the one page scroll region (the catalog treatment, KIT-16).
//!
//! The clamp needs the content height, but this frame's rows are not laid out yet, so the
//! content box reads its own prior-frame rect — a pass-through geometry probe, `track`ed so
//! its rect is stamped for next frame. One frame stale, invisible at 60fps. Every quantity is
//! in device px: the stamped rect is device px, so the authored heights are scaled once here
//! (VIEW-02). The thumb captures primary input and keeps dragging outside its narrow track,
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
/// Default scrollbar track/thumb width, logical px. Pub so a caller sizing "viewport + track"
/// to a total width (`log_view`'s footer) can reserve the gutter.
pub const scrollbar_w: f32 = 6.0;
/// Default vertical gap between the content column's rows, logical px. Pub so a caller
/// sizing the viewport in rows (`log_view`'s N-lines height) counts the gaps it gets.
pub const content_gap: f32 = 4.0;

pub const Options = struct {
    /// Viewport width in logical px; `0` fills the parent's width.
    width: f32 = 0,
    /// Viewport height in logical px.
    height: f32,
    /// Scrollbar gutter width, logical px.
    gutter: f32 = scrollbar_w,
    /// Draw the thumb a pixel narrower on each side than the gutter, so it reads as sitting in
    /// the track (the catalog's wider gutter); false fills the gutter.
    inset_thumb: bool = false,
    /// A hairline frame around the viewport.
    outline: bool = true,
    /// Gap between the content column's rows, logical px.
    gap: f32 = content_gap,
    /// Snap the offset to the top this frame (a query or sort change).
    reset: bool = false,
    /// At `≤760` logical width build no nested scroll: the content flows into the page's one
    /// scroll region and `scrolled` is false.
    release_narrow: bool = false,
};

pub const ScrollView = struct {
    /// The viewport and track side by side; the plain flow column when released.
    outer: El,
    /// The clipped viewport; the outer box itself when released.
    viewport: El,
    /// The column the caller appends rows into.
    content: El,
    /// Whether a nested scroll region was built this frame.
    scrolled: bool,
};

/// Build the view. `state` is the scroll state when the caller owns it (an always-built
/// owner's slot keeps the offset while the view is hidden); null means the view keeps its own.
pub fn scroll_view(parent: El, id: []const u8, opts: Options, state: ?*ScrollState) !ScrollView {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const scale = ctx.res.view.scale;

    if (opts.release_narrow and ctx.res.view.metrics.width_class.atMost(.w760)) {
        const flow = try parent.div(id);
        _ = flow.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
            .with_flow(.{ .dir = .column }).with_gap(opts.gap);
        return .{ .outer = flow, .viewport = flow, .content = flow, .scrolled = false };
    }

    const fill = opts.width <= 0;
    const outer = try parent.div(id);
    _ = outer.with_flow(.{ .dir = .row });
    _ = if (fill)
        outer.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = opts.height })
    else
        outer.with_size(.fit_children, .fit_children);

    const viewport = try outer.div("viewport");
    _ = viewport.with_overflow(.clip);
    _ = if (fill)
        viewport.with_size(.grow, .{ .pct_of_parent = 1.0 })
    else
        viewport.with_size(.{ .fixed = opts.width }, .{ .fixed = opts.height });
    if (opts.outline) _ = viewport.with_style(.{Style{ .outline_color = th.line2 }});

    const content = try viewport.div("content");
    _ = content.with_flow(.{ .dir = .column }).with_gap(opts.gap);
    if (fill) _ = content.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
    // The probe covers the viewport, so it must not take the hit; tracked so its rect resolves.
    const content_h = if (content.get().rect(ctx)) |r| r.h else 0;
    _ = content.pass_through().track();

    const st = state orelse outer.state(ScrollState);
    if (opts.reset) st.offset = 0;

    const view_h = uic.view.dp(opts.height, scale);
    const max_offset = @max(0.0, content_h - view_h);
    if (viewport.query().wheel and ctx.res.input.pointer.wheel.y != 0) {
        st.offset -= ctx.res.input.pointer.wheel.y * uic.view.dp(scroll_speed, scale); // wheel up ⇒ toward the top
    }
    st.offset = std.math.clamp(st.offset, 0, max_offset);

    if (max_offset > 0) {
        const gutter = uic.view.dp(opts.gutter, scale);
        const track = try outer.div("track");
        _ = track.with_flow(.{ .dir = .column })
            .with_size_px(.{ .fixed = gutter }, .{ .fixed = view_h })
            .with_style(.{Style{ .fill = th.line }});

        const thumb_h = @min(view_h, @max(uic.view.dp(min_thumb, scale), view_h * view_h / content_h));
        const thumb_travel = view_h - thumb_h;
        const thumb_y = (st.offset / max_offset) * thumb_travel;
        const thumb_w = if (opts.inset_thumb) gutter - uic.view.dp(2, scale) else gutter;

        const above = try track.div("above");
        _ = above.with_size_px(.{ .fixed = gutter }, .{ .fixed = thumb_y });
        const thumb = try track.div("thumb");
        _ = thumb.with_size_px(.{ .fixed = thumb_w }, .{ .fixed = thumb_h });
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
    return .{ .outer = outer, .viewport = viewport, .content = content, .scrolled = true };
}
