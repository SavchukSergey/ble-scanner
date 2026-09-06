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

const testing = std.testing;

test "Kind.parse recognizes every CLI spelling and rejects garbage" {
    try testing.expectEqual(Kind.auto, Kind.parse("auto").?);
    try testing.expectEqual(Kind.linux_hci, Kind.parse("linux-hci").?);
    try testing.expectEqual(Kind.win_rt, Kind.parse("win-rt").?);
    try testing.expectEqual(Kind.win_ps, Kind.parse("win-ps").?);
    try testing.expectEqual(Kind.replay, Kind.parse("replay").?);
    try testing.expect(Kind.parse("bluetooth-magic") == null);
    try testing.expect(Kind.parse("") == null);
    // Case-sensitive: the CLI spellings are lowercase-hyphenated only.
    try testing.expect(Kind.parse("Auto") == null);
    try testing.expect(Kind.parse("WIN-RT") == null);
}

test "Kind.label roundtrips through parse for every variant" {
    // Catches a typo introduced in one of the two hand-maintained switch
    // tables (parse's map, label's switch) without the other following.
    inline for (@typeInfo(Kind).@"enum".fields) |f| {
        const k: Kind = @enumFromInt(f.value);
        try testing.expectEqual(k, Kind.parse(k.label()).?);
    }
}

test "defaultForOs resolves to a Kind that is actually implemented here" {
    try testing.expect(Kind.defaultForOs().implemented());
}

test "replay is implemented on every OS" {
    try testing.expect(Kind.replay.implemented());
}

test "auto reports implemented (it is resolved to a concrete kind before use)" {
    try testing.expect(Kind.auto.implemented());
}
