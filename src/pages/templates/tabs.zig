//! `tabs` template — a row of text chips switching which content the caller builds:
//! the active label wears fg + its outline, inactive ones sit dim; any chip lifts to accent
//! on hover/held/focus (the active tab included, mirroring `button`).
//! Body-sized on purpose — tabs are navigation chrome, not content; they should read as
//! the top edge of the panel they switch, not compete with it (the caller left-aligns
//! the strip over the content for the classic tab silhouette). Returns the active index;
//! the *caller* branches on it and builds that tab's subtree — the template owns only
//! the strip. The selection persists in the strip node's own pooled `TabsState` (the
//! `ScrollState` pattern), so it survives the frame-arena reset without touching
//! `Resources`. A click lands before the chrome reads the selection, so the switch
//! renders the same frame.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const TabsState = uic.UiState.TabsState;

pub const Tabs = struct { el: El, active: usize };

pub fn tabs(parent: El, id: []const u8, labels: []const []const u8) !Tabs {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;

    const bar = try parent.div(id);
    _ = bar.with_flow(.{ .dir = .row }).with_gap(10);
    const bar_key = bar.get().key;

    const st = bar.state(TabsState);
    if (st.active >= labels.len) st.active = 0; // labels shrank across frames — stay valid

    // INPUT-08: collect the member keys in paint order for the group's `controls` links.
    var member_keys: [uic.semantic.max_relations]u64 = undefined;
    var member_len: usize = 0;

    for (labels, 0..) |label, i| {
        const chip = try bar.item("tab", i);
        const chip_key = chip.get().key;
        // Switch on the click before the lifecycle publishes `selected`, so it is current.
        if (chip.query().clicked) st.active = i;
        const is_active = st.active == i;
        // A tab is a single-selection member registered under the strip's roving group: its
        // label is the authoritative chip text, `selected` mirrors the active index, and the
        // group key links it back to the strip.
        const q = chip.control(.{ .name = label, .role = .radio, .selected = is_active, .roving_group = bar_key });
        if (member_len < member_keys.len) {
            member_keys[member_len] = chip_key;
            member_len += 1;
        }
        // Interaction wins over the resting state (as `button` does): hover/held/focus lifts to
        // accent even for the **active** tab, so hovering the active tab changes its color too;
        // a resting active tab is fg, a resting inactive tab is dim.
        const c = if (q.held or q.hovering or q.focused) th.acc else if (is_active) th.fg else th.dim;
        const lbl = (try chip.text("l", label))
            .with_style(.{ style.body, Style{ .text = c }, style.pad_sym(6, 2) });
        if (is_active) _ = chip.with_style(.{Style{ .outline_color = c }});
        // Padded text in a wrapper box: adopt the label's box-relative baseline so the
        // strip baseline-aligns wherever it sits (see `resource_bar`'s chip).
        chip.get().size.baseline = lbl.get().size.baseline_off();
    }

    // The strip itself is a single-selection group controlling its member tabs (by key,
    // in paint order). Named "tabs" for the bridge; the caller left-aligns it over content.
    ctx.res.semantics.publish(uic.semantic.describeGroup(bar_key, "tabs", member_keys[0..member_len]));

    return .{ .el = bar, .active = st.active };
}
