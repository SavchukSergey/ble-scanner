//! Platform-neutral BLE advertisement model. Every backend (raw HCI on Linux,
//! WinRT watcher on Windows, replay files) normalizes into these types, which
//! is the single contract between capture and decoding/UI.

const std = @import("std");

pub const AddrType = enum(u1) {
    public = 0,
    random = 1,
};

/// Advertisement PDU type (legacy report event types cover the common cases).
pub const AdvType = enum {
    connectable_undirected,
    connectable_directed,
    scannable_undirected,
    non_connectable_undirected,
    scan_response,

    /// HCI legacy advertising report evt_type byte (0..4).
    pub fn fromHci(t: u8) ?AdvType {
        return switch (t) {
            0 => .connectable_undirected,
            1 => .connectable_directed,
            2 => .scannable_undirected,
            3 => .non_connectable_undirected,
            4 => .scan_response,
            else => null,
        };
    }

    /// WinRT AdvertisementType enum name (used by the Windows backend + replay files).
    pub fn fromWinName(s: []const u8) ?AdvType {
        const map = .{
            .{ "ConnectableUndirected", .connectable_undirected },
            .{ "ConnectableDirected", .connectable_directed },
            .{ "ScannableUndirected", .scannable_undirected },
            .{ "NonConnectableUndirected", .non_connectable_undirected },
            .{ "ScanResponse", .scan_response },
        };
        inline for (map) |e| {
            if (std.mem.eql(u8, s, e[0])) return e[1];
        }
        return null;
    }

    pub fn short(self: AdvType) []const u8 {
        return switch (self) {
            .connectable_undirected => "ADV",
            .connectable_directed => "DIR",
            .scannable_undirected => "SCAN",
            .non_connectable_undirected => "NCON",
            .scan_response => "RSP",
        };
    }
};

/// One AD structure from the advertising payload: [type][data...].
pub const AdSection = struct {
    typ: u8,
    data: []const u8,
};

/// A single observed advertisement event. Heap-allocated by the backend,
/// ownership transfers through the event bus to the app, which copies what it
/// needs into the store and then frees the event.
pub const AdvEvent = struct {
    /// Address in display order: addr[0] is the most significant byte.
    addr: [6]u8,
    addr_type: AddrType,
    adv_type: AdvType,
    rssi: i8,
    /// Explicit local name if the backend provides one (WinRT), otherwise
    /// the store falls back to parsing the 0x09/0x08 sections.
    name: ?[]const u8 = null,
    tx_power: ?i8 = null,
    sections: []const AdSection = &.{},
    ts_ms: i64,

    /// Single backing allocation for name + all section payloads (sections
    /// array is a separate allocation). deinit frees both.
    backing: []u8 = &.{},

    pub fn deinit(self: *AdvEvent, alloc: std.mem.Allocator) void {
        if (self.backing.len > 0) alloc.free(self.backing);
        if (self.sections.len > 0) alloc.free(self.sections);
        alloc.destroy(self);
    }
};

/// Parse "AA:BB:CC:DD:EE:FF" (colons optional, hex, case-insensitive).
pub fn parseMac(s: []const u8) ?[6]u8 {
    var out: [6]u8 = undefined;
    var oi: usize = 0;
    var hi: ?u8 = null;
    for (s) |c| {
        if (c == ':' or c == '-') continue;
        const d = std.fmt.charToDigit(c, 16) catch return null;
        if (hi) |h| {
            if (oi >= 6) return null;
            out[oi] = (h << 4) | d;
            oi += 1;
            hi = null;
        } else {
            hi = d;
        }
    }
    if (oi != 6 or hi != null) return null;
    return out;
}

/// Format addr into "AA:BB:CC:DD:EE:FF" (buf must be >= 17 bytes).
pub fn formatMac(addr: [6]u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
        addr[0], addr[1], addr[2], addr[3], addr[4], addr[5],
    }) catch unreachable;
}

/// Stable map key for (addr, addr_type).
pub fn addrKey(addr: [6]u8, t: AddrType) u64 {
    var k: u64 = @intFromEnum(t);
    for (addr) |b| k = (k << 8) | b;
    return k;
}

pub fn hexByte(b: u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{X:0>2}", .{b}) catch unreachable;
}

/// Lowercase-hex encode data into buf; returns the written slice (may be
/// truncated if buf is too small — caller sizes it).
pub fn hexEncode(data: []const u8, buf: []u8) []const u8 {
    const n = @min(data.len * 2, buf.len / 2 * 2);
    var i: usize = 0;
    while (i < n / 2) : (i += 1) {
        _ = std.fmt.bufPrint(buf[i * 2 ..][0..2], "{x:0>2}", .{data[i]}) catch unreachable;
    }
    return buf[0..n];
}

test "parseMac / formatMac / addrKey" {
    const a = parseMac("c8:47:8c:11:22:33").?;
    try std.testing.expectEqualSlices(u8, &.{ 0xC8, 0x47, 0x8C, 0x11, 0x22, 0x33 }, &a);
    var buf: [17]u8 = undefined;
    try std.testing.expectEqualStrings("C8:47:8C:11:22:33", formatMac(a, &buf));
    try std.testing.expect(parseMac("zz") == null);
    try std.testing.expectEqual(addrKey(a, .random), addrKey(a, .random));
    try std.testing.expect(addrKey(a, .random) != addrKey(a, .public));
}

test "AdvType roundtrip" {
    try std.testing.expectEqual(AdvType.scan_response, AdvType.fromWinName("ScanResponse").?);
    try std.testing.expectEqual(AdvType.connectable_undirected, AdvType.fromHci(0).?);
    try std.testing.expect(AdvType.fromHci(9) == null);
}
