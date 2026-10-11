//! `modal_body` — BUY/SELL tabs plus the three trade segments: stock, transfer preview, holdings.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const TradeState = uic.UiState.TradeState;
const modal_mod = @import("./modal.zig");

pub const Offer = struct {
    /// The quote's own id. It keys the offer's row, so the row keeps its identity (hover, focus,
    /// the selection outline) when the list changes around it; a position would not.
    id: usize,
    name: []const u8 = "",
    detail: []const u8 = "",
    give: []const u8,
    receive: []const u8,
    effect: []const u8 = "",
    stock: u32 = 1,
    refusal: []const u8 = "",

    pub fn valid(self: Offer) bool {
        return self.stock > 0 and self.refusal.len == 0;
    }
};

pub const Holding = struct { label: []const u8, value: []const u8 };

pub const Result = struct {
    mode: usize,
    selected: ?usize,
    can_confirm: bool,
};

pub fn firstValidOffer(offers: []const Offer) usize {
    for (offers, 0..) |offer, i| if (offer.valid()) return i;
    return 0;
}

pub fn modal_body(parent: El, width: f32, buy_give: []const u8, sell_give: []const u8, buy_offers: []const Offer, sell_offers: []const Offer, holdings: []const Holding, st: *TradeState) !Result {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const inner_width = width - 30; // body/tab bands have 15px horizontal padding
    const tab_band = try parent.div("tab_band");
    _ = tab_band.with_size(.{ .fixed = inner_width }, .fit_children).with_style(.{style.pad_each(9, 15, 0, 15)});
    // The trade state owns the mode; the strip is controlled by it, so there is one value.
    const previous_mode = st.mode;
    _ = try (@import("./tabs.zig")).tabs(tab_band, "modes", &.{ "BUY", "SELL" }, &st.mode);
    if (st.mode != previous_mode) {
        const switched = if (st.mode == 0) buy_offers else sell_offers;
        if (st.sel() >= switched.len or !switched[st.sel()].valid()) st.setSel(firstValidOffer(switched));
    }
    const offers = if (st.mode == 0) buy_offers else sell_offers;

    const band = try parent.div("body_band");
    _ = band.with_size(.{ .fixed = inner_width }, .fit_children).with_style(.{style.pad_each(12, 15, 14, 15)});
    const body = try band.div("body");
    _ = body.with_flow(.{ .dir = .row, .cross = .start }).with_gap(14);

    const stock = try body.div("stock");
    _ = stock.with_size(.{ .fixed = 220 }, .fit_children).with_flow(.{ .dir = .column, .cross = .start }).with_gap(5);
    _ = (try stock.text("heading", "THEIR STOCK")).with_style(.{ style.eyebrow, Style{ .text = th.dim } });
    for (offers, 0..) |offer, i| {
        const row = try stock.item("of", offer.id);
        _ = row.with_size(.{ .fixed = 204 }, .fit_children) // 220px border-box minus 8px side padding
            .with_flow(.{ .dir = .row, .main = .space_between, .cross = .start })
            .with_style(.{style.pad_sym(8, 7)});
        const enabled = offer.valid();
        const name = if (offer.name.len > 0) offer.name else if (st.mode == 0) offer.receive else offer.give;
        const detail = if (offer.detail.len > 0) offer.detail else if (offer.refusal.len > 0) offer.refusal else if (st.mode == 0) "available stock" else "your spare stock";
        // Select on the click before the lifecycle publishes `selected`, so it is current.
        if (enabled and row.query().clicked) st.setSel(i);
        const chosen = st.sel() == i;
        const q = row.control(.{ .enabled = enabled, .name = name, .role = .button, .selected = chosen });
        _ = row.with_style(.{Style{ .outline_color = if (chosen) th.warn else if (q.hovering or q.focused) th.dim else th.line }});
        const copy = try row.div("copy");
        _ = copy.with_flow(.{ .dir = .column, .cross = .start }).with_gap(2);
        _ = (try copy.text("name", name)).with_style(.{ style.body, Style{ .text = if (enabled) th.fg else th.dim } });
        _ = (try copy.text("detail", detail)).with_style(.{Style{ .font = 9, .text = if (enabled) th.line2 else th.danger }});
        _ = (try row.text("count", try std.fmt.allocPrint(ctx.arena, "\u{00d7}{d}", .{offer.stock})))
            .with_style(.{Style{ .font = 10, .text = th.dim }});
    }

    const selected: ?usize = if (offers.len == 0) null else @min(st.sel(), offers.len - 1);
    const preview = try body.div("preview");
    _ = preview.with_size(.{ .fixed = 170 }, .{ .fixed = 190 }) // 190×210 border-box minus 10px padding
        .with_flow(.{ .dir = .column, .cross = .start }).with_gap(9)
        .with_style(.{ Style{ .outline_color = th.line2 }, style.pad(10) });
    if (selected) |si| {
        const offer = offers[si];
        _ = (try preview.text("give_label", if (st.mode == 0) buy_give else sell_give)).with_style(.{Style{ .font = 10, .text = th.dim }});
        _ = (try preview.text("give", offer.give)).with_style(.{ style.body, Style{ .text = th.fg } });
        const arrow = try preview.div("arrow_row");
        _ = arrow.with_size(.{ .pct_of_parent = 1 }, .fit_children).with_flow(.{ .dir = .row, .main = .center });
        _ = (try arrow.text("arrow", "\u{21c4}")).with_style(.{Style{ .font = 20, .text = th.warn }});
        _ = (try preview.text("receive_label", "YOU RECEIVE")).with_style(.{Style{ .font = 10, .text = th.dim }});
        _ = (try preview.text("receive", offer.receive)).with_style(.{ style.body, Style{ .text = th.fg } });
        if (offer.effect.len > 0) {
            try modal_mod.rule(preview, "effect_rule", 168);
            _ = (try preview.text_fit("effect", offer.effect, .{ .wrap = 168 })).with_style(.{Style{ .font = 10, .text = th.warn }});
        }
    }

    const hold_width: f32 = 208;
    const hold = try body.div("holdings");
    _ = hold.with_size(.{ .fixed = hold_width }, .fit_children).with_flow(.{ .dir = .column, .cross = .start }).with_gap(3);
    _ = (try hold.text("heading", "YOU HOLD")).with_style(.{ style.eyebrow, Style{ .text = th.dim } });
    for (holdings, 0..) |holding, i| {
        const row = try hold.item("h", i);
        _ = row.with_size(.{ .fixed = hold_width - 2 }, .fit_children) // subtract 1px side padding
            .with_flow(.{ .dir = .row, .main = .space_between, .cross = .center })
            .with_style(.{style.pad_each(4, 1, 4, 1)});
        _ = (try row.text("label", holding.label)).with_style(.{ style.small, Style{ .text = th.dim } });
        _ = (try row.text("value", holding.value)).with_style(.{ style.small, Style{ .text = th.fg } });
        _ = (try hold.item("hr", i)).with_size(.{ .fixed = hold_width }, .{ .fixed = 1 }).with_style(.{Style{ .fill = th.line }});
    }
    _ = (try hold.text_fit("side_note", "The preview is final: payment, replacement, and remaining stock are visible before exchange.", .{ .wrap = hold_width - 20 }))
        .with_style(.{ style.small, Style{ .text = th.dim }, style.pad_each(9, 10, 0, 10) });

    return .{ .mode = st.mode, .selected = selected, .can_confirm = selected != null and offers[selected.?].valid() };
}

test "firstValidOffer skips unavailable offers" {
    const offers = [_]Offer{
        .{ .id = 1, .give = "a", .receive = "x", .stock = 0 },
        .{ .id = 2, .give = "b", .receive = "y", .refusal = "no" },
        .{ .id = 3, .give = "c", .receive = "z", .stock = 3 },
    };
    try std.testing.expectEqual(@as(usize, 2), firstValidOffer(&offers));
}
