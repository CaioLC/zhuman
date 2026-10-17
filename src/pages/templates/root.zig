//! The game's **template shelf** — heavy, pre-styled compositions built on the `ui_client`
//! foundation (elements + style) and themed from `res.view.theme` (the palette `ha.palette`
//! installs). Mirrors
//! `ui_client/features/`: this barrel re-exports one module per template. Game content
//! (it reads `res.view.theme` art direction), so it lives under `pages/`, not on the `ha`
//! library surface. Screen builders import it as `@import("./templates/root.zig")`.

const button_mod = @import("./button.zig");
const panel_mod = @import("./panel.zig");
const curtain_mod = @import("./curtain.zig");
const scroll_view_mod = @import("./scroll_view.zig");
const figure_mod = @import("./figure.zig");
const log_view_mod = @import("./log_view.zig");
const action_tile_mod = @import("./action_tile.zig");
const generator_section_mod = @import("./generator_section.zig");
const tabs_mod = @import("./tabs.zig");
const act_surface_mod = @import("./act_surface.zig");
const holdings_mod = @import("./holdings.zig");
const build_list_mod = @import("./build_list.zig");
const capital_row_mod = @import("./capital_row.zig");
const terminal_mod = @import("./terminal.zig");
const rail_mod = @import("./rail.zig");
const slider_mod = @import("./slider.zig");
const stock_token_mod = @import("./stock_token.zig");
const runline_mod = @import("./runline.zig");
const header_mod = @import("./header.zig");
const speed_controls_mod = @import("./speed_controls.zig");
const market_strip_mod = @import("./market_strip.zig");
const catalog_controls_mod = @import("./catalog_controls.zig");
const eating_policy_mod = @import("./eating_policy.zig");
const milestone_goal_mod = @import("./milestone_goal.zig");
const modal_mod = @import("./modal.zig");
const modal_header_mod = @import("./modal_header.zig");
const modal_body_mod = @import("./modal_body.zig");
const modal_footer_mod = @import("./modal_footer.zig");
const trade_dialog_mod = @import("./trade_dialog.zig");
const menu_dialog_mod = @import("./menu_dialog.zig");
const act_one_surface_mod = @import("./act_one_surface.zig");
const act_one_workspace_mod = @import("./act_one_workspace.zig");
const board_primitives_mod = @import("./board_primitives.zig");
const readout_mod = @import("./readout.zig");
const table_mod = @import("./table.zig");
const browser_mod = @import("./browser.zig");
const copy_mod = @import("./copy.zig");

// composites
pub const button = button_mod.button;
pub const panel = panel_mod.panel;
pub const ScrollView = scroll_view_mod.ScrollView;
pub const scroll_view = scroll_view_mod.scroll_view;
pub const ScrollOptions = scroll_view_mod.Options;
pub const log_view = log_view_mod.log_view;
pub const action_tile = action_tile_mod.action_tile;
pub const generator_section = generator_section_mod.generator_section;
pub const actions_section = @import("./actions_section.zig").actions_section;
pub const ActionsShelf = @import("./actions_section.zig").Shelf;
pub const Tabs = tabs_mod.Tabs;
pub const tabs = tabs_mod.tabs;
pub const act_surface = act_surface_mod.act_surface;
pub const act_page = @import("./act_page.zig").act_page;
pub const ActPage = @import("./act_page.zig").ActPage;
pub const vigorStock = @import("./act_page.zig").vigorStock;
pub const curtain = curtain_mod.curtain;
pub const CurtainOptions = curtain_mod.Options;
pub const ActSurface = act_surface_mod.Result;
pub const ActSurfaceOptions = act_surface_mod.Options;
pub const ActActivity = act_surface_mod.Activity;
pub const activityOf = act_surface_mod.activity;
pub const holdings = holdings_mod.holdings;
pub const HoldingsContent = holdings_mod.Content;
pub const HoldingsLine = holdings_mod.Line;
pub const HoldingsSentence = holdings_mod.Sentence;
pub const HoldingsTone = holdings_mod.Tone;
pub const build_list = build_list_mod.build_list;
pub const BuildShelf = build_list_mod.Shelf;
pub const build_scroll_gutter = capital_row_mod.scroll_gutter;
pub const build_lane_width = capital_row_mod.lane_width;
pub const buildCostOverflow = build_list_mod.costOverflow;
pub const build_section = @import("./build_section.zig").build_section;
pub const capital_row = capital_row_mod.capital_row;
pub const terminal = terminal_mod.terminal;
pub const Terminal = terminal_mod.Shell;
pub const shell = terminal_mod.shell;
pub const shell_content = terminal_mod.shell_content;
pub const Shell = terminal_mod.Regions;
pub const ShellOptions = terminal_mod.ShellOptions;
pub const Act = terminal_mod.Act;
pub const rail = rail_mod.rail;
pub const Rail = rail_mod.Rail;
pub const RailOptions = rail_mod.RailOptions;
pub const slider = slider_mod.slider;
pub const Slider = slider_mod.Slider;
pub const SliderOptions = slider_mod.Options;
pub const stock_token = stock_token_mod.stock_token;
pub const stockline = stock_token_mod.stockline;
pub const Stock = stock_token_mod.Stock;
pub const StockTone = stock_token_mod.Tone;
pub const runline = runline_mod.runline;
pub const Run = runline_mod.Run;
pub const header = header_mod.header;
pub const Header = header_mod.Header;
pub const HeaderOptions = header_mod.Options;
pub const speed_controls = speed_controls_mod.speed_controls;
pub const menu_control = speed_controls_mod.menu_control;
pub const speed_stepper = speed_controls_mod.speed_stepper;
pub const market_strip = market_strip_mod.market_strip;
pub const MarketKind = market_strip_mod.MarketKind;
pub const marketIdentity = market_strip_mod.marketIdentity;
pub const activity_strip = market_strip_mod.activity_strip;
pub const ActivityState = market_strip_mod.ActivityState;
pub const activityIdentity = market_strip_mod.activityIdentity;
pub const catalog_controls = catalog_controls_mod.catalog_controls;
pub const Catalog = catalog_controls_mod.Catalog;
pub const catalog_less_than = catalog_controls_mod.lessThan;
pub const eating_policy = eating_policy_mod.eating_policy;
pub const milestone_goal = milestone_goal_mod.milestone_goal;
pub const MilestoneGoal = milestone_goal_mod.Goal;
pub const MilestoneRequirement = milestone_goal_mod.Requirement;
pub const MilestoneLifecycle = milestone_goal_mod.Lifecycle;
pub const modal = modal_mod.modal;
pub const Modal = modal_mod.Modal;
pub const modal_header = modal_header_mod.modal_header;
pub const modal_body = modal_body_mod.modal_body;
pub const ModalBodyResult = modal_body_mod.Result;
pub const modal_footer = modal_footer_mod.modal_footer;
pub const ModalFooterResult = modal_footer_mod.Result;
pub const trade_dialog = trade_dialog_mod.trade_dialog;
pub const menu_dialog = menu_dialog_mod.menu_dialog;
pub const TradeOffer = trade_dialog_mod.Offer;
pub const TradeHolding = trade_dialog_mod.Holding;
pub const act_one_surface = act_one_surface_mod.act_one_surface;
pub const ActOneSurface = act_one_surface_mod.Result;
pub const ActOneSurfaceOptions = act_one_surface_mod.Options;
pub const ActOneSurfaceActivity = act_one_surface_mod.Activity;
pub const act_one_workspace = act_one_workspace_mod.act_one_workspace;
pub const ActOneWorkspace = act_one_workspace_mod.Result;
pub const ActOneWorkspaceOptions = act_one_workspace_mod.Options;
pub const TradeResult = trade_dialog_mod.Result;
// Board-level primitives
pub const empty_state = board_primitives_mod.empty_state;
// Readout panels (HOLDINGS / BODY)
pub const ReadoutPad = readout_mod.Pad;
pub const readout_panel = readout_mod.readout_panel;
pub const readout_heading = readout_mod.readout_heading;
pub const section_label = readout_mod.section_label;
pub const kv_line = readout_mod.kv_line;
pub const kv_line_in = readout_mod.kv_line_in;
pub const sentence = readout_mod.sentence;
pub const divider = readout_mod.divider;
// Fixed-lane tables
pub const table_header_cell = table_mod.header_cell;
pub const table_cell = table_mod.cell;
pub const sort_header_cell = table_mod.sort_header_cell;
pub const SortShown = table_mod.SortShown;
pub const nextSort = catalog_controls_mod.nextSort;
pub const table_row = table_mod.table_row;
// Prose leaves
pub const summary_line = copy_mod.summary_line;
pub const empty_line = copy_mod.empty_line;
pub const headline = copy_mod.headline;
pub const lede = copy_mod.lede;
pub const prose_measure = copy_mod.prose_measure;
// Catalog browser chrome
pub const browser_heading = browser_mod.browser_heading;
pub const TileLanes = browser_mod.Lanes;
pub const tile_lanes = browser_mod.tile_lanes;

// vitals figure
pub const Figure = figure_mod.Figure;
pub const fig_dead = figure_mod.fig_dead;
pub const figure = figure_mod.figure;

// status helpers

// Re-exporting a function does not pull its file's tests into a test build; referencing the
// module does. One line per shelf module keeps every template's tests in `zig build test`.
test {
    _ = button_mod;
    _ = panel_mod;
    _ = scroll_view_mod;
    _ = figure_mod;
    _ = log_view_mod;
    _ = action_tile_mod;
    _ = generator_section_mod;
    _ = tabs_mod;
    _ = curtain_mod;
    _ = @import("./act_page.zig");
    _ = act_surface_mod;
    _ = holdings_mod;
    _ = build_list_mod;
    _ = capital_row_mod;
    _ = terminal_mod;
    _ = rail_mod;
    _ = slider_mod;
    _ = stock_token_mod;
    _ = runline_mod;
    _ = header_mod;
    _ = speed_controls_mod;
    _ = market_strip_mod;
    _ = catalog_controls_mod;
    _ = eating_policy_mod;
    _ = milestone_goal_mod;
    _ = modal_mod;
    _ = modal_header_mod;
    _ = modal_body_mod;
    _ = modal_footer_mod;
    _ = trade_dialog_mod;
    _ = menu_dialog_mod;
    _ = act_one_surface_mod;
    _ = act_one_workspace_mod;
    _ = board_primitives_mod;
    _ = readout_mod;
    _ = table_mod;
    _ = browser_mod;
    _ = copy_mod;
    _ = @import("./actions_section.zig");
    _ = @import("./build_section.zig");
}
