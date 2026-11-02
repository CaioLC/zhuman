//! The session menu's slot list, headless through the replay rig. The rig has no window, but
//! the slot rows carry text, so the test opens the real font (SDL_ttf needs no window) and builds
//! the real dialog; synthetic clicks go through the router onto the rows' stamped geometry,
//! found by their accessible names.

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

    /// Click the centre of the control named `name`.
    fn click(self: *MenuRig, r: *uic.Replay, name: []const u8) !void {
        const key = for (self.res.semantics.snapshot()) |n| {
            if (std.mem.eql(u8, n.labelText(), name)) break n.key;
        } else return error.NoSuchControl;
        const rect = self.ui.rectOf(key) orelse return error.NotStamped;
        const x = rect.x + rect.w / 2;
        const y = rect.y + rect.h / 2;
        try r.frame(&.{ .{ .pointer_press = .{ .x = x, .y = y } }, .{ .pointer_release = .{ .x = x, .y = y } } });
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
