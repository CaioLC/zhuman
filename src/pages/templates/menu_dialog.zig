//! `menu_dialog` — the session menu (`menu.html`) on the shared `dialog_frame`: the menu list
//! (Continue, Save, Load, Settings, Quit to menu), the save and load slot list, the shared
//! settings panel, and the quit confirmation. Opening pauses the simulation (`MenuState.show`);
//! Continue, × and Escape on the menu screen resume it. Escape on a sub-screen steps back to
//! the menu. Quit is the one destructive choice, so it is the one that confirms.
//!
//! A slot click asks the host for a save or a load (`SaveSlots.request`); the host applies it
//! between frames and leaves the flash the menu screen shows. With no saves folder every slot is
//! disabled and the footer says why.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const El = uic.elements.El;
const res_mod = ha.res;
const Screen = res_mod.MenuScreen;

const modal_mod = @import("./modal.zig");
const frame_mod = @import("./dialog_frame.zig");
const button_mod = @import("./button.zig");
const menu_list_mod = @import("./menu_list.zig");
const settings_mod = @import("./settings_panel.zig");

/// `.menu-dialog`: 620px wide.
const width: f32 = 620;
/// `.panel-body`'s cap.
const settings_width: f32 = 540;

/// The dialog's widths this frame: `min(620px, 100vw - 28px)`, its inner lane, and the settings
/// panel's 540px held inside that lane.
fn dims(ctx: *uic.UiCtx) struct { w: f32, inner: f32, settings: f32 } {
    const w = @min(width, ctx.res.view.metrics.terminal.w - 28);
    const inner = w - 2 * frame_mod.pad_x;
    return .{ .w = w, .inner = inner, .settings = @min(settings_width, inner) };
}
const slot_id_w: f32 = 8 * 6;

/// What the menu shows about the run behind it.
pub const Session = struct {
    act: u8,
    day: u64,
    people: u32,
};

pub const Result = struct {
    root: *uic.Node,
    /// Continue, × or Escape on the menu screen: close and resume.
    resumed: bool,
    /// The quit was confirmed.
    quit: bool,
    /// A setting the host applies changed this frame.
    changed: settings_mod.Changed,
};

fn actNumeral(act: u8) []const u8 {
    return switch (act) {
        1 => "I",
        2 => "II",
        3 => "III",
        else => "?",
    };
}

fn describe(buf: []u8, act: u8, day: u64, people: u32) []const u8 {
    return std.mem.print(buf, "Act {s} \u{00b7} Day {d} \u{00b7} population {d}", .{ actNumeral(act), day, people }) catch "?";
}

fn title(screen: Screen) []const u8 {
    return switch (screen) {
        .menu => "Paused",
        .save => "Save",
        .load => "Load",
        .settings => "Settings",
        .quit => "Quit to menu",
    };
}

fn footerNote(menu: *const res_mod.MenuState, saves: *const res_mod.SaveSlots) []const u8 {
    const unavailable = "Saving is unavailable: the save folder could not be opened.";
    return switch (menu.screen) {
        .menu => menu.flash() orelse "Escape resumes. The simulation is frozen while this is open.",
        .save => if (saves.dir == null) unavailable else "Saving writes the settlement as it stands at this moment.",
        .load => if (saves.dir == null) unavailable else "Loading discards the settlement in progress.",
        .settings => "Difficulty applies from the next day onward.",
        .quit => "",
    };
}

/// The sub-screens' head: BACK at the right (`.menu-dialog .panel-head`). Returns its click.
fn backHead(parent: El) !bool {
    const head = try parent.box("head", .{
        .w = .{ .fixed = dims(parent.ctx).inner }, .h = .fit_children,
        .flow = .{ .dir = .row, .main = .end, .cross = .center }, .margin = .{ .after = 11 },
    }, .{});
    const back = try button_mod.button_variant(head, "back", "BACK", true, .back);
    return back.consume(.clicked);
}

/// One `.slot` row. Returns its click.
fn slotRow(parent: El, i: usize, slot: res_mod.SaveSlots.Slot, saving: bool, available: bool) !bool {
    const ctx = parent.ctx;
    const enabled = available and (saving or slot.filled);
    const row = try parent.boxi("slot", i, .{
        .w = .{ .fixed = dims(ctx).inner - 18 }, .h = .fit_children,
        .flow = .{ .dir = .row, .cross = .center }, .gap = 11,
    }, .{style.pad_sym(9, 8)});
    var dbuf: [64]u8 = undefined;
    const what = if (slot.filled) describe(&dbuf, slot.act, slot.day, slot.people) else "empty";
    const verb = if (saving) (if (slot.filled) "OVERWRITE" else "SAVE HERE") else if (slot.filled) "LOAD" else "";
    var nbuf: [16]u8 = undefined;
    const q = row.control(.{ .enabled = enabled, .name = std.mem.print(&nbuf, "Slot {d}", .{i + 1}) catch "Slot", .role = .button, .value = what, .ring = false });
    row.set(.{}, .{slot_look});

    try row.label_fit("id", std.mem.print(&nbuf, "SLOT {d}", .{i + 1}) catch "SLOT", .{ .cell = .{ .mode = .clip, .width = slot_id_w } }, .{style.eyebrow_dim});
    const what_box = try row.box("what_box", .{ .w = .grow, .h = .fit_children }, .{});
    try what_box.label("what", what, .{ Style{ .font = 12 }, slot_what });
    if (verb.len > 0) {
        try row.label("verb", verb, .{ Style{ .font = 10, .tracking = 0.07 }, slot_verb });
    }
    return q.clicked;
}

/// A slot row's chrome: a line edge on the ground, line2 on the panel while hovered or
/// visibly focused (a disabled slot never lifts).
pub const slot_look = Style{ .outline_ink = .line, .fill_ink = .bg, .on = &.{.{ .when = .hover_focus, .outline_ink = .line2, .fill_ink = .panel }} };
/// What the slot holds, fg; line2 while the slot cannot be used.
pub const slot_what = Style{ .ink = .fg, .on = &.{.{ .when = .disabled, .ink = .line2 }} };
/// The slot's verb, accent; line2 while the slot cannot be used.
pub const slot_verb = Style{ .ink = .acc, .on = &.{.{ .when = .disabled, .ink = .line2 }} };

/// The slot list. A click asks the host for the save or the load and returns to the menu
/// screen, where the host's flash reports the outcome.
fn slotsScreen(parent: El, menu: *res_mod.MenuState, saves: *res_mod.SaveSlots, saving: bool) !void {
    if (try backHead(parent)) {
        menu.screen = .menu;
        return;
    }
    const list = try parent.box("slots", .{ .flow = .{ .dir = .column, .cross = .start }, .gap = 5 }, .{});
    for (saves.slots, 0..) |slot, i| {
        if (!try slotRow(list, i, slot, saving, saves.dir != null)) continue;
        const at: u8 = @intCast(i);
        saves.request = if (saving) .{ .save = at } else .{ .load = at };
        menu.flash_len = 0;
        menu.screen = .menu;
    }
}

const QuitChoice = enum { none, quit, save_first, cancel };

fn quitScreen(parent: El, saves: *const res_mod.SaveSlots, session: Session) !QuitChoice {
    const ctx = parent.ctx;
    const copy_style = Style{ .font = 12, .ink = .fg };

    const first = try parent.box("stands", .{ .flow = .{ .dir = .row, .cross = .center }, .margin = .{ .after = 4 } }, .{});
    try first.label("a", "The settlement stands at ", .{copy_style});
    try first.label("when", try ctx.arena.print("Act {s} \u{00b7} Day {d}", .{ actNumeral(session.act), session.day }), .{Style{ .font = 12, .ink = .warn }});
    try first.label("b", ".", .{copy_style});

    var dbuf: [64]u8 = undefined;
    const rest = if (saves.latest()) |i| blk: {
        const s = saves.slots[i];
        break :blk try ctx.arena.print("Your most recent save is slot {d}, {s} \u{2014} everything since then is lost.", .{ i + 1, describe(&dbuf, s.act, s.day, s.people) });
    } else "There is no save yet \u{2014} everything since the start is lost.";
    (try parent.text_fit("lost", rest, .{ .wrap = 52 * 7.2 })).set(.{ .margin = .{ .after = 14 } }, .{copy_style});

    const row = try parent.box("confirm", .{ .flow = .{ .dir = .row, .cross = .center }, .gap = 9 }, .{});
    const quit = try button_mod.button_variant(row, "quit", "QUIT TO MENU", true, .danger);
    const save_first = try button_mod.button_variant(row, "save_first", "SAVE FIRST", true, .secondary);
    const cancel = try button_mod.button_variant(row, "cancel", "CANCEL", true, .secondary);
    if (quit.consume(.clicked)) return .quit;
    if (save_first.consume(.clicked)) return .save_first;
    if (cancel.consume(.clicked)) return .cancel;
    return .none;
}

pub fn menu_dialog(ctx: *uic.UiCtx, id: []const u8, session: Session) !Result {
    const menu = &ctx.res.menu;
    const shown = menu.screen;
    const frame = try frame_mod.dialog_frame(ctx, .{
        .id = id,
        .width = dims(ctx).w,
        .kicker = try ctx.arena.print("PAUSED \u{00b7} ACT {s} \u{00b7} DAY {d}", .{ actNumeral(session.act), session.day }),
        .title = title(shown),
        .close_name = "Resume",
    });

    // `.menu-dialog .dialog-body`: 14px over, 15px aside, 16px under.
    const body = try frame.body.box("content", .{
        .w = .{ .fixed = dims(ctx).inner }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
    }, .{style.pad_each(14, frame_mod.pad_x, 16, frame_mod.pad_x)});

    var resumed = frame.close_clicked;
    var quit = false;
    var changed: settings_mod.Changed = .{};
    var initial_focus: ?u64 = null;
    // A body keyed by the screen, so a screen's controls never inherit another's focus/state.
    const screen_box = try body.box(@tagName(shown), .{ .flow = .{ .dir = .column, .cross = .start } }, .{});
    switch (shown) {
        .menu => {
            const list = try menu_list_mod.menu_list(screen_box, "menu", &.{
                .{ .id = "continue", .label = "Continue" },
                .{ .id = "save", .label = "Save" },
                .{ .id = "load", .label = "Load" },
                .{ .id = "settings", .label = "Settings" },
                .{ .id = "quit", .label = "Quit to menu" },
            }, .{ .font = 16, .top = 0 });
            initial_focus = list.first_key;
            if (list.clicked) |i| {
                menu.flash_len = 0;
                switch (i) {
                    0 => resumed = true,
                    1 => menu.screen = .save,
                    2 => menu.screen = .load,
                    3 => menu.screen = .settings,
                    else => menu.screen = .quit,
                }
            }
        },
        .save, .load => try slotsScreen(screen_box, menu, &ctx.res.saves, shown == .save),
        .settings => {
            if (try backHead(screen_box)) {
                menu.screen = .menu;
            } else {
                changed = try settings_mod.settings_panel(screen_box, "settings", &ctx.res.settings, .{ .width = dims(ctx).settings });
            }
        },
        .quit => switch (try quitScreen(screen_box, &ctx.res.saves, session)) {
            .quit => quit = true,
            .save_first => menu.screen = .save,
            .cancel => menu.screen = .menu,
            .none => {},
        },
    }

    const note = footerNote(menu, &ctx.res.saves);
    if (note.len > 0) try frame_mod.dialog_note(frame.footer, "note", note, dims(ctx).inner);

    const outcome = modal_mod.settle(ctx, frame.modal, .{
        .owned = resumed or quit,
        .initial_focus = initial_focus,
        .escape_steps_back = shown != .menu,
    });
    if (outcome.back) menu.screen = .menu;
    // Escape on the menu screen closes the dialog: that is a resume, as the footer says.
    if (outcome.closed and !quit) resumed = true;

    return .{ .root = frame.modal.root, .resumed = resumed, .quit = quit, .changed = changed };
}
