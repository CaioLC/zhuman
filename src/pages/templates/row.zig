//! `row` template — a flowed horizontal container with a default gap. A common layout
//! building block: the caller appends children, which flow left-to-right, spaced by the gap.
//! Children share a common **text baseline** (the default cross-align) so mixed-size text —
//! a heading next to body text — lines up on one writing line. For box-centering instead
//! (e.g. an icon beside a label), pass `.cross = .center` on the flow.

const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const UiCtx = uic.UiCtx;
const El = el.El;

pub fn row(ctx: *UiCtx, parent: anytype, id: []const u8) !El {
    return (try el.div(ctx, parent, id)).with_flow(.{ .dir = .row }).with_gap(16);
}
