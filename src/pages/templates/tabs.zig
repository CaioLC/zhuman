//! `tabs` template — a row of text chips switching which content the caller builds:
//! the active label wears fg + its outline, inactive ones sit dim (accent on hover).
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

pub fn tabs(ctx: *UiCtx, parent: El, id: []const u8, labels: []const []const u8) !Tabs {
    const th = ctx.res.view.theme;

    const bar = try el.div(ctx, parent, id);
    _ = bar.with_flow(.{ .dir = .row }).with_gap(10);
    const bar_key = bar.get().key;

    const st = bar.get().state(ctx, TabsState);
    if (st.active >= labels.len) st.active = 0; // labels shrank across frames — stay valid

    // INPUT-08: collect the member keys in paint order for the group's `controls` links.
    var member_keys: [uic.semantic.max_relations]u64 = undefined;
    var member_len: usize = 0;

    for (labels, 0..) |label, i| {
        const key = try std.fmt.allocPrint(ctx.arena, "tab{d}", .{i});
        const chip = try el.div(ctx, bar, key);
        const chip_key = chip.get().key;
        const q = chip.query();
        ctx.registerRovingFocus(bar_key, chip_key, true);
        if (q.clicked) _ = ctx.requestFocus(chip_key);
        const focused = ctx.isFocused(chip_key);
        if (q.hovering) ctx.res.cursor.request(.pointer);
        if (q.clicked) st.active = i;

        const is_active = st.active == i;
        uic.publishControlState(ctx, chip_key, .{
            .focused = focused,
            .focus_visible = focused,
            .selected = is_active,
        });
        // A tab is a single-selection member; its label is the authoritative chip text and
        // `selected` mirrors the active index. Linked back to the strip group by key.
        ctx.res.semantics.publish(uic.semantic.describeRadio(chip_key, label, is_active, focused, bar_key));
        if (member_len < member_keys.len) {
            member_keys[member_len] = chip_key;
            member_len += 1;
        }
        const c = if (is_active) th.fg else if (q.held or q.hovering or focused) th.acc else th.dim;
        const lbl = (try el.text(ctx, chip, "l", label))
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
