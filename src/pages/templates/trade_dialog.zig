//! `trade_dialog` (KIT-21) — the shared trade overlay a venue opens: a modal with a header,
//! buy/sell tabs, a three-column body (offers · preview · holdings), and a footer. It is
//! **identity-map driven** — the venue (passerby / merchant / exchange) supplies the kicker,
//! title, column headings, the give-label per mode, the CTA, and the footer note — so the
//! dialog is not rebuilt per venue.
//!
//! The **offer list** has exclusive selection (one offer highlighted), finite **stock** (an
//! out-of-stock or refused offer is disabled and shows its refusal copy), and a **preview** of
//! the selected offer's give/receive/effect beside the player's **live holdings**. Completion is
//! **atomic**: the CTA reports the confirmed offer index once, and the caller performs the
//! exchange (the dialog owns none of the economy). **Mode change selects the first valid offer**
//! of the new mode **without discarding** the other mode's selection (kept in `TradeState`).

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const TradeState = uic.UiState.TradeState;

const market = @import("./market_strip.zig");

/// One offer in a mode's list. `stock` gates availability (0 ⇒ disabled); a nonempty `refusal`
/// forces a disabled offer with that copy (e.g. "won't take that"). The caller formats the
/// give/receive/effect strings (the dialog owns no economy math).
pub const Offer = struct {
    give: []const u8,
    receive: []const u8,
    effect: []const u8 = "",
    stock: u32 = 1,
    refusal: []const u8 = "",

    /// Whether this offer can be selected/confirmed: in stock and not refused.
    pub fn valid(self: Offer) bool {
        return self.stock > 0 and self.refusal.len == 0;
    }
};

/// The venue's presentation — a pure identity table row.
pub const VenueIdentity = struct {
    kicker: []const u8,
    title: []const u8,
    /// The give-label for buy vs sell mode ("You pay" / "You give").
    buy_give: []const u8,
    sell_give: []const u8,
    cta: []const u8,
    footer: []const u8,
};

/// The **venue identity map** (pure, tested): a `MarketKind` → all the dialog's venue wording.
pub fn venueIdentity(kind: market.MarketKind) VenueIdentity {
    return switch (kind) {
        .passerby => .{ .kicker = "A PASSERBY", .title = "Odd trinkets", .buy_give = "You pay", .sell_give = "You give", .cta = "Take it", .footer = "They will not linger." },
        .merchant => .{ .kicker = "A MERCHANT", .title = "Wares for sale", .buy_give = "You pay", .sell_give = "You give", .cta = "Deal", .footer = "Prices are firm." },
        .exchange => .{ .kicker = "THE EXCHANGE", .title = "Open market", .buy_give = "Bid", .sell_give = "Offer", .cta = "Execute", .footer = "Cleared on the book." },
    };
}

/// The first selectable offer index of a list (in stock, not refused), or 0 if none is valid —
/// the pure rule mode-change uses so switching tabs lands on a usable offer.
pub fn firstValidOffer(offers: []const Offer) usize {
    for (offers, 0..) |o, i| if (o.valid()) return i;
    return 0;
}

/// What the dialog reports this frame. `mode` is the active tab; `selected` the current offer
/// index (null when the mode has no offers); `confirmed` the offer index the CTA committed this
/// frame (the caller performs the atomic exchange); `dismissed` whether Escape/close fired.
pub const Result = struct {
    mode: usize,
    selected: ?usize,
    confirmed: ?usize = null,
    dismissed: bool = false,
};

/// Build the trade dialog as a modal overlay. Returns its `root` (the caller lists it last in
/// the frame trees so it draws on top) via `out_root`, and the interaction `Result`. `holdings`
/// is the player's live holdings line (formatted by the caller).
pub fn trade_dialog(
    ctx: *UiCtx,
    id: []const u8,
    kind: market.MarketKind,
    buy_offers: []const Offer,
    sell_offers: []const Offer,
    holdings: []const u8,
    out_root: **uic.Node,
) !Result {
    const th = ctx.res.view.theme;
    const idn = venueIdentity(kind);

    const m = try uic.modal(ctx, id, idn.title);
    out_root.* = m.root;
    const st = m.box.state(ctx, TradeState);

    // Kicker under the modal's title. `modal` already built the box; wrap it as an El to append.
    const box = El{ .node = m.box, .ctx = ctx };
    _ = (try el.text(ctx, box, "kicker", idn.kicker)).with_style(.{ style.eyebrow, Style{ .text = th.acc } });

    // Buy/Sell tabs — a two-option roving tablist. Switching mode is a KIT-21 rule: keep each
    // mode's own selection, and land on the first valid offer of the new mode when its stored
    // selection is no longer valid.
    const tabs = try (@import("./tabs.zig")).tabs(ctx, box, "modes", &.{ "BUY", "SELL" });
    if (tabs.active != st.mode) {
        st.mode = tabs.active;
        const list = if (st.mode == 0) buy_offers else sell_offers;
        // Only re-seed if the remembered selection is now invalid (don't discard needlessly).
        const cur = st.sel();
        if (cur >= list.len or !list[cur].valid()) st.setSel(firstValidOffer(list));
    }

    const offers = if (st.mode == 0) buy_offers else sell_offers;
    const give_label = if (st.mode == 0) idn.buy_give else idn.sell_give;

    // Three-column body: offers | preview | holdings.
    const body = try el.div(ctx, box, "body");
    _ = body.with_flow(.{ .dir = .row }).with_gap(ha.tokens.gap.group).with_size(.fit_children, .fit_children);

    // Column 1: the offer list (exclusive selection; disabled when out of stock / refused).
    const list_col = try el.div(ctx, body, "offers");
    _ = list_col.with_flow(.{ .dir = .column }).with_gap(ha.tokens.gap.tight);
    for (offers, 0..) |offer, i| {
        const okey = try std.fmt.allocPrint(ctx.arena, "of{d}", .{i});
        const row = try el.div(ctx, list_col, okey);
        const selectable = offer.valid();
        ctx.registerFocus(row.get().key, selectable);
        const rq = row.query();
        if (rq.clicked and !selectable) _ = ctx.consumeFlag(row.get().key, .clicked);
        if (rq.clicked and selectable) {
            _ = ctx.requestFocus(row.get().key);
            st.setSel(i);
        }
        const chosen = st.sel() == i;
        const rfocused = ctx.isFocused(row.get().key);
        if (rq.hovering and selectable) ctx.res.cursor.request(.pointer);
        uic.publishControlState(ctx, row.get().key, .{ .disabled = !selectable, .selected = chosen, .focused = rfocused, .focus_visible = rfocused });
        const ink = if (!selectable) th.line2 else if (chosen) th.acc else if (rq.hovering or rfocused) th.fg else th.dim;
        _ = row.with_flow(.{ .dir = .row }).with_gap(ha.tokens.gap.inline_)
            .with_style(.{ Style{ .fill = if (chosen) th.panel else null }, style.pad_sym(6, 3) });
        _ = (try el.text(ctx, row, "g", offer.give)).with_style(.{ style.body, Style{ .text = ink } });
        _ = (try el.text(ctx, row, "arrow", "\u{2192}")).with_style(.{ style.body, Style{ .text = ink } });
        _ = (try el.text(ctx, row, "r", offer.receive)).with_style(.{ style.body, Style{ .text = ink } });
        // Disabled/refusal copy (out of stock, or the venue refuses).
        if (!selectable) {
            const why = if (offer.refusal.len > 0) offer.refusal else "out of stock";
            _ = (try el.text(ctx, row, "no", why)).with_style(.{ style.small, Style{ .text = th.danger } });
        }
    }

    // Resolve the current selection (null when the mode has no offers).
    const selected: ?usize = if (offers.len == 0) null else @min(st.sel(), offers.len - 1);

    // Column 2: preview of the selected offer's give/receive/effect.
    const preview = try el.div(ctx, body, "preview");
    _ = preview.with_flow(.{ .dir = .column }).with_gap(ha.tokens.gap.tight);
    if (selected) |si| {
        const o = offers[si];
        _ = (try el.text(ctx, preview, "gl", give_label)).with_style(.{ style.small, Style{ .text = th.dim } });
        _ = (try el.text(ctx, preview, "gv", o.give)).with_style(.{ style.body, Style{ .text = th.fg } });
        _ = (try el.text(ctx, preview, "rl", "You receive")).with_style(.{ style.small, Style{ .text = th.dim } });
        _ = (try el.text(ctx, preview, "rv", o.receive)).with_style(.{ style.body, Style{ .text = th.good } });
        if (o.effect.len > 0)
            _ = (try el.text(ctx, preview, "ef", o.effect)).with_style(.{ style.small, Style{ .text = th.dim } });
    }

    // Column 3: live holdings (the caller's formatted line).
    const hold_col = try el.div(ctx, body, "holdings");
    _ = hold_col.with_flow(.{ .dir = .column }).with_gap(ha.tokens.gap.tight);
    _ = (try el.text(ctx, hold_col, "hl", "Holdings")).with_style(.{ style.small, Style{ .text = th.dim } });
    _ = (try el.text(ctx, hold_col, "hv", holdings)).with_style(.{ style.body, Style{ .text = th.fg } });

    // Footer: the venue note + the CTA (enabled only when a valid offer is selected).
    const footer = try el.div(ctx, box, "footer");
    _ = footer.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.group).with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
    _ = (try el.text(ctx, footer, "note", idn.footer)).with_style(.{ style.small, Style{ .text = th.dim } });

    var confirmed: ?usize = null;
    const can_confirm = selected != null and offers[selected.?].valid();
    const cta = try el.div(ctx, footer, "cta");
    _ = cta.with_layout(.center_right);
    ctx.registerFocus(cta.get().key, can_confirm);
    const cq = cta.query();
    if (cq.clicked and !can_confirm) _ = ctx.consumeFlag(cta.get().key, .clicked);
    if (cq.clicked and can_confirm) {
        _ = ctx.requestFocus(cta.get().key);
        confirmed = selected; // atomic: reported once; the caller performs the exchange
    }
    const cfocused = ctx.isFocused(cta.get().key);
    if (cq.hovering) ctx.res.cursor.request(if (can_confirm) .pointer else .not_allowed);
    uic.publishControlState(ctx, cta.get().key, .{ .disabled = !can_confirm, .focused = cfocused, .focus_visible = cfocused });
    _ = cta.with_flow(.{ .dir = .row }).with_style(.{ style.btn_primary, style.pad_sym(10, 3) });
    _ = (try el.text(ctx, cta, "l", idn.cta)).with_style(.{style.btn_primary});

    // Outside-click / Escape dismissal: consume the box's click, then a root click is outside.
    _ = ctx.consumeFlag(m.box.key, .clicked);
    const dismissed = (El{ .node = m.root, .ctx = ctx }).query().clicked or (El{ .node = m.root, .ctx = ctx }).query().dismissed;

    return .{ .mode = st.mode, .selected = selected, .confirmed = confirmed, .dismissed = dismissed };
}

// ============================ Tests (pure identity map + selection) =====================

test "venue identity map: kicker/title/CTA per venue" {
    try std.testing.expectEqualStrings("A PASSERBY", venueIdentity(.passerby).kicker);
    try std.testing.expectEqualStrings("Deal", venueIdentity(.merchant).cta);
    try std.testing.expectEqualStrings("Bid", venueIdentity(.exchange).buy_give);
    try std.testing.expectEqualStrings("Execute", venueIdentity(.exchange).cta);
}

test "firstValidOffer skips out-of-stock and refused offers" {
    const offers = [_]Offer{
        .{ .give = "a", .receive = "x", .stock = 0 }, // out of stock
        .{ .give = "b", .receive = "y", .refusal = "no" }, // refused
        .{ .give = "c", .receive = "z", .stock = 3 }, // first valid
    };
    try std.testing.expectEqual(@as(usize, 2), firstValidOffer(&offers));
    // All invalid ⇒ falls back to 0.
    const none = [_]Offer{.{ .give = "a", .receive = "x", .stock = 0 }};
    try std.testing.expectEqual(@as(usize, 0), firstValidOffer(&none));
}

test "TradeState keeps per-mode selection separate" {
    var s = TradeState{};
    s.setSel(2); // buy mode selection
    try std.testing.expectEqual(@as(usize, 2), s.buy_sel);
    s.mode = 1;
    s.setSel(4); // sell mode selection
    try std.testing.expectEqual(@as(usize, 4), s.sell_sel);
    try std.testing.expectEqual(@as(usize, 2), s.buy_sel); // buy untouched
    s.mode = 0;
    try std.testing.expectEqual(@as(usize, 2), s.sel()); // back to buy's own selection
}

test "Offer.valid gates on stock and refusal" {
    try std.testing.expect((Offer{ .give = "a", .receive = "b", .stock = 1 }).valid());
    try std.testing.expect(!(Offer{ .give = "a", .receive = "b", .stock = 0 }).valid());
    try std.testing.expect(!(Offer{ .give = "a", .receive = "b", .stock = 1, .refusal = "no" }).valid());
}
