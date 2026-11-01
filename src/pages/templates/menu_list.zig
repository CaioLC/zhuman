//! `menu_list` — the shared menu list (`.menu`, `.menu-item`): the title screen's and the
//! session menu's one column of large text rows. Each row is one button: a `›` mark (invisible
//! at rest, accent on hover or focus), the label (dim at rest, fg on hover or focus) and, on a
//! disabled row, the reason it is disabled (`.menu-why`), because a hidden control teaches
//! nothing and a grey one without a reason only half does.

const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const El = uic.elements.El;

pub const Item = struct {
    /// Stable node id.
    id: []const u8,
    label: []const u8,
    enabled: bool = true,
    /// Why the row is disabled, shown beside it.
    why: []const u8 = "",
};

pub const Options = struct {
    /// The label size: 17px on the title screen, 16px inside a dialog.
    font: f32 = 17,
    /// Space above the list (`.menu`'s 30px under the wordmark; none inside a dialog).
    top: f32 = 30,
};

pub const Result = struct {
    /// The row activated this frame.
    clicked: ?usize,
    /// The first row's key, for a dialog's initial focus.
    first_key: ?u64,
};

/// A row's `›` mark: the ground colour at rest (invisible, holding its lane), accent on hover
/// or visible focus. A disabled row never lifts.
pub const mark_look = Style{ .ink = .bg, .on = &.{.{ .when = .hover_focus, .ink = .acc }} };
/// A row's label: dim at rest, fg on hover or visible focus, line2 while disabled.
pub const label_look = Style{ .ink = .dim, .on = &.{ .{ .when = .hover_focus, .ink = .fg }, .{ .when = .disabled, .ink = .line2 } } };

pub fn menu_list(parent: El, id: []const u8, items: []const Item, opts: Options) !Result {
    const list = try parent.box(id, .{
        .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start }, .gap = 1,
    }, .{style.pad_each(opts.top, 0, 0, 0)});

    var clicked: ?usize = null;
    var first_key: ?u64 = null;
    for (items, 0..) |item, i| {
        const row = try list.box(item.id, .{
            .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center }, .gap = 14,
        }, .{style.pad_sym(0, 5)});
        const q = row.control(.{ .enabled = item.enabled, .name = item.label, .role = .button, .ring = false });
        if (first_key == null) first_key = row.get().key;
        if (q.clicked) clicked = i;

        // The mark keeps its 2ch lane at rest, drawn in the ground colour, so labels align.
        try row.label_fit("mark", "\u{203a}", .{ .cell = .{ .mode = .clip, .width = 2 * 0.6 * opts.font } }, .{ Style{ .font = opts.font }, mark_look });
        try row.label("label", item.label, .{ Style{ .font = opts.font, .tracking = -0.02 }, label_look });
        if (!item.enabled and item.why.len > 0) {
            try row.label("why", item.why, .{Style{ .font = 10, .tracking = 0.06, .ink = .line2 }});
        }
    }
    return .{ .clicked = clicked, .first_key = first_key };
}
