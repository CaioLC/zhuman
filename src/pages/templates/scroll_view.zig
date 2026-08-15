//! `scroll_view` template — a fixed-size, clipped viewport over a `fit_children` content
//! column the caller appends rows to. Wheel-scrolls while hovered (offset persisted in a
//! `ScrollState` slot, folded into `content.layout.scroll_y`); a track + thumb ride beside
//! it once content overflows. Behavior-heavy: built from `El` for the structure, dropping to
//! `.get()` only for the state/geometry reads. Scroll math unchanged from the old widget.
//! Returns `El` handles (shelf convention) — callers append rows into `.content`.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const ScrollState = uic.UiState.ScrollState;

/// Wheel delta → px scrolled per tick.
const scroll_speed: f32 = 24.0;
/// Scrollbar track/thumb width, in px. Pub so a caller sizing "viewport + track" to a
/// total width (`log_view`'s full-width footer) can reserve the gutter.
pub const scrollbar_w: f32 = 6.0;
/// Vertical gap between the content column's rows, in px. Pub so a caller sizing the
/// viewport in *rows* (`log_view`'s N-lines height) counts the gaps it will actually get.
pub const content_gap: f32 = 4.0;

pub const ScrollView = struct {
    outer: El, // wraps the viewport + scrollbar track side by side
    viewport: El, // fixed width×height, clipped
    content: El, // fit_children column — the caller's rows attach here
};

pub fn scroll_view(ctx: *UiCtx, parent: El, id: []const u8, width: f32, height: f32) !ScrollView {
    const th = ctx.res.theme;

    const outer = try el.div(ctx, parent, id);
    _ = outer.with_flow(.{ .dir = .row }).with_size(.fit_children, .fit_children);

    const viewport = try el.div(ctx, outer, "viewport");
    _ = viewport.with_layout(.relative)
        .with_size(.{ .fixed = width }, .{ .fixed = height })
        .with_overflow(.clip)
        .with_style(.{Style{ .outline_color = th.line2 }}); // dim frame around the scroll area

    const content = try el.div(ctx, viewport, "content");
    _ = content.with_flow(.{ .dir = .column }).with_gap(content_gap);
    const content_node = content.get();
    // Clamp needs content height, but this frame's rows aren't laid out yet — read last
    // frame's rect (queried here to keep the slot alive).
    const content_h = if (content_node.rect(ctx)) |r| r.h else 0;
    _ = content.query();

    const max_offset = @max(0.0, content_h - height);
    const st = outer.get().state(ctx, ScrollState);
    if (viewport.query().hovering and ctx.res.input.wheel_y != 0) {
        st.offset -= ctx.res.input.wheel_y * scroll_speed; // wheel up ⇒ toward the top
    }
    st.offset = std.math.clamp(st.offset, 0, max_offset);
    content_node.layout.scroll_y = st.offset; // translate content's children, no second pass

    if (max_offset > 0) {
        const track = try el.div(ctx, outer, "track");
        _ = track.with_flow(.{ .dir = .column })
            .with_size(.{ .fixed = scrollbar_w }, .{ .fixed = height })
            .with_style(.{Style{ .fill = th.line }});

        // Thumb: two stacked fixed children (an invisible spacer, then the thumb) so ordinary
        // vertical flow positions it — no absolute offset needed.
        const thumb_h = @max(16.0, height * height / content_h);
        const thumb_y = (st.offset / max_offset) * (height - thumb_h);

        const spacer = try el.div(ctx, track, "above");
        _ = spacer.with_size(.{ .fixed = scrollbar_w }, .{ .fixed = thumb_y });

        const thumb = try el.div(ctx, track, "thumb");
        _ = thumb.with_size(.{ .fixed = scrollbar_w }, .{ .fixed = thumb_h })
            .with_style(.{Style{ .fill = th.line2 }});
    }

    return .{ .outer = outer, .viewport = viewport, .content = content };
}
