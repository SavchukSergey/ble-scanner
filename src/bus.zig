//! Event bus: single producer-consumer FIFO connecting backend threads and
//! the input thread to the main render loop.

const std = @import("std");
const model = @import("ble/model.zig");
const input = @import("tui/input.zig");

pub const Event = union(enum) {
    adv: *model.AdvEvent,
    key: input.Key,
    backend: BackendEvent,
};

/// Backend lifecycle notification. `msg` is owned by the producer and only
/// valid until the consumer handles the event (the App copies it).
pub const BackendEvent = struct {
    pub const Code = enum { started, stopped, failed };
    code: Code,
    msg: ?[]const u8 = null,
};

pub const Bus = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: std.ArrayList(Event) = .empty,
    /// Set by deinit; makes push() a no-op so detached threads holding a
    /// stale pointer at shutdown can't write into freed memory.
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(io: std.Io, gpa: std.mem.Allocator) Bus {
        return .{ .io = io, .gpa = gpa };
    }

    pub fn deinit(self: *Bus) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown.store(true, .release);
        self.queue.deinit(self.gpa);
        self.mutex.unlock(self.io);
    }

    /// Called from any thread. Wakes the consumer. No-op after deinit.
    pub fn push(self: *Bus, ev: Event) void {
        if (self.shutdown.load(.acquire)) {
            switch (ev) {
                .adv => |a| a.deinit(self.gpa),
                .key, .backend => {},
            }
            return;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.shutdown.load(.acquire)) {
            switch (ev) {
                .adv => |a| a.deinit(self.gpa),
                .key, .backend => {},
            }
            return;
        }
        self.queue.append(self.gpa, ev) catch {
            switch (ev) {
                .adv => |a| a.deinit(self.gpa),
                .key, .backend => {},
            }
            return;
        };
        self.cond.signal(self.io);
    }

    /// Drain everything pending into `out` (appended). Main thread only.
    pub fn popAll(self: *Bus, out: *std.ArrayList(Event)) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        out.appendSlice(self.gpa, self.queue.items) catch return;
        self.queue.clearRetainingCapacity();
    }

    pub fn pending(self: *Bus) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.queue.items.len;
    }
};

const testing = std.testing;

test "push then popAll preserves order and drains pending" {
    var bus = Bus.init(testing.io, testing.allocator);
    defer bus.deinit();

    bus.push(.{ .key = .{ .code = .char, .ch = 'a' } });
    bus.push(.{ .key = .{ .code = .char, .ch = 'b' } });
    bus.push(.{ .key = .{ .code = .char, .ch = 'c' } });
    try testing.expectEqual(@as(usize, 3), bus.pending());

    var out: std.ArrayList(Event) = .empty;
    defer out.deinit(testing.allocator);
    bus.popAll(&out);

    try testing.expectEqual(@as(usize, 0), bus.pending());
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqual(@as(u8, 'a'), out.items[0].key.ch);
    try testing.expectEqual(@as(u8, 'b'), out.items[1].key.ch);
    try testing.expectEqual(@as(u8, 'c'), out.items[2].key.ch);
}

test "popAll appends to existing contents instead of replacing them" {
    var bus = Bus.init(testing.io, testing.allocator);
    defer bus.deinit();

    var out: std.ArrayList(Event) = .empty;
    defer out.deinit(testing.allocator);
    out.append(testing.allocator, .{ .key = .{ .code = .char, .ch = 'z' } }) catch unreachable;

    bus.push(.{ .key = .{ .code = .char, .ch = 'y' } });
    bus.popAll(&out);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u8, 'z'), out.items[0].key.ch);
    try testing.expectEqual(@as(u8, 'y'), out.items[1].key.ch);
}

test "push after deinit frees an adv event instead of queuing it" {
    var bus = Bus.init(testing.io, testing.allocator);
    bus.deinit();

    // Ownership of ev transfers to push(); if the post-deinit path fails
    // to free it (or double-frees it), testing.allocator's leak/corruption
    // check at the end of this test catches it.
    const ev = testing.allocator.create(model.AdvEvent) catch unreachable;
    ev.* = .{
        .addr = .{ 1, 2, 3, 4, 5, 6 },
        .addr_type = .random,
        .adv_type = .connectable_undirected,
        .rssi = -50,
        .ts_ms = 0,
    };
    bus.push(.{ .adv = ev });
}

test "push after deinit is a no-op for key/backend events (no crash)" {
    var bus = Bus.init(testing.io, testing.allocator);
    bus.deinit();
    bus.push(.{ .key = .{ .code = .char, .ch = 'q' } });
    bus.push(.{ .backend = .{ .code = .stopped } });
}
