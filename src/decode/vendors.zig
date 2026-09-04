//! Vendor payload decoders: best-effort field extraction for common
//! manufacturer-data and service-data formats. Each decoder writes
//! human-readable "key: value" lines through an Io.Writer and returns
//! whether it recognized the payload.
//!
//! Adding support for a new vendor format = add a function + a dispatch
//! entry below (see README "adding device types").

const std = @import("std");

// --- Apple Continuity (manufacturer data, company 0x004C) --------------------

const continuity_type_names = [_]struct { t: u8, name: []const u8 }{
    .{ .t = 0x01, .name = "AirDrop" },
    .{ .t = 0x02, .name = "AirPlay" },
    .{ .t = 0x05, .name = "AirPods" },
    .{ .t = 0x07, .name = "Proximity Pairing (Find My nearby)" },
    .{ .t = 0x08, .name = "AirPlay (target)" },
    .{ .t = 0x09, .name = "Hey Siri" },
    .{ .t = 0x0A, .name = "AirPods case" },
    .{ .t = 0x0B, .name = "Apple TV" },
    .{ .t = 0x0C, .name = "HomePod" },
    .{ .t = 0x0D, .name = "Apple ID beacon" },
    .{ .t = 0x0E, .name = "Apple TV (pairing)" },
    .{ .t = 0x0F, .name = "AirPods (set)" },
    .{ .t = 0x10, .name = "Nearby Action" },
    .{ .t = 0x11, .name = "Nearby Info" },
    .{ .t = 0x12, .name = "Nearby Info (Find My)" },
    .{ .t = 0x13, .name = "Find My (leaked)" },
    .{ .t = 0x14, .name = "Nearby Info (extended)" },
    .{ .t = 0x15, .name = "Find My" },
    .{ .t = 0x16, .name = "App Launch" },
};

const airpods_models = [_]struct { m: u8, name: []const u8 }{
    .{ .m = 0x00, .name = "AirPods (1st gen)" },
    .{ .m = 0x01, .name = "AirPods (2nd gen)" },
    .{ .m = 0x02, .name = "AirPods Pro" },
    .{ .m = 0x03, .name = "AirPods Max" },
    .{ .m = 0x04, .name = "AirPods (3rd gen)" },
    .{ .m = 0x05, .name = "AirPods Pro (2nd gen)" },
    .{ .m = 0x08, .name = "Powerbeats" },
    .{ .m = 0x09, .name = "Powerbeats Pro" },
    .{ .m = 0x0A, .name = "Beats Solo Pro" },
    .{ .m = 0x0B, .name = "Beats Studio Buds" },
    .{ .m = 0x0D, .name = "Beats Fit Pro" },
    .{ .m = 0x0E, .name = "Beats Studio Pro" },
};

fn airpodsModel(m: u8) []const u8 {
    for (airpods_models) |x| {
        if (x.m == m) return x.name;
    }
    return "unknown model";
}

fn continuityTypeName(t: u8) ?[]const u8 {
    for (continuity_type_names) |x| {
        if (x.t == t) return x.name;
    }
    return null;
}

pub fn decodeApple(payload: []const u8, w: *std.Io.Writer) bool {
    // The manufacturer payload contains one or more [type][len][body]
    // Continuity structures stacked back to back — decode each.
    if (payload.len < 2) return false;
    var p: usize = 0;
    var any = false;
    while (p + 2 <= payload.len) {
        const t = payload[p];
        const l = payload[p + 1];
        if (p + 2 + l > payload.len) break;
        const body = payload[p + 2 ..][0..l];
        if (decodeAppleTlv(t, body, w)) any = true;
        p += 2 + l;
    }
    return any;
}

fn decodeAppleTlv(t: u8, body: []const u8, w: *std.Io.Writer) bool {
    const name = continuityTypeName(t) orelse return false;
    w.print("continuity type  0x{X:0>2} ({s})\n", .{ t, name }) catch return true;

    switch (t) {
        0x07 => { // proximity pairing
            if (body.len < 1) return true;
            const dev = body[0] >> 4;
            const flags = body[0] & 0x0F;
            w.print("device           {s} (0x{X})\n", .{ airpodsModel(dev), dev }) catch {};
            if (body.len >= 2) {
                const earbits = body[1];
                var parts: []const u8 = "";
                if (earbits & 0x10 != 0) parts = "left in ear";
                if (earbits & 0x20 != 0) parts = if (parts.len > 0) "both in ear" else "right in ear";
                if (earbits & 0x40 != 0) parts = if (parts.len > 0) parts else "in case";
                w.print("state            0x{X:0>2} {s}\n", .{ earbits, parts }) catch {};
                // one-time pairing code when flag bit 0x1 set
                if (flags & 0x1 != 0 and body.len >= 5) {
                    w.print("pairing code     {X:0>2}{X:0>2}{X:0>2}\n", .{ body[2], body[3], body[4] }) catch {};
                }
            }
        },
        0x10 => { // nearby action: [action u16 BE][auth tag...]
            if (body.len >= 2) {
                const action = std.mem.readInt(u16, body[0..2], .big);
                const action_name: []const u8 = switch (action) {
                    0x0118 => "setup nearby",
                    0x0119 => "AirPods setup nearby",
                    0x011A => "Apple TV setup nearby",
                    0x1A18 => "auto-connect",
                    0x301A => "Apple TV / HomePod nearby",
                    else => "",
                };
                w.print("action           0x{X:0>4} {s}\n", .{ action, action_name }) catch {};
                if (body.len > 2) {
                    var hex: [24]u8 = undefined;
                    w.print("auth tag         {s}\n", .{hexOf(body[2..], &hex)}) catch {};
                }
            }
        },
        0x12 => { // nearby info
            if (body.len >= 2) {
                const flags = body[0];
                const status = body[1];
                const ap_state = (status >> 6) & 0x3;
                w.print("flags            0x{X:0>2}\n", .{flags}) catch {};
                w.print("status           0x{X:0>2} (AP state {d})\n", .{ status, ap_state }) catch {};
            }
        },
        else => {},
    }
    return true;
}

// --- Microsoft CDP (manufacturer data, company 0x0006) ------------------------

pub fn decodeCdp(payload: []const u8, w: *std.Io.Writer) bool {
    if (payload.len < 4) return false;
    // CDP frame: [scenario u8][flags u8][...]. Scenario 0x01 = Swift Pair.
    const scenario = payload[0];
    const scenario_name: []const u8 = switch (scenario) {
        0x01 => "Swift Pair advertisement",
        0x02 => "Invoke",
        0x03 => "Device inventory",
        0x04 => "Out of band",
        0x05 => "Companion",
        else => "unknown",
    };
    w.print("scenario         0x{X:0>2} ({s})\n", .{ scenario, scenario_name }) catch return true;
    if (payload.len >= 5) {
        const dev_type = payload[4];
        const type_name: []const u8 = switch (dev_type) {
            0x01 => "mouse/pointing",
            0x02 => "keyboard",
            0x03 => "mouse+keyboard combo",
            0x04 => "gamepad",
            0x05 => "device management",
            0x06 => "pen",
            0x07 => "remote control",
            else => "unknown",
        };
        w.print("device type      0x{X:0>2} ({s})\n", .{ dev_type, type_name }) catch {};
    }
    // Swift Pair names ride at the end as UTF-16LE.
    if (scenario == 0x01 and payload.len > 8) {
        const name_part = payload[8..];
        if (name_part.len >= 2) {
            w.writeAll("name             ") catch return true;
            var i: usize = 0;
            while (i + 1 < name_part.len) : (i += 2) {
                const c = std.mem.readInt(u16, name_part[i..][0..2], .little);
                if (c == 0) break;
                if (c >= 0x20 and c < 0x7F) w.writeByte(@intCast(c)) catch break;
            }
            w.writeByte('\n') catch {};
        }
    }
    return true;
}

// --- Xiaomi Mi Beacon (service data 0xFE95) -----------------------------------

const xiaomi_products = [_]struct { p: u16, name: []const u8 }{
    .{ .p = 0x055B, .name = "LYWSD03MMC temp/hygrometer" },
    .{ .p = 0x03BC, .name = "CGG1 temp/hygrometer" },
    .{ .p = 0x045C, .name = "CGDK2 sensor" },
    .{ .p = 0x01AA, .name = "Mi Band 6" },
    .{ .p = 0x0148, .name = "Mi Band 5" },
    .{ .p = 0x01C4, .name = "Mi Band 4" },
    .{ .p = 0x0256, .name = "Mi Smart Band 7" },
    .{ .p = 0x038F, .name = "Mi Smart Band 8" },
};

fn xiaomiProduct(p: u16) ?[]const u8 {
    for (xiaomi_products) |x| {
        if (x.p == p) return x.name;
    }
    return null;
}

pub fn decodeXiaomi(data: []const u8, w: *std.Io.Writer) bool {
    if (data.len < 5) return false;
    const frame_ctrl = std.mem.readInt(u16, data[0..2], .little);
    const product = std.mem.readInt(u16, data[2..4], .little);
    const counter = data[4];
    const encrypted = frame_ctrl & 0x0008 != 0;
    const has_mac = frame_ctrl & 0x0002 != 0;
    const has_cap = frame_ctrl & 0x0010 != 0;

    const pn = xiaomiProduct(product);
    if (pn) |n| {
        w.print("product          0x{X:0>4} {s}\n", .{ product, n }) catch return true;
    } else {
        w.print("product id       0x{X:0>4}\n", .{product}) catch return true;
    }
    w.print("frame control    0x{X:0>4} {s}\n", .{ frame_ctrl, if (encrypted) "(encrypted)" else "" }) catch {};
    w.print("counter          {d}\n", .{counter}) catch {};

    var rest = data[5..];
    if (has_mac and rest.len >= 6) {
        var mbuf: [17]u8 = undefined;
        var m: [6]u8 = undefined;
        for (0..6) |k| m[k] = rest[5 - k]; // reversed on air
        w.print("source mac       {s}\n", .{macStr(m, &mbuf)}) catch {};
        rest = rest[6..];
    }
    if (encrypted) {
        w.writeAll("payload          encrypted (Mi Beacon crypto)\n") catch {};
        return true;
    }
    if (has_cap and rest.len >= 1) {
        const cap = rest[0];
        var feats: []const u8 = "";
        if (cap & 0x01 != 0) feats = "connectable";
        if (cap & 0x02 != 0) feats = if (feats.len > 0) "connectable, address" else featad("address");
        w.print("capabilities     0x{X:0>2} {s}\n", .{ cap, feats }) catch {};
    }
    return true;
}

fn featad(s: []const u8) []const u8 {
    return s;
}

fn macStr(addr: [6]u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
        addr[0], addr[1], addr[2], addr[3], addr[4], addr[5],
    }) catch "??:??:??:??:??:??";
}

// --- Google Fast Pair (service data 0xFE2C) -----------------------------------

pub fn decodeFastPair(data: []const u8, w: *std.Io.Writer) bool {
    if (data.len < 2) return false;
    const model = std.mem.readInt(u16, data[0..2], .little);
    const model_name: []const u8 = switch (model) {
        0x0001 => "Google Fast Pair headset",
        0x0084 => "Google Fast Pair device",
        0x0184 => "Phone setup (paired)",
        else => "",
    };
    w.print("model id         0x{X:0>4} {s}\n", .{ model, model_name }) catch return true;
    if (data.len >= 3) {
        w.print("extra flags      0x{X:0>2}\n", .{data[2]}) catch {};
    }
    return true;
}

// --- Exposure Notification (service data 0xFD6F) ------------------------------

pub fn decodeExposure(data: []const u8, w: *std.Io.Writer) bool {
    if (data.len < 16) return false;
    var hex: [40]u8 = undefined;
    w.print("rolling proximity id  {s}\n", .{hexOf(data[0..16], &hex)}) catch return true;
    if (data.len > 16) {
        var hex2: [16]u8 = undefined;
        w.print("metadata              {s} (encrypted)\n", .{hexOf(data[16..], &hex2)}) catch {};
    }
    return true;
}

// --- Eddystone frames (service data 0xFEAA) — detail view of UID/TLM ----------

pub fn decodeEddystone(data: []const u8, w: *std.Io.Writer) bool {
    if (data.len < 1) return false;
    switch (data[0]) {
        0x00 => {
            if (data.len < 18) return false;
            var hex: [24]u8 = undefined;
            w.writeAll("frame           UID\n") catch return true;
            w.print("tx power @0 m   {d} dBm\n", .{@as(i8, @bitCast(data[1]))}) catch {};
            w.print("namespace       {s}\n", .{hexOf(data[2..12], &hex)}) catch {};
            w.print("instance        {s}\n", .{hexOf(data[12..18], &hex)}) catch {};
        },
        0x20 => {
            if (data.len < 14) return false;
            w.writeAll("frame           TLM\n") catch return true;
            w.print("battery         {d} mV\n", .{std.mem.readInt(u16, data[2..4], .big)}) catch {};
            const temp = std.mem.readInt(i16, data[4..6], .big);
            w.print("temperature     {d}.{d} °C\n", .{ @divTrunc(temp, 10), @abs(@mod(temp, 10)) }) catch {};
            w.print("adv count       {d}\n", .{std.mem.readInt(u32, data[6..10], .big)}) catch {};
            w.print("uptime          {d} s\n", .{std.mem.readInt(u32, data[10..14], .big)}) catch {};
        },
        else => return false, // URL handled by classify; unknown frames stay raw
    }
    return true;
}

// --- Samsung SmartThings Find (service data 0xFD69) --------------------------

pub fn decodeSmartThings(data: []const u8, w: *std.Io.Writer) bool {
    if (data.len < 8) return false;
    var hex: [40]u8 = undefined;
    w.writeAll("network          SmartThings Find (Samsung)\n") catch return true;
    w.print("flags            0x{X:0>2}\n", .{data[0]}) catch {};
    w.print("ephemeral id     {s}\n", .{hexOf(data[1..@min(data.len, 15)], &hex)}) catch {};
    if (data.len > 15) {
        var hex2: [16]u8 = undefined;
        w.print("extra            {s} (rotating/encrypted)\n", .{hexOf(data[15..], &hex2)}) catch {};
    }
    return true;
}

// --- Google Quick Share / Nearby (service data 0xFCF1) ----------------------

pub fn decodeQuickShare(data: []const u8, w: *std.Io.Writer) bool {
    if (data.len < 6) return false;
    var hex: [40]u8 = undefined;
    w.writeAll("service          Quick Share / Nearby (Google)\n") catch return true;
    w.print("flags            0x{X:0>2}\n", .{data[0]}) catch {};
    w.print("ephemeral id     {s}\n", .{hexOf(data[1..@min(data.len, 17)], &hex)}) catch {};
    if (data.len > 17) {
        var hex2: [16]u8 = undefined;
        w.print("extra            {s} (rotating/encrypted)\n", .{hexOf(data[17..], &hex2)}) catch {};
    }
    return true;
}

// --- Google Find My Device network (service data 0xFEF3) --------------------

pub fn decodeFindMyDevice(data: []const u8, w: *std.Io.Writer) bool {
    if (data.len < 3) return false;
    var hex: [40]u8 = undefined;
    w.writeAll("network          Find My Device (Google)\n") catch return true;
    w.print("frame type       0x{X:0>2}\n", .{data[0]}) catch {};
    w.print("ephemeral id     {s}\n", .{hexOf(data[1..@min(data.len, 17)], &hex)}) catch {};
    if (data.len > 17) {
        var hex2: [16]u8 = undefined;
        w.print("extra            {s} (rotating/encrypted)\n", .{hexOf(data[17..], &hex2)}) catch {};
    }
    return true;
}

// --- dispatch -------------------------------------------------------------------

/// Manufacturer data decoder: `payload` has the company id stripped.
pub fn decodeMfr(company: u16, payload: []const u8, w: *std.Io.Writer) bool {
    return switch (company) {
        0x004C => decodeApple(payload, w),
        0x0006 => decodeCdp(payload, w),
        else => false,
    };
}

/// 16-bit service-data decoder: `data` has the uuid stripped.
pub fn decodeSvcData(uuid: u16, data: []const u8, w: *std.Io.Writer) bool {
    return switch (uuid) {
        0xFE95 => decodeXiaomi(data, w),
        0xFE2C => decodeFastPair(data, w),
        0xFD6F => decodeExposure(data, w),
        0xFEAA => decodeEddystone(data, w),
        0xFEF3 => decodeFindMyDevice(data, w),
        0xFCF1 => decodeQuickShare(data, w),
        0xFD69 => decodeSmartThings(data, w),
        else => false,
    };
}

fn hexOf(data: []const u8, buf: []u8) []const u8 {
    const n = @min(data.len * 2, buf.len / 2 * 2);
    var i: usize = 0;
    while (i < n / 2) : (i += 1) {
        _ = std.fmt.bufPrint(buf[i * 2 ..][0..2], "{x:0>2}", .{data[i]}) catch unreachable;
    }
    return buf[0..n];
}

// --- tests ----------------------------------------------------------------------

const testing = std.testing;

test "decode apple proximity pairing" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    // type 07 len 05: device 0x02 (AirPods Pro) | flags, earbits
    const payload = [_]u8{ 0x07, 0x05, 0x22, 0x10, 0x01, 0x02, 0x03 };
    try testing.expect(decodeApple(&payload, &aw.writer));
    try aw.writer.flush();
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "AirPods Pro") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Proximity Pairing") != null);
}

test "decode apple stacked continuity TLVs" {
    // Real payload from the wild: Nearby Info (12/02) followed by an
    // AirPods proximity-pairing structure (07/11) in one section.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const payload = [_]u8{
        0x12, 0x02, 0x6e, 0x01,
        0x07, 0x11, 0x06, 0x28, 0x13, 0xc0, 0x49, 0xf4, 0x2c, 0x35, 0x4b, 0x72, 0xd2, 0xd1, 0x75, 0xf4, 0x01, 0x08, 0xea,
    };
    try testing.expect(decodeApple(&payload, &aw.writer));
    try aw.writer.flush();
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "Nearby Info") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Proximity Pairing") != null);
    try testing.expect(std.mem.indexOf(u8, out, "right in ear") != null);
}

test "decode microsoft cdp swift pair" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const payload = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 'X', 0x00, 'B', 0x00, 'o', 0x00, 'x', 0x00 };
    try testing.expect(decodeCdp(&payload, &aw.writer));
    try aw.writer.flush();
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "Swift Pair") != null);
    try testing.expect(std.mem.indexOf(u8, out, "keyboard") != null);
    try testing.expect(std.mem.indexOf(u8, out, "XBox") != null);
}

test "decode xiaomi frame" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    // frame_ctrl 0x0000 (plain), product 0x055B, counter 3
    const data = [_]u8{ 0x00, 0x00, 0x5B, 0x05, 0x03, 0x0D, 0x10, 0x04, 0x01, 0x00, 0x20 };
    try testing.expect(decodeXiaomi(&data, &aw.writer));
    try aw.writer.flush();
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "LYWSD03MMC") != null);
    try testing.expect(std.mem.indexOf(u8, out, "counter") != null);
}

test "decode exposure notification" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const data = [_]u8{0xAB} ** 16 ++ [_]u8{ 0x00, 0x11 };
    try testing.expect(decodeExposure(&data, &aw.writer));
    try aw.writer.flush();
    try testing.expect(std.mem.indexOf(u8, aw.written(), "rolling proximity id") != null);
}

test "decode find my device network beacon" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const data = [_]u8{0x4A} ** 16;
    try testing.expect(decodeFindMyDevice(&data, &aw.writer));
    try aw.writer.flush();
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "Find My Device") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ephemeral id") != null);

    // Short discovery frame seen in the wild: [11][01][90][04][45 3C].
    aw.clearRetainingCapacity();
    const short = [_]u8{ 0x11, 0x01, 0x90, 0x04, 0x45, 0x3C };
    try testing.expect(decodeFindMyDevice(&short, &aw.writer));
    try aw.writer.flush();
    try testing.expect(std.mem.indexOf(u8, aw.written(), "frame type       0x11") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "019004453c") != null);
}

test "decode apple nearby action alignment" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    // type 10 len 06: action 0x3E1A + auth
    const payload = [_]u8{ 0x10, 0x06, 0x3E, 0x1A, 0x13, 0xF8, 0x97, 0xB1 };
    try testing.expect(decodeApple(&payload, &aw.writer));
    try aw.writer.flush();
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "action           0x3E1A") != null);
    try testing.expect(std.mem.indexOf(u8, out, "auth tag") != null);
}

test "decode eddystone tlm" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const data = [_]u8{ 0x20, 0x00, 0x0C, 0x80, 0x00, 0xE6, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x3C, 0x00 };
    try testing.expect(decodeEddystone(&data, &aw.writer));
    try aw.writer.flush();
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "TLM") != null);
    try testing.expect(std.mem.indexOf(u8, out, "3200 mV") != null);
}
