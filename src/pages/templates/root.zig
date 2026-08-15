//! The game's **template shelf** — heavy, pre-styled compositions built on the `ui_client`
//! foundation (elements + style/placement) and themed via `ha.theme`. Mirrors
//! `ui_client/features/`: this barrel re-exports one module per template. Game content
//! (it reads `res.theme` art direction), so it lives under `pages/`, not on the `ha`
//! library surface. Screen builders import it as `@import("./templates/root.zig")`.

const button_mod = @import("./button.zig");
const panel_mod = @import("./panel.zig");
const scroll_view_mod = @import("./scroll_view.zig");
const figure_mod = @import("./figure.zig");
const status_mod = @import("./status.zig");
const action_button_mod = @import("./action_button.zig");
const row_mod = @import("./row.zig");

// composites
pub const button = button_mod.button;
pub const panel = panel_mod.panel;
pub const row = row_mod.row;
pub const ScrollView = scroll_view_mod.ScrollView;
pub const scroll_view = scroll_view_mod.scroll_view;
pub const action_button = action_button_mod.action_button;

// vitals figure
pub const Figure = figure_mod.Figure;
pub const fig_robust = figure_mod.fig_robust;
pub const fig_ok = figure_mod.fig_ok;
pub const fig_weary = figure_mod.fig_weary;
pub const fig_dead = figure_mod.fig_dead;
pub const figure_glyphs = figure_mod.figure_glyphs;
pub const figure = figure_mod.figure;

// status helpers
pub const Status = status_mod.Status;
pub const actor_status = status_mod.actor_status;
pub const heartbeat_color = status_mod.heartbeat_color;
