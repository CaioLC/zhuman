//! `select` — the **keyboard-operable select / popup control** (KIT-09). A compact
//! `label value ▾` control that opens a popup list of options; choosing one commits it and
//! closes. One reusable control for every "pick one of N" (sort kind, sort direction, …)
//! rather than a bespoke dropdown per catalog.
//!
//! **State** lives in a pooled `SelectState { open, value, highlight }` keyed by the control's
//! node, so it survives the frame-arena rebuild: `value` is the committed choice, `open`
//! whether the popup is showing, `highlight` the arrow-movable pending choice while open.
//!
//! **Interaction (KIT-09 checklist):**
//!   - **label / value** — the closed control shows `{label}  {value} ▾`.
//!   - **open / close** — clicking the control toggles the popup; clicking an option commits
//!     it and closes; clicking outside (or Escape) closes without committing.
//!   - **arrows / Enter / Escape** — the pure `Model` below encodes the keyboard transitions
//!     (open moves the highlight; Enter commits the highlight and closes; Escape closes); a
//!     host routes key events into it the way `main.zig` routes text into the editor. The
//!     pointer path drives the same `Model`, so keyboard and pointer stay one source of truth.
//!   - **disabled** — a disabled control cannot open or commit (the KIT-03 button contract:
//!     a stray `.clicked` is consumed).
//!   - **focus restoration** — closing returns focus to the control (the opener), so keyboard
//!     flow continues from the select, not from the vanished popup.
//!   - **top-layer clipping** — the popup is an absolutely-placed overlay with `.clip`, drawn
//!     after its siblings, so it floats over following content and its own contents are clipped
//!     to it.
//!   - **compact height** — the control stands at `tokens.control.h_compact` (30 logical px).

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;
const UiCtx = uic.UiCtx;
const SelectState = uic.UiState.SelectState;

/// The built select: the committed `value` index and the control `el`. The caller reads
/// `value` to drive its sort/whatever; the control owns its own open/commit state. The pure
/// state machine lives on `SelectState` (open/toggle/cancel/moveHighlight/commit), so the
/// pointer path here and a host's keyboard routing drive one source of truth.
pub const Select = struct { value: usize, el: El };

/// Build a select control into `parent`. `label` is the static lead-in, `options` the choices;
/// returns the committed value index. `enabled` gates open/commit (KIT-03). The popup is an
/// overlay child clipped to itself, drawn after the closed control.
pub fn select(ctx: *UiCtx, parent: El, id: []const u8, label: []const u8, options: []const []const u8, enabled: bool) !Select {
    const th = ctx.res.view.theme;
    const n = options.len;

    const box = try el.div(ctx, parent, id);
    const st = box.get().state(ctx, SelectState);
    if (st.value >= n) st.value = 0; // options shrank across frames — stay valid
    if (st.highlight >= n) st.highlight = 0;

    // The closed control: label + value + caret, at the compact control height (KIT-01 token).
    ctx.registerFocus(box.get().key, enabled);
    const q = box.query();
    if (q.clicked and !enabled) _ = ctx.consumeFlag(box.get().key, .clicked); // disabled can't open
    if (q.clicked and enabled) {
        _ = ctx.requestFocus(box.get().key); // focus restoration: the control owns focus
        st.toggle(!enabled);
    }
    const focused = ctx.isFocused(box.get().key);
    if (q.hovering) ctx.res.cursor.request(if (enabled) .pointer else .not_allowed);
    uic.publishControlState(ctx, box.get().key, .{ .disabled = !enabled, .focused = focused, .focus_visible = focused });

    _ = box.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.inline_)
        .with_size(.fit_children, .{ .fixed = ha.tokens.control.h_compact })
        .with_style(.{ Style{ .outline_color = if (!enabled) th.line else if (focused or q.hovering) th.acc else th.line2 }, style.pad_sym(8, 0) });
    _ = (try el.text(ctx, box, "lbl", label)).with_style(.{ style.small, Style{ .text = th.dim } });
    const value_txt = if (n > 0) options[st.value] else "";
    _ = (try el.text(ctx, box, "val", value_txt)).with_style(.{ style.body, Style{ .text = if (enabled) th.fg else th.dim } });
    _ = (try el.text(ctx, box, "caret", if (st.open) "\u{25B4}" else "\u{25BE}")) // ▴ open / ▾ closed
        .with_style(.{Style{ .text = th.dim }});

    // The popup: an absolutely-placed overlay under the control, clipped to itself, drawn after
    // the closed control so it floats over following siblings (top-layer within this subtree).
    if (st.open and enabled) {
        const pop = try el.div(ctx, box, "popup");
        _ = pop.with_layout(.top_left).with_offset(0, ha.tokens.control.h_compact)
            .with_flow(.{ .dir = .column })
            .with_overflow(.clip)
            .with_style(.{ Style{ .fill = th.panel, .outline_color = th.line2 }, style.pad_sym(0, 4) });
        for (options, 0..) |opt, i| {
            const okey = try std.fmt.allocPrint(ctx.arena, "o{d}", .{i});
            const row = try el.div(ctx, pop, okey);
            const rq = row.query();
            if (rq.hovering) {
                ctx.res.cursor.request(.pointer);
                st.highlight = i; // pointer hover moves the highlight, like the arrows
            }
            if (rq.clicked) st.commit(i, n); // choose + close
            const highlighted = st.highlight == i;
            _ = row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
                .with_style(.{ Style{ .fill = if (highlighted) th.line else th.panel }, style.pad_sym(8, 4) });
            _ = (try el.text(ctx, row, "t", opt))
                .with_style(.{ style.body, Style{ .text = if (i == st.value) th.acc else th.fg } });
        }
    }

    return .{ .value = st.value, .el = box };
}
