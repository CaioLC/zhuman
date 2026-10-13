//! `header` — the complete HUD header assembly: current stocks on the left, run context plus
//! chevron speed and pause controls on the right. It owns composition and placement only; callers supply
//! formatted stock values and run data, while the child templates retain their behavior.

const ha = @import("ha");
const uic = ha.ui_client;
const el = uic.elements;
const UiCtx = uic.UiCtx;
const El = el.El;

const stock_mod = @import("./stock_token.zig");
const run_mod = @import("./runline.zig");
const speed_mod = @import("./speed_controls.zig");

pub const Options = struct {
    stocks: []const stock_mod.Stock,
    /// The long-line stockline form: Act II's nine stocks rest at the compact size.
    compact_stocks: bool = false,
    /// Speed is normal game chrome; audits can suppress it when isolating stock layout.
    show_speed: bool = true,
    run: run_mod.Run,
};

pub const Header = struct {
    el: El,
    speed: ?El,
    stocks: El,
    run: El,
    menu: El,
    pause: El,
};

/// Assemble the full-width HUD header as one intrinsic-height row. Stocks own the left; run
/// context, chevron speed, menu, and pause share the right group in that order.
pub fn header(parent: El, id: []const u8, options: Options) !Header {
    const root = try parent.div(id);
    _ = root.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .center });

    const stocks = try stock_mod.stockline(root, "stocks", options.stocks, options.compact_stocks);

    const right = try root.div("right");
    _ = right.with_flow(.{ .dir = .row, .cross = .center }).with_gap(12);
    const run = try run_mod.runline(right, "run", options.run);
    const speed: ?El = if (options.show_speed) try speed_mod.speed_controls(right, "speed") else null;
    const menu = try speed_mod.menu_control(right, "menu");
    const pause = try speed_mod.pause_control(right, "pause");

    return .{ .el = root, .speed = speed, .stocks = stocks, .run = run, .menu = menu, .pause = pause };
}
