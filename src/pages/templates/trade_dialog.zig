//! `trade_dialog` — the trade dialog (`trade.html`) on the shared `dialog_frame`: BUY/SELL tabs
//! (and a lot search once a direction holds more lots than a page), a **ledger** of lots on the
//! left and the shared **deal slip** on the right, and a footer that keeps what the visit has
//! moved, the paginator and LEAVE. Every state is derived from the page's `Book`
//! (`trade_book`). Settling does not close the dialog: a visit is one sitting, so the numbers
//! move and the counter stays open. The page settles through its own authority and sets
//! `TradeState.settled` so the slip flashes the new values.
//!
//! The venue's identity map supplies the wording: the kicker, the ledger heads and give-label
//! per direction, and the call to action.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const El = uic.elements.El;
const UiCtx = uic.UiCtx;
const TradeState = uic.UiState.TradeState;
const market = @import("./market_strip.zig");
const modal_mod = @import("./modal.zig");
const frame_mod = @import("./dialog_frame.zig");
const button_mod = @import("./button.zig");
const tabs_mod = @import("./tabs.zig");
const scroll_mod = @import("./scroll_view.zig");
const paginator_mod = @import("./paginator.zig");
const slip_mod = @import("./deal_slip.zig");
const book_mod = @import("./trade_book.zig");

pub const Book = book_mod.Book;
pub const Lot = book_mod.Lot;
pub const Term = book_mod.Term;
pub const Balance = book_mod.Balance;
pub const Delta = book_mod.Delta;
pub const Notation = book_mod.Notation;

/// `.trade-dialog`: 820px.
pub const width: f32 = 820;
/// The ledger and slip's height: fixed, so the dialog does not resize as lots sell out, and
/// tall enough for a full page of lots and the slip (`.trade-body` at its fullest).
const body_h: f32 = 380;
/// Lots a ledger page holds before search and pages appear.
pub const per_page: usize = 7;
const pad_x: f32 = 15;
const price_w: f32 = 92;
const corner_w: f32 = 151;
const col_gap: f32 = 9;
/// The ledger's rows at narrow widths (`@media (max-width: 760px)`): the slip drops under it.
const narrow_rows_h: f32 = 260;

/// The dialog's lanes for this frame: `min(820px, 100vw - 28px)` wide, and at 760 and below
/// one column (the slip under the ledger, no ledger head, the corner on its own line).
const Lanes = struct {
    width: f32,
    narrow: bool,
    ledger_w: f32,

    fn of(ctx: *UiCtx) Lanes {
        const m = ctx.res.view.metrics;
        const narrow = m.width_class.atMost(.w760);
        const w = @min(width, m.terminal.w - 28);
        return .{
            .width = w,
            .narrow = narrow,
            .ledger_w = if (narrow) w else w - slip_mod.width - 1,
        };
    }
};

/// `.ledger-head, .ledger-row { grid-template-columns: minmax(0, 1fr) 92px 151px; gap: 9px }`.
const wide_tracks = [_]uic.Track{
    .{ .basis = .{ .fr = 1 } },
    .{ .basis = .{ .px = price_w } },
    .{ .basis = .{ .px = corner_w } },
};
/// Narrow (`@media (max-width: 760px)`): the lot and the price on line 1, the corner spanning
/// both on line 2. The prototype's price track is `auto` and its row gap 2px; the dialog keeps
/// its fixed 92px price and the 9px line gap it has always drawn.
const narrow_tracks = [_]uic.Track{
    .{ .basis = .{ .fr = 1 } },
    .{ .basis = .{ .px = price_w } },
};
const narrow_row_gap: f32 = col_gap;

/// The ledger's one column set this frame, shared by the head and every row.
fn ledgerTracks(ctx: *UiCtx, ln: Lanes) !*uic.TrackSet {
    return if (ln.narrow)
        uic.tracks_gaps(ctx, &narrow_tracks, col_gap, narrow_row_gap)
    else
        uic.tracks(ctx, &wide_tracks, col_gap);
}

pub const Heads = struct { lot: []const u8, price: []const u8, corner: []const u8 };

pub const VenueIdentity = struct {
    kicker: []const u8,
    title: []const u8,
    buy_head: Heads,
    sell_head: Heads,
    buy_give: []const u8,
    sell_give: []const u8,
    buy_cta: []const u8,
    sell_cta: []const u8,
};

pub fn venueIdentity(kind: market.MarketKind) VenueIdentity {
    return switch (kind) {
        // Act I barters: one CTA, `YOU GIVE` both ways. The merchant prices in coin: the give
        // label and the CTA change with direction.
        .passerby => .{
            .kicker = "PASSERBY",
            .title = "What will you trade?",
            .buy_head = .{ .lot = "THEY OFFER", .price = "YOU GIVE", .corner = "STOCK" },
            .sell_head = .{ .lot = "YOU OFFER", .price = "THEY GIVE", .corner = "YOU HOLD" },
            .buy_give = "YOU GIVE",
            .sell_give = "YOU GIVE",
            .buy_cta = "TRADE \u{2192}",
            .sell_cta = "TRADE \u{2192}",
        },
        .merchant => .{
            .kicker = "MERCHANT",
            .title = "What will you trade?",
            .buy_head = .{ .lot = "THEY OFFER", .price = "PRICE", .corner = "STOCK" },
            .sell_head = .{ .lot = "YOU OFFER", .price = "THEY PAY", .corner = "YOU HOLD" },
            .buy_give = "YOU PAY",
            .sell_give = "YOU GIVE",
            .buy_cta = "BUY \u{2192}",
            .sell_cta = "SELL \u{2192}",
        },
        .exchange => .{
            .kicker = "EXCHANGE",
            .title = "What will the floor clear?",
            .buy_head = .{ .lot = "OFFERED", .price = "BID", .corner = "DEPTH" },
            .sell_head = .{ .lot = "YOU OFFER", .price = "ASK", .corner = "YOU HOLD" },
            .buy_give = "YOU PAY",
            .sell_give = "YOU GIVE",
            .buy_cta = "BUY \u{2192}",
            .sell_cta = "SELL \u{2192}",
        },
    };
}

pub const Settle = struct { id: u32, lots: u32 };

pub const Result = struct {
    /// A lot to settle this frame, and how many lots.
    settle: ?Settle = null,
    dismissed: bool = false,
    /// The dialog's own root, for the page to list after its shell.
    root: *uic.Node,
};

fn modeOf(st: *const TradeState) book_mod.Mode {
    return if (st.mode == 0) .buy else .sell;
}

/// The direction's lots that answer the query, in book order.
fn visible(a: std.mem.Allocator, book: Book, mode: book_mod.Mode, query: []const u8) ![]*const Lot {
    var out: std.ArrayList(*const Lot) = .empty;
    for (book.lots) |*l| {
        if (l.mode != mode) continue;
        if (query.len > 0 and !try book.matches(a, l, query)) continue;
        try out.append(a, l);
    }
    return out.items;
}

/// The first lot of the list the player can take, else the first.
fn firstTakeable(a: std.mem.Allocator, book: Book, list: []const *const Lot) !u32 {
    for (list) |l| if ((try book.refusal(a, l)) == null) return l.id;
    return if (list.len > 0) list[0].id else 0;
}

fn headRow(parent: El, heads: Heads, set: *uic.TrackSet) !void {
    const row = try parent.div("head");
    _ = row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center }).in_tracks(set)
        .with_style(.{style.pad_each(10, pad_x, 7, pad_x)});
    const s = style.eyebrow_dim;
    _ = (try row.text_fit("lot", heads.lot, .{ .cell_fill = .clip })).with_style(.{s});
    _ = (try row.text_fit("price", heads.price, .{ .cell_fill = .clip })).with_style(.{s});
    const corner = try row.div("corner");
    _ = corner.with_size(.fit_children, .fit_children).with_flow(.{ .dir = .row, .main = .end });
    _ = (try corner.text("t", heads.corner)).with_style(.{s});
}

/// One ledger row (`.ledger-row`). Returns its click and key.
fn ledgerRow(parent: El, book: Book, lot: *const Lot, chosen: bool, ln: Lanes, set: *uic.TrackSet) !struct { clicked: bool, key: u64 } {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const a = ctx.arena;
    const refused = try book.refusal(a, lot);
    const row = try parent.item("lot", lot.id);
    _ = row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center }).in_tracks(set)
        .with_style(.{style.pad_each(6, pad_x, 6, pad_x)});
    const q = row.control(.{ .name = lot.lot, .role = .button, .selected = chosen, .value = if (refused) |r| r.short else null });
    const hot = q.hover_focus();
    // Selected: a line2 rule round the row on the panel fill; hover: the fill alone.
    _ = row.with_style(.{Style{ .fill_ink = if (chosen or hot) .panel else .bg, .outline_ink = if (chosen) .line2 else if (chosen or hot) .panel else .bg }});

    const item = try row.div("item");
    _ = item.with_size(.fit_children, .fit_children).with_flow(.{ .dir = .column, .cross = .start }).with_gap(1);
    const lot_ink = if (chosen) th.acc else if (refused != null) th.dim else th.fg;
    _ = (try item.text_fit("lot", lot.lot, .{ .cell_fill = .ellipsis })).with_style(.{Style{ .font = 13, .text = lot_ink }});
    _ = (try item.text_fit("sub", try book.subLine(a, lot), .{ .cell_fill = .ellipsis })).with_style(.{style.caption_faint});

    _ = (try row.text_fit("price", try book.fmtShort(a, Book.counterpart(lot)), .{ .cell_fill = .clip }))
        .with_style(.{Style{ .font = 12, .ink = if (refused != null) .line2 else .fg }});

    // Narrow, the corner takes its own line under the lot (`.row-corner { grid-column: 1 / -1 }`).
    const corner = try row.div("corner");
    _ = corner.with_size(.fit_children, .fit_children).with_flow(.{ .dir = .row, .main = if (ln.narrow) .start else .end });
    if (ln.narrow) _ = corner.at_track(0, El.all_tracks);
    if (refused) |r| {
        _ = (try corner.text("t", r.short)).with_style(.{Style{ .font = 10, .ink = .danger }});
    } else {
        _ = (try corner.text("t", try book.lotsCorner(a, lot))).with_style(.{style.caption});
    }
    return .{ .clicked = q.clicked, .key = row.get().key };
}

/// `THIS VISIT −5 coin · +6 water`, or `THIS VISIT nothing traded yet`.
fn visitLedger(parent: El, visit: []const Delta) !void {
    const ctx = parent.ctx;
    const row = try parent.div("visit");
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(9);
    _ = (try row.text("label", "THIS VISIT")).with_style(.{style.eyebrow_dim});
    var any = false;
    for (visit) |d| if (@abs(d.n) > 0.001) {
        any = true;
    };
    if (!any) {
        _ = (try row.text("none", "nothing traded yet")).with_style(.{style.caption_faint});
        return;
    }
    const deltas = try row.div("deltas");
    _ = deltas.with_flow(.{ .dir = .row, .cross = .center });
    var first = true;
    for (visit, 0..) |d, i| {
        if (@abs(d.n) <= 0.001) continue;
        const cell = try deltas.item("d", i);
        _ = cell.with_flow(.{ .dir = .row, .cross = .center });
        if (!first) _ = (try cell.text("sep", " \u{00b7} ")).with_style(.{Style{ .font = 10, .ink = .fg }});
        first = false;
        const sign = if (d.n < 0) "\u{2212}" else "+";
        const text = try ctx.arena.print("{s}{s} {s}", .{ sign, try book_mod.fmtNum(ctx.arena, @abs(d.n)), d.key });
        _ = (try cell.text("t", text)).with_style(.{Style{ .font = 10, .ink = if (d.n < 0) .warn else .good }});
    }
}

pub fn trade_dialog(ctx: *UiCtx, id: []const u8, kind: market.MarketKind, meta: []const u8, book: Book, visit: []const Delta, st: *TradeState) !Result {
    const th = ctx.res.view.theme;
    const a = ctx.arena;
    const identity = venueIdentity(kind);
    const ln = Lanes.of(ctx);
    const frame = try frame_mod.dialog_frame(ctx, .{
        .id = id,
        .width = ln.width,
        .kicker = try a.print("{s} \u{00b7} {s}", .{ identity.kicker, meta }),
        .title = identity.title,
    });

    // A fresh open starts on BUY with the first lot that can be taken, as the prototype does.
    if (frame.modal.first_open) {
        st.mode = 0;
        st.page = 0;
        st.lots = 1;
        st.selected = try firstTakeable(a, book, try visible(a, book, .buy, ""));
    }

    // --- tabs, and the lot search once a direction is busy --------------------------------
    const tab_band = try frame.body.div("tab_band");
    _ = tab_band.with_size(.{ .fixed = frame.inner_width }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center }).with_gap(7)
        .with_style(.{style.pad_each(9, pad_x, 0, pad_x)});
    const previous_mode = st.mode;
    _ = try tabs_mod.tabs_named(tab_band, "modes", "Trade direction", &.{ "BUY", "SELL" }, &st.mode);
    const mode = modeOf(st);
    var in_mode: usize = 0;
    for (book.lots) |l| in_mode += @intFromBool(l.mode == mode);
    const busy = in_mode > per_page;

    // The search editor lives on the dialog box, so a reopened dialog starts clear.
    var query: []const u8 = "";
    const editor = frame.modal.box.state(uic.UiState.TextInputState);
    if (busy or editor.len > 0) {
        const field = try uic.text_input_look(tab_band, "search", "search lots", 80, frame.modal.box, .{ .font = 10, .placeholder = th.line2 });
        _ = field.with_size(.grow, .fit_children);
        query = frame.modal.box.state(uic.UiState.TextInputState).text();
    }

    const list = try visible(a, book, mode, query);
    // A chosen lot from the other direction (the tab set from outside the strip) is no choice.
    var chosen_here = false;
    for (book.lots) |l| chosen_here = chosen_here or (l.id == st.selected and l.mode == mode);
    if (st.mode != previous_mode or (st.selected != 0 and !chosen_here)) {
        // Switching direction takes the first lot that can be taken, at one lot, page one.
        st.selected = try firstTakeable(a, book, list);
        st.lots = 1;
        st.page = 0;
    }
    const n_pages = paginator_mod.pages(list.len, per_page);
    if (st.page >= n_pages) st.page = @intCast(n_pages - 1);

    // --- the ledger | the slip ------------------------------------------------------------
    const trade_body = try frame.body.div("trade_body");
    _ = trade_body.with_size(.{ .fixed = ln.width }, .{ .fixed = if (ln.narrow) narrow_rows_h + 1 + body_h else body_h })
        .with_flow(.{ .dir = if (ln.narrow) .column else .row, .cross = .start });

    const ledger = try trade_body.div("ledger");
    _ = ledger.with_size(.{ .fixed = ln.ledger_w }, if (ln.narrow) .{ .fixed = narrow_rows_h } else .{ .pct_of_parent = 1.0 })
        .with_flow(.{ .dir = .column, .cross = .start });
    // One column set for the head and every row (`grid-template-columns` on both): the ledger
    // is their common ancestor, the rows sitting in the scroll view's content below it.
    const set = try ledgerTracks(ctx, ln);
    _ = ledger.with_tracks(set);
    if (!ln.narrow) try headRow(ledger, if (mode == .buy) identity.buy_head else identity.sell_head, set);
    const rows_area = try ledger.div("rows_area");
    _ = rows_area.with_size(.{ .pct_of_parent = 1.0 }, .grow);
    // Narrow, the rows get their height outright: a parent-high scroll view takes its content's
    // height on a stacked page, and the dialog's rows must still scroll in their own box.
    const rows = try scroll_mod.scroll_view(rows_area, "rows", .{ .height = if (ln.narrow) narrow_rows_h else 0, .framed = false, .gap = 0, .name = "lots" }, null);

    var first_row: ?u64 = null;
    if (list.len == 0) {
        const msg = if (query.len > 0) "No lot matches that search." else "Nothing to offer in this direction.";
        _ = (try rows.content.text("empty", msg)).with_style(.{ style.note, style.pad_sym(pad_x, 14) });
    } else {
        const start = @as(usize, st.page) * per_page;
        const end = @min(list.len, start + per_page);
        for (list[start..end]) |l| {
            const r = try ledgerRow(rows.content, book, l, st.selected == l.id, ln, set);
            if (first_row == null) first_row = r.key;
            if (r.clicked) {
                st.selected = if (st.selected == l.id) 0 else l.id;
                st.lots = 1;
            }
        }
    }

    _ = (try trade_body.div("divider")).with_size(if (ln.narrow) .{ .fixed = ln.width } else .{ .fixed = 1 }, if (ln.narrow) .{ .fixed = 1 } else .{ .pct_of_parent = 1.0 })
        .with_style(.{style.rule_fill});

    const chosen = book.byId(st.selected);
    const slip = try slip_mod.deal_slip(trade_body, "slip", book, chosen, st.lots, .{
        .give_label = if (mode == .buy) identity.buy_give else identity.sell_give,
        .cta = if (mode == .buy) identity.buy_cta else identity.sell_cta,
        .flash = st.settled,
        .height = body_h,
    });
    st.settled = false;
    st.lots = slip.lots;

    // --- footer: the visit ledger, then the paginator and LEAVE ---------------------------
    try visitLedger(frame.footer, visit);
    const actions = try frame.footer.div("actions");
    _ = actions.with_flow(.{ .dir = .row, .cross = .center }).with_gap(10);
    if (busy) st.page = @intCast(try paginator_mod.paginator(actions, "pages", st.page, list.len, per_page));
    const leave = try button_mod.button_variant(actions, "leave", "LEAVE", true, .secondary);

    const settle: ?Settle = if (slip.settle and chosen != null) .{ .id = chosen.?.id, .lots = slip.lots } else null;
    return .{
        .settle = settle,
        // Open on the offers, not on the close control.
        .dismissed = modal_mod.dismissed(ctx, frame.modal, frame.close_clicked or leave.consume(.clicked), first_row),
        .root = frame.modal.root,
    };
}

test "venue identity map matches the authored trade chrome" {
    try std.testing.expectEqualStrings("PASSERBY", venueIdentity(.passerby).kicker);
    try std.testing.expectEqualStrings("TRADE \u{2192}", venueIdentity(.passerby).sell_cta);
    try std.testing.expectEqualStrings("YOU GIVE", venueIdentity(.passerby).buy_head.price);
    try std.testing.expectEqualStrings("YOU PAY", venueIdentity(.merchant).buy_give);
    try std.testing.expectEqualStrings("THEY PAY", venueIdentity(.merchant).sell_head.price);
    try std.testing.expectEqualStrings("SELL \u{2192}", venueIdentity(.merchant).sell_cta);
}

test "the ledger's tracks fill its width, wide and narrow" {
    var auto_max: [3]f32 = undefined;
    var widths: [3]f32 = undefined;
    // Wide: the ledger beside the slip, its rows' content box inside the 15px padding.
    var wide: uic.TrackSet = .{ .tracks = &wide_tracks, .col_gap = col_gap, .auto_max = &auto_max, .widths = &widths };
    @memset(wide.auto_max, 0);
    const ledger_inner = width - slip_mod.width - 1 - 2 * pad_x;
    wide.solve(ledger_inner);
    try std.testing.expect(widths[0] > 0);
    try std.testing.expectEqual(price_w, widths[1]);
    try std.testing.expectEqual(corner_w, widths[2]);
    try std.testing.expectApproxEqAbs(ledger_inner, widths[0] + widths[1] + widths[2] + 2 * col_gap, 1e-3);

    // Narrow at 560: the rows are the scroll view's width less its gutter; the lot and the
    // price fill line 1, and the corner's span (both tracks and the gap) is the whole line.
    var narrow: uic.TrackSet = .{ .tracks = &narrow_tracks, .col_gap = col_gap, .row_gap = narrow_row_gap, .auto_max = auto_max[0..2], .widths = widths[0..2] };
    @memset(narrow.auto_max, 0);
    const narrow_inner = (560 - 28) - 2 * pad_x - scroll_mod.scrollbar_w;
    narrow.solve(narrow_inner);
    try std.testing.expectEqual(price_w, widths[1]);
    try std.testing.expectApproxEqAbs(narrow_inner, widths[0] + col_gap + widths[1], 1e-3);
}
