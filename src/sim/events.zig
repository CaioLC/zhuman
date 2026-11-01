//! The simulation's events: the store's namespace (`ecs.Events(@This(), ReaderId)`, held on
//! `sim.Resources.events`). Every public struct here is an event, plain fixed-size data that
//! names agents, records and items by index and amounts by number, never by text.
//!
//! **Intents** say what an agent means to do. The UI writes them today, a decider will later;
//! a handler system reads each family and calls the rule it already has. **Facts** say what
//! happened. Systems and the rules they call write them; `systems/log.zig` is the one reader that
//! turns them into `Log` lines, and the UI reads them with its own cursor.
//!
//! A refused intent changes nothing and is answered by `Refused`, naming the intent and the gate.

const ecs = @import("ecs");
const comp = @import("./components.zig");
const ledger = @import("./rules/ledger.zig");
const market = @import("./rules/market.zig");
const neighbours = @import("./rules/neighbours.zig");
const Condition = @import("./res.zig").Condition;

const Entity = ecs.Entity;
const Receipt = ledger.Receipt;

/// Every scheduled reader, one stored cursor each per event type. A handler reads its intent
/// family under its own id; `log` reads every fact.
pub const ReaderId = enum { labor, build, generators, ration, passerby, barter, log };

/// Who comes and goes on the sim clock.
pub const Who = enum { passerby, merchant };

// —— intents ——————————————————————————————————————————————————————————————————————

/// Begin labor verb `ai` (`actions.begin`).
pub const BeginLabor = struct { agent: Entity, ai: u16 };
/// Begin building good `gi` (`capital.begin`).
pub const BeginBuild = struct { agent: Entity, gi: u16 };
/// Abandon the build in progress (`capital.cancel_build`).
pub const CancelBuild = struct { agent: Entity };
/// Switch generator `gi` on or off (`capital.toggle_generator`).
pub const ToggleGenerator = struct { agent: Entity, gi: u16 };
/// Collect generator `gi`'s cycle (`capital.collect_generator`).
pub const CollectGenerator = struct { agent: Entity, gi: u16 };
/// Set the metabolism rate; the handler clamps it into the configured band.
pub const SetRation = struct { agent: Entity, rate: f32 };
/// Take `lots` of the passerby's offer `quote` (`barter.resolve`), every line scaled by `lots`.
pub const Barter = struct { agent: Entity, quote: market.Quote, lots: u16 };
/// Establish technology `ti` on the research board.
pub const Research = struct { agent: Entity, ti: u16 };
/// Raise the Exchange.
pub const RaiseExchange = struct { agent: Entity };
/// Take `lots` of the Coin Merchant's lot `lot`.
pub const MerchantDeal = struct { agent: Entity, lot: u32, lots: u32 };
/// Settle a deal with stub neighbour `neighbour`: what the agent gives and takes, per item.
pub const NeighbourDeal = struct {
    agent: Entity,
    neighbour: u8,
    give: [neighbours.bundle_len]u16,
    take: [neighbours.bundle_len]u16,
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

/// `agent` collected generator `gi`: `receipt` landed and `vigor` was restored.
pub const Collected = struct { agent: Entity, gi: u16, receipt: Receipt = .{}, vigor: f32 = 0, act: u8 = 1 };

/// `agent`'s condition band changed.
pub const BandCrossed = struct { agent: Entity, from: Condition, to: Condition };

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
/// records (`systems/merchant.zig`) and how many lots it took. `act` is the act the agent's
/// words are in.
pub const Traded = struct {
    agent: Entity,
    with: Who,
    direction: market.Direction,
    biomass_moved: f32 = 0,
    lot: u32 = 0,
    lots: u32 = 0,
    act: u8 = 1,
};

/// A visitor arrived.
pub const Arrived = struct { who: Who };

/// A visitor left.
pub const Departed = struct { who: Who };
