//! `row` template — a flowed horizontal container with a default gap. A common layout
//! building block: the caller appends children, which flow left-to-right, spaced by the gap.
//! Children are **vertically centered** (`.center_left`) so mixed-height content (a heading
//! next to body text, an icon next to a label) shares a common center line.

const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const UiCtx = uic.UiCtx;
const El = el.El;

pub fn row(ctx: *UiCtx, parent: anytype, id: []const u8) !El {
    return (try el.div(ctx, parent, id)).with_align_children(.horizontal, .center_left).with_gap(16);
}
