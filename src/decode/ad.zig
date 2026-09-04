//! AD structure (GAP) decoder: walks the section list of an advertisement
//! and extracts the fields the UI cares about.

const std = @import("std");
const model = @import("../ble/model.zig");

const AdSection = model.AdSection;

/// Human name for an AD structure type byte; null → unknown.
pub fn sectionName(t: u8) ?[]const u8 {
    return switch (t) {
        0x01 => "Flags",
        0x02 => "Incomplete 16-bit service UUIDs",
        0x03 => "Complete 16-bit service UUIDs",
        0x04 => "Incomplete 32-bit service UUIDs",
        0x05 => "Complete 32-bit service UUIDs",
        0x06 => "Incomplete 128-bit service UUIDs",
        0x07 => "Complete 128-bit service UUIDs",
        0x08 => "Shortened local name",
        0x09 => "Complete local name",
        0x0A => "Tx power level",
        0x0D => "Class of device",
        0x10 => "Service data - 16-bit UUID",
        0x11 => "Service data - 32-bit UUID",
        0x12 => "Peripheral connection interval range",
        0x14 => "16-bit service UUIDs (list)" ,
        0x15 => "Service data - 128-bit UUID",
        0x16 => "Service data - 16-bit UUID",
        0x19 => "Appearance",
        0x1A => "Advertising interval",
        0x1B => "LE Bluetooth device address",
        0x1C => "LE role",
        0x1D => "Simple pairing hash C",
        0x1E => "Simple pairing randomizer R",
        0x1F => "16-bit service UUIDs (list)",
        0x20 => "32-bit service UUIDs (list)",
        0x21 => "128-bit service UUIDs (list)",
        0x22 => "32-bit service data (list)",
        0x24 => "128-bit service data (list)",
        0x3D => "3D information data",
        0xFF => "Manufacturer data",
        else => null,
    };
}

pub const Manufacturer = struct {
    company: u16,
    payload: []const u8,
};

/// First manufacturer-data section, with the LE u16 company id stripped.
pub fn manufacturer(sections: []const AdSection) ?Manufacturer {
    for (sections) |s| {
        if (s.typ == 0xFF and s.data.len >= 2) {
            return .{ .company = std.mem.readInt(u16, s.data[0..2], .little), .payload = s.data[2..] };
        }
    }
    return null;
}

/// Local name from 0x09/0x08 sections (lossy UTF-8 is handled by the UI).
pub fn localName(sections: []const AdSection) ?[]const u8 {
    var fallback: ?[]const u8 = null;
    for (sections) |s| {
        if (s.typ == 0x09 and s.data.len > 0) return s.data;
        if (s.typ == 0x08 and s.data.len > 0) fallback = s.data;
    }
    return fallback;
}

pub fn txPower(sections: []const AdSection) ?i8 {
    for (sections) |s| {
        if (s.typ == 0x0A and s.data.len >= 1) return @bitCast(s.data[0]);
    }
    return null;
}

pub fn flags(sections: []const AdSection) ?u8 {
    for (sections) |s| {
        if (s.typ == 0x01 and s.data.len >= 1) return s.data[0];
    }
    return null;
}

pub const ServiceData = struct {
    uuid: u16,
    data: []const u8,
};

/// First 16-bit service-data section (0x16).
pub fn serviceData16(sections: []const AdSection) ?ServiceData {
    for (sections) |s| {
        if (s.typ == 0x16 and s.data.len >= 2) {
            return .{ .uuid = std.mem.readInt(u16, s.data[0..2], .little), .data = s.data[2..] };
        }
    }
    return null;
}

/// Collect 16-bit service UUIDs from 0x02/0x03 sections into out; returns count.
pub fn serviceUuids16(sections: []const AdSection, out: []u16) usize {
    var n: usize = 0;
    for (sections) |s| {
        if ((s.typ == 0x02 or s.typ == 0x03) and s.data.len >= 2) {
            var i: usize = 0;
            while (i + 2 <= s.data.len and n < out.len) : (i += 2) {
                out[n] = std.mem.readInt(u16, s.data[i..][0..2], .little);
                n += 1;
            }
        }
    }
    return n;
}

/// Collect 32-bit service UUIDs from 0x04/0x05 sections (rare).
pub fn serviceUuids32(sections: []const AdSection, out: []u32) usize {
    var n: usize = 0;
    for (sections) |s| {
        if ((s.typ == 0x04 or s.typ == 0x05) and s.data.len >= 4) {
            var i: usize = 0;
            while (i + 4 <= s.data.len and n < out.len) : (i += 4) {
                out[n] = std.mem.readInt(u32, s.data[i..][0..4], .little);
                n += 1;
            }
        }
    }
    return n;
}

/// Collect 128-bit service UUIDs from 0x06/0x07 sections. Bytes are
/// little-endian on air; returned arrays are in display (big-endian) order.
pub fn serviceUuids128(sections: []const AdSection, out: [][16]u8) usize {
    var n: usize = 0;
    for (sections) |s| {
        if ((s.typ == 0x06 or s.typ == 0x07) and s.data.len >= 16) {
            var i: usize = 0;
            while (i + 16 <= s.data.len and n < out.len) : (i += 16) {
                for (0..16) |k| out[n][k] = s.data[i + 15 - k];
                n += 1;
            }
        }
    }
    return n;
}

/// GATT Appearance value (0x19 section) if present.
pub fn appearance(sections: []const AdSection) ?u16 {
    for (sections) |s| {
        if (s.typ == 0x19 and s.data.len >= 2) {
            return std.mem.readInt(u16, s.data[0..2], .little);
        }
    }
    return null;
}

pub const SecView = struct {
    typ: u8,
    data: []const u8,
};

/// Split a raw advertising-data blob ([len][type][payload…]…) into AD
/// structures (the format delivered by HCI advertising reports). len
/// includes the type byte. Malformed entries stop the scan; at most
/// out.len structures are written. Returns the number written.
pub fn splitSections(data: []const u8, out: []SecView) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < data.len and n < out.len) {
        const len = data[i];
        if (len == 0) break;
        if (i + 1 + len > data.len) break; // truncated
        out[n] = .{ .typ = data[i + 1], .data = data[i + 2 ..][0 .. len - 1] };
        n += 1;
        i += 1 + len;
    }
    return n;
}

pub fn flagDescriptions(f: u8, buf: *[96]u8) []const u8 {
    var w: usize = 0;
    if (f & 0x01 != 0) w += append(buf, w, "LE discoverable ");
    if (f & 0x02 != 0) w += append(buf, w, "general ");
    if (f & 0x04 == 0) {
        w += append(buf, w, "BR/EDR not supported ");
    } else {
        w += append(buf, w, "dual-mode ");
    }
    return std.mem.trim(u8, buf[0..w], " ");
}

fn append(buf: []u8, at: usize, s: []const u8) usize {
    const n = @min(s.len, buf.len - at);
    @memcpy(buf[at..][0..n], s[0..n]);
    return n;
}

test "splitSections" {
    // 02 01 06 | 04 FF 8F 03 58 | 00 (terminator) | garbage after
    const data = [_]u8{ 0x02, 0x01, 0x06, 0x04, 0xFF, 0x8F, 0x03, 0x58, 0x00, 0xAA, 0xBB };
    var out: [8]SecView = undefined;
    const n = splitSections(&data, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u8, 0x01), out[0].typ);
    try std.testing.expectEqualSlices(u8, &.{0x06}, out[0].data);
    try std.testing.expectEqual(@as(u8, 0xFF), out[1].typ);
    try std.testing.expectEqualSlices(u8, &.{ 0x8F, 0x03, 0x58 }, out[1].data);

    // truncated structure is dropped
    const trunc = [_]u8{ 0x05, 0x02, 0x01 };
    try std.testing.expectEqual(@as(usize, 0), splitSections(&trunc, &out));
}

test "service uuid collectors" {
    // Incomplete 16-bit list (0x02) + a 128-bit list (0x07).
    const secs = [_]AdSection{
        .{ .typ = 0x02, .data = &.{ 0x10, 0x13 } },
        .{ .typ = 0x07, .data = &[_]u8{
            0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0,
            0x4f, 0x54, 0x55, 0x41, 0x20, 0x44, 0x59, 0x42,
        } },
    };
    var u16s: [8]u16 = undefined;
    try std.testing.expectEqual(@as(usize, 1), serviceUuids16(&secs, &u16s));
    try std.testing.expectEqual(@as(u16, 0x1310), u16s[0]);

    var u128s: [2][16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), serviceUuids128(&secs, &u128s));
    // Display order spells "BYD " at the start.
    try std.testing.expectEqualSlices(u8, "BYD ", u128s[0][0..4]);
}

test "section extraction" {
    const secs = [_]AdSection{
        .{ .typ = 0x01, .data = &.{0x06} },
        .{ .typ = 0x09, .data = "Pixel 8" },
        .{ .typ = 0x0A, .data = &.{@bitCast(@as(i8, -4))} },
        .{ .typ = 0x03, .data = &.{ 0x0F, 0x18, 0x2C, 0xFE } },
        .{ .typ = 0xFF, .data = &.{ 0xE0, 0x00, 0x01, 0x84 } },
        .{ .typ = 0x16, .data = &.{ 0x2C, 0xFE, 0xAA } },
    };
    try std.testing.expectEqualStrings("Pixel 8", localName(&secs).?);
    try std.testing.expectEqual(@as(i8, -4), txPower(&secs).?);
    try std.testing.expectEqual(@as(u16, 0x00E0), manufacturer(&secs).?.company);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x84 }, manufacturer(&secs).?.payload);
    try std.testing.expectEqual(@as(u16, 0xFE2C), serviceData16(&secs).?.uuid);
    var uuids: [8]u16 = undefined;
    try std.testing.expectEqual(@as(usize, 2), serviceUuids16(&secs, &uuids));
    try std.testing.expectEqual(@as(u16, 0x180F), uuids[0]);
    try std.testing.expectEqual(@as(u8, 0x06), flags(&secs).?);
}
