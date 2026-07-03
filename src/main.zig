const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const tag = ha.tag;
const ui = ha.ui;
const Resources = ha.res.Resources;
const widgets = ha.widgets;
const sdl = ha.sdl;
const sys = ha.systems;
const ecs = ha.ecs;

const fps = 60;
const font_path = "assets/fonts/Kenney Mini Square.ttf";

/// Real seconds per in-game day — paces the `Day N` readout. Tunable; the day is flavor
/// today (population, not day-count, is the progression spine).
const secs_per_day: f32 = 20;

/// Where an action's produce lands — the perishable larder or the durable stockpile.
const Yield = enum { food, materials };

/// A choice open to the actor. The action is *priced* in `energy_cost` — the work it takes —
/// which the actor pays from `Vigor` (its muscle). Paying also burns `Satiety` (work makes
/// you hungry). For that price it rolls a `p_success` chance at `yield` units landing in the
/// `target` stock (food to eat, or materials to build with). The yield is *scaled by current
/// vigor* (`v / max`): a tired actor produces below standard, so the labor/leisure margin is
/// implicit — work while drained for poor output, or pause and let vigor refill. The player
/// ranks these and acts on the one it most prefers; later the sim's AI ranks the same
/// catalog. Praxeology: cost, options, uncertainty.
const Action = struct {
    label: []const u8,
    energy_cost: f32, // the work the action takes; paid from Vigor
    yield: f32, // units produced on success, before vigor-scaling
    target: Yield, // which stock the yield lands in
    p_success: f32,
};

const actions = [_]Action{
    // Forage: cheap, reliable food. The hand-to-mouth staple.
    .{ .label = "Forage", .energy_cost = 2, .yield = 5, .target = .food, .p_success = 0.85 },
    // Fish: dearer and riskier, but a real food surplus when it lands.
    .{ .label = "Fish", .energy_cost = 4, .yield = 14, .target = .food, .p_success = 0.4 },
    // Chop wood: turns effort into building materials — the investment feedstock.
    .{ .label = "Chop wood", .energy_cost = 5, .yield = 8, .target = .materials, .p_success = 0.6 },
};

/// Satiety burned per unit of energy the actor pays from vigor — work makes you hungry.
const effort_k: f32 = 0.4;

/// Vigor a build click won't dip below — so investing in capital never zeroes vigor (which
/// is death). Building stops when you hit this floor; the rest waits for vigor to refill.
const build_vigor_floor: f32 = 0.5;

const CapitalKind = enum { tool, comfort };

/// A capital good: build it now by paying an `energy_cost` (work, from vigor) and consuming
/// `material_cost` from the stockpile — the *now-vs-later* margin, with teeth (your score
/// dips to build). A `.tool` improves one action (`target` indexes into `actions`) via any
/// mix of three effects: `yield_mult`/`prob_add` boost its output (a rod), `cost_mult` < 1
/// lowers its energy price (an axe — saves human effort), and `power_capacity` > 0 makes it
/// an *external-energy* tool (a saw) that pays the action's price from its own durability
/// instead of vigor, wearing down by the energy it supplies and breaking at 0. A `.comfort`
/// good raises vigor recovery (`trickle_add`). One-time unlocks, tracked by a bit in
/// `comp.Capital.owned`; durability (power tools) lives in `comp.Capital.durability`.
const Good = struct {
    label: []const u8,
    energy_cost: f32, // work to build it; paid from Vigor
    material_cost: f32, // goods consumed from the stockpile to build it
    kind: CapitalKind,
    target: usize = 0, // tool only: which action it improves
    yield_mult: f32 = 1.0, // tool only: scales the action's yield
    prob_add: f32 = 0.0, // tool only: adds to the action's success chance
    cost_mult: f32 = 1.0, // tool only: scales the action's energy price (effort-saver, < 1)
    power_capacity: f32 = 0.0, // tool only: > 0 ⇒ external-energy tool, this much durability (energy units)
    trickle_add: f32 = 0.0, // comfort only
    icon_col: f32 = 0, // which cell of the icons.png sheet (grid col, row)
    icon_row: f32 = 0,
};

/// On-screen size of a capital icon button.
const icon_px = 56.0;
/// Gap between a hovered icon and the tooltip floating above it.
const tip_gap = 6.0;

const capital = [_]Good{
    // Sandals: walking is easier, makes foraging (actions[0]) more effective. (sheet: top-right)
    .{ .label = "Sandals", .energy_cost = 6, .material_cost = 8, .kind = .tool, .target = 0, .yield_mult = 1.1, .prob_add = 0.10, .icon_col = 1, .icon_row = 0 },
    // Fishing rod: makes Fish (actions[1]) land more often and yield more. (sheet: top-left)
    .{ .label = "Fishing rod", .energy_cost = 8, .material_cost = 20, .kind = .tool, .target = 1, .yield_mult = 1.6, .prob_add = 0.25, .icon_col = 0, .icon_row = 0 },
    // Bed: rest better — vigor trickles back faster. (sheet: bottom-left)
    .{ .label = "Bed", .energy_cost = 6, .material_cost = 16, .kind = .comfort, .trickle_add = 0.4, .icon_col = 0, .icon_row = 1 },
    // Fireplace: warmth speeds recovery a lot. (sheet: bottom-right)
    .{ .label = "Fireplace", .energy_cost = 10, .material_cost = 40, .kind = .comfort, .trickle_add = 0.8, .icon_col = 1, .icon_row = 1 },
    // Axe: effort-saver — makes Chop wood (actions[2]) cheaper to swing. PLACEHOLDER icon
    // (borrows the sandals cell) until axe art exists.
    .{ .label = "Axe", .energy_cost = 8, .material_cost = 18, .kind = .tool, .target = 2, .cost_mult = 0.6, .icon_col = 1, .icon_row = 0 },
    // Saw: external-energy tool — pays Chop wood's (actions[2]) price from its own durability
    // instead of vigor, sparing muscle until it wears out. PLACEHOLDER icon (borrows the
    // fireplace cell) until saw art exists.
    .{ .label = "Saw", .energy_cost = 14, .material_cost = 45, .kind = .tool, .target = 2, .power_capacity = 80, .icon_col = 1, .icon_row = 1 },
};

/// Spawn a fresh actor — rested but hungry, with a thin larder and nothing built. Used at
/// startup and on "start over": death wipes the entity, this reseeds the run from the
/// bottom, so everything accumulated is lost. Satiety starts part-full so the hunger clock
/// is already ticking; food is scarce, so the first job is to keep eating.
fn spawn_player(world: *ha.world.World) void {
    _ = world.spawn(.{
        comp.Vigor{ .v = 10, .max = 10, .trickle = 0.5 }, // rested; passive regen up to the hunger cap
        comp.Satiety{ .v = 6, .max = 10, .drain = 0.25 }, // peckish; hunger clock already running
        comp.Food{ .v = 4, .max = 30, .spoil = 0.05 }, // a thin, perishable larder
        comp.Materials{ .v = 0 }, // nothing stockpiled yet
        comp.Capital{}, // owns nothing yet
        tag.Player,
    });
}

/// Bit mask for capital good `i` (its index in the `capital` catalog).
fn bit(i: usize) u32 {
    return @as(u32, 1) << @as(u5, @intCast(i));
}

/// Whether the actor owns capital good `i`.
fn owns(cap: *const comp.Capital, i: usize) bool {
    return (cap.owned & bit(i)) != 0;
}

/// Format good `gi`'s hover detail into `buf`. Owned: "owned" (or remaining durability for a
/// power tool); unowned: its build cost (energy work + materials) and salient effect — powered
/// (pays an action from durability), effort-saver (×cost on an action), output boost (yield/
/// odds), or comfort (vigor trickle). Falls back to the bare label if the buffer is too small.
fn capital_tip(buf: []u8, g: Good, gi: usize, cap: *const comp.Capital) []const u8 {
    if (owns(cap, gi)) {
        if (g.power_capacity > 0)
            return std.fmt.bufPrint(buf, "{s}: {d:.0}/{d:.0} durability", .{ g.label, cap.durability[gi], g.power_capacity }) catch g.label;
        return std.fmt.bufPrint(buf, "{s}: owned", .{g.label}) catch g.label;
    }
    if (cap.progress[gi] > 0) // a build underway — show how far along
        return std.fmt.bufPrint(buf, "{s}: building {d:.0}/{d:.0} e", .{ g.label, cap.progress[gi], g.energy_cost }) catch g.label;
    if (g.kind == .comfort)
        return std.fmt.bufPrint(buf, "{s}: {d:.0} e, {d:.0} mat | +{d:.1}/s vig", .{ g.label, g.energy_cost, g.material_cost, g.trickle_add }) catch g.label;
    if (g.power_capacity > 0)
        return std.fmt.bufPrint(buf, "{s}: {d:.0} e, {d:.0} mat | powers {s}, {d:.0} dur", .{ g.label, g.energy_cost, g.material_cost, actions[g.target].label, g.power_capacity }) catch g.label;
    if (g.cost_mult < 1.0)
        return std.fmt.bufPrint(buf, "{s}: {d:.0} e, {d:.0} mat | {s} x{d:.2} cost", .{ g.label, g.energy_cost, g.material_cost, actions[g.target].label, g.cost_mult }) catch g.label;
    return std.fmt.bufPrint(buf, "{s}: {d:.0} e, {d:.0} mat | x{d:.1} yield, +{d:.0}%", .{ g.label, g.energy_cost, g.material_cost, g.yield_mult, g.prob_add * 100 }) catch g.label;
}

/// How an action's energy price is paid this frame. `eff_cost` is the base price after any
/// owned effort-saver tools (`cost_mult`); the price is then split so vigor always covers at
/// least 5% (`from_vigor`) and an owned external-energy tool's durability covers the rest
/// (`from_power`, drawn from good `power_idx`). With no power tool, vigor pays it all.
const Payment = struct {
    eff_cost: f32,
    from_vigor: f32,
    from_power: f32,
    power_idx: ?usize,
};

/// Plan how to pay `base_cost` for `action_idx`, given what the actor owns. Folds effort-savers
/// into the price, then routes the bulk through the first owned power tool that still has
/// durability, leaving vigor the 5% floor (plus whatever the tool can't cover).
fn plan_payment(cap: *const comp.Capital, action_idx: usize, base_cost: f32) Payment {
    var eff = base_cost;
    var power_idx: ?usize = null;
    var avail: f32 = 0;
    for (capital, 0..) |g, gi| {
        if (g.kind != .tool or g.target != action_idx or !owns(cap, gi)) continue;
        eff *= g.cost_mult; // effort-savers stack multiplicatively
        if (g.power_capacity > 0 and cap.durability[gi] > 0 and power_idx == null) {
            power_idx = gi;
            avail = cap.durability[gi];
        }
    }
    const vigor_min = 0.05 * eff;
    var from_power: f32 = 0;
    if (power_idx != null) {
        from_power = eff - vigor_min;
        if (from_power > avail) from_power = avail; // tool can't cover more than it has
        if (from_power < 0) from_power = 0;
    }
    return .{ .eff_cost = eff, .from_vigor = eff - from_power, .from_power = from_power, .power_idx = power_idx };
}

const App = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    window: sdl.video.Window,
    renderer: sdl.render.Renderer,
    frame_capper: sdl.extras.FramerateCapper(f32),
    font: sdl.ttf.Font,
    resources: Resources,
    world: ha.world.World,
    frame_arena: std.heap.ArenaAllocator,
    ui: widgets.UiCtx,

    fn init() !App {
        const gpa = std.heap.GeneralPurposeAllocator(.{}){};
        try sdl.init(.{ .video = true, .events = true });
        try sdl.ttf.init();
        const window, const renderer = try sdl.render.Renderer.initWithWindow(
            "Human Action",
            800,
            600,
            .{ .resizable = true },
        );
        var frame_capper = sdl.extras.FramerateCapper(f32){ .mode = .{ .unlimited = {} } };
        renderer.setVSync(.{ .on_each_num_refresh = 1 }) catch {
            frame_capper.mode = .{ .limited = fps };
        };
        return .{
            .gpa = gpa,
            .window = window,
            .renderer = renderer,
            .frame_capper = frame_capper,
            .font = undefined,
            .resources = undefined,
            .world = undefined,
            .frame_arena = undefined,
            .ui = undefined,
        };
    }

    fn setup(self: *App, allocator: std.mem.Allocator) !void {
        self.font = try sdl.ttf.Font.init(font_path, 24);
        self.resources = try Resources.init(&self.font, &self.renderer, self.window);
        self.world = ha.world.World.init();
        spawn_player(&self.world);
        self.resources.log.push(.dim, "You wake alone. Cold. Hungry.");

        self.frame_arena = std.heap.ArenaAllocator.init(allocator);
        self.ui = widgets.UiCtx.init(&self.resources, allocator, self.frame_arena.allocator());
    }

    fn deinit(self: *App) void {
        self.ui.deinit();
        self.frame_arena.deinit();
        self.world.deinit();
        self.resources.deinit();
        self.font.deinit();
        self.renderer.deinit();
        self.window.deinit();
        sdl.ttf.quit();
        sdl.quit(.{ .video = true, .events = true });
        _ = self.gpa.deinit();
    }
};

pub fn main() !void {
    var app = try App.init();
    defer app.deinit();
    try app.setup(app.gpa.allocator());

    var quit = false;

    while (!quit) {
        // Event Stage
        app.resources.input.mouse_down = false; // edge: true only on a press this frame
        while (sdl.events.poll()) |event| {
            switch (event) {
                .quit, .terminating => quit = true,
                .key_down => |key| if (key.key == .escape) {
                    quit = true;
                },
                .mouse_motion => |mm| {
                    app.resources.input.mouse_x = mm.x;
                    app.resources.input.mouse_y = mm.y;
                },
                .mouse_button_down => |mb| {
                    app.resources.input.mouse_x = mb.x;
                    app.resources.input.mouse_y = mb.y;
                    if (mb.button == .left) {
                        app.resources.input.mouse_down = true;
                        app.ui.mark(.clicked, mb.x, mb.y);
                    }
                },
                else => {},
            }
        }

        // Update Stage
        // 1. update game resources
        app.resources.time.dt = app.frame_capper.delay();
        // 2. update game systems
        ecs.run(&app.world, &app.resources, sys.advance_clock); // run clock ticks while alive
        ecs.run(&app.world, &app.resources, sys.update_satiety); // hunger drains
        ecs.run(&app.world, &app.resources, sys.metabolize); // food → satiety (passive eating)
        ecs.run(&app.world, &app.resources, sys.update_food); // larder spoils
        ecs.run(&app.world, &app.resources, sys.update_vigor); // vigor trickles up to the hunger cap
        ecs.run(&app.world, &app.resources, sys.mark_dead); // vigor at 0 → tag Dead
        ecs.run(&app.world, &app.resources, sys.despawn_dead); // reap Dead entities
        // 3. update ui
        app.ui.mark(.hovering, app.resources.input.mouse_x, app.resources.input.mouse_y);
        app.ui.beginFrame();
        _ = app.frame_arena.reset(.retain_capacity); // last frame's node tree dies here
        const frame = try build_ui(&app.ui, &app.world);
        // Lay out + stamp each root tree, in list order. Each is independent — a screen
        // is sized to the window and placed from (0,0); a floating overlay (the tooltip)
        // carries its own layout origin, set in build_ui.
        for (frame.trees) |t| {
            try t.set_global_pos();
            ui.stamp_rects(&app.ui, t); // capture rects into interaction slots for next frame's hit-test
        }

        // Render Stage
        // window
        try app.renderer.setDrawColor(.{ .r = 20, .g = 20, .b = 40, .a = 255 });
        try app.renderer.clear();
        // ui — trees painted in list order, so later ones (overlays) land on top
        for (frame.trees) |t| draw_tree(&app.ui, t);
        // present
        try app.renderer.present();

        app.ui.endFrame();
    }
}

/// Map a log entry's tone to the color its line renders in (host policy, mirroring the
/// widget palette). The log panel recolors each label with this after building it.
fn log_tone_color(t: ha.log.Tone) ui.Color {
    return switch (t) {
        .dim => .{ .r = 110, .g = 120, .b = 130 },
        .normal => .{ .r = 200, .g = 200, .b = 210 },
        .good => .{ .r = 120, .g = 200, .b = 140 },
        .warn => .{ .r = 230, .g = 180, .b = 80 },
        .danger => .{ .r = 210, .g = 90, .b = 70 },
    };
}

/// Walk a UI tree and paint each node by its render aspects. Order matters: fill
/// (backmost) → image → text → outline (topmost), so a hover/affordance ring shows
/// over opaque icon tiles. Called once per root tree, in the render list's order.
fn draw_tree(u: *widgets.UiCtx, root: *widgets.Node) void {
    var it = root.iterate();
    while (it.next()) |node| {
        if (node.render_data.fill) |c| widgets.draw_fill(u, node, c);
        if (node.render_data.img) |s| widgets.draw_texture(u, node, s);
        if (node.render_data.text) |c| widgets.draw_text(u, node, c);
        if (node.render_data.outline) |c| widgets.draw_outline(u, node, c);
    }
}

/// What `build_ui` hands back each frame: a flat list of independent root trees, laid
/// out and drawn in order (later trees paint on top). Generalizes the old fixed
/// `main`/`overlay` pair — the screen, plus any floating overlays (a hover tooltip,
/// later a modal). A `ui_*` builder returns a single tree or a tuple of them, which
/// `collect` flattens into this list. Arena-backed, so it dies with the frame's tree.
const Ui = struct {
    trees: []const *widgets.Node,
};

/// Append `item` to the render list, flattening whatever shape a `ui_*` builder hands
/// back: a single `*Node`, an `?*Node` (skipped when null), or a tuple mixing the two
/// (e.g. a screen plus its optional tooltip). Each leaf is an independent root tree; its
/// position in the list is its draw order.
fn collect(list: *std.ArrayList(*widgets.Node), arena: std.mem.Allocator, item: anytype) !void {
    switch (@typeInfo(@TypeOf(item))) {
        .optional => if (item) |v| try collect(list, arena, v),
        .pointer => try list.append(arena, item), // a single `*Node`
        .@"struct" => |s| inline for (s.fields) |f| try collect(list, arena, @field(item, f.name)),
        else => @compileError("collect: unsupported UI tree shape " ++ @typeName(@TypeOf(item))),
    }
}

/// A fullscreen root: the anchor box a whole screen's content positions against. Every
/// screen (`ui_playgame`, `ui_gameover`) is its own independent tree rooted here, laid
/// out from (0,0) and drawn in the order `build_ui` lists it. Sized to the live window
/// so `.center`/`.center_left`/… anchors resolve against the full display.
fn ui_root(ui_ctx: *widgets.UiCtx, id: []const u8) !*widgets.Node {
    const ww, const wh = try ui_ctx.res.window.getSize();
    const root = try widgets.Node.create(ui_ctx.arena, id);
    _ = root.with_layout(ui.features.Layout.init(.top_left, .horizontal))
        .with_size(ui.features.Size.initFixed(@floatFromInt(ww), @floatFromInt(wh), null));
    return root;
}

/// The game-over screen: death is total — the run is over and everything accumulated is
/// gone. A centered message plus a "Start over" button that reseeds a fresh actor from
/// the bottom. Builds its own fullscreen root (via `ui_root`) and returns it, so its
/// keys are final at build time and its slots match the rects stamped after layout.
fn ui_gameover(ui_ctx: *widgets.UiCtx, world: *ha.world.World) !*widgets.Node {
    const over = try ui_root(ui_ctx, "over");
    const center_div = try widgets.Node.pcreate(ui_ctx.arena, "c_div", over);
    _ = center_div.with_layout(ui.features.Layout.init(.center, .vertical).with_gap(10));
    _ = try widgets.label(ui_ctx, center_div, "dead_text", "You perished, cold and starved.");
    const restart = try widgets.button(ui_ctx, center_div, "restart", "Start over", true);
    if (restart.query(ui_ctx).clicked) {
        spawn_player(world);
        ui_ctx.res.time.elapsed = 0; // fresh run starts on Day 1
        ui_ctx.res.log.clear();
        ui_ctx.res.log.push(.dim, "You wake alone. Cold. Hungry.");
    }
    return over;
}

/// The actor's condition word + a severity color, from how fed and how rested it is
/// (mirrors the design's status pill). No DEAD case here — that's the game-over screen.
const Status = struct { word: []const u8, color: ui.Color };
fn actor_status(vigor: *const comp.Vigor, satiety: *const comp.Satiety) Status {
    const sat_frac = satiety.v / satiety.max;
    const cap = vigor.max * sat_frac; // the hunger ceiling
    if (sat_frac <= 0.12) return .{ .word = "STARVING", .color = .{ .r = 210, .g = 90, .b = 70 } };
    if (cap > 0 and vigor.v < cap * 0.25) return .{ .word = "EXHAUSTED", .color = .{ .r = 230, .g = 180, .b = 80 } };
    if (sat_frac < 0.30) return .{ .word = "HUNGRY", .color = .{ .r = 230, .g = 180, .b = 80 } };
    return .{ .word = "ALIVE", .color = .{ .r = 79, .g = 158, .b = 196 } };
}

/// The live HUD while the actor is alive: a top-left status panel (the actor's stocks
/// and their live rates) plus a centered column of Actions and Capital. Each action is
/// priced in energy paid from vigor (which also burns satiety); each capital good is an
/// incremental build. Reads and mutates the actor's components inline on click. Builds
/// its own fullscreen root and returns the pair `.{ screen, tooltip }` — the tooltip a
/// floating overlay root (or null when nothing is hovered) for the render list's top
/// layer. `actor` is the `MaybeSingle` fetch tuple — `{ *Vigor, *Satiety, *Food,
/// *Materials, *Capital }`.
fn ui_playgame(ui_ctx: *widgets.UiCtx, actor: anytype) !struct { *widgets.Node, ?*widgets.Node } {
    var char_buf: [64]u8 = undefined;
    var overlay: ?*widgets.Node = null; // floating tooltip, built by the goods menu on hover

    const play = try ui_root(ui_ctx, "play");

    const vigor, const satiety, const food, const materials, const cap = actor;
    // Vigor's live ceiling is pulled down by hunger (see `update_vigor`).
    const vigor_cap = vigor.max * (satiety.v / satiety.max);

    // Status panel — the actor's stocks, pinned top-left, each with the live rate read
    // off its component. Vigor is shown against its *hunger ceiling*, not its base max,
    // so a starving actor visibly loses headroom. Materials is the bare stockpile.
    const status_div = try widgets.Node.pcreate(ui_ctx.arena, "status_div", play);
    _ = status_div.with_layout(ui.features.Layout.init(.top_left, .vertical).with_gap(10));
    const day = 1 + @as(u64, @intFromFloat(ui_ctx.res.time.elapsed / secs_per_day));
    _ = try widgets.label(ui_ctx, status_div, "day_text", std.fmt.bufPrint(&char_buf, "Day {d}", .{day}) catch "?");
    const res_panel = try widgets.panel(ui_ctx, status_div, "res_panel", "Resources");
    _ = try widgets.label(ui_ctx, res_panel, "vigor_text", std.fmt.bufPrint(&char_buf, "Vigor: {d:.0}/{d:.0}  (+{d:.1}/s)", .{ vigor.v, vigor_cap, vigor.trickle }) catch "?");
    _ = try widgets.label(ui_ctx, res_panel, "satiety_text", std.fmt.bufPrint(&char_buf, "Satiety: {d:.0}/{d:.0}  (-{d:.1}/s)", .{ satiety.v, satiety.max, satiety.drain }) catch "?");
    _ = try widgets.label(ui_ctx, res_panel, "food_text", std.fmt.bufPrint(&char_buf, "Food: {d:.0}/{d:.0}  (spoils {d:.2}/s)", .{ food.v, food.max, food.spoil }) catch "?");
    _ = try widgets.label(ui_ctx, res_panel, "materials_text", std.fmt.bufPrint(&char_buf, "Materials: {d:.0}", .{materials.v}) catch "?");

    // Event log — newest-first feed of what just happened. Lives on `Resources.log`
    // (survives the per-frame arena); each line is recolored by its tone.
    const log_panel = try widgets.panel(ui_ctx, status_div, "log_panel", "Log");
    const feed = &ui_ctx.res.log;
    const shown = @min(feed.count, 6);
    var li: usize = 0;
    while (li < shown) : (li += 1) {
        const entry = feed.get(li);
        const lkey = try std.fmt.allocPrint(ui_ctx.arena, "log{d}", .{li});
        const lnode = try widgets.label(ui_ctx, log_panel, lkey, entry.text());
        lnode.render_data.text = log_tone_color(entry.tone);
    }

    // Actor condition word, pinned top-right of the screen (colored by severity).
    const status = actor_status(vigor, satiety);
    const status_node = try widgets.label(ui_ctx, play, "status_text", status.word);
    status_node.render_data.text = status.color;
    _ = status_node.with_layout(ui.features.Layout.init(.top_right, null));

    const center_div = try widgets.Node.pcreate(ui_ctx.arena, "c_div", play);
    _ = center_div.with_layout(ui.features.Layout.init(.center, .vertical).with_gap(10));

    // Actions panel — each action is priced in energy (work), paid from vigor; the
    // payment also burns satiety. The effective yield/odds fold in any owned tool
    // that targets this action (a rod boosts Fish), then the yield is scaled by
    // current vigor against its *base* max (`sfac`) — so being tired (or starving,
    // which drains vigor) means below-standard output. The roll decides success.
    const act_panel = try widgets.panel(ui_ctx, center_div, "act_panel", "Actions");
    for (actions, 0..) |act, i| {
        const bkey = try std.fmt.allocPrint(ui_ctx.arena, "act{d}", .{i}); // arena-lived: outlives this frame's tree
        const sfac = vigor.v / vigor.max; // tired → below-standard outcomes

        var eff_yield = act.yield;
        var eff_prob = act.p_success;
        for (capital, 0..) |g, gi| {
            if (g.kind == .tool and g.target == i and owns(cap, gi)) {
                eff_yield *= g.yield_mult;
                eff_prob += g.prob_add;
            }
        }
        if (eff_prob > 1.0) eff_prob = 1.0;

        // Plan the payment: effort-savers cheapen the price, a power tool pays the
        // bulk from its durability, vigor covers the 5% floor (and any shortfall).
        const pay = plan_payment(cap, i, act.energy_cost);

        const unit: u8 = if (act.target == .food) 'f' else 'm';
        const txt = std.fmt.bufPrint(
            &char_buf,
            "{s}  (-{d:.1} vig, +{d:.1}{c}, {d:.0}%)",
            .{ act.label, pay.from_vigor, eff_yield * sfac, unit, eff_prob * 100 },
        ) catch act.label;
        // Affordable only if vigor strictly covers its share — an action never spends
        // the last unit of vigor (vigor 0 is death; you starve, you don't work yourself
        // to death). Drives both the dimmed look and the click guard.
        const affordable = vigor.v > pay.from_vigor;
        const btn = try widgets.button(ui_ctx, act_panel, bkey, txt, affordable);
        if (btn.query(ui_ctx).clicked and affordable) {
            vigor.v -= pay.from_vigor; // muscle pays its share
            satiety.v -= pay.from_vigor * effort_k; // only muscle work makes you hungry
            if (satiety.v < 0) satiety.v = 0;
            if (pay.power_idx) |pi| { // the tool wears by the energy it supplied
                cap.durability[pi] -= pay.from_power;
                if (cap.durability[pi] <= 0) { // worn out — it breaks, rebuild required
                    cap.durability[pi] = 0;
                    cap.owned &= ~bit(pi);
                }
            }
            const produced: f32 = if (ui_ctx.res.random().float(f32) < eff_prob) eff_yield * sfac else 0;
            if (produced > 0) {
                switch (act.target) {
                    .food => {
                        food.v += produced;
                        if (food.v > food.max) food.v = food.max; // larder is capped
                    },
                    .materials => materials.v += produced,
                }
            }
            var lbuf: [96]u8 = undefined;
            const uname = if (act.target == .food) "food" else "materials";
            const lmsg = if (produced > 0)
                std.fmt.bufPrint(&lbuf, "{s}. +{d:.0} {s}", .{ act.label, produced, uname }) catch act.label
            else
                std.fmt.bufPrint(&lbuf, "{s} — came back empty", .{act.label}) catch act.label;
            ui_ctx.res.log.push(if (produced > 0) .good else .warn, lmsg);
        }
    }

    // Capital Goods — a collapsible drawer pinned bottom-left. Its titled panel is the
    // toggle: clicking it opens/closes the goods tray. The tray is built as a *sibling*
    // of the panel (not a child), so clicking a good to build it never also trips the
    // toggle — the hit-test marks every slot whose rect contains the point.
    const capital_goods = try widgets.Node.pcreate(ui_ctx.arena, "capital", play);
    _ = capital_goods.with_layout(ui.features.Layout.init(.bottom_left, .vertical).with_gap(10));
    const cap_panel = try widgets.panel(ui_ctx, capital_goods, "cap_panel", "Capital Goods");
    const cg = cap_panel.query(ui_ctx);
    if (cg.clicked) ui_ctx.setFlag(cap_panel.key, .active, !cg.active);
    // `cg.active` is the pre-toggle value, so this frame's live state is:
    const cap_panel_open = if (cg.clicked) !cg.active else cg.active;
    // Open: build the goods tray under the drawer and bubble up its hover tooltip.
    if (cap_panel_open) overlay = try ui_capital_goods_menu(ui_ctx, capital_goods, actor);

    return .{ play, overlay };
}

/// The capital-goods tray: a horizontal row of build icons (the `capital` catalog),
/// built under `parent` and shown while the Capital Goods drawer is open. An owned good
/// is a static icon; an unowned one an icon_button whose ring brightens on hover and
/// dims when unaffordable. Building is incremental — the first click commits materials,
/// then each click pours spare vigor into the good until it completes. Reads and mutates
/// the actor's stocks inline on click. Returns the hover tooltip as a floating overlay
/// root (or null when nothing is hovered) for the render list's top layer. `actor` is
/// the `MaybeSingle` fetch tuple — `{ *Vigor, *Satiety, *Food, *Materials, *Capital }`.
fn ui_capital_goods_menu(ui_ctx: *widgets.UiCtx, parent: *widgets.Node, actor: anytype) !?*widgets.Node {
    const res = ui_ctx.res;
    var char_buf: [64]u8 = undefined;
    const vigor, const satiety, _, const materials, const cap = actor;

    const cap_row = try widgets.Node.pcreate(ui_ctx.arena, "cap_row", parent);
    _ = cap_row.with_layout(ui.features.Layout.init(.relative, .horizontal).with_gap(8));
    var hovered: ?usize = null; // which good the cursor is over
    var hov_rect: ?ui.Rect = null; // and where it sat last frame, to float the tooltip over it
    for (capital, 0..) |g, gi| {
        const ckey = try std.fmt.allocPrint(ui_ctx.arena, "cap{d}", .{gi});
        const sprite = widgets.icon_sprite(res, g.icon_col, g.icon_row);
        if (owns(cap, gi)) {
            // Owned: a static icon, no ring, not clickable — but still queried so
            // hovering it shows its tooltip.
            const node = try widgets.Node.pcreate(ui_ctx.arena, ckey, cap_row);
            try widgets.data_sprite(ui_ctx, node, sprite, icon_px);
            _ = node.with_layout(ui.features.Layout.init(.relative, null));
            if (node.query(ui_ctx).hovering) {
                hovered = gi;
                hov_rect = node.rect(ui_ctx);
            }
            continue;
        }
        // Building pours spare vigor into the good across clicks/sessions. Materials
        // are committed up front (first click); energy is the labour over time. A
        // grand good (saw: 14 e) can't fit one 10-vigor body, so it needs several
        // sessions — vigor refills, you click again, progress climbs until it's done.
        const started = cap.progress[gi] > 0;
        const can_invest = vigor.v > build_vigor_floor;
        // Affordable = there's vigor to invest, and (to *start*) materials in hand.
        const affordable = can_invest and (started or materials.v >= g.material_cost);
        const buy = try widgets.icon_button(ui_ctx, cap_row, ckey, sprite, icon_px, affordable);
        if (buy.query(ui_ctx).hovering) {
            hovered = gi;
            hov_rect = buy.rect(ui_ctx);
        }
        if (buy.query(ui_ctx).clicked and affordable) {
            var lbuf: [96]u8 = undefined;
            if (!started) { // commit materials to begin
                materials.v -= g.material_cost;
                ui_ctx.res.log.push(.normal, std.fmt.bufPrint(&lbuf, "Committed {d:.0} mat to {s}.", .{ g.material_cost, g.label }) catch g.label);
            }
            const need = g.energy_cost - cap.progress[gi];
            const chunk = @min(need, vigor.v - build_vigor_floor); // spare vigor this session
            vigor.v -= chunk; // muscle invested as labour
            satiety.v -= chunk * effort_k; // building is hungry work too
            if (satiety.v < 0) satiety.v = 0;
            cap.progress[gi] += chunk;
            if (cap.progress[gi] >= g.energy_cost) { // the build completes
                cap.progress[gi] = 0;
                cap.owned |= bit(gi);
                if (g.power_capacity > 0) cap.durability[gi] = g.power_capacity; // fuel up a fresh power tool
                // Comfort effects bake into the components (so the readouts track them);
                // tool effects are folded in at action resolution (see `ui_playgame`).
                if (g.kind == .comfort) vigor.trickle += g.trickle_add;
                ui_ctx.res.log.push(.good, std.fmt.bufPrint(&lbuf, "Built {s}!", .{g.label}) catch g.label);
            }
        }
    }

    // Hover tooltip — a floating overlay tree showing the hovered good's costs/effects,
    // pinned above its icon. Built only when a good is hovered and its last-frame rect
    // is known (the tray is static, so last frame's rect is right). Sized by a throwaway
    // layout pass, then given an origin centred over the icon.
    if (hovered) |hi| {
        if (hov_rect) |r| {
            const tip = capital_tip(&char_buf, capital[hi], hi, cap);
            const box = try widgets.tooltip(ui_ctx, "tip", tip);
            try box.set_global_pos(); // resolve its size (origin still 0,0)
            const ox = r.x + (r.w - box.size.width) / 2; // centred over the icon
            const oy = r.y - box.size.height - tip_gap; // floating just above it
            box.layout = box.layout.with_origin(ox, oy);
            return box;
        }
    }
    return null;
}

fn build_ui(ui_ctx: *widgets.UiCtx, world: *ha.world.World) !Ui {
    // queries
    // MaybeSingle: the actor is despawned on death, so it may be absent. All of its stocks
    // co-spawn on one entity, so one query fetches them together.
    const q_actor = ecs.MaybeSingle(.{ comp.Vigor, comp.Satiety, comp.Food, comp.Materials, comp.Capital, ecs.With(tag.Player) }){ .world = world };
    const actor = q_actor.get();

    // Render list — the frame's root trees, drawn in order (later ones on top). Arena-
    // backed; dies with this frame's node tree. `collect` flattens each builder's return.
    var trees: std.ArrayList(*widgets.Node) = .empty;
    // Content, only while the menu is closed: the play HUD if the actor lives, else the
    // game-over screen. Each builder returns its own tree(s) — `ui_playgame` a
    // `.{ screen, tooltip }` pair, `ui_gameover` a single screen — which `collect` adds.
    if (actor) |a| {
        try collect(&trees, ui_ctx.arena, try ui_playgame(ui_ctx, a));
    } else {
        try collect(&trees, ui_ctx.arena, try ui_gameover(ui_ctx, world));
    }

    return .{ .trees = trees.items };
}
