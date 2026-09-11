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
//!
//! **`shell` (KIT-04)** extends this into the one region skeleton every screen composes into:
//! a screen passes a `ShellOptions` descriptor (act identity, responsive padding, and which
//! optional regions it wants) and gets a `Regions` struct of `El` handles — always `header`
//! and `body`, plus optional `rail`/`nav`/`market`/`activity`/`footer` — laid out in the
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

// === KIT-04 · one terminal shell template ==============================================
//
// `shell` extends `terminal` (the outer chrome) into the **region skeleton every screen
// composes into**, so a screen supplies *descriptors* — which regions it wants and its
// responsive padding — instead of hand-building the header/page-grid/rail/main/footer graph.
// One shell serves Act I and Act II: the always-present regions (`header`, `body`) plus the
// optional ones (`rail`, `nav`, `market`, `activity`, `footer`) are created only when the
// descriptor asks, laid out in the prototype's arrangement:
//
//     ┌ content box (page padding, column, section gap) ──────────────┐
//     │ header            (thin top strip: stocks · run context)      │
//     │ market            (optional: MarketStrip)                     │
//     │ activity          (optional: ActivityStrip)                   │
//     │ ┌ page grid (row, grows) ─────────────────────────────────┐  │
//     │ │ rail (optional)  │  body (main surface, grows)           │  │
//     │ └──────────────────────────────────────────────────────────┘ │
//     │ nav               (optional: tab/view navigation)            │
//     │ footer            (optional: EventLog, bottom-anchored)       │
//     └───────────────────────────────────────────────────────────────┘
//
// **Overlay roots** (tooltip, modal) are deliberately *not* children of the terminal box —
// they are their own top-layer roots the screen stamps after the shell so they float above
// the clip and can cover any control (see the modal/tooltip contract). The shell owns the
// in-terminal regions; the screen owns its overlay roots. This keeps the clip honest (nothing
// inside the terminal box escapes it) while overlays still layer correctly.

/// What a screen asks the shell to compose. `act` is carried for descriptor-driven region
/// content (which strips/nav a given act shows) and to key the shell; the booleans turn the
/// optional regions on. `page_pad`/`section_gap` are the screen's responsive choice (VIEW-04)
/// so the shell does not re-derive the width class.
pub const ShellOptions = struct {
    id: []const u8,
    /// The act this shell is for — future region descriptors branch on it; today it only
    /// documents intent and is available to region content.
    act: Act = .act_one,
    page_pad: f32,
    section_gap: f32,
    rail: bool = false,
    nav: bool = false,
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
    /// The tab/view navigation region, present iff `opts.nav`.
    nav: ?El = null,
    /// The optional market strip, present iff `opts.market`.
    market: ?El = null,
    /// The optional activity strip, present iff `opts.activity`.
    activity: ?El = null,
    /// The footer event-log region (bottom-anchored, full width), present iff `opts.footer`.
    footer: ?El = null,
};

/// Build the terminal shell **and** its region skeleton, returning the region handles the
/// screen fills. Composes on top of `terminal`, so the framed/full-window chrome and clip are
/// unchanged; this only lays out the interior. A screen requests its regions via `opts` and
/// never hand-builds the header/grid/footer arrangement again.
pub fn shell(ctx: *UiCtx, opts: ShellOptions) !Regions {
    const sh = try terminal(ctx, opts.id);
    const content = sh.content;

    // The interior column: page padding + section gap, top-aligned so the header sits at the
    // top edge and the footer (bottom-anchored) owns the bottom regardless of body growth.
    _ = content.with_layout(.top_left).with_flow(.{ .dir = .column }).with_gap(opts.section_gap)
        .with_style(.{style.pad(opts.page_pad)});

    // Header: a thin full-width strip. The screen fills it (stocks left, run context right).
    const header = try el.div(ctx, content, "shell_header");
    _ = header.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);

    // Optional market / activity strips ride directly under the header (full width).
    const market = if (opts.market) blk: {
        const s = try el.div(ctx, content, "shell_market");
        _ = s.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
        break :blk s;
    } else null;
    const activity = if (opts.activity) blk: {
        const s = try el.div(ctx, content, "shell_activity");
        _ = s.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
        break :blk s;
    } else null;

    // The page grid: a row that grows to fill the remaining height, holding the optional rail
    // beside the main surface. When there is no rail, the body is the whole grid row.
    const grid = try el.div(ctx, content, "shell_grid");
    _ = grid.with_size(.{ .pct_of_parent = 1.0 }, .grow)
        .with_flow(.{ .dir = .row });
    _ = grid.with_gap(opts.section_gap);

    const rail = if (opts.rail) blk: {
        const r = try el.div(ctx, grid, "shell_rail");
        // Width is the screen's to set (KIT-05 animates it between rail.expanded/collapsed);
        // height fills the grid row.
        _ = r.with_size(.fit_children, .{ .pct_of_parent = 1.0 });
        break :blk r;
    } else null;

    const body = try el.div(ctx, grid, "shell_body");
    _ = body.with_size(.grow, .{ .pct_of_parent = 1.0 });

    // Optional navigation region under the grid (a tablist selecting the body view).
    const nav = if (opts.nav) blk: {
        const n = try el.div(ctx, content, "shell_nav");
        _ = n.with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
        break :blk n;
    } else null;

    // Footer: the event log, bottom-anchored (out of flow) so body growth never pushes it —
    // it owns the bottom edge of the content box.
    const footer = if (opts.footer) blk: {
        const f = try el.div(ctx, content, "shell_footer");
        _ = f.with_layout(.bottom_left);
        break :blk f;
    } else null;

    return .{
        .root = sh.root,
        .header = header,
        .body = body,
        .rail = rail,
        .nav = nav,
        .market = market,
        .activity = activity,
        .footer = footer,
    };
}
