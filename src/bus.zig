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

    pub fn init(io: std.Io, gpa: std.mem.Allocator) Bus {
        return .{ .io = io, .gpa = gpa };
    }

    pub fn deinit(self: *Bus) void {
        self.queue.deinit(self.gpa);
    }

    /// Called from any thread. Wakes the consumer.
    pub fn push(self: *Bus, ev: Event) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.queue.append(self.gpa, ev) catch {
            // Out of memory: drop a key event, or an adv event (freeing it)
            // rather than dying — the UI keeps running.
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
