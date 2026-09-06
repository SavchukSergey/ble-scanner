//! Device classification: turns raw advertisement sections into a device
//! kind + label by running the rule table in db/devices.zig, then falling
//! back to the GATT appearance and service-UUID heuristics.

const std = @import("std");
const ad = @import("ad.zig");
const companies = @import("../db/companies.zig");
const services = @import("../db/services.zig");
const devices = @import("../db/devices.zig");
const model = @import("../ble/model.zig");

pub const Kind = devices.Kind;
pub const Match = devices.Rule;

/// Best-effort classification of one advertisement. `name` is the device's
/// current name (explicit or parsed from the 0x09/0x08 section) and is used
/// by name-prefix rules.
pub fn classify(sections: []const model.AdSection, name: []const u8) Match {
    const mfr = ad.manufacturer(sections);
    const sd = ad.serviceData16(sections);
    var svc: ?u16 = null;
    if (sd) |s| {
        svc = s.uuid;
    } else {
        var uuids: [16]u16 = undefined;
        const n = ad.serviceUuids16(sections, &uuids);
        if (n > 0) svc = uuids[0];
    }

    // 1. Rule table (first match wins; name rules only for named devices).
    for (devices.rules) |r| {
        if (r.name_prefix) |np| {
            if (name.len >= np.len and std.ascii.startsWithIgnoreCase(name, np)) return r;
            continue;
        }
        if (r.company) |c| {
            if (mfr == null or mfr.?.company != c) continue;
            if (r.prefix.len > 0) {
                const p = mfr.?.payload;
                if (p.len < r.prefix.len or !std.mem.eql(u8, p[0..r.prefix.len], r.prefix)) continue;
            }
            return r;
        }
        if (r.svc) |s| {
            if (svc == null or svc.? != s) continue;
            return r;
        }
    }

    // 2. GATT appearance.
    if (ad.appearance(sections)) |ap| {
        if (devices.kindForAppearance(ap)) |k| {
            // Prefer the appearance's own name as detail.
            var m = Match{ .kind = k };
            const ap_name = @import("../db/appearance.zig").nameFor(ap);
            if (!std.mem.eql(u8, ap_name, k.label())) m.detail = ap_name;
            return m;
        }
    }

    // 3. Service heuristics.
    var uuids: [16]u16 = undefined;
    const n = ad.serviceUuids16(sections, &uuids);
    for (uuids[0..n]) |u| {
        for (devices.svc_kinds) |s| {
            if (s.svc == u) return .{ .kind = s.kind };
        }
    }

    return .{ .kind = .unknown };
}

/// Company name for the list column: explicit manufacturer company if
/// present, else the vendor service-UUID owner, else null.
pub fn companyHint(sections: []const model.AdSection) ?[]const u8 {
    if (ad.manufacturer(sections)) |m| {
        return companies.lookup(m.company);
    }
    var uuids: [16]u16 = undefined;
    const n = ad.serviceUuids16(sections, &uuids);
    if (n > 0) return services.lookup(uuids[0]);
    if (ad.serviceData16(sections)) |sd| {
        return services.lookup(sd.uuid);
    }
    return null;
}

// --- iBeacon -------------------------------------------------------------------

pub const IBeacon = struct {
    uuid: [16]u8,
    major: u16,
    minor: u16,
    tx_1m: i8,
};

/// Parse an iBeacon manufacturer payload (company id already stripped):
/// type=0x02 len=0x15 uuid major minor tx.
pub fn parseIBeacon(m: ad.Manufacturer) ?IBeacon {
    if (m.payload.len < 23) return null;
    if (m.payload[0] != 0x02 or m.payload[1] != 0x15) return null;
    var b: IBeacon = undefined;
    @memcpy(&b.uuid, m.payload[2..18]);
    b.major = std.mem.readInt(u16, m.payload[18..20], .big);
    b.minor = std.mem.readInt(u16, m.payload[20..22], .big);
    b.tx_1m = @bitCast(m.payload[22]);
    return b;
}

/// Rough path-loss distance estimate (n=2) in meters, 0.1..100 clamped.
pub fn estimateDistance(tx_1m: i8, rssi: i8) f32 {
    const dx: f32 = @as(f32, @floatFromInt(tx_1m)) - @as(f32, @floatFromInt(rssi));
    const d = std.math.pow(f32, 10, dx / 20.0);
    return std.math.clamp(d, 0.1, 100.0);
}

// --- Eddystone ---------------------------------------------------------------

pub const Eddystone = union(enum) {
    uid: struct { tx: i8, namespace: [10]u8, instance: [6]u8 },
    url: struct { tx: i8, url: []const u8 },
    tlm: struct { vbatt: u16, temp_cx10: i16, adv_cnt: u32, sec_cnt: u32 },
    unknown_frame,
};

const url_prefixes = [_][]const u8{ "http://www.", "https://www.", "http://", "https://" };
const url_eic = [_][]const u8{
    ".com/", ".org/", ".edu/", ".net/", ".info/", ".biz/", ".gov/",
    ".com",  ".org",  ".edu",  ".net",  ".info",  ".biz",  ".gov",
};

/// Parse an Eddystone frame from the 0xFEAA service-data payload
/// (uuid already stripped). `buf` receives the decoded URL.
pub fn parseEddystone(data: []const u8, buf: []u8) Eddystone {
    if (data.len < 1) return .unknown_frame;
    const frame = data[0];
    const body = data[1..];
    switch (frame) {
        0x00 => { // UID: tx(1) + namespace(10) + instance(6) = 17 bytes read.
            if (body.len < 17) return .unknown_frame;
            return .{ .uid = .{
                .tx = @bitCast(body[0]),
                .namespace = body[1..11][0..10].*,
                .instance = body[11..17][0..6].*,
            } };
        },
        0x10 => { // URL
            if (body.len < 2) return .unknown_frame;
            const tx: i8 = @bitCast(body[0]);
            const scheme = if (body[1] < url_prefixes.len) url_prefixes[body[1]] else "http://";
            var w: usize = 0;
            w += copyStr(buf, w, scheme);
            for (body[2..]) |c| {
                if (c < url_eic.len) {
                    w += copyStr(buf, w, url_eic[c]);
                } else if (c >= 32 and c < 127 and w < buf.len) {
                    buf[w] = c;
                    w += 1;
                }
            }
            return .{ .url = .{ .tx = tx, .url = buf[0..w] } };
        },
        0x20 => { // TLM: version(1) + vbatt(2) + temp(2) + adv_cnt(4) + sec_cnt(4) = 13 bytes read.
            if (body.len < 13) return .unknown_frame;
            if (body[0] != 0x00) return .unknown_frame; // only unencrypted TLM
            return .{ .tlm = .{
                .vbatt = std.mem.readInt(u16, body[1..3], .big),
                .temp_cx10 = std.mem.readInt(i16, body[3..5], .big),
                .adv_cnt = std.mem.readInt(u32, body[5..9], .big),
                .sec_cnt = std.mem.readInt(u32, body[9..13], .big),
            } };
        },
        else => return .unknown_frame,
    }
}

fn copyStr(buf: []u8, at: usize, s: []const u8) usize {
    const n = @min(s.len, buf.len - at);
    @memcpy(buf[at..][0..n], s[0..n]);
    return n;
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "classify ibeacon" {
    const secs = [_]model.AdSection{
        .{ .typ = 0xFF, .data = &[_]u8{0x4C} ++ &[_]u8{0x00} ++ &[_]u8{0x02} ++ &[_]u8{0x15} ++ ([_]u8{0xDE} ** 16) ++ &[_]u8{ 0x00, 0x01, 0x00, 0x02, 0xC5 } },
    };
    const m = classify(&secs, "");
    try testing.expectEqual(Kind.ibeacon, m.kind);
    const b = parseIBeacon(ad.manufacturer(&secs).?).?;
    try testing.expectEqual(@as(u16, 1), b.major);
    try testing.expectEqual(@as(u16, 2), b.minor);
    try testing.expectEqual(@as(i8, -59), b.tx_1m);
}

test "classify eddystone url" {
    const secs = [_]model.AdSection{
        .{ .typ = 0x16, .data = &.{ 0xAA, 0xFE, 0x10, 0xEE, 0x03, 'c', 'o', 'f', 'f', 'e', 'e', 0x00 } },
    };
    try testing.expectEqual(Kind.eddystone, classify(&secs, "").kind);
    var buf: [128]u8 = undefined;
    const sd = ad.serviceData16(&secs).?;
    const e = parseEddystone(sd.data, &buf);
    try testing.expectEqualStrings("https://coffee.com/", e.url.url);
}

test "parse eddystone tlm at the minimum on-air length" {
    // Exactly frame(1)+version(1)+vbatt(2)+temp(2)+adv_cnt(4)+sec_cnt(4) =
    // 14 bytes total, no trailing padding — the shortest a real TLM frame
    // gets. Regression test for an off-by-one that rejected this as
    // .unknown_frame (checked body.len < 14 when only 13 are ever read).
    const data = [_]u8{ 0x20, 0x00, 0x0C, 0x80, 0x00, 0xE6, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x3C, 0x00 };
    var buf: [8]u8 = undefined;
    const e = parseEddystone(&data, &buf);
    const t = switch (e) {
        .tlm => |t| t,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(u16, 3200), t.vbatt);
    try testing.expectEqual(@as(i16, 230), t.temp_cx10);
    try testing.expectEqual(@as(u32, 2560), t.adv_cnt);
    try testing.expectEqual(@as(u32, 15360), t.sec_cnt);
}

test "classify continuity and exposure" {
    const airpods = [_]model.AdSection{
        .{ .typ = 0xFF, .data = &.{ 0x4C, 0x00, 0x07, 0x19, 0x07, 0x20 } },
    };
    const m1 = classify(&airpods, "");
    try testing.expectEqual(Kind.continuity, m1.kind);
    try testing.expectEqualStrings("AirPods nearby", m1.detail.?);

    const en = [_]model.AdSection{
        .{ .typ = 0x16, .data = &([_]u8{ 0x6F, 0xFD } ++ ([_]u8{0xAB} ** 20)) },
    };
    try testing.expectEqual(Kind.exposure, classify(&en, "").kind);
}

test "classify by appearance" {
    // Appearance 0x03C1 = HID Keyboard
    const kb = [_]model.AdSection{
        .{ .typ = 0x01, .data = &.{0x06} },
        .{ .typ = 0x19, .data = &.{ 0xC1, 0x03 } },
        .{ .typ = 0x09, .data = "K380" },
    };
    const m = classify(&kb, "K380");
    try testing.expectEqual(Kind.keyboard, m.kind);

    // Appearance 0x0300 = Thermometer
    const therm = [_]model.AdSection{
        .{ .typ = 0x19, .data = &.{ 0x00, 0x03 } },
    };
    try testing.expectEqual(Kind.thermometer, classify(&therm, "").kind);
}

test "classify by service heuristic" {
    const hr = [_]model.AdSection{
        .{ .typ = 0x03, .data = &.{ 0x0D, 0x18, 0x0F, 0x18 } },
    };
    try testing.expectEqual(Kind.heart_rate, classify(&hr, "").kind);
}

test "classify find-my nearby info beacon" {
    // 4C00 12 02 00 01 — Apple Nearby Info (Find My network).
    const secs = [_]model.AdSection{
        .{ .typ = 0xFF, .data = &.{ 0x4C, 0x00, 0x12, 0x02, 0x00, 0x01 } },
    };
    const m = classify(&secs, "");
    try testing.expectEqual(Kind.continuity, m.kind);
    try testing.expectEqualStrings("Find My nearby", m.detail.?);
}

test "classify by name prefix" {
    const secs = [_]model.AdSection{
        .{ .typ = 0x01, .data = &.{0x06} },
        .{ .typ = 0x03, .data = &.{ 0x0D, 0x18 } },
        .{ .typ = 0x09, .data = "WHOOP 5B00502404" },
    };
    const m = classify(&secs, "WHOOP 5B00502404");
    try testing.expectEqual(Kind.band, m.kind);
    try testing.expectEqualStrings("WHOOP fitness band", m.detail.?);

    // Mi Smart Band name wins over the generic Huami company rule.
    const mi = [_]model.AdSection{
        .{ .typ = 0xFF, .data = &([_]u8{ 0x57, 0x01 } ++ ([_]u8{0xFF} ** 8)) },
    };
    const m2 = classify(&mi, "Mi Smart Band 4");
    try testing.expectEqual(Kind.band, m2.kind);
    try testing.expectEqualStrings("Mi Band", m2.detail.?);

    // Apple 0xFCB2 service beacons.
    const fcb2 = [_]model.AdSection{
        .{ .typ = 0x16, .data = &.{ 0xB2, 0xFC, 0x01, 0x01, 0x27, 0x03 } },
    };
    const m3 = classify(&fcb2, "");
    try testing.expectEqual(Kind.unknown, m3.kind);
    try testing.expectEqualStrings("Apple service", m3.detail.?);
}

test "company hints from generated tables" {
    const xiaomi = [_]model.AdSection{
        .{ .typ = 0x16, .data = &.{ 0x95, 0xFE, 0x40 } },
    };
    try testing.expectEqualStrings("Xiaomi Inc.", companyHint(&xiaomi).?);

    const apple = [_]model.AdSection{
        .{ .typ = 0xFF, .data = &.{ 0x4C, 0x00, 0x12, 0x02 } },
    };
    try testing.expectEqualStrings("Apple, Inc.", companyHint(&apple).?);
}

test "classify samsung tv beacon with no advertised name" {
    // Real capture (wild16): company 0x0075, payload type 0x42, no name in
    // any frame — the name-prefix TV rules can't fire, this used to fall
    // through to .unknown.
    const secs = [_]model.AdSection{
        .{ .typ = 0xFF, .data = &[_]u8{ 0x75, 0x00, 0x42, 0x04, 0x01, 0x80, 0x60, 0xE4, 0x7D, 0xBD, 0x1D, 0xFF, 0xB5, 0xE6, 0x7D, 0xBD, 0x1D, 0xFF, 0xB4, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 } },
    };
    const m = classify(&secs, "");
    try testing.expectEqual(Kind.tv, m.kind);
    try testing.expectEqualStrings("Samsung TV", m.detail.?);
}

test "classify unnamed YUNMAI-family scale by service signature" {
    // Real capture (wild17): no name captured (device heard 3x at -107
    // dBm, no scan response), manufacturer data is the device's own
    // reversed MAC + 0000, custom svc 0x1310 + model UUID 0x5812.
    const secs = [_]model.AdSection{
        .{ .typ = 0x01, .data = &.{0x06} },
        .{ .typ = 0x02, .data = &.{ 0x10, 0x13 } },
        .{ .typ = 0x02, .data = &.{ 0x12, 0x58 } },
        .{ .typ = 0xFF, .data = &[_]u8{ 0x30, 0xCC, 0xD5, 0x21, 0xF8, 0x5C, 0x00, 0x00 } },
    };
    const m = classify(&secs, "");
    try testing.expectEqual(Kind.scale, m.kind);
    try testing.expectEqualStrings("YUNMAI-family scale", m.detail.?);

    // The named sibling keeps its more specific label (name rule wins).
    const named = classify(&secs, "YUNMAI-ISSE-US");
    try testing.expectEqualStrings("YUNMAI smart scale", named.detail.?);
}
