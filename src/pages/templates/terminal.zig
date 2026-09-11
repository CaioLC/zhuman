//! `terminal` — the **centered terminal workspace shell** (VIEW-03). Every screen builds
//! inside it. It reads the frame's `ViewMetrics` and composes the outer chrome:
//!
//!   - **Framed** (logical width > 760): the window is filled with the near-black terminal
//!     **ground** (`#090806`), and the terminal itself is a `metrics.terminal`-sized box —
//!     capped at the `900×820` reference and centered — with a soft drop shadow (RENDER-05),
//!     a hairline border, its own `bg` fill, and **clipped** internals. The screen fills the
//!     returned inner box, so nothing spills past the terminal edge.
//!   - **Full-window** (≤760): the terminal *is* the window — no ground, no shadow, no border,
//!     no cap — exactly the prototype's full-width mode. The returned box is the whole window.
//!
//! The shell returns the **inner content box** (an `El`) for the screen to lay out into, plus
//! the terminal rect it occupies, so a screen positions against the terminal, not the window.
//! Coordinates are device px (VIEW-02): `metrics.terminal` is logical, so it is scaled by the
//! frame `scale` here, once.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;
const UiCtx = uic.UiCtx;

/// The prototype's terminal **ground** — the near-black `#090806` the framed terminal floats
/// on, darker than the terminal's own `bg` (`#0e0c09`). An art-direction literal that KIT-01
/// will fold into the palette tokens; kept here (game tier) meanwhile, not in the generic
/// `Theme`.
pub const ground: uic.Color = .{ .r = 9, .g = 8, .b = 6, .a = 255 };

/// A built terminal shell: the fullscreen `root` (hand this to the render walk) and the
/// `content` box the screen fills.
pub const Shell = struct {
    root: El,
    content: El,
};

/// Build the terminal shell for this frame and return the inner content box to fill. `id`
/// keys the shell nodes. See the module doc for the framed vs full-window composition.
pub fn terminal(ctx: *UiCtx, id: []const u8) !Shell {
    const m = ctx.res.view.metrics;
    const th = ctx.res.view.theme;
    const scale = ctx.res.view.scale;

    const root = try el.root(ctx, id);

    if (!m.framed()) {
        // Full-window (≤760): the terminal is the whole window; no frame chrome. Fill with the
        // terminal's own bg and clip, and hand the root back as the content box.
        _ = root.with_layout(.top_left)
            .with_style(.{Style{ .fill = th.bg }})
            .with_overflow(.clip);
        return .{ .root = root, .content = root };
    }

    // Framed: the window is the terminal ground; the terminal is a centered, capped box.
    _ = root.with_layout(.top_left).with_style(.{Style{ .fill = ground }});

    // The terminal rect in device px (metrics.terminal is logical — scale once, VIEW-02).
    const tx = uic.view.dp(m.terminal.x, scale);
    const ty = uic.view.dp(m.terminal.y, scale);
    const tw = uic.view.dp(m.terminal.w, scale);
    const twh = uic.view.dp(m.terminal.h, scale);

    // A soft drop shadow behind the terminal (RENDER-05), placed before the box so it paints
    // under it. Understated: the prototype's `0 16px 80px #000a`, in device px.
    try uic.shadow.drop(ctx, root, id, tx, ty, tw, twh, .{
        .offset_y = uic.view.dp(16, scale),
        .blur = uic.view.dp(60, scale),
        .base_alpha = 0xaa,
        .count = 5,
    });

    // The terminal box: absolutely placed at the centered rect, its own bg, a hairline border,
    // and clipped internals so screen content never spills past the edge.
    const box = try el.div(ctx, root, "terminal_box");
    _ = box.with_layout(.top_left)
        .with_size_px(.{ .fixed = tw }, .{ .fixed = twh })
        .with_offset_px(tx, ty)
        .with_style(.{Style{ .fill = th.bg, .outline_color = th.line2 }})
        .with_overflow(.clip);

    return .{ .root = root, .content = box };
}
