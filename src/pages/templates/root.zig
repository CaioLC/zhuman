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
const stat_mod = @import("./stat.zig");
const log_view_mod = @import("./log_view.zig");
const resource_bar_mod = @import("./resource_bar.zig");
const action_card_mod = @import("./action_card.zig");
const action_tile_mod = @import("./action_tile.zig");
const eat_tile_mod = @import("./eat_tile.zig");
const capital_tile_mod = @import("./capital_tile.zig");
const tabs_mod = @import("./tabs.zig");

// composites
pub const button = button_mod.button;
pub const panel = panel_mod.panel;
pub const row = row_mod.row;
pub const stat = stat_mod.stat;
pub const ScrollView = scroll_view_mod.ScrollView;
pub const scroll_view = scroll_view_mod.scroll_view;
pub const log_view = log_view_mod.log_view;
pub const resource_bar = resource_bar_mod.resource_bar;
pub const action_button = action_button_mod.action_button;
pub const action_card = action_card_mod.action_card;
pub const action_tile = action_tile_mod.action_tile;
pub const eat_tile = eat_tile_mod.eat_tile;
pub const capital_tile = capital_tile_mod.capital_tile;
pub const Tabs = tabs_mod.Tabs;
pub const tabs = tabs_mod.tabs;

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
pub const compute_warmth = status_mod.compute_warmth;
