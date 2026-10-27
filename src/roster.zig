//! `roster` — the **authored roster**: the labor verbs, the capital goods and the technologies
//! as data, loaded from `data/actions.zon`, `data/goods.zon` and `data/technologies.zon` into
//! one `Catalog`.
//!
//! The record grammar is the contract content is written against (the prose is in
//! `src/README.md`, "The authored roster"): one flat id space shared by resources, actions
//! and goods; every quantity a `Line` naming an item, with a cadence of `once` or `day`; a
//! good's behavior a list of `Effect`s from a fixed vocabulary. Loading parses with
//! `std.zon.parse` and then validates every cross-reference and shape rule before the catalog
//! is handed out, so a bad file is refused whole — with a line and column, or a rule and the
//! offending id — never half-applied.
//!
//! The sim runs on the catalog (`actions.zig`, `capital.zig`, `effects.zig`), and so do the
//! pages.

const std = @import("std");
// A relative import, not `ha`: `res.zig` carries the catalog, and `test-ui` compiles `res.zig`
// without the `ha` module.
const dist = @import("./dist.zig");

const Allocator = std.mem.Allocator;

// ============================ The grammar ===============================================

/// The ledger's columns — the fungible stocks an agent holds. In code, because each one is
/// structural (a stockline, a palette hue, a board wedge) and each has its own behavior
/// (food spoils, coin settles). A `Line` names one by its tag name, so the spelling here is
/// part of the content contract.
pub const Resource = enum {
    food,
    biomass,
    water,
    fuel,
    metal,
    minerals,
    coin,

    /// Food and Biomass exist from Act I; the display cover calls Biomass "Materials" until
    /// the curtain.
    pub fn act(self: Resource) u8 {
        return switch (self) {
            .food, .biomass => 1,
            else => 2,
        };
    }

    pub fn letterIn(self: Resource, shown_act: u8) []const u8 {
        return switch (self) {
            .food => "f",
            .biomass => if (shown_act <= 1) "m" else "b",
            .water => "w",
            .fuel => "fu",
            .metal => "me",
            .minerals => "mi",
            .coin => "c",
        };
    }

    pub fn wordIn(self: Resource, shown_act: u8) []const u8 {
        if (self == .biomass) return if (shown_act <= 1) "materials" else "biomass";
        return @tagName(self);
    }

    pub fn labelIn(self: Resource, shown_act: u8) []const u8 {
        return switch (self) {
            .food => "Food",
            .biomass => if (shown_act <= 1) "Materials" else "Biomass",
            .water => "Water",
            .fuel => "Fuel",
            .metal => "Metal",
            .minerals => "Minerals",
            .coin => "Coin",
        };
    }

    pub fn abbrevIn(self: Resource, shown_act: u8) []const u8 {
        return switch (self) {
            .food => "FO",
            .biomass => if (shown_act <= 1) "MA" else "BI",
            .water => "WA",
            .fuel => "FU",
            .metal => "ME",
            .minerals => "MI",
            .coin => "CO",
        };
    }
};

test "resource naming cover changes only biomass at the curtain" {
    try std.testing.expectEqual(@as(u8, 1), Resource.biomass.act());
    try std.testing.expectEqualStrings("m", Resource.biomass.letterIn(1));
    try std.testing.expectEqualStrings("materials", Resource.biomass.wordIn(1));
    try std.testing.expectEqualStrings("Materials", Resource.biomass.labelIn(1));
    try std.testing.expectEqualStrings("MA", Resource.biomass.abbrevIn(1));
    try std.testing.expectEqualStrings("b", Resource.biomass.letterIn(2));
    try std.testing.expectEqualStrings("biomass", Resource.biomass.wordIn(2));
    try std.testing.expectEqualStrings("Biomass", Resource.biomass.labelIn(2));
    try std.testing.expectEqualStrings("BI", Resource.biomass.abbrevIn(2));

    inline for ([_]Resource{ .food, .water, .fuel, .metal, .minerals, .coin }) |r| {
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

/// When a line settles. `once` is paid at begin (an input) or lands at completion (an
/// output); `day` is an authored per-day rate on a generator and is realized as one complete,
/// cycle-scaled amount when the player collects.
pub const Cadence = enum { once, day };

/// One quantity of one item — the only shape a cost, an upkeep, a yield, a satchel or a
/// quote is written in. `item` is a resource name or a good id. `kind` defaults to `.fixed`,
/// an exact amount; the other kinds draw, and `n` is then the scale (`dist.Dist.s`).
pub const Line = struct {
    item: []const u8,
    n: f32,
    kind: dist.Kind = .fixed,
    sd: f32 = 0,
    per: Cadence = .once,

    /// The line as the distribution the sim samples.
    pub fn asDist(self: Line) dist.Dist {
        return .{ .kind = self.kind, .s = self.n, .sd = self.sd };
    }
};

/// The caps the sim's bounded per-agent containers rely on (`comp.Goods`, `comp.Research`);
/// the validator holds the files to them. `max_lines` bounds one side of a verb *after*
/// every `add` effect on it has inserted its line.
pub const max_goods = 128;
pub const max_lines = 4;
pub const max_techs = 128;

/// A bounded list of lines — one side of a verb's effective terms, or a receipt.
pub const Lines = struct {
    items: [max_lines]Line = undefined,
    len: u8 = 0,

    pub fn of(src: []const Line) Lines {
        var l = Lines{};
        for (src) |x| l.push(x);
        return l;
    }

    /// The lines of `src` at one cadence: a build order or a flow, an upkeep or a product.
    pub fn only(src: []const Line, per: Cadence) Lines {
        var l = Lines{};
        for (src) |x| if (x.per == per) l.push(x);
        return l;
    }

    pub fn slice(self: *const Lines) []const Line {
        return self.items[0..self.len];
    }

    pub fn push(self: *Lines, l: Line) void {
        std.debug.assert(self.len < max_lines);
        self.items[self.len] = l;
        self.len += 1;
    }

    /// The line for `item` at cadence `per`, if present.
    pub fn find(self: *Lines, item: []const u8, per: Cadence) ?*Line {
        for (self.items[0..self.len]) |*l| if (l.per == per and eql(l.item, item)) return l;
        return null;
    }
};

/// The body-and-time price of an act: energy, a flow that is never a stock, and hours. Kept
/// apart from the lines because energy's gate is strict (vigor may never reach zero) where
/// an item's is not.
pub const Price = struct {
    energy: f32,
    hours: f32,
};

/// A collectable generator's cycle. `hours` is passive accumulation time; `energy` is paid
/// only when collecting and never occupies the actor. Day-cadence input/output lines remain
/// rates and are multiplied by the cycle's fraction of a day. `vigor` is a fixed direct
/// restoration for generators such as a medicinal herb bed.
pub const Generator = struct {
    energy: f32,
    hours: f32,
    vigor: f32 = 0,
    /// Optional action label when collecting is a verb distinct from the owned good's name.
    label: []const u8 = "",
};

/// What an effect tweaks on its target verb: the price, or one named input/output line.
pub const Stat = union(enum) {
    energy,
    hours,
    input: []const u8,
    output: []const u8,
};

/// What owning a good does. A small fixed vocabulary; the sim is its interpreter, and a new
/// kind of effect is a code change while a new good is not.
pub const Effect = union(enum) {
    /// The target verb exists while this good is held.
    grant: []const u8,
    /// Multiply a stat on the target verb. A yield scale moves `s` and `sd` together.
    scale: Tweak,
    /// Offset a stat on the target verb; a line that is absent is inserted.
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

/// Standing conditions a good asks of its builder, read once at begin — as against `input`,
/// which is what the build spends.
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
    /// Whether the ACTIONS surface lists it. A verb can exist, and be granted, off-surface.
    on_surface: bool = true,
    /// Spawned on every agent, bare-handed; everything else arrives by a grant.
    innate: bool = false,
    /// Resource domains the verb works in; the specialization model's key.
    sectors: []const []const u8 = &.{},
    /// Retained tooling: ids that must be held for the verb to be offered.
    needs: []const []const u8 = &.{},
    /// The technology that opens the verb: held once it is researched, as a grant would.
    tech: ?[]const u8 = null,
    requires: Price,
    input: []const Line = &.{},
    output: []const Line = &.{},
};

pub const Good = struct {
    id: []const u8,
    name: []const u8,
    act: u8 = 1,
    /// False for a good the passerby carries and no one builds; it then has no price or tier.
    buildable: bool = true,
    tier: ?Tier = null,
    sectors: []const []const u8 = &.{},
    requires: ?Price = null,
    /// `once` lines are the build order; `day` lines are the upkeep.
    input: []const Line = &.{},
    /// `once` lines are the product — absent means one of itself; `day` lines are the
    /// generator's authored rate, realized only on collection.
    output: []const Line = &.{},
    /// Passive cycle metadata. Null means this good is not shown on the GENERATORS surface.
    generator: ?Generator = null,
    /// The verb (or tool) a modifier works on; must be held before the good is offered.
    needs: []const []const u8 = &.{},
    family: ?Family = null,
    effects: []const Effect = &.{},
    unlock: ?Unlock = null,
    /// How many humans it houses. Zero for everything but a shelter.
    capacity: u32 = 0,
    milestone: ?Milestone = null,
    /// The technology a recipe waits on: offered only once it is researched.
    tech: ?[]const u8 = null,
    copy: Copy = .{},
};

/// An axial position on the research board. The ring and the pure/hybrid wedge derive from
/// it (`grid/hex.zig`); ring 0 is the foundation and is never a record.
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
/// never an item and only a good's `tech` names one — so a recipe and the technology that
/// opens it may share a name. `cost` is the research price as once-lines; a tile established
/// at the curtain has none. `initial` is its state when the act opens; the board promotes
/// and establishes from there (`comp.Research`).
pub const Technology = struct {
    id: []const u8,
    name: []const u8,
    act: u8 = 2,
    coord: Coord,
    cost: []const Line = &.{},
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

    /// The first act an item (a resource or a good) exists in, or null for an unknown id.
    pub fn itemAct(self: *const Catalog, id: []const u8) ?u8 {
        if (resource(id)) |r| return r.act();
        if (self.good(id)) |g| return g.act;
        return null;
    }
};

pub const File = enum {
    actions,
    goods,
    technologies,

    pub fn path(self: File) []const u8 {
        return switch (self) {
            .actions => "data/actions.zon",
            .goods => "data/goods.zon",
            .technologies => "data/technologies.zon",
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
/// one by one — beside `assets/`, where the game finds its other files.
pub const data_dir = "data";

/// The most bytes one data file may hold.
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

/// Load from `data_dir` when the working directory has one, else the shipped copy.
pub fn loadData(gpa: Allocator, io: std.Io, diag: ?*Diagnostics) Error!Catalog {
    var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{}) catch return load(gpa, shipped, diag);
    defer dir.close(io);
    return loadDir(gpa, io, dir, diag);
}

/// The shape and cross-reference rules a loaded roster must satisfy.
pub const Rule = enum {
    /// An id is empty or not `[a-z][a-z0-9_]*`.
    bad_id,
    /// An id is used twice, or collides with a resource name.
    duplicate_id,
    /// A line names an item that is neither a resource nor a good.
    unknown_item,
    /// An effect names a verb that does not exist.
    unknown_target,
    /// A `needs` entry names nothing.
    unknown_need,
    /// A sector is not a resource name.
    unknown_sector,
    /// A good's or a verb's `tech` names no technology.
    unknown_tech,
    /// A record references an item or verb from a later act than its own.
    later_act,
    /// A grant targets an innate verb.
    grant_innate,
    /// A scale/add targets a verb the good neither needs nor grants, and that is not innate.
    target_not_held,
    /// Two goods share a rank in one family, or a rank is zero.
    rank_collision,
    /// Two goods claim the same milestone.
    milestone_twice,
    /// A good's once-output names something other than itself.
    output_not_self,
    /// A buildable good lacks a price or tier, or a traded one carries them.
    buildable_shape,
    /// An action carries a day line; actions resolve once.
    bad_cadence,
    /// A negative quantity, a drawn input, a non-positive scale, or a zero research cost.
    bad_number,
    /// A technology sits on the foundation (ring 0) or shares a coordinate with another.
    bad_coord,
    /// More goods than `max_goods` or technologies than `max_techs`, or more lines on one
    /// side of a record than `max_lines` once every `add` on it has inserted its line.
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
        try self.ids();
        for (self.actions) |a| try self.checkAction(a);
        var claimed: [@typeInfo(Milestone).@"enum".field_names.len]bool = @splat(false);
        for (self.goods, 0..) |g, gi| try self.checkGood(g, gi, &claimed);
        for (self.technologies, 0..) |t, ti| try self.checkTech(t, ti);
        try self.checkCapacity();
    }

    /// The caps the sim's bounded containers rely on.
    fn checkCapacity(self: *Validator) Error!void {
        if (self.goods.len > max_goods) return self.fail(.goods, .too_many, self.goods[max_goods].id, "goods");
        if (self.technologies.len > max_techs) return self.fail(.technologies, .too_many, self.technologies[max_techs].id, "technologies");
        for (self.actions) |a| {
            try self.checkSide(.actions, a.id, a.input, true);
            try self.checkSide(.actions, a.id, a.output, false);
        }
        for (self.goods) |g| {
            if (g.input.len > max_lines) return self.fail(.goods, .too_many, g.id, "input lines");
            if (g.output.len > max_lines) return self.fail(.goods, .too_many, g.id, "output lines");
        }
    }

    /// One side of a verb must still fit after every `add` on it has inserted its line.
    fn checkSide(self: *Validator, file: File, id: []const u8, base: []const Line, is_input: bool) Error!void {
        if (base.len > max_lines) return self.fail(file, .too_many, id, "lines");
        var inserted: [max_lines][]const u8 = undefined;
        var ins: usize = 0;
        for (self.goods) |g| {
            for (g.effects) |e| {
                const tw = switch (e) {
                    .add => |t| t,
                    else => continue,
                };
                if (!eql(tw.target, id)) continue;
                const item = switch (tw.stat) {
                    .input => |i| if (is_input) i else continue,
                    .output => |o| if (!is_input) o else continue,
                    else => continue,
                };
                var present = false;
                for (base) |l| if (l.per == .once and eql(l.item, item)) {
                    present = true;
                };
                for (inserted[0..ins]) |x| if (eql(x, item)) {
                    present = true;
                };
                if (present) continue;
                if (base.len + ins + 1 > max_lines) return self.fail(file, .too_many, id, item);
                inserted[ins] = item;
                ins += 1;
            }
        }
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

    fn checkPrice(self: *Validator, file: File, id: []const u8, p: Price) Error!void {
        if (p.energy < 0 or p.hours < 0) return self.fail(file, .bad_number, id, "a negative price");
    }

    fn checkAction(self: *Validator, a: Action) Error!void {
        try self.checkPrice(.actions, a.id, a.requires);
        for (a.input) |l| {
            try self.checkLine(.actions, a.id, a.act, l, true);
            if (l.per == .day) return self.fail(.actions, .bad_cadence, a.id, l.item);
        }
        for (a.output) |l| {
            try self.checkLine(.actions, a.id, a.act, l, false);
            if (l.per == .day) return self.fail(.actions, .bad_cadence, a.id, l.item);
        }
        for (a.sectors) |s| if (Catalog.resource(s) == null) return self.fail(.actions, .unknown_sector, a.id, s);
        for (a.needs) |n| try self.checkNeed(.actions, a.id, a.act, n);
        if (a.tech) |t| {
            const rec = self.findTech(t) orelse return self.fail(.actions, .unknown_tech, a.id, t);
            if (rec.act > a.act) return self.fail(.actions, .later_act, a.id, t);
        }
    }

    fn checkGood(self: *Validator, g: Good, gi: usize, claimed: []bool) Error!void {
        if (g.buildable) {
            if (g.requires == null or g.tier == null) return self.fail(.goods, .buildable_shape, g.id, "a buildable good carries requires and tier");
        } else if (g.requires != null or g.tier != null) {
            return self.fail(.goods, .buildable_shape, g.id, "a traded good has no price or tier");
        }
        if (g.requires) |p| try self.checkPrice(.goods, g.id, p);
        if (g.generator) |gen| {
            if (gen.energy < 0 or gen.hours <= 0 or gen.vigor < 0) return self.fail(.goods, .bad_number, g.id, "invalid generator cycle");
        }
        for (g.input) |l| try self.checkLine(.goods, g.id, g.act, l, true);
        for (g.output) |l| {
            try self.checkLine(.goods, g.id, g.act, l, false);
            if (l.per == .once and !eql(l.item, g.id)) return self.fail(.goods, .output_not_self, g.id, l.item);
        }
        for (g.sectors) |s| if (Catalog.resource(s) == null) return self.fail(.goods, .unknown_sector, g.id, s);
        for (g.needs) |n| try self.checkNeed(.goods, g.id, g.act, n);
        if (g.tech) |t| {
            const rec = self.findTech(t) orelse return self.fail(.goods, .unknown_tech, g.id, t);
            if (rec.act > g.act) return self.fail(.goods, .later_act, g.id, t);
        }
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
            const i = @intFromEnum(m);
            if (claimed[i]) return self.fail(.goods, .milestone_twice, g.id, @tagName(m));
            claimed[i] = true;
        }
    }

    fn checkLine(self: *Validator, file: File, id: []const u8, act: u8, l: Line, is_input: bool) Error!void {
        const item_act = self.itemAct(l.item) orelse return self.fail(file, .unknown_item, id, l.item);
        if (item_act > act) return self.fail(file, .later_act, id, l.item);
        if (l.n < 0 or l.sd < 0) return self.fail(file, .bad_number, id, l.item);
        if (is_input and l.kind != .fixed) return self.fail(file, .bad_number, id, "an input is an exact amount");
    }

    fn checkNeed(self: *Validator, file: File, id: []const u8, act: u8, need: []const u8) Error!void {
        if (self.findAction(need)) |a| {
            if (a.act > act) return self.fail(file, .later_act, id, need);
            return;
        }
        if (self.findGood(need)) |g| {
            if (g.act > act) return self.fail(file, .later_act, id, need);
            return;
        }
        return self.fail(file, .unknown_need, id, need);
    }

    fn checkEffect(self: *Validator, g: Good, e: Effect) Error!void {
        switch (e) {
            .grant => |t| {
                const a = self.findAction(t) orelse return self.fail(.goods, .unknown_target, g.id, t);
                if (a.act > g.act) return self.fail(.goods, .later_act, g.id, t);
                if (a.innate) return self.fail(.goods, .grant_innate, g.id, t);
            },
            .scale, .add => |tw| {
                const a = self.findAction(tw.target) orelse return self.fail(.goods, .unknown_target, g.id, tw.target);
                if (a.act > g.act) return self.fail(.goods, .later_act, g.id, tw.target);
                if (!a.innate and !self.holds(g, tw.target)) return self.fail(.goods, .target_not_held, g.id, tw.target);
                switch (tw.stat) {
                    .energy, .hours => {},
                    .input, .output => |item| {
                        if (self.itemAct(item) == null) return self.fail(.goods, .unknown_item, g.id, item);
                    },
                }
                if (e == .scale and tw.by <= 0) return self.fail(.goods, .bad_number, g.id, "a scale must be positive");
            },
            .vigor_ceiling => |v| if (v <= 0) return self.fail(.goods, .bad_number, g.id, "vigor_ceiling must be positive"),
            .food_quality => {},
            .spoil_scale => |s| if (s <= 0) return self.fail(.goods, .bad_number, g.id, "spoil_scale must be positive"),
        }
    }

    /// Whether `g` guarantees the verb `target` exists when its effects apply: it needs it or
    /// grants it itself.
    fn holds(self: *Validator, g: Good, target: []const u8) bool {
        _ = self;
        for (g.needs) |n| if (eql(n, target)) return true;
        for (g.effects) |e| switch (e) {
            .grant => |t| if (eql(t, target)) return true,
            else => {},
        };
        return false;
    }

    /// A tile: a plain id unique among technologies, off the foundation and on a coordinate
    /// of its own, priced in exact once-lines of positive amounts.
    fn checkTech(self: *Validator, t: Technology, ti: usize) Error!void {
        try self.checkId(.technologies, t.id);
        for (self.technologies[0..ti]) |o| {
            if (eql(t.id, o.id)) return self.fail(.technologies, .duplicate_id, t.id, o.id);
            if (o.coord.q == t.coord.q and o.coord.r == t.coord.r) return self.fail(.technologies, .bad_coord, t.id, o.id);
        }
        if (t.coord.ring() == 0) return self.fail(.technologies, .bad_coord, t.id, "the foundation");
        for (t.cost) |l| {
            try self.checkLine(.technologies, t.id, t.act, l, true);
            if (l.per == .day) return self.fail(.technologies, .bad_cadence, t.id, l.item);
            if (l.n <= 0) return self.fail(.technologies, .bad_number, t.id, l.item);
        }
    }

    fn findTech(self: *Validator, id: []const u8) ?*const Technology {
        for (self.technologies) |*t| if (eql(t.id, id)) return t;
        return null;
    }

    fn findAction(self: *Validator, id: []const u8) ?*const Action {
        for (self.actions) |*a| if (eql(a.id, id)) return a;
        return null;
    }

    fn findGood(self: *Validator, id: []const u8) ?*const Good {
        for (self.goods) |*g| if (eql(g.id, id)) return g;
        return null;
    }

    fn itemAct(self: *Validator, id: []const u8) ?u8 {
        if (Catalog.resource(id)) |r| return r.act();
        if (self.findGood(id)) |g| return g.act;
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

// —— the validator bites ————————————————————————————————————————————————————————————————

const ok_actions =
    \\.{
    \\    .{ .id = "forage", .name = "Forage", .innate = true, .requires = .{ .energy = 1.0, .hours = 1.0 } },
    \\    .{ .id = "fish", .name = "Fish", .requires = .{ .energy = 1.0, .hours = 1.0 } },
    \\}
;

const ok_goods =
    \\.{
    \\    .{ .id = "rod", .name = "Rod", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
    \\       .input = .{ .{ .item = "biomass", .n = 1.0 } }, .effects = .{ .{ .grant = "fish" } } },
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
    try testing.expect(std.mem.startsWith(u8, d.message(), "data/actions.zon: 2:"));
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

test "lines name real items of the record's own act" {
    try expectRule(
        \\.{ .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .output = .{ .{ .item = "berries", .n = 1.0 } } } }
    , ok_goods, .unknown_item);
    try expectRule(
        \\.{ .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .output = .{ .{ .item = "water", .n = 1.0 } } } }
    , ok_goods, .later_act);
    try expectRule(
        \\.{ .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .input = .{ .{ .item = "biomass", .n = 1.0, .kind = .normal } } } }
    , ok_goods, .bad_number);
    try expectRule(
        \\.{ .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .output = .{ .{ .item = "food", .n = 1.0, .per = .day } } } }
    , ok_goods, .bad_cadence);
}

test "effects point at verbs the good can reach" {
    try expectRule(ok_actions,
        \\.{ .{ .id = "rod", .name = "Rod", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .effects = .{ .{ .grant = "swim" } } } }
    , .unknown_target);
    try expectRule(ok_actions,
        \\.{ .{ .id = "rod", .name = "Rod", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .effects = .{ .{ .grant = "forage" } } } }
    , .grant_innate);
    // A modifier on a non-innate verb must need it or grant it.
    try expectRule(ok_actions,
        \\.{ .{ .id = "gloves", .name = "Gloves", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .effects = .{ .{ .scale = .{ .target = "fish", .stat = .energy, .by = 0.5 } } } } }
    , .target_not_held);
    try expectRule(ok_actions,
        \\.{ .{ .id = "gloves", .name = "Gloves", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .needs = .{"fish"}, .effects = .{ .{ .scale = .{ .target = "fish", .stat = .energy, .by = 0.0 } } } } }
    , .bad_number);
    try expectRule(ok_actions,
        \\.{ .{ .id = "gloves", .name = "Gloves", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .needs = .{"row"} } }
    , .unknown_need);
}

test "goods keep their shape" {
    try expectRule(ok_actions,
        \\.{ .{ .id = "rod", .name = "Rod", .requires = .{ .energy = 1.0, .hours = 1.0 } } }
    , .buildable_shape);
    try expectRule(ok_actions,
        \\.{ .{ .id = "net", .name = "Net", .buildable = false, .tier = .crude } }
    , .buildable_shape);
    try expectRule(ok_actions,
        \\.{ .{ .id = "kiln", .name = "Kiln", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .output = .{ .{ .item = "food", .n = 4.0 } } } }
    , .output_not_self);
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

test "a lot of an intermediate is its own once-output" {
    var cat = try load(testing.allocator, .{ .actions = ok_actions, .goods =
        \\.{ .{ .id = "charcoal", .name = "Charcoal", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .input = .{ .{ .item = "biomass", .n = 6.0 } }, .output = .{ .{ .item = "charcoal", .n = 4.0 } } } }
    }, null);
    defer cat.deinit();
    try testing.expectEqual(@as(f32, 4.0), cat.good("charcoal").?.output[0].n);
}

// —— technologies ———————————————————————————————————————————————————————————————————————

const ok_techs =
    \\.{
    \\    .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 },
    \\       .cost = .{ .{ .item = "food", .n = 2.0 } }, .initial = .available },
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
        \\.{ .{ .id = "oven", .name = "Oven", .act = 2, .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .tech = "kilns" } }
    , .technologies = ok_techs }, null);
    defer cat.deinit();
    try testing.expectEqual(@as(u16, 0), cat.techIndex("kilns").?);
    try testing.expectEqualStrings("kilns", cat.good("oven").?.tech.?);

    try expectTechRule(
        \\.{ .{ .id = "oven", .name = "Oven", .act = 2, .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .tech = "glass" } }
    , ok_techs, .unknown_tech);
    // Act I has no research: a first-act recipe cannot wait on a second-act tile.
    try expectTechRule(
        \\.{ .{ .id = "oven", .name = "Oven", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .tech = "kilns" } }
    , ok_techs, .later_act);
}

test "a verb names a technology that exists, of its own act or earlier" {
    var cat = try load(testing.allocator, .{ .actions =
        \\.{ .{ .id = "fire", .name = "Fire", .act = 2, .tech = "kilns", .requires = .{ .energy = 1.0, .hours = 1.0 } } }
    , .goods = ".{}", .technologies = ok_techs }, null);
    defer cat.deinit();
    try testing.expectEqualStrings("kilns", cat.action("fire").?.tech.?);

    var d = Diagnostics{};
    try testing.expectError(error.Invalid, load(testing.allocator, .{ .actions =
        \\.{ .{ .id = "fire", .name = "Fire", .act = 2, .tech = "glass", .requires = .{ .energy = 1.0, .hours = 1.0 } } }
    , .goods = ".{}", .technologies = ok_techs }, &d));
    try testing.expectEqual(Rule.unknown_tech, d.rule.?);
    try testing.expectError(error.Invalid, load(testing.allocator, .{ .actions =
        \\.{ .{ .id = "fire", .name = "Fire", .tech = "kilns", .requires = .{ .energy = 1.0, .hours = 1.0 } } }
    , .goods = ".{}", .technologies = ok_techs }, &d));
    try testing.expectEqual(Rule.later_act, d.rule.?);
}

test "technologies keep their shape" {
    try expectTechRule(ok_goods,
        \\.{ .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 0, .r = 0 } } }
    , .bad_coord);
    try expectTechRule(ok_goods,
        \\.{
        \\    .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 } },
        \\    .{ .id = "wells", .name = "Wells", .coord = .{ .q = 1, .r = 0 } },
        \\}
    , .bad_coord);
    try expectTechRule(ok_goods,
        \\.{
        \\    .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 } },
        \\    .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 0, .r = 1 } },
        \\}
    , .duplicate_id);
    try expectTechRule(ok_goods,
        \\.{ .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 },
        \\     .cost = .{ .{ .item = "food", .n = 0.0 } } } }
    , .bad_number);
    try expectTechRule(ok_goods,
        \\.{ .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 },
        \\     .cost = .{ .{ .item = "food", .n = 2.0, .per = .day } } } }
    , .bad_cadence);
    try expectTechRule(ok_goods,
        \\.{ .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 },
        \\     .cost = .{ .{ .item = "clay", .n = 2.0 } } } }
    , .unknown_item);
}

test "a coordinate's ring is its distance from the foundation" {
    try testing.expectEqual(@as(u32, 0), (Coord{ .q = 0, .r = 0 }).ring());
    try testing.expectEqual(@as(u32, 1), (Coord{ .q = 1, .r = -1 }).ring());
    try testing.expectEqual(@as(u32, 2), (Coord{ .q = -1, .r = -1 }).ring());
    try testing.expectEqual(@as(u32, 4), (Coord{ .q = 4, .r = -4 }).ring());
}
