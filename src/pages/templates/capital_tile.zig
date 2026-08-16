//! `capital_tile` template — the capital-good counterpart of `action_tile`. **UI-only
//! mock for now** (no build logic behind it): it renders the grammar so the family can
//! be judged on screen. Same box as an action tile, two deliberate differences: the
//! outline is **dashed** — an unowned good is a plan, not a thing; it turns solid the
//! day owning/building lands — and the second row carries a **consequence**, not a
//! yield band: capital is a stock purchase (`pay once → own`) that changes which flows
//! exist, so the arrow slot names what changes — `→ Fish` (a new verb), `→ Gather -1e`
//! (a cheaper verb), `→ +1f/day` (a flow that runs itself). Reports the click; the
//! caller decides what building means (today: nothing).

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
) !Tile {
    const th = ctx.res.theme;

    const box = try el.div(ctx, parent, id);
    const chrome = if (box.query().hovering) th.acc else th.fg;
    _ = box.with_flow(.{ .dir = .column, .cross = .center }).with_gap(2)
        .with_style(.{ Style{ .outline_color = chrome }, style.dashed, style.pad_sym(12, 6) });

    _ = (try el.text(ctx, box, "name", name)).with_style(.{ style.h3, Style{ .text = chrome } });

    const row = try el.div(ctx, box, "info");
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(6);
    _ = (try el.text(ctx, row, "cost", cost_txt))
        .with_style(.{ style.body, Style{ .text = th.dim } });
    _ = (try el.text(ctx, row, "arrow", "→"))
        .with_style(.{ style.body, Style{ .text = th.dim } });
    _ = (try el.text(ctx, row, "eff", consequence))
        .with_style(.{ style.body, Style{ .text = th.fg } });

    return .{ .el = box, .clicked = box.query().clicked };
}
