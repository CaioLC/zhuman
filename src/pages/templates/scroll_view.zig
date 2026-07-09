//! `scroll_view` template — a fixed-size, clipped viewport over a `fit_children` content
//! column the caller appends rows to. Wheel-scrolls while hovered (offset persisted in a
//! `ScrollState` slot, folded into `content.layout.scroll_y`); a track + thumb ride beside
//! it once content overflows. Behavior-heavy and content-free, so it's structural nodes +
//! placement + `fill`/`outline` chrome — no content leaves. Migrated onto the new
//! foundation; the scroll math is unchanged from the old widget.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const Node = uic.Node;
const ScrollState = uic.UiState.ScrollState;

/// Wheel delta → px scrolled per tick.
const scroll_speed: f32 = 24.0;
/// Scrollbar track/thumb width, in px.
const scrollbar_w: f32 = 6.0;

pub const ScrollView = struct {
    outer: *Node, // wraps the viewport + scrollbar track side by side
    viewport: *Node, // fixed width×height, clipped
    content: *Node, // fit_children column — the caller's rows attach here
};

pub fn scroll_view(ctx: *UiCtx, parent: *Node, id: []const u8, width: f32, height: f32) !ScrollView {
    const th = ctx.res.theme;

    const outer = try Node.pcreate(ctx.arena, id, parent);
    style.apply_placement(outer, .{ style.flow, style.row, style.fit });

    const viewport = try Node.pcreate(ctx.arena, "viewport", outer);
    style.apply_placement(viewport, .{ style.flow, style.fixed(width, height), style.clip });
    style.apply(ctx, viewport, .{Style{ .outline = th.line2 }}); // dim frame around the scroll area

    const content = try Node.pcreate(ctx.arena, "content", viewport);
    style.apply_placement(content, .{ style.flow, style.col, style.gap(4) });
    // Clamp needs content height, but this frame's rows aren't laid out yet — read last
    // frame's rect (queried here to keep the slot alive, exactly like the old widget).
    const content_h = if (content.rect(ctx)) |r| r.h else 0;
    _ = content.query(ctx);

    const max_offset = @max(0.0, content_h - height);
    const st = outer.state(ctx, ScrollState);
    if (viewport.query(ctx).hovering and ctx.res.input.wheel_y != 0) {
        st.offset -= ctx.res.input.wheel_y * scroll_speed; // wheel up ⇒ toward the top
    }
    st.offset = std.math.clamp(st.offset, 0, max_offset);
    content.layout.scroll_y = st.offset; // translate content's children, no second pass

    if (max_offset > 0) {
        const track = try Node.pcreate(ctx.arena, "track", outer);
        style.apply_placement(track, .{ style.flow, style.col, style.fixed(scrollbar_w, height) });
        style.apply(ctx, track, .{Style{ .fill = th.line }});

        // Thumb: two stacked fixed children (an invisible spacer, then the thumb) so
        // ordinary vertical flow positions it — no absolute offset needed.
        const thumb_h = @max(16.0, height * height / content_h);
        const thumb_y = (st.offset / max_offset) * (height - thumb_h);

        const spacer = try Node.pcreate(ctx.arena, "above", track);
        style.apply_placement(spacer, .{ style.flow, style.fixed(scrollbar_w, thumb_y) });

        const thumb = try Node.pcreate(ctx.arena, "thumb", track);
        style.apply_placement(thumb, .{ style.flow, style.fixed(scrollbar_w, thumb_h) });
        style.apply(ctx, thumb, .{Style{ .fill = th.line2 }});
    }

    return .{ .outer = outer, .viewport = viewport, .content = content };
}
