//! Event logger: serializes AdvEvents as JSONL in the same schema the
//! replay backend and --selftest consume — recordings are directly
//! replayable (`--replay capture.jsonl`).

const std = @import("std");
const model = @import("ble/model.zig");

pub fn writeEvent(w: *std.Io.Writer, ev: *const model.AdvEvent) !void {
    var mac: [17]u8 = undefined;
    try w.print("{{\"mac\":\"{s}\",\"atype\":{d},\"etype\":\"{s}\",\"rssi\":{d},\"name\":", .{
        model.formatMac(ev.addr, &mac),
        @intFromEnum(ev.addr_type),
        advTypeWinName(ev.adv_type),
        ev.rssi,
    });
    if (ev.name) |n| {
        try w.writeByte('"');
        try writeJsonString(w, n);
        try w.writeByte('"');
    } else {
        try w.writeAll("null");
    }
    try w.print(",\"tx\":", .{});
    if (ev.tx_power) |t| {
        try w.print("{d}", .{t});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"secs\":[");
    var hex: [2048]u8 = undefined; // extended adv can reach ~1650 bytes
    for (ev.sections, 0..) |sec, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"t\":{d},\"d\":\"{s}\"}}", .{ sec.typ, model.hexEncode(sec.data, &hex) });
    }
    try w.print("],\"ts\":{d}}}\n", .{ev.ts_ms});
}

fn advTypeWinName(t: model.AdvType) []const u8 {
    return switch (t) {
        .connectable_undirected => "ConnectableUndirected",
        .connectable_directed => "ConnectableDirected",
        .scannable_undirected => "ScannableUndirected",
        .non_connectable_undirected => "NonConnectableUndirected",
        .scan_response => "ScanResponse",
    };
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n', '\r', '\t' => try w.writeByte(' '),
            else => {
                if (c < 0x20) {
                    try w.writeByte(' ');
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

test "writeEvent roundtrips through replay parser" {
    const replay = @import("ble/replay.zig");
    const testing = std.testing;

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const backing = [_]u8{ 0x06, 0x8F, 0x03, 0x58 };
    const secs = [_]model.AdSection{
        .{ .typ = 0x01, .data = backing[0..1] },
        .{ .typ = 0xFF, .data = backing[1..] },
    };
    const ev = model.AdvEvent{
        .addr = .{ 0xC8, 0x47, 0x8C, 0x11, 0x22, 0x33 },
        .addr_type = .random,
        .adv_type = .scan_response,
        .rssi = -58,
        .name = "Te\"st",
        .tx_power = null,
        .sections = &secs,
        .ts_ms = 1000,
    };
    try writeEvent(&aw.writer, &ev);
    try aw.writer.flush();

    const parsed = try replay.parseLine(testing.allocator, aw.written(), 0);
    defer parsed.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, &ev.addr, &parsed.addr);
    try testing.expectEqual(ev.addr_type, parsed.addr_type);
    try testing.expectEqual(ev.adv_type, parsed.adv_type);
    try testing.expectEqual(ev.rssi, parsed.rssi);
    try testing.expectEqualStrings("Te\"st", parsed.name.?);
    try testing.expectEqual(@as(usize, 2), parsed.sections.len);
    try testing.expectEqualSlices(u8, secs[1].data, parsed.sections[1].data);
    try testing.expectEqual(ev.ts_ms, parsed.ts_ms);
}
