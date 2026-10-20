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
    /// The confirmation CTA while the BUY tab is active.
    buy_cta: []const u8,
    /// The confirmation CTA while the SELL tab is active. Equal to `buy_cta` for venues whose
    /// CTA does not change by direction (Act I's single `TRADE →`).
    sell_cta: []const u8,
    footer: []const u8,
    /// The note under the YOU HOLD column: what the preview guarantees at this venue.
    hold_note: []const u8,
};

pub fn venueIdentity(kind: market.MarketKind) VenueIdentity {
    return switch (kind) {
        // The Act I passerby and the exchange keep one CTA per venue; the Coin Merchant (Act II)
        // is the first venue whose give-label and CTA change with direction: BUY spends Coin
        // (`YOU PAY` / `BUY →`), SELL earns it (`YOU GIVE` / `SELL →`).
        .passerby => .{ .kicker = "PASSERBY", .title = "What will you trade?", .buy_give = "YOU GIVE", .sell_give = "YOU GIVE", .buy_cta = "TRADE \u{2192}", .sell_cta = "TRADE \u{2192}", .footer = "Fixed ratios, finite stock, limited time. Selling repeats at diminishing marginal prices.", .hold_note = "The preview is final: payment, replacement, and remaining stock are visible before exchange." },
        .merchant => .{ .kicker = "MERCHANT", .title = "What will you trade?", .buy_give = "YOU PAY", .sell_give = "YOU GIVE", .buy_cta = "BUY \u{2192}", .sell_cta = "SELL \u{2192}", .footer = "Coin prices are firm; stock is finite and the merchant leaves at the end of market day.", .hold_note = "The price is final for this lot. Coin and stock settle together." },
        .exchange => .{ .kicker = "EXCHANGE", .title = "What will you trade?", .buy_give = "BID", .sell_give = "OFFER", .buy_cta = "EXECUTE \u{2192}", .sell_cta = "EXECUTE \u{2192}", .footer = "Cleared on the book.", .hold_note = "Orders clear at the book price shown." },
    };
}

pub const Result = struct {
    mode: usize,
    selected: ?usize,
    confirmed: ?usize = null,
    dismissed: bool = false,
    /// The dialog's own root, for the page to list after its shell.
    root: *uic.Node,
};

pub fn trade_dialog(ctx: *UiCtx, id: []const u8, kind: market.MarketKind, meta: []const u8, buy_offers: []const Offer, sell_offers: []const Offer, holdings: []const Holding, st: *TradeState) !Result {
    const identity = venueIdentity(kind);
    const m = try modal_mod.modal(ctx, id, identity.title, modal_mod.default_width);

    const close_clicked = try header_mod.modal_header(m.box, m.width, identity.kicker, meta, identity.title);
    const body = try body_mod.modal_body(m.box, m.width, identity.buy_give, identity.sell_give, identity.hold_note, buy_offers, sell_offers, holdings, st);
    // The CTA follows the active tab: a merchant shows `BUY →` on the buy tab and `SELL →` on
    // the sell tab; single-CTA venues set both to the same label, so this is a no-op for them.
    const cta = if (body.mode == 0) identity.buy_cta else identity.sell_cta;
    const footer = try footer_mod.modal_footer(m.box, m.width, identity.footer, cta, body.can_confirm);

    return .{
        .mode = body.mode,
        .selected = body.selected,
        .confirmed = if (footer.confirm) body.selected else null,
        .dismissed = modal_mod.dismissed(ctx, m, close_clicked or footer.leave, footer.primary_key),
        .root = m.root,
    };
}

test "venue identity map matches authored trade chrome" {
    try std.testing.expectEqualStrings("PASSERBY", venueIdentity(.passerby).kicker);
    try std.testing.expectEqualStrings("What will you trade?", venueIdentity(.passerby).title);
    try std.testing.expectEqualStrings("TRADE \u{2192}", venueIdentity(.passerby).buy_cta);
    try std.testing.expectEqualStrings("BID", venueIdentity(.exchange).buy_give);
    try std.testing.expectEqualStrings("EXECUTE \u{2192}", venueIdentity(.exchange).buy_cta);
    // The Coin Merchant's give-label and CTA change with direction (ACT2-14).
    try std.testing.expectEqualStrings("YOU PAY", venueIdentity(.merchant).buy_give);
    try std.testing.expectEqualStrings("YOU GIVE", venueIdentity(.merchant).sell_give);
    try std.testing.expectEqualStrings("BUY \u{2192}", venueIdentity(.merchant).buy_cta);
    try std.testing.expectEqualStrings("SELL \u{2192}", venueIdentity(.merchant).sell_cta);
    // Each venue states its own settlement guarantee under YOU HOLD.
    try std.testing.expect(!std.mem.eql(u8, venueIdentity(.passerby).hold_note, venueIdentity(.merchant).hold_note));
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
    try std.testing.expect((Offer{ .id = 1, .give = "a", .receive = "b" }).valid());
    try std.testing.expect(!(Offer{ .id = 1, .give = "a", .receive = "b", .stock = 0 }).valid());
    try std.testing.expect(!(Offer{ .id = 1, .give = "a", .receive = "b", .refusal = "no" }).valid());
}
