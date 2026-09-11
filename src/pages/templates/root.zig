//! The game's **template shelf** — heavy, pre-styled compositions built on the `ui_client`
//! foundation (elements + style) and themed from `res.view.theme` (the palette `ha.palette`
//! installs). Mirrors
//! `ui_client/features/`: this barrel re-exports one module per template. Game content
//! (it reads `res.view.theme` art direction), so it lives under `pages/`, not on the `ha`
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
const ration_dial_mod = @import("./ration_dial.zig");
const tabs_mod = @import("./tabs.zig");
const holdings_mod = @import("./holdings.zig");
const build_list_mod = @import("./build_list.zig");
const capital_row_mod = @import("./capital_row.zig");
const good_text_mod = @import("./good_text.zig");
const terminal_mod = @import("./terminal.zig");
const rail_mod = @import("./rail.zig");
const view_nav_mod = @import("./view_nav.zig");
const select_mod = @import("./select.zig");
const slider_mod = @import("./slider.zig");
const disclosure_mod = @import("./disclosure.zig");
const stock_token_mod = @import("./stock_token.zig");
const runline_mod = @import("./runline.zig");
const market_strip_mod = @import("./market_strip.zig");
const catalog_controls_mod = @import("./catalog_controls.zig");

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
pub const ration_dial = ration_dial_mod.ration_dial;
pub const Tabs = tabs_mod.Tabs;
pub const tabs = tabs_mod.tabs;
pub const holdings = holdings_mod.holdings;
pub const build_list = build_list_mod.build_list;
pub const capital_row = capital_row_mod.capital_row;
pub const good_text = good_text_mod;
pub const terminal = terminal_mod.terminal;
pub const Terminal = terminal_mod.Shell;
pub const shell = terminal_mod.shell;
pub const Shell = terminal_mod.Regions;
pub const ShellOptions = terminal_mod.ShellOptions;
pub const Act = terminal_mod.Act;
pub const rail = rail_mod.rail;
pub const Rail = rail_mod.Rail;
pub const RailOptions = rail_mod.RailOptions;
pub const view_nav = view_nav_mod.view_nav;
pub const ViewNav = view_nav_mod.ViewNav;
pub const retain_view = view_nav_mod.retain;
pub const select = select_mod.select;
pub const Select = select_mod.Select;
pub const slider = slider_mod.slider;
pub const disclosure = disclosure_mod.disclosure;
pub const Disclosure = disclosure_mod.Disclosure;
pub const stock_token = stock_token_mod.stock_token;
pub const stockline = stock_token_mod.stockline;
pub const Stock = stock_token_mod.Stock;
pub const runline = runline_mod.runline;
pub const Run = runline_mod.Run;
pub const market_strip = market_strip_mod.market_strip;
pub const MarketKind = market_strip_mod.MarketKind;
pub const marketIdentity = market_strip_mod.marketIdentity;
pub const activity_strip = market_strip_mod.activity_strip;
pub const ActivityState = market_strip_mod.ActivityState;
pub const activityIdentity = market_strip_mod.activityIdentity;
pub const catalog_controls = catalog_controls_mod.catalog_controls;
pub const count_summary = catalog_controls_mod.count_summary;
pub const Catalog = catalog_controls_mod.Catalog;
pub const catalog_less_than = catalog_controls_mod.lessThan;

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
