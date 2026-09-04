//! Scanner backend factory. replay (any OS), win-ps (Windows, via an
//! embedded PowerShell + WinRT watcher) and linux-hci (raw HCI socket) are
//! implemented.

const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum {
    auto,
    linux_hci,
    win_ps,
    replay,

    pub fn parse(s: []const u8) ?Kind {
        const map = .{
            .{ "auto", .auto },
            .{ "linux-hci", .linux_hci },
            .{ "win-ps", .win_ps },
            .{ "replay", .replay },
        };
        inline for (map) |e| {
            if (std.mem.eql(u8, s, e[0])) return e[1];
        }
        return null;
    }

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .auto => "auto",
            .linux_hci => "linux-hci",
            .win_ps => "win-ps",
            .replay => "replay",
        };
    }

    /// What `auto` resolves to on this OS.
    pub fn defaultForOs() Kind {
        return switch (builtin.os.tag) {
            .linux => .linux_hci,
            .windows => .win_ps,
            else => .replay,
        };
    }

    /// Backends that are implemented on this OS.
    pub fn implemented(self: Kind) bool {
        return switch (self) {
            .replay => true,
            .win_ps => builtin.os.tag == .windows,
            .linux_hci => builtin.os.tag == .linux,
            .auto => true,
        };
    }
};
