//! Device-type database: rules that turn raw advertisement fingerprints
//! into a device Kind + label. This is THE place to add device types
//! observed in the wild (see README):
//!
//!   1. run `ble-scanner --seconds 30 --log wild.jsonl`
//!   2. inspect the device's manufacturer/service data in the detail view
//!   3. append a Rule below (and optionally a vendor decoder in
//!      decode/vendors.zig); the first matching rule wins
//!   4. `zig build test` keeps the tables honest

const std = @import("std");
const appearance_db = @import("appearance.zig");

pub const Kind = enum {
    // beacon / framework formats (highest precedence)
    ibeacon,
    eddystone,
    continuity,
    fast_pair,
    exposure,
    cdp,
    xiaomi,

    // generic categories (from appearance / services)
    watch,
    band,
    headphones,
    tracker,
    phone,
    computer,
    tv,
    keyboard,
    mouse,
    hid,
    thermometer,
    heart_rate,
    scale,
    blood_pressure,
    glucose,
    cycling,
    sensor,
    lock,
    light,
    appliance,
    car,
    unknown,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .ibeacon => "iBeacon",
            .eddystone => "Eddystone beacon",
            .continuity => "Apple Continuity",
            .fast_pair => "Fast Pair",
            .exposure => "Exposure Notification",
            .cdp => "Microsoft CDP",
            .xiaomi => "Xiaomi device",
            .watch => "watch",
            .band => "fitness band",
            .headphones => "headphones",
            .tracker => "tracker tag",
            .phone => "phone",
            .computer => "computer",
            .tv => "TV",
            .keyboard => "keyboard",
            .mouse => "mouse",
            .hid => "HID device",
            .thermometer => "thermometer",
            .heart_rate => "heart-rate sensor",
            .scale => "scale",
            .blood_pressure => "blood-pressure monitor",
            .glucose => "glucose meter",
            .cycling => "cycling sensor",
            .sensor => "sensor",
            .lock => "lock",
            .light => "light",
            .appliance => "appliance",
            .car => "car",
            .unknown => "unknown",
        };
    }
};

pub const Rule = struct {
    /// Manufacturer company id (0xFF section); null = don't care.
    company: ?u16 = null,
    /// Bytes that must follow the company id (hex prefix match).
    prefix: []const u8 = &.{},
    /// Service-data or advertised 16-bit service UUID.
    svc: ?u16 = null,
    /// Case-insensitive prefix of the advertised name.
    name_prefix: ?[]const u8 = null,
    kind: Kind,
    /// Extra hint shown in the list/detail beyond kind.label().
    detail: ?[]const u8 = null,
};

/// Ordered rule table; first match wins.
pub const rules = [_]Rule{
    // Apple Continuity: 0x004C type 0x02 + 0x15/0x16 = iBeacon, rest = Continuity.
    .{ .company = 0x004C, .prefix = &.{0x02, 0x15}, .kind = .ibeacon },
    .{ .company = 0x004C, .prefix = &.{0x02, 0x16}, .kind = .ibeacon },
    .{ .company = 0x004C, .prefix = &.{0x07}, .kind = .continuity, .detail = "AirPods nearby" },
    // Nearby Info (0x12): Find My network participation beacons.
    .{ .company = 0x004C, .prefix = &.{0x12}, .kind = .continuity, .detail = "Find My nearby" },
    .{ .company = 0x004C, .kind = .continuity },

    // Google Fast Pair / Eddystone, Exposure Notification (shared UUID),
    // Microsoft CDP (Swift Pair).
    .{ .svc = 0xFE2C, .kind = .fast_pair },
    .{ .svc = 0xFEAA, .kind = .eddystone },
    .{ .svc = 0xFD6F, .kind = .exposure },
    .{ .company = 0x0006, .kind = .cdp, .detail = "Swift Pair" },

    // Google Find My Device network + Quick Share/Nearby Share beacons.
    .{ .svc = 0xFEF3, .kind = .tracker, .detail = "Find My Device network" },
    .{ .svc = 0xFCF1, .kind = .tracker, .detail = "Quick Share / Nearby" },

    // Samsung SmartThings Find network beacon.
    .{ .svc = 0xFD69, .kind = .tracker, .detail = "SmartThings Find" },

    // Zebra BLE barcode scanners.
    .{ .svc = 0xFE79, .kind = .hid, .detail = "barcode scanner" },

    // Xiaomi ecosystem.
    .{ .svc = 0xFE95, .kind = .xiaomi },
    .{ .company = 0x038F, .kind = .xiaomi },

    // Apple 0xFCB2 service-data beacons (undocumented Apple service).
    .{ .svc = 0xFCB2, .kind = .unknown, .detail = "Apple service" },

    // Name-identifiable wearables (checked against the advertised name).
    .{ .name_prefix = "WHOOP", .kind = .band, .detail = "WHOOP fitness band" },
    .{ .name_prefix = "Mi Smart Band", .kind = .band, .detail = "Mi Band" },
    .{ .name_prefix = "Mi Band", .kind = .band, .detail = "Mi Band" },
    .{ .name_prefix = "Amazfit", .kind = .band, .detail = "Amazfit" },
    .{ .name_prefix = "Galaxy Watch", .kind = .watch, .detail = "Samsung Galaxy Watch" },
    .{ .name_prefix = "Galaxy Buds", .kind = .headphones, .detail = "Galaxy Buds" },
    .{ .name_prefix = "BYD", .kind = .car, .detail = "BYD (digital key)" },

    // Known wearable vendors (no appearance/service hints needed).
    .{ .company = 0x0087, .kind = .watch, .detail = "Garmin" },
    .{ .company = 0x0157, .kind = .band, .detail = "Amazfit" },
};

/// GATT Appearance category id → (Kind, detail label).
pub const appearance_kinds = [_]struct { cat: u8, kind: Kind }{
    .{ .cat = 0x01, .kind = .phone },
    .{ .cat = 0x02, .kind = .computer },
    .{ .cat = 0x03, .kind = .watch },
    .{ .cat = 0x0C, .kind = .thermometer },
    .{ .cat = 0x0D, .kind = .heart_rate },
    .{ .cat = 0x0E, .kind = .blood_pressure },
    .{ .cat = 0x0F, .kind = .hid },
    .{ .cat = 0x10, .kind = .glucose },
    .{ .cat = 0x11, .kind = .sensor },
    .{ .cat = 0x12, .kind = .cycling },
    .{ .cat = 0x14, .kind = .watch },
    .{ .cat = 0x15, .kind = .sensor },
    .{ .cat = 0x18, .kind = .band },
    .{ .cat = 0x19, .kind = .scale },
    .{ .cat = 0x1B, .kind = .appliance },
    .{ .cat = 0x1C, .kind = .appliance },
    .{ .cat = 0x1F, .kind = .car },
    .{ .cat = 0x22, .kind = .tv },
    .{ .cat = 0x24, .kind = .hid },
    .{ .cat = 0x25, .kind = .tracker },
    .{ .cat = 0x27, .kind = .sensor },
    .{ .cat = 0x2A, .kind = .headphones },
    .{ .cat = 0x2B, .kind = .light },
    .{ .cat = 0x2D, .kind = .lock },
    .{ .cat = 0x32, .kind = .light },
};

/// Service-UUID heuristics (checked when neither rules nor appearance hit).
pub const svc_kinds = [_]struct { svc: u16, kind: Kind }{
    .{ .svc = 0x1812, .kind = .hid },
    .{ .svc = 0x180D, .kind = .heart_rate },
    .{ .svc = 0x1809, .kind = .thermometer },
    .{ .svc = 0x181A, .kind = .sensor },
    .{ .svc = 0x181D, .kind = .scale }, // Weight Scale
    .{ .svc = 0x1810, .kind = .blood_pressure },
    .{ .svc = 0x1808, .kind = .glucose },
};

/// HID appearance subcategories worth calling out directly.
pub fn hidSubkind(sub: u8) ?Kind {
    return switch (sub) {
        0x01 => .keyboard,
        0x02 => .mouse,
        else => null,
    };
}

/// Appearance value → refined kind (keyboard/mouse for HID subs).
pub fn kindForAppearance(appearance: u16) ?Kind {
    const cat: u8 = @intCast(appearance >> 6);
    const sub: u8 = @intCast(appearance & 0x3F);
    if (cat == 0x0F) {
        if (hidSubkind(sub)) |k| return k;
    }
    for (appearance_kinds) |a| {
        if (a.cat == cat) return a.kind;
    }
    return null;
}

test "rule sanity: ibeacon before generic continuity" {
    // The first two rules must be the iBeacon prefixes so the generic
    // 0x004C rule doesn't shadow them.
    try std.testing.expectEqual(Kind.ibeacon, rules[0].kind);
    try std.testing.expectEqual(Kind.continuity, rules[2].kind);
}

test "appearance mapping" {
    try std.testing.expectEqual(Kind.phone, kindForAppearance(0x0040).?);
    try std.testing.expectEqual(Kind.keyboard, kindForAppearance(0x03C1).?);
    try std.testing.expectEqual(Kind.thermometer, kindForAppearance(0x0300).?);
    try std.testing.expect(kindForAppearance(0) == null);
    _ = appearance_db;
}
