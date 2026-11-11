//! `save` — a run written to a file and read back.
//!
//! A run is the world, `Sim` and the state, and a save holds those three, as ZON: written by
//! `std.zon.stringify.serialize` and read by `std.zon.parse.fromSlice`. One record per live
//! entity, in entity order; entity ids are not saved, so a load spawns fresh ones. The plain
//! components are saved as they are. The components kept by catalog index (`Verbs`, `Goods`,
//! `Generators`, `Research`, `Busy`) are saved as records keyed by the roster's ids, so a save
//! survives a roster edit: a load resolves each id against the roster it finds, and a record
//! naming an id the roster no longer has is dropped and counted (`Report.dropped`). `Quotes` is
//! derived, so a save says only that the agent carries it; the `quotes` writer in every act's
//! `handle` set refills it on the load frame's tick, before the build. `Label` is not saved.
//!
//! A component this module does not name is a compile error (the `comptime` block below), and
//! so is a field of `Sim` it does not name, so neither can be forgotten silently. Every tag is
//! saved by name through `Tag`.
//!
//! `Sim` is saved field by field: the prng's state is kept, so a load carries the run's luck as
//! `Sim.reset` does; the reach seen-set as good ids; the log as its lines, oldest first, which
//! a load pushes back in order and then stamps with each line's own time. The merchant's visit
//! is saved as it is: its array indexes a static table in code, not the roster, so a change to
//! that table is a change of `version`. The encounter's per-ware arrays are saved as lists in
//! `market.Ware` order, so a ware appended to the end reads as zero from a file written before
//! it.
//!
//! `version` guards the shape: `read` refuses a file whose version is not between `oldest` and
//! `version` (`error.UnknownVersion`) before it parses the rest. A write goes to a temporary
//! file that is renamed over the slot (`std.Io.Dir.createFileAtomic`), so a failed write leaves
//! the slot as it was. File IO goes through the `std.Io.Dir` the caller passes.

const std = @import("std");
const comp = @import("../components.zig");
const tags = @import("../tags.zig");
const roster = @import("./roster.zig");
const ecs = @import("../ecs.zig");
const res_mod = @import("../res.zig");
const logmod = @import("../log.zig");
const market = @import("../rules/market.zig");
const neighbours = @import("../rules/neighbours.zig");
const effects = @import("../rules/effects.zig");
const capital = @import("../rules/capital.zig");
const GameState = @import("../state.zig").GameState;

const Allocator = std.mem.Allocator;
const World = ecs.World;
const Entity = ecs.Entity;
const Resources = res_mod.Resources;
const Sim = res_mod.Sim;

/// The shape's version: what a capture writes.
pub const version: u32 = 3;

/// The oldest version a load reads. A version-2 file keys a generator record by the good that
/// ran it; a load reads such an id as the generator verb that good opens
/// (`capital.generatorOf`), so the file loads unchanged.
pub const oldest: u32 = 2;

/// The largest file `read` accepts.
pub const max_bytes: usize = 4 * 1024 * 1024;

/// Every tag, by its declaration name.
pub const Tag = std.meta.DeclEnum(tags);

/// The plain components: saved as they are, under these field names of `AgentSave`.
const plain = .{
    .{ "vigor", comp.Vigor },
    .{ "food", comp.InventoryFood },
    .{ "biomass", comp.InventoryBiomass },
    .{ "water", comp.InventoryWater },
    .{ "fuel", comp.InventoryFuel },
    .{ "metal", comp.InventoryMetal },
    .{ "minerals", comp.InventoryMinerals },
    .{ "coin", comp.InventoryCoin },
    .{ "granted", comp.Granted },
    .{ "migrated", comp.Migrated },
    .{ "metabolism", comp.Metabolism },
    .{ "condition", comp.Condition },
    .{ "outlook", comp.Outlook },
};
/// Kept by catalog index, saved as records keyed by id.
const keyed = .{ comp.Verbs, comp.Goods, comp.Generators, comp.Research, comp.Busy };
/// Derived: saved as presence only.
const presence = .{comp.Quotes};
/// Not saved.
const excluded = .{comp.Label};

/// The fields of `Sim` the save holds; `log` among them, as lines.
const sim_fields = .{ "elapsed", "log", "tutorial_done", "prng", "reach_seen", "encounter", "merchant", "neighbours", "exchange", "population" };

fn named(comptime T: type) bool {
    inline for (plain) |p| if (p[1] == T) return true;
    inline for (keyed ++ presence ++ excluded) |K| if (K == T) return true;
    return false;
}

comptime {
    for (@typeInfo(comp).@"struct".decl_names) |name| {
        if (!named(@field(comp, name))) @compileError("save.zig does not name the component " ++ name ++ ": add it to plain, keyed, presence or excluded");
    }
    for (plain) |p| {
        if (@FieldType(AgentSave, p[0]) != ?p[1]) @compileError("AgentSave." ++ p[0] ++ " is not ?" ++ @typeName(p[1]));
    }
    for (@typeInfo(tags).@"struct".decl_names) |name| {
        if (@sizeOf(@field(tags, name)) != 0) @compileError("the tag " ++ name ++ " carries data a save would lose");
    }
    for (@typeInfo(Sim).@"struct".field_names) |name| {
        var found = false;
        for (sim_fields) |f| found = found or std.mem.eql(u8, f, name);
        if (!found) @compileError("save.zig does not name the field Sim." ++ name);
    }
}

pub const GoodSave = struct { id: []const u8, count: u32 };
/// A generator verb whose progress or mode differs from the default, by the verb's id. `off` is
/// the older record's word for the mode: a load reads `off = true` as `mode = .off`; a capture
/// never writes it.
pub const GeneratorSave = struct { id: []const u8, progress: f32 = 0, mode: comp.Generators.Mode = .on, off: bool = false };
pub const ResearchSave = struct { id: []const u8, state: roster.TechState };
pub const BusySave = struct {
    pub const Doing = union(enum) { labor: []const u8, build: []const u8 };
    doing: Doing,
    total: f32,
    remaining: f32,
    quality: f32,
};

/// One live entity. A null field is a component the entity does not carry.
pub const AgentSave = struct {
    tags: []const Tag = &.{},
    vigor: ?comp.Vigor = null,
    food: ?comp.InventoryFood = null,
    biomass: ?comp.InventoryBiomass = null,
    water: ?comp.InventoryWater = null,
    fuel: ?comp.InventoryFuel = null,
    metal: ?comp.InventoryMetal = null,
    minerals: ?comp.InventoryMinerals = null,
    coin: ?comp.InventoryCoin = null,
    granted: ?comp.Granted = null,
    migrated: ?comp.Migrated = null,
    metabolism: ?comp.Metabolism = null,
    condition: ?comp.Condition = null,
    outlook: ?comp.Outlook = null,
    /// The ids of the verbs the agent holds of its own.
    verbs: ?[]const []const u8 = null,
    /// Only the goods owned (a count above zero).
    goods: ?[]const GoodSave = null,
    generators: ?[]const GeneratorSave = null,
    /// Every technology of the roster the save was made with.
    research: ?[]const ResearchSave = null,
    busy: ?BusySave = null,
    quotes: bool = false,
};

pub const LineSave = struct { text: []const u8, tone: logmod.Tone = .normal, at: f32 = 0, refused: bool = false };

pub const LogSave = struct {
    pushed: u64 = 0,
    now: f32 = 0,
    /// Oldest first.
    lines: []const LineSave = &.{},
};

pub const NeighboursSave = struct {
    /// The first `Market.n` neighbours.
    agents: []const neighbours.Agent = &.{},
    sell_posts: [neighbours.item_count]neighbours.Post = @splat(.{}),
    buy_posts: [neighbours.item_count]neighbours.Post = @splat(.{}),
    /// `Market.history[0..history_len]`.
    history: []const neighbours.Evidence = &.{},
    seeded: bool = false,
};

/// The passerby's encounter, its per-ware arrays as lists in `market.Ware` order.
pub const EncounterSave = struct {
    phase: market.Phase = .absent,
    id: u32 = 0,
    remaining: f32 = 0,
    stock: []const f32 = &.{},
    visit: []const f32 = &.{},
    sold: []const u16 = &.{},
    bought: []const u16 = &.{},
    level: []const i8 = &.{},
};

pub const SimSave = struct {
    elapsed: f32,
    tutorial_done: bool,
    /// The Xoshiro256 state.
    prng: [4]u64,
    /// The good ids whose reach bit is set.
    reach_seen: []const []const u8,
    encounter: EncounterSave,
    merchant: market.MerchantVisit,
    exchange: Sim.Exchange,
    population: f32,
    neighbours: NeighboursSave,
    log: LogSave,
};

pub const Save = struct {
    version: u32,
    /// act_one, act_two or act_three; a save is never made in title or game_over.
    state: GameState,
    sim: SimSave,
    agents: []const AgentSave,
};

/// Whether `e` is in any storage.
fn alive(w: *const World, e: Entity) bool {
    inline for (@typeInfo(comp).@"struct".decl_names) |name| {
        if (w.has(e, @field(comp, name))) return true;
    }
    inline for (@typeInfo(tags).@"struct".decl_names) |name| {
        if (w.has(e, @field(tags, name))) return true;
    }
    return false;
}

/// The run as a `Save`, every string and slice allocated in `arena`.
pub fn capture(arena: Allocator, res: *const Resources, w: *const World) !Save {
    var agents: std.ArrayList(AgentSave) = .empty;
    var e: Entity = 0;
    while (e < w.next_id) : (e += 1) {
        if (!alive(w, e)) continue;
        try agents.append(arena, try captureAgent(arena, &res.catalog, w, e));
    }
    return .{ .version = version, .state = res.states.current, .sim = try captureSim(arena, res), .agents = agents.items };
}

fn captureAgent(arena: Allocator, cat: *const roster.Catalog, w: *const World, e: Entity) !AgentSave {
    var a: AgentSave = .{};
    var tag_list: std.ArrayList(Tag) = .empty;
    inline for (@typeInfo(Tag).@"enum".field_names) |name| {
        if (w.has(e, @field(tags, name))) try tag_list.append(arena, @field(Tag, name));
    }
    a.tags = tag_list.items;
    inline for (plain) |p| {
        if (w.get(e, p[1])) |v| @field(a, p[0]) = v.*;
    }
    if (w.get(e, comp.Verbs)) |v| {
        var list: std.ArrayList([]const u8) = .empty;
        for (cat.actions, 0..) |rec, ai| {
            if (v.held[ai]) try list.append(arena, try arena.dupe(u8, rec.id));
        }
        a.verbs = list.items;
    }
    if (w.get(e, comp.Goods)) |g| {
        var list: std.ArrayList(GoodSave) = .empty;
        for (cat.goods, 0..) |rec, gi| {
            if (g.count[gi] > 0) try list.append(arena, .{ .id = try arena.dupe(u8, rec.id), .count = g.count[gi] });
        }
        a.goods = list.items;
    }
    if (w.get(e, comp.Generators)) |g| {
        var list: std.ArrayList(GeneratorSave) = .empty;
        for (cat.actions, 0..) |rec, ai| {
            if (g.progress[ai] != 0 or g.mode[ai] != .on) try list.append(arena, .{ .id = try arena.dupe(u8, rec.id), .progress = g.progress[ai], .mode = g.mode[ai] });
        }
        a.generators = list.items;
    }
    if (w.get(e, comp.Research)) |r| {
        const list = try arena.alloc(ResearchSave, cat.technologies.len);
        for (cat.technologies, list, 0..) |t, *out, ti| out.* = .{ .id = try arena.dupe(u8, t.id), .state = r.state[ti] };
        a.research = list;
    }
    if (w.get(e, comp.Busy)) |b| {
        a.busy = .{
            .doing = switch (b.doing) {
                .labor => |ai| .{ .labor = try arena.dupe(u8, cat.actions[ai].id) },
                .build => |gi| .{ .build = try arena.dupe(u8, cat.goods[gi].id) },
            },
            .total = b.total,
            .remaining = b.remaining,
            .quality = b.quality,
        };
    }
    a.quotes = w.has(e, comp.Quotes);
    return a;
}

fn captureSim(arena: Allocator, res: *const Resources) !SimSave {
    const s = &res.sim;
    var reach: std.ArrayList([]const u8) = .empty;
    for (res.catalog.goods, 0..) |g, gi| {
        if (s.reach_seen[gi]) try reach.append(arena, try arena.dupe(u8, g.id));
    }
    const lines = try arena.alloc(LineSave, s.log.count);
    for (lines, 0..) |*l, k| {
        const entry = s.log.get(s.log.count - 1 - k);
        l.* = .{ .text = try arena.dupe(u8, entry.text()), .tone = entry.tone, .at = entry.at, .refused = entry.refused };
    }
    return .{
        .elapsed = s.elapsed,
        .tutorial_done = s.tutorial_done,
        .prng = s.prng.s,
        .reach_seen = reach.items,
        .encounter = .{
            .phase = s.encounter.phase,
            .id = s.encounter.id,
            .remaining = s.encounter.remaining,
            .stock = try arena.dupe(f32, &s.encounter.stock),
            .visit = try arena.dupe(f32, &s.encounter.visit),
            .sold = try arena.dupe(u16, &s.encounter.sold),
            .bought = try arena.dupe(u16, &s.encounter.bought),
            .level = try arena.dupe(i8, &s.encounter.level),
        },
        .merchant = s.merchant,
        .exchange = s.exchange,
        .population = s.population,
        .neighbours = .{
            .agents = try arena.dupe(neighbours.Agent, s.neighbours.people()),
            .sell_posts = s.neighbours.sell_posts,
            .buy_posts = s.neighbours.buy_posts,
            .history = try arena.dupe(neighbours.Evidence, s.neighbours.history[0..s.neighbours.history_len]),
            .seeded = s.neighbours.seeded,
        },
        .log = .{ .pushed = s.log.pushed, .now = s.log.now, .lines = lines },
    };
}

/// `s` as ZON text.
fn encode(arena: Allocator, s: *const Save) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.zon.stringify.serialize(s.*, .{ .emit_default_optional_fields = false }, &out.writer);
    try out.writer.writeByte('\n');
    return out.written();
}

/// ZON text as a `Save`: `error.UnknownVersion` when its version is outside `oldest`..`version`,
/// `error.ParseZon` when it is not a save.
fn decode(arena: Allocator, src: [:0]const u8) !Save {
    var diag: std.zon.parse.Diagnostics = undefined;
    const head = std.zon.parse.fromSlice(struct { version: u32 }, .{
        .gpa = arena, .arena = arena, .source = src, .diagnostics = &diag, .ignore_unknown_fields = true,
    }) catch |err| return logged(err, &diag);
    if (head.version < oldest or head.version > version) return error.UnknownVersion;
    return std.zon.parse.fromSlice(Save, .{ .gpa = arena, .arena = arena, .source = src, .diagnostics = &diag }) catch |err| logged(err, &diag);
}

fn logged(err: error{ OutOfMemory, ParseZon }, diag: *const std.zon.parse.Diagnostics) error{ OutOfMemory, ParseZon } {
    if (err == error.ParseZon) {
        for (diag.errors) |e| std.log.warn("save: {d}:{d}: {s}", .{ e.loc.line + 1, e.loc.column + 1, e.msg });
    }
    return err;
}

/// Capture the run and write it to `sub_path` in `dir`, replacing what is there.
pub fn write(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, gpa: Allocator, res: *const Resources, w: *const World) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const s = try capture(arena.allocator(), res, w);
    const text = try encode(arena.allocator(), &s);
    var file = try dir.createFileAtomic(io, sub_path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, text);
    try file.replace(io);
}

/// A save read from a file, and the arena that holds its strings and slices.
pub const Loaded = struct {
    save: Save,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
    }
};

/// Read and parse `sub_path` in `dir`. `error.UnknownVersion` when the file's version is outside
/// `oldest`..`version`; a file that is not a save is `error.ParseZon`, its errors logged as warnings.
pub fn read(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, gpa: Allocator) !Loaded {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const src = try dir.readFileAllocOptions(io, sub_path, a, .limited(max_bytes), .of(u8), 0);
    const s = try decode(a, src);
    return .{ .save = s, .arena = arena };
}

/// What a load could not place.
pub const Report = struct {
    /// Records naming an id the roster no longer has: a verb, a good, a generator, a
    /// technology, a reach bit, or the work in progress.
    dropped: u32 = 0,
};

/// Replace the run with `s`: empty the world and spawn each agent afresh, resolving every id
/// against the roster in `res.catalog`; rebuild `Sim`; set the state. The state is written
/// directly, never requested through `States.set`: a transition would run its `on_enter`, and
/// entering Act I begins a new run.
pub fn apply(res: *Resources, w: *World, s: *const Save) Report {
    var report: Report = .{};
    const cat = &res.catalog;
    w.clear();
    for (s.agents[0..@min(s.agents.len, ecs.MAX_ENTITIES)]) |*a| applyAgent(w, cat, a, &report);
    applySim(&res.sim, cat, &s.sim, &report);
    res.states = .{ .current = s.state, .next = null };
    return report;
}

/// The verb a generator record names: the verb by its id, or, for a version-2 record, the
/// generator verb the named good opens.
fn generatorIndex(cat: *const roster.Catalog, id: []const u8) ?u16 {
    if (cat.actionIndex(id)) |ai| return ai;
    return capital.generatorOf(cat, id);
}

fn applyAgent(w: *World, cat: *const roster.Catalog, a: *const AgentSave, report: *Report) void {
    const e = w.spawn(.{});
    for (a.tags) |t| switch (t) {
        inline else => |k| {
            const T = @field(tags, @tagName(k));
            if (!w.has(e, T)) w.add(e, T{});
        },
    };
    inline for (plain) |p| {
        if (@field(a, p[0])) |v| w.add(e, v);
    }
    if (a.verbs) |list| {
        var verbs = comp.Verbs{};
        for (list) |id| {
            if (cat.actionIndex(id)) |ai| verbs.held[ai] = true else report.dropped += 1;
        }
        w.add(e, verbs);
    }
    if (a.goods) |list| {
        var goods = comp.Goods{};
        for (list) |r| {
            if (cat.goodIndex(r.id)) |gi| goods.count[gi] = r.count else report.dropped += 1;
        }
        w.add(e, goods);
    }
    if (a.generators) |list| {
        var gens = comp.Generators{};
        for (list) |r| {
            if (generatorIndex(cat, r.id)) |ai| {
                gens.progress[ai] = r.progress;
                gens.mode[ai] = if (r.off) .off else r.mode;
            } else report.dropped += 1;
        }
        w.add(e, gens);
    }
    if (a.research) |list| {
        // A technology new to the roster keeps its authored initial state.
        var research = comp.Research.entry(cat);
        for (list) |r| {
            if (cat.techIndex(r.id)) |ti| research.state[ti] = r.state else report.dropped += 1;
        }
        w.add(e, research);
    }
    if (a.busy) |b| {
        const doing: ?comp.Busy.Doing = switch (b.doing) {
            .labor => |id| if (cat.actionIndex(id)) |ai| .{ .labor = ai } else null,
            .build => |id| if (cat.goodIndex(id)) |gi| .{ .build = gi } else null,
        };
        if (doing) |d| {
            w.add(e, comp.Busy{ .doing = d, .total = b.total, .remaining = b.remaining, .quality = b.quality });
        } else report.dropped += 1;
    }
    if (a.quotes) w.add(e, comp.Quotes{});
    // The body and the larder against the goods as this roster reads them: delta-based against
    // the saved `Granted`, so an unchanged roster changes nothing.
    effects.apply(w, e, cat);
}

fn applySim(sim: *Sim, cat: *const roster.Catalog, s: *const SimSave, report: *Report) void {
    sim.reset();
    sim.elapsed = s.elapsed;
    sim.tutorial_done = s.tutorial_done;
    sim.prng.s = s.prng;
    for (s.reach_seen) |id| {
        if (cat.goodIndex(id)) |gi| sim.reach_seen[gi] = true else report.dropped += 1;
    }
    sim.encounter = .{ .phase = s.encounter.phase, .id = s.encounter.id, .remaining = s.encounter.remaining };
    for (s.encounter.stock[0..@min(s.encounter.stock.len, market.ware_count)], 0..) |v, i| sim.encounter.stock[i] = v;
    for (s.encounter.visit[0..@min(s.encounter.visit.len, market.ware_count)], 0..) |v, i| sim.encounter.visit[i] = v;
    for (s.encounter.sold[0..@min(s.encounter.sold.len, market.ware_count)], 0..) |v, i| sim.encounter.sold[i] = v;
    for (s.encounter.bought[0..@min(s.encounter.bought.len, market.ware_count)], 0..) |v, i| sim.encounter.bought[i] = v;
    for (s.encounter.level[0..@min(s.encounter.level.len, market.ware_count)], 0..) |v, i| sim.encounter.level[i] = v;
    sim.merchant = s.merchant;
    sim.exchange = s.exchange;
    sim.population = s.population;

    const n = @min(s.neighbours.agents.len, neighbours.max_agents);
    @memcpy(sim.neighbours.agents[0..n], s.neighbours.agents[0..n]);
    sim.neighbours.n = @intCast(n);
    sim.neighbours.sell_posts = s.neighbours.sell_posts;
    sim.neighbours.buy_posts = s.neighbours.buy_posts;
    const h = @min(s.neighbours.history.len, sim.neighbours.history.len);
    @memcpy(sim.neighbours.history[0..h], s.neighbours.history[0..h]);
    sim.neighbours.history_len = @intCast(h);
    sim.neighbours.seeded = s.neighbours.seeded;

    // Each line pushed back in order, at its own time, then flagged as it was.
    for (s.log.lines) |l| {
        sim.log.now = l.at;
        sim.log.push(l.tone, l.text);
        sim.log.entries[(sim.log.head + logmod.capacity - 1) % logmod.capacity].refused = l.refused;
    }
    sim.log.pushed = @max(s.log.pushed, sim.log.pushed);
    sim.log.now = s.log.now;
}

/// What a slot shows: the act, the day and how many people.
pub const Summary = struct { act: u8, day: u32, people: u32 };

pub fn actOf(state: GameState) u8 {
    return switch (state) {
        .act_two => 2,
        .act_three => 3,
        .title, .act_one, .game_over => 1,
    };
}

pub fn summary(s: *const Save, cfg: *const res_mod.Config) Summary {
    const act = actOf(s.state);
    return .{
        .act = act,
        .day = 1 + std.math.lossyCast(u32, s.sim.elapsed / cfg.secs_per_day),
        .people = if (act >= 2) std.math.lossyCast(u32, s.sim.population) else 1,
    };
}

/// `read` then `summary`; null on any error.
pub fn peek(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, gpa: Allocator, cfg: *const res_mod.Config) ?Summary {
    var loaded = read(io, dir, sub_path, gpa) catch return null;
    defer loaded.deinit();
    return summary(&loaded.save, cfg);
}

/// Whether the run can be saved now: it is in an act, and no transition is pending.
pub fn canSave(res: *const Resources) bool {
    const in_act = switch (res.states.current) {
        .act_one, .act_two, .act_three => true,
        .title, .game_over => false,
    };
    return in_act and res.states.next == null;
}

// ============================ Tests =====================================================

const testing = std.testing;
const run = @import("../systems/run.zig");
const migration = @import("./migration.zig");

fn shipped() !roster.Catalog {
    return roster.load(testing.allocator, roster.shipped, null);
}

/// An Act II settlement with a little of everything: goods, a generator part-way, a build in
/// progress, research, a second entity with tags, and a `Sim` with lines, reach, a passerby, the
/// merchant away, neighbours seeded and the Exchange standing.
fn settle(res: *Resources, w: *World) Entity {
    const cat = &res.catalog;
    const e = run.spawn_player(w, cat);
    const goods = w.get(e, comp.Goods).?;
    goods.count[cat.goodIndex("sandals").?] = 2;
    goods.count[cat.goodIndex("hatchet").?] = 1;
    goods.count[cat.goodIndex("garden_bed").?] = 1;
    effects.apply(w, e, cat);
    const gens = w.get(e, comp.Generators).?;
    gens.progress[cat.actionIndex("tend_garden").?] = 3.75;
    gens.mode[cat.actionIndex("check_traps").?] = .off;
    gens.mode[cat.actionIndex("tend_garden").?] = .auto;
    w.add(e, comp.Busy{ .doing = .{ .build = cat.goodIndex("hatchet").? }, .total = 5, .remaining = 2.125, .quality = 0.7 });
    _ = migration.migrate_to_act_two(w, e, cat);
    const research = w.get(e, comp.Research).?;
    research.state[cat.techIndex("spring_well").?] = .researched;
    research.state[cat.techIndex("surface_ore").?] = .available;
    w.get(e, comp.Vigor).?.v = 7.3;
    w.get(e, comp.Outlook).?.recovery = .{ .partial = .{ .days = 2.5, .restored = 1.25 } };

    _ = w.spawn(.{ comp.Vigor{ .v = 1, .max = 3 }, tags.Generator{}, tags.Dead{} });

    const sim = &res.sim;
    sim.elapsed = 1234.5;
    sim.tutorial_done = true;
    _ = res.random().int(u64);
    sim.reach_seen[cat.goodIndex("hatchet").?] = true;
    sim.encounter = .{ .phase = .present, .id = 3, .remaining = 17.5, .stock = .{ 1, 2.5, 3, 4, 1, 0, 1, 1 }, .visit = .{ -1, 2.5, 0, 1, 0, 0, 0, -1 }, .sold = .{ 2, 0, 0, 0, 0, 1, 0, 1 }, .bought = .{ 0, 3, 1, 0, 0, 0, 0, 0 }, .level = .{ -2, 0, 4, 1, 0, 0, -4, 0 } };
    sim.merchant = .{ .present = false, .id = 4, .remaining = 9.25 };
    sim.neighbours.seed(10);
    sim.population = 61;
    sim.exchange.standing = true;
    sim.log.now = 10;
    sim.log.push(.normal, "You wake alone. Cold. Hungry.");
    sim.log.now = 20.5;
    sim.log.push(.good, "Shelter raised \u{2014} at last.");
    var over: [logmod.max_len + 1]u8 = undefined;
    @memset(&over, 'x');
    sim.log.push(.warn, &over);
    sim.log.now = 30;
    sim.log.push(.danger, "\"Quoted\" and \\ escaped.");
    sim.log.now = 1234.5;
    res.states = .{ .current = .act_two };
    return e;
}

fn expectWorldsEqual(a: *const World, b: *const World) !void {
    var e: Entity = 0;
    while (e < @max(a.next_id, b.next_id)) : (e += 1) {
        inline for (@typeInfo(comp).@"struct".decl_names) |name| {
            const T = @field(comp, name);
            if (T == comp.Label) continue;
            try testing.expectEqual(a.has(e, T), b.has(e, T));
            if (T != comp.Quotes) {
                if (a.get(e, T)) |va| try testing.expect(std.meta.eql(va.*, b.get(e, T).?.*));
            }
        }
        inline for (@typeInfo(tags).@"struct".decl_names) |name| {
            try testing.expectEqual(a.has(e, @field(tags, name)), b.has(e, @field(tags, name)));
        }
    }
}

fn expectSimsEqual(a: *Sim, b: *Sim) !void {
    try testing.expectEqual(a.elapsed, b.elapsed);
    try testing.expectEqual(a.tutorial_done, b.tutorial_done);
    try testing.expectEqual(a.prng.s, b.prng.s);
    try testing.expectEqual(a.reach_seen, b.reach_seen);
    try testing.expect(std.meta.eql(a.encounter, b.encounter));
    try testing.expect(std.meta.eql(a.merchant, b.merchant));
    try testing.expectEqual(a.exchange, b.exchange);
    try testing.expectEqual(a.population, b.population);
    const na = &a.neighbours;
    const nb = &b.neighbours;
    try testing.expectEqual(na.n, nb.n);
    for (na.people(), nb.people()) |x, y| try testing.expect(std.meta.eql(x, y));
    try testing.expect(std.meta.eql(na.sell_posts, nb.sell_posts));
    try testing.expect(std.meta.eql(na.buy_posts, nb.buy_posts));
    try testing.expectEqual(na.history_len, nb.history_len);
    for (na.history[0..na.history_len], nb.history[0..nb.history_len]) |x, y| try testing.expectEqual(x, y);
    try testing.expectEqual(na.seeded, nb.seeded);
    try testing.expectEqual(a.log.pushed, b.log.pushed);
    try testing.expectEqual(a.log.now, b.log.now);
    try testing.expectEqual(a.log.head, b.log.head);
    try testing.expectEqual(a.log.count, b.log.count);
    for (0..a.log.count) |i| {
        const x = a.log.get(i);
        const y = b.log.get(i);
        try testing.expectEqualStrings(x.text(), y.text());
        try testing.expectEqual(x.tone, y.tone);
        try testing.expectEqual(x.at, y.at);
        try testing.expectEqual(x.refused, y.refused);
    }
    for (0..3) |_| try testing.expectEqual(a.prng.random().int(u64), b.prng.random().int(u64));
}

test "a run survives capture, ZON and apply exactly" {
    var res = Resources{ .catalog = try shipped() };
    defer res.catalog.deinit();
    var w = try World.init(testing.allocator);
    defer w.deinit();
    _ = settle(&res, &w);
    try testing.expect(res.sim.neighbours.seeded and res.sim.neighbours.n == 10);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try capture(a, &res, &w);
    try testing.expectEqual(@as(usize, 2), s.agents.len);
    const text = try encode(a, &s);
    const back = try decode(a, try a.dupeSentinel(u8, text, 0));

    var res2 = Resources{ .catalog = try shipped() };
    defer res2.catalog.deinit();
    var w2 = try World.init(testing.allocator);
    defer w2.deinit();
    _ = run.spawn_player(&w2, &res2.catalog); // what the load replaces
    res2.states.set(.act_one);
    const report = apply(&res2, &w2, &back);
    try testing.expectEqual(@as(u32, 0), report.dropped);
    try testing.expectEqual(w.next_id, w2.next_id);
    try expectWorldsEqual(&w, &w2);
    try expectSimsEqual(&res.sim, &res2.sim);
    try testing.expectEqual(GameState.act_two, res2.states.current);
    try testing.expectEqual(@as(?GameState, null), res2.states.next);
}

test "a record naming an id the roster no longer has is dropped and counted" {
    var res = Resources{ .catalog = try shipped() };
    defer res.catalog.deinit();
    var w = try World.init(testing.allocator);
    defer w.deinit();
    const goods = [_]GoodSave{ .{ .id = "sandals", .count = 1 }, .{ .id = "no_such_good", .count = 3 } };
    const verbs = [_][]const u8{ "forage", "no_such_verb" };
    const agents = [_]AgentSave{.{
        .tags = &.{.Player},
        .vigor = .{},
        .granted = .{},
        .verbs = &verbs,
        .goods = &goods,
        .busy = .{ .doing = .{ .labor = "no_such_verb" }, .total = 1, .remaining = 1, .quality = 1 },
    }};
    const s = Save{
        .version = version,
        .state = .act_one,
        .sim = .{ .elapsed = 0, .tutorial_done = false, .prng = .{ 1, 2, 3, 4 }, .reach_seen = &.{"gone_too"}, .encounter = .{}, .merchant = .{}, .exchange = .{}, .population = 48, .neighbours = .{}, .log = .{} },
        .agents = &agents,
    };
    const report = apply(&res, &w, &s);
    try testing.expectEqual(@as(u32, 4), report.dropped);
    try testing.expect(w.get(0, comp.Verbs).?.held[res.catalog.actionIndex("forage").?]);
    try testing.expectEqual(@as(u32, 1), w.get(0, comp.Goods).?.count[res.catalog.goodIndex("sandals").?]);
    try testing.expect(!w.has(0, comp.Busy));
    try testing.expect(w.has(0, tags.Player));
}

test "a version-2 generator record, keyed by its good, loads as the verb; a capture keys it by the verb" {
    var res = Resources{ .catalog = try shipped() };
    defer res.catalog.deinit();
    const cat = &res.catalog;
    var w = try World.init(testing.allocator);
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\.{ .version = 2, .state = .act_one,
        \\   .sim = .{ .elapsed = 0, .tutorial_done = false, .prng = .{ 1, 2, 3, 4 }, .reach_seen = .{}, .encounter = .{ .phase = .present, .id = 2, .stock = .{ 8, 20, 1, 0 } }, .merchant = .{}, .exchange = .{}, .population = 48, .neighbours = .{}, .log = .{} },
        \\   .agents = .{ .{ .generators = .{
        \\       .{ .id = "wire_snares", .off = true },
        \\       .{ .id = "garden_bed", .progress = 2.5, .off = false },
        \\       .{ .id = "chicken_coop", .mode = .auto },
        \\   } } } }
    ;
    const old = try decode(a, try a.dupeSentinel(u8, src, 0));
    try testing.expectEqual(@as(u32, 0), apply(&res, &w, &old).dropped);
    const gens = w.get(0, comp.Generators).?;
    try testing.expectEqual(comp.Generators.Mode.off, gens.mode[cat.actionIndex("check_traps").?]);
    try testing.expectEqual(comp.Generators.Mode.on, gens.mode[cat.actionIndex("tend_garden").?]);
    try testing.expectEqual(@as(f32, 2.5), gens.progress[cat.actionIndex("tend_garden").?]);
    try testing.expectEqual(comp.Generators.Mode.auto, gens.mode[cat.actionIndex("collect_eggs").?]);
    // Its encounter, written before the rank-2 wares, loads with them at zero.
    try testing.expectEqual(@as(f32, 20), res.sim.encounter.stockOf(.biomass));
    try testing.expectEqual(@as(f32, 0), res.sim.encounter.stockOf(.whetstone));
    try testing.expectEqual(@as(f32, 0), res.sim.encounter.stockOf(.hand_axe));
    try testing.expectEqual(@as(f32, 0), res.sim.encounter.stockOf(.cookpot));

    // A capture writes the mode under the verb's id, and never the older word.
    const text = try encode(a, &(try capture(a, &res, &w)));
    try testing.expect(std.mem.indexOf(u8, text, ".off = ") == null);
    try testing.expect(std.mem.indexOf(u8, text, "\"tend_garden\"") != null and std.mem.indexOf(u8, text, "\"garden_bed\"") == null);
    var w2 = try World.init(testing.allocator);
    defer w2.deinit();
    _ = apply(&res, &w2, &(try decode(a, try a.dupeSentinel(u8, text, 0))));
    try testing.expectEqual(gens.mode, w2.get(0, comp.Generators).?.mode);
    try testing.expectEqual(gens.progress, w2.get(0, comp.Generators).?.progress);
}

test "a file of another version is refused; garbage is a parse error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "v99.zon", .data = ".{ .version = 99, .anything = .{ .at = \"all\" } }" });
    try testing.expectError(error.UnknownVersion, read(testing.io, tmp.dir, "v99.zon", testing.allocator));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "junk.zon", .data = "this is not a save" });
    try testing.expectError(error.ParseZon, read(testing.io, tmp.dir, "junk.zon", testing.allocator));
    try testing.expect(peek(testing.io, tmp.dir, "junk.zon", testing.allocator, &.{}) == null);
    try testing.expect(peek(testing.io, tmp.dir, "missing.zon", testing.allocator, &.{}) == null);
}

test "write then read through a directory; peek gives the act, the day and the people" {
    var res = Resources{ .catalog = try shipped() };
    defer res.catalog.deinit();
    var w = try World.init(testing.allocator);
    defer w.deinit();
    _ = settle(&res, &w);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(testing.io, tmp.dir, "slot1.zon", testing.allocator, &res, &w);
    try write(testing.io, tmp.dir, "slot1.zon", testing.allocator, &res, &w); // over an existing file

    var loaded = try read(testing.io, tmp.dir, "slot1.zon", testing.allocator);
    defer loaded.deinit();
    var res2 = Resources{ .catalog = try shipped() };
    defer res2.catalog.deinit();
    var w2 = try World.init(testing.allocator);
    defer w2.deinit();
    _ = apply(&res2, &w2, &loaded.save);
    try expectWorldsEqual(&w, &w2);
    try expectSimsEqual(&res.sim, &res2.sim);

    // 1234.5 game-seconds at 20 a day is day 62; Act II reads the population.
    const got = peek(testing.io, tmp.dir, "slot1.zon", testing.allocator, &res.config).?;
    try testing.expectEqual(Summary{ .act = 2, .day = 62, .people = 61 }, got);
}

test "canSave is false off an act and with a transition pending" {
    var res = Resources{};
    try testing.expect(!canSave(&res)); // title
    res.states = .{ .current = .game_over };
    try testing.expect(!canSave(&res));
    res.states = .{ .current = .act_one };
    try testing.expect(canSave(&res));
    res.states.set(.act_two);
    try testing.expect(!canSave(&res));
    res.states = .{ .current = .act_three };
    try testing.expect(canSave(&res));
}
