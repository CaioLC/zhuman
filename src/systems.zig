const std = @import("std");
const font = @import("./font.zig");
const time = @import("./time.zig");
const Resources = @import("./res.zig").Resources;
const Producer = @import("./world.zig").Producer;
const Consumer = @import("./world.zig").Consumer;

pub fn tick_singletons(r: *Resources, dt: f32) void {
    r.counter.update(dt);
    r.timer.update(dt);
    r.calendar.update(dt);
}

pub fn aggregate_produce(producers: []const Producer, out: *font.TextData) void {
    var total: i32 = 0;
    for (producers) |p| total += p.value.get();
    out.update(std.fmt.bufPrint(&out.buf, "Produce: {d}", .{total}) catch "?");
}

pub fn aggregate_demand(consumers: []const Consumer, out: *font.TextData) void {
    var total: i32 = 0;
    for (consumers) |c| total += c.value.get();
    out.update(std.fmt.bufPrint(&out.buf, "Demand: {d}", .{total}) catch "?");
}

pub fn format_counter(c: *const time.Counter, out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Counter: {d:.0}", .{c.get()}) catch "?");
}

pub fn format_population(p: *const time.Accumulator(i32), out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Population: {d}", .{p.get()}) catch "?");
}

pub fn format_calendar(c: *const time.Counter, out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Calendar: {d:.0}", .{c.get()}) catch "?");
}

pub fn format_money(m: *const time.Accumulator(i32), out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Money: {d}", .{m.get()}) catch "?");
}

pub fn format_calories(c: *const time.Accumulator(i32), out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Calories: {d}", .{c.get()}) catch "?");
}

pub fn format_stockpile(s: *const time.Accumulator(i32), out: *font.TextData) void {
    out.update(std.fmt.bufPrint(&out.buf, "Stockpile: {d}", .{s.get()}) catch "?");
}
