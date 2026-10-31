//! `header` — the complete HUD header assembly: current stocks on the left, run context plus
//! the `<< {speed} >>` stepper and menu on the right. It owns composition and placement only;
//! callers supply raw stock values and run data, while the child templates retain their behavior.

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
};

/// Assemble the full-width HUD header as one intrinsic-height row. Stocks own the left; run
/// context, the speed stepper (pause..3×), and the menu share the right group in that order.
pub fn header(parent: El, id: []const u8, options: Options) !Header {
    const root = try parent.box(id, .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children,
        .flow = .{ .dir = .row, .main = .space_between, .cross = .center },
    }, .{});

    const stocks = try stock_mod.stockline(root, "stocks", options.stocks, options.compact_stocks);
    // The stockline takes what the run context leaves, 12px clear of it, and wraps when it
    // runs long (`.stockline { flex-wrap: wrap }`): a long line never runs under the run
    // context, and nothing is hidden. Stacked (≤760) the run context holds to the first line.
    // Its grown width is final before any height is solved, so its fit height counts every
    // line it wraps to.
    const stack = @import("./terminal.zig").stacked(parent.ctx);
    root.set(.{ .flow = .{ .dir = .row, .main = .start, .cross = if (stack) .start else .center }, .gap = 12 }, .{});
    stocks.get().layout.flow.wrap = true;
    stocks.set(.{ .w = .grow, .h = .fit_children }, .{});

    const right = try root.box("right", .{ .flow = .{ .dir = .row, .cross = .center }, .gap = 12 }, .{});
    const run = try run_mod.runline(right, "run", options.run);
    const speed: ?El = if (options.show_speed) try speed_mod.speed_stepper(right, "speed") else null;
    const menu = try speed_mod.menu_control(right, "menu");

    return .{ .el = root, .speed = speed, .stocks = stocks, .run = run, .menu = menu };
}
