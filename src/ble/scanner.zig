//! Scanner backend factory. replay (any OS), win-rt (Windows, native
//! WinRT COM), win-ps (Windows, embedded PowerShell fallback) and
//! linux-hci (raw HCI socket) are implemented.

const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum {
    auto,
    linux_hci,
    win_rt,
    win_ps,
    replay,

    pub fn parse(s: []const u8) ?Kind {
        const map = .{
            .{ "auto", .auto },
            .{ "linux-hci", .linux_hci },
            .{ "win-rt", .win_rt },
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
            .win_rt => "win-rt",
            .win_ps => "win-ps",
            .replay => "replay",
        };
    }

    /// What `auto` resolves to on this OS.
    pub fn defaultForOs() Kind {
        return switch (builtin.os.tag) {
            .linux => .linux_hci,
            .windows => .win_rt, // native COM; win-ps (PS + C#) remains selectable
            else => .replay,
        };
    }

    /// Backends that are implemented on this OS.
    pub fn implemented(self: Kind) bool {
        return switch (self) {
            .replay => true,
            .win_rt => builtin.os.tag == .windows,
            .win_ps => builtin.os.tag == .windows,
            .linux_hci => builtin.os.tag == .linux,
            .auto => true,
        };
    }
};
