//! `catalog_controls` (KIT-15) — the shared controls bar above a catalog's results: a search
//! field, an adjacent sort toggle, and a disclosed Sort-by + Direction row, plus a count-only
//! live summary. It **composes** the earlier controls rather than reinventing them — the search
//! field is `widgets.text_input` (INPUT-07 editor, with the `/` shortcut), the sort row is a
//! `disclosure` (KIT-11) holding two `select`s (KIT-09), and the query is `query.zig` (KIT-14).
//!
//! Contract (KIT-15):
//!   - **`/` focuses the search field of the *active* view only** — only the active catalog
//!     builds its `text_input`, and `text_input` registers itself as the `/` search target, so
//!     the shortcut naturally lands on the visible field (an inactive view builds nothing).
//!   - **Escape clears** a non-empty field (else the field's own focus-clear applies).
//!   - **adjacent sort toggle** opens/closes the disclosed sort row; **Escape inside the sort
//!     row** closes it and **restores focus to the toggle**.
//!   - **Sort-by** and **Direction** are `select`s; a **`none` direction disables** ordering
//!     (the caller leaves rows in their natural order) and is the reset value.
//!   - **count-only live summary** ("{n} shown") — never the row contents.
//!   - **reset-to-top on query/sort change** — a `changed` flag flips when the (query, sort,
//!     dir) signature differs from last frame, so the viewport (KIT-16) resets its scroll.
//!   - **deterministic name tie-break** — `lessThan` breaks equal sort keys by name, so the
//!     order is stable frame to frame.
//!   - **independent per surface** — all state is a `CatalogState` keyed by the surface node,
//!     so ACTIONS and BUILD keep separate query/sort/open (and their own scroll, KIT-16).

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
/// field's editor buffer — valid until the next edit), the chosen `sort` index and `dir`, and
/// `changed` — true on the frame the query/sort/dir differs from the last, so the caller resets
/// its result scroll to the top. The caller filters/sorts its own rows from these.
pub const Catalog = struct {
    query_text: []const u8,
    sort: usize,
    dir: Direction,
    changed: bool,
};

/// FNV-1a over the (query, sort, dir) tuple — the signature used to detect a change for
/// reset-to-top. Cheap and allocation-free.
fn signature(query_text: []const u8, sort: usize, dir: Direction) u64 {
    var h: u64 = 1469598103934665603;
    for (query_text) |c| {
        h ^= c;
        h *%= 1099511628211;
    }
    h ^= sort *% 1099511628211;
    h ^= @as(u64, @intFromEnum(dir)) *% 14695981039346656;
    return h;
}

/// Build the catalog controls into `parent`. `sort_kinds` are the Sort-by option labels; the
/// surface owns `enabled`. Returns the resolved `Catalog`. `id` keys the surface's independent
/// state — pass distinct ids for ACTIONS vs BUILD so their query/sort/open stay separate.
pub fn catalog_controls(ctx: *UiCtx, parent: El, id: []const u8, sort_kinds: []const []const u8) !Catalog {
    const bar = try el.div(ctx, parent, id);
    _ = bar.with_flow(.{ .dir = .column }).with_gap(ha.tokens.gap.tight)
        .with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
    const st = bar.get().state(ctx, CatalogState);
    if (st.sort >= sort_kinds.len) st.sort = 0;

    // Row 1: the search field + the adjacent sort toggle.
    const row = try el.div(ctx, bar, "row");
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.inline_)
        .with_size(.{ .pct_of_parent = 1.0 }, .fit_children);

    // Search field (widgets.text_input): owns the query text, registers the `/` shortcut.
    const field = try uic.text_input(ctx, row.get(), "search", "Search…", 200);
    const editor = field.state(ctx, uic.UiState.TextInputState);
    // Escape clears a non-empty field (the field's own outside/Escape focus-clear still applies
    // when empty). `main`'s dismiss routes `.dismissed` to the focused/escape target; here we
    // clear the buffer when the field is focused and holds text and Escape was routed to it.
    if (ctx.isFocused(field.key) and editor.len > 0 and field.query(ctx).dismissed) {
        _ = editor.clear();
    }
    const query_text = editor.text();

    // Adjacent sort toggle: opens/closes the disclosed sort row.
    const toggle = try el.div(ctx, row, "sort_toggle");
    ctx.registerFocus(toggle.get().key, true);
    const toggle_key = toggle.get().key;
    const tq = toggle.query();
    if (tq.clicked) {
        _ = ctx.requestFocus(toggle_key);
        st.sort_open = !st.sort_open;
    }
    if (tq.hovering) ctx.res.cursor.request(.pointer);
    const tfocused = ctx.isFocused(toggle_key);
    uic.publishControlState(ctx, toggle_key, .{ .focused = tfocused, .focus_visible = tfocused });
    _ = toggle.with_layout(.center_right).with_flow(.{ .dir = .row }).with_style(.{style.pad_sym(8, 2)});
    _ = (try el.text(ctx, toggle, "t", if (st.sort_open) "sort \u{2191}" else "sort \u{2193}"))
        .with_style(.{ style.small, style.btn_secondary });

    // Row 2 (disclosed): Sort-by + Direction selects. Built only while open (nothing in it is
    // focusable when closed). Escape inside closes and restores focus to the toggle.
    if (st.sort_open) {
        const sort_row = try el.div(ctx, bar, "sort_row");
        _ = sort_row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.group)
            .with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
            .with_style(.{style.pad_each(2, 0, 0, 0)});

        const by = try select_mod.select(ctx, sort_row, "sort_by", "Sort", sort_kinds, true);
        st.sort = by.value;

        const dir_labels = [_][]const u8{ "None", "Asc", "Desc" };
        const dir_sel = try select_mod.select(ctx, sort_row, "sort_dir", "Dir", &dir_labels, true);
        st.dir = @enumFromInt(dir_sel.value);

        // Escape inside the sort row closes it and restores focus to the toggle. The row's own
        // dismiss (routed to the focused select) is inspected here.
        if (sort_row.query().dismissed or by.el.query().dismissed or dir_sel.el.query().dismissed) {
            st.sort_open = false;
            _ = ctx.requestFocus(toggle_key);
        }
    }

    // `none` direction resets ordering — normalized here so the caller's sort simply no-ops.
    // (The selects already carry `none` as index 0.)

    // Change detection for reset-to-top: compare this frame's (query, sort, dir) signature.
    const sig = signature(query_text, st.sort, st.dir);
    const changed = sig != st.last_sig;
    st.last_sig = sig;

    return .{ .query_text = query_text, .sort = st.sort, .dir = st.dir, .changed = changed };
}

/// The **count-only live summary** — render "{n} shown" (never the row contents). Call after
/// filtering, passing the visible count. Kept separate so the caller counts its own rows.
pub fn count_summary(ctx: *UiCtx, parent: El, id: []const u8, shown: usize) !void {
    var buf: [24]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{d} shown", .{shown}) catch "?";
    _ = (try el.text(ctx, parent, id, txt)).with_style(.{ style.small, Style{ .text = ctx.res.view.theme.dim } });
}

/// Compose a caller's key comparison with the **deterministic name tie-break** (KIT-15). Given
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

test "catalog signature changes on query, sort, or direction change" {
    const a = signature("wood", 0, .none);
    try std.testing.expectEqual(a, signature("wood", 0, .none)); // stable
    try std.testing.expect(a != signature("fish", 0, .none)); // query
    try std.testing.expect(a != signature("wood", 1, .none)); // sort
    try std.testing.expect(a != signature("wood", 0, .ascending)); // dir
}

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
