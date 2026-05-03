const std = @import("std");
const font = @import("./font.zig");
const Singletons = @import("./singletons.zig").Singletons;
const Producer = @import("./world.zig").Producer;
const Consumer = @import("./world.zig").Consumer;

pub fn tick_singletons(s: *Singletons, dt: f32) void {
    s.counter.update(dt);
    s.timer.update(dt);
    s.calendar.update(dt);
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

pub fn format_singletons(s: *Singletons) void {
    s.counter_display.update(std.fmt.bufPrint(&s.counter_display.buf, "Counter: {d:.0}", .{s.counter.get()}) catch "?");
    s.population_display.update(std.fmt.bufPrint(&s.population_display.buf, "Population: {d}", .{s.population.get()}) catch "?");
    s.calendar_display.update(std.fmt.bufPrint(&s.calendar_display.buf, "Calendar: {d:.0}", .{s.calendar.get()}) catch "?");
    s.money_display.update(std.fmt.bufPrint(&s.money_display.buf, "Money: {d}", .{s.money.get()}) catch "?");
    s.calories_display.update(std.fmt.bufPrint(&s.calories_display.buf, "Calories: {d}", .{s.calories.get()}) catch "?");
    s.stockpile_display.update(std.fmt.bufPrint(&s.stockpile_display.buf, "Stockpile: {d}", .{s.stockpile.get()}) catch "?");
}
