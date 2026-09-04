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
