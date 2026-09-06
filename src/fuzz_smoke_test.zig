//! Seeded random-input smoke tests: panic in Debug = bug. Not a
//! correctness oracle — the contract under test is "hostile input must
//! error out or produce bounded output, never crash or loop forever".
//! All generators are deterministic xorshift32 so failures reproduce.

const std = @import("std");
const ad = @import("decode/ad.zig");
const classify = @import("decode/classify.zig");
const vendors = @import("decode/vendors.zig");
const filter_mod = @import("filter.zig");
const input = @import("tui/input.zig");
const screen_mod = @import("tui/screen.zig");
const model = @import("ble/model.zig");
const replay = @import("ble/replay.zig");
const store_mod = @import("store.zig");
const log_mod = @import("log.zig");

const testing = std.testing;

const Rng = struct {
    s: u32,
    fn next(self: *Rng) u32 {
        var x = self.s;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.s = x;
        return x;
    }
    fn byte(self: *Rng) u8 {
        return @truncate(self.next());
    }
    fn flip(self: *Rng) bool {
        return self.next() & 1 == 0;
    }
    fn below(self: *Rng, n: usize) usize {
        return @intCast(@mod(@as(u64, self.next()), @as(u64, @intCast(n))));
    }
};

fn randomSlicesInto(buf: []u8, rng: *Rng) []const u8 {
    for (buf) |*b| b.* = rng.byte();
    const n = rng.below(buf.len + 1);
    return buf[0..n];
}

test "fuzz: AD-structure walker + field extractors" {
    var rng = Rng{ .s = 0xF00D };
    var buf: [64]u8 = undefined;
    var secs: [8]model.AdSection = undefined;
    var out16: [16]u16 = undefined;
    var out32: [4]u32 = undefined;
    var out128: [2][16]u8 = undefined;
    var fbuf: [96]u8 = undefined;
    var i: usize = 0;
    while (i < 30_000) : (i += 1) {
        const data = randomSlicesInto(&buf, &rng);
        var views: [10]ad.SecView = undefined;
        _ = ad.splitSections(data, &views);
        // Sections built from the raw bytes, with random types/data.
        const n = rng.below(secs.len + 1);
        for (secs[0..n]) |*s| {
            const d = randomSlicesInto(&buf, &rng);
            s.* = .{ .typ = rng.byte(), .data = d };
        }
        _ = ad.manufacturer(secs[0..n]);
        _ = ad.localName(secs[0..n]);
        _ = ad.txPower(secs[0..n]);
        _ = ad.flags(secs[0..n]);
        _ = ad.serviceData16(secs[0..n]);
        _ = ad.serviceUuids16(secs[0..n], &out16);
        _ = ad.serviceUuids32(secs[0..n], &out32);
        _ = ad.serviceUuids128(secs[0..n], &out128);
        _ = ad.appearance(secs[0..n]);
        if (rng.below(64) == 0) _ = ad.flagDescriptions(rng.byte(), &fbuf);
        _ = classify.classify(secs[0..n], "");
        _ = classify.companyHint(secs[0..n]);
        _ = classify.parseIBeacon(ad.manufacturer(secs[0..n]) orelse .{ .company = 0, .payload = &.{} });
        var ebuf: [128]u8 = undefined;
        _ = classify.parseEddystone(randomSlicesInto(&ebuf, &rng), &fbuf);
    }
}

test "fuzz: vendor decoders over random payloads" {
    var rng = Rng{ .s = 0xBEEF };
    var buf: [64]u8 = undefined;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const companies = [_]u16{ 0x004C, 0x0006, 0x0087, 0x0157, 0x0075, 0x0D23, 0x01A9, 0x038F, 0x07D0, 0x4C42, 0xFFFF, 0x0000 };
    const uuids = [_]u16{ 0xFE95, 0xFE2C, 0xFD6F, 0xFEF3, 0xFCF1, 0xFD69, 0xFEAA, 0xFCB2, 0xA201, 0x0000 };
    var i: usize = 0;
    while (i < 30_000) : (i += 1) {
        const payload = randomSlicesInto(&buf, &rng);
        aw.clearRetainingCapacity();
        _ = vendors.decodeMfr(companies[rng.below(companies.len)], payload, &aw.writer);
        aw.writer.flush() catch {};
        aw.clearRetainingCapacity();
        _ = vendors.decodeSvcData(uuids[rng.below(uuids.len)], payload, &aw.writer);
        aw.writer.flush() catch {};
    }
}

test "fuzz: filter parse + match" {
    var rng = Rng{ .s = 0xC0FFEE };
    var inbuf: [140]u8 = undefined;
    var fbuf: [96]u8 = undefined;
    var i: usize = 0;
    while (i < 30_000) : (i += 1) {
        const q = randomSlicesInto(inbuf[0..100], &rng);
        const f = filter_mod.parse(q);
        _ = filter_mod.matches(&f, .{
            .mac = randomSlicesInto(fbuf[0..17], &rng),
            .name = randomSlicesInto(&fbuf, &rng),
            .company = randomSlicesInto(&fbuf, &rng),
            .kind = randomSlicesInto(&fbuf, &rng),
            .rssi = @bitCast(rng.byte()),
        });
        // Also feed it ascii-ish text heavy in 'rssi:'/'mac:' prefixes.
        for (inbuf[0..60]) |*b| b.* = switch (rng.below(4)) {
            0 => ':',
            1 => '-',
            2 => @as(u8, 'a') + @as(u8, @intCast(rng.below(26))),
            else => @as(u8, '0') + @as(u8, @intCast(rng.below(10))),
        };
        const f2 = filter_mod.parse(inbuf[0..rng.below(inbuf.len + 1)]);
        _ = f2.active();
    }
}

test "fuzz: key decoder state machine" {
    var rng = Rng{ .s = 0x5EED };
    var i: usize = 0;
    while (i < 30_000) : (i += 1) {
        var d: input.Decoder = .{};
        var j: usize = 0;
        const len = rng.below(24);
        const seq_ish = [_]u8{ 0x1B, '[', 'O', ';', '<', '>', '?', '=', '~', 'A' };
        while (j < len) : (j += 1) {
            const b = switch (rng.below(3)) {
                0 => rng.byte(), // anything
                1 => seq_ish[rng.below(seq_ish.len)], // sequence-ish
                else => rng.byte() % 0x7F,
            };
            _ = d.feed(b);
        }
        _ = d.flushTail();
    }
}

test "fuzz: screen text paths over hostile bytes" {
    var rng = Rng{ .s = 0xD1CE };
    var s = try screen_mod.Screen.init(testing.allocator, 24, 5);
    defer s.deinit();
    var buf: [80]u8 = undefined;
    var i: usize = 0;
    while (i < 30_000) : (i += 1) {
        s.clear();
        _ = s.text(@intCast(rng.below(30)), @intCast(rng.below(6)), randomSlicesInto(&buf, &rng), .{});
        s.textBounded(@intCast(rng.below(30)), @intCast(rng.below(6)), randomSlicesInto(&buf, &rng), @intCast(rng.below(30)), .{});
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try s.render(&aw.writer);
        try aw.writer.flush();
    }
}

test "fuzz: replay parser over mutated real lines" {
    var rng = Rng{ .s = 0x0FA1 };
    var buf: [300]u8 = undefined;
    const base = "{\"mac\":\"C8:47:8C:11:22:33\",\"atype\":1,\"etype\":\"ScanResponse\",\"rssi\":-58,\"name\":\"Band 8\",\"tx\":-4,\"secs\":[{\"t\":255,\"d\":\"8F0358\"}],\"ts\":1234}";
    var i: usize = 0;
    while (i < 30_000) : (i += 1) {
        const n = base.len;
        @memcpy(buf[0..n], base);
        const mutations = 1 + rng.below(4);
        var m: usize = 0;
        while (m < mutations) : (m += 1) {
            switch (rng.below(3)) {
                0 => buf[rng.below(n)] = rng.byte(), // flip
                1 => buf[rng.below(n)] = oneOf(&rng), // json-ish char
                else => {}, // truncation handled below
            }
        }
        const len = if (rng.flip()) n else rng.below(n + 1);
        const ev = replay.parseLine(testing.allocator, buf[0..len], @intCast(rng.next() % 1000)) catch continue;
        ev.deinit(testing.allocator);
    }
}

fn oneOf(rng: *Rng) u8 {
    const chars = "{}[]\":,\\0123456789abcdefnul";
    return chars[rng.below(chars.len)];
}

test "fuzz: store aggregation with random events" {
    var rng = Rng{ .s = 0x570E };
    var store = try store_mod.Store.init(testing.allocator);
    defer store.deinit();
    var namebuf: [80]u8 = undefined;
    var databuf: [40]u8 = undefined;
    var i: usize = 0;
    while (i < 3_000) : (i += 1) {
        const ev = try testing.allocator.create(model.AdvEvent);
        ev.* = .{
            .addr = .{ rng.byte(), rng.byte(), rng.byte(), rng.byte(), rng.byte(), rng.byte() },
            .addr_type = if (rng.flip()) .random else .public,
            .adv_type = .connectable_undirected,
            .rssi = if (rng.below(8) == 0) (if (rng.flip()) -127 else -128) else @as(i8, @bitCast(rng.byte())) | -120,
            .ts_ms = @intCast(rng.next() % 10_000),
        };
        if (rng.below(3) == 0) {
            const nm = randomSlicesInto(namebuf[0..70], &rng);
            // sanitizeName-compatible: cut at control bytes sometimes
            ev.name = nm;
        }
        if (rng.below(2) == 0) {
            const nsecs = rng.below(5);
            const secs = try testing.allocator.alloc(model.AdSection, nsecs);
            for (secs) |*sec| {
                sec.* = .{ .typ = rng.byte(), .data = randomSlicesInto(&databuf, &rng) };
            }
            ev.sections = secs;
        }
        store.update(ev); // frees ev incl. its sections slice
    }
    // Surviving entries must render coherent views.
    var secs_buf: [40]model.AdSection = undefined;
    for (store.entries()) |e| {
        const n = e.sections(&secs_buf);
        try testing.expect(n <= secs_buf.len);
        for (secs_buf[0..n]) |sec| try testing.expect(sec.data.len <= 40);
        _ = e.rssiAvg();
        _ = e.name();
        var j: usize = 0;
        while (j < e.alt_count) : (j += 1) _ = e.altName(j);
    }
}

test "fuzz: log serializer over random sections" {
    var rng = Rng{ .s = 0x106B };
    var buf: [300]u8 = undefined;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const nsecs = rng.below(6);
        var secs: [6]model.AdSection = undefined;
        for (secs[0..nsecs]) |*sec| {
            sec.* = .{ .typ = rng.byte(), .data = randomSlicesInto(&buf, &rng) };
        }
        const ev = model.AdvEvent{
            .addr = .{ rng.byte(), rng.byte(), rng.byte(), rng.byte(), rng.byte(), rng.byte() },
            .addr_type = if (rng.flip()) .random else .public,
            .adv_type = .scan_response,
            .rssi = @bitCast(rng.byte()),
            .name = if (rng.flip()) randomSlicesInto(&buf, &rng) else null,
            .tx_power = @bitCast(rng.byte()),
            .sections = secs[0..nsecs],
            .ts_ms = @intCast(rng.next()),
        };
        aw.clearRetainingCapacity();
        log_mod.writeEvent(&aw.writer, &ev) catch {};
        aw.writer.flush() catch {};
    }
}

test "fuzz: parseMac / hexEncode / mac format" {
    var rng = Rng{ .s = 0x0ACC };
    var buf: [40]u8 = undefined;
    var hexbuf: [7]u8 = undefined; // deliberately odd/small
    var i: usize = 0;
    while (i < 30_000) : (i += 1) {
        const s = randomSlicesInto(&buf, &rng);
        if (model.parseMac(s)) |mac| {
            var out: [17]u8 = undefined;
            _ = model.formatMac(mac, &out);
        }
        _ = model.hexEncode(s, &hexbuf);
    }
}
