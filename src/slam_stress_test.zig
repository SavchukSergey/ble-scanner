const std = @import("std");
const slam_mod = @import("slam.zig");
const widgets = @import("tui/widgets.zig");
const screen_mod = @import("tui/screen.zig");
const store_mod = @import("store.zig");

test "slam stress: pruning, late devices, render sizes" {
    const gpa = std.testing.allocator;
    var s = slam_mod.Slam.init(gpa);
    defer s.deinit();

    var rng: u32 = 42;
    var step: usize = 0;
    while (step < 60) : (step += 1) {
        s.beginStep();
        var dev: u64 = 0;
        while (dev < 70) : (dev += 1) {
            if (dev > step * 2) break;
            var x = rng;
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            rng = x;
            const noise = (@as(f32, @floatFromInt(x & 0xFFFF)) / 32768.0 - 1.0) * 0.15;
            const d = 2.0 + @as(f32, @floatFromInt(dev % 12)) * 1.7;
            s.observe(dev + 1, d * (1.0 + noise), @intCast(20 + step * 3 + dev));
        }
        s.solve(12);
    }
    try std.testing.expect(s.observerStepCount() <= slam_mod.max_observer_nodes);

    for (s.edges.items) |e| {
        try std.testing.expect(e.a < s.nodes.items.len);
        try std.testing.expect(e.b < s.nodes.items.len);
        try std.testing.expect(e.a != e.b);
    }
    for (s.nodes.items) |nd| {
        try std.testing.expect(std.math.isFinite(nd.x));
        try std.testing.expect(std.math.isFinite(nd.y));
    }

    var st = try store_mod.Store.init(gpa);
    defer st.deinit();
    var order: std.ArrayList(*store_mod.Entry) = .empty;
    defer order.deinit(gpa);

    const sizes = [_][2]u32{ .{ 80, 24 }, .{ 110, 28 }, .{ 135, 40 }, .{ 60, 20 }, .{ 42, 15 } };
    for (sizes) |sz| {
        var scr = try screen_mod.Screen.init(gpa, sz[0], sz[1]);
        defer scr.deinit();
        widgets.drawMap(&scr, &s, order.items, 0, 60, 123456, false);
        widgets.drawMap(&scr, &s, order.items, 0, 60, 123456, true);
    }
}
