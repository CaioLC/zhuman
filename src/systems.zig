const std = @import("std");
const comp = @import("./components.zig");
const tag = @import("./tags.zig");
const ecs = @import("./ecs.zig");
const res_mod = @import("./res.zig");

pub fn update_counter(
    time: ecs.Res(res_mod.Time),
    q: ecs.Query(.{ comp.Counter, ecs.With(tag.Player) }),
) void {
    const dt = time.get().dt;
    var it = q.iter();
    while (it.next()) |c| {
        c.buffer += dt;
        if (c.buffer >= c.multiplier) {
            c.v += 1;
            c.buffer -= c.multiplier;
        }
    }
}
