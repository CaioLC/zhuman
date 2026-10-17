//! `terminal` — the **centered terminal workspace shell**. Every screen builds
//! inside it. It reads the frame's `ViewMetrics` and composes the outer chrome:
//!
//!   - **Framed** (logical width > 760): the window is filled with the near-black terminal
//!     **ground** (`#090806`), and the terminal itself is a `metrics.terminal`-sized box —
//!     capped at the `900×820` reference and centered — with a soft drop shadow,
//!     a hairline border, its own `bg` fill, and **clipped** internals. The screen fills the
//!     returned inner box, so nothing spills past the terminal edge.
//!   - **Full-window** (≤760): the terminal *is* the window — no ground, no shadow, no border,
//!     no cap — exactly the prototype's full-width mode. The returned box is the whole window.
//!
//! The shell returns the **inner content box** (an `El`) for the screen to lay out into, plus
//! the terminal rect it occupies, so a screen positions against the terminal, not the window.
//! Coordinates are device px: `metrics.terminal` is logical, so it is scaled by the
//! frame `scale` here, once.
//!
//! **`shell`** extends this into the one region skeleton every screen composes into:
//! a screen passes a `ShellOptions` descriptor (act identity, responsive padding, and which
//! optional regions it wants) and gets a `Regions` struct of `El` handles — always `header`
//! and `body`, plus optional `rail`/`market`/`activity`/`footer` — laid out in the
//! prototype's arrangement, so no screen hand-builds that graph. Overlay roots stay the
//! screen's own top-layer roots, outside the clipped terminal box.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;
const UiCtx = uic.UiCtx;

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
    const ground = ctx.res.view.ground;
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

    // The terminal rect in device px (metrics.terminal is logical — scale once).
    const tx = uic.view.dp(m.terminal.x, scale);
    const ty = uic.view.dp(m.terminal.y, scale);
    const tw = uic.view.dp(m.terminal.w, scale);
    const twh = uic.view.dp(m.terminal.h, scale);

    // A soft drop shadow behind the terminal, placed before the box so it paints
    // under it. Understated: the prototype's `0 16px 80px #000a`, in device px.
    try uic.shadow.drop(root, id, tx, ty, tw, twh, .{
        .offset_y = uic.view.dp(16, scale),
        .blur = uic.view.dp(60, scale),
        .base_alpha = 0xaa,
        .count = 5,
    });

    // The terminal box: absolutely placed at the centered rect, its own bg, a hairline border,
    // and clipped internals so screen content never spills past the edge.
    const box = try root.div("terminal_box");
    _ = box.with_layout(.top_left)
        .with_size_px(.{ .fixed = tw }, .{ .fixed = twh })
        .with_offset_px(tx, ty)
        .with_style(.{Style{ .fill = th.bg, .outline_color = th.line2 }})
        .with_overflow(.clip);

    return .{ .root = root, .content = box };
}

// === The shell: one region skeleton for every screen ==============================================
//
// `shell` extends `terminal` (the outer chrome) into the **region skeleton every screen
// composes into**, so a screen supplies *descriptors* — which regions it wants and its
// responsive padding — instead of hand-building the header/page-grid/rail/main/footer graph.
// One shell serves Act I and Act II: the always-present regions (`header`, `body`) plus the
// optional ones (`rail`, `market`, `activity`, `footer`) are created only when the
// descriptor asks, laid out in the prototype's arrangement:
//
//     ┌ content box (page padding, column, section gap) ──────────────┐
//     │ header            (thin top strip: stocks · run context)      │
//     │ market            (optional: MarketStrip)                     │
//     │ activity          (optional: ActivityStrip)                   │
//     │ ┌ page grid (row, grows) ─────────────────────────────────┐  │
//     │ │ rail (optional)  │  body (main surface, grows)           │  │
//     │ └──────────────────────────────────────────────────────────┘ │
//     │ footer            (optional: EventLog, bottom-anchored)       │
//     └───────────────────────────────────────────────────────────────┘
//
// A tab strip is never a shell region: it is the first row of the surface it switches, in
// both acts (`tabs`).
//
// **Overlay roots** (tooltip, modal) are deliberately *not* children of the terminal box —
// they are their own top-layer roots the screen stamps after the shell so they float above
// the clip and can cover any control (see the modal/tooltip contract). The shell owns the
// in-terminal regions; the screen owns its overlay roots. This keeps the clip honest (nothing
// inside the terminal box escapes it) while overlays still layer correctly.

/// What a screen asks the shell to compose. `act` is carried for descriptor-driven region
/// content (which strips a given act shows) and to key the shell; the booleans turn the
/// optional regions on. `page_pad`/`section_gap` are the screen's responsive choice
/// so the shell does not re-derive the width class.
pub const ShellOptions = struct {
    id: []const u8,
    /// The act this shell is for — future region descriptors branch on it; today it only
    /// documents intent and is available to region content.
    act: Act = .act_one,
    page_pad: f32,
    section_gap: f32,
    rail: bool = false,
    market: bool = false,
    activity: bool = false,
    footer: bool = false,
};

/// The two acts the one shell serves. Act I is the survival HUD; Act II (the settlement /
/// STRUCTURE board) reuses the same skeleton with more regions turned on.
pub const Act = enum { act_one, act_two };

/// The built region handles. `root` goes to the render walk; the screen fills the non-null
/// region boxes. Optional regions are null when the descriptor did not request them, so a
/// screen `if (regions.rail) |rail| …`s only the regions it asked for.
pub const Regions = struct {
    root: El,
    /// The thin top strip (stocks left, run context right). Always present.
    header: El,
    /// The main view surface — the screen's primary content, grows to fill. Always present.
    body: El,
    /// The side rail (Holdings/BODY), present iff `opts.rail`.
    rail: ?El = null,
    /// The optional market strip, present iff `opts.market`.
    market: ?El = null,
    /// The optional activity strip, present iff `opts.activity`.
    activity: ?El = null,
    /// The framed footer event-log content lane, reserved in normal flow iff `opts.footer`.
    footer: ?El = null,
};

const header_content_height: f32 = 23;
const header_pad_top: f32 = 15;
const header_pad_bottom: f32 = 10;
const grid_pad_top: f32 = 12;
const grid_pad_bottom: f32 = 10;
const footer_height: f32 = 86;
const footer_pad_top: f32 = 4;
const footer_pad_bottom: f32 = 2;

fn insetRegion(parent: El, id: []const u8, inset: f32) !El {
    const row = try parent.div(id);
    _ = row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .start });
    _ = try row.spacer("lead", inset, 1);
    const region = try row.div("content");
    _ = region.with_size(.grow, .fit_children);
    _ = try row.spacer("tail", inset, 1);
    return region;
}

fn footerBandHeight(page_pad: f32) f32 {
    return footer_height + page_pad;
}

/// Compose the prototype's interior rows into an existing definite-size box. Production
/// `shell` uses the terminal content box; the debug shelf uses this seam to audit one complete
/// 900×820 page without creating a second root or duplicating the region geometry.
pub fn shell_content(root: El, content: El, opts: ShellOptions) !Regions {
    const ctx = root.ctx;
    const th = ctx.res.view.theme;
    _ = content.with_layout(.top_left)
        .with_flow(.{ .dir = .column });

    // Header: 48px total at the reference (15px top + 23px content + 10px bottom), with
    // horizontal page insets represented as flow lanes so percentage sizing remains border-box
    // safe in this layout engine.
    const header_band = try content.div("shell_header_band");
    _ = header_band.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .start });
    _ = try header_band.spacer("lead", opts.page_pad, 1);
    const header = try header_band.div("shell_header");
    _ = header.with_size(.grow, .{ .fixed = header_content_height })
        .with_style(.{style.pad_each(header_pad_top, 0, header_pad_bottom, 0)});
    _ = try header_band.spacer("tail", opts.page_pad, 1);

    // Teaching-mode context strips remain shell-owned and horizontally aligned to the page.
    // The underway Act I surface owns its own market/activity strips, so these regions are absent
    // there and the page grid receives the full middle row.
    const market = if (opts.market)
        try insetRegion(content, "shell_market_band", opts.page_pad)
    else
        null;
    const activity = if (opts.activity)
        try insetRegion(content, "shell_activity_band", opts.page_pad)
    else
        null;

    // The page-grid row owns all remaining height after the header and optional reserved footer.
    // Its authored 12px/10px vertical and page-width horizontal insets are real flow lanes; the
    // body therefore has a definite height and cannot extend underneath the logger.
    const grid_band = try content.div("shell_grid_band");
    _ = grid_band.with_size(.{ .pct_of_parent = 1.0 }, .grow)
        .with_flow(.{ .dir = .column });
    _ = try grid_band.spacer("top", 1, grid_pad_top);
    const grid_row = try grid_band.div("row");
    _ = grid_row.with_size(.{ .pct_of_parent = 1.0 }, .grow)
        .with_flow(.{ .dir = .row, .cross = .start });
    _ = try grid_row.spacer("lead", opts.page_pad, 1);
    const grid = try grid_row.div("shell_grid");
    _ = grid.with_size(.grow, .{ .pct_of_parent = 1.0 })
        .with_flow(.{ .dir = .row }).with_gap(opts.section_gap);
    _ = try grid_row.spacer("tail", opts.page_pad, 1);
    _ = try grid_band.spacer("bottom", 1, grid_pad_bottom);

    const rail = if (opts.rail) blk: {
        const r = try grid.div("shell_rail");
        _ = r.with_size(.fit_children, .{ .pct_of_parent = 1.0 });
        break :blk r;
    } else null;

    const body = try grid.div("shell_body");
    _ = body.with_size(.grow, .{ .pct_of_parent = 1.0 });

    // Footer: reserve its complete 86px frame plus bottom page margin in normal flow. The
    // previous absolute child did not subtract itself from the growing grid, allowing workspace
    // content to run underneath the log. The returned handle is the frame's 80px content lane;
    // callers continue to render the authoritative live Log through `log_view`.
    const footer = if (opts.footer) blk: {
        const band = try content.div("shell_footer_band");
        _ = band.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = footerBandHeight(opts.page_pad) })
            .with_flow(.{ .dir = .column });
        const row = try band.div("row");
        _ = row.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = footer_height })
            .with_flow(.{ .dir = .row, .cross = .start });
        _ = try row.spacer("lead", opts.page_pad, 1);
        const frame = try row.div("frame");
        _ = frame.with_size(.grow, .{ .fixed = footer_height })
            .with_flow(.{ .dir = .column })
            .with_overflow(.clip)
            .with_style(.{Style{ .outline_color = th.line2 }});
        _ = try frame.spacer("top", 1, footer_pad_top);
        const f = try frame.div("shell_footer");
        _ = f.with_size(.{ .pct_of_parent = 1.0 }, .grow)
            .with_overflow(.clip);
        _ = try frame.spacer("bottom", 1, footer_pad_bottom);
        _ = try row.spacer("tail", opts.page_pad, 1);
        _ = try band.spacer("margin", 1, opts.page_pad);
        break :blk f;
    } else null;

    return .{
        .root = root,
        .header = header,
        .body = body,
        .rail = rail,
        .market = market,
        .activity = activity,
        .footer = footer,
    };
}

/// Build the terminal shell **and** its region skeleton, returning the region handles the
/// screen fills. The interior is the same composer used by the full-page debug fixture.
pub fn shell(ctx: *UiCtx, opts: ShellOptions) !Regions {
    const sh = try terminal(ctx, opts.id);
    return shell_content(sh.root, sh.content, opts);
}

test "shell reference rows reserve header and framed footer geometry" {
    try std.testing.expectEqual(@as(f32, 48), header_pad_top + header_content_height + header_pad_bottom);
    try std.testing.expectEqual(@as(f32, 102), footerBandHeight(16));
    try std.testing.expectEqual(@as(f32, 86), footer_height);
    try std.testing.expectEqual(@as(f32, 22), grid_pad_top + grid_pad_bottom);
}
