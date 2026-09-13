//! `trade_dialog` — thin venue/state coordinator composed from four templates:
//! `modal` (outer shell), `modal_header`, `modal_body`, and `modal_footer`.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const UiCtx = uic.UiCtx;
const TradeState = uic.UiState.TradeState;
const market = @import("./market_strip.zig");
const modal_mod = @import("./modal.zig");
const header_mod = @import("./modal_header.zig");
const body_mod = @import("./modal_body.zig");
const footer_mod = @import("./modal_footer.zig");

pub const Offer = body_mod.Offer;
pub const Holding = body_mod.Holding;
pub const firstValidOffer = body_mod.firstValidOffer;

pub const VenueIdentity = struct {
    kicker: []const u8,
    title: []const u8,
    buy_give: []const u8,
    sell_give: []const u8,
    cta: []const u8,
    footer: []const u8,
};

pub fn venueIdentity(kind: market.MarketKind) VenueIdentity {
    return switch (kind) {
        .passerby => .{ .kicker = "PASSERBY", .title = "What will you trade?", .buy_give = "YOU GIVE", .sell_give = "YOU GIVE", .cta = "TRADE \u{2192}", .footer = "Fixed ratios, finite stock, limited time. Selling repeats at diminishing marginal prices." },
        .merchant => .{ .kicker = "MERCHANT", .title = "What will you trade?", .buy_give = "YOU GIVE", .sell_give = "YOU GIVE", .cta = "TRADE \u{2192}", .footer = "Prices are firm." },
        .exchange => .{ .kicker = "EXCHANGE", .title = "What will you trade?", .buy_give = "BID", .sell_give = "OFFER", .cta = "EXECUTE \u{2192}", .footer = "Cleared on the book." },
    };
}

pub const Result = struct {
    mode: usize,
    selected: ?usize,
    confirmed: ?usize = null,
    dismissed: bool = false,
};

pub fn trade_dialog(ctx: *UiCtx, id: []const u8, kind: market.MarketKind, meta: []const u8, buy_offers: []const Offer, sell_offers: []const Offer, holdings: []const Holding, st: *TradeState, out_root: **uic.Node) !Result {
    const identity = venueIdentity(kind);
    const m = try modal_mod.modal(ctx, id, identity.title, modal_mod.default_width);
    out_root.* = m.root;

    const close_clicked = try header_mod.modal_header(ctx, m.box, m.width, identity.kicker, meta, identity.title);
    const body = try body_mod.modal_body(ctx, m.box, m.width, identity.buy_give, identity.sell_give, buy_offers, sell_offers, holdings, st);
    const footer = try footer_mod.modal_footer(ctx, m.box, m.width, identity.footer, identity.cta, body.can_confirm);

    return .{
        .mode = body.mode,
        .selected = body.selected,
        .confirmed = if (footer.confirm) body.selected else null,
        .dismissed = modal_mod.dismissed(ctx, m, close_clicked or footer.leave),
    };
}

test "venue identity map matches authored trade chrome" {
    try std.testing.expectEqualStrings("PASSERBY", venueIdentity(.passerby).kicker);
    try std.testing.expectEqualStrings("What will you trade?", venueIdentity(.passerby).title);
    try std.testing.expectEqualStrings("TRADE \u{2192}", venueIdentity(.merchant).cta);
    try std.testing.expectEqualStrings("BID", venueIdentity(.exchange).buy_give);
    try std.testing.expectEqualStrings("EXECUTE \u{2192}", venueIdentity(.exchange).cta);
}

test "TradeState keeps per-mode selection separate" {
    var state = TradeState{};
    state.setSel(2);
    try std.testing.expectEqual(@as(usize, 2), state.buy_sel);
    state.mode = 1;
    state.setSel(4);
    try std.testing.expectEqual(@as(usize, 4), state.sell_sel);
    try std.testing.expectEqual(@as(usize, 2), state.buy_sel);
}

test "Offer availability requires stock and no refusal" {
    try std.testing.expect((Offer{ .give = "a", .receive = "b" }).valid());
    try std.testing.expect(!(Offer{ .give = "a", .receive = "b", .stock = 0 }).valid());
    try std.testing.expect(!(Offer{ .give = "a", .receive = "b", .refusal = "no" }).valid());
}
