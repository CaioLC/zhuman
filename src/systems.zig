const std = @import("std");
const font = @import("./font.zig");
const comp = @import("./components.zig");
const Resources = @import("./res.zig").Resources;

pub fn tick_singletons(r: *Resources, dt: f32) void {
    advance_counter(&r.counter, dt);
    advance_counter(&r.calendar, dt);
    advance_timer(&r.timer, dt);
}

pub fn advance_counter(c: *comp.Counter, dt: f32) void {
    c.v += dt;
}

pub fn advance_timer(t: *comp.Timer, dt: f32) void {
    if (t.v > t.end) t.v -= dt;
    if (t.v < t.end) t.v = t.end;
}

pub fn format_counter(c: *const comp.Counter, out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Counter: {d:.0}", .{c.v}) catch "?");
}

pub fn format_population(p: *const i32, out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Population: {d}", .{p.*}) catch "?");
}

pub fn format_calendar(c: *const comp.Counter, out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Calendar: {d:.0}", .{c.v}) catch "?");
}

pub fn format_money(m: *const i32, out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Money: {d}", .{m.*}) catch "?");
}

pub fn format_calories(c: *const i32, out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Calories: {d}", .{c.*}) catch "?");
}

pub fn format_stockpile(s: *const i32, out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Stockpile: {d}", .{s.*}) catch "?");
}
