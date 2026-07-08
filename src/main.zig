const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const tag = ha.tag;
const ui = ha.ui;
const Resources = ha.res.Resources;
const widgets = ha.ui_client;
const sdl = ha.sdl;
const sys = ha.systems;
const ecs = ha.ecs;
const actions = ha.actions;
const pages = @import("./ui_client/pages.zig");

// CONFIGS
const fps = 60;
// TODO: we'll need to implement different font sizes
const font_path = "assets/fonts/Kenney Mini Square Mono.ttf";
/// Real seconds per in-game day — paces the `Day N` readout. Tunable; the day is flavor
/// today (population, not day-count, is the progression spine). `pub`: read by
/// `pages.ui_playgame`.
/// TODO: implement different game speeds
pub const secs_per_day: f32 = 20;
/// Gap between a hovered icon and the tooltip floating above it. `pub`: read by
/// `pages.ui_capital_goods_menu`.
pub const tip_gap = 6.0;
// END CONFIGS

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
        // Every existing draw uses alpha=255 (opaque), so blending changes nothing for
        // them — this just lets the scanline overlay (`draw_scanlines`) paint at partial
        // alpha instead of a flat opaque stripe.
        try renderer.setDrawBlendMode(.blend);
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
        _ = spawn_player(&self.world);
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
        app.resources.input.wheel_y = 0; // edge: nonzero only on a wheel tick this frame
        while (sdl.events.poll()) |event| {
            switch (event) {
                .quit, .terminating => quit = true,
                .key_down => |key| if (key.key) |kc| {
                    if (kc == .escape) {
                        if (app.resources.focused_text != null) {
                            // Typing: Escape unfocuses the field rather than quitting.
                            app.resources.focused_text = null;
                            sdl.keyboard.stopTextInput(app.window) catch {};
                        } else if (pages.browse_open(&app.ui) != null) {
                            pages.close_browse(&app.ui); // browsing: Escape backs out of the catalog
                        } else {
                            quit = true;
                        }
                    } else if (kc == .backspace) {
                        if (app.resources.focused_text) |fk| {
                            const idx = app.ui.cache(fk, widgets.UiState.TextInputState);
                            const st = app.ui.pool(widgets.UiState.TextInputState).get(idx);
                            var n = st.len;
                            if (n > 0) {
                                n -= 1;
                                while (n > 0 and (st.buf[n] & 0xC0) == 0x80) n -= 1; // skip UTF-8 continuation bytes
                                st.len = n;
                            }
                        }
                    }
                },
                .text_input => |ti| if (app.resources.focused_text) |fk| {
                    const idx = app.ui.cache(fk, widgets.UiState.TextInputState);
                    const st = app.ui.pool(widgets.UiState.TextInputState).get(idx);
                    if (st.len + ti.text.len <= st.buf.len) {
                        @memcpy(st.buf[st.len..][0..ti.text.len], ti.text);
                        st.len += ti.text.len;
                    }
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
                .mouse_wheel => |mw| {
                    app.resources.input.wheel_y = mw.scroll_y;
                },
                else => {},
            }
        }

        // Update Stage
        // 1. update game resources
        app.resources.time.dt = app.frame_capper.delay();
        // 2. update game systems
        ecs.run(&app.world, &app.resources, sys.advance_clock); // run clock ticks while alive
        ecs.run(&app.world, &app.resources, sys.eat_food); // food → satiety (passive eating)
        ecs.run(&app.world, &app.resources, sys.update_food); // larder spoils
        ecs.run(&app.world, &app.resources, sys.update_vigor); // vigor trickles up to the hunger cap
        ecs.run(&app.world, &app.resources, sys.update_population); // population grows on surplus, shrinks on starvation
        ecs.run(&app.world, &app.resources, sys.mark_dead); // vigor at 0 → tag Dead
        ecs.run(&app.world, &app.resources, sys.despawn_dead); // reap Dead entities
        // 3. update ui
        app.ui.mark(.hovering, app.resources.input.mouse_x, app.resources.input.mouse_y);
        app.ui.beginFrame();
        _ = app.frame_arena.reset(.retain_capacity); // last frame's node tree dies here
        const frame = try pages.build_ui(&app.ui, &app.world);
        // Lay out + stamp each root tree, in list order. Each is independent — a screen
        // is sized to the window and placed from (0,0); a floating overlay (the tooltip)
        // carries its own layout origin, set in build_ui.
        for (frame.trees) |t| {
            try t.set_global_pos();
            ui.stamp_rects(&app.ui, t); // capture rects into interaction slots for next frame's hit-test
        }

        // Render Stage
        // window — cleared to the theme's own background, so it shifts cold/warm too
        const bg = app.resources.theme.bg;
        try app.renderer.setDrawColor(.{ .r = bg.r, .g = bg.g, .b = bg.b, .a = 255 });
        try app.renderer.clear();
        // ui — trees painted in list order, so later ones (overlays) land on top
        for (frame.trees) |t| widgets.draw_tree(&app.ui, t);
        // scanlines — a CRT-style overlay on top of everything (terminal identity, M5)
        {
            const ww, const wh = try app.resources.window.getSize();
            widgets.draw_scanlines(&app.resources, ww, wh);
        }
        // present
        try app.renderer.present();

        app.ui.endFrame();
    }
}

fn spawn_agent(world: *ha.world.World) u32 {
    return world.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 }, // rested; passive regen up to the hunger cap
        comp.StockFood{ .v = 4, .spoil = 0.05 }, // a thin, perishable larder
        comp.StockMaterials{ .v = 0 }, // nothing stockpiled yet
        tag.Player,
    } ++ actions.actions_bundle);
}

pub fn spawn_player(world: *ha.world.World) ha.world.Entity {
    const e = spawn_agent(world);
    world.add(e, tag.Player);
    return e;
}

/// TODO: Spawn capital and associates with the appropriate owner (player and, later, many agents)
fn spawn_capital(world: *ha.world.World, owner: entity_id) void {}

/// Format good `gi`'s hover detail into `buf`. Owned: "owned" (or remaining durability for a
/// power tool); unowned: its build cost (energy work + materials) and salient effect — powered
/// (pays an action from durability), effort-saver (×cost on an action), output boost (yield/
/// odds), or comfort (vigor trickle). Falls back to the bare label if the buffer is too small.
pub fn capital_tip(buf: []u8, g: Good, gi: usize, cap: *const comp.Capital) []const u8 {
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
    return std.fmt.bufPrint(buf, "{s}: {d:.0} e, {d:.0} mat | x{d:.1} yield", .{ g.label, g.energy_cost, g.material_cost, g.yield_mult }) catch g.label;
}

/// How an action's energy price is paid this frame. `eff_cost` is the base price after any
/// owned effort-saver tools (`cost_mult`); the price is then split so vigor always covers at
/// least 5% (`from_vigor`) and an owned external-energy tool's durability covers the rest
/// (`from_power`, drawn from good `power_idx`). With no power tool, vigor pays it all.
pub const Payment = struct {
    eff_cost: f32,
    from_vigor: f32,
    from_power: f32,
    power_idx: ?usize,
};

/// Plan how to pay `base_cost` for `action_idx`, given what the actor owns. Folds effort-savers
/// into the price, then routes the bulk through the first owned power tool that still has
/// durability, leaving vigor the 5% floor (plus whatever the tool can't cover).
pub fn plan_payment(cap: *const comp.Capital, action_idx: usize, base_cost: f32) Payment {
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

/// Action `i`'s current effective quality multiplier: tool yield bonuses (owned tools
/// targeting it) times how tired the actor is (`vigor/max`) — scales both the label's
/// shown yield band and the actual draw. Shared by the UI, `resolve_action`, and
/// `ai_decide`'s ranking, so all three agree on what an action is "worth" right now.
pub fn action_quality(vigor: *const comp.Vigor, cap: *const comp.Capital, i: usize) f32 {
    var eff_mult: f32 = 1.0;
    for (capital, 0..) |g, gi| {
        if (g.kind == .tool and g.target == i and owns(cap, gi)) eff_mult *= g.yield_mult;
    }
    return eff_mult * (vigor.v / vigor.max);
}

/// Whether the actor can currently afford action `i` — vigor must strictly cover its
/// (tool-adjusted) share of the price; an action never spends the last unit of vigor
/// (vigor 0 is death — you starve, you don't work yourself to death). Shared by the UI
/// (dims an unaffordable button) and any decider (which options are even viable).
pub fn affordable(vigor: *const comp.Vigor, cap: *const comp.Capital, i: usize) bool {
    const pay = plan_payment(cap, i, actions[i].energy_cost);
    return vigor.v > pay.from_vigor;
}

/// Apply decision `i` (an index into `actions`) to the actor: spend vigor/satiety (and
/// any power-tool durability), draw the yield, deposit it, and log the result. The
/// shared "act" step of the `decide → act` split (roadmap M7) — a decider only ever
/// *chooses* `i`; both the player (via a click, in `ui_playgame`) and `ai_decide` (below)
/// funnel through this to actually act on it. Silently no-ops if `i` isn't affordable —
/// defends against a decider that "cheats" the vigor-0-is-death gate.
pub fn resolve_action(
    res: *Resources,
    i: usize,
    vigor: *comp.Vigor,
    satiety: *comp.Satiety,
    food: *comp.StockFood,
    materials: *comp.StockMaterials,
    cap: *comp.Capital,
) void {
    if (!affordable(vigor, cap, i)) return;
    const act = actions[i];
    const k = action_quality(vigor, cap, i);
    const pay = plan_payment(cap, i, act.energy_cost);

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
    // Draw the yield from the action's distribution, scaled by k, rounded to a whole.
    const produced = @round(ha.dist.sample(act.dist, res.random()) * k);
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
    res.log.push(if (produced > 0) .good else .warn, lmsg);
}

pub fn compute_warmth() f32 {
    return 0.0;
}

/// Whether the actor can currently invest in building capital good `gi` — there must be
/// vigor to spare above the build floor, and (to *start*) enough materials in hand.
/// Shared by both presentations of the capital catalog (the icon tray, the M4 browser).
pub fn afford_build(gi: usize, vigor: *const comp.Vigor, materials: *const comp.StockMaterials, cap: *const comp.Capital) bool {
    const g = capital[gi];
    const started = cap.progress[gi] > 0;
    const can_invest = vigor.v > build_vigor_floor;
    return can_invest and (started or materials.v >= g.material_cost);
}

/// Apply one investment click toward capital good `gi`: commit materials on the first
/// click, then pour spare vigor into `progress` until it reaches the good's energy cost
/// and it completes. The shared "act" step for building (mirrors `resolve_action`'s role
/// for the labor catalog) — both the always-visible icon tray and the M4 catalog browser
/// funnel through this rather than duplicating the incremental-build logic. Silently
/// no-ops if `gi` isn't affordable, same defensive stance as `resolve_action`.
pub fn build_capital(
    res: *Resources,
    gi: usize,
    vigor: *comp.Vigor,
    satiety: *comp.Satiety,
    materials: *comp.StockMaterials,
    cap: *comp.Capital,
) void {
    if (!afford_build(gi, vigor, materials, cap)) return;
    const g = capital[gi];
    const started = cap.progress[gi] > 0;

    var lbuf: [96]u8 = undefined;
    if (!started) { // commit materials to begin
        materials.v -= g.material_cost;
        res.log.push(.normal, std.fmt.bufPrint(&lbuf, "Committed {d:.0} mat to {s}.", .{ g.material_cost, g.label }) catch g.label);
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
        res.log.push(.good, std.fmt.bufPrint(&lbuf, "Built {s}!", .{g.label}) catch g.label);
    }
}

/// `Population`'s carrying-capacity ceiling (roadmap M6): 1 (yourself) plus each owned
/// comfort good's `capacity_add` — which capital goods count as "shelter" is catalog
/// knowledge, so this lives here (not `systems.update_population`, which just integrates
/// `count` toward whatever capacity it finds already set — same split as `Vigor.trickle`).
pub fn compute_capacity(cap: *const comp.Capital) f32 {
    var c: f32 = 1.0;
    for (capital, 0..) |g, gi| {
        if (g.kind == .comfort and owns(cap, gi)) c += g.capacity_add;
    }
    return c;
}
