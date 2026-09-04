//! Widget drawing: top bar, list body, detail body, help overlay, and small
//! formatting helpers shared by the views.

const std = @import("std");
const screen_mod = @import("screen.zig");
const store = @import("../store.zig");
const model = @import("../ble/model.zig");
const ad = @import("../decode/ad.zig");
const classify = @import("../decode/classify.zig");
const companies = @import("../db/companies.zig");
const services = @import("../db/services.zig");
const slam_mod = @import("../slam.zig");

pub const Screen = screen_mod.Screen;
pub const Style = screen_mod.Style;
pub const Entry = store.Entry;

// palette
pub const c_base: u8 = 252;
pub const c_dim: u8 = 244;
pub const c_accent: u8 = 81;
pub const c_green: u8 = 114;
pub const c_yellow: u8 = 221;
pub const c_red: u8 = 210;
pub const c_bar_bg: u8 = 238;
pub const c_sel_bg: u8 = 237;

pub const bar_glyphs = [_][]const u8{ "·", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
pub const bar_glyphs_ascii = [_][]const u8{ ".", ":", ":", "-", "-", "=", "=", "+", "#" };

/// Block glyph for RSSI bucket (ASCII fallback under --ascii).
pub fn barGlyph(i: usize) []const u8 {
    return if (screen_mod.ascii) bar_glyphs_ascii[i] else bar_glyphs[i];
}

pub fn rssiBucket(r: i8) usize {
    const v: i32 = @as(i32, r) + 100;
    return @intCast(std.math.clamp(@divTrunc(v, 9), 0, 8));
}

pub fn rssiColor(r: i8) u8 {
    if (r >= -60) return c_green;
    if (r >= -80) return c_yellow;
    return c_red;
}

pub fn hasRssi(e: *const Entry) bool {
    return e.rssi_last != 127;
}

/// "5s" / "12m" / "3h" for a duration in ms.
pub fn fmtAge(ms: i64, buf: []u8) []const u8 {
    const s = @divTrunc(ms, 1000);
    if (s < 0) return "now";
    if (s < 60) return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "now";
    const m = @divTrunc(s, 60);
    if (m < 60) return std.fmt.bufPrint(buf, "{d}m", .{m}) catch "now";
    return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(m, 60)}) catch "now";
}

/// HH:MM:SS local time from epoch ms.
pub fn fmtClock(ms: i64, buf: []u8) []const u8 {
    const epoch_s: i64 = @divFloor(ms, 1000);
    const local_s = epoch_s + localUtcOffsetSeconds(epoch_s);
    const day_s: u64 = @intCast(@mod(local_s, 86400));
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ day_s / 3600, (day_s / 60) % 60, day_s % 60 }) catch "--:--:--";
}

var cached_offset: ?i64 = null;
var cached_until: i64 = 0;

fn localUtcOffsetSeconds(now_s: i64) i64 {
    // Cache for an hour — timezone changes are rare and the query is
    // expensive enough to avoid per-frame.
    if (cached_offset) |off| {
        if (now_s < cached_until) return off;
    }
    const off = queryUtcOffset(now_s);
    cached_offset = off;
    cached_until = now_s + 3600;
    return off;
}

fn queryUtcOffset(now_s: i64) i64 {
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .windows => {
            const GetTimeZoneInformation = struct {
                extern "kernel32" fn GetTimeZoneInformation(
                    lpTimeZoneInformation: *anyopaque,
                ) callconv(.c) u32;
            }.GetTimeZoneInformation;
            // TIME_ZONE_INFORMATION: LONG Bias; WCHAR StandardName[32];
            // SYSTEMTIME StandardDate; LONG StandardBias;
            // WCHAR DaylightName[32]; SYSTEMTIME DaylightDate; LONG DaylightBias;
            const TZI = extern struct {
                Bias: i32,
                StandardName: [32]u16,
                StandardDate: extern struct { y: u16, mo: u16, dow: u16, d: u16, h: u16, mi: u16, s: u16, ms: u16 },
                StandardBias: i32,
                DaylightName: [32]u16,
                DaylightDate: extern struct { y: u16, mo: u16, dow: u16, d: u16, h: u16, mi: u16, s: u16, ms: u16 },
                DaylightBias: i32,
            };
            var tzi: TZI = undefined;
            const rc = GetTimeZoneInformation(@ptrCast(&tzi));
            // Bias is minutes WEST of UTC (UTC = local + bias); the total
            // offset is Bias + (active ? DaylightBias : StandardBias).
            const total_bias: i64 = @as(i64, tzi.Bias) +
                (if (rc == 2) @as(i64, tzi.DaylightBias) else 0);
            return -total_bias * 60;
        },
        .linux => {
            return linuxUtcOffset(now_s);
        },
        else => return 0,
    }
}

/// Read the current UTC offset from /etc/localtime (TZif v2).
/// Falls back to UTC when the file is missing or unparseable.
fn linuxUtcOffset(now_s: i64) i64 {
    const io = std.Io.Threaded.init(std.heap.page_allocator) catch return 0;
    const file = std.Io.Dir.cwd().openFile(io, "/etc/localtime", .{}) catch return 0;
    defer file.close(io);
    var fbuf: [4096]u8 = undefined;
    const n = file.readStreaming(io, &.{fbuf[0..]}) catch return 0;
    const data = fbuf[0..n];

    // TZif v2 header: magic(4) ver(1) pad(15) then counts:
    // isutcnt(4) isstdcnt(4) leapcnt(4) timecnt(4) typecnt(4) charcnt(4)
    if (data.len < 44 or !std.mem.eql(u8, data[0..4], "TZif")) return 0;
    const timecnt = std.mem.readInt(u32, data[20..24], .big);
    const typecnt = std.mem.readInt(u32, data[24..28], .big);
    if (typecnt == 0 or timecnt == 0) return 0;

    // v2 block starts after the v1 data block; find it by the second magic.
    var v2_off: usize = 44;
    // v1 data size: timecnt*4 + timecnt*1 + typecnt*6 + charcnt + leapcnt*8 + isstdcnt + isutcnt
    const isutcnt = std.mem.readInt(u32, data[12..16], .big);
    const isstdcnt = std.mem.readInt(u32, data[16..20], .big);
    const leapcnt = std.mem.readInt(u32, data[28..32], .big);
    const charcnt = std.mem.readInt(u32, data[32..36], .big);
    const v1_size = 44 + @as(usize, timecnt) * 4 + timecnt + @as(usize, typecnt) * 6 + charcnt + @as(usize, leapcnt) * 8 + isstdcnt + isutcnt;
    if (v1_size >= data.len) return 0;
    v2_off = v1_size;
    if (v2_off + 44 > data.len or !std.mem.eql(u8, data[v2_off .. v2_off + 4], "TZif")) return 0;

    // v2 counts
    const v2_timecnt = std.mem.readInt(u32, data[v2_off + 20 ..][0..4], .big);
    const v2_typecnt = std.mem.readInt(u32, data[v2_off + 24 ..][0..4], .big);
    if (v2_timecnt == 0 or v2_typecnt == 0) return 0;

    const trans_off = v2_off + 44;
    const idx_off = trans_off + @as(usize, v2_timecnt) * 8; // 8-byte times in v2
    const type_off = idx_off + v2_timecnt;

    if (type_off + @as(usize, v2_typecnt) * 6 > data.len) return 0;

    // Find the last transition <= now (binary search would be nice but
    // linear is fine for typical ~200 entries).
    var active_type: usize = 0;
    var i: usize = 0;
    while (i < v2_timecnt) : (i += 1) {
        const t: i64 = std.mem.readInt(i64, data[trans_off + i * 8 ..][0..8], .big);
        if (t <= now_s) {
            active_type = data[idx_off + i];
        } else break;
    }
    if (active_type >= v2_typecnt) return 0;

    // ttinfo: gmtoff (i32 BE), isdst (u8), abbrind (u8)
    const gmtoff = std.mem.readInt(i32, data[type_off + active_type * 6 ..][0..4], .big);
    return gmtoff;
}

pub fn drawTopBar(s: *Screen, backend: []const u8, n_dev: usize, now_ms: i64, paused: bool, sort_label: []const u8, filter_text: ?[]const u8) void {
    const st: Style = .{ .fg = 255, .bg = c_bar_bg, .bold = true };
    s.fillRect(0, 0, s.w, 1, st);
    var buf: [112]u8 = undefined;
    var left: []const u8 = " ble-scanner ";
    if (filter_text) |ft| {
        left = std.fmt.bufPrint(&buf, " ble-scanner · {s} · sort: {s} · filter: {s} ", .{ backend, sort_label, ft }) catch left;
    } else if (screen_mod.ascii) {
        left = if (paused)
            std.fmt.bufPrint(&buf, " ble-scanner - {s} - II paused - sort: {s} ", .{ backend, sort_label }) catch left
        else
            std.fmt.bufPrint(&buf, " ble-scanner - {s} - sort: {s} ", .{ backend, sort_label }) catch left;
    } else if (paused) {
        left = std.fmt.bufPrint(&buf, " ble-scanner · {s} · II paused · sort: {s} ", .{ backend, sort_label }) catch left;
    } else {
        left = std.fmt.bufPrint(&buf, " ble-scanner · {s} · sort: {s} ", .{ backend, sort_label }) catch left;
    }
    _ = s.text(0, 0, left, st);

    var rbuf: [96]u8 = undefined;
    const right = if (screen_mod.ascii)
        std.fmt.bufPrint(&rbuf, "{d} devices - {s} ", .{ n_dev, fmtClock(now_ms, rbuf[48..]) }) catch ""
    else
        std.fmt.bufPrint(&rbuf, "{d} devices · {s} ", .{ n_dev, fmtClock(now_ms, rbuf[48..]) }) catch "";
    const rw: u32 = @intCast(right.len);
    if (rw < s.w) _ = s.text(s.w - rw, 0, right, st);
}

pub const Hints = struct {
    pub const list = "↑↓ select · ⏎ details · m view · / filter · r raw · s sort · c clear · p pause · ? help · q quit";
    pub const radar = "↑↓ select · ⏎ details · m view · / filter · p pause · ? help · q quit";
    pub const detail = "↑↓ scroll · PgUp/PgDn page · Esc back · ? help · q quit";
};

/// Filter input line, drawn over the hints row while editing.
pub fn drawFilterInput(s: *Screen, buf: []const u8) void {
    const st: Style = .{ .fg = 255, .bg = 238 };
    s.fillRect(0, s.h - 1, s.w, 1, st);
    var label: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&label, " / {s}▏", .{buf}) catch " / ";
    _ = s.text(1, s.h - 1, line, st);
    const hint = "⏎ apply · Esc cancel";
    const hw: u32 = @intCast(hint.len);
    if (hw + 2 < s.w) {
        _ = s.text(s.w - hw - 1, s.h - 1, hint, .{ .fg = c_dim, .bg = 238 });
    }
}

pub fn drawHints(s: *Screen, text: []const u8) void {
    const st: Style = .{ .fg = c_dim };
    s.fillRect(0, s.h - 1, s.w, 1, st);
    _ = s.text(0, s.h - 1, " ", st);
    _ = s.text(1, s.h - 1, text, st);
}

const Columns = struct {
    name: u32 = 0,
    company: u32 = 0,
    typ: u32 = 0,
    last: u32 = 0,
    rssi: u32 = 0,
    x_name: u32 = 0,
    x_rssi: u32 = 0,
    x_last: u32 = 0,
    x_company: u32 = 0,
    x_type: u32 = 0,
    x_end: u32 = 0,
};

fn computeColumns(w: u32) Columns {
    var c: Columns = .{};
    const mac_w: u32 = 17;
    const t_w: u32 = 2;
    var x: u32 = 1;
    x += mac_w + 1 + t_w + 1; // mac + gap + type marker + gap
    c.x_name = x;

    const rssi_w: u32 = 8; // "█ -100"
    const last_w: u32 = 4;
    const company_w: u32 = 18;
    const type_w: u32 = 15;

    var total: u32 = 0;
    if (w >= 104) {
        c.company = company_w;
        c.typ = type_w;
        c.last = last_w;
        c.rssi = rssi_w;
        total = rssi_w + 1 + last_w + 1 + company_w + 1 + type_w + 1;
    } else if (w >= 86) {
        c.typ = type_w;
        c.last = last_w;
        c.rssi = rssi_w;
        total = rssi_w + 1 + last_w + 1 + type_w + 1;
    } else if (w >= 70) {
        c.last = last_w;
        c.rssi = rssi_w;
        total = rssi_w + 1 + last_w + 1;
    } else if (w >= 50) {
        c.rssi = rssi_w;
        total = rssi_w + 1;
    }
    c.name = if (w > total + c.x_name + 4) w - total - c.x_name else 0;

    var xe = c.x_name + c.name;
    if (c.name > 0) xe += 1;
    c.x_rssi = xe;
    xe += c.rssi;
    if (c.rssi > 0) xe += 1;
    c.x_last = xe;
    xe += c.last;
    if (c.last > 0) xe += 1;
    c.x_company = xe;
    xe += c.company;
    if (c.company > 0) xe += 1;
    c.x_type = xe;
    xe += c.typ;
    c.x_end = xe;
    return c;
}

pub fn drawListBody(s: *Screen, entries: []*Entry, sel_idx: usize, top: usize, now_ms: i64, raw: bool) void {
    const vy0: u32 = 2;
    const vh: u32 = if (s.h > 3) s.h - 3 else 0;
    const need_scroll = entries.len > vh and vh > 1;
    // Reserve a gap column + the scrollbar track on the right.
    const w_eff: u32 = if (need_scroll and s.w > 10) s.w - 2 else s.w;
    const c = computeColumns(w_eff);
    const st_hdr: Style = .{ .fg = c_dim, .bold = true };

    var x: u32 = 1;
    _ = s.text(x, 1, "ADDRESS", st_hdr);
    x += 17 + 1;
    _ = s.text(x, 1, "T", st_hdr);
    x += 2 + 1;
    if (c.name > 0) {
        if (raw) {
            _ = s.text(c.x_name, 1, "RAW ADVERTISING DATA (merged, latest payload)", st_hdr);
        } else {
            _ = s.text(c.x_name, 1, "NAME", st_hdr);
            if (c.company > 0) _ = s.text(c.x_company, 1, "COMPANY", st_hdr);
            if (c.typ > 0) _ = s.text(c.x_type, 1, "TYPE", st_hdr);
            if (c.last > 0) _ = s.text(c.x_last, 1, "LAST", st_hdr);
            if (c.rssi > 0) _ = s.text(c.x_rssi, 1, "RSSI", st_hdr);
        }
    }

    if (vh == 0) return;

    var i: usize = top;
    var row: u32 = 0;
    while (i < entries.len and row < vh) : ({
        i += 1;
        row += 1;
    }) {
        const e = entries[i];
        const y = vy0 + row;
        const selected = (i == sel_idx);
        const base: Style = if (selected) .{ .fg = 255, .bg = c_sel_bg } else .{ .fg = c_base };
        const dim: Style = if (selected) .{ .fg = 250, .bg = c_sel_bg } else .{ .fg = c_dim };
        if (selected) s.fillRect(0, y, w_eff, 1, base);

        var buf: [18]u8 = undefined;
        _ = s.text(1, y, model.formatMac(e.addr, &buf), base);
        const tmark: []const u8 = if (e.addr_type == .random) "*" else " ";
        _ = s.text(19, y, tmark, dim);

        if (c.name > 0) {
            if (raw) {
                // Raw mode: hex of the merged payload, spanning up to the
                // RSSI column (or the end when narrow).
                const span = (if (c.rssi > 0) c.x_rssi else if (c.company > 0) c.x_type + c.typ else c.x_name + c.name) - c.x_name;
                var hex: [160]u8 = undefined;
                const hx = model.hexEncode(e.blob.items, &hex);
                if (hx.len == 0) {
                    s.textBounded(c.x_name, y, "(empty)", span, dim);
                } else {
                    s.textBounded(c.x_name, y, hx, span, .{ .fg = 180, .bg = base.bg });
                }
            } else {
                const nm = e.name();
                if (nm.len > 0) {
                    s.textBounded(c.x_name, y, nm, c.name, base);
                } else {
                    s.textBounded(c.x_name, y, "(unknown)", c.name, dim);
                }
            }
        }

        // Latest classification from stored sections.
        var secs_buf: [40]model.AdSection = undefined;
        const nsecs = e.sections(&secs_buf);
        const secs = secs_buf[0..nsecs];
        const match = if (raw) null else classify.classify(secs, e.name());

        if (!raw) {
            if (c.company > 0) {
                s.textBounded(c.x_company, y, classify.companyHint(secs) orelse "-", c.company, dim);
            }
            if (c.typ > 0) {
                const tl = if (match) |m| m.detail orelse m.kind.label() else "-";
                s.textBounded(c.x_type, y, tl, c.typ, .{ .fg = c_accent, .bg = base.bg });
            }
        }
        if (c.last > 0) {
            var ab: [8]u8 = undefined;
            _ = s.text(c.x_last, y, fmtAge(now_ms - e.last_ms, &ab), dim);
        }
        if (c.rssi > 0) {
            var rb: [16]u8 = undefined;
            if (e.rssi_last == 127) {
                _ = s.text(c.x_rssi, y, "  --", dim);
            } else {
                const bar = std.fmt.bufPrint(&rb, "{s} {d}", .{ barGlyph(rssiBucket(e.rssi_last)), e.rssi_last }) catch "-";
                _ = s.text(c.x_rssi, y, bar, .{ .fg = rssiColor(e.rssi_last), .bg = base.bg });
            }
        }
    }

    if (need_scroll) drawScrollbar(s, vy0, vh, top, entries.len);
}

/// Right-edge scrollbar: dim track, accent thumb sized/positioned
/// proportionally to the viewport. `top` is the first visible row.
fn drawScrollbar(s: *Screen, vy0: u32, vh: u32, top: usize, total: usize) void {
    const x = s.w - 1;
    const n = @max(total, 1);
    var thumb_len: u32 = (vh * vh) / @as(u32, @intCast(n));
    if (thumb_len < 1) thumb_len = 1;
    if (thumb_len > vh) thumb_len = vh;
    const scrollable: u32 = @intCast(n - @min(n, vh));
    const max_off: u32 = vh - thumb_len;
    var thumb_pos: u32 = 0;
    if (scrollable > 0) {
        thumb_pos = (@as(u32, @intCast(top)) * max_off) / scrollable;
        if (thumb_pos > max_off) thumb_pos = max_off;
    }
    const track_ch: u21 = if (screen_mod.ascii) '|' else '┆';
    const thumb_ch: u21 = if (screen_mod.ascii) '#' else '█';
    var r: u32 = 0;
    while (r < vh) : (r += 1) {
        const in_thumb = r >= thumb_pos and r < thumb_pos + thumb_len;
        s.put(x, vy0 + r, if (in_thumb) thumb_ch else track_ch, .{
            .fg = if (in_thumb) c_accent else 240,
        });
    }
}

pub const LineKind = enum { title, section, label, text, dim, hex, accent, warn };

pub const Line = struct {
    kind: LineKind,
    text: []const u8,
};

pub fn lineStyle(kind: LineKind, bg: u8) Style {
    return switch (kind) {
        .title => .{ .fg = c_accent, .bold = true, .bg = bg },
        .section => .{ .fg = 81, .bold = true, .bg = bg },
        .label => .{ .fg = 255, .bold = true, .bg = bg },
        .text => .{ .fg = c_base, .bg = bg },
        .dim => .{ .fg = c_dim, .bg = bg },
        .hex => .{ .fg = 180, .bg = bg },
        .accent => .{ .fg = c_accent, .bg = bg },
        .warn => .{ .fg = c_red, .bg = bg },
    };
}

pub fn drawDetailBody(s: *Screen, lines: []const Line, scroll: u32) void {
    const y0: u32 = 0;
    const vh: u32 = if (s.h > 1) s.h - 1 else 1;
    var y: u32 = y0;
    var idx: usize = scroll;
    while (idx < lines.len and y < vh) : ({
        idx += 1;
        y += 1;
    }) {
        const l = lines[idx];
        _ = s.text(0, y, l.text, lineStyle(l.kind, 0));
    }
}

pub fn drawEmpty(s: *Screen, msg: []const u8) void {
    if (s.h < 4) return;
    const y = s.h / 2;
    const st: Style = .{ .fg = c_dim };
    const x = if (s.w > msg.len) (s.w - @as(u32, @intCast(msg.len))) / 2 else 0;
    _ = s.text(x, y, msg, st);
}

pub fn drawErrorBox(s: *Screen, title: []const u8, msg: []const u8) void {
    if (s.w < 30 or s.h < 6) return;
    const bw: u32 = @min(@as(u32, @intCast(@max(msg.len, title.len))) + 6, s.w - 4);
    const bh: u32 = 6;
    const x = (s.w - bw) / 2;
    const y = (s.h - bh) / 2;

    s.fillRect(x, y, bw, bh, .{ .fg = c_base, .bg = 52 });
    s.box(x, y, bw, bh, .{ .fg = c_red, .bg = 52 });
    _ = s.text(x + 2, y, " ", .{ .fg = c_red, .bg = 52 });
    _ = s.text(x + 3, y, title, .{ .fg = c_red, .bg = 52, .bold = true });
    // wrap msg at bw-4
    var rest = msg;
    var yy = y + 2;
    while (rest.len > 0 and yy < y + bh - 1) : (yy += 1) {
        const max: usize = bw - 4;
        var take = @min(rest.len, max);
        if (rest.len > max) {
            if (std.mem.lastIndexOfScalar(u8, rest[0..take], ' ')) |sp| take = sp;
        }
        _ = s.text(x + 2, yy, rest[0..take], .{ .fg = c_base, .bg = 52 });
        rest = rest[@min(take + 1, rest.len)..];
    }
}

// --- radar view ---------------------------------------------------------------

const pi_f: f32 = 3.14159265;

/// Approximate distance in meters from (smoothed) RSSI, using the
/// advertised TX power when present and -59 dBm @1m otherwise.
/// Path-loss exponent 2, clamped to the drawable range.
pub fn estDistanceMeters(e: *const Entry) f32 {
    if (!hasRssi(e)) return 50.0; // no signal data: park at the outer ring
    var secs_buf: [40]model.AdSection = undefined;
    const n = e.sections(&secs_buf);
    const tx: i8 = ad.txPower(secs_buf[0..n]) orelse -59;
    const dx: f32 = @as(f32, @floatFromInt(tx)) - @as(f32, @floatFromInt(e.rssiAvg()));
    return std.math.clamp(std.math.pow(f32, 10, dx / 20.0), 0.3, 50.0);
}

/// Stable pseudo-angle from the address — the layout must not flicker
/// between frames, and there is no real directional information.
fn hashAngle(key: u64) f32 {
    var h: u64 = 2166136261;
    for (@as([8]u8, @bitCast(key))) |b| h = (h ^ b) *% 16777619;
    return @as(f32, @floatFromInt(h % 3600)) / 3600.0 * 2.0 * pi_f;
}

fn deviceGlyph(e: *const Entry) u21 {
    for (e.name()) |c| {
        if (c >= '!' and c <= '~') return std.ascii.toUpper(c);
    }
    const hexd = "0123456789ABCDEF";
    return @intCast(hexd[e.addr[5] >> 4]);
}

/// Polar "radar": log-scale distance rings around the receiver.
/// Distances are signal-strength estimates; angles carry NO meaning
/// (a single antenna hears no bearing) — the glyph spread is a stable
/// hash purely to avoid overlap.
pub fn drawRadar(s: *Screen, entries: []*Entry, sel_idx: usize, now_ms: i64) void {
    if (s.w < 40 or s.h < 14) {
        drawEmpty(s, "terminal too small for the radar view");
        return;
    }

    const cx: f32 = @as(f32, @floatFromInt(s.w)) / 2.0 - (if (s.w >= 104) @as(f32, 13.0) else 0.0);
    const cy: f32 = @as(f32, @floatFromInt(s.h - 2)) / 2.0 + 0.5;
    // Cells are ~2:1; halve vertical excursions to keep circles round.
    const rmax: f32 = @min(cx - 3.0, (cy - 1.5) * 2.0);
    if (rmax < 6.0) {
        drawEmpty(s, "terminal too small for the radar view");
        return;
    }

    const ring_dim: Style = .{ .fg = 240 };
    const ringR = struct {
        fn f(d: f32, r_max: f32) f32 {
            const l = @log(d / 0.3) / @log(50.0 / 0.3);
            return r_max * l;
        }
    }.f;

    // Rings at 1/2/5/10/20 m with labels on the +x axis.
    const rings = [_]u8{ 1, 2, 5, 10, 20 };
    for (rings) |dm| {
        const d: f32 = @floatFromInt(dm);
        const rr = ringR(d, rmax);
        if (rr < 3.0) continue;
        var t: f32 = 0;
        while (t < 2.0 * pi_f) : (t += 0.06) {
            const x = cx + rr * @cos(t);
            const y = cy + rr * @sin(t) / 2.0;
            s.put(@intFromFloat(x), @intFromFloat(y), if (screen_mod.ascii) '.' else '·', ring_dim);
        }
        var lb: [8]u8 = undefined;
        const txt = if (dm < 10)
            std.fmt.bufPrint(&lb, "{d}m", .{dm}) catch ""
        else
            std.fmt.bufPrint(&lb, "{d}m", .{dm}) catch "";
        _ = s.text(@intFromFloat(cx + rr - 2), @intFromFloat(cy - rr / 4 - 0.6), txt, .{ .fg = 244 });
    }

    // Crosshair.
    var xi: i32 = @intFromFloat(cx - rmax);
    while (xi <= @as(i32, @intFromFloat(cx + rmax))) : (xi += 1) {
        s.put(@intCast(xi), @intFromFloat(cy), if (screen_mod.ascii) '.' else '·', ring_dim);
    }
    var yi: i32 = @intFromFloat(cy - rmax / 2);
    while (yi <= @as(i32, @intFromFloat(cy + rmax / 2))) : (yi += 1) {
        s.put(@intFromFloat(cx), @intCast(yi), if (screen_mod.ascii) '.' else '·', ring_dim);
    }

    // Animated sweep (purely decorative, shows the view is live).
    {
        const sweep_deg: f32 = @floatFromInt(@mod(@divTrunc(now_ms, 50), 360));
        const a = sweep_deg * pi_f / 180.0;
        var t: f32 = 2.0;
        while (t < rmax) : (t += 1.0) {
            s.put(@intFromFloat(cx + t * @cos(a)), @intFromFloat(cy + t * @sin(a) / 2.0), if (screen_mod.ascii) '|' else '│', .{ .fg = 74 });
        }
    }

    // You.
    s.put(@intFromFloat(cx), @intFromFloat(cy), if (screen_mod.ascii) '@' else '⌖', .{ .fg = 255, .bold = true });

    // Devices (input order is nearest-first; the selected entry gets
    // bracket markers).
    for (entries, 0..) |e, i| {
        const r = ringR(estDistanceMeters(e), rmax);
        const ang = hashAngle(e.key);
        var x: u32 = @intFromFloat(@max(0, cx + r * @cos(ang)));
        const y: u32 = @intFromFloat(@max(0, cy + r * @sin(ang) / 2.0));
        const selected = (i == sel_idx);
        const st: Style = if (selected)
            .{ .fg = 255, .bg = c_sel_bg, .bold = true }
        else
            .{ .fg = if (hasRssi(e)) rssiColor(e.rssiAvg()) else 240, .bold = true };
        const g = deviceGlyph(e);
        // Nudge once on collision with another glyph.
        if (isGlyph(s, x, y)) x += 1;
        if (isGlyph(s, x, y)) x -|= 2;
        if (selected) {
            s.put(x -| 1, y, '[', .{ .fg = c_accent, .bold = true });
            s.put(x + 1, y, ']', .{ .fg = c_accent, .bold = true });
        }
        s.put(x, y, g, st);
    }

    // Selected-device readout + scrolling nearest panel (shared with map mode).
    drawSelectionReadout(s, entries, sel_idx);
    drawNearestPanel(s, entries, sel_idx);
    drawFooter(s, "≈ distance from signal strength · no directional data");
}

/// Selected-device readout line under the top bar (radar + map views).
fn drawSelectionReadout(s: *Screen, entries: []*Entry, sel_idx: usize) void {
    if (entries.len == 0 or sel_idx >= entries.len) return;
    const e = entries[sel_idx];
    var nb: [17]u8 = undefined;
    var nm: []const u8 = e.name();
    if (nm.len == 0) nm = model.formatMac(e.addr, &nb);
    var db: [12]u8 = undefined;
    const dist = estDistanceMeters(e);
    const dstr = if (dist < 10)
        std.fmt.bufPrint(&db, "~{d:.1} m", .{dist}) catch ""
    else
        std.fmt.bufPrint(&db, "~{d} m", .{@as(u32, @intFromFloat(dist))}) catch "";
    var rb: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&rb, "⏎ {s} · {s} · {d} dBm", .{ nm, dstr, e.rssiAvg() }) catch "";
    s.textBounded(2, 1, line, @min(@as(u32, @intCast(line.len)), s.w -| 4), .{ .fg = c_accent, .bold = true });
}

/// Scrolling nearest-devices panel (radar + map views); follows the
/// selection like the main list.
fn drawNearestPanel(s: *Screen, entries: []*Entry, sel_idx: usize) void {
    if (s.w < 104 or entries.len == 0) return;
        const px: u32 = s.w - 26;
        const sorted = entries;
        std.mem.sort(*Entry, sorted, {}, struct {
            fn lt(_: void, a: *Entry, b: *Entry) bool {
                return a.rssiAvg() > b.rssiAvg();
            }
        }.lt);

        const rows_avail: usize = if (s.h > 11) s.h - 7 else 1;
        var top: usize = 0;
        if (sel_idx >= rows_avail / 2 and sorted.len > rows_avail) {
            top = @min(sel_idx - rows_avail / 2, sorted.len - rows_avail);
        }

        var hb: [24]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hb, "NEAREST {d}/{d}", .{ sel_idx + 1, sorted.len }) catch "NEAREST";
        _ = s.text(px, 2, hdr, .{ .fg = c_dim, .bold = true });
        if (top > 0) {
            s.put(px + 21, 2, if (screen_mod.ascii) '^' else '↑', .{ .fg = c_accent });
        }

        var row: u32 = 4;
        var i: usize = top;
        while (i < sorted.len and row < s.h - 3) : ({
            i += 1;
            row += 1;
        }) {
            const e = sorted[i];
            var db: [12]u8 = undefined;
            const dist = estDistanceMeters(e);
            const dstr = if (dist < 10)
                std.fmt.bufPrint(&db, "~{d:.1}m", .{dist}) catch ""
            else
                std.fmt.bufPrint(&db, "~{d}m", .{@as(u32, @intFromFloat(dist))}) catch "";
            const row_sel = (i == sel_idx);
            const row_st: Style = if (row_sel) .{ .fg = 255, .bg = c_sel_bg, .bold = true } else .{ .fg = c_base };
            if (row_sel) s.fillRect(px, row, 22, 1, row_st);
            s.put(px, row, if (row_sel) '>' else ' ', row_st);
            s.put(px + 1, row, deviceGlyph(e), .{ .fg = if (row_sel) 255 else rssiColor(e.rssiAvg()), .bg = row_st.bg, .bold = true });
            var nb: [17]u8 = undefined;
            var nm: []const u8 = e.name();
            if (nm.len == 0) nm = model.formatMac(e.addr, &nb);
            s.textBounded(px + 3, row, nm, 14, row_st);
            _ = s.text(px + 18, row, dstr, .{ .fg = if (row_sel) 255 else c_dim, .bg = row_st.bg });
        }
        if (i < sorted.len) {
            s.put(px + 21, s.h - 3, if (screen_mod.ascii) 'v' else '↓', .{ .fg = c_accent });
        }
}

/// Shared honesty footer for radar/map views.
fn drawFooter(s: *Screen, msg: []const u8) void {
    const mw: u32 = @intCast(msg.len);
    if (mw + 2 < s.w) {
        _ = s.text((s.w - mw) / 2, s.h - 2, msg, .{ .fg = c_dim });
    }
}

fn isGlyph(s: *Screen, x: u32, y: u32) bool {
    if (x >= s.w or y >= s.h) return true;
    const ch = s.back[@as(usize, y) * s.w + x].ch;
    return (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9');
}

/// Bounds-checked cell put from float world coordinates, clipped to the
/// map's drawable rows (between the readout and the footer).
fn putF(s: *Screen, x: f32, y: f32, ch: u21, st: Style) void {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;
    const wf: f32 = @floatFromInt(s.w);
    const y_min: f32 = 2; // below top bar + selection readout
    const y_max: f32 = @as(f32, @floatFromInt(s.h)) - 2; // above footer + hints
    if (x < 0 or x >= wf or y < y_min or y >= y_max) return;
    s.put(@intFromFloat(x), @intFromFloat(y), ch, st);
}

/// SLAM map view: devices at solved positions, dotted observer trail,
/// scale bar. Correct up to rotation/translation/mirror (no odometry).
pub fn drawMap(s: *Screen, m: *const slam_mod.Slam, entries: []*Entry, sel_idx: usize, steps: usize, now_ms: i64, observer_centered: bool) void {
    if (s.w < 40 or s.h < 14 or m.nodes.items.len == 0) {
        drawEmpty(s, if (steps == 0) "map: waiting for the first observer step…" else "terminal too small for the map view");
        return;
    }

    const cx: f32 = @as(f32, @floatFromInt(s.w)) / 2.0 - (if (s.w >= 104) @as(f32, 13.0) else 0.0);
    const cy: f32 = @as(f32, @floatFromInt(s.h - 2)) / 2.0 + 0.5;
    const rmax: f32 = @min(cx - 3.0, (cy - 1.5) * 2.0);
    if (rmax < 6.0) {
        drawEmpty(s, "terminal too small for the map view");
        return;
    }

    // Bounds over all nodes, in meters.
    var minx: f32 = 1e9;
    var miny: f32 = 1e9;
    var maxx: f32 = -1e9;
    var maxy: f32 = -1e9;
    for (m.nodes.items) |nd| {
        minx = @min(minx, nd.x);
        maxx = @max(maxx, nd.x);
        miny = @min(miny, nd.y);
        maxy = @max(maxy, nd.y);
    }
    const span_x = @max(maxx - minx, 0.5);
    const span_y = @max(maxy - miny, 0.5);
    // Camera: fit-to-content midpoint (default), or the current observer
    // position in you-centered mode (GPS-style; far discoveries may leave
    // the viewport instead of rescaling the view).
    var midx = (minx + maxx) / 2.0;
    var midy = (miny + maxy) / 2.0;
    var scale: f32 = @min((rmax * 2.0) / span_x, (rmax * 2.0) / span_y);
    if (observer_centered) {
        // Camera on the latest observer node; scale from a fixed reference
        // span (the smaller of the fitted span and ~30 m) so zoom doesn't
        // breathe with discovery while walking.
        var last_obs: ?slam_mod.Node = null;
        for (m.nodes.items) |nd| {
            if (nd.kind == .observer) last_obs = nd;
        }
        if (last_obs) |o| {
            midx = o.x;
            midy = o.y;
            const ref_span = @max(6.0, @min(@max(span_x, span_y), 30.0));
            scale = rmax * 2.0 / ref_span;
        }
    }

    // Faint meter grid: '+' at intersections of lines every grid_m meters,
    // aligned to whole meters — same linear units as the scale bar (unlike
    // the radar's log rings, this carries no distance encoding).
    {
        var grid_m: f32 = 1.0;
        while (grid_m * scale < 4.0 and grid_m < 64.0) grid_m *= 2.0;
        const gch: u21 = if (screen_mod.ascii) '+' else '·';
        var gx = @floor(minx / grid_m) * grid_m;
        while (gx <= maxx) : (gx += grid_m) {
            var gy = @floor(miny / grid_m) * grid_m;
            while (gy <= maxy) : (gy += grid_m) {
                putF(s, cx + (gx - midx) * scale, cy + (gy - midy) * scale * 0.5, gch, .{ .fg = 236 });
            }
        }
    }

    // Observer trail: dotted segments between consecutive observer nodes.
    var prev: ?slam_mod.Node = null;
    for (m.nodes.items) |nd| {
        if (nd.kind != .observer) continue;
        if (prev) |p| {
            const x0 = cx + (p.x - midx) * scale;
            const y0 = cy + (p.y - midy) * scale * 0.5;
            const x1 = cx + (nd.x - midx) * scale;
            const y1 = cy + (nd.y - midy) * scale * 0.5;
            const len = @max(@abs(x1 - x0), @abs((y1 - y0) * 2.0));
            const nsteps: usize = @intFromFloat(@max(1.0, len));
            var t: usize = 0;
            while (t < nsteps) : (t += 1) {
                const f = @as(f32, @floatFromInt(t)) / @as(f32, @floatFromInt(nsteps));
                putF(s, x0 + (x1 - x0) * f, y0 + (y1 - y0) * f, if (screen_mod.ascii) '.' else '·', .{ .fg = 240 });
            }
        }
        prev = nd;
    }

    // Devices at solved positions.
    for (m.nodes.items) |nd| {
        if (nd.kind != .device) continue;
        var e_for_node: ?*Entry = null;
        for (entries) |e| {
            if (e.key == nd.key) {
                e_for_node = e;
                break;
            }
        }
        const e = e_for_node orelse continue;
        const x: u32 = blk: {
            const fx = cx + (nd.x - midx) * scale;
            if (!std.math.isFinite(fx) or fx < 0 or fx >= @as(f32, @floatFromInt(s.w))) continue;
            break :blk @intFromFloat(fx);
        };
        const y: u32 = blk: {
            const fy = cy + (nd.y - midy) * scale * 0.5;
            if (!std.math.isFinite(fy) or fy < 2 or fy >= @as(f32, @floatFromInt(s.h)) - 2) continue;
            break :blk @intFromFloat(fy);
        };
        const selected = sel_idx < entries.len and entries[sel_idx].key == nd.key;
        const st: Style = if (selected)
            .{ .fg = 255, .bg = c_sel_bg, .bold = true }
        else
            .{ .fg = if (hasRssi(e)) rssiColor(e.rssiAvg()) else 240, .bold = true };
        if (selected) {
            s.put(x -| 1, y, '[', .{ .fg = c_accent, .bold = true });
            s.put(x + 1, y, ']', .{ .fg = c_accent, .bold = true });
        }
        s.put(x, y, deviceGlyph(e), st);
    }

    // Current observer position: pulses on the wall clock so the view
    // visibly stays live (no directional sweep — azimuths are real here).
    if (prev) |p| {
        const blink_on = @mod(@divTrunc(now_ms, 600), 2) == 0;
        const mch: u21 = if (screen_mod.ascii)
            (if (blink_on) '@' else 'O')
        else if (blink_on) '⌖' else '◎';
        putF(s, cx + (p.x - midx) * scale, cy + (p.y - midy) * scale * 0.5, mch, .{ .fg = 255, .bold = true });
    }

    // Scale bar (nice length).
    const nice: f32 = if (span_x > 40) 10 else if (span_x > 16) 5 else if (span_x > 6) 2 else 1;
    const bar_cols: u32 = @intFromFloat(@max(3.0, nice * scale));
    const bar_x: u32 = 3;
    const bar_y = s.h - 3;
    if (bar_x + bar_cols + 8 < s.w) {
        var i: u32 = 0;
        while (i < bar_cols) : (i += 1) s.put(bar_x + i, bar_y, if (screen_mod.ascii) '-' else '─', .{ .fg = 244 });
        var lb: [16]u8 = undefined;
        const txt = if (nice == @floor(nice))
            std.fmt.bufPrint(&lb, " {d} m", .{@as(u32, @intFromFloat(nice))}) catch ""
        else
            std.fmt.bufPrint(&lb, " {d:.1} m", .{nice}) catch "";
        _ = s.text(bar_x + bar_cols + 1, bar_y, txt, .{ .fg = c_dim });
    }

    // Selection readout + scrolling nearest panel (shared with the rings
    // view) and the honesty footer.
    drawSelectionReadout(s, entries, sel_idx);
    drawNearestPanel(s, entries, sel_idx);
    drawFooter(s, if (observer_centered)
        "≈ range-only SLAM · you-centered camera (z: fit view) · up to rotation/mirror"
    else
        "≈ range-only SLAM · walk turns to improve · map up to rotation/mirror");
}

pub fn drawHelpOverlay(s: *Screen) void {
    const bw: u32 = @min(46, if (s.w > 4) s.w - 4 else s.w);
    const bh: u32 = @min(16, if (s.h > 2) s.h - 2 else s.h);
    if (bw < 20 or bh < 8) return;
    const x = (s.w - bw) / 2;
    const y = (s.h - bh) / 2;

    s.fillRect(x, y, bw, bh, .{ .fg = c_base, .bg = 235 });
    s.box(x, y, bw, bh, .{ .fg = c_accent, .bg = 235 });
    _ = s.text(x + 2, y, " keys ", .{ .fg = c_accent, .bg = 235, .bold = true });

    const rows = [_][2][]const u8{
        .{ "↑↓ / j k", "move selection / scroll" },
        .{ "PgUp PgDn", "page up / down" },
        .{ "g / G", "top / bottom (detail)" },
        .{ "Enter", "open device details" },
        .{ "Esc", "back to device list" },
        .{ "s", "cycle sort mode" },
        .{ "/", "filter: text, mac: name: company: type: rssi:-70" },
        .{ "m", "cycle view: list · radar rings · SLAM map" },
        .{ "s (radar/map)", "toggle rings ↔ SLAM map · x resets the solve" },
        .{ "Esc", "clear the active filter" },
        .{ "c", "clear device list" },
        .{ "p", "pause / resume capture" },
        .{ "?", "toggle this help" },
        .{ "q / Ctrl-C", "quit" },
    };
    var yy = y + 2;
    for (rows) |r| {
        if (yy >= y + bh - 1) break;
        _ = s.text(x + 2, yy, r[0], .{ .fg = 255, .bg = 235, .bold = true });
        s.textBounded(x + 14, yy, r[1], bw -| 16, .{ .fg = c_base, .bg = 235 });
        yy += 1;
    }
}
