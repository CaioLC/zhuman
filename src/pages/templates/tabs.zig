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
//!
//! **The view-switching contract** (both acts' surface nav, the trade dialog's BUY/SELL):
//!
//!   - **Exactly one tab is selected and the strip is one Tab stop.** Members register under
//!     the strip's roving group, so Tab reaches "the tabs" once and the arrows move within them;
//!     Enter/Space activate through the shared `.clicked` path.
//!   - **Inactive views are not built, but their state persists.** The caller builds only the
//!     active view's subtree, so nothing in a hidden view is focusable. A view's pooled state
//!     (collapse, query/sort, the search editor) lives on an always-built owner and is passed
//!     down as a state pointer, so the view restores exactly where it was
//!     (`src/ui_client/README.md`, "Who owns a template's state").
//!   - **A tab strip is never a shell region.** It renders into the nav row heading the surface
//!     it switches (`act_one_surface`, the Act II page).

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

/// A tab's label: dim, fg while it is the active tab (published as `selected`), and accent
/// while hot on every tab, the active one included.
pub const tab_label = Style{ .ink = .dim, .on = &.{ .{ .when = .selected, .ink = .fg }, .{ .when = .hot, .ink = .acc } } };

/// Build the strip. When the caller passes `active`, that is the selection (read on entry,
/// written on exit) and the strip's own slot is only a mirror; null means the strip owns it.
pub fn tabs(parent: El, id: []const u8, labels: []const []const u8, active: ?*usize) !Tabs {
    return tabs_named(parent, id, "tabs", labels, active);
}

/// `tabs` with the strip's accessible name (the prototype's `nav aria-label`).
pub fn tabs_named(parent: El, id: []const u8, name: []const u8, labels: []const []const u8, active: ?*usize) !Tabs {
    const ctx = parent.ctx;

    const bar = try parent.box(id, .{ .flow = .{ .dir = .row }, .gap = 10 }, .{});
    const bar_key = bar.get().key;

    const st = bar.state(TabsState);
    if (active) |a| st.active = a.*; // the caller's selection is authoritative
    if (st.active >= labels.len) st.active = 0; // labels shrank across frames — stay valid
    defer if (active) |a| {
        a.* = st.active;
    };

    // Collect the member keys in paint order for the group's `controls` links.
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
        _ = chip.control(.{ .name = label, .role = .radio, .selected = is_active, .roving_group = bar_key, .ring = false });
        if (member_len < member_keys.len) {
            member_keys[member_len] = chip_key;
            member_len += 1;
        }
        // Hover/held/focus lifts the label to accent on every tab, the active one included
        // (`.tab:hover { color: acc }`); a resting active tab is fg, a resting inactive tab is
        // dim. Only the active tab is outlined, always in fg (`.tab[aria-selected] { border:
        // fg }`), so the lift reads the same on every tab and no tab gains an outline on hover.
        const lbl = (try chip.text("l", label))
            .with_style(.{ style.body, tab_label, style.pad_sym(6, 2) });
        if (is_active) _ = chip.with_style(.{Style{ .outline_ink = .fg }});
        // Padded text in a wrapper box: adopt the label's box-relative baseline so the
        // strip baseline-aligns wherever it sits (the chip baseline-adopt pattern).
        chip.get().size.baseline = lbl.get().size.baseline_off();
    }

    // The strip itself is a single-selection group controlling its member tabs (by key,
    // in paint order), under the caller's name; the caller left-aligns it over content.
    ctx.res.semantics.publish(uic.semantic.describeGroup(bar_key, name, member_keys[0..member_len]));

    return .{ .el = bar, .active = st.active };
}
