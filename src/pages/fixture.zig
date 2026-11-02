//! `fixture` — a **development-only deterministic fixture harness**. Where `debug_page` audits
//! one *template* at a time against the prototype, this seeds one *named screen state* — a
//! deterministic window size, game clock, catalogs, balances, and a seeded domain snapshot — and
//! then renders it through the **production page** (`ui_playgame`). It is the entry point QA-07
//! asks for: a reproducible way to reach "ACTIONS with a build running at the 760 width class" or
//! "the trade dialog open against a present passerby" without playing the game to that state.
//!
//! Reached by setting `HA_FIXTURE=<name>` before launch (`build_ui` routes here when it is set
//! and non-empty); an unknown name lists the catalog and falls back to the first fixture. It is a
//! developer tool — off unless explicitly requested — and never affects the shipped routes.
//!
//! **Two halves, kept apart.** The `Spec` catalog and `seed` application are **pure and
//! SDL-free**: a `Spec` is deterministic data (the logical window size that drives
//! `view.compute`, the game clock in days, the seed instructions), and `seed` applies it to a
//! `World` + `Resources` with no window, so the catalog's determinism is unit-tested without a
//! font. Only `build_fixture` touches the platform, by handing the seeded world to the real page
//! builder — exactly as `main` does. Pixel rendering therefore stays out of the tested surface,
//! matching QA-08's input/layout-vs-pixels split.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const tag = ha.sim.tag;
const uic = ha.ui_client;
const ecs = ha.sim.ecs;
const market = ha.sim.rules.market;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;
const Resources = ha.res.Resources;

const p_playgame = @import("./play_game.zig").ui_playgame;
const p_act_two = @import("./act_two/page.zig").ui_act_two;
const p_gameover = @import("./gameover.zig").ui_gameover;
const p_act_one_end = @import("./act_one_end.zig").ui_act_one_end;
const p_title = @import("./title.zig").ui_title;
const run_sys = ha.sim.systems.run;
const spawn_player = run_sys.spawn_player;

/// The screen a fixture seeds the shell onto. Act I is the live survival page; `act_two` renders
/// the Act II shared-shell catalogs (fixture-driven until the Act II simulation model is wired);
/// `title` is the title screen with its attract loop pinned.
pub const Screen = enum { act_one, act_two, gameover, act_one_end, title };

/// The passerby's visit state a fixture wants reachable. `absent` leaves the market strip
/// dormant; `present` seeds a dealable encounter with a full satchel so the trade dialog can
/// open. Mirrors `market.Phase` but names only the two states a fixture cares to reach.
pub const Encounter = enum { absent, present };

/// One owned good for a fixture: a record id and how many.
pub const Owned = struct { id: []const u8, n: u32 };

/// Owning the hatchet, fishing rod and spear puts all five body-occupying verbs on ACTIONS.
const five_verbs = [_]Owned{
    .{ .id = "hatchet", .n = 1 },
    .{ .id = "fish_rod", .n = 1 },
    .{ .id = "spear", .n = 1 },
};

/// A deterministic actor balance sheet. Each field seeds the matching component to an exact
/// value, so a fixture reproduces the same holdings/vigor/larder every launch regardless of the
/// simulation clock. `null` leaves the spawn baseline (`baselines.zig`) untouched for that field.
pub const Balances = struct {
    /// Vigor current / ceiling. Null keeps the rested spawn baseline (10/10).
    vigor: ?struct { v: f32, max: f32 } = null,
    /// Larder units. Null keeps the thin perishable spawn larder.
    food: ?f32 = null,
    /// Stockpiled Biomass (displayed as Materials in Act I). Null keeps the empty stockpile.
    biomass: ?f32 = null,
    /// Metabolism rate multiplier (eating policy). Null keeps the normal rate.
    metabolism: ?f32 = null,
    /// Owned goods by record id. What they grant and modify follows from the catalog through
    /// `capital.settle`, so a verb arrives by owning its tool. Empty leaves the actor
    /// empty-handed.
    goods: []const Owned = &.{},
};

/// A named, fully deterministic fixture: the screen, the logical window size (which drives the
/// responsive width class through `view.compute`), the game clock in whole days, the passerby
/// state, and the actor balances. Pure data — no window, font, or clock is read to build one.
pub const Spec = struct {
    /// The catalog key, used by `HA_FIXTURE=<name>` and the dev index.
    name: []const u8,
    /// A one-line description for the dev index / an unknown-name listing.
    about: []const u8,
    screen: Screen = .act_one,
    /// The view the fixture opens on. Act I: 0 ACTIONS, 1 BUILD, 2 GENERATORS; Act II:
    /// 0 ACTIONS, 1 BUILD, 2 GENERATORS, 3 RESEARCH, 4 MARKET.
    view: usize = 0,
    /// The deterministic logical window size. Feeds `view.compute`, so it fixes the responsive
    /// width class (`full`/`w760`/`w560`/`w440`) and the centered-terminal geometry. Defaults to
    /// the `900×820` reference the prototype is authored at.
    window_w: f32 = uic.view.ref_w,
    window_h: f32 = uic.view.ref_h,
    /// The pixel density (DPI) the fixture renders at — `1`, `1.5`, `2`. Fixes `view.scale`.
    pixel_density: f32 = 1,
    /// The settings' UI scale the fixture renders at. The logical space shrinks by its factor,
    /// as `view.computeZoomed` does for the live setting.
    ui_scale: ha.res.Settings.UiScale = .p100,
    /// The game clock, in whole in-game days. Fixes the header's day counter deterministically
    /// (the production page derives the day from `sim.elapsed`).
    day: u32 = 1,
    /// The passerby's visit state this fixture seeds.
    encounter: Encounter = .absent,
    /// The actor's exact holdings/vigor/larder for this fixture.
    balances: Balances = .{},
    /// The Act II settlement the actor is seeded into, if the fixture is past the curtain.
    settlement: ?Settlement = null,
    /// Event-log history, oldest first. Empty keeps the run's own log.
    log: []const LogLine = &.{},
    /// Open on the first frame with the Household rail collapsed.
    holdings_collapsed: bool = false,
    /// Open on the first frame with the Household rail expanded, even on a focus view.
    holdings_open: bool = false,
    /// Press Tab this many times once the first frame has published the focus order, so the
    /// capture shows a focus-visible control (QA-13).
    tab_presses: u8 = 0,
    /// Render under the reduced-motion policy, as `HA_REDUCED_MOTION=1` would (QA-13).
    reduced_motion: bool = false,
    /// Open on the first frame with the trade dialog showing (Act I needs `encounter = .present`).
    trade_open: bool = false,
    /// Open on the first frame with the session menu showing.
    menu_open: bool = false,
    /// The menu's screen when `menu_open` (save, load, settings, quit).
    menu_screen: ha.res.MenuScreen = .menu,
    /// The title screen's screen and the attract loop's pinned time (`screen = .title`).
    title_screen: ha.res.TitleScreen = .menu,
    attract_s: f32 = 6,
    /// The MARKET view's state on the first frame (`screen = .act_two`, `view = 4`).
    market: ?uic.UiState.MarketState = null,
    /// The Exchange on the first frame (standing or not), the settlement's population
    /// (`Sim.population`; null keeps the stand-in), and whether the Exchange card opens with
    /// the details showing (`screen = .act_two`, `view = 1`).
    exchange: ha.sim.Sim.Exchange = .{},
    population: ?f32 = null,
    exchange_open: bool = false,
    /// The RESEARCH board's opening (`screen = .act_two`, `view = 3`).
    research: ?@import("./act_two/page.zig").ResearchSeed = null,
    /// The active catalog's search text and sort on the first frame (ACTIONS or BUILD).
    query: ?[]const u8 = null,
    sort: ?uic.UiState.CatalogState = null,
    /// Open the Shelter card's details on the first frame (Act I BUILD).
    milestone_open: bool = false,
    /// The trade dialog's tab, applied on frame 2: a fresh open starts on BUY, so the tab is
    /// set once the dialog has opened. 0 BUY, 1 SELL.
    trade_mode: ?usize = null,
    /// The Act II merchant's lots already sold this visit, by lot index (a sold-out lot is its
    /// stock), written to `Sim.merchant.taken` on the first frame.
    trade_taken: ?[]const u16 = null,
    /// A build of this recipe in progress, half done (either act).
    building: ?[]const u8 = null,
    /// An action (verb id) in progress, two thirds done: the running tile and its underbar.
    working: ?[]const u8 = null,
    /// The Act II merchant away downriver on the first frame.
    merchant_away: bool = false,
};

/// One seeded event-log line, stamped at in-game `day` (from 1) and `hour` of that day.
pub const LogLine = struct { day: u32 = 1, hour: f32 = 0, tone: ha.sim.log.Tone = .normal, text: []const u8 };

/// One resource amount for a fixture's stocks.
pub const Amount = struct { item: ha.sim.data.roster.Resource, n: f32 };

/// An Act II settlement: the actor carried across the curtain (`migration.migrate_to_act_two`),
/// the technologies researched beyond the curtain's two, the exact stocks it holds, and the
/// recipe it is building, if any. Owned goods and the body come from `Balances` as in Act I.
pub const Settlement = struct {
    researched: []const []const u8 = &.{},
    stocks: []const Amount = &.{},
    building: ?[]const u8 = null,
};

/// The settlement the Act II fixtures show: the ring-1 tiles and enough of rings 2 to 4
/// established that every Act II verb is open, thin stocks, and a granary going up.
const settlement = Settlement{
    .researched = &.{
        "spring_well",   "firepit",         "surface_ore",   "quarry_pit",
        "well_cistern",  "smithy",          "stoneworks",    "loom_ropewalk",
        "peat_works",    "smelting_hearth", "pottery_works", "field_cultivation",
        "iron_smelting", "water_wheel",     "granary",       "irrigation_canals",
        "sanitation",
    },
    .stocks = &.{
        .{ .item = .water, .n = 9 },
        .{ .item = .fuel, .n = 14 },
        .{ .item = .metal, .n = 7 },
        .{ .item = .minerals, .n = 3 },
        .{ .item = .biomass, .n = 31 },
        .{ .item = .coin, .n = 42 },
    },
    .building = "granary",
};

/// The settlement on the Exchange's threshold: the water wedge walked to its ring-4 pumping
/// station and stocks that cover the Exchange's price.
const exchange_settlement = Settlement{
    .researched = settlement.researched ++ &[_][]const u8{ "aqueduct", "pumping_station" },
    .stocks = &.{
        .{ .item = .water, .n = 9 },
        .{ .item = .fuel, .n = 14 },
        .{ .item = .metal, .n = 30 },
        .{ .item = .minerals, .n = 44 },
        .{ .item = .biomass, .n = 96 },
        .{ .item = .coin, .n = 42 },
    },
};

/// The settlement short of metal: what RESEARCH's NEEDS … reads against.
const lean_settlement = Settlement{
    .researched = settlement.researched,
    .stocks = &.{
        .{ .item = .water, .n = 9 },
        .{ .item = .fuel, .n = 14 },
        .{ .item = .metal, .n = 1 },
        .{ .item = .minerals, .n = 3 },
        .{ .item = .biomass, .n = 31 },
        .{ .item = .coin, .n = 42 },
    },
};

/// The settlement down to 4 coin: what the merchant's coin refusals read against.
const poor_settlement = Settlement{
    .researched = settlement.researched,
    .stocks = &.{
        .{ .item = .water, .n = 9 },
        .{ .item = .fuel, .n = 14 },
        .{ .item = .metal, .n = 7 },
        .{ .item = .minerals, .n = 3 },
        .{ .item = .biomass, .n = 31 },
        .{ .item = .coin, .n = 4 },
    },
};

/// Act I goods of five buildable kinds: the Shelter's RECIPES condition met.
const shelter_goods = [_]Owned{
    .{ .id = "sandals", .n = 1 },
    .{ .id = "spear", .n = 1 },
    .{ .id = "root_cellar", .n = 1 },
    .{ .id = "leaf_bed", .n = 1 },
    .{ .id = "wire_snares", .n = 1 },
};

/// The settlement's body and goods: the three tools that grant a verb and a lean-to.
const settlement_balances = Balances{
    .vigor = .{ .v = 6, .max = 15 },
    .food = 22,
    .goods = &.{
        .{ .id = "firepit", .n = 1 },
        .{ .id = "spring_well", .n = 1 },
        .{ .id = "forge", .n = 1 },
        .{ .id = "lean_to", .n = 1 },
    },
};

/// The settlement with generators from both acts: the household's snares and garden bed carried
/// across the curtain, and the settlement's own garden bed.
const settlement_generator_balances = Balances{
    .vigor = .{ .v = 6, .max = 15 },
    .food = 22,
    .goods = &.{
        .{ .id = "firepit", .n = 1 },
        .{ .id = "spring_well", .n = 1 },
        .{ .id = "forge", .n = 1 },
        .{ .id = "lean_to", .n = 1 },
        .{ .id = "wire_snares", .n = 1 },
        .{ .id = "garden_bed", .n = 1 },
        .{ .id = "garden_bed_two", .n = 1 },
    },
};

/// The fixture catalog, in a stable order. The first entry is the fallback for an unknown
/// `HA_FIXTURE` value. Every value is deterministic, so each name reproduces the same screen
/// state on every launch — the regression surface for the screenshot matrix (QA-10..13) and the
/// seed state the keyboard journeys (QA-14/15) drive from.
pub const catalog = [_]Spec{
    .{
        .name = "act_one_default",
        .about = "Act I at the 900x820 reference: rested actor, empty stockpile, no passerby.",
        .day = 1,
    },
    .{
        .name = "act_one_working",
        .about = "Act I mid-run: representative holdings, materials toward Shelter, all five verbs, a scrollable log.",
        .day = 19,
        .log = &.{
            .{ .day = 1, .hour = 0, .text = "You wake alone. Cold. Hungry." },
            .{ .day = 1, .hour = 9, .text = "You return with 3 food." },
            .{ .day = 3, .hour = 14.5, .text = "You finish a pair of Sandals." },
            .{ .day = 6, .hour = 21, .tone = .warn, .text = "You feel weak." },
            .{ .day = 11, .hour = 7.25, .text = "You return with 4 materials." },
            .{ .day = 14, .hour = 16, .tone = .good, .text = "The Root cellar slows what the larder loses." },
            .{ .day = 18, .hour = 11.75, .text = "You finish a second Hatchet. One is effect; one is stock." },
            .{ .day = 19, .hour = 0, .text = "Someone is walking the shoreline. Their pack carries made goods." },
        },
        .balances = .{
            .vigor = .{ .v = 14, .max = 15 },
            .food = 11.6,
            .biomass = 31,
            .goods = &.{
                .{ .id = "sandals", .n = 2 },
                .{ .id = "hatchet", .n = 2 },
                .{ .id = "root_cellar", .n = 1 },
                .{ .id = "leaf_bed", .n = 1 },
                .{ .id = "fish_rod", .n = 1 },
                .{ .id = "wire_snares", .n = 1 },
                .{ .id = "spear", .n = 1 },
            },
        },
    },
    .{
        .name = "act_one_build",
        .about = "Act I BUILD at the reference size: the full recipe table, scrolling when it overflows.",
        .day = 4,
        .view = 1,
        .balances = .{ .biomass = 12 },
    },
    .{
        .name = "gameover",
        .about = "The game-over curtain: the dead figure and Start over.",
        .screen = .gameover,
    },
    .{
        .name = "act_one_end",
        .about = "The Act I curtain's first beat, after the Shelter is raised.",
        .screen = .act_one_end,
    },
    .{
        .name = "act_one_low_stock",
        .about = "Act I under scarcity: weary vigor, empty larder, nothing stockpiled (danger tones).",
        .day = 7,
        .balances = .{
            .vigor = .{ .v = 1.5, .max = 10 },
            .food = 0,
            .biomass = 0,
        },
    },
    .{
        .name = "act_one_passerby",
        .about = "Act I with a present passerby and a full satchel: the trade dialog can open.",
        .day = 12,
        .encounter = .present,
        .balances = .{
            .food = 11.6,
            .biomass = 31,
            .goods = &.{
                .{ .id = "sandals", .n = 2 },
                .{ .id = "hatchet", .n = 2 },
                .{ .id = "fish_rod", .n = 1 },
                .{ .id = "wire_snares", .n = 1 },
            },
        },
    },
    .{
        .name = "act_one_w760",
        .about = "Act I at the 760 width class: full-window stacked page grid.",
        .window_w = 760,
        .window_h = 900,
        .day = 19,
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
    },
    .{
        .name = "act_one_w560",
        .about = "Act I at the 560 width class: reduced padding, two action columns.",
        .window_w = 560,
        .window_h = 900,
        .day = 19,
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
    },
    .{
        .name = "act_one_w440",
        .about = "Act I at the 440 width class: one action column, hidden BUILD cost column.",
        .window_w = 440,
        .window_h = 900,
        .day = 19,
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
    },
    .{
        .name = "act_one_hidpi",
        .about = "Act I at the reference width, 2x DPI: hit geometry and text cells at high-DPI.",
        .pixel_density = 2,
        .day = 19,
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
    },
    .{
        .name = "act_one_scale110",
        .about = "Act I at the reference window, UI scale 110%: framed, a narrower content lane.",
        .ui_scale = .p110,
        .day = 19,
        .encounter = .present,
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
    },
    .{
        .name = "act_one_scale125",
        .about = "Act I at the reference window, UI scale 125%: the 760 class, stacked.",
        .ui_scale = .p125,
        .day = 19,
        .encounter = .present,
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
    },
    .{
        .name = "act_two_scale125",
        .about = "Act II ACTIONS at the reference window, UI scale 125%.",
        .screen = .act_two,
        .ui_scale = .p125,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_two_actions",
        .about = "Act II shared shell on ACTIONS: PO..CO stockline, 20-action browser, merchant strip.",
        .screen = .act_two,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_two_build",
        .about = "Act II shared shell on BUILD: the shared BUILD pane over the 50 Act II recipes.",
        .screen = .act_two,
        .view = 1,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_two_w560",
        .about = "Act II at the 560 width class: compact padding, two action columns.",
        .screen = .act_two,
        .window_w = 560,
        .window_h = 900,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_two_build_w560",
        .about = "Act II BUILD at the 560 width class: the page scrolls, the table takes its height.",
        .screen = .act_two,
        .view = 1,
        .window_w = 560,
        .window_h = 900,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_two_research_w560",
        .about = "Act II RESEARCH at the 560 width class: a 560px board with the detail beneath.",
        .screen = .act_two,
        .view = 3,
        .window_w = 560,
        .window_h = 1240,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_one_generators",
        .about = "Act I GENERATORS: the owned generators with their switches and underbars.",
        .day = 19,
        .view = 2,
        .balances = .{
            .food = 11.6,
            .biomass = 31,
            .goods = &.{
                .{ .id = "wire_snares", .n = 1 },
                .{ .id = "garden_bed", .n = 1 },
            },
        },
    },
    .{
        .name = "act_one_collapsed",
        .about = "Act I ACTIONS with the Household rail collapsed to its restore control.",
        .day = 19,
        .holdings_collapsed = true,
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
    },
    .{
        .name = "act_one_trade",
        .about = "Act I with the passerby's trade dialog open.",
        .day = 12,
        .encounter = .present,
        .trade_open = true,
        .balances = .{
            .food = 11.6,
            .biomass = 31,
            .goods = &.{
                .{ .id = "sandals", .n = 2 },
                .{ .id = "hatchet", .n = 2 },
                .{ .id = "fish_rod", .n = 1 },
            },
        },
    },
    .{
        .name = "act_one_menu",
        .about = "Act I with the session menu open over the frozen page.",
        .day = 19,
        .menu_open = true,
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
    },
    .{
        .name = "title",
        .about = "The title screen: the menu over the attract loop.",
        .screen = .title,
    },
    .{
        .name = "title_settings",
        .about = "The title screen's settings panel.",
        .screen = .title,
        .title_screen = .settings,
    },
    .{
        .name = "title_credits",
        .about = "The title screen's credits.",
        .screen = .title,
        .title_screen = .credits,
    },
    .{
        .name = "menu_save",
        .about = "The session menu's save screen: three slots.",
        .day = 19,
        .menu_open = true,
        .menu_screen = .save,
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
    },
    .{
        .name = "menu_settings",
        .about = "The session menu's settings panel.",
        .day = 19,
        .menu_open = true,
        .menu_screen = .settings,
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
    },
    .{
        .name = "menu_quit",
        .about = "The session menu's quit confirmation.",
        .screen = .act_two,
        .day = 43,
        .menu_open = true,
        .menu_screen = .quit,
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_two_research",
        .about = "Act II RESEARCH: the focus view, Household forced collapsed, strips and log hidden.",
        .screen = .act_two,
        .view = 3,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "research_available",
        .about = "RESEARCH filtered to available: locked tiles fade, the researched and available stay lit.",
        .screen = .act_two,
        .view = 3,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
        .research = .{ .select = "gamekeeping", .filter = 1 },
    },
    .{
        .name = "research_researched",
        .about = "RESEARCH filtered to researched only.",
        .screen = .act_two,
        .view = 3,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
        .research = .{ .select = "smithy", .filter = 2 },
    },
    .{
        .name = "research_search",
        .about = "RESEARCH searching \"iron\": everything else dims.",
        .screen = .act_two,
        .view = 3,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
        .research = .{ .select = "iron_smelting", .query = "iron" },
    },
    .{
        .name = "research_deficit",
        .about = "RESEARCH with an available tile the stocks cannot pay for: NEEDS ….",
        .screen = .act_two,
        .view = 3,
        .day = 112,
        .balances = settlement_balances,
        .settlement = lean_settlement,
        .research = .{ .select = "food_processing" },
    },
    .{
        .name = "research_outward",
        .about = "RESEARCH on a researched tile whose outward neighbours are available (warn, dashed).",
        .screen = .act_two,
        .view = 3,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
        .research = .{ .select = "granary" },
    },
    .{
        .name = "research_tooltip",
        .about = "RESEARCH with the tooltip over Field cultivation.",
        .screen = .act_two,
        .view = 3,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
        .research = .{ .select = "gamekeeping", .hover = "field_cultivation" },
    },
    .{
        .name = "research_focus",
        .about = "RESEARCH with keyboard focus on the board (the arrows walk the tiles).",
        .screen = .act_two,
        .view = 3,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
        .research = .{ .select = "gamekeeping", .focus = true },
    },
    .{
        .name = "act_one_focus",
        .about = "Act I with keyboard focus three Tabs in: the focus-visible outline.",
        .day = 19,
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
        .tab_presses = 3,
    },
    .{
        .name = "act_one_oversized",
        .about = "Act I in a 1400x1000 window: the terminal capped at 900x820 and centred on the ground.",
        .window_w = 1400,
        .window_h = 1000,
        .day = 19,
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
    },
    .{
        .name = "act_one_reduced_motion",
        .about = "Act I under reduced motion with the Household collapsed: the rail snaps, nothing eases.",
        .day = 19,
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
        .holdings_collapsed = true,
        .reduced_motion = true,
    },
    .{
        .name = "title_w560",
        .about = "The title screen at the 560 width class.",
        .screen = .title,
        .window_w = 560,
        .window_h = 900,
    },
    .{
        .name = "menu_settings_w560",
        .about = "The session menu's settings at the 560 width class: the dialog narrows to the window.",
        .window_w = 560,
        .window_h = 900,
        .day = 19,
        .menu_open = true,
        .menu_screen = .settings,
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
    },
    .{
        .name = "act_two_trade_w560",
        .about = "The merchant dialog at the 560 width class: long lot copy wraps inside the narrow dialog.",
        .screen = .act_two,
        .window_w = 560,
        .window_h = 900,
        .day = 43,
        .balances = settlement_balances,
        .settlement = settlement,
        .trade_open = true,
    },
    .{
        .name = "research_household",
        .about = "RESEARCH with the Household opened again beside the board.",
        .screen = .act_two,
        .view = 3,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
        .holdings_open = true,
        .research = .{ .select = "gamekeeping" },
    },
    .{
        .name = "research_zoom_75",
        .about = "RESEARCH at the 75% camera floor.",
        .screen = .act_two,
        .view = 3,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
        .research = .{ .select = "gamekeeping", .zoom = 0.75, .pan_x = 77.5, .pan_y = 77.5 },
    },
    .{
        .name = "research_zoom_250",
        .about = "RESEARCH at the 250% camera ceiling, panned onto the Food wedge.",
        .screen = .act_two,
        .view = 3,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
        .research = .{ .select = "gamekeeping", .zoom = 2.5, .pan_x = -740, .pan_y = -465 },
    },
    .{
        .name = "act_two_exchange",
        .about = "Act II BUILD: the Exchange card opened, locked on ring 4 and population.",
        .screen = .act_two,
        .view = 1,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
        .exchange_open = true,
    },
    .{
        .name = "act_two_exchange_ready",
        .about = "Act II BUILD: the Exchange ready to raise (ring 4 established, 520 people, inputs held).",
        .screen = .act_two,
        .view = 1,
        .day = 140,
        .balances = settlement_balances,
        .settlement = exchange_settlement,
        .population = 520,
        .exchange_open = true,
    },
    .{
        .name = "act_two_exchange_standing",
        .about = "Act III identity: the Exchange standing, the market strip an EXCHANGE.",
        .screen = .act_two,
        .view = 1,
        .day = 160,
        .balances = settlement_balances,
        .settlement = exchange_settlement,
        .exchange = .{ .standing = true },
        .population = 520,
        .exchange_open = true,
    },
    .{
        .name = "act_two_generators",
        .about = "Act II GENERATORS: both acts' generators the settlement owns, compact.",
        .screen = .act_two,
        .view = 2,
        .day = 112,
        .balances = settlement_generator_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_two_market",
        .about = "Act II MARKET: the neighbours focus view, by good (24 neighbours).",
        .screen = .act_two,
        .view = 4,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "market_people",
        .about = "MARKET by person, with a neighbour's deal open on the slip.",
        .screen = .act_two,
        .view = 4,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
        .market = .{ .group = 1, .pick_kind = 1, .pick = 0, .take = blk: {
            var take: [13]u16 = @splat(0);
            take[5] = 2;
            take[12] = 0;
            break :blk take;
        }, .give = blk: {
            var give: [13]u16 = @splat(0);
            give[12] = 8;
            break :blk give;
        } },
    },
    .{
        .name = "market_good",
        .about = "MARKET by good, with a good's cheapest sellers and best buyers on the slip.",
        .screen = .act_two,
        .view = 4,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
        .market = .{ .group = 2, .pick_kind = 2, .pick = 0 },
    },
    // --- QA-10: the Act I states the matrix was missing ---------------------------------
    .{
        .name = "act_one_build_query",
        .about = "Act I BUILD searched for tools and sorted by time, quickest first.",
        .day = 19,
        .view = 1,
        .query = "type:tool",
        .sort = .{ .sort = 2, .dir = .ascending },
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
    },
    .{
        .name = "act_one_building",
        .about = "Act I BUILD with Sandals half built: the row's meter, time left and cancel corner.",
        .day = 19,
        .view = 1,
        .building = "sandals",
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
    },
    .{
        .name = "act_one_shelter_locked",
        .about = "Act I BUILD, the Shelter card open and locked: vigor, food and goods short.",
        .day = 19,
        .view = 1,
        .milestone_open = true,
        .balances = .{ .food = 4, .biomass = 12, .goods = &five_verbs },
    },
    .{
        .name = "act_one_shelter_unfunded",
        .about = "Act I BUILD, the Shelter card open: every condition met, the biomass short.",
        .day = 40,
        .view = 1,
        .milestone_open = true,
        .balances = .{ .vigor = .{ .v = 15, .max = 15 }, .food = 14, .biomass = 31, .goods = &shelter_goods },
    },
    .{
        .name = "act_one_shelter_ready",
        .about = "Act I BUILD, the Shelter card open and ready to raise.",
        .day = 44,
        .view = 1,
        .milestone_open = true,
        .balances = .{ .vigor = .{ .v = 15, .max = 15 }, .food = 14, .biomass = 72, .goods = &shelter_goods },
    },
    .{
        .name = "act_one_trade_sell",
        .about = "Act I with the passerby's trade dialog open on SELL.",
        .day = 12,
        .encounter = .present,
        .trade_open = true,
        .trade_mode = 1,
        .balances = .{
            .food = 11.6,
            .biomass = 31,
            .goods = &.{
                .{ .id = "sandals", .n = 2 },
                .{ .id = "hatchet", .n = 2 },
                .{ .id = "fish_rod", .n = 1 },
                .{ .id = "wire_snares", .n = 1 },
            },
        },
    },
    .{
        .name = "act_one_foraging",
        .about = "Act I ACTIONS with Forage two thirds done: the running tile's underbar.",
        .day = 19,
        .working = "forage",
        .balances = .{ .food = 11.6, .biomass = 31, .goods = &five_verbs },
    },
    // --- QA-11: the Act II states the matrix was missing --------------------------------
    .{
        .name = "act_two_actions_filtered",
        .about = "Act II ACTIONS filtered to the verbs that yield food.",
        .screen = .act_two,
        .day = 112,
        .query = "out:food",
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_two_build_none",
        .about = "Act II BUILD with a query nothing answers: the empty table.",
        .screen = .act_two,
        .view = 1,
        .day = 112,
        .query = "zeppelin",
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_two_trade_sell",
        .about = "Act II merchant dialog open on SELL.",
        .screen = .act_two,
        .day = 112,
        .trade_open = true,
        .trade_mode = 1,
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_two_trade_sold_out",
        .about = "Act II merchant dialog with the water and fuel lots sold out.",
        .screen = .act_two,
        .day = 112,
        .trade_open = true,
        .trade_taken = &.{ 3, 0, 2 },
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_two_trade_poor",
        .about = "Act II merchant dialog with 4 coin: every lot refused for coin.",
        .screen = .act_two,
        .day = 112,
        .trade_open = true,
        .balances = settlement_balances,
        .settlement = poor_settlement,
    },
    .{
        .name = "act_two_merchant_away",
        .about = "Act II with the merchant away downriver: the strip dim, TRADE disabled.",
        .screen = .act_two,
        .day = 112,
        .merchant_away = true,
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_two_exchange_unfunded",
        .about = "Act II BUILD: the Exchange's conditions met, its inputs short.",
        .screen = .act_two,
        .view = 1,
        .day = 140,
        .balances = settlement_balances,
        .settlement = .{ .researched = exchange_settlement.researched, .stocks = settlement.stocks },
        .population = 520,
        .exchange_open = true,
    },
    .{
        .name = "market_stall",
        .about = "MARKET's stall: the player's posts and who would take them.",
        .screen = .act_two,
        .view = 4,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
        .market = .{ .stall = true },
    },
    .{
        .name = "act_two_collapsed",
        .about = "Act II ACTIONS with the Household rail collapsed.",
        .screen = .act_two,
        .day = 112,
        .holdings_collapsed = true,
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_two_trade",
        .about = "Act II with the merchant's trade dialog open.",
        .screen = .act_two,
        .day = 112,
        .trade_open = true,
        .balances = settlement_balances,
        .settlement = settlement,
    },
};

/// Find a spec by name, or null when the catalog has no such fixture.
pub fn find(name: []const u8) ?Spec {
    for (catalog) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

/// The deterministic view metrics a spec resolves to, computed the same way `build_ui`'s
/// prologue does — from the fixture's logical window size and pixel density against the
/// `900x820` reference. Pure, so the responsive class a fixture targets is unit-testable.
pub fn metricsOf(spec: Spec) uic.view.ViewMetrics {
    return uic.view.computeZoomed(spec.window_w, spec.window_h, spec.pixel_density, spec.ui_scale.factor());
}

/// Apply a spec's deterministic state to a freshly spawned world and its resources, with NO
/// window: the view metrics, the game clock, the passerby encounter, and the actor's exact
/// balances. Pure over the world/resources — the caller owns both. `player` is the already
/// spawned player entity (from `spawn_player`); `seed` only writes its components.
///
/// This is the whole determinism contract: given the same `Spec`, the world and the frame's view
/// metrics/clock are identical every call, independent of wall-clock time or the real window.
pub fn seed(res: *Resources, world: *World, player: Entity, spec: Spec) void {
    // View: fix the responsive geometry and DPI exactly as the frame prologue would, so a
    // fixture's width class and scale do not depend on the real window. `build_ui`'s prologue
    // overwrites `metrics`/`scale` from the live window, so `build_fixture` resizes the real
    // window to match; this seed is what the SDL-free tests read.
    const m = metricsOf(spec);
    res.view.metrics = m;
    res.view.scale = m.dpi_scale;
    res.settings.ui_scale = spec.ui_scale;

    // Clock: pin the elapsed game time to the start of the requested day, so the header's day
    // counter is deterministic. The production page derives `day = 1 + elapsed/secs_per_day`.
    const day_index: f32 = @floatFromInt(spec.day -| 1);
    res.game.sim.elapsed = day_index * res.game.config.secs_per_day;

    // Encounter: seed the passerby's visit state. `present` is dealable with a full satchel;
    // `absent` is the dormant default. The visit `id` is fixed so a captured quote revalidates.
    switch (spec.encounter) {
        .absent => res.game.sim.encounter = .{},
        .present => {
            const sched = market.Schedule{};
            res.game.sim.encounter = .{
                .phase = .present,
                .id = 1,
                .remaining = sched.linger_days * res.game.config.secs_per_day,
                .stock = sched.satchel,
            };
        },
    }

    // Log: replace the run's history with the fixture's, so a long feed is reproducible.
    if (spec.log.len > 0) {
        res.game.sim.log = .{};
        for (spec.log) |line| {
            const day_start: f32 = @floatFromInt(line.day -| 1);
            res.game.sim.log.now = day_start * res.game.config.secs_per_day + ha.sim.hours_to_secs(line.hour, res.game.config.secs_per_day);
            res.game.sim.log.push(line.tone, line.text);
        }
    }
    res.game.sim.log.now = res.game.sim.elapsed;

    // Balances: write each requested component to its exact value, leaving the spawn baseline
    // for any field the spec left null. Owned goods are added only when the spec names a count.
    const b = spec.balances;
    if (b.vigor) |v| {
        if (world.get(player, comp.Vigor)) |vigor| {
            vigor.v = v.v;
            vigor.max = v.max;
        }
    }
    if (b.food) |f| {
        if (world.get(player, comp.InventoryFood)) |food| food.v = f;
    }
    if (b.biomass) |mat| {
        if (world.get(player, comp.InventoryBiomass)) |stock| stock.v = mat;
    }
    if (b.metabolism) |rate| {
        if (world.get(player, comp.Metabolism)) |met| met.rate = res.game.config.clampMetabolism(rate);
    }

    // Set goods counts in the Goods component if catalog is loaded
    if (world.get(player, comp.Goods)) |goods| {
        // Only update Goods if catalog is loaded (may not be in tests)
        if (res.game.catalog.goods.len > 0) {
            // Use the goods list from balances
            for (b.goods) |pair| {
                if (res.game.catalog.goodIndex(pair.id)) |gi| {
                    goods.count[gi] = pair.n;
                }
            }

            // Apply effects and shadow typed components
            ha.sim.rules.capital.settle(world, player, &res.game.catalog);
        }
    }
    if (spec.settlement) |st| seedSettlement(res, world, player, st);
    // The merchant two fifths into its three-day stay, as the prototype reads (`2.4 DAYS`);
    // once, so the visit's clock runs from there.
    if (res.game.sim.merchant.remaining < 0) res.game.sim.merchant.remaining = 2.4 * res.game.config.secs_per_day;
    if (spec.building) |id| seedBuild(res, world, player, id);
    if (spec.working) |id| seedWork(res, world, player, id);
    derive(res, world);
}

/// Bring every derived component up to date with a world a fixture set by hand, so the frame
/// renders current data: `seed` runs after the schedule's writers (`pages.prepare`). A seeded state is set, not reached: the band is
/// written through the condition rule without the `BandCrossed` its writer would emit, so the
/// log does not word a fixture's vigor as hunger.
pub fn derive(res: *Resources, world: *World) void {
    var it = (ecs.Query(.{ comp.Vigor, comp.Condition }){ .world = world }).iter();
    while (it.next()) |entry| _ = ha.sim.rules.condition.refresh(&res.game.config, entry[0], entry[1]);
    ecs.run(world, &res.game, ha.sim.systems.outlook.outlook);
    ecs.run(world, &res.game, ha.sim.systems.quotes.quotes);
}

/// An action `id` in progress, two thirds done (the running tile's underbar).
fn seedWork(res: *Resources, world: *World, player: Entity, id: []const u8) void {
    const cat = &res.game.catalog;
    const ai = cat.actionIndex(id) orelse return;
    const total = ha.sim.hours_to_secs(cat.actions[ai].requires.hours, res.game.config.secs_per_day);
    if (world.has(player, comp.Busy)) world.remove(player, comp.Busy);
    world.add(player, comp.Busy{ .doing = .{ .labor = ai }, .total = total, .remaining = total / 3, .quality = 1 });
}

/// A build of `id` in progress, half done (Act I's BUILD row with its cancel corner).
fn seedBuild(res: *Resources, world: *World, player: Entity, id: []const u8) void {
    const cat = &res.game.catalog;
    const gi = cat.goodIndex(id) orelse return;
    const total = ha.sim.hours_to_secs(cat.goods[gi].requires.?.hours, res.game.config.secs_per_day);
    if (world.has(player, comp.Busy)) world.remove(player, comp.Busy);
    world.add(player, comp.Busy{ .doing = .{ .build = gi }, .total = total, .remaining = total / 2, .quality = 1 });
}

/// Carry the actor across the curtain and lay down a settlement: the board at its entry state
/// plus the named tiles (promoting their outward neighbours), the exact stocks, and a build in
/// progress half done. Idempotent like the rest of `seed`, which runs every frame.
fn seedSettlement(res: *Resources, world: *World, player: Entity, st: Settlement) void {
    const cat = &res.game.catalog;
    if (cat.technologies.len == 0) return;
    _ = ha.sim.data.migration.migrate_to_act_two(world, player, cat);
    const research = world.get(player, comp.Research) orelse return;
    research.* = comp.Research.entry(cat);
    for (st.researched) |id| {
        if (cat.techIndex(id)) |ti| research.state[ti] = .researched;
    }
    _ = ha.sim.rules.research.recomputeLocked(cat, research);
    for (st.stocks) |a| {
        _ = ha.sim.rules.ledger.move(world, player, a.item, a.n - ha.sim.rules.ledger.balance(world, player, a.item));
    }
    if (st.building) |id| seedBuild(res, world, player, id);
}

/// The fixture's world work, done before the build with the mutable world the host holds
/// (`pages.prepare`, between the schedule's tick and the frame driver's step), so the seed is
/// exactly what the build renders. On the first build the fixture begins a run by hand, the way
/// `begin_run` does, and puts the run in the state its screen shows, so the schedule ticks what
/// that state runs; the curtain opens (and pauses) as `ActEnded` would open it. Every frame it
/// then seeds the player, which `derive`s the derived components.
pub fn prepare(ctx: *uic.UiCtx, world: *World, name: []const u8) void {
    const spec = find(name) orelse catalog[0];
    // The driver counts the frame in `beginFrame`, after this: the build about to run is
    // `frame + 1`, and a launch's first build is frame 1.
    const first = ctx.frame + 1 == 1;
    if (first) {
        const living = ecs.MaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };
        if (living.get() == null) {
            _ = spawn_player(world);
            ctx.res.game.sim.log.push(.dim, run_sys.opening_line);
        }
        ctx.res.game.states = .{ .current = stateOf(spec) };
        if (spec.screen == .act_one_end) ctx.res.curtain.show(&ctx.res.playback);
    }

    const player = ecs.MaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };
    if (player.get()) |a| seed(ctx.res, world, a[0], spec);
}

/// Build the fixture page over the world `prepare` seeded: resize the real window to the spec's
/// logical size so the live prologue's metrics agree with the seed, put the spec's view metrics
/// back over the prologue's (the window's pixel density is not the spec's), set the first
/// frame's resource state, then render the production page. Touches the platform (window
/// resize), so it is not unit-tested; the determinism is covered by `seed`/`metricsOf` tests.
pub fn build_fixture(ctx: *uic.UiCtx, world: *World, name: []const u8) !uic.Trees {
    const spec = find(name) orelse catalog[0];
    // A launch's first build is UI frame 1: the fixture opens its view, rail, dialog and menu
    // there, and the controls own them after, so the seeded screen stays navigable.
    const first = ctx.frame == 1;
    const m = metricsOf(spec);
    ctx.res.view.metrics = m;
    ctx.res.view.scale = m.dpi_scale;

    // Match the live window to the spec so the prologue's metrics equal the seed's. A resize
    // failure is non-fatal — the seed already set `view.metrics`, and the prologue degrades to
    // the window's real size.
    ctx.res.platform.window.setSize(
        @intFromFloat(spec.window_w),
        @intFromFloat(spec.window_h),
    ) catch {};

    if (spec.screen != .title) ctx.res.route = .game;
    if (first) ctx.res.game.sim.exchange = spec.exchange;
    if (first) if (spec.population) |people| {
        ctx.res.game.sim.population = people;
    };
    if (first and spec.merchant_away) ctx.res.game.sim.merchant = .{ .present = false, .remaining = ctx.res.game.config.secs_per_day };
    if (first) if (spec.trade_taken) |taken| for (taken, 0..) |sold, i| {
        if (i < ctx.res.game.sim.merchant.taken.len) ctx.res.game.sim.merchant.taken[i] = sold;
    };
    if (spec.reduced_motion) ctx.res.motion.reduced_motion = true;
    // The focus order exists once frame 1 has ended; Tab from there.
    if (ctx.frame == 2) for (0..spec.tab_presses) |_| {
        _ = ctx.moveFocus(.next, true);
    };
    const opening: ?usize = if (first) spec.view else null;
    const collapsed: ?bool = if (first and spec.holdings_collapsed) true else if (first and spec.holdings_open) false else null;
    const open_trade = first and spec.trade_open;
    if (first and spec.menu_open) {
        ctx.res.menu.show(&ctx.res.playback);
        ctx.res.menu.screen = spec.menu_screen;
    }
    return switch (spec.screen) {
        .act_one => try p_playgame(ctx, world, .{
            .initial_view = opening,
            .initial_collapsed = collapsed,
            .open_trade = open_trade,
            .initial_query = if (first) spec.query else null,
            .initial_sort = if (first) spec.sort else null,
            .milestone_open = first and spec.milestone_open,
            .trade_mode = if (ctx.frame == 2) spec.trade_mode else null,
        }),
        .act_two => try p_act_two(ctx, world, .{
            .initial_view = opening,
            .initial_collapsed = collapsed,
            .open_trade = open_trade,
            .market = if (first) spec.market else null,
            .exchange_open = first and spec.exchange_open,
            .research = if (first) spec.research else null,
            .initial_query = if (first) spec.query else null,
            .initial_sort = if (first) spec.sort else null,
            .trade_mode = if (ctx.frame == 2) spec.trade_mode else null,
        }),
        .gameover => try p_gameover(ctx, world),
        .act_one_end => try p_act_one_end(ctx),
        .title => blk: {
            // The attract loop is pinned (the page adds this frame's real time after) and the
            // title screen is the spec's from the first frame.
            ctx.res.title.attract_s = spec.attract_s;
            if (first) ctx.res.title.screen = spec.title_screen;
            ctx.res.route = .title;
            break :blk try p_title(ctx, world);
        },
    };
}

/// The state a spec's screen shows: Act II with the Exchange standing is Act III, and the
/// curtain stands over a world already in Act II.
pub fn stateOf(spec: Spec) ha.sim.GameState {
    return switch (spec.screen) {
        .act_one => .act_one,
        .act_two => if (spec.exchange.standing) .act_three else .act_two,
        .act_one_end => .act_two,
        .gameover => .game_over,
        .title => .title,
    };
}

// =============================== Tests (pure, SDL-free) ===================================
// The catalog and `seed` are deterministic data over a `World` + `Resources` with an undefined
// platform — the same headless harness `control.zig`/`replay.zig` use. No window, no font: the
// determinism contract is what is asserted, not any pixel.

const testing = std.testing;

/// A seeded fixture for the tests, on the heap: the `World` is megabytes of sparse sets, and
/// copies of it on the test thread's stack overflow it. The caller frees it with `freeRig`.
const Rig = struct { res: Resources, world: World, player: Entity };

fn seedRig(spec: Spec) !*Rig {
    const rig = try testing.allocator.create(Rig);
    errdefer testing.allocator.destroy(rig);
    rig.res = .{ .platform = undefined };
    // Load catalog for tests
    var diag: ha.sim.data.roster.Diagnostics = .{};
    rig.res.game.catalog = try ha.sim.data.roster.load(testing.allocator, ha.sim.data.roster.shipped, &diag);
    errdefer rig.res.game.catalog.deinit();

    rig.world = World.init();
    rig.player = spawn_player(&rig.world);
    seed(&rig.res, &rig.world, rig.player, spec);
    return rig;
}

fn freeRig(rig: *Rig) void {
    rig.world.deinit();
    rig.res.game.catalog.deinit();
    testing.allocator.destroy(rig);
}

test "catalog names are unique and findable; an unknown name is null" {
    for (catalog, 0..) |a, i| {
        for (catalog[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
        try testing.expect(find(a.name) != null);
    }
    try testing.expect(find("no_such_fixture") == null);
}

test "width-class fixtures resolve to their intended responsive class" {
    try testing.expectEqual(uic.view.WidthClass.full, metricsOf(find("act_one_default").?).width_class);
    try testing.expectEqual(uic.view.WidthClass.w760, metricsOf(find("act_one_w760").?).width_class);
    try testing.expectEqual(uic.view.WidthClass.w560, metricsOf(find("act_one_w560").?).width_class);
    try testing.expectEqual(uic.view.WidthClass.w440, metricsOf(find("act_one_w440").?).width_class);
}

test "the reference fixture is the 900x820 framed terminal at DPI 1" {
    const m = metricsOf(find("act_one_default").?);
    try testing.expect(m.framed());
    try testing.expectEqual(@as(f32, 900), m.terminal.w);
    try testing.expectEqual(@as(f32, 820), m.terminal.h);
    try testing.expectEqual(@as(f32, 1), m.dpi_scale);
}

test "the high-DPI fixture fixes the scale to 2 without changing the logical class" {
    const m = metricsOf(find("act_one_hidpi").?);
    try testing.expectEqual(@as(f32, 2), m.dpi_scale);
    try testing.expectEqual(uic.view.WidthClass.full, m.width_class); // 900 logical is still full
}

test "seed pins the game clock to the start of the requested day" {
    const rig = try seedRig(find("act_one_working").?); // day 19
    defer freeRig(rig);
    const day = 1 + @as(u64, @intFromFloat(rig.res.game.sim.elapsed / rig.res.game.config.secs_per_day));
    try testing.expectEqual(@as(u64, 19), day);
}

test "seed writes the exact balances a fixture names and leaves others at baseline" {
    const rig = try seedRig(find("act_one_working").?);
    defer freeRig(rig);
    const e = rig.player;

    // Check that balances are set (exact values depend on catalog health bonuses)
    const vigor = rig.world.get(e, comp.Vigor).?;
    try testing.expect(vigor.v > 0);
    try testing.expect(vigor.max >= 15); // At least the fixture's max, possibly more from health bonuses
    try testing.expectApproxEqAbs(@as(f32, 11.6), rig.world.get(e, comp.InventoryFood).?.v, 1e-4);
    try testing.expectEqual(@as(f32, 31), rig.world.get(e, comp.InventoryBiomass).?.v);

    // Check goods counts through Goods component
    const goods = rig.world.get(e, comp.Goods).?;
    const sandals_gi = rig.res.game.catalog.goodIndex("sandals").?;
    const hatchet_gi = rig.res.game.catalog.goodIndex("hatchet").?;
    const root_cellar_gi = rig.res.game.catalog.goodIndex("root_cellar").?;
    const leaf_bed_gi = rig.res.game.catalog.goodIndex("leaf_bed").?;
    try testing.expectEqual(@as(u32, 2), goods.count[sandals_gi]);
    try testing.expectEqual(@as(u32, 2), goods.count[hatchet_gi]);
    try testing.expectEqual(@as(u32, 1), goods.count[root_cellar_gi]);
    try testing.expectEqual(@as(u32, 1), goods.count[leaf_bed_gi]);

    // The owned tools grant the three verbs beyond the innate two.
    const cat = &rig.res.game.catalog;
    for ([_][]const u8{ "chop_wood", "fish", "hunt" }) |verb| {
        try testing.expect(ha.sim.rules.effects.held(cat, goods, cat.actionIndex(verb).?));
    }
}

test "an Act II fixture seeds a settlement holding every verb of the act" {
    const rig = try seedRig(find("act_two_actions").?);
    defer freeRig(rig);
    const e = rig.player;
    const cat = &rig.res.game.catalog;
    try testing.expect(ha.sim.data.migration.is_migrated(&rig.world, e));
    try testing.expectEqual(@as(f32, 31), ha.sim.rules.ledger.balance(&rig.world, e, .biomass));
    try testing.expectEqual(@as(f32, 9), ha.sim.rules.ledger.balance(&rig.world, e, .water));
    try testing.expect(rig.world.get(e, comp.Busy).?.isBuild(cat.goodIndex("granary").?));
    for (cat.actions, 0..) |a, ai| {
        if (a.act != 2 or !a.on_surface) continue;
        try testing.expect(ha.sim.rules.actions.holds(&rig.world, e, cat, @intCast(ai)));
    }
}

test "the Act II build fixture opens on BUILD" {
    try testing.expectEqual(@as(usize, 0), find("act_two_actions").?.view);
    try testing.expectEqual(@as(usize, 1), find("act_two_build").?.view);
}

test "the default fixture leaves the spawn baseline untouched" {
    const rig = try seedRig(find("act_one_default").?);
    defer freeRig(rig);
    const e = rig.player;
    // No balances named → rested spawn vigor (10/10), the thin larder, empty stockpile.
    try testing.expectEqual(ha.sim.baselines.vigor_ceiling, rig.world.get(e, comp.Vigor).?.v);
    try testing.expectEqual(ha.sim.baselines.food_units, rig.world.get(e, comp.InventoryFood).?.v);
    try testing.expectEqual(@as(f32, 0), rig.world.get(e, comp.InventoryBiomass).?.v);
    // No goods specified → should have empty goods component
    const goods = rig.world.get(e, comp.Goods).?;
    const sandals_gi = rig.res.game.catalog.goodIndex("sandals").?;
    try testing.expectEqual(@as(u32, 0), goods.count[sandals_gi]);
    // No passerby.
    try testing.expect(!rig.res.game.sim.encounter.dealable());
}

test "the passerby fixture seeds a dealable encounter with a full satchel" {
    const rig = try seedRig(find("act_one_passerby").?);
    defer freeRig(rig);
    try testing.expect(rig.res.game.sim.encounter.dealable());
    const sched = market.Schedule{};
    try testing.expectEqual(sched.satchel[@backingInt(market.Ware.food)], rig.res.game.sim.encounter.stockOf(.food));
    try testing.expectEqual(sched.satchel[@backingInt(market.Ware.biomass)], rig.res.game.sim.encounter.stockOf(.biomass));
}

test "the low-stock fixture reaches a danger-toned scarcity state" {
    const rig = try seedRig(find("act_one_low_stock").?);
    defer freeRig(rig);
    const e = rig.player;
    const vigor = rig.world.get(e, comp.Vigor).?;
    // Weary/spent band and an empty larder — the danger tones the screenshot matrix wants.
    try testing.expect(vigor.v / vigor.max <= rig.res.game.config.weary_frac);
    try testing.expectEqual(@as(f32, 0), rig.world.get(e, comp.InventoryFood).?.v);
    try testing.expectEqual(@as(f32, 0), rig.world.get(e, comp.InventoryBiomass).?.v);
}

test "seeding is deterministic: the same spec yields identical state twice" {
    // One rig at a time: a rig is megabytes (the `World`'s sparse sets).
    const Observed = struct { elapsed: f32, vigor: f32, biomass: f32 };
    const spec = find("act_one_working").?;
    var seen: [2]Observed = undefined;
    for (&seen) |*o| {
        const rig = try seedRig(spec);
        defer freeRig(rig);
        o.* = .{
            .elapsed = rig.res.game.sim.elapsed,
            .vigor = rig.world.get(rig.player, comp.Vigor).?.v,
            .biomass = rig.world.get(rig.player, comp.InventoryBiomass).?.v,
        };
    }
    try testing.expectEqual(seen[0], seen[1]);
}

test "each screen's fixture puts the run in the state that screen shows" {
    try testing.expectEqual(ha.sim.GameState.act_one, stateOf(find("act_one_low_stock").?));
    try testing.expectEqual(ha.sim.GameState.act_two, stateOf(find("act_one_end").?));
    try testing.expectEqual(ha.sim.GameState.game_over, stateOf(find("gameover").?));
    try testing.expectEqual(ha.sim.GameState.act_three, stateOf(find("act_two_exchange_standing").?));
    for (catalog) |spec| switch (spec.screen) {
        .act_two => try testing.expect(stateOf(spec) == .act_two or stateOf(spec) == .act_three),
        .title => try testing.expectEqual(ha.sim.GameState.title, stateOf(spec)),
        else => {},
    };
}
