const std = @import("std");
const font = @import("./font.zig");
const time = @import("./time.zig");
const Resources = @import("./res.zig").Resources;
const Producer = @import("./world.zig").Producer;
const Consumer = @import("./world.zig").Consumer;

pub fn tick_singletons(r: *Resources, dt: f32) void {
    advance_counter(&r.counter, dt);
    advance_counter(&r.calendar, dt);
    advance_timer(&r.timer, dt);
}

pub fn advance_counter(c: *time.Counter, dt: f32) void {
    c.v += dt;
}

pub fn advance_timer(t: *time.Timer, dt: f32) void {
    if (t.v > t.end) t.v -= dt;
    if (t.v < t.end) t.v = t.end;
}

pub fn aggregate_produce(producers: []const Producer, out: *font.TextData) void {
    var total: i32 = 0;
    for (producers) |p| total += p.value.v;
    out.update(std.fmt.bufPrint(&out.buf, "Produce: {d}", .{total}) catch "?");
}

pub fn aggregate_demand(consumers: []const Consumer, out: *font.TextData) void {
    var total: i32 = 0;
    for (consumers) |c| total += c.value.v;
    out.update(std.fmt.bufPrint(&out.buf, "Demand: {d}", .{total}) catch "?");
}

pub fn format_counter(c: *const time.Counter, out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Counter: {d:.0}", .{c.v}) catch "?");
}

pub fn format_population(p: *const time.Accumulator(i32), out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Population: {d}", .{p.v}) catch "?");
}

pub fn format_calendar(c: *const time.Counter, out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Calendar: {d:.0}", .{c.v}) catch "?");
}

pub fn format_money(m: *const time.Accumulator(i32), out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Money: {d}", .{m.v}) catch "?");
}

pub fn format_calories(c: *const time.Accumulator(i32), out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Calories: {d}", .{c.v}) catch "?");
}

pub fn format_stockpile(s: *const time.Accumulator(i32), out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Stockpile: {d}", .{s.v}) catch "?");
}
