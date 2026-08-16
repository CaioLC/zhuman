//! `capital_tile` template — the capital-good counterpart of `action_tile`. Same box
//! family, two deliberate differences. The outline speaks **ownership**: `dashed` while
//! unowned — a good that doesn't exist yet is a plan — turning `solid` the day it's
//! built (later, durability can walk it back toward dashed as the tool frays). And the
//! second row carries a **consequence**, not a yield band: capital is a stock purchase
//! (pay once → own) that changes which flows exist, so the arrow slot names what
//! changes — `→ Fish` (a new verb), `→ Gather -1e` (a cheaper verb), `→ +1f/day` (a
//! flow that runs itself). String-driven like the bare `tile`; a wrapper per real good
//! (`fish_rod_tile`) reads the world, formats, and acts on the reported click. An owned
//! tile is inert (never clicked, no hover accent); an unaffordable plan dims flat.

const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;

const Tile = @import("./action_tile.zig").Tile;

pub fn capital_tile(
    ctx: *UiCtx,
    parent: El,
    id: []const u8,
    name: []const u8,
    cost_txt: []const u8,
    consequence: []const u8,
    can: bool,
    owned: bool,
    progress: ?f32,
) !Tile {
    const th = ctx.res.theme;
    const building = progress != null;

    const box = try el.div(ctx, parent, id);
    // Query unconditionally: an unqueried node has no slot, so stamp_rects skips it and
    // the prior-frame rect (which the build underbar is sized from) would read null.
    const q = box.query();
    const hot = !owned and !building and can; // a buildable plan is the only interactive state
    const chrome = if (owned) th.fg else if (building) th.fg else if (!can) th.dim else if (q.hovering) th.acc else th.fg;
    // Outline + 1px bottom inset on the box; content padding on `inner` — so the build
    // underbar spans the full width, flush above the border line (see `action_tile`).
    _ = box.with_flow(.{ .dir = .column })
        .with_style(.{
            Style{ .outline_color = chrome },
            if (owned) style.solid else style.dashed,
            style.pad_each(0, 0, 1, 0),
        });

    const inner = try el.div(ctx, box, "inner");
    _ = inner.with_flow(.{ .dir = .column, .cross = .center }).with_gap(2)
        .with_style(.{style.pad_sym(12, 6)});

    _ = (try el.text(ctx, inner, "name", name)).with_style(.{ style.h3, Style{ .text = chrome } });

    const row = try el.div(ctx, inner, "info");
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(6);
    const lit = owned or building or can;
    _ = (try el.text(ctx, row, "cost", cost_txt))
        .with_style(.{ style.body, Style{ .text = if (lit) th.dim else chrome } });
    _ = (try el.text(ctx, row, "arrow", "→"))
        .with_style(.{ style.body, Style{ .text = if (lit) th.dim else chrome } });
    _ = (try el.text(ctx, row, "eff", consequence))
        .with_style(.{ style.body, Style{ .text = if (lit) th.fg else chrome } });

    // Build progress: the underbar filling along the dashed plan — the good materializing.
    // Full tile width × progress, from LAST frame's rect (prior-frame pattern); anchored,
    // so it never resizes the tile. Moot the frame ownership lands (outline goes solid).
    if (progress) |p| {
        if (box.get().rect(ctx)) |r| {
            const bar = try el.div(ctx, box, "bar");
            _ = bar.with_layout(.bottom_left)
                .with_size(.{ .fixed = r.w * @min(p, 1) }, .{ .fixed = 3 })
                .with_style(.{Style{ .fill = th.acc }});
        }
    }

    return .{ .el = box, .clicked = hot and q.clicked };
}
