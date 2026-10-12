//! `catalog_controls` — the shared controls bar above a catalog's results: a search
//! field, an adjacent sort toggle, and a disclosed Sort-by + Direction row, plus a count-only
//! live summary. It **composes** the earlier controls rather than reinventing them — the search
//! field is `uic.text_input` (editor, with the `/` shortcut), the sort row is a
//! `disclosure` holding two `select`s, and the query is `query.zig`.
//!
//! Contract:
//!   - **`/` focuses the search field of the *active* view only** — only the active catalog
//!     builds its `text_input`, and `text_input` registers itself as the `/` search target, so
//!     the shortcut naturally lands on the visible field (an inactive view builds nothing).
//!   - **Escape clears** a non-empty field (else the field's own focus-clear applies).
//!   - **adjacent sort toggle** opens/closes the disclosed sort row; **Escape inside the sort
//!     row** closes it and **restores focus to the toggle**.
//!   - **Sort-by** and **Direction** are `select`s; a **`none` direction disables** ordering
//!     (the caller leaves rows in their natural order) and is the reset value.
//!   - **count-only live summary** ("{n} shown") — never the row contents.
//!   - **deterministic name tie-break** — `lessThan` breaks equal sort keys by name, so the
//!     order is stable frame to frame.
//!   - **independent per surface** — all state is a `CatalogState` keyed by the surface node,
//!     so ACTIONS and BUILD keep separate query/sort/open.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const CatalogState = uic.UiState.CatalogState;
const Direction = CatalogState.Direction;

const select_mod = @import("./select.zig");

/// The controls' resolved output for this frame: the live `query_text` (a slice into the
/// field's editor buffer — valid until the next edit) and the chosen `sort` index and `dir`.
/// The caller filters/sorts its own rows from these.
pub const Catalog = struct {
    query_text: []const u8,
    sort: usize,
    dir: Direction,
};

/// Build the catalog controls into `parent`. `sort_kinds` are the Sort-by option labels; the
/// surface owns `enabled`. Returns the resolved `Catalog`. The query/sort/open state is
/// `state` when the caller passes one (an always-built owner's slot, so a hidden catalog keeps
/// it), else the bar's own slot keyed by `id`; likewise the search editor lives on
/// `search_owner` when given. Distinct ids keep ACTIONS and BUILD separate either way.
pub fn catalog_controls(parent: El, id: []const u8, sort_kinds: []const []const u8, state: ?*CatalogState, search_owner: ?El) !Catalog {
    const ctx = parent.ctx;
    const bar = try parent.div(id);
    _ = bar.with_flow(.{ .dir = .column }).with_gap(ha.tokens.gap.tight)
        .with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
    const st = state orelse bar.state(CatalogState);
    if (st.sort >= sort_kinds.len) st.sort = 0;

    // Row 1: the search field + the adjacent sort toggle.
    const row = try bar.div("row");
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.inline_)
        .with_size(.{ .pct_of_parent = 1.0 }, .fit_children);

    // Search field (`uic.text_input`): owns the query text, registers the `/` shortcut.
    const field = try uic.text_input(row, "search", "Search…", 200, search_owner);
    const field_key = field.get().key;
    const editor = (search_owner orelse field).state(uic.UiState.TextInputState);
    // Escape clears a non-empty field (the field's own outside/Escape focus-clear still applies
    // when empty). `main`'s dismiss routes `.dismissed` to the focused/escape target; here we
    // clear the buffer when the field is focused and holds text and Escape was routed to it.
    if (ctx.isFocused(field_key) and editor.len > 0 and field.query().dismissed) {
        _ = editor.clear();
    }
    const query_text = editor.text();

    // Adjacent sort toggle: opens/closes the disclosed sort row.
    const toggle = try row.div("sort_toggle");
    const toggle_key = toggle.get().key;
    if (toggle.query().clicked) st.sort_open = !st.sort_open;
    _ = toggle.control(.{ .name = "sort", .role = .button, .expanded = st.sort_open });
    _ = toggle.with_layout(.center_right).with_flow(.{ .dir = .row }).with_style(.{style.pad_sym(8, 2)});
    _ = (try toggle.text("t", if (st.sort_open) "sort \u{2191}" else "sort \u{2193}"))
        .with_style(.{ style.small, style.btn_secondary });

    // Row 2 (disclosed): Sort-by + Direction selects. Built only while open (nothing in it is
    // focusable when closed). Escape inside closes and restores focus to the toggle.
    if (st.sort_open) {
        const sort_row = try bar.div("sort_row");
        _ = sort_row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.group)
            .with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
            .with_style(.{style.pad_each(2, 0, 0, 0)});

        // The selects are controlled by the catalog state, so reopening the row (which rebuilds
        // them with fresh pooled state) shows the sort that is actually in force.
        const by = try select_mod.select(sort_row, "sort_by", "Sort", sort_kinds, true, &st.sort);

        const dir_labels = [_][]const u8{ "None", "Asc", "Desc" };
        var dir_index: usize = @intFromEnum(st.dir);
        const dir_sel = try select_mod.select(sort_row, "sort_dir", "Dir", &dir_labels, true, &dir_index);
        st.dir = @enumFromInt(dir_index);

        // Escape inside the sort row closes it and restores focus to the toggle. The row's own
        // dismiss (routed to the focused select) is inspected here.
        if (sort_row.query().dismissed or by.el.query().dismissed or dir_sel.el.query().dismissed) {
            st.sort_open = false;
            _ = ctx.requestFocus(toggle_key);
        }
    }

    // `none` direction resets ordering — normalized here so the caller's sort simply no-ops.
    // (The selects already carry `none` as index 0.)

    return .{ .query_text = query_text, .sort = st.sort, .dir = st.dir };
}

/// The **count-only live summary** — render "{n} shown" (never the row contents). Call after
/// filtering, passing the visible count. Kept separate so the caller counts its own rows.
pub fn count_summary(parent: El, id: []const u8, shown: usize) !void {
    const ctx = parent.ctx;
    var buf: [24]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{d} shown", .{shown}) catch "?";
    _ = (try parent.text(id, txt)).with_style(.{ style.small, Style{ .text = ctx.res.view.theme.dim } });
}

/// Compose a caller's key comparison with the **deterministic name tie-break**. Given
/// whether `a` sorts before `b` by the primary key (`primary_less`) and their equality
/// (`primary_eq`), fall back to a case-insensitive name compare so equal keys never reorder
/// frame to frame. `dir` applies the direction (`none` ⇒ keep the caller's natural order:
/// returns `false` so a stable sort leaves rows put).
pub fn lessThan(dir: Direction, primary_less: bool, primary_eq: bool, name_a: []const u8, name_b: []const u8) bool {
    if (dir == .none) return false; // no ordering — natural order preserved by a stable sort
    const base = if (primary_eq) nameLess(name_a, name_b) else primary_less;
    return if (dir == .descending) !base and !(primary_eq and eqlName(name_a, name_b)) else base;
}

fn nameLess(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = lowerAscii(a[i]);
        const cb = lowerAscii(b[i]);
        if (ca != cb) return ca < cb;
    }
    return a.len < b.len;
}
fn eqlName(a: []const u8, b: []const u8) bool {
    return !nameLess(a, b) and !nameLess(b, a);
}
fn lowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// ============================ Tests (pure helpers) ======================================

test "catalog lessThan: none preserves order; name breaks ties; descending inverts" {
    // No direction ⇒ never reorders (stable sort keeps natural order).
    try std.testing.expect(!lessThan(.none, true, false, "a", "b"));
    // Ascending by primary key.
    try std.testing.expect(lessThan(.ascending, true, false, "x", "y"));
    try std.testing.expect(!lessThan(.ascending, false, false, "x", "y"));
    // Equal primary key ⇒ name tie-break (case-insensitive), ascending.
    try std.testing.expect(lessThan(.ascending, false, true, "Apple", "banana"));
    try std.testing.expect(!lessThan(.ascending, false, true, "banana", "Apple"));
    // Descending inverts the primary comparison.
    try std.testing.expect(!lessThan(.descending, true, false, "x", "y"));
    try std.testing.expect(lessThan(.descending, false, false, "x", "y"));
}
