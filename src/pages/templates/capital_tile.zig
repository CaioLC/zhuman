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
) !Tile {
    const th = ctx.res.theme;

    const box = try el.div(ctx, parent, id);
    const hot = !owned and can; // a buildable plan is the only interactive state
    const chrome = if (owned) th.fg else if (!can) th.dim else if (box.query().hovering) th.acc else th.fg;
    _ = box.with_flow(.{ .dir = .column, .cross = .center }).with_gap(2)
        .with_style(.{
            Style{ .outline_color = chrome },
            if (owned) style.solid else style.dashed,
            style.pad_sym(12, 6),
        });

    _ = (try el.text(ctx, box, "name", name)).with_style(.{ style.h3, Style{ .text = chrome } });

    const row = try el.div(ctx, box, "info");
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(6);
    _ = (try el.text(ctx, row, "cost", cost_txt))
        .with_style(.{ style.body, Style{ .text = if (owned or can) th.dim else chrome } });
    _ = (try el.text(ctx, row, "arrow", "→"))
        .with_style(.{ style.body, Style{ .text = if (owned or can) th.dim else chrome } });
    _ = (try el.text(ctx, row, "eff", consequence))
        .with_style(.{ style.body, Style{ .text = if (owned or can) th.fg else chrome } });

    return .{ .el = box, .clicked = hot and box.query().clicked };
}
