//! `view_nav` — the **shared tab/view navigation**. A thin, reusable layer over the
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
//!   - **Inactive panels are not built or focusable, but their state persists.** The caller
//!     builds only the active view's subtree (an unbuilt view has no nodes, so nothing in it
//!     is focusable). A view's pooled state (collapse, query/sort, the search editor) lives on
//!     an always-built owner and is passed down as a state pointer — BUILD's catalog state is
//!     on the Act I surface — so it survives the frames the view is not built, and the view
//!     restores exactly where it was when the player returns to it (`src/ui_client/README.md`,
//!     "Who owns a template's state").
//!
//! It renders into the nav row that heads the surface it switches — a tab strip is never a
//! shell region (`act_one_surface`, the Act II page). The caller reads `active` and builds that
//! one view below it. The strip chrome, roving focus, selection persistence, and
//! accessibility group all come from `tabs` unchanged — this adds the view contract and a
//! single place to document it.

const uic = @import("ha").ui_client;
const el = uic.elements;
const El = el.El;
const UiCtx = uic.UiCtx;

const tabs = @import("./tabs.zig");

/// The nav result: the active view index (the caller builds that view) and the strip `El`.
pub const ViewNav = struct { active: usize, el: El };

/// Render the shared view-switching tablist into `nav_parent`, the surface's nav row. `active`
/// is the selection when the caller keeps it on an always-built node — to open on a given view,
/// or to hold it across a rebuilt strip; null means the strip keeps its own. Returns the active
/// index; the caller builds that view below.
pub fn view_nav(nav_parent: El, id: []const u8, labels: []const []const u8, active: ?*usize) !ViewNav {
    const t = try tabs.tabs(nav_parent, id, labels, active);
    return .{ .active = t.active, .el = t.el };
}
