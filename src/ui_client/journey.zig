//! `journey` — **keyboard-only interaction journeys** (QA-14/15) driven through the shared
//! host routing policy (`route.Router`). A journey is a multi-frame script of keyboard
//! commands against a representative stamped control set, asserting that focus traversal,
//! activation, roving movement, and dismissal reach every control and return focus correctly
//! **without a pointer**.
//!
//! **Why a model, not the live page.** A production frame's node tree needs the platform font to
//! measure text (see `test_ui.zig`), so a keyboard journey over the real page cannot run SDL-free.
//! What a journey actually exercises is the host interaction state machine — the focus registry,
//! the semantic-command mapping, and the engine's event stage — all of which are pure. So a
//! journey stamps the controls the production screen registers (by the same stable keys and in the
//! same Tab order) and scripts the keyboard over them through the one routing policy
//! (`route.Router.routeCommand`) that production (`main.zig`/`frame.Driver`) and the full-frame
//! headless `replay.Replay` also use — no routing logic is duplicated here.
//!
//! **The frame contract.** Focus traversal reads the *last completed* frame's registered order
//! (the engine's double-buffered focus registry), so a journey step that changes which controls
//! exist re-registers them and ends the frame before the next command traverses — exactly the
//! build→event-stage cadence `main.zig` runs. `Scene` encapsulates that cadence so a journey reads
//! as "register these controls, then press these keys".

const std = @import("std");
const input = @import("input.zig");
const command = @import("command.zig");
const route = @import("route.zig");
const cb = @import("ctx_binding.zig");
const ui = @import("ui");

const UiCtx = cb.UiCtx;
const Rect = ui.Rect;

/// A control a journey registers: its stable key, whether it is enabled, and an optional roving
/// group (a tab in a strip). Mirrors what `El.control` registers for a production control.
pub const Control = struct {
    key: u64,
    enabled: bool = true,
    group: ?u64 = null,
    /// A nominal rect, so the control is both focusable and hittable (a keyboard journey never
    /// uses the rect, but stamping keeps the slot live and consistent with a real frame).
    rect: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
};

/// What one scripted key command did, derived from the shared router's effect so a test can
/// assert routing without re-deriving it. The router returns only `handled`/`suppress_text`;
/// `Scene` observes the focus/interaction change around the dispatch to classify it.
pub const Outcome = struct {
    command: command.Command,
    /// A focus-moving command (`focus_next`/`focus_previous`/`focus_search`) that moved focus.
    focus_moved: bool = false,
    /// A roving-group move (`move_left/right/up/down`) that moved the roving focus.
    roving_moved: bool = false,
    /// An arrow/page/home/end command that fell through to the focused range owner (a slider)
    /// and marked its flag, because no roving group claimed the move.
    range_marked: bool = false,
    /// `activate` (Enter/Space) that marked a focused control `clicked`.
    activated: bool = false,
    /// `dismiss` (Escape) that marked the registered escape owner `dismissed`.
    dismissed: bool = false,
};

/// A keyboard-journey scene: one `UiCtx` and a `route.Router`, with helpers that run the
/// build→event-stage frame cadence so focus traversal always reads a completed frame's order.
pub const Scene = struct {
    ctx: *UiCtx,
    router: route.Router,

    pub fn init(ctx: *UiCtx) Scene {
        return .{ .ctx = ctx, .router = route.Router.init(ctx, .none) };
    }

    /// Stamp a slot the way the post-layout `stamp_rects` walk would, so the event stage can
    /// hit-test and bubble against it — the keyboard journey's by-hand layout.
    fn stamp(self: *Scene, node_key: u64, rect: Rect) void {
        _ = self.ctx.interactionOf(node_key); // a node has no slot until queried
        _ = self.ctx.stampRect(node_key, rect, null, null);
    }

    /// Register and stamp a frame's controls, then end the frame to publish the focus order and
    /// the command owners for the next event stage — the production build→endFrame boundary.
    /// `escape_owner`, when set, is registered as the Escape (dismiss) target this frame.
    pub fn frame(self: *Scene, controls: []const Control, escape_owner: ?u64) void {
        self.ctx.beginFrame();
        self.ctx.res.commands.beginBuild();
        for (controls) |c| {
            if (c.group) |g| self.ctx.registerRovingFocus(g, c.key, c.enabled) else self.ctx.registerFocus(c.key, c.enabled);
            self.stamp(c.key, c.rect);
        }
        if (escape_owner) |e| self.ctx.res.commands.registerEscape(e);
        self.ctx.res.commands.endBuild();
        self.ctx.endFrame();
        // The next frame's event stage will read this just-published order. Open the input frame
        // so a key can be scripted immediately.
        self.ctx.beginFrame();
        for (controls) |c| self.stamp(c.key, c.rect); // slots re-stamped this frame
        self.ctx.res.input.beginFrame();
    }

    /// Press one key with modifiers and return the routed command outcome (null when the key
    /// mapped to no command). Dispatches through the shared `route.Router` — the same policy
    /// production and the full-frame replay use.
    pub fn key(self: *Scene, kc: @import("sdl3").keycode.Keycode, mods: input.Modifiers) ?Outcome {
        self.ctx.res.input.recordKey(kc, .press, mods);
        const cmd = command.fromKeyEvent(.{ .key = kc, .action = .press, .modifiers = mods }) orelse return null;
        return self.dispatch(cmd);
    }

    /// Route one semantic command through the shared router and classify its effect for the
    /// test's assertions by observing the focus/interaction change around the dispatch.
    fn dispatch(self: *Scene, cmd: command.Command) Outcome {
        var out: Outcome = .{ .command = cmd };
        const focus_before = self.ctx.focusedKey();
        const routed = self.router.routeCommand(cmd);
        const focus_after = self.ctx.focusedKey();
        const moved = focus_before != focus_after;
        switch (cmd) {
            .focus_next, .focus_previous, .focus_search => out.focus_moved = moved,
            .move_left, .move_right, .move_up, .move_down => {
                out.roving_moved = moved;
                out.range_marked = !moved and routed.handled;
            },
            .page_up, .page_down => out.range_marked = routed.handled,
            .activate => out.activated = routed.handled,
            .dismiss => out.dismissed = routed.handled,
            else => {},
        }
        return out;
    }

    /// Press Tab (optionally Shift+Tab) and return the outcome.
    pub fn tab(self: *Scene, shift: bool) ?Outcome {
        return self.key(.tab, .{ .shift = shift });
    }

    pub fn focusedKey(self: *const Scene) ?u64 {
        return self.ctx.focusedKey();
    }
};

// =============================== QA-14 / QA-15 journeys ===================================
// SDL-free: a `Resources` with an undefined platform, real pools/focus/semantics, controls
// stamped and registered by hand, keyboard scripted, focus/activation/dismissal read back.

const testing = std.testing;
const Resources = @import("../res.zig").Resources;
const key_of = ui.key;

const Rig = struct {
    res: Resources,
    ctx: UiCtx,

    fn init(self: *Rig) void {
        self.res = .{ .platform = undefined, .sim = .{} };
        self.ctx = UiCtx.init(&self.res, testing.allocator, undefined);
    }

    fn deinit(self: *Rig) void {
        self.ctx.deinit();
    }
};

test "QA-14 Act I keyboard journey: tab across the shell, activate, and dismiss a dialog" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var scene = Scene.init(&rig.ctx);

    // The Act I shell's keyboard-reachable controls, in Tab order: the two view-nav tabs
    // (a roving group), the eating-rate slider, the market TRADE action, and a build row.
    const nav = key_of(0, "view_nav");
    const tab_actions = key_of(0, "nav.actions");
    const tab_build = key_of(0, "nav.build");
    const eating = key_of(0, "eating_rate");
    const trade = key_of(0, "market.trade");
    const build_row = key_of(0, "build.shelter");

    const shell = [_]Control{
        .{ .key = tab_actions, .group = nav },
        .{ .key = tab_build, .group = nav },
        .{ .key = eating },
        .{ .key = trade },
        .{ .key = build_row },
    };

    // Frame 1: register the shell; focus the first tab to start the journey from a known place.
    scene.frame(&shell, null);
    try testing.expect(rig.ctx.requestFocus(tab_actions));

    // Tab moves to the next global stop. The roving group contributes ONE stop (its active
    // member), so Tab leaves the nav group and lands on the slider, then the trade action.
    try testing.expect(scene.tab(false).?.focus_moved);
    try testing.expectEqual(@as(?u64, eating), scene.focusedKey());
    try testing.expect(scene.tab(false).?.focus_moved);
    try testing.expectEqual(@as(?u64, trade), scene.focusedKey());

    // Enter on the TRADE action activates it (the page would open the dialog here).
    const activate = scene.key(.return_key, .{}).?;
    try testing.expect(activate.activated);
    try testing.expect(rig.ctx.interactionOf(trade).clicked);

    // Frame 2: the trade dialog is open — its controls trap focus, and it is the Escape owner.
    const dlg_tabs = key_of(0, "trade.tabs");
    const dlg_buy = key_of(0, "trade.buy");
    const dlg_sell = key_of(0, "trade.sell");
    const dlg_confirm = key_of(0, "trade.confirm");
    const dlg_close = key_of(0, "trade.close");
    const dialog = [_]Control{
        .{ .key = dlg_buy, .group = dlg_tabs },
        .{ .key = dlg_sell, .group = dlg_tabs },
        .{ .key = dlg_confirm },
        .{ .key = dlg_close },
    };
    scene.frame(&dialog, dlg_close); // Escape routes to the dialog's close
    try testing.expect(rig.ctx.requestFocus(dlg_confirm));

    // Tab cycles within the dialog's controls; Escape dismisses via the registered owner.
    try testing.expect(scene.tab(false).?.focus_moved);
    const dismiss = scene.key(.escape, .{}).?;
    try testing.expect(dismiss.dismissed);
    try testing.expect(rig.ctx.interactionOf(dlg_close).dismissed);
}

test "QA-14 eating rate: arrow keys drive the focused slider as a range owner" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var scene = Scene.init(&rig.ctx);

    const eating = key_of(0, "eating_rate");
    // Register the slider as a range owner so arrow keys route to it (not roving focus).
    rig.ctx.beginFrame();
    rig.ctx.res.commands.beginBuild();
    rig.ctx.registerFocus(eating, true);
    scene.stamp(eating, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    rig.ctx.res.commands.registerRange(eating);
    rig.ctx.res.commands.endBuild();
    rig.ctx.endFrame();
    rig.ctx.beginFrame();
    scene.stamp(eating, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    rig.ctx.res.input.beginFrame();
    try testing.expect(rig.ctx.requestFocus(eating));

    // Right/Left arrow over a focused range owner (no roving group) marks the slider's
    // increment/decrement flags — the keyboard path the eating policy reads.
    const right = scene.key(.right, .{}).?;
    try testing.expect(!right.roving_moved); // not a roving move → fell through to range
    try testing.expect(right.range_marked);
    try testing.expect(rig.ctx.interactionOf(eating).increment);
}

test "QA-15 Act II keyboard journey: search focus, tab the catalog controls, roving sort" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var scene = Scene.init(&rig.ctx);

    // Act II catalog controls: a search field (the `/` shortcut target), a sort select, and
    // the two view tabs as a roving group.
    const search = key_of(0, "catalog.search");
    const sort = key_of(0, "catalog.sort");
    const nav = key_of(0, "act2.nav");
    const tab_actions = key_of(0, "act2.actions");
    const tab_build = key_of(0, "act2.build");

    // Register with the search field as the `/` shortcut target and a text owner.
    rig.ctx.beginFrame();
    rig.ctx.res.commands.beginBuild();
    rig.ctx.registerFocus(search, true);
    rig.ctx.registerFocus(sort, true);
    rig.ctx.registerRovingFocus(nav, tab_actions, true);
    rig.ctx.registerRovingFocus(nav, tab_build, true);
    for ([_]u64{ search, sort, tab_actions, tab_build }) |k| scene.stamp(k, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    // `editorKeyOf` indirection: the field owns its model, so editor = field key.
    rig.ctx.res.commands.registerText(search, search, true); // search_shortcut = true
    rig.ctx.res.commands.endBuild();
    rig.ctx.endFrame();
    rig.ctx.beginFrame();
    for ([_]u64{ search, sort, tab_actions, tab_build }) |k| scene.stamp(k, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    rig.ctx.res.input.beginFrame();

    // `/` focuses the search field from anywhere (the search shortcut).
    const slash = scene.key(.slash, .{}).?;
    try testing.expect(slash.focus_moved);
    try testing.expectEqual(@as(?u64, search), scene.focusedKey());

    // Tab advances to the sort control, then to the nav group's single stop.
    try testing.expect(scene.tab(false).?.focus_moved);
    try testing.expectEqual(@as(?u64, sort), scene.focusedKey());
    try testing.expect(scene.tab(false).?.focus_moved);
    try testing.expectEqual(@as(?u64, tab_actions), scene.focusedKey());

    // Right arrow moves roving focus within the nav group (ACTIONS → BUILD) and marks the
    // newly active tab clicked, the way the production tab strip switches views.
    const right = scene.key(.right, .{}).?;
    try testing.expect(right.roving_moved);
    try testing.expectEqual(@as(?u64, tab_build), scene.focusedKey());
    try testing.expect(rig.ctx.interactionOf(tab_build).clicked);
}

test "QA-15 Shift+Tab reverses the catalog traversal" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var scene = Scene.init(&rig.ctx);

    const a = key_of(0, "a");
    const b = key_of(0, "b");
    const c = key_of(0, "c");
    const controls = [_]Control{ .{ .key = a }, .{ .key = b }, .{ .key = c } };
    scene.frame(&controls, null);
    try testing.expect(rig.ctx.requestFocus(c));

    // Shift+Tab walks backward: c → b → a.
    try testing.expect(scene.tab(true).?.focus_moved);
    try testing.expectEqual(@as(?u64, b), scene.focusedKey());
    try testing.expect(scene.tab(true).?.focus_moved);
    try testing.expectEqual(@as(?u64, a), scene.focusedKey());
}

test "QA-15 a disabled control is skipped by keyboard traversal" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var scene = Scene.init(&rig.ctx);

    const a = key_of(0, "a");
    const disabled = key_of(0, "disabled");
    const c = key_of(0, "c");
    const controls = [_]Control{ .{ .key = a }, .{ .key = disabled, .enabled = false }, .{ .key = c } };
    scene.frame(&controls, null);
    try testing.expect(rig.ctx.requestFocus(a));

    // Tab from a skips the disabled control and lands on c.
    try testing.expect(scene.tab(false).?.focus_moved);
    try testing.expectEqual(@as(?u64, c), scene.focusedKey());
}
