//! Replay backend: reads a JSONL file of advertisement events (the same
//! schema the Windows backend emits and --log records) and re-emits them.
//! Doubles as the no-radio demo, the test harness, and the workflow for
//! turning captured devices into database entries.

const std = @import("std");
const model = @import("model.zig");
const bus_mod = @import("../bus.zig");

const JSec = struct {
    t: u8,
    d: []const u8, // lowercase hex
};

const JAdv = struct {
    mac: []const u8,
    atype: u8 = 0,
    etype: []const u8 = "ConnectableUndirected",
    rssi: i16 = -100,
    name: ?[]const u8 = null,
    tx: ?i16 = null,
    secs: []const JSec = &.{},
    ts: i64 = 0,
};

pub const Replay = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    data: []u8,
    /// Added to every event timestamp so "last seen" looks live.
    ts_shift: i64 = 0,
    /// Set by requestStop(); checked between events.
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Heap-allocates the Replay (caller receives an owned pointer; close()
    /// frees it).
    pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8, live: bool) !*Replay {
        const data = try readFile(gpa, io, path);
        errdefer gpa.free(data);
        const self = try gpa.create(Replay);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .data = data };
        if (live) {
            var max_ts: i64 = 0;
            var it = std.mem.splitScalar(u8, data, '\n');
            while (it.next()) |line| {
                const ts = lineTs(line) orelse continue;
                if (ts > max_ts) max_ts = ts;
            }
            self.ts_shift = nowMs(io) - max_ts;
        }
        return self;
    }

    pub fn close(self: *Replay) void {
        self.gpa.free(self.data);
        self.gpa.destroy(self);
    }

    pub fn requestStop(self: *Replay) void {
        self.stopped.store(true, .release);
    }

    /// Feed every event onto the bus with optional pacing (thread body).
    pub fn run(self: *Replay, b: *bus_mod.Bus, paced: bool) void {
        var it = std.mem.splitScalar(u8, self.data, '\n');
        var prev_ts: ?i64 = null;
        while (it.next()) |line| {
            if (self.stopped.load(.acquire)) return;
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0) continue;
            const ev = parseLine(self.gpa, trimmed, self.ts_shift) catch continue;
            if (paced) {
                if (prev_ts) |pt| {
                    const gap = ev.ts_ms - pt;
                    const clamped = std.math.clamp(gap, 0, 150);
                    self.io.sleep(std.Io.Duration.fromMilliseconds(clamped), .awake) catch {};
                    if (self.stopped.load(.acquire)) {
                        ev.deinit(self.gpa);
                        return;
                    }
                }
                prev_ts = ev.ts_ms;
            }
            b.push(.{ .adv = ev });
        }
    }
};

/// Extract "ts":N without a full parse (cheap pre-scan for shifting).
fn lineTs(line: []const u8) ?i64 {
    const idx = std.mem.indexOf(u8, line, "\"ts\":") orelse return null;
    const i: usize = idx + 5;
    const end = std.mem.indexOfScalarPos(u8, line, i, ',') orelse line.len;
    return std.fmt.parseInt(i64, std.mem.trim(u8, line[i..end], " }\""), 10) catch null;
}

pub fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{buf[0..]}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexDecode(s: []const u8, out: []u8) !usize {
    if (s.len % 2 != 0) return error.BadHex;
    var i: usize = 0;
    while (i < s.len / 2) : (i += 1) {
        const hi = hexVal(s[i * 2]) orelse return error.BadHex;
        const lo = hexVal(s[i * 2 + 1]) orelse return error.BadHex;
        out[i] = (hi << 4) | lo;
    }
    return i;
}

pub const ParseLineError = error{ BadJson, BadHex, OutOfMemory };

/// Parse one JSONL line into a heap-allocated AdvEvent (caller/b consumer
/// owns it). `ts_shift` is added to the timestamp.
pub fn parseLine(gpa: std.mem.Allocator, line: []const u8, ts_shift: i64) ParseLineError!*model.AdvEvent {
    const parsed = std.json.parseFromSlice(JAdv, gpa, line, .{
        .ignore_unknown_fields = true,
    }) catch return error.BadJson;
    defer parsed.deinit();
    const j = parsed.value;

    const addr = model.parseMac(j.mac) orelse return error.BadJson;

    // Compute backing blob: name + section payloads.
    const name_len: usize = if (j.name) |nm| @min(nm.len, 64) else 0;
    var total: usize = name_len;
    for (j.secs) |s| total += (s.d.len / 2);

    const ev = try gpa.create(model.AdvEvent);
    errdefer gpa.destroy(ev);
    const backing = try gpa.alloc(u8, total);
    errdefer gpa.free(backing);
    const sections = try gpa.alloc(model.AdSection, j.secs.len);
    errdefer gpa.free(sections);

    var off: usize = 0;
    var ev_name: ?[]const u8 = null;
    if (j.name) |nm| {
        if (nm.len > 0) {
            const n = @min(nm.len, 64);
            @memcpy(backing[off..][0..n], nm[0..n]);
            ev_name = backing[off..][0..n];
            off += n;
        }
    }
    for (j.secs, 0..) |s, i| {
        const n = hexDecode(s.d, backing[off..]) catch return error.BadHex;
        sections[i] = .{ .typ = s.t, .data = backing[off..][0..n] };
        off += n;
    }

    const adv_type = model.AdvType.fromWinName(j.etype) orelse .connectable_undirected;
    const rssi: i8 = @intCast(std.math.clamp(@as(i32, j.rssi), -128, 127));
    const tx: ?i8 = if (j.tx) |t| @as(i8, @intCast(std.math.clamp(@as(i32, t), -128, 127))) else null;

    ev.* = .{
        .addr = addr,
        .addr_type = if (j.atype == 1) .random else .public,
        .adv_type = adv_type,
        .rssi = rssi,
        .name = ev_name,
        .tx_power = tx,
        .sections = sections,
        .ts_ms = j.ts + ts_shift,
        .backing = backing,
    };
    return ev;
}

// tests -----------------------------------------------------------------------

const testing = std.testing;

test "parseLine builds owned event" {
    const line =
        \\{"mac":"C8:47:8C:11:22:33","atype":1,"etype":"ScanResponse","rssi":-58,"name":"Band 8","tx":-4,"secs":[{"t":1,"d":"06"},{"t":255,"d":"8F0358"}],"ts":1234}
    ;
    const ev = try parseLine(testing.allocator, line, 1000);
    defer ev.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, &.{ 0xC8, 0x47, 0x8C, 0x11, 0x22, 0x33 }, &ev.addr);
    try testing.expectEqual(model.AddrType.random, ev.addr_type);
    try testing.expectEqual(model.AdvType.scan_response, ev.adv_type);
    try testing.expectEqual(@as(i8, -58), ev.rssi);
    try testing.expectEqual(@as(i8, -4), ev.tx_power.?);
    try testing.expectEqualStrings("Band 8", ev.name.?);
    try testing.expectEqual(@as(usize, 2), ev.sections.len);
    try testing.expectEqual(@as(u8, 1), ev.sections[0].typ);
    try testing.expectEqualSlices(u8, &.{0x06}, ev.sections[0].data);
    try testing.expectEqualSlices(u8, &.{ 0x8F, 0x03, 0x58 }, ev.sections[1].data);
    try testing.expectEqual(@as(i64, 2234), ev.ts_ms);
}

test "parseLine rejects garbage" {
    try testing.expectError(error.BadJson, parseLine(testing.allocator, "{not json", 0));
    try testing.expectError(error.BadHex, parseLine(testing.allocator, "{\"mac\":\"AA:BB:CC:DD:EE:FF\",\"secs\":[{\"t\":255,\"d\":\"XYZ\"}]}", 0));
}

test "lineTs extracts timestamp" {
    try testing.expectEqual(@as(i64, 1234), lineTs("{\"ts\":1234,\"x\":1}").?);
    try testing.expect(lineTs("{\"nope\":1}") == null);
}
