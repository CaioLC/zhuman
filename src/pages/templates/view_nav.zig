//! `view_nav` — the **shared tab/view navigation** (KIT-07). A thin, reusable layer over the
//! `tabs` strip that formalizes the prototype's view-switching contract so a screen does not
//! re-implement it per act:
//!
//!   - **Exactly one view is selected and globally focusable.** Selection lives in the strip's
//!     pooled `TabsState` (one active index); the tablist contributes exactly **one** global
//!     Tab stop via roving focus (`registerRovingFocus`), so Tab reaches "the tabs" once and
//!     the arrows move *within* them.
//!   - **Arrows rove within the tablist; Enter/Space switches.** Both are the engine's existing
//!     roving-focus + activation path (`moveFocusedRoving`, `command.activate` → `.clicked`),
//!     which `tabs` already wires; the active chip's click sets the index the *same* frame.
//!   - **Inactive panels are not built or focusable, but their state persists in the shell.**
//!     The caller builds only the active view's subtree (an unbuilt view has no nodes, so
//!     nothing in it is focusable), and calls `retain` for each inactive view so its pooled
//!     state (scroll offset, collapse, query/sort) survives the frame-arena rebuild by key —
//!     the view restores exactly where it was when the player returns to it.
//!
//! It renders into the shell's `regions.nav` (KIT-04). The caller reads `active`, builds that
//! one view into the body, and `retain`s the others. The strip chrome, roving focus, selection
//! persistence, and accessibility group all come from `tabs` unchanged — this adds the
//! view-retention contract and a single place to document it.

const uic = @import("ha").ui_client;
const el = uic.elements;
const El = el.El;
const UiCtx = uic.UiCtx;

const tabs = @import("./tabs.zig");

/// The nav result: the active view index (the caller builds that view) and the strip `El`.
pub const ViewNav = struct { active: usize, el: El };

/// Render the shared view-switching tablist into `nav_parent` (typically the shell's
/// `regions.nav`). Returns the active index; the caller builds that view into the body.
pub fn view_nav(ctx: *UiCtx, nav_parent: El, id: []const u8, labels: []const []const u8) !ViewNav {
    const t = try tabs.tabs(ctx, nav_parent, id, labels);
    return .{ .active = t.active, .el = t.el };
}

/// Retain an **inactive** view's pooled state across the frame it is not built. `parent` is
/// the container the view would build under, `child_id` the view's stable child key, and `T`
/// its state type (e.g. a scroll/collapse/query state). Keeps the slot alive by key without
/// allocating the view's nodes, so returning to the view restores its scroll/collapse exactly.
/// A no-op-safe wrapper over `Node.retainChildState`, so a screen retains a view without
/// naming the engine's retention primitive. Returns whether a slot was retained.
pub fn retain(ctx: *UiCtx, parent: El, child_id: []const u8, comptime T: type) bool {
    return parent.get().retainChildState(ctx, child_id, T);
}
