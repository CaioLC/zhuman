//! `deal_slip` — THE DEAL (`.slip`), shared by the trade dialog and the neighbours view: the
//! chosen lot, a `LOTS − n + of {max}` stepper, what you give and what you receive scaled by the
//! lots, the before → after of every stock the deal touches, the consequence, and the one
//! call to action. A lot that cannot be taken shows its long refusal and `CANNOT TRADE`. After
//! a settlement the AFTER values flash warn and settle back (not under reduced motion).
//!
//! It fills its parent's height: the call to action sits at the slip's foot.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const El = uic.elements.El;

const book_mod = @import("./trade_book.zig");
const stepper_mod = @import("./quantity_stepper.zig");
const Book = book_mod.Book;
const Lot = book_mod.Lot;

pub const width: f32 = 250;
const pad_x: f32 = 15;
const inner: f32 = width - 2 * pad_x;
const flash_s: f32 = 0.7;

pub const Options = struct {
    /// `YOU GIVE` / `YOU PAY` for this direction.
    give_label: []const u8,
    /// `TRADE →`, `BUY →`, `SELL →`.
    cta: []const u8,
    /// A settlement landed last frame: flash the AFTER values once.
    flash: bool = false,
    /// The slip's outer height (its parent's); the call to action sits at its foot.
    height: f32,
};

pub const Result = struct {
    /// The slip's lot count after this frame's stepper clicks.
    lots: u32,
    /// The call to action was activated on a takeable lot.
    settle: bool,
    /// The call to action's key, for the dialog's focus order.
    cta_key: ?u64,
};

fn label(parent: El, id: []const u8, text: []const u8) !void {
    try parent.label(id, text, .{style.eyebrow_dim});
}

fn hrule(parent: El, id: []const u8) !void {
    try parent.leaf(id, .{ .w = .{ .fixed = inner }, .h = .{ .fixed = 1 } }, .{style.rule_fill});
}

/// The slip's full-width call to action (`.primary-action.slip-action`).
fn action(parent: El, text: []const u8, enabled: bool) !struct { clicked: bool, key: u64 } {
    const th = parent.ctx.res.view.theme;
    const b = try parent.box("cta", .{
        .w = .{ .fixed = inner }, .h = .fit_children,
        .flow = .{ .dir = .row, .main = .center, .cross = .center },
    }, .{});
    const q = b.control(.{ .enabled = enabled, .name = text, .role = .button, .ring = false });
    const lit = enabled and (q.hot());
    const line = if (!enabled) th.line else if (lit) th.acc else th.fg;
    const ink = if (!enabled) th.line2 else if (lit) th.acc else th.fg;
    b.set(.{}, .{Style{ .outline_color = line }});
    try b.label("lbl", text, .{ style.body, Style{ .text = ink }, style.pad_sym(8, 7) });
    return .{ .clicked = enabled and q.clicked, .key = b.get().key };
}

pub fn deal_slip(parent: El, id: []const u8, book: Book, lot: ?*const Lot, lots: u32, opts: Options) !Result {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const a = ctx.arena;

    const slip = try parent.div(id);
    // Fixed sizes are content boxes: the authored 10px/13px padding comes off the height.
    slip.set(.{
        .w = .{ .fixed = inner }, .h = .{ .fixed = opts.height - 10 - 13 },
        .flow = .{ .dir = .column, .cross = .start }, .gap = 10,
    }, .{style.pad_each(10, pad_x, 13, pad_x)});
    try slip.label("heading", "THE DEAL", .{ style.eyebrow, style.muted });

    const l = lot orelse {
        try slip.label_fit("placeholder", "Pick a lot on the left.", .fill, .{style.note});
        return .{ .lots = lots, .settle = false, .cta_key = null };
    };

    const refused = try book.refusal(a, l);
    const max = book.maxLots(l);
    var n = std.math.clamp(lots, 1, @max(1, max));

    // The wrapped texts below fill their parent's width, so each parent column takes the
    // slip's content width (a fitted column would leave them one line wide).
    const head = try slip.box("lot", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
        .gap = 3,
    }, .{});
    try head.label_fit("name", l.lot, .fill, .{Style{ .font = 14, .ink = .fg }});
    try head.label_fit("effect", l.effect, .fill, .{style.caption});

    if (refused) |r| {
        try slip.label_fit("refusal", r.long, .fill, .{Style{ .font = 11, .ink = .danger }});
    } else {
        // LOTS − n + of {max}, between two rules.
        try hrule(slip, "qty_top");
        const qty = try slip.box("qty", .{
            .w = .{ .fixed = inner }, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center },
            .gap = 8,
        }, .{});
        try label(qty, "label", "LOTS");
        n = try stepper_mod.quantity_stepper(qty, "stepper", n, 1, @max(1, max), .{ .less = "One lot fewer", .more = "One lot more" });
        const fill = try qty.box("fill", .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .row, .main = .end } }, .{});
        try fill.label("max", try a.print("of {d}", .{max}), .{style.caption});
        try hrule(slip, "qty_bottom");

        // YOU GIVE / YOU RECEIVE.
        const terms = try slip.box("terms", .{
            .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
            .gap = 7,
        }, .{});
        inline for (.{ .{ "give", true }, .{ "get", false } }) |side| {
            const giving = side[1];
            const term = try terms.box(side[0], .{
                .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children,
                .flow = .{ .dir = .column, .cross = .start }, .gap = 2,
            }, .{});
            try label(term, "dt", if (giving) opts.give_label else "YOU RECEIVE");
            const text = try Book.fmtLong(a, if (giving) l.price else l.receive, n, !giving);
            try term.label_fit("dd", text, .fill, .{Style{ .font = 13, .ink = .fg }});
        }

        // AFTER: before → after on only the stocks the deal touches.
        try hrule(slip, "after_rule");
        const after = try slip.box("after", .{
            .w = .{ .fixed = inner }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
            .gap = 3,
        }, .{});
        try label(after, "head", "AFTER");
        for (try book.after(a, l, n), 0..) |row, i| {
            const r = try after.boxi("row", i, .{
                .w = .{ .fixed = inner }, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center },
                .gap = 5,
            }, .{});
            const key_box = try r.box("key", .{ .w = .grow, .h = .fit_children }, .{});
            try key_box.label_fit("k", try std.ascii.allocUpperString(a, row.key), .{ .cell = .{ .mode = .ellipsis, .width = inner - 90 } }, .{Style{ .font = 12, .tracking = 0.04, .ink = .dim }});
            try r.label("from", try book_mod.fmtNum(a, row.before), .{Style{ .font = 12, .ink = .line2 }});
            try r.label("arrow", "\u{2192}", .{Style{ .font = 12, .ink = .line2 }});
            const to = try r.text("to", try book_mod.fmtNum(a, row.after));
            const target = if (row.after < 0) th.danger else switch (row.sign()) {
                .down => th.warn,
                .up => th.good,
                .flat => th.fg,
            };
            // The flash: a fresh settlement starts each value at warn and eases to its tone.
            const key = to.get().key;
            if (opts.flash) ctx.res.tween.from(key, 0, 1, flash_s);
            const t = ctx.res.tween.value(key, 1);
            to.set(.{}, .{Style{ .font = 12, .text = uic.mix(th.warn, target, t) }});
        }
    }
    if (refused == null and l.consequence.len > 0) {
        try slip.label_fit("consequence", l.consequence, .fill, .{Style{ .font = 10, .ink = .acc }});
    }

    // The call to action sits at the slip's foot (`.slip-action { margin-top: auto }`).
    try slip.leaf("push", .{ .w = .{ .fixed = 1 }, .h = .grow }, .{});
    const cta = try action(slip, if (refused != null) "CANNOT TRADE" else opts.cta, refused == null and max > 0);
    return .{ .lots = n, .settle = cta.clicked, .cta_key = cta.key };
}
