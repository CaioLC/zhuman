//! The session menu's slot list and settings panel, headless through the replay rig. The rig
//! has no window, but the rows carry text, so the test opens the real font (SDL_ttf needs no
//! window) and builds the real dialog; synthetic clicks and keys go through the router onto the
//! controls' stamped geometry, found by their accessible names.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const res_mod = ha.res;
const Screen = res_mod.MenuScreen;
const menu_dialog = @import("./menu_dialog.zig").menu_dialog;

const testing = std.testing;

const MenuFixture = struct {
    pub fn build(_: *MenuFixture, ctx: *uic.UiCtx) anyerror!uic.Trees {
        const r = try menu_dialog(ctx, "session_menu", .{ .act = 1, .day = 3, .people = 1 });
        const out = try ctx.arena.alloc(*uic.Node, 1);
        out[0] = r.root;
        return out;
    }
};

const MenuRig = struct {
    fonts: ha.font.Fonts,
    res: res_mod.Resources,
    arena: std.heap.ArenaAllocator,
    ui: uic.UiCtx,
    driver: uic.FrameDriver,
    fx: MenuFixture = .{},

    fn setUp(self: *MenuRig) !void {
        try ha.sdl.ttf.init();
        self.fonts = try ha.font.Fonts.init(testing.allocator, "assets/fonts/JetBrainsMonoNL-Regular.ttf", style.default_font);
        self.res = uic.replay.headlessResources();
        self.res.platform.font = &self.fonts;
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.ui = uic.UiCtx.init(&self.res, testing.allocator, self.arena.allocator());
        self.driver = uic.FrameDriver.init(&self.ui, &self.arena, testing.io, .none);
        self.fx = .{};
    }

    fn tearDown(self: *MenuRig) void {
        self.ui.deinit();
        self.arena.deinit();
        self.fonts.deinit();
        ha.sdl.ttf.quit();
    }

    /// Open the menu on the save screen and run two frames, so the rows are stamped.
    fn openSave(self: *MenuRig, r: *uic.Replay) !void {
        self.res.menu.show(&self.res.playback);
        self.res.menu.screen = .save;
        try r.idle(2);
    }

    /// Open the menu on the settings screen and run two frames, so the controls are stamped.
    fn openSettings(self: *MenuRig, r: *uic.Replay) !void {
        self.res.menu.show(&self.res.playback);
        self.res.menu.screen = .settings;
        try r.idle(2);
    }

    /// The semantic node of the control named `name`.
    fn node(self: *MenuRig, name: []const u8) !uic.SemanticNode {
        for (self.res.semantics.snapshot()) |n| {
            if (std.mem.eql(u8, n.labelText(), name)) return n;
        }
        return error.NoSuchControl;
    }

    /// The stamped box of the control named `name`.
    fn rect(self: *MenuRig, name: []const u8) !uic.Rect {
        return self.ui.rectOf((try self.node(name)).key) orelse error.NotStamped;
    }

    /// Click the centre of the control named `name`.
    fn click(self: *MenuRig, r: *uic.Replay, name: []const u8) !void {
        try self.clickAt(r, name, 0.5);
    }

    /// Click the control named `name` at fraction `f` of its width, on its vertical centre.
    fn clickAt(self: *MenuRig, r: *uic.Replay, name: []const u8, f: f32) !void {
        const box = try self.rect(name);
        const x = box.x + box.w * f;
        const y = box.y + box.h / 2;
        try r.frame(&.{ .{ .pointer_press = .{ .x = x, .y = y } }, .{ .pointer_release = .{ .x = x, .y = y } } });
    }

    fn key(_: *MenuRig, r: *uic.Replay, k: uic.replay.Keycode) !void {
        try r.frame(&.{.{ .key_press = .{ .key = k } }});
        try r.frame(&.{.{ .key_release = .{ .key = k } }});
    }
};

test "menu: a click on slot 1 of the save screen asks the host to save to slot 1, and returns to the menu" {
    var rig: MenuRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    rig.res.saves.dir = std.Io.Dir.cwd();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(MenuFixture, &rig.fx));
    try rig.openSave(&r);
    try testing.expectEqual(@as(?res_mod.SaveSlots.Request, null), rig.res.saves.request);
    try rig.click(&r, "Slot 1");
    try testing.expectEqual(@as(?res_mod.SaveSlots.Request, .{ .save = 0 }), rig.res.saves.request);
    try testing.expectEqual(Screen.menu, rig.res.menu.screen);
    try testing.expect(rig.res.menu.open);
}

/// The save screen with slot 2 filled, then a click on it: the overwrite screen, stamped.
fn openOverwrite(rig: *MenuRig, r: *uic.Replay) !void {
    rig.res.saves.dir = std.Io.Dir.cwd();
    rig.res.saves.slots[1] = .{ .filled = true, .act = 1, .day = 12, .people = 1 };
    try rig.openSave(r);
    try rig.click(r, "Slot 2");
    try r.idle(2);
}

test "menu: a click on a filled slot of the save screen asks for nothing and opens the overwrite screen" {
    var rig: MenuRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(MenuFixture, &rig.fx));
    try openOverwrite(&rig, &r);
    try testing.expectEqual(@as(?res_mod.SaveSlots.Request, null), rig.res.saves.request);
    try testing.expectEqual(Screen.overwrite, rig.res.menu.screen);
    try testing.expectEqual(@as(?u8, 1), rig.res.menu.overwrite_slot);
    _ = try rig.node("OVERWRITE");
    _ = try rig.node("CANCEL");
}

test "menu: OVERWRITE asks the host to save to the filled slot and returns to the menu" {
    var rig: MenuRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(MenuFixture, &rig.fx));
    try openOverwrite(&rig, &r);
    try rig.click(&r, "OVERWRITE");
    try testing.expectEqual(@as(?res_mod.SaveSlots.Request, .{ .save = 1 }), rig.res.saves.request);
    try testing.expectEqual(Screen.menu, rig.res.menu.screen);
    try testing.expect(rig.res.menu.open);
}

test "menu: CANCEL on the overwrite screen returns to the save screen and asks for nothing" {
    var rig: MenuRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(MenuFixture, &rig.fx));
    try openOverwrite(&rig, &r);
    try rig.click(&r, "CANCEL");
    try testing.expectEqual(@as(?res_mod.SaveSlots.Request, null), rig.res.saves.request);
    try testing.expectEqual(Screen.save, rig.res.menu.screen);
}

test "menu: Escape on the overwrite screen steps back to the save screen, not the menu" {
    var rig: MenuRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(MenuFixture, &rig.fx));
    try openOverwrite(&rig, &r);
    try rig.key(&r, .escape);
    try testing.expectEqual(@as(?res_mod.SaveSlots.Request, null), rig.res.saves.request);
    try testing.expectEqual(Screen.save, rig.res.menu.screen);
    try testing.expect(rig.res.menu.open);
    // A second Escape steps back from the save screen to the menu.
    try rig.key(&r, .escape);
    try testing.expectEqual(Screen.menu, rig.res.menu.screen);
    try testing.expect(rig.res.menu.open);
}

test "menu: an overwrite screen whose slot is no longer filled shows the save list" {
    var rig: MenuRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(MenuFixture, &rig.fx));
    try openOverwrite(&rig, &r);
    rig.res.saves.slots[1] = .{};
    try r.idle(1);
    try testing.expectEqual(Screen.save, rig.res.menu.screen);
    try testing.expectError(error.NoSuchControl, rig.node("OVERWRITE"));
}

test "menu: beside a filled slot an empty slot still saves in one click" {
    var rig: MenuRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    rig.res.saves.dir = std.Io.Dir.cwd();
    rig.res.saves.slots[1] = .{ .filled = true, .act = 1, .day = 12, .people = 1 };
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(MenuFixture, &rig.fx));
    try rig.openSave(&r);
    try rig.click(&r, "Slot 3");
    try testing.expectEqual(@as(?res_mod.SaveSlots.Request, .{ .save = 2 }), rig.res.saves.request);
    try testing.expectEqual(Screen.menu, rig.res.menu.screen);
}

test "menu: a click on a filled slot of the load screen loads it in one click" {
    var rig: MenuRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    rig.res.saves.dir = std.Io.Dir.cwd();
    rig.res.saves.slots[1] = .{ .filled = true, .act = 1, .day = 12, .people = 1 };
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(MenuFixture, &rig.fx));
    rig.res.menu.show(&rig.res.playback);
    rig.res.menu.screen = .load;
    try r.idle(2);
    try rig.click(&r, "Slot 2");
    try testing.expectEqual(@as(?res_mod.SaveSlots.Request, .{ .load = 1 }), rig.res.saves.request);
    try testing.expectEqual(Screen.menu, rig.res.menu.screen);
}

test "menu: with no saves folder a slot click asks for nothing" {
    var rig: MenuRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(MenuFixture, &rig.fx));
    try rig.openSave(&r);
    try rig.click(&r, "Slot 1");
    try testing.expectEqual(@as(?res_mod.SaveSlots.Request, null), rig.res.saves.request);
    try testing.expectEqual(Screen.save, rig.res.menu.screen);
}

test "settings: the rows run DIFFICULTY, TUTORIAL, MUSIC, EFFECTS, UI SCALE, BRIGHTNESS, CONTRAST, WINDOW down the panel" {
    var rig: MenuRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(MenuFixture, &rig.fx));
    try rig.openSettings(&r);
    // The first control of each row, in the prototype's order.
    const firsts = [_][]const u8{ "ABUNDANT", "ON", "Music volume", "Effects volume", "90%", "Brightness", "NORMAL", "1280\u{00d7}720" };
    var prev_y: f32 = -std.math.inf(f32);
    for (firsts) |name| {
        const box = try rig.rect(name);
        try testing.expect(box.y > prev_y);
        prev_y = box.y;
    }
}

test "settings: TUTORIAL is on and BRIGHTNESS 100% by default; a click on OFF holds the flag off" {
    var rig: MenuRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(MenuFixture, &rig.fx));
    try rig.openSettings(&r);
    try testing.expectEqual(res_mod.Settings.Tutorial.on, rig.res.settings.tutorial);
    try testing.expectEqual(@as(f32, 100), rig.res.settings.brightness);
    try testing.expectEqual(@as(f32, 1), rig.res.settings.brightnessFactor());
    try testing.expect((try rig.node("ON")).state.checked);
    try testing.expect(!(try rig.node("OFF")).state.checked);
    try rig.click(&r, "OFF");
    try r.idle(1);
    try testing.expectEqual(res_mod.Settings.Tutorial.off, rig.res.settings.tutorial);
    try testing.expect((try rig.node("OFF")).state.checked);
}

test "settings: a press along BRIGHTNESS lands on the 80..140 grid of fives, from its min at the left to its max at the right" {
    var rig: MenuRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(MenuFixture, &rig.fx));
    try rig.openSettings(&r);
    try rig.clickAt(&r, "Brightness", 0);
    try testing.expectEqual(@as(f32, 80), rig.res.settings.brightness);
    try rig.clickAt(&r, "Brightness", 0.999);
    try testing.expectEqual(@as(f32, 140), rig.res.settings.brightness);
    try rig.clickAt(&r, "Brightness", 0.5);
    try testing.expectEqual(@as(f32, 110), rig.res.settings.brightness);
    // 0.52 of the lane is 111.2: it snaps to 110, never a value off the grid.
    try rig.clickAt(&r, "Brightness", 0.52);
    try testing.expectEqual(@as(f32, 110), rig.res.settings.brightness);
    try rig.clickAt(&r, "Brightness", 0.55);
    try testing.expectEqual(@as(f32, 115), rig.res.settings.brightness);
    // The volumes keep their 0..100 range beside it.
    try testing.expectEqual(@as(f32, 60), rig.res.settings.music);
}

test "settings: the focused BRIGHTNESS slider steps by five on the arrows and stops at 80 and 140" {
    var rig: MenuRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(MenuFixture, &rig.fx));
    try rig.openSettings(&r);
    // A press focuses the slider (and sets it to the press's value, 110 at the middle).
    try rig.clickAt(&r, "Brightness", 0.5);
    try testing.expectEqual(@as(f32, 110), rig.res.settings.brightness);
    try rig.key(&r, .right);
    try testing.expectEqual(@as(f32, 115), rig.res.settings.brightness);
    try rig.key(&r, .left);
    try rig.key(&r, .left);
    try testing.expectEqual(@as(f32, 105), rig.res.settings.brightness);
    try rig.key(&r, .end);
    try testing.expectEqual(@as(f32, 140), rig.res.settings.brightness);
    try rig.key(&r, .right);
    try testing.expectEqual(@as(f32, 140), rig.res.settings.brightness);
    try rig.key(&r, .home);
    try testing.expectEqual(@as(f32, 80), rig.res.settings.brightness);
    try rig.key(&r, .left);
    try testing.expectEqual(@as(f32, 80), rig.res.settings.brightness);
}

test "settings: BRIGHTNESS's fill runs from its own min to its own max, (v - 80) / 60" {
    const B = res_mod.Settings.Brightness;
    const model = uic.UiState.SliderModel{ .min = B.min, .max = B.max, .step = B.step };
    var v: f32 = B.min;
    while (v <= B.max) : (v += B.step) {
        try testing.expectApproxEqAbs((v - 80) / 60, model.toFraction(v), 1e-6);
        try testing.expectEqual(v, model.snap(v));
    }
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), model.toFraction(100), 1e-6);
}
