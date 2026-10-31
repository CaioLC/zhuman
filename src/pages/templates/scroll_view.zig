//! `scroll_view` — the one scroll component: a clipped viewport over a column the caller
//! appends rows to, with a wheel-scrolled, thumb-dragged offset persisted in `ScrollState`.
//! The viewport is either a fixed `height` high or, at 0, as high as its parent, whose height
//! must then be definite; and either a fixed `width` wide or, at 0, as wide as its parent
//! (less a reserved `gutter`). A parent-wide view's content column spans the viewport, so its
//! width is definite: a row inside can be `pct_of_parent = 1.0` of it.
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
    /// A parent-wide view (`width = 0`) only: room kept right of the viewport whether or not
    /// the track shows, logical px, at least `scrollbar_w`. The track takes its first
    /// `scrollbar_w` when it appears and the rest stays outside the view, so the viewport (and
    /// every row in it) keeps one width as the content starts or stops overflowing (CSS
    /// `scrollbar-gutter: stable`). 0, the default: the track takes its room from the viewport.
    gutter: f32 = 0,
    /// Viewport height in logical px; `0` fills the parent's height.
    height: f32,
    /// Draw the viewport's hairline frame. A catalog region inside a surface goes without.
    framed: bool = true,
    /// Vertical gap between content rows, logical px. A dense feed (the footer log) uses 0.
    gap: f32 = content_gap,
    /// The accessible name of the viewport while it is a focus stop (it overflows).
    name: []const u8 = "scroll region",
};

pub const ScrollView = struct {
    /// The viewport and track side by side.
    outer: El,
    /// The clipped viewport.
    viewport: El,
    /// The column the caller appends rows into.
    content: El,
};

/// Whether the pointer is over another wheel owner nested inside the viewport `vkey` (an
/// inner scroll view, the research board): that one takes the wheel, not this view.
fn innerWheel(ctx: *UiCtx, vkey: u64) bool {
    const p = ctx.res.input.pointer.position;
    for (ctx.res.commands.wheelOwners()) |o| {
        if (o == vkey or !ctx.isStampedDescendant(o, vkey)) continue;
        if (ctx.rectOf(o)) |r| if (r.contains(p.x, p.y)) return true;
    }
    return false;
}

/// Build the view. `state` is the scroll state when the caller owns it (an always-built
/// owner's slot keeps the offset while the view is hidden); null means the view keeps its own.
pub fn scroll_view(parent: El, id: []const u8, opts: Options, state: ?*ScrollState) !ScrollView {
    const ctx = parent.ctx;
    const scale = ctx.res.view.scale;

    const fill = opts.width <= 0;
    const fill_h = opts.height <= 0;
    std.debug.assert(opts.gutter == 0 or (fill and opts.gutter >= scrollbar_w));
    // Stacked (≤760) the whole page is the scroll view: a parent-high view has no height to
    // fill, so it takes its content's and lets the page scroll it.
    if (fill_h and @import("./terminal.zig").stacked(ctx)) {
        const outer = try parent.box(id, .{
            .flow = .{ .dir = .row, .cross = .start },
            .w = if (fill) .{ .pct_of_parent = 1.0 } else .fit_children, .h = .fit_children,
            .pct_less = .{ .w = opts.gutter },
        }, .{});
        // no track here: the whole gutter is kept
        const viewport = try outer.box("viewport", .{
            .flow = .{ .dir = .column, .cross = .start }, .w = if (fill) .grow else .{ .fixed = opts.width },
            .h = .fit_children,
        }, .{});
        if (opts.framed) _ = viewport.with_style(.{Style{ .outline_ink = .line2 }});
        const content = try viewport.box("content", .{ .flow = .{ .dir = .column }, .gap = opts.gap }, .{});
        if (fill) _ = content.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
        const st = state orelse outer.state(ScrollState);
        if (st.dragging) uic.cancelScrollThumb(ctx, st);
        return .{ .outer = outer, .viewport = viewport, .content = content };
    }
    const outer = try parent.div(id);
    // Top-aligned: the default baseline cross-alignment would place the viewport by its
    // content's first baseline and shift it against the track.
    outer.set(.{ .flow = .{ .dir = .row, .cross = .start } }, .{});
    outer.set(.{
        .w = if (fill) .{ .pct_of_parent = 1.0 } else .fit_children,
        .h = if (fill_h) .{ .pct_of_parent = 1.0 } else if (fill) .{ .fixed = opts.height } else .fit_children,
    }, .{});

    const viewport = try outer.div("viewport");
    // Top-anchored column: the default row/baseline flow would align an overflowing content
    // column by its baseline and start it part-way scrolled.
    viewport.set(.{ .overflow = .clip, .flow = .{ .dir = .column, .cross = .start } }, .{});
    if (opts.framed) _ = viewport.with_style(.{Style{ .outline_ink = .line2 }});
    viewport.set(.{
        .w = if (fill) .grow else .{ .fixed = opts.width },
        .h = if (fill or fill_h) .{ .pct_of_parent = 1.0 } else .{ .fixed = opts.height },
    }, .{});

    const content = try viewport.box("content", .{ .flow = .{ .dir = .column }, .gap = opts.gap }, .{});
    if (fill) _ = content.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
    // The probe covers the viewport, so it must not take the hit; tracked so its rect resolves.
    const content_h = if (content.get().rect(ctx)) |r| r.h else 0;
    content.probe();

    const st = state orelse outer.state(ScrollState);

    // A parent-high viewport knows its height only from the prior frame; until then it does
    // not scroll.
    const view_h = if (fill_h)
        (if (viewport.get().rect(ctx)) |r| r.h else 0)
    else
        uic.view.dp(opts.height, scale);
    const max_offset = if (view_h <= 0) 0 else @max(0.0, content_h - view_h);
    const vkey = viewport.get().key;
    if (viewport.query().wheel and ctx.res.input.pointer.wheel.y != 0 and !innerWheel(ctx, vkey)) {
        st.offset -= ctx.res.input.pointer.wheel.y * uic.view.dp(scroll_speed, scale); // wheel up ⇒ toward the top
    }
    // Keyboard: an overflowing viewport is a focus stop and the scroll owner of the controls
    // inside it. Up/Down move a line, Page Up/Down a viewport less a line, Home/End the ends.
    if (max_offset > 0) {
        ctx.res.commands.registerScroll(vkey);
        ctx.res.commands.registerWheel(vkey);
        const vq = viewport.control(.{ .name = opts.name, .role = .group, .cursor = .default });
        const line = uic.view.dp(scroll_speed, scale);
        if (vq.scroll_up) st.offset -= line;
        if (vq.scroll_down) st.offset += line;
        if (vq.scroll_page_up) st.offset -= @max(line, view_h - line);
        if (vq.scroll_page_down) st.offset += @max(line, view_h - line);
        if (vq.scroll_top) st.offset = 0;
        if (vq.scroll_bottom) st.offset = max_offset;
        if (vq.focus_visible and opts.framed) _ = viewport.with_style(.{Style{ .outline_ink = .acc }});
        // A newly focused control inside the view is scrolled into it, once.
        if (ctx.focusedKey()) |fk| {
            if (fk != vkey and st.revealed != fk and ctx.isStampedDescendant(fk, vkey)) {
                if (ctx.rectOf(fk)) |fr| if (viewport.get().rect(ctx)) |vr| {
                    if (fr.y < vr.y) st.offset -= vr.y - fr.y else if (fr.y + fr.h > vr.y + vr.h) st.offset += @min(fr.y + fr.h - (vr.y + vr.h), fr.y - vr.y);
                };
            }
            st.revealed = fk;
        } else st.revealed = null;
    }
    st.offset = std.math.clamp(st.offset, 0, max_offset);

    // A reserved gutter lies outside the outer box, less the track's share once it shows.
    if (opts.gutter > 0) _ = outer.with_pct_less(if (max_offset > 0) opts.gutter - scrollbar_w else opts.gutter, null);

    if (max_offset > 0) {
        const gutter = uic.view.dp(scrollbar_w, scale);
        const track = try outer.div("track");
        _ = track.with_flow(.{ .dir = .column })
            .with_size_px(.{ .fixed = gutter }, .{ .fixed = view_h })
            .with_style(.{style.rule_fill});

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
        thumb.set(.{}, .{Style{ .fill_ink = if (st.dragging) .acc else .line2 }});
    } else if (st.dragging) {
        uic.cancelScrollThumb(ctx, st);
    }

    content.get().layout.scroll_y = st.offset; // translate the content's children, no second pass
    return .{ .outer = outer, .viewport = viewport, .content = content };
}
