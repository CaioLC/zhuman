//! The simulation's events: the store's namespace (`ecs.Events(@This(), ReaderId)`, held on
//! `sim.Resources.events`). Every public struct here is an event, plain fixed-size data that
//! names agents, records and items by index and amounts by number, never by text.
//!
//! **Intents** say what an agent means to do. The UI writes them; a handler system reads each
//! family and calls the rule that carries it out. **Facts** say what
//! happened. Systems and the rules they call write them; `systems/log.zig` is the one reader that
//! turns them into `Log` lines, and the UI reads them with its own cursor.
//!
//! A refused intent changes nothing and is answered by `Refused`, naming the intent and the gate.
//!
//! The run's lifecycle is events too: `NewRun` asks for a fresh run, `RunBegun` says one began,
//! and `ActEnded` says the player's act ended and the next is requested (`systems/run.zig`,
//! `systems/curtain.zig`).

const ecs = @import("ecs");
const comp = @import("./components.zig");
const ledger = @import("./rules/ledger.zig");
const market = @import("./rules/market.zig");
const neighbours = @import("./rules/neighbours.zig");
const Band = comp.Condition.Band;
const GameState = @import("./state.zig").GameState;

const Entity = ecs.Entity;
const Receipt = ledger.Receipt;

/// Every scheduled reader, one stored cursor each per event type. A handler reads its intent
/// family under its own id; `run` reads `NewRun`; `debug` reads `DebugPoke`; `log` reads every fact.
pub const ReaderId = enum { labor, build, generators, ration, passerby, barter, merchant, research, exchange, neighbours, run, debug, log };

/// Who comes and goes on the sim clock.
pub const Who = enum { passerby, merchant };

// —— intents ——————————————————————————————————————————————————————————————————————

/// Begin labor verb `ai` (`actions.begin`).
pub const BeginLabor = struct { agent: Entity, ai: u16 };
/// Begin building good `gi` (`capital.begin`).
pub const BeginBuild = struct { agent: Entity, gi: u16 };
/// Abandon the build in progress (`capital.cancel_build`).
pub const CancelBuild = struct { agent: Entity };
/// Move generator verb `ai` to its next mode: on, auto, off, on (`capital.toggle_generator`).
pub const ToggleGenerator = struct { agent: Entity, ai: u16 };
/// Collect generator verb `ai`'s cycle (`capital.collect_generator`).
pub const CollectGenerator = struct { agent: Entity, ai: u16 };
/// Set the metabolism rate; the handler clamps it into the configured band.
pub const SetRation = struct { agent: Entity, rate: f32 };
/// Take `lots` of the passerby's offer `quote` (`barter.resolve`), every line scaled by `lots`.
pub const Barter = struct { agent: Entity, quote: market.Quote, lots: u16 };
/// Establish technology `ti` on the research board.
pub const Research = struct { agent: Entity, ti: u16 };
/// Raise the Exchange.
pub const RaiseExchange = struct { agent: Entity };
/// Take `lots` of the Coin Merchant's lot `lot`, an index into `systems/merchant.zig`'s `lots`.
pub const MerchantDeal = struct { agent: Entity, lot: u32, lots: u32 };
/// Settle a deal with stub neighbour `neighbour`: what the agent gives and takes, per item.
pub const NeighbourDeal = struct {
    agent: Entity,
    neighbour: u8,
    give: [neighbours.bundle_len]u16,
    take: [neighbours.bundle_len]u16,
};
/// Begin a fresh run: the current one, if any, is retired. Never refused.
pub const NewRun = struct {};
/// The template audit harness's door: a debug-only poke of one component, applied by `systems/debug.zig`.
pub const DebugPoke = struct {
    pub const What = union(enum) { food: f32, vigor: struct { v: f32, max: f32 }, rate: f32, biomass: f32, good: struct { gi: u16, count: u32 }, settle, generator_mode: struct { ai: u16, mode: comp.Generators.Mode } };
    agent: Entity,
    what: What,
};

// —— facts ————————————————————————————————————————————————————————————————————————

/// An intent was refused and changed nothing.
pub const Refused = struct {
    agent: Entity,
    intent: Intent,
    reason: Reason,

    pub const Intent = enum {
        begin_labor,
        begin_build,
        cancel_build,
        toggle_generator,
        collect_generator,
        set_ration,
        barter,
        research,
        raise_exchange,
        merchant_deal,
        neighbour_deal,
    };

    /// The gate that refused. The labor, build and generator quotes' standings map onto these
    /// by name.
    pub const Reason = enum {
        /// No such verb, recipe or generator for this agent: not held, not buildable, not
        /// owned, or an index the roster does not have.
        unavailable,
        /// The recipe's technology is not researched.
        tech,
        /// A prerequisite verb or tool is not held.
        needs,
        /// The recipe's standing conditions are not met.
        unlock,
        /// The body is occupied.
        busy,
        /// The energy price would take vigor to zero.
        energy,
        /// An input is short.
        short,
        /// The generator's cycle has not matured.
        not_ready,
        /// The generator is switched off.
        off,
        /// No build is in progress.
        nothing_to_cancel,
        /// The counterparty has gone.
        departed,
        /// The offer was made by a visitor who is no longer the one here.
        stale,
        /// The counterparty has no more of it.
        sold_out,
        /// The agent cannot cover the price.
        unaffordable,
        /// The agent does not own the good it offers.
        not_owned,
        /// The agent has no research board.
        no_board,
        /// The milestone's conditions are not met.
        locked,
        /// The milestone already stands.
        already_standing,
        /// The counterparty does not accept the deal in its own valuation.
        not_wanted,
    };
};

/// `agent` began `doing`, paying `energy` and the `paid` lines. `weary` when that payment took
/// it out of the alive band. `act` is the act the agent's words are in.
pub const WorkBegun = struct {
    agent: Entity,
    doing: comp.Busy.Doing,
    weary: bool = false,
    energy: f32 = 0,
    paid: Receipt = .{},
    act: u8 = 1,
};

/// `agent` finished `doing` and `receipt` landed. For a build, `owned` is the count of the good
/// held after it.
pub const WorkDone = struct {
    agent: Entity,
    doing: comp.Busy.Doing,
    receipt: Receipt = .{},
    owned: u32 = 0,
    act: u8 = 1,
};

/// `agent`'s work finished as nothing: the verb was lost mid-task.
pub const WorkLost = struct { agent: Entity, doing: comp.Busy.Doing };

/// `agent` abandoned building `gi` and `refund` came back.
pub const BuildCancelled = struct { agent: Entity, gi: u16, refund: Receipt = .{}, act: u8 = 1 };

/// One unit of `agent`'s good `gi` broke.
pub const GoodBroke = struct { agent: Entity, gi: u16 };

/// `agent` collected generator verb `ai`: `receipt` landed and `vigor` was restored.
pub const Collected = struct { agent: Entity, ai: u16, receipt: Receipt = .{}, vigor: f32 = 0, act: u8 = 1 };

/// `agent`'s condition band changed.
pub const BandCrossed = struct { agent: Entity, from: Band, to: Band };

/// `agent`'s larder emptied.
pub const FoodRanOut = struct { agent: Entity };

/// `agent` died.
pub const Died = struct { agent: Entity };

/// The goods `agent` owns changed.
pub const GoodsChanged = struct { agent: Entity };

/// Recipe `gi`'s prerequisite became satisfied for `agent`.
pub const RecipeInReach = struct { agent: Entity, gi: u16 };

/// `agent` traded with `with` in `direction`, moving `biomass_moved` materials (for a sell to
/// the passerby, what it paid). A merchant trade names the lot by index in the merchant's
/// records (`systems/merchant.zig`) and how many lots it took. `acquired` is the good a buy from
/// the passerby brought in, by catalog index, when it was one. `act` is the act the agent's
/// words are in.
pub const Traded = struct {
    agent: Entity,
    with: Who,
    direction: market.Direction,
    biomass_moved: f32 = 0,
    acquired: ?u16 = null,
    lot: u32 = 0,
    lots: u32 = 0,
    act: u8 = 1,
};

/// `agent` established technology `ti`; `newly` has a bit set, by catalog index, for each
/// tile that became available with it.
pub const Researched = struct { agent: Entity, ti: u16, newly: u64 = 0 };

/// `agent` raised the Exchange.
pub const ExchangeRaised = struct { agent: Entity };

/// `agent` settled a deal with stub neighbour `neighbour`; both sides moved.
pub const NeighbourSettled = struct { agent: Entity, neighbour: u8 };

/// A run began: a fresh player and a reset `Sim`.
pub const RunBegun = struct {};

/// The player's act `act` ended and the next act is requested.
pub const ActEnded = struct { act: GameState };

/// A visitor arrived.
pub const Arrived = struct { who: Who };

/// A visitor left.
pub const Departed = struct { who: Who };
