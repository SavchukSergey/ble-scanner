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

/// "5s" / "12m" / "3h" for a duration in ms.
pub fn fmtAge(ms: i64, buf: []u8) []const u8 {
    const s = @divTrunc(ms, 1000);
    if (s < 0) return "now";
    if (s < 60) return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "now";
    const m = @divTrunc(s, 60);
    if (m < 60) return std.fmt.bufPrint(buf, "{d}m", .{m}) catch "now";
    return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(m, 60)}) catch "now";
}

/// HH:MM:SS (UTC) from epoch ms.
pub fn fmtClock(ms: i64, buf: []u8) []const u8 {
    const s: u64 = @intCast(@mod(@divFloor(ms, 1000), 86400));
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ s / 3600, (s / 60) % 60, s % 60 }) catch "--:--:--";
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
    pub const list = "↑↓ select · ⏎ details · / filter · r raw · s sort · c clear · p pause · ? help · q quit";
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
            const bar = std.fmt.bufPrint(&rb, "{s} {d}", .{ barGlyph(rssiBucket(e.rssi_last)), e.rssi_last }) catch "-";
            _ = s.text(c.x_rssi, y, bar, .{ .fg = rssiColor(e.rssi_last), .bg = base.bg });
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
