//! `dialog_frame` — the one dialog shell every game dialog shares (the prototype's
//! `.terminal-dialog` / `.dialog-shell`): a header with the warn kicker, the title and the ×
//! control, a hairline, the body, a hairline, and the footer band. The trade dialog and the
//! session menu fill the body and the footer; the frame owns only the chrome, so neither
//! hand-rolls a header, a close control, rules or padding.
//!
//! Build order is the visual order, so the body and the footer are created before the caller
//! fills them. Close with `modal.settle` after filling both.

const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = uic.elements.El;

const modal_mod = @import("./modal.zig");

/// The header and footer bands' horizontal padding (`.dialog-header`, `.dialog-footer`: 15px).
pub const pad_x: f32 = 15;
const close_size: f32 = 28;

pub const Options = struct {
    id: []const u8,
    width: f32 = modal_mod.default_width,
    /// The warn line over the title (`PASSERBY · 1.8 DAYS LEFT`, `PAUSED · ACT II · DAY 43`).
    kicker: []const u8,
    /// The dialog's title; also its accessible name.
    title: []const u8,
    /// The × control's accessible name (`Close`, `Resume`).
    close_name: []const u8 = "Close",
    /// A fixed body height, so a dialog whose content changes (rows selling out, screens
    /// swapping) does not resize; null fits the content.
    body_height: ?f32 = null,
};

pub const Frame = struct {
    modal: modal_mod.Modal,
    /// The body column, the dialog's full width; the caller pads its own bands.
    body: El,
    /// The footer band, already padded: a row with its ends spread apart.
    footer: El,
    /// The × was clicked this frame.
    close_clicked: bool,
    /// The × control's key, for a caller that wants initial focus there.
    close_key: u64,
    width: f32,
    /// The width inside a band's horizontal padding.
    inner_width: f32,
};

pub fn dialog_frame(ctx: *UiCtx, opts: Options) !Frame {
    const m = try modal_mod.modal(ctx, opts.id, opts.title, opts.width);
    const inner_width = opts.width - 2 * pad_x;

    // Header: 13px over, 10px under, the kicker over the title on the left and the × on the right.
    // The extra 16px off the fixed width is the engine's text/control overhang at this size.
    const header = try m.box.div("header");
    _ = header.with_size(.{ .fixed = opts.width - 2 * pad_x - 16 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .center })
        .with_style(.{style.pad_each(13, pad_x, 10, pad_x)});
    const heading = try header.div("heading");
    _ = heading.with_flow(.{ .dir = .column, .cross = .start }).with_gap(2);
    _ = (try heading.text("kicker", opts.kicker))
        .with_style(.{ style.small, Style{ .font = 10, .tracking = 0.08, .ink = .warn } });
    _ = (try heading.text("title", opts.title))
        .with_style(.{ style.heading, style.ink(.fg) });

    const close = try header.div("close");
    _ = close.with_size(.{ .fixed = close_size }, .{ .fixed = close_size })
        .with_flow(.{ .dir = .row, .main = .center, .cross = .center });
    _ = close.control(.{ .name = opts.close_name, .role = .icon_button });
    _ = (try close.text("glyph", "\u{00d7}"))
        .with_style(.{Style{ .font = 18, .ink = .dim, .hot = .{ .ink = .acc } }});
    const close_clicked = close.consume(.clicked);
    try modal_mod.rule(m.box, "header_rule", opts.width);

    const body = try m.box.div("body");
    _ = body.with_size(.{ .fixed = opts.width }, if (opts.body_height) |h| .{ .fixed = h } else .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start })
        .with_overflow(.clip);

    try modal_mod.rule(m.box, "footer_rule", opts.width);
    const footer = try m.box.div("footer");
    _ = footer.with_size(.{ .fixed = inner_width }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .center }).with_gap(12)
        .with_style(.{style.pad_sym(pad_x, 9)});

    return .{
        .modal = m,
        .body = body,
        .footer = footer,
        .close_clicked = close_clicked,
        .close_key = close.get().key,
        .width = opts.width,
        .inner_width = inner_width,
    };
}

/// The footer's note (`.dialog-note`): small dim prose, wrapped short of the actions.
pub fn dialog_note(footer: El, id: []const u8, note: []const u8, wrap: f32) !void {
    _ = (try footer.text_fit(id, note, .{ .wrap = wrap }))
        .with_style(.{style.fine_print});
}
