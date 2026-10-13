//! `act_two/coin_merchant` — the Act II **Coin Merchant** (ACT2-14).
//!
//! A thin content adapter over the shared `trade_dialog` using the `.merchant` venue identity:
//! BUY lots cost Coin (`YOU PAY` / `BUY →`), SELL lots earn Coin (`YOU GIVE` / `SELL →`), each a
//! finite-stock Coin/resource/good bundle with a refusal reason when a lot is unavailable. The
//! lots come from the fixture records; a confirmed offer is reported back by index so the caller
//! can settle it atomically once the Act II market model (ACT2-07/08/09) is live.
//!
//! The merchant's inventory and the selected offer survive unrelated view switches because the
//! dialog's open/mode/selection all live in the caller-owned `TradeState` (the same persistence
//! the Act I passerby relies on); expiry/departure closes the dialog by the caller flipping
//! `ts.open = false`, exactly as the Act I page does when the passerby leaves.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const Node = uic.Node;
const UiCtx = uic.UiCtx;
const TradeState = uic.UiState.TradeState;

const fx = @import("./fixtures.zig");
const t = @import("../templates/root.zig");

/// The result of building the merchant dialog for a frame.
pub const Result = struct {
    /// The dialog's overlay root (to list after the page shell), or null when closed.
    root: ?*Node,
    /// The confirmed offer's index into the active list, or null. `mode` says which list.
    confirmed: ?usize = null,
    /// 0 = BUY (into `fx.merchant_buys`), 1 = SELL (into `fx.merchant_sells`).
    mode: usize = 0,
};

fn toOffers(arena: std.mem.Allocator, lots: []const fx.MerchantOffer) ![]t.TradeOffer {
    const out = try arena.alloc(t.TradeOffer, lots.len);
    for (lots, 0..) |lot, i| {
        out[i] = .{
            .id = lot.id,
            .name = lot.name,
            .detail = lot.detail,
            .give = lot.give,
            .receive = lot.receive,
            .effect = lot.effect,
            .stock = lot.stock,
            .refusal = lot.refusal,
        };
    }
    return out;
}

/// Build the Coin Merchant dialog when `ts.open`. Returns the overlay root (or null) plus any
/// confirmed offer this frame. The caller lists the root after its page shell and routes a
/// confirmed index to settlement.
pub fn coin_merchant(ctx: *UiCtx, id: []const u8, ts: *TradeState) !Result {
    if (!ts.open) return .{ .root = null };

    const buys = try toOffers(ctx.arena, &fx.merchant_buys);
    const sells = try toOffers(ctx.arena, &fx.merchant_sells);

    // The settlement's live Coin balance plus a few typed holdings — the YOU HOLD column.
    const holdings = [_]t.TradeHolding{
        .{ .label = "Coin", .value = "126" },
        .{ .label = "Biomass", .value = "31" },
        .{ .label = "Minerals", .value = "3" },
        .{ .label = "Fuel", .value = "14" },
        .{ .label = "Tools", .value = "\u{00d7}6" },
    };

    const res = try t.trade_dialog(ctx, id, .merchant, fx.merchant_meta, buys, sells, &holdings, ts);

    // Escape / outside-click / LEAVE closes. (A live caller also closes on merchant departure.)
    if (res.dismissed) ts.open = false;

    return .{
        .root = if (ts.open) res.root else null,
        .confirmed = res.confirmed,
        .mode = res.mode,
    };
}

// ============================ Tests =====================================================

test "coin merchant exposes the finite BUY and SELL lots" {
    // The fixture carries both directions, including a sold-out and a refused lot.
    try std.testing.expect(fx.merchant_buys.len == 9);
    try std.testing.expect(fx.merchant_sells.len == 5);

    var sold_out = false;
    var refused = false;
    for (fx.merchant_buys) |lot| {
        if (lot.stock == 0) sold_out = true;
        if (lot.refusal.len > 0) refused = true;
    }
    try std.testing.expect(sold_out); // a zero-stock lot is unselectable
    try std.testing.expect(refused); // a refusal reason is unselectable
}

test "BUY lots pay Coin; SELL lots receive Coin" {
    for (fx.merchant_buys) |lot| {
        try std.testing.expect(std.mem.indexOf(u8, lot.give, "Coin") != null); // YOU PAY coin
    }
    for (fx.merchant_sells) |lot| {
        try std.testing.expect(std.mem.indexOf(u8, lot.receive, "Coin") != null); // earn coin
    }
}
