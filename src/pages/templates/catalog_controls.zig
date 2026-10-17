//! `catalog_controls` — the search field above a catalog's results (BUILD and ACTIONS), and
//! the sort helpers a sortable table's column headers use. The field is `uic.text_input`
//! (editor, with the `/` shortcut); the query language is `query.zig`.
//!
//! Contract:
//!   - **`/` focuses the search field of the *active* view only** — only the active catalog
//!     builds its `text_input`, and `text_input` registers itself as the `/` search target.
//!   - **Escape clears** a non-empty field (else the field's own focus-clear applies).
//!   - **deterministic name tie-break** — `lessThan` breaks equal sort keys by name, so a
//!     header-sorted table's order is stable frame to frame (`nextSort` handles the clicks).
//!   - **independent per surface** — the query and sort live in a `CatalogState` the caller
//!     keys per view, so ACTIONS and BUILD keep separate state.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const El = el.El;
const CatalogState = uic.UiState.CatalogState;
const Direction = CatalogState.Direction;

/// The controls' resolved output for this frame: the live `query_text` (a slice into the
/// field's editor buffer — valid until the next edit) and the catalog state in force, which a
/// header-sorted table reads its sort from. `state` is valid until the next `CatalogState`
/// acquire (a pool can move as it grows).
pub const Catalog = struct {
    query_text: []const u8,
    state: *CatalogState,
};

/// Build the search field into `parent`. The catalog state is `state` when the caller passes
/// one (an always-built owner's slot, so a hidden catalog keeps it), else the bar's own slot;
/// likewise the search editor lives on `search_owner` when given.
pub fn catalog_controls(parent: El, id: []const u8, state: ?*CatalogState, search_owner: ?El) !Catalog {
    const ctx = parent.ctx;
    const bar = try parent.div(id);
    _ = bar.with_flow(.{ .dir = .row, .cross = .center })
        .with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
    const st = state orelse bar.state(CatalogState);

    const field = try uic.text_input(bar, "search", "Search…", 200, search_owner);
    const field_key = field.get().key;
    const editor = (search_owner orelse field).state(uic.UiState.TextInputState);
    // Escape clears a non-empty field (the field's own outside/Escape focus-clear still applies
    // when empty): the dismiss is routed to the focused field.
    if (ctx.isFocused(field_key) and editor.len > 0 and field.query().dismissed) {
        _ = editor.clear();
    }
    return .{ .query_text = editor.text(), .state = st };
}
/// A column-header sort click: the clicked column becomes the sort in its `natural` direction
/// (the one a player expects first — nearest/cheapest/quickest/A–Z), and clicking the column
/// already in force flips the direction. `dir` is the direction in force (never `none`).
pub fn nextSort(sort: usize, dir: Direction, clicked: usize, natural: Direction) struct { sort: usize, dir: Direction } {
    if (clicked != sort) return .{ .sort = clicked, .dir = natural };
    return .{ .sort = sort, .dir = if (dir == .descending) .ascending else .descending };
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

test "nextSort: a new column takes its natural direction; the active column flips" {
    const a = nextSort(0, .descending, 2, .ascending);
    try std.testing.expectEqual(@as(usize, 2), a.sort);
    try std.testing.expectEqual(Direction.ascending, a.dir);
    const b = nextSort(2, .ascending, 2, .ascending);
    try std.testing.expectEqual(Direction.descending, b.dir);
    const c = nextSort(2, .descending, 2, .ascending);
    try std.testing.expectEqual(Direction.ascending, c.dir);
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
