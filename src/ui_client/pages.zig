//! The game's screen builders (`ui_*`) and `build_ui`, the per-frame dispatcher that picks
//! among them — moved out of `main.zig`, which now only owns `App`, the event loop, and
//! the sim tick. Unlike the rest of `ui_client/` (ctx_binding/draw/data/widgets/tree),
//! this file is game *content*, not reusable host UI plumbing — it lives under
//! `ui_client/` for human organization (it's still "UI, not sim"), not because it's part
//! of the `ha` library surface; it's reached by `main.zig` via a plain relative import,
//! the same module as `main.zig` itself, not through `ha`'s barrel.
//!
//! These screens still call into the pre-redesign actions/capital game logic
//! (`resolve_action`, `build_capital`, `plan_payment`, …) that CLAUDE.md's status note
//! flags as parked mid-refactor — that logic stays in `main.zig` untouched, reached here
//! via `app.*` (this file imports `main.zig` back, the mirror image of `main.zig`
//! importing this file). Every pre-existing broken reference inside the moved code
//! (`capital`, `actions` used as an array, `Good`, `effort_k`, `icon_px`, …) moved with it
//! unchanged — this file doesn't fix or touch any of that.

const std = @import("std");
const ha = @import("ha");
const app = @import("../main.zig");

const comp = ha.comp;
const tag = ha.tag;
const ui = ha.ui;
const Resources = ha.res.Resources;
const widgets = ha.ui_client;
const sdl = ha.sdl;
const ecs = ha.ecs;
const actions = ha.actions;

/// Map a log entry's tone to the current theme's matching color role (host policy,
/// mirroring the widget palette). The log panel recolors each label with this after
/// building it.
fn log_tone_color(t: ha.theme.Theme, tone: ha.log.Tone) ui.Color {
    return switch (tone) {
        .dim => t.dim,
        .normal => t.fg,
        .good => t.acc,
        .warn => t.warn,
        .danger => t.danger,
    };
}

/// The game-over screen: death is total — the run is over and everything accumulated is
/// gone. A centered message plus a "Start over" button that, since that loss is
/// irreversible, opens a confirm modal rather than reseeding immediately — "Yes" (or
/// Enter — not yet wired) reseeds a fresh actor from the bottom, "Cancel" or a click
/// outside the dialog backs out. Builds its own fullscreen root (via `ui_root`) plus the
/// modal's overlay root (or null when not confirming) and returns the pair, so its keys
/// are final at build time and its slots match the rects stamped after layout.
///
/// The open/closed flag rides on `restart`'s own `active` interaction flag (mirrors the
/// Capital Goods drawer toggle in `ui_playgame`) rather than a separate state slot —
/// `restart` is read every frame regardless, so its slot (and the latch) never lapses.
/// `restart` stays built (and queried) while the modal is open, per `widgets.modal`'s
/// input-capture note — safe here only because its own click handler (open the modal) is
/// idempotent; a future modal guarding a non-idempotent action would need an explicit
/// `if (!confirm_open)` guard instead.
fn ui_gameover(ui_ctx: *widgets.UiCtx, world: *ha.world.World) !struct { *widgets.Node, ?*widgets.Node } {
    const over = try widgets.ui_root(ui_ctx, "over");
    const center_div = try widgets.Node.pcreate(ui_ctx.arena, "c_div", over);
    _ = center_div.with_layout(ui.features.Layout.init(.center, .vertical).with_gap(10));
    try ui_figure(ui_ctx, center_div, fig_dead, ui_ctx.res.theme.danger);
    _ = try widgets.label(ui_ctx, center_div, "dead_text", "You perished, cold and starved.");
    const restart = try widgets.button(ui_ctx, center_div, "restart", "Start over", true);

    const rst = restart.query(ui_ctx);
    if (rst.clicked and !rst.active) ui_ctx.setFlag(restart.key, .active, true);
    const confirm_open = rst.active or rst.clicked; // pre-toggle `active`, or opening this frame

    var overlay: ?*widgets.Node = null;
    if (confirm_open) {
        const m = try widgets.modal(ui_ctx, "restart_confirm", "Start a new life? This run will be lost.");
        const yes = try widgets.button(ui_ctx, m.box, "yes", "Yes, start over", true);
        const cancel = try widgets.button(ui_ctx, m.box, "cancel", "Cancel", true);

        var close = false;
        if (yes.query(ui_ctx).clicked) {
            app.spawn_player(world);
            ui_ctx.res.time.elapsed = 0; // fresh run starts on Day 1
            ui_ctx.res.log.clear();
            ui_ctx.res.log.push(.dim, "You wake alone. Cold. Hungry.");
            close = true;
        } else if (cancel.query(ui_ctx).clicked) {
            close = true;
        } else if (ui_ctx.res.input.mouse_down) {
            // Click-outside-to-dismiss: null (no rect yet) on the frame the modal first
            // opens — that's also this same click, so treating "unknown" as "don't
            // close" is exactly right, not just a safe default.
            if (m.box.rect(ui_ctx)) |r| {
                if (!r.contains(ui_ctx.res.input.mouse_x, ui_ctx.res.input.mouse_y)) close = true;
            }
        }
        if (close) ui_ctx.setFlag(restart.key, .active, false);
        overlay = m.root;
    }

    return .{ over, overlay };
}

/// The actor's condition word + a severity color, from how fed and how rested it is
/// (mirrors the design's status pill). No DEAD case here — that's the game-over screen.
const Status = struct { word: []const u8, color: ui.Color };
fn actor_status(t: ha.theme.Theme, vigor: *const comp.Vigor, satiety: *const comp.Satiety) Status {
    const sat_frac = satiety.v / satiety.max;
    const cap = vigor.max * sat_frac; // the hunger ceiling
    if (sat_frac <= 0.12) return .{ .word = "STARVING", .color = t.danger };
    if (cap > 0 and vigor.v < cap * 0.25) return .{ .word = "EXHAUSTED", .color = t.warn };
    if (sat_frac < 0.30) return .{ .word = "HUNGRY", .color = t.warn };
    return .{ .word = "ALIVE", .color = t.acc };
}

/// A tiny 3-line ASCII stand-in for the actor's body (the design's "vitals figure").
const Figure = struct { l1: []const u8, l2: []const u8, l3: []const u8 };
const fig_robust = Figure{ .l1 = "  \\o/", .l2 = "   |", .l3 = "  / \\" };
const fig_ok = Figure{ .l1 = "   O", .l2 = "  /|\\", .l3 = "  / \\" };
const fig_weary = Figure{ .l1 = "   o", .l2 = "  /|", .l3 = "  /" };
const fig_dead = Figure{ .l1 = "   x", .l2 = "  -|-", .l3 = "  / \\" };

/// Which figure/color the actor's vitals show — picked the same way `actor_status` picks
/// a condition word but independently: the figure reacts to hunger/exhaustion *and*
/// warmth, not just the status pill's severity. An enum (not the `Figure` value itself)
/// so the color mapping below doesn't need to reverse-lookup which glyphs it got.
const FigureKind = enum { weary, ok, robust };

/// `warmth` is `compute_warmth`'s 0..1 mood; `sat_frac`/`vigor_frac_of_ceiling` gate the
/// weary case ahead of it, mirroring the design: a starving or exhausted actor looks
/// weary regardless of how "warm" the rest of the picture is.
fn figure_kind(warmth: f32, sat_frac: f32, vigor_frac_of_ceiling: f32) FigureKind {
    if (sat_frac < 0.15 or vigor_frac_of_ceiling < 0.2) return .weary;
    if (warmth > 0.6) return .robust;
    return .ok;
}

fn figure_glyphs(k: FigureKind) Figure {
    return switch (k) {
        .weary => fig_weary,
        .ok => fig_ok,
        .robust => fig_robust,
    };
}

fn figure_color(t: ha.theme.Theme, k: FigureKind) ui.Color {
    return switch (k) {
        .weary => t.warn,
        .ok, .robust => t.acc,
    };
}

/// Build the figure's 3 lines as stacked labels (not one multi-line string — text nodes
/// here are single-line) under `parent`, all in `color`.
fn ui_figure(ui_ctx: *widgets.UiCtx, parent: *widgets.Node, fig: Figure, color: ui.Color) !void {
    const col = try widgets.Node.pcreate(ui_ctx.arena, "fig", parent);
    _ = col.with_layout(ui.features.Layout.init(.relative, .vertical));
    const l1 = try widgets.label(ui_ctx, col, "l1", fig.l1);
    l1.render_data.text = color;
    const l2 = try widgets.label(ui_ctx, col, "l2", fig.l2);
    l2.render_data.text = color;
    const l3 = try widgets.label(ui_ctx, col, "l3", fig.l3);
    l3.render_data.text = color;
}

/// A pulsing color between `t.dim` and `t.acc` (period ~1.1s, matching the design's CSS
/// `ha-pulse` keyframes) — the "heartbeat". Driven by `elapsed` (the run clock), so it
/// freezes the instant the actor dies (the clock stops with them) rather than needing a
/// separate wall-clock timer.
fn heartbeat_color(t: ha.theme.Theme, elapsed: f32) ui.Color {
    const phase = 0.5 + 0.5 * std.math.sin(elapsed * (2.0 * std.math.pi / 1.1));
    return ui.Color.lerp(t.dim, t.acc, phase);
}

/// Format `n` compactly for the HUD — `1.2M`, `12k`, `3.4k`, or a bare integer — so the
/// accumulator's big counters stay readable. Writes into `buf`, returns the slice.
fn fmt_num(buf: []u8, n: f32) []const u8 {
    const r = @round(n);
    if (r >= 1_000_000) return std.fmt.bufPrint(buf, "{d:.1}M", .{r / 1_000_000}) catch "?";
    if (r >= 10_000) return std.fmt.bufPrint(buf, "{d:.0}k", .{r / 1000}) catch "?";
    if (r >= 1_000) return std.fmt.bufPrint(buf, "{d:.1}k", .{r / 1000}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.0}", .{r}) catch "?";
}

/// The live HUD while the actor is alive: a top-left status panel (the actor's stocks
/// and their live rates) plus a centered column of Actions and Capital. Each action is
/// priced in energy paid from vigor (which also burns satiety); each capital good is an
/// incremental build. Reads and mutates the actor's components inline on click. Builds
/// its own fullscreen root and returns the pair `.{ screen, tooltip }` — the tooltip a
/// floating overlay root (or null when nothing is hovered) for the render list's top
/// layer. `actor` is the `MaybeSingle` fetch tuple — `{ *Vigor, *Satiety, *Food,
/// *Materials, *Capital, *Population }`.
fn ui_playgame(ui_ctx: *widgets.UiCtx, actor: anytype) !struct { *widgets.Node, ?*widgets.Node } {
    var char_buf: [64]u8 = undefined;
    var overlay: ?*widgets.Node = null; // floating tooltip, built by the goods menu on hover

    const play = try widgets.ui_root(ui_ctx, "play");

    const vigor, const satiety, const food, const materials, const cap, const pop = actor;
    // Vigor's live ceiling is pulled down by hunger (see `update_vigor`).
    const vigor_cap = vigor.max * (satiety.v / satiety.max);

    // Population: capacity is catalog-dependent (which capital goods are "shelter"), so
    // it's recomputed here each frame; `systems.update_population` just integrates
    // `count` toward it. Crossing 2 is Act I's win condition (roadmap M6) — the actual
    // second agent is M8's job, so for now this just surfaces the moment in the log.
    pop.capacity = app.compute_capacity(cap);
    if (!pop.crossed and pop.count >= 2.0) {
        pop.crossed = true;
        ui_ctx.res.log.push(.good, "Population reached 2 - the shelter can support another. (Act II arrives in a future update.)");
    }

    // Status panel — the actor's stocks, pinned top-left, each with the live rate read
    // off its component. Vigor is shown against its *hunger ceiling*, not its base max,
    // so a starving actor visibly loses headroom. Materials is the bare stockpile.
    const status_div = try widgets.Node.pcreate(ui_ctx.arena, "status_div", play);
    _ = status_div.with_layout(ui.features.Layout.init(.top_left, .vertical).with_gap(10));
    const day = 1 + @as(u64, @intFromFloat(ui_ctx.res.time.elapsed / app.secs_per_day));
    _ = try widgets.label(ui_ctx, status_div, "day_text", std.fmt.bufPrint(&char_buf, "Day {d}", .{day}) catch "?");
    const res_panel = try widgets.panel(ui_ctx, status_div, "res_panel", "Resources");

    // Vitals: a small ASCII figure (mood — hunger/exhaustion first, then warmth) beside a
    // pulsing "heartbeat" readout. Flavor only — the numbers below it are load-bearing.
    const warmth = app.compute_warmth(vigor, satiety, cap);
    const vitals = try widgets.Node.pcreate(ui_ctx.arena, "vitals", res_panel);
    _ = vitals.with_layout(ui.features.Layout.init(.relative, .horizontal).with_gap(10));
    const kind = figure_kind(warmth, satiety.v / satiety.max, if (vigor_cap > 0) vigor.v / vigor_cap else 0);
    try ui_figure(ui_ctx, vitals, figure_glyphs(kind), figure_color(ui_ctx.res.theme, kind));
    const heart = try widgets.label(ui_ctx, vitals, "heartbeat", "<3 <3 <3");
    heart.render_data.text = heartbeat_color(ui_ctx.res.theme, ui_ctx.res.time.elapsed);

    _ = try widgets.label(ui_ctx, res_panel, "vigor_text", std.fmt.bufPrint(&char_buf, "Vigor: {d:.0}/{d:.0}  (+{d:.1}/s)", .{ vigor.v, vigor_cap, vigor.trickle }) catch "?");
    _ = try widgets.label(ui_ctx, res_panel, "satiety_text", std.fmt.bufPrint(&char_buf, "Satiety: {d:.0}/{d:.0}  (-{d:.1}/s)", .{ satiety.v, satiety.max, satiety.drain }) catch "?");
    _ = try widgets.label(ui_ctx, res_panel, "food_text", std.fmt.bufPrint(&char_buf, "Food: {d:.0}/{d:.0}  (spoils {d:.2}/s)", .{ food.v, food.max, food.spoil }) catch "?");
    var mat_buf: [16]u8 = undefined;
    _ = try widgets.label(ui_ctx, res_panel, "materials_text", std.fmt.bufPrint(&char_buf, "Materials: {s}", .{fmt_num(&mat_buf, materials.v)}) catch "?");
    _ = try widgets.label(ui_ctx, res_panel, "population_text", std.fmt.bufPrint(&char_buf, "Population: {d:.1}/{d:.0}", .{ pop.count, pop.capacity }) catch "?");

    // Event log — newest-first feed of what just happened. Lives on `Resources.log`
    // (survives the per-frame arena); each line is recolored by its tone. Scrollable
    // (mouse wheel) so the whole run's history is reachable, not just the last few lines.
    const log_panel = try widgets.panel(ui_ctx, status_div, "log_panel", "Log");
    const feed = &ui_ctx.res.log;
    const log_view = try widgets.scroll_view(ui_ctx, log_panel, "log_view", 260, 160);
    var li: usize = 0;
    while (li < feed.count) : (li += 1) {
        const entry = feed.get(li);
        const lkey = try std.fmt.allocPrint(ui_ctx.arena, "log{d}", .{li});
        const lnode = try widgets.label(ui_ctx, log_view.content, lkey, entry.text());
        lnode.render_data.text = log_tone_color(ui_ctx.res.theme, entry.tone);
    }

    // Actor condition word, pinned top-right of the screen (colored by severity).
    const status = actor_status(ui_ctx.res.theme, vigor, satiety);
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
    const browse_labor = try widgets.button(ui_ctx, act_panel, "browse_labor", "Browse catalog", true);
    if (browse_labor.query(ui_ctx).clicked) open_browse(ui_ctx, .labor);

    // "Let AI decide" — a live, clickable proof of the `decide → act` split (roadmap
    // M7): `ai_decide` ranks the same catalog a human reads below and picks an index,
    // then this button funnels it through the very same `resolve_action` a manual click
    // does. Dimmed exactly when `ai_decide` would return `null` (nothing affordable).
    const ai_pick = ai_decide(vigor, cap);
    const ai_btn = try widgets.button(ui_ctx, act_panel, "ai_decide", "Let AI decide", ai_pick != null);
    if (ai_btn.query(ui_ctx).clicked) {
        if (ai_pick) |i| app.resolve_action(ui_ctx.res, i, vigor, satiety, food, materials, cap);
    }

    for (actions, 0..) |act, i| {
        const bkey = try std.fmt.allocPrint(ui_ctx.arena, "act{d}", .{i}); // arena-lived: outlives this frame's tree
        const k = app.action_quality(vigor, cap, i); // tools up, tiredness down — scales the whole distribution

        // Plan the payment: effort-savers cheapen the price, a power tool pays the
        // bulk from its durability, vigor covers the 5% floor (and any shortfall).
        const pay = app.plan_payment(cap, i, act.energy_cost);

        // Label shows the p10–p90 yield band (scaled by k), not a single number — the
        // spread is the risk. Collapse to one figure when the rounded ends coincide.
        const band = ha.dist.stats(act.dist);
        const lo = @round(band.p10 * k);
        const hi = @round(band.p90 * k);
        const unit: u8 = if (act.target == .food) 'f' else 'm';
        var rbuf: [24]u8 = undefined;
        const range = if (lo == hi)
            std.fmt.bufPrint(&rbuf, "{d:.0}", .{lo}) catch "?"
        else
            std.fmt.bufPrint(&rbuf, "{d:.0}-{d:.0}", .{ lo, hi }) catch "?";
        const txt = std.fmt.bufPrint(
            &char_buf,
            "{s}  (-{d:.1} vig, +{s}{c})",
            .{ act.label, pay.from_vigor, range, unit },
        ) catch act.label;
        const can_afford = app.affordable(vigor, cap, i);
        const btn = try widgets.button(ui_ctx, act_panel, bkey, txt, can_afford);
        if (btn.query(ui_ctx).clicked and can_afford) {
            app.resolve_action(ui_ctx.res, i, vigor, satiety, food, materials, cap);
        }
    }

    // Capital Goods — a collapsible drawer pinned bottom-left. Its titled panel is the
    // toggle: clicking it opens/closes the goods tray. The tray is built as a *sibling*
    // of the panel (not a child), so clicking a good to build it never also trips the
    // toggle — the hit-test marks every slot whose rect contains the point.
    const capital_goods = try widgets.Node.pcreate(ui_ctx.arena, "capital", play);
    _ = capital_goods.with_layout(ui.features.Layout.init(.bottom_left, .vertical).with_gap(10));
    const cap_panel = try widgets.panel(ui_ctx, capital_goods, "cap_panel", "Capital Goods");
    // Built as a *sibling* of `cap_panel`, not a child — `cap_panel`'s whole box is the
    // drawer's own click surface (see below), so a child button here would double-fire
    // both the drawer toggle and the browser open on the same click (flat, occlusion-
    // unaware hit-testing marks every slot whose rect contains the point).
    const browse_capital = try widgets.button(ui_ctx, capital_goods, "browse_capital", "Browse catalog", true);
    if (browse_capital.query(ui_ctx).clicked) open_browse(ui_ctx, .capital);
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
/// the `MaybeSingle` fetch tuple — `{ *Vigor, *Satiety, *Food, *Materials, *Capital,
/// *Population }`.
fn ui_capital_goods_menu(ui_ctx: *widgets.UiCtx, parent: *widgets.Node, actor: anytype) !?*widgets.Node {
    const res = ui_ctx.res;
    var char_buf: [64]u8 = undefined;
    const vigor, const satiety, _, const materials, const cap, _ = actor;

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
        const can_afford_build = app.afford_build(gi, vigor, materials, cap);
        const buy = try widgets.icon_button(ui_ctx, cap_row, ckey, sprite, icon_px, can_afford_build);
        if (buy.query(ui_ctx).hovering) {
            hovered = gi;
            hov_rect = buy.rect(ui_ctx);
        }
        if (buy.query(ui_ctx).clicked and can_afford_build) {
            app.build_capital(ui_ctx.res, gi, vigor, satiety, materials, cap);
        }
    }

    // Hover tooltip — a floating overlay tree showing the hovered good's costs/effects,
    // pinned above its icon. Built only when a good is hovered and its last-frame rect
    // is known (the tray is static, so last frame's rect is right). Sized by a throwaway
    // layout pass, then given an origin centred over the icon.
    if (hovered) |hi| {
        if (hov_rect) |r| {
            const tip = app.capital_tip(&char_buf, capital[hi], hi, cap);
            const box = try widgets.tooltip(ui_ctx, "tip", tip);
            try box.set_global_pos(); // resolve its size (origin still 0,0)
            const ox = r.x + (r.w - box.size.width) / 2; // centred over the icon
            const oy = r.y - box.size.height - app.tip_gap; // floating just above it
            box.layout = box.layout.with_origin(ox, oy);
            return box;
        }
    }
    return null;
}

/// Which catalog the M4 browser overlay is showing, if either. Its open/closed state
/// rides on a *fixed* interaction key (`browse_key`, not a node-derived one) because the
/// flag must be readable/settable from three places that never build the same node in
/// the same frame: the "Browse" button on the home screen (opens it), `build_ui`'s own
/// routing check (reads it every frame regardless of which screen that turns out to be),
/// and the browser's own "‹ BACK" button (closes it). A node-derived key would get pruned
/// (see `ui/cache.zig`'s `Pool.prune`) the instant the screen that builds it isn't shown.
const BrowseKind = enum { labor, capital };
fn browse_key(kind: BrowseKind) u64 {
    return ui.key(0, if (kind == .labor) "labor_browse_open" else "capital_browse_open");
}
pub fn browse_open(ctx: *widgets.UiCtx) ?BrowseKind {
    if (ctx.interactionOf(browse_key(.labor)).active) return .labor;
    if (ctx.interactionOf(browse_key(.capital)).active) return .capital;
    return null;
}
fn open_browse(ctx: *widgets.UiCtx, kind: BrowseKind) void {
    ctx.setFlag(browse_key(kind), .active, true);
}
pub fn close_browse(ctx: *widgets.UiCtx) void {
    ctx.setFlag(browse_key(.labor), .active, false);
    ctx.setFlag(browse_key(.capital), .active, false);
    ctx.res.focused_text = null;
    sdl.keyboard.stopTextInput(ctx.res.window) catch {};
}

/// Case-insensitive ASCII substring search — the catalog browser's search box. An empty
/// `needle` matches everything (no filter typed yet).
fn contains_ci(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// A checkbox-style toggle: `[x] label` / `[ ] label`, flipping its own latched `.active`
/// flag on click (the same "own key persists its state" idiom `cap_panel`'s drawer toggle
/// uses in `ui_playgame`). Peeks the pre-click state via the node's *precomputed* key
/// (`ui.key(parent.key, key)` — identical to what `pcreate` derives internally) so the
/// checkbox glyph is baked into the label text before the node exists.
fn toggle_btn(ctx: *widgets.UiCtx, parent: *widgets.Node, key: []const u8, base_label: []const u8) !bool {
    const pre = ctx.interactionOf(ui.key(parent.key, key)).active;
    var buf: [40]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "[{s}] {s}", .{ if (pre) "x" else " ", base_label }) catch base_label;

    const node = try widgets.Node.pcreate(ctx.arena, key, parent);
    try widgets.data_text(ctx, node, text);
    node.size.padding = ui.features.Padding.initSymmetric(6, 3);
    _ = node.with_layout(ui.features.Layout.init(.relative, null));

    var on = pre;
    if (node.query(ctx).clicked) {
        on = !on;
        ctx.setFlag(node.key, .active, on);
    }
    const c = if (on) ctx.res.theme.acc else ctx.res.theme.dim;
    node.render_data.outline = c;
    node.render_data.text = c;
    return on;
}

/// An exclusive "radio" row: one button per label under `parent`, clicking one selects it
/// and clears the rest (self-contained — each option just latches its own `.active`).
/// Returns the selected index, defaulting to `0` (the first label) when none is active yet
/// — true on first render, and again after the browser closes and its slots are pruned,
/// which conveniently mirrors the design prototype's own reset-search/category-on-open.
fn radio_row(ctx: *widgets.UiCtx, parent: *widgets.Node, row_key: []const u8, labels: []const []const u8) !usize {
    const row = try widgets.Node.pcreate(ctx.arena, row_key, parent);
    _ = row.with_layout(ui.features.Layout.init(.relative, .horizontal).with_gap(6));

    var nodes: [8]*widgets.Node = undefined;
    for (labels, 0..) |lbl, i| {
        const k = try std.fmt.allocPrint(ctx.arena, "opt{d}", .{i});
        const node = try widgets.Node.pcreate(ctx.arena, k, row);
        try widgets.data_text(ctx, node, lbl);
        node.size.padding = ui.features.Padding.initSymmetric(6, 3);
        _ = node.with_layout(ui.features.Layout.init(.relative, null));
        nodes[i] = node;
    }

    var active_i: ?usize = null;
    var clicked_i: ?usize = null;
    for (nodes[0..labels.len], 0..) |node, i| {
        const q = node.query(ctx);
        if (q.active) active_i = i;
        if (q.clicked) clicked_i = i;
    }
    if (clicked_i) |ci| {
        for (nodes[0..labels.len], 0..) |node, i| ctx.setFlag(node.key, .active, i == ci);
        active_i = ci;
    }
    const sel = active_i orelse 0;
    for (nodes[0..labels.len], 0..) |node, i| {
        const c = if (i == sel) ctx.res.theme.acc else ctx.res.theme.dim;
        node.render_data.outline = c;
        node.render_data.text = c;
    }
    return sel;
}

/// One row in the catalog browser: name + cost chip on top, a dim sub-line below, and an
/// ACT/BUILD button at the right. Returns whether the button was clicked (still guarded
/// by `can_act`, same as every other button in the HUD — this is purely the look).
fn catalog_row(
    ctx: *widgets.UiCtx,
    parent: *widgets.Node,
    key: []const u8,
    name: []const u8,
    cost: []const u8,
    sub: []const u8,
    act_label: []const u8,
    can_act: bool,
) !bool {
    const row = try widgets.Node.pcreate(ctx.arena, key, parent);
    row.render_data.outline = ctx.res.theme.line;
    _ = row.with_layout(ui.features.Layout.init(.relative, .horizontal).with_gap(12))
        .with_size(ui.features.Size.init(.fit_children, .fit_children, ui.features.Padding.initSymmetric(10, 6)));

    const info = try widgets.Node.pcreate(ctx.arena, "info", row);
    _ = info.with_layout(ui.features.Layout.init(.relative, .vertical).with_gap(2));
    const top = try widgets.Node.pcreate(ctx.arena, "top", info);
    _ = top.with_layout(ui.features.Layout.init(.relative, .horizontal).with_gap(10));
    const nlbl = try widgets.label(ctx, top, "name", name);
    nlbl.render_data.text = ctx.res.theme.fg;
    const clbl = try widgets.label(ctx, top, "cost", cost);
    clbl.render_data.text = ctx.res.theme.acc;
    const slbl = try widgets.label(ctx, info, "sub", sub);
    slbl.render_data.text = ctx.res.theme.dim;

    const btn = try widgets.button(ctx, row, "act", act_label, can_act);
    return btn.query(ctx).clicked and can_act;
}

/// The M4 catalog browser: a fullscreen list over one catalog (`kind`), replacing the
/// play screen while open (`build_ui` routes here instead of `ui_playgame`). Search +
/// hide-can't-do/hide-owned toggles + a cheapest/richest/a-z sort + category chips filter
/// a curated, hand-authored catalog (roadmap's locked decision #3 — not the design
/// prototype's procedurally-generated ~150-item sweep, so "category sidebar" here is a
/// filter-chip row rather than a scrolling left column; revisit if the catalog grows).
/// Rows funnel through the same `resolve_action`/`build_capital` the inline HUD uses —
/// this is a second *presentation* of the same catalog + act step, not a second mechanism.
fn ui_catalog(ui_ctx: *widgets.UiCtx, kind: BrowseKind, actor: anytype) !*widgets.Node {
    const vigor, const satiety, const food, const materials, const cap, _ = actor;

    const root = try widgets.ui_root(ui_ctx, "catalog");
    const col = try widgets.Node.pcreate(ui_ctx.arena, "col", root);
    _ = col.with_layout(ui.features.Layout.init(.top_left, .vertical).with_gap(10))
        .with_size(ui.features.Size.init(.fit_children, .fit_children, ui.features.Padding.init(16)));

    // Header: back + title + search.
    const header = try widgets.Node.pcreate(ui_ctx.arena, "header", col);
    _ = header.with_layout(ui.features.Layout.init(.relative, .horizontal).with_gap(14));
    const back = try widgets.button(ui_ctx, header, "back", "< BACK", true);
    if (back.query(ui_ctx).clicked) close_browse(ui_ctx);
    const title_lbl = try widgets.label(ui_ctx, header, "title", if (kind == .labor) "LABOR CATALOG" else "CAPITAL CATALOG");
    title_lbl.render_data.text = ui_ctx.res.theme.fg;
    const search = try widgets.text_input(ui_ctx, header, "search", "search...", 200);
    const sidx = ui_ctx.cache(search.key, widgets.UiState.TextInputState);
    const query_text = ui_ctx.pool(widgets.UiState.TextInputState).get(sidx).buf[0..ui_ctx.pool(widgets.UiState.TextInputState).get(sidx).len];

    // Filters: hide-can't-do (both), hide-owned (capital only), sort.
    const filters = try widgets.Node.pcreate(ui_ctx.arena, "filters", col);
    _ = filters.with_layout(ui.features.Layout.init(.relative, .horizontal).with_gap(10));
    const hide_cant = try toggle_btn(ui_ctx, filters, "hide_cant", "hide can't-do");
    const hide_owned = if (kind == .capital) try toggle_btn(ui_ctx, filters, "hide_owned", "hide owned") else false;
    const sort_i = try radio_row(ui_ctx, filters, "sort", &.{ "CHEAPEST", "RICHEST", "A-Z" });

    // Category chips — "ALL" plus each distinct category this catalog carries.
    const cat_labels: []const []const u8 = if (kind == .labor)
        &.{ "ALL", "FORAGE", "FISH & HUNT", "WOODCUTTING" }
    else
        &.{ "ALL", "SHELTER & COMFORT", "TOOLS & CRAFT", "ENERGY" };
    const cat_i = try radio_row(ui_ctx, col, "cats", cat_labels);
    const cat_filter: ?[]const u8 = if (cat_i == 0) null else cat_labels[cat_i];

    const list = try widgets.Node.pcreate(ui_ctx.arena, "list", col);
    _ = list.with_layout(ui.features.Layout.init(.relative, .vertical).with_gap(6));

    if (kind == .labor) {
        var idxs: [actions.len]usize = undefined;
        for (0..actions.len) |i| idxs[i] = i;
        // Tiny catalog (≤ a handful of rows) — a plain insertion sort beats pulling in
        // `std.sort`'s comparator-context machinery for this scale.
        var i: usize = 1;
        while (i < idxs.len) : (i += 1) {
            const v = idxs[i];
            var j = i;
            while (j > 0) : (j -= 1) {
                const a = idxs[j - 1];
                const before = switch (sort_i) {
                    0 => actions[a].energy_cost <= actions[v].energy_cost, // cheapest first
                    1 => ha.dist.stats(actions[a].dist).mean >= ha.dist.stats(actions[v].dist).mean, // richest first
                    else => std.mem.order(u8, actions[a].label, actions[v].label) == .lt, // a-z
                };
                if (before) break;
                idxs[j] = a;
            }
            idxs[j] = v;
        }

        for (idxs) |gi| {
            const act = actions[gi];
            if (cat_filter) |cf| if (!std.mem.eql(u8, act.category, cf)) continue;
            if (!contains_ci(act.label, query_text)) continue;
            const can_act = app.affordable(vigor, cap, gi);
            if (hide_cant and !can_act) continue;

            const k = app.action_quality(vigor, cap, gi);
            const band = ha.dist.stats(act.dist);
            const lo = @round(band.p10 * k);
            const hi = @round(band.p90 * k);
            const unit: u8 = if (act.target == .food) 'f' else 'm';
            var rbuf: [24]u8 = undefined;
            const range = if (lo == hi)
                std.fmt.bufPrint(&rbuf, "{d:.0}{c}", .{ lo, unit }) catch "?"
            else
                std.fmt.bufPrint(&rbuf, "{d:.0}-{d:.0}{c}", .{ lo, hi, unit }) catch "?";
            var costbuf: [16]u8 = undefined;
            const pay = app.plan_payment(cap, gi, act.energy_cost);
            const cost = std.fmt.bufPrint(&costbuf, "-{d:.1} vig", .{pay.from_vigor}) catch "?";
            var subbuf: [64]u8 = undefined;
            const sub = std.fmt.bufPrint(&subbuf, "{s} - +{s}", .{ act.category, range }) catch act.category;

            const rkey = try std.fmt.allocPrint(ui_ctx.arena, "row{d}", .{gi});
            if (try catalog_row(ui_ctx, list, rkey, act.label, cost, sub, "ACT", can_act)) {
                app.resolve_action(ui_ctx.res, gi, vigor, satiety, food, materials, cap);
            }
        }
    } else {
        var idxs: [capital.len]usize = undefined;
        for (0..capital.len) |i| idxs[i] = i;
        var i: usize = 1;
        while (i < idxs.len) : (i += 1) {
            const v = idxs[i];
            var j = i;
            while (j > 0) : (j -= 1) {
                const a = idxs[j - 1];
                const before = switch (sort_i) {
                    0 => capital[a].material_cost <= capital[v].material_cost, // cheapest first
                    1 => capital[a].energy_cost >= capital[v].energy_cost, // richest (biggest build) first
                    else => std.mem.order(u8, capital[a].label, capital[v].label) == .lt, // a-z
                };
                if (before) break;
                idxs[j] = a;
            }
            idxs[j] = v;
        }

        for (idxs) |gi| {
            const g = capital[gi];
            if (cat_filter) |cf| if (!std.mem.eql(u8, g.category, cf)) continue;
            if (!contains_ci(g.label, query_text)) continue;
            const owned = owns(cap, gi);
            if (hide_owned and owned) continue;
            const can_act = !owned and app.afford_build(gi, vigor, materials, cap);
            if (hide_cant and !owned and !can_act) continue;

            var costbuf: [24]u8 = undefined;
            const cost = if (owned)
                (if (g.power_capacity > 0)
                    std.fmt.bufPrint(&costbuf, "{d:.0}/{d:.0} dur", .{ cap.durability[gi], g.power_capacity }) catch "owned"
                else
                    "owned")
            else if (cap.progress[gi] > 0)
                std.fmt.bufPrint(&costbuf, "{d:.0}%", .{100 * cap.progress[gi] / g.energy_cost}) catch "?"
            else
                std.fmt.bufPrint(&costbuf, "{d:.0} mat, {d:.0} e", .{ g.material_cost, g.energy_cost }) catch "?";
            var subbuf: [64]u8 = undefined;
            const sub = std.fmt.bufPrint(&subbuf, "{s} - {s}", .{ g.category, capital_effect(g) }) catch g.category;
            const act_label = if (owned) "DONE" else if (cap.progress[gi] > 0) "POUR" else "BUILD";

            const rkey = try std.fmt.allocPrint(ui_ctx.arena, "row{d}", .{gi});
            if (try catalog_row(ui_ctx, list, rkey, g.label, cost, sub, act_label, can_act)) {
                app.build_capital(ui_ctx.res, gi, vigor, satiety, materials, cap);
            }
        }
    }

    return root;
}

/// One-line plain-English effect summary for a capital good's browser row (distinct from
/// `capital_tip`'s hover text, which also folds in owned/building status the row already
/// shows via its cost chip).
fn capital_effect(g: Good) []const u8 {
    if (g.power_capacity > 0) return "powers an action from its own durability, not vigor";
    if (g.cost_mult < 1.0) return "lowers an action's energy price";
    if (g.kind == .comfort) return "raises vigor recovery";
    return "boosts an action's yield";
}

pub fn build_ui(ui_ctx: *widgets.UiCtx, world: *ha.world.World) !widgets.Ui {
    // queries
    // MaybeSingle: the actor is despawned on death, so it may be absent. All of its stocks
    // co-spawn on one entity, so one query fetches them together.
    const q_actor = ecs.MaybeSingle(.{ comp.Vigor, comp.Satiety, comp.StockFood, comp.StockMaterials, comp.Capital, comp.Population, ecs.With(tag.Player) }){ .world = world };
    const actor = q_actor.get();

    // Resolve this frame's COLD↔WARM theme before building anything, so every widget's
    // `ctx.res.theme` read below sees the same value. Death reads as cold — there's no
    // live actor left to compute a warmth from, and the game-over screen is meant to feel
    // that way.
    ui_ctx.res.theme = if (actor) |a| ha.theme.lerp(app.compute_warmth(a[0], a[1], a[4])) else ha.theme.cold;

    // Render list — the frame's root trees, drawn in order (later ones on top). Arena-
    // backed; dies with this frame's node tree. `collect` flattens each builder's return.
    var trees: std.ArrayList(*widgets.Node) = .empty;
    // Content: the play HUD if the actor lives, else the game-over screen. Each builder
    // returns a `.{ screen, overlay }` pair (a hover tooltip for `ui_playgame`, a confirm
    // modal for `ui_gameover` — null when neither is showing), which `collect` adds.
    if (actor) |a| {
        // `browse_open` must run every frame regardless of which screen this turns out to
        // be — it's the thing that keeps its own fixed interaction slots alive (see
        // `BrowseKind`'s doc comment).
        if (browse_open(ui_ctx)) |kind| {
            try widgets.collect(&trees, ui_ctx.arena, try ui_catalog(ui_ctx, kind, a));
        } else {
            try widgets.collect(&trees, ui_ctx.arena, try ui_playgame(ui_ctx, a));
        }
    } else {
        try widgets.collect(&trees, ui_ctx.arena, try ui_gameover(ui_ctx, world));
    }

    return .{ .trees = trees.items };
}
