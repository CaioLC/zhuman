//! `header` — the complete HUD header assembly: current stocks on the left and run context
//! on the right. It owns composition and placement only; callers supply formatted stock values
//! and run data, while `stockline` and `runline` retain their individual rendering behavior.

const ha = @import("ha");
const uic = ha.ui_client;
const el = uic.elements;
const UiCtx = uic.UiCtx;
const El = el.El;

const stock_mod = @import("./stock_token.zig");
const run_mod = @import("./runline.zig");

pub const Options = struct {
    stocks: []const stock_mod.Stock,
    run: run_mod.Run,
};

pub const Header = struct {
    el: El,
    stocks: El,
    run: El,
};

/// Assemble the full-width HUD header as one intrinsic-height row. Keeping both children in flow
/// gives the wrapper a real height; `space_between` pins the run context right even when stocks
/// is an empty, zero-width line after actor death.
pub fn header(parent: El, id: []const u8, options: Options) !Header {
    const root = try parent.div(id);
    _ = root.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .baseline });

    const stocks = try stock_mod.stockline(root, "stocks", options.stocks);
    const run = try run_mod.runline(root, "run", options.run);

    return .{ .el = root, .stocks = stocks, .run = run };
}
