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
        // Lay out + stamp each root. The overlay is its own tree, positioned via its
        // layout origin (set in build_ui) rather than the main tree's flow.
        try frame.main.set_global_pos();
        ui.stamp_rects(&app.ui, frame.main); // capture rects into interaction slots for next frame's hit-test
        if (frame.overlay) |ov| {
            try ov.set_global_pos();
            ui.stamp_rects(&app.ui, ov);
        }

        // Render Stage
        // window
        try app.renderer.setDrawColor(.{ .r = 20, .g = 20, .b = 40, .a = 255 });
        try app.renderer.clear();
        // ui — main tree first, then the overlay on top
        draw_tree(&app.ui, frame.main);
        if (frame.overlay) |ov| draw_tree(&app.ui, ov);
        // present
        try app.renderer.present();

        app.ui.endFrame();
    }
}

/// Walk a UI tree and paint each node by its render aspects. Order matters: fill
/// (backmost) → image → text → outline (topmost), so a hover/affordance ring shows
/// over opaque icon tiles. Called per root — the main tree, then any overlay.
fn draw_tree(u: *widgets.UiCtx, root: *widgets.Node) void {
    var it = root.iterate();
    while (it.next()) |node| {
        if (node.render_data.fill) |c| widgets.draw_fill(u, node, c);
        if (node.render_data.img) |s| widgets.draw_texture(u, node, s);
        if (node.render_data.text) |c| widgets.draw_text(u, node, c);
        if (node.render_data.outline) |c| widgets.draw_outline(u, node, c);
    }
}

/// What `build_ui` hands back each frame: the main tree, plus an optional floating
/// overlay tree (the hover tooltip). The render loop lays out and draws each in order —
/// the overlay last, so it sits on top. Two layers for now; grow to a list if needed.
const Ui = struct {
    main: *widgets.Node,
    overlay: ?*widgets.Node = null,
};

fn build_ui(ui_ctx: *widgets.UiCtx, world: *ha.world.World) !Ui {
    // "globals"
    const res = ui_ctx.res;
    const ww, const wh = try res.window.getSize();
    var char_buf: [64]u8 = undefined;
    var overlay: ?*widgets.Node = null; // floating tooltip, built on hover below

    // queries
    // MaybeSingle: the actor is despawned on death, so it may be absent. All of its stocks
    // co-spawn on one entity, so one query fetches them together.
    const q_actor = ecs.MaybeSingle(.{ comp.Vigor, comp.Satiety, comp.Food, comp.Materials, comp.Capital, ecs.With(tag.Player) }){ .world = world };
    const actor = q_actor.get();

    // node graph
    const root = try widgets.Node.create(ui_ctx.arena, "root");
    _ = root.with_layout(ui.features.Layout.init(.top_left, .horizontal))
        .with_size(ui.features.Size.initFixed(@floatFromInt(ww), @floatFromInt(wh), null));
    // Menu mock, pinned center-left — will open a menu (no-op for now). Borrows the
    // fireplace cell from the icon sheet until it gets its own glyph.
    const menu = try widgets.icon_button(ui_ctx, root, "menu", widgets.icon_sprite(res, 1, 1), icon_px, true);
    _ = menu.with_layout(ui.features.Layout.init(.center_left, null));
    const m = menu.query(ui_ctx);
    if (m.clicked) ui_ctx.setFlag(menu.key, .active, !m.active);
    // `m.active` is the pre-toggle value, so this frame's live state is:
    const menu_open = if (m.clicked) !m.active else m.active;
    if (menu_open) {
        _ = try widgets.label(ui_ctx, root, "my_menu", "this is a menu.");
    } else {
        const center_div = try widgets.Node.pcreate(ui_ctx.arena, "c_div", root);
        _ = center_div.with_layout(ui.features.Layout.init(.center, .vertical).with_gap(10));
        {
            if (actor) |a| {
                const vigor, const satiety, const food, const materials, const cap = a;
                // Vigor's live ceiling is pulled down by hunger (see `update_vigor`).
                const vigor_cap = vigor.max * (satiety.v / satiety.max);

                // Resources panel — the actor's stocks, each with the live rate read off its
                // component. Vigor is shown against its *hunger ceiling*, not its base max, so
                // a starving actor visibly loses headroom. Materials is the bare stockpile.
                const res_panel = try widgets.panel(ui_ctx, center_div, "res_panel", "Resources");
                _ = try widgets.label(ui_ctx, res_panel, "vigor_text", std.fmt.bufPrint(&char_buf, "Vigor: {d:.0}/{d:.0}  (+{d:.1}/s)", .{ vigor.v, vigor_cap, vigor.trickle }) catch "?");
                _ = try widgets.label(ui_ctx, res_panel, "satiety_text", std.fmt.bufPrint(&char_buf, "Satiety: {d:.0}/{d:.0}  (-{d:.1}/s)", .{ satiety.v, satiety.max, satiety.drain }) catch "?");
                _ = try widgets.label(ui_ctx, res_panel, "food_text", std.fmt.bufPrint(&char_buf, "Food: {d:.0}/{d:.0}  (spoils {d:.2}/s)", .{ food.v, food.max, food.spoil }) catch "?");
                _ = try widgets.label(ui_ctx, res_panel, "materials_text", std.fmt.bufPrint(&char_buf, "Materials: {d:.0}", .{materials.v}) catch "?");

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
                        if (ui_ctx.res.random().float(f32) < eff_prob) {
                            const produced = eff_yield * sfac;
                            switch (act.target) {
                                .food => {
                                    food.v += produced;
                                    if (food.v > food.max) food.v = food.max; // larder is capped
                                },
                                .materials => materials.v += produced,
                            }
                        }
                    }
                }

                // Capital panel — spend work (vigor) + materials now on a permanent edge later.
                // One-time unlocks, shown as a horizontal tray of icons (icons.png sheet). An
                // owned good is a static icon; an unowned one is an icon_button — its ring
                // brightens on hover and dims when unaffordable (the click is also guarded).
                // The buttons are icon-only; hovering one fills the detail line below the tray
                // with its costs/effects (queried off last frame's stamped rects).
                const cap_panel = try widgets.panel(ui_ctx, center_div, "cap_panel", "Capital");
                const cap_row = try widgets.Node.pcreate(ui_ctx.arena, "cap_row", cap_panel);
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
                        if (!started) materials.v -= g.material_cost; // commit materials to begin
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
                            // tool effects are folded in at action resolution above.
                            if (g.kind == .comfort) vigor.trickle += g.trickle_add;
                        }
                    }
                }
                // Hover tooltip — a floating overlay tree showing the hovered good's costs/
                // effects, pinned above its icon. Built only when a good is hovered and its
                // last-frame rect is known (the tray is static, so last frame's rect is right).
                // Sized by a throwaway layout pass, then given an origin centred over the icon.
                if (hovered) |hi| {
                    if (hov_rect) |r| {
                        const tip = capital_tip(&char_buf, capital[hi], hi, cap);
                        const box = try widgets.tooltip(ui_ctx, "tip", tip);
                        try box.set_global_pos(); // resolve its size (origin still 0,0)
                        const ox = r.x + (r.w - box.size.width) / 2; // centred over the icon
                        const oy = r.y - box.size.height - tip_gap; // floating just above it
                        box.layout = box.layout.with_origin(ox, oy);
                        overlay = box;
                    }
                }
            } else {
                // Death is total: the run is over and everything accumulated is gone.
                _ = try widgets.label(ui_ctx, center_div, "dead_text", "You perished, cold and starved.");
                const restart = try widgets.button(ui_ctx, center_div, "restart", "Start over", true);
                if (restart.query(ui_ctx).clicked) spawn_player(world);
            }
        }
    }
    // const bottom_div = try widgets.Node.pcreate(ui_ctx.arena, "b_div", root);
    // _ = bottom_div.with_layout(ui.features.Layout.init(.bottom_center, .vertical).with_gap(4));
    // {
    //     _ = try widgets.label(ui_ctx, bottom_div, "player_state", "You are hungry.");
    //     _ = try widgets.label(ui_ctx, bottom_div, "city_state", "You are alone.");
    // }
    return .{ .main = root, .overlay = overlay };
}
