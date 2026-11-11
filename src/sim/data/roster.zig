//! `roster` — the **authored roster**: the labor verbs, the capital goods and the technologies
//! as data, loaded from `assets/roster/actions.zon`, `assets/roster/goods.zon` and
//! `assets/roster/technologies.zon` into one `Catalog`.
//!
//! The record grammar is the contract content is written against (the prose is in
//! `src/README.md`, "The authored roster"): one flat id space shared by actions and goods,
//! beside the `Resource` enum; every amount keyed by resource name (`Requires`, `Output`,
//! `Stock`); a record's gates naming a technology, goods and verbs; a good's behavior a list of
//! `Effect`s from a fixed vocabulary. Loading parses with `std.zon.parse` and then validates
//! every cross-reference and shape rule before the catalog is handed out, so a bad file is
//! refused whole — with a line and column, or a rule and the offending id — never half-applied.
//!
//! The sim runs on the catalog (`actions.zig`, `capital.zig`, `effects.zig`), and so do the
//! pages.

const std = @import("std");
// A relative import, not `ha`: `sim/res.zig` carries the catalog, and `test-ui` and `test-sim`
// compile it without the `ha` module.
const dist = @import("../kernel/dist.zig");

const Allocator = std.mem.Allocator;

// ============================ The grammar ===============================================

/// The ledger's columns — the fungible stocks an agent holds. In code, because each one is
/// structural (a stockline, a palette hue, a board wedge) and each has its own behavior
/// (food spoils, coin settles). A record's amounts are keyed by its tag name, so the spelling
/// here is part of the content contract.
pub const Resource = enum {
    food,
    biomass,
    water,
    fuel,
    metal,
    minerals,
    coin,

    /// Food and biomass exist from Act I.
    pub fn act(self: Resource) u8 {
        return switch (self) {
            .food, .biomass => 1,
            else => 2,
        };
    }

    // The shown names. They are the same in every act — the player reads `biomass` as
    // "materials" throughout — and take the act so a call site states which act it shows.

    /// The two-letter unit after an amount in a cost or yield (`12ma`, `+1–3fo`).
    pub fn letterIn(self: Resource, shown_act: u8) []const u8 {
        _ = shown_act;
        return switch (self) {
            .food => "fo",
            .biomass => "ma",
            .water => "wa",
            .fuel => "fu",
            .metal => "me",
            .minerals => "mi",
            .coin => "co",
        };
    }

    /// The lowercase word in running text.
    pub fn wordIn(self: Resource, shown_act: u8) []const u8 {
        _ = shown_act;
        if (self == .biomass) return "materials";
        return @tagName(self);
    }

    /// The capitalised name on a heading or label.
    pub fn labelIn(self: Resource, shown_act: u8) []const u8 {
        _ = shown_act;
        return switch (self) {
            .food => "Food",
            .biomass => "Materials",
            .water => "Water",
            .fuel => "Fuel",
            .metal => "Metal",
            .minerals => "Minerals",
            .coin => "Coin",
        };
    }

    /// The stock-line code.
    pub fn abbrevIn(self: Resource, shown_act: u8) []const u8 {
        _ = shown_act;
        return switch (self) {
            .food => "FO",
            .biomass => "MA",
            .water => "WA",
            .fuel => "FU",
            .metal => "ME",
            .minerals => "MI",
            .coin => "CO",
        };
    }
};

test "biomass is shown as materials in every act, and every resource has a two-letter unit" {
    try std.testing.expectEqual(@as(u8, 1), Resource.biomass.act());
    try std.testing.expectEqualStrings("ma", Resource.biomass.letterIn(1));
    try std.testing.expectEqualStrings("materials", Resource.biomass.wordIn(1));
    try std.testing.expectEqualStrings("Materials", Resource.biomass.labelIn(1));
    try std.testing.expectEqualStrings("MA", Resource.biomass.abbrevIn(1));
    try std.testing.expectEqualStrings("fo", Resource.food.letterIn(1));
    try std.testing.expectEqualStrings("co", Resource.coin.letterIn(2));

    inline for (comptime std.enums.values(Resource)) |r| {
        try std.testing.expectEqual(@as(usize, 2), r.letterIn(1).len);
        try std.testing.expectEqualStrings(r.letterIn(1), r.letterIn(2));
        try std.testing.expectEqualStrings(r.wordIn(1), r.wordIn(2));
        try std.testing.expectEqualStrings(r.labelIn(1), r.labelIn(2));
        try std.testing.expectEqualStrings(r.abbrevIn(1), r.abbrevIn(2));
    }
}

test "materials is not a catalog resource id" {
    try std.testing.expect(Catalog.resource("materials") == null);
    try std.testing.expectEqual(Resource.biomass, Catalog.resource("biomass").?);
}

/// The caps the sim's bounded per-agent containers rely on (`comp.Goods`, `comp.Research`,
/// `comp.Quotes`); the validator holds the files to them.
pub const max_actions = 64;
pub const max_goods = 128;
pub const max_techs = 128;

/// Whether struct `T` carries exactly one field per `Resource` tag beside the `extra` fields,
/// so adding a resource fails to compile until every keyed shape follows.
fn keyedByResource(comptime T: type, comptime extra: []const []const u8) bool {
    const fields = @typeInfo(T).@"struct".field_names;
    const tags = @typeInfo(Resource).@"enum".field_names;
    if (fields.len != tags.len + extra.len) return false;
    for (tags) |t| {
        if (!@hasField(T, t)) return false;
    }
    for (extra) |x| {
        if (!@hasField(T, x)) return false;
    }
    return true;
}

/// An amount of each resource, keyed by name: a technology's research price. Absent is zero.
pub const Stock = struct {
    food: f32 = 0,
    biomass: f32 = 0,
    water: f32 = 0,
    fuel: f32 = 0,
    metal: f32 = 0,
    minerals: f32 = 0,
    coin: f32 = 0,

    pub fn get(self: *const Stock, r: Resource) f32 {
        return switch (r) {
            inline else => |t| @field(self, @tagName(t)),
        };
    }

    /// Whether every amount is zero.
    pub fn isEmpty(self: *const Stock) bool {
        for (std.enums.values(Resource)) |r| if (self.get(r) != 0) return false;
        return true;
    }

    comptime {
        std.debug.assert(keyedByResource(Stock, &.{}));
    }
};

/// Everything a record demands: the body's energy (strictly below current vigor), the hours,
/// an amount of each resource, and the gates. For a labor verb the price is paid at begin; for
/// a generator verb at each collection, `hours` being the cycle; for a good it is the build
/// cost. A gate entry is a good id, satisfied while the agent owns at least one unit, or a
/// verb id, satisfied while the agent holds that verb.
pub const Requires = struct {
    energy: f32 = 0,
    hours: f32 = 0,
    food: f32 = 0,
    biomass: f32 = 0,
    water: f32 = 0,
    fuel: f32 = 0,
    metal: f32 = 0,
    minerals: f32 = 0,
    coin: f32 = 0,
    /// Gate: this technology must read researched (`comp.Research`).
    tech: ?[]const u8 = null,
    /// Gate: at least one of these ids is satisfied.
    any: []const []const u8 = &.{},
    /// Gate: every one of these ids is satisfied.
    all: []const []const u8 = &.{},

    pub fn get(self: *const Requires, r: Resource) f32 {
        return switch (r) {
            inline else => |t| @field(self, @tagName(t)),
        };
    }

    pub fn ptr(self: *Requires, r: Resource) *f32 {
        return switch (r) {
            inline else => |t| &@field(self, @tagName(t)),
        };
    }

    /// Whether the record carries any gate. A verb with none is held only as an agent's own.
    pub fn gated(self: *const Requires) bool {
        return self.tech != null or self.any.len > 0 or self.all.len > 0;
    }

    /// Whether it demands nothing at all: no energy, hours, resource or gate.
    pub fn isEmpty(self: *const Requires) bool {
        if (self.energy != 0 or self.hours != 0 or self.gated()) return false;
        for (std.enums.values(Resource)) |r| if (self.get(r) != 0) return false;
        return true;
    }

    comptime {
        std.debug.assert(keyedByResource(Requires, &.{ "energy", "hours", "tech", "any", "all" }));
    }
};

/// One drawn amount: the distribution and its scale (`dist.Dist.s`). `fixed` is exact; the
/// other kinds draw, and the spread is the risk. Written `.{ .poisson = 3.0 }`.
pub const Draw = union(enum) {
    fixed: f32,
    normal: f32,
    poisson: f32,
    uniform: f32,
    exponential: f32,

    pub fn scale(self: Draw) f32 {
        return switch (self) {
            inline else => |s| s,
        };
    }

    pub fn scalePtr(self: *Draw) *f32 {
        return switch (self.*) {
            inline else => |*s| s,
        };
    }

    pub fn kind(self: Draw) dist.Kind {
        return switch (self) {
            inline else => |_, t| @field(dist.Kind, @tagName(t)),
        };
    }

    /// The draw as the distribution the sim samples.
    pub fn asDist(self: Draw) dist.Dist {
        return .{ .kind = self.kind(), .s = self.scale() };
    }
};

/// What a verb yields at completion, or a generator at each collection: a draw per resource,
/// keyed by name, and a direct vigor restoration.
pub const Output = struct {
    food: ?Draw = null,
    biomass: ?Draw = null,
    water: ?Draw = null,
    fuel: ?Draw = null,
    metal: ?Draw = null,
    minerals: ?Draw = null,
    coin: ?Draw = null,
    /// Direct vigor restoration at completion, clamped at the ceiling.
    vigor: f32 = 0,

    pub fn get(self: *const Output, r: Resource) ?Draw {
        return switch (r) {
            inline else => |t| @field(self, @tagName(t)),
        };
    }

    pub fn ptr(self: *Output, r: Resource) *?Draw {
        return switch (r) {
            inline else => |t| &@field(self, @tagName(t)),
        };
    }

    comptime {
        std.debug.assert(keyedByResource(Output, &.{"vigor"}));
    }
};

/// What an effect tweaks on its target verb: the energy, the hours, one resource it requires
/// or one it yields.
pub const Stat = union(enum) {
    energy,
    hours,
    input: Resource,
    output: Resource,
};

/// What owning a good does. A small fixed vocabulary; the sim is its interpreter, and a new
/// kind of effect is a code change while a new good is not.
pub const Effect = union(enum) {
    /// Multiply a stat on the target verb. A yield's scale moves; an absent one stays absent.
    scale: Tweak,
    /// Offset a stat on the target verb: an absent output is inserted as `fixed`, and an input
    /// adds to its resource's amount.
    add: Tweak,
    /// Raise the vigor ceiling by this much and fill what it adds; losing it only clamps.
    vigor_ceiling: f32,
    /// Raise the larder's quality by this many steps.
    food_quality: u8,
    /// Multiply the larder's spoilage rate.
    spoil_scale: f32,

    pub const Tweak = struct {
        target: []const u8,
        stat: Stat,
        by: f32,
    };
};

/// A tool family and this good's rank in it. A family's verb takes the effects of the best
/// rank owned; lower ranks in the same family are superseded, not stacked.
pub const Family = struct {
    name: []const u8,
    rank: u8,
};

/// Standing conditions a good asks of its builder, read once at begin — as against its
/// resources, which are what the build spends.
pub const Unlock = struct {
    /// Absolute current vigor, not a fraction of the ceiling.
    vigor_abs: f32,
    /// Units in the larder.
    food: f32,
    /// How many good kinds already owned.
    goods: u32,
};

pub const Tier = enum { crude, manufactured };

/// The act a good's completion ends. At most one good per value.
pub const Milestone = enum { act_one };

/// A good in the player's words. Empty strings mean the good has no copy on that surface.
pub const Copy = struct {
    /// What owning it changes, as a sentence fragment for the BUILD row.
    effect: []const u8 = "",
    /// The rail's compact form of the same fact.
    short: []const u8 = "",
    /// The receipt line when the build completes.
    built: []const u8 = "",
};

pub const Action = struct {
    id: []const u8,
    name: []const u8,
    /// The first act the verb exists in.
    act: u8 = 1,
    /// Resource domains the verb works in; the specialization model's key.
    sectors: []const []const u8 = &.{},
    /// A generator accumulates `requires.hours` passively without occupying `Busy`; collecting
    /// pays `requires` and draws `output`, both per cycle.
    generator: bool = false,
    requires: Requires = .{},
    output: Output = .{},
};

pub const Good = struct {
    id: []const u8,
    name: []const u8,
    act: u8 = 1,
    /// False for a good the passerby carries and no one builds; it then has no tier and an
    /// empty `requires`.
    buildable: bool = true,
    tier: ?Tier = null,
    sectors: []const []const u8 = &.{},
    /// The build cost and its gates. A build yields one unit of the good.
    requires: Requires = .{},
    family: ?Family = null,
    effects: []const Effect = &.{},
    unlock: ?Unlock = null,
    /// How many humans it houses. Zero for everything but a shelter.
    capacity: u32 = 0,
    milestone: ?Milestone = null,
    copy: Copy = .{},
};

/// An axial position on the research board. The ring and the pure/hybrid wedge derive from
/// it (`kernel/hex.zig`); ring 0 is the foundation and is never a record.
pub const Coord = struct {
    q: i32,
    r: i32,

    pub fn ring(self: Coord) u32 {
        return @max(@abs(self.q), @abs(self.r), @abs(self.q + self.r));
    }
};

/// Where a technology stands on the board: silent, offered, or established.
pub const TechState = enum { locked, available, researched };

/// A tile of the research board. Technologies have an id space of their own — a tile is
/// never an item and only a `requires.tech` names one — so a recipe and the technology that
/// opens it may share a name. `cost` is the research price, keyed by resource; a tile
/// established at the curtain has none. `initial` is its state when the act opens; the board
/// promotes and establishes from there (`comp.Research`).
pub const Technology = struct {
    id: []const u8,
    name: []const u8,
    /// The board label: a few capitals that fit inside a hex (`FORAGE`, `CISTRN`).
    short: []const u8 = "",
    act: u8 = 2,
    coord: Coord,
    cost: Stock = .{},
    initial: TechState = .locked,
    /// What establishing it does, in the player's words.
    effect: []const u8 = "",
    /// What it opens — a recipe, a verb, a conversion. Empty when nothing distinct.
    enables: []const u8 = "",
};

// ============================ The catalog ===============================================

/// The loaded roster. Owns its records' memory; immutable once handed out.
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    actions: []const Action,
    goods: []const Good,
    technologies: []const Technology,

    /// No records at all, over an arena that owns nothing — what a `Resources` holds before
    /// `load`, and what a UI test rig that never reads the roster gets for free.
    pub const empty: Catalog = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .actions = &.{},
        .goods = &.{},
        .technologies = &.{},
    };

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn action(self: *const Catalog, id: []const u8) ?*const Action {
        for (self.actions) |*a| if (std.mem.eql(u8, a.id, id)) return a;
        return null;
    }

    pub fn good(self: *const Catalog, id: []const u8) ?*const Good {
        for (self.goods) |*g| if (std.mem.eql(u8, g.id, id)) return g;
        return null;
    }

    /// The catalog index of an action — what a `Busy` and the sim's per-agent containers key
    /// on within one load. The id is the identity across loads.
    pub fn actionIndex(self: *const Catalog, id: []const u8) ?u16 {
        for (self.actions, 0..) |a, i| if (std.mem.eql(u8, a.id, id)) return @intCast(i);
        return null;
    }

    pub fn goodIndex(self: *const Catalog, id: []const u8) ?u16 {
        for (self.goods, 0..) |g, i| if (std.mem.eql(u8, g.id, id)) return @intCast(i);
        return null;
    }

    pub fn technology(self: *const Catalog, id: []const u8) ?*const Technology {
        for (self.technologies) |*t| if (std.mem.eql(u8, t.id, id)) return t;
        return null;
    }

    /// The catalog index of a technology — what `comp.Research` keys on within one load.
    pub fn techIndex(self: *const Catalog, id: []const u8) ?u16 {
        for (self.technologies, 0..) |t, i| if (std.mem.eql(u8, t.id, id)) return @intCast(i);
        return null;
    }

    /// The resource an id names, if it names one.
    pub fn resource(id: []const u8) ?Resource {
        return std.meta.stringToEnum(Resource, id);
    }
};

pub const File = enum {
    actions,
    goods,
    technologies,

    pub fn path(self: File) []const u8 {
        return switch (self) {
            .actions => "assets/roster/actions.zon",
            .goods => "assets/roster/goods.zon",
            .technologies => "assets/roster/technologies.zon",
        };
    }
};

/// The files' bytes. `shipped` is the copy compiled into the binary. `technologies`
/// defaults to no records, so a rig over the two Act I files alone needs nothing.
pub const Sources = struct {
    actions: [:0]const u8,
    goods: [:0]const u8,
    technologies: [:0]const u8 = ".{}",
};

pub const shipped = Sources{
    .actions = @embedFile("actions.zon"),
    .goods = @embedFile("goods.zon"),
    .technologies = @embedFile("technologies.zon"),
};

/// The directory, relative to the working directory, whose files override the shipped copy
/// one by one — under `assets/`, where the game finds its other files.
pub const roster_dir = "assets/roster";

/// The most bytes one roster file may hold.
const max_file_bytes = 4 << 20;

/// Load the roster from `dir`: each file it holds replaces the shipped copy of that file, and
/// each file it lacks falls back to the shipped one. A file that exists but cannot be read
/// fails the load like a parse error, with the reason in `diag`. The bytes read are freed
/// before returning; the catalog owns copies of every string it keeps.
pub fn loadDir(gpa: Allocator, io: std.Io, dir: std.Io.Dir, diag: ?*Diagnostics) Error!Catalog {
    const names = @typeInfo(File).@"enum".field_names;
    var src = shipped;
    var owned: [names.len]?[:0]u8 = @splat(null);
    defer for (owned) |o| if (o) |bytes| gpa.free(bytes);
    inline for (names, 0..) |name, i| {
        const file: File = @field(File, name);
        if (dir.readFileAllocOptions(io, std.fs.path.basename(file.path()), gpa, .limited(max_file_bytes), .of(u8), 0)) |bytes| {
            owned[i] = bytes;
            @field(src, name) = bytes;
        } else |err| switch (err) {
            error.FileNotFound => {},
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (diag) |d| d.set(file, null, "cannot read: {s}", .{@errorName(err)});
                return error.Invalid;
            },
        }
    }
    return load(gpa, src, diag);
}

/// Load from `roster_dir` when the working directory has one, else the shipped copy.
pub fn loadData(gpa: Allocator, io: std.Io, diag: ?*Diagnostics) Error!Catalog {
    var dir = std.Io.Dir.cwd().openDir(io, roster_dir, .{}) catch return load(gpa, shipped, diag);
    defer dir.close(io);
    return loadDir(gpa, io, dir, diag);
}

/// The shape and cross-reference rules a loaded roster must satisfy.
pub const Rule = enum {
    /// An id is empty or not `[a-z][a-z0-9_]*`.
    bad_id,
    /// An id is used twice, or collides with a resource name.
    duplicate_id,
    /// An effect names a verb that does not exist.
    unknown_target,
    /// A gate entry names neither a good nor a verb.
    unknown_gate,
    /// A sector is not a resource name.
    unknown_sector,
    /// A `requires.tech` names no technology.
    unknown_tech,
    /// A record references a resource, a good, a verb or a technology from a later act than
    /// its own.
    later_act,
    /// A verb's gates lead back to itself through other verbs' gates.
    gate_cycle,
    /// Two goods share a rank in one family, or a rank is zero.
    rank_collision,
    /// Two goods claim the same milestone.
    milestone_twice,
    /// A buildable good lacks a tier, or a traded one carries a tier or any `requires`.
    buildable_shape,
    /// A negative amount, a non-positive draw scale or effect scale, a tile not established at
    /// the curtain with no research cost, or a generator with no cycle.
    bad_number,
    /// A technology sits on the foundation (ring 0) or shares a coordinate with another.
    bad_coord,
    /// More verbs than `max_actions`, goods than `max_goods` or technologies than `max_techs`.
    too_many,
};

/// Where a load failed: the file, the rule if validation refused it (null for a parse error),
/// and a human-readable message with the line and column or the offending ids.
pub const Diagnostics = struct {
    file: File = .actions,
    rule: ?Rule = null,
    buf: [768]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostics) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Diagnostics, file: File, rule: ?Rule, comptime fmt: []const u8, args: anytype) void {
        self.file = file;
        self.rule = rule;
        var w = std.Io.Writer.fixed(&self.buf);
        w.print("{s}: ", .{file.path()}) catch {};
        w.print(fmt, args) catch {};
        self.len = w.buffered().len;
    }
};

pub const Error = error{ OutOfMemory, Invalid };

/// Parse and validate the files. On `error.Invalid` nothing is allocated for the caller and
/// `diag`, if given, says why.
pub fn load(gpa: Allocator, src: Sources, diag: ?*Diagnostics) Error!Catalog {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const actions = try parseFile([]const Action, a, .actions, src.actions, diag);
    const goods = try parseFile([]const Good, a, .goods, src.goods, diag);
    const technologies = try parseFile([]const Technology, a, .technologies, src.technologies, diag);
    var v = Validator{ .actions = actions, .goods = goods, .technologies = technologies, .diag = diag };
    try v.run();
    return .{ .arena = arena, .actions = actions, .goods = goods, .technologies = technologies };
}

/// `a` is the catalog's arena: it owns the parsed records and the parser's diagnostics, so
/// it doubles as the parser's scratch allocator and nothing needs freeing here.
fn parseFile(comptime T: type, a: Allocator, file: File, source: [:0]const u8, diag: ?*Diagnostics) Error!T {
    var zd: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(T, .{ .gpa = a, .arena = a, .source = source, .diagnostics = &zd }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            if (diag) |d| d.set(file, null, "{f}", .{ZonErrors{ .errors = zd.errors }});
            return error.Invalid;
        },
    };
}

/// The parser's errors as `line:col: error: msg` lines. `Diagnostics.set` already leads with
/// the file's path, so this omits the per-line path `std.zon.parse.Diagnostics.fmt` adds.
const ZonErrors = struct {
    errors: []const std.zon.parse.Diagnostics.Error,

    pub fn format(self: ZonErrors, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.errors) |e| {
            try w.print("{d}:{d}: error: {s}\n", .{ e.loc.line + 1, e.loc.column + 1, e.msg });
            for (e.notes) |n| try w.print("{d}:{d}: note: {s}\n", .{ n.loc.line + 1, n.loc.column + 1, n.msg });
        }
    }
};

const Validator = struct {
    actions: []const Action,
    goods: []const Good,
    technologies: []const Technology,
    diag: ?*Diagnostics,

    fn fail(self: *Validator, file: File, rule: Rule, id: []const u8, subject: []const u8) Error {
        if (self.diag) |d| d.set(file, rule, "{s} in '{s}': '{s}'", .{ @tagName(rule), id, subject });
        return error.Invalid;
    }

    fn run(self: *Validator) Error!void {
        try self.checkCapacity();
        try self.ids();
        for (self.actions) |a| try self.checkAction(a);
        var claimed: [@typeInfo(Milestone).@"enum".field_names.len]bool = @splat(false);
        for (self.goods, 0..) |g, gi| try self.checkGood(g, gi, &claimed);
        for (self.technologies, 0..) |t, ti| try self.checkTech(t, ti);
        var state: [max_actions]u8 = @splat(0);
        for (self.actions, 0..) |a, ai| {
            if (self.cyclic(ai, &state)) return self.fail(.actions, .gate_cycle, a.id, "its own gate");
        }
    }

    /// The caps the sim's bounded containers rely on.
    fn checkCapacity(self: *Validator) Error!void {
        if (self.actions.len > max_actions) return self.fail(.actions, .too_many, self.actions[max_actions].id, "actions");
        if (self.goods.len > max_goods) return self.fail(.goods, .too_many, self.goods[max_goods].id, "goods");
        if (self.technologies.len > max_techs) return self.fail(.technologies, .too_many, self.technologies[max_techs].id, "technologies");
    }

    fn ids(self: *Validator) Error!void {
        for (self.actions, 0..) |a, i| {
            try self.checkId(.actions, a.id);
            if (Catalog.resource(a.id) != null) return self.fail(.actions, .duplicate_id, a.id, "a resource");
            for (self.actions[0..i]) |o| if (eql(a.id, o.id)) return self.fail(.actions, .duplicate_id, a.id, o.id);
        }
        for (self.goods, 0..) |g, i| {
            try self.checkId(.goods, g.id);
            if (Catalog.resource(g.id) != null) return self.fail(.goods, .duplicate_id, g.id, "a resource");
            for (self.goods[0..i]) |o| if (eql(g.id, o.id)) return self.fail(.goods, .duplicate_id, g.id, o.id);
            for (self.actions) |a| if (eql(g.id, a.id)) return self.fail(.goods, .duplicate_id, g.id, "an action");
        }
    }

    fn checkId(self: *Validator, file: File, id: []const u8) Error!void {
        if (id.len == 0 or !std.ascii.isLower(id[0])) return self.fail(file, .bad_id, id, "must start with a lowercase letter");
        for (id) |c| {
            if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return self.fail(file, .bad_id, id, "only [a-z0-9_]");
        }
    }

    /// A record's demands: no negative amount, no resource or gate of a later act, and every
    /// gate naming something.
    fn checkRequires(self: *Validator, file: File, id: []const u8, act: u8, r: Requires) Error!void {
        if (r.energy < 0 or r.hours < 0) return self.fail(file, .bad_number, id, "a negative price");
        for (std.enums.values(Resource)) |res| {
            const n = r.get(res);
            if (n < 0) return self.fail(file, .bad_number, id, @tagName(res));
            if (n > 0 and res.act() > act) return self.fail(file, .later_act, id, @tagName(res));
        }
        if (r.tech) |t| {
            const rec = self.findTech(t) orelse return self.fail(file, .unknown_tech, id, t);
            if (rec.act > act) return self.fail(file, .later_act, id, t);
        }
        for (r.any) |g| try self.checkGate(file, id, act, g);
        for (r.all) |g| try self.checkGate(file, id, act, g);
    }

    fn checkGate(self: *Validator, file: File, id: []const u8, act: u8, gate: []const u8) Error!void {
        const gate_act = if (self.findAction(gate)) |a| a.act else if (self.findGood(gate)) |g| g.act else return self.fail(file, .unknown_gate, id, gate);
        if (gate_act > act) return self.fail(file, .later_act, id, gate);
    }

    fn checkAction(self: *Validator, a: Action) Error!void {
        try self.checkRequires(.actions, a.id, a.act, a.requires);
        if (a.generator and a.requires.hours <= 0) return self.fail(.actions, .bad_number, a.id, "a generator with no cycle");
        for (std.enums.values(Resource)) |res| {
            const d = a.output.get(res) orelse continue;
            if (d.scale() <= 0) return self.fail(.actions, .bad_number, a.id, @tagName(res));
            if (res.act() > a.act) return self.fail(.actions, .later_act, a.id, @tagName(res));
        }
        if (a.output.vigor < 0) return self.fail(.actions, .bad_number, a.id, "a negative vigor");
        for (a.sectors) |s| if (Catalog.resource(s) == null) return self.fail(.actions, .unknown_sector, a.id, s);
    }

    fn checkGood(self: *Validator, g: Good, gi: usize, claimed: []bool) Error!void {
        if (g.buildable) {
            if (g.tier == null) return self.fail(.goods, .buildable_shape, g.id, "a buildable good carries a tier");
        } else if (g.tier != null or !g.requires.isEmpty()) {
            return self.fail(.goods, .buildable_shape, g.id, "a traded good has no tier and no requires");
        }
        try self.checkRequires(.goods, g.id, g.act, g.requires);
        for (g.sectors) |s| if (Catalog.resource(s) == null) return self.fail(.goods, .unknown_sector, g.id, s);
        for (g.effects) |e| try self.checkEffect(g, e);
        if (g.family) |f| {
            if (f.rank == 0) return self.fail(.goods, .rank_collision, g.id, "rank 0");
            for (self.goods[0..gi]) |o| {
                if (o.family) |of| {
                    if (eql(of.name, f.name) and of.rank == f.rank) return self.fail(.goods, .rank_collision, g.id, o.id);
                }
            }
        }
        if (g.milestone) |m| {
            const i = @backingInt(m);
            if (claimed[i]) return self.fail(.goods, .milestone_twice, g.id, @tagName(m));
            claimed[i] = true;
        }
    }

    fn checkEffect(self: *Validator, g: Good, e: Effect) Error!void {
        switch (e) {
            .scale, .add => |tw| {
                const a = self.findAction(tw.target) orelse return self.fail(.goods, .unknown_target, g.id, tw.target);
                if (a.act > g.act) return self.fail(.goods, .later_act, g.id, tw.target);
                if (e == .scale and tw.by <= 0) return self.fail(.goods, .bad_number, g.id, "a scale must be positive");
            },
            .vigor_ceiling => |v| if (v <= 0) return self.fail(.goods, .bad_number, g.id, "vigor_ceiling must be positive"),
            .food_quality => {},
            .spoil_scale => |s| if (s <= 0) return self.fail(.goods, .bad_number, g.id, "spoil_scale must be positive"),
        }
    }

    /// A tile: a plain id unique among technologies, off the foundation and on a coordinate
    /// of its own, priced in non-negative amounts of resources of its act — a positive price
    /// unless it opens established.
    fn checkTech(self: *Validator, t: Technology, ti: usize) Error!void {
        try self.checkId(.technologies, t.id);
        for (self.technologies[0..ti]) |o| {
            if (eql(t.id, o.id)) return self.fail(.technologies, .duplicate_id, t.id, o.id);
            if (o.coord.q == t.coord.q and o.coord.r == t.coord.r) return self.fail(.technologies, .bad_coord, t.id, o.id);
        }
        if (t.coord.ring() == 0) return self.fail(.technologies, .bad_coord, t.id, "the foundation");
        for (std.enums.values(Resource)) |res| {
            const n = t.cost.get(res);
            if (n < 0) return self.fail(.technologies, .bad_number, t.id, @tagName(res));
            if (n > 0 and res.act() > t.act) return self.fail(.technologies, .later_act, t.id, @tagName(res));
        }
        if (t.initial != .researched and t.cost.isEmpty()) return self.fail(.technologies, .bad_number, t.id, "no research cost");
    }

    /// Whether the gates reachable from verb `ai` through the verbs they name come back to a
    /// verb on the path. `state` marks each verb unvisited (0), on the path (1) or done (2).
    fn cyclic(self: *Validator, ai: usize, state: *[max_actions]u8) bool {
        if (state[ai] == 1) return true;
        if (state[ai] == 2) return false;
        state[ai] = 1;
        const r = self.actions[ai].requires;
        for ([_][]const []const u8{ r.any, r.all }) |list| for (list) |gate| {
            const next = self.actionIndex(gate) orelse continue;
            if (self.cyclic(next, state)) return true;
        };
        state[ai] = 2;
        return false;
    }

    fn findTech(self: *Validator, id: []const u8) ?*const Technology {
        for (self.technologies) |*t| if (eql(t.id, id)) return t;
        return null;
    }

    fn findAction(self: *Validator, id: []const u8) ?*const Action {
        for (self.actions) |*a| if (eql(a.id, id)) return a;
        return null;
    }

    fn actionIndex(self: *Validator, id: []const u8) ?usize {
        for (self.actions, 0..) |a, i| if (eql(a.id, id)) return i;
        return null;
    }

    fn findGood(self: *Validator, id: []const u8) ?*const Good {
        for (self.goods) |*g| if (eql(g.id, id)) return g;
        return null;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ============================ Tests =====================================================

const testing = std.testing;

fn loadShipped() !Catalog {
    var d = Diagnostics{};
    return load(testing.allocator, shipped, &d) catch |err| {
        std.debug.print("{s}\n", .{d.message()});
        return err;
    };
}

test "the shipped files load and validate" {
    var cat = try loadShipped();
    defer cat.deinit();
    try testing.expect(cat.actions.len > 0);
    try testing.expect(cat.goods.len > 0);
    try testing.expect(cat.actionIndex("forage") != null);
    try testing.expect(cat.goodIndex("shelter") != null);
    try testing.expect(cat.technologies.len > 0);
    try testing.expectEqual(TechState.researched, cat.technology("foraging").?.initial);
}

test "a record's demands and yields read by resource" {
    var cat = try loadShipped();
    defer cat.deinit();
    const traps = cat.action("check_traps").?;
    try testing.expect(traps.generator);
    try testing.expectEqual(@as(f32, 2.0), traps.requires.get(.biomass));
    try testing.expectEqual(dist.Kind.exponential, traps.output.get(.food).?.kind());
    try testing.expectEqual(@as(f32, 1.5), traps.output.get(.food).?.scale());
    try testing.expect(traps.output.get(.biomass) == null);
    try testing.expectEqualStrings("wire_snares", traps.requires.all[0]);
    try testing.expectEqual(@as(f32, 120.0), cat.good("shelter").?.requires.biomass);
    try testing.expectEqualStrings("rope_bag", cat.good("shelter").?.requires.all[0]);
    try testing.expect(cat.good("fish_rod").?.requires.isEmpty());
}

// —— the validator bites ————————————————————————————————————————————————————————————————

const ok_actions =
    \\.{
    \\    .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 } },
    \\    .{ .id = "fish", .name = "Fish", .requires = .{ .energy = 1.0, .hours = 1.0 } },
    \\}
;

const ok_goods =
    \\.{
    \\    .{ .id = "rod", .name = "Rod", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0, .biomass = 1.0 } },
    \\}
;

fn expectRule(actions_src: [:0]const u8, goods_src: [:0]const u8, rule: Rule) !void {
    var d = Diagnostics{};
    if (load(testing.allocator, .{ .actions = actions_src, .goods = goods_src }, &d)) |*cat| {
        var c = cat.*;
        c.deinit();
        return error.ExpectedInvalid;
    } else |err| {
        try testing.expectEqual(Error.Invalid, err);
        try testing.expectEqual(rule, d.rule.?);
        try testing.expect(d.len > 0);
    }
}

test "the minimal fixture is valid" {
    var cat = try load(testing.allocator, .{ .actions = ok_actions, .goods = ok_goods }, null);
    defer cat.deinit();
}

test "a parse error names the file, the line and the column" {
    var d = Diagnostics{};
    const bad =
        \\.{
        \\    .{ .id = "forage", .nmae = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 } },
        \\}
    ;
    try testing.expectError(error.Invalid, load(testing.allocator, .{ .actions = bad, .goods = ok_goods }, &d));
    try testing.expectEqual(File.actions, d.file);
    try testing.expect(d.rule == null);
    try testing.expect(std.mem.startsWith(u8, d.message(), "assets/roster/actions.zon: 2:"));
    // A resource the enum does not name is a parse error too: the fields are the contract.
    try testing.expectError(error.Invalid, load(testing.allocator, .{ .actions =
        \\.{ .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .berries = 1.0 } } }
    , .goods = ok_goods }, &d));
    try testing.expect(d.rule == null);
}

test "ids are plain, unique, and never a resource name" {
    try expectRule(
        \\.{ .{ .id = "Forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 } } }
    , ok_goods, .bad_id);
    try expectRule(
        \\.{ .{ .id = "food", .name = "Food", .requires = .{ .energy = 1.0, .hours = 1.0 } } }
    , ok_goods, .duplicate_id);
    try expectRule(ok_actions,
        \\.{ .{ .id = "fish", .name = "Fish", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 } } }
    , .duplicate_id);
}

test "amounts and yields name resources of the record's own act" {
    try expectRule(
        \\.{ .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .output = .{ .water = .{ .normal = 1.0 } } } }
    , ok_goods, .later_act);
    try expectRule(
        \\.{ .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0, .metal = 1.0 } } }
    , ok_goods, .later_act);
    try expectRule(
        \\.{ .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0, .biomass = -1.0 } } }
    , ok_goods, .bad_number);
    try expectRule(
        \\.{ .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .output = .{ .food = .{ .poisson = 0.0 } } } }
    , ok_goods, .bad_number);
    try expectRule(
        \\.{ .{ .id = "traps", .name = "Traps", .generator = true, .requires = .{ .energy = 1.0, .hours = 0.0 } } }
    , ok_goods, .bad_number);
}

test "a gate names a good or a verb of the record's own act, and never loops" {
    try expectRule(
        \\.{ .{ .id = "fish", .name = "Fish", .requires = .{ .energy = 1.0, .any = .{"row"} } } }
    , ok_goods, .unknown_gate);
    try expectRule(ok_actions,
        \\.{ .{ .id = "gloves", .name = "Gloves", .tier = .crude, .requires = .{ .energy = 1.0, .all = .{"swim"} } } }
    , .unknown_gate);
    try expectRule(
        \\.{
        \\    .{ .id = "fish", .name = "Fish", .requires = .{ .energy = 1.0, .any = .{"rod"} } },
        \\    .{ .id = "weir", .name = "Weir", .act = 2, .requires = .{ .energy = 1.0, .all = .{"fish"} } },
        \\    .{ .id = "row", .name = "Row", .requires = .{ .energy = 1.0, .all = .{"weir"} } },
        \\}
    , ok_goods, .later_act);
    try expectRule(
        \\.{
        \\    .{ .id = "fish", .name = "Fish", .requires = .{ .energy = 1.0, .all = .{"row"} } },
        \\    .{ .id = "row", .name = "Row", .requires = .{ .energy = 1.0, .any = .{ "rod", "fish" } } },
        \\}
    , ok_goods, .gate_cycle);
    try expectRule(
        \\.{ .{ .id = "fish", .name = "Fish", .requires = .{ .energy = 1.0, .all = .{"fish"} } } }
    , ok_goods, .gate_cycle);
}

test "effects point at verbs the good can reach" {
    try expectRule(ok_actions,
        \\.{ .{ .id = "gloves", .name = "Gloves", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .effects = .{ .{ .scale = .{ .target = "fsh", .stat = .energy, .by = 0.5 } } } } }
    , .unknown_target);
    try expectRule(ok_actions,
        \\.{ .{ .id = "gloves", .name = "Gloves", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0, .all = .{"fish"} },
        \\     .effects = .{ .{ .scale = .{ .target = "fish", .stat = .{ .output = .food }, .by = 0.0 } } } } }
    , .bad_number);
}

test "goods keep their shape" {
    try expectRule(ok_actions,
        \\.{ .{ .id = "rod", .name = "Rod", .requires = .{ .energy = 1.0, .hours = 1.0 } } }
    , .buildable_shape);
    try expectRule(ok_actions,
        \\.{ .{ .id = "net", .name = "Net", .buildable = false, .tier = .crude } }
    , .buildable_shape);
    try expectRule(ok_actions,
        \\.{ .{ .id = "net", .name = "Net", .buildable = false, .requires = .{ .biomass = 2.0 } } }
    , .buildable_shape);
    try expectRule(ok_actions,
        \\.{
        \\    .{ .id = "rod", .name = "Rod", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\       .family = .{ .name = "fishing", .rank = 1 } },
        \\    .{ .id = "net", .name = "Net", .buildable = false, .family = .{ .name = "fishing", .rank = 1 } },
        \\}
    , .rank_collision);
    try expectRule(ok_actions,
        \\.{
        \\    .{ .id = "hut", .name = "Hut", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 }, .milestone = .act_one },
        \\    .{ .id = "hall", .name = "Hall", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 }, .milestone = .act_one },
        \\}
    , .milestone_twice);
}

test "a roster over the verb cap is refused" {
    const many = comptime blk: {
        @setEvalBranchQuota(100_000);
        var s: []const u8 = ".{\n    .{ .id = \"fish\", .name = \"Fish\", .requires = .{ .energy = 1.0, .hours = 1.0 } },\n";
        for (0..max_actions) |i| {
            s = s ++ std.fmt.comptimePrint("    .{{ .id = \"v{d}\", .name = \"V{d}\", .requires = .{{ .energy = 1.0, .hours = 1.0 }} }},\n", .{ i, i });
        }
        break :blk std.fmt.comptimePrint("{s}}}", .{s});
    };
    try expectRule(many, ok_goods, .too_many);
}

// —— technologies ———————————————————————————————————————————————————————————————————————

const ok_techs =
    \\.{
    \\    .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 },
    \\       .cost = .{ .food = 2.0 }, .initial = .available },
    \\}
;

fn expectTechRule(goods_src: [:0]const u8, techs_src: [:0]const u8, rule: Rule) !void {
    var d = Diagnostics{};
    if (load(testing.allocator, .{ .actions = ok_actions, .goods = goods_src, .technologies = techs_src }, &d)) |*cat| {
        var c = cat.*;
        c.deinit();
        return error.ExpectedInvalid;
    } else |err| {
        try testing.expectEqual(Error.Invalid, err);
        try testing.expectEqual(rule, d.rule.?);
    }
}

test "a recipe names a technology that exists, of its own act or earlier" {
    var cat = try load(testing.allocator, .{ .actions = ok_actions, .goods =
        \\.{ .{ .id = "oven", .name = "Oven", .act = 2, .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0, .tech = "kilns" } } }
    , .technologies = ok_techs }, null);
    defer cat.deinit();
    try testing.expectEqual(@as(u16, 0), cat.techIndex("kilns").?);
    try testing.expectEqualStrings("kilns", cat.good("oven").?.requires.tech.?);

    try expectTechRule(
        \\.{ .{ .id = "oven", .name = "Oven", .act = 2, .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0, .tech = "glass" } } }
    , ok_techs, .unknown_tech);
    // Act I has no research: a first-act recipe cannot wait on a second-act tile.
    try expectTechRule(
        \\.{ .{ .id = "oven", .name = "Oven", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0, .tech = "kilns" } } }
    , ok_techs, .later_act);
}

test "a verb names a technology that exists, of its own act or earlier" {
    var cat = try load(testing.allocator, .{ .actions =
        \\.{ .{ .id = "fire", .name = "Fire", .act = 2, .requires = .{ .energy = 1.0, .hours = 1.0, .tech = "kilns" } } }
    , .goods = ".{}", .technologies = ok_techs }, null);
    defer cat.deinit();
    try testing.expectEqualStrings("kilns", cat.action("fire").?.requires.tech.?);

    var d = Diagnostics{};
    try testing.expectError(error.Invalid, load(testing.allocator, .{ .actions =
        \\.{ .{ .id = "fire", .name = "Fire", .act = 2, .requires = .{ .energy = 1.0, .hours = 1.0, .tech = "glass" } } }
    , .goods = ".{}", .technologies = ok_techs }, &d));
    try testing.expectEqual(Rule.unknown_tech, d.rule.?);
    try testing.expectError(error.Invalid, load(testing.allocator, .{ .actions =
        \\.{ .{ .id = "fire", .name = "Fire", .requires = .{ .energy = 1.0, .hours = 1.0, .tech = "kilns" } } }
    , .goods = ".{}", .technologies = ok_techs }, &d));
    try testing.expectEqual(Rule.later_act, d.rule.?);
}

test "technologies keep their shape" {
    try expectTechRule(ok_goods,
        \\.{ .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 0, .r = 0 }, .cost = .{ .food = 1.0 } } }
    , .bad_coord);
    try expectTechRule(ok_goods,
        \\.{
        \\    .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 }, .cost = .{ .food = 1.0 } },
        \\    .{ .id = "wells", .name = "Wells", .coord = .{ .q = 1, .r = 0 }, .cost = .{ .food = 1.0 } },
        \\}
    , .bad_coord);
    try expectTechRule(ok_goods,
        \\.{
        \\    .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 }, .cost = .{ .food = 1.0 } },
        \\    .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 0, .r = 1 }, .cost = .{ .food = 1.0 } },
        \\}
    , .duplicate_id);
    // A tile priced at nothing is refused unless it opens established.
    try expectTechRule(ok_goods,
        \\.{ .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 } } }
    , .bad_number);
    try expectTechRule(ok_goods,
        \\.{ .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 }, .cost = .{ .food = -2.0 } } }
    , .bad_number);
    var cat = try load(testing.allocator, .{ .actions = ok_actions, .goods = ok_goods, .technologies =
        \\.{ .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 }, .initial = .researched } }
    }, null);
    cat.deinit();
}

test "a coordinate's ring is its distance from the foundation" {
    try testing.expectEqual(@as(u32, 0), (Coord{ .q = 0, .r = 0 }).ring());
    try testing.expectEqual(@as(u32, 1), (Coord{ .q = 1, .r = -1 }).ring());
    try testing.expectEqual(@as(u32, 2), (Coord{ .q = -1, .r = -1 }).ring());
    try testing.expectEqual(@as(u32, 4), (Coord{ .q = 4, .r = -4 }).ring());
}
