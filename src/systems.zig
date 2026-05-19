const std = @import("std");
const comp = @import("./components.zig");
const tag = @import("./tags.zig");
const ecs = @import("./ecs.zig");
const res_mod = @import("./res.zig");

const Resources = res_mod.Resources;
const Query = ecs.Query;
const With = ecs.With;

pub fn update_counter(
    res: *Resources,
    q: Query(.{ comp.Counter }),
) void {
    const dt = res.time.dt;
    var it = q.iter();
    while (it.next()) |c| {
        c.buffer += dt;
        if (c.buffer >= c.multiplier) {
            c.v += 1;
            c.buffer -= c.multiplier;
        }
    }
}
