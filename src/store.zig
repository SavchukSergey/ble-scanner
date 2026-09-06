//! Device store: aggregates advertisement events per device (dedup by
//! address + address type), tracks RSSI statistics/history and keeps the
//! latest raw advertising payload sections for the detail view.

const std = @import("std");
const model = @import("ble/model.zig");

pub const hist_len = 64;

pub const Entry = struct {
    key: u64,
    addr: [6]u8,
    addr_type: model.AddrType,
    adv_type: model.AdvType,

    name_buf: [64]u8 = @splat(0),
    name_len: u8 = 0,
    /// Up to 3 previously-seen distinct names (rotating).
    alt_names: [3][48]u8 = @splat(@splat(0)),
    alt_lens: [3]u8 = @splat(0),
    alt_count: u8 = 0,

    first_ms: i64,
    last_ms: i64,
    count: u32 = 0,

    rssi_last: i8 = 127,
    rssi_min: i8 = 127,
    rssi_max: i8 = -128,
    rssi_sum: i64 = 0,
    rssi_n: u32 = 0,

    hist: [hist_len]i8 = @splat(0),
    hist_pos: u8 = 0,
    hist_fill: u8 = 0,

    /// Latest captured sections, copied out of the AdvEvent.
    blob: std.ArrayList(u8) = .empty,
    sec_typ: std.ArrayList(u8) = .empty,
    sec_off: std.ArrayList(u32) = .empty,
    sec_len: std.ArrayList(u32) = .empty,

    pub fn name(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn altName(self: *const Entry, i: usize) ?[]const u8 {
        if (i >= self.alt_count) return null;
        const n = self.alt_lens[i];
        if (n == 0) return null;
        return self.alt_names[i][0..n];
    }

    fn pushAltName(self: *Entry, nm: []const u8) void {
        const n = @min(nm.len, self.alt_names[0].len);
        if (n == 0) return;
        // rotate: [0] -> [1] -> [2] dropped
        var i: usize = if (self.alt_count < 3) self.alt_count else 2;
        while (i > 0) : (i -= 1) {
            self.alt_names[i] = self.alt_names[i - 1];
            self.alt_lens[i] = self.alt_lens[i - 1];
        }
        @memcpy(self.alt_names[0][0..n], nm[0..n]);
        self.alt_lens[0] = @intCast(n);
        if (self.alt_count < 3) self.alt_count += 1;
    }

    fn hasAltName(self: *const Entry, nm: []const u8) bool {
        var i: usize = 0;
        while (i < self.alt_count) : (i += 1) {
            const n = self.alt_lens[i];
            if (n == nm.len and std.mem.eql(u8, self.alt_names[i][0..n], nm)) return true;
        }
        return false;
    }

    pub fn rssiAvg(self: *const Entry) i8 {
        if (self.rssi_n == 0) return 127; // no valid sample seen
        const avg = @divTrunc(self.rssi_sum, @as(i64, self.rssi_n));
        return @intCast(std.math.clamp(avg, -128, 127));
    }

    /// Sections as (type, data) views over the blob.
    pub fn sections(self: *const Entry, out: []model.AdSection) usize {
        const n = @min(out.len, self.sec_typ.items.len);
        for (0..n) |i| {
            out[i] = .{
                .typ = self.sec_typ.items[i],
                .data = self.blob.items[self.sec_off.items[i]..][0..self.sec_len.items[i]],
            };
        }
        return n;
    }

    fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        self.blob.deinit(gpa);
        self.sec_typ.deinit(gpa);
        self.sec_off.deinit(gpa);
        self.sec_len.deinit(gpa);
        gpa.destroy(self);
    }
};

pub const max_devices = 4096;

pub const Store = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMap(u64, *Entry),
    list: std.ArrayList(*Entry) = .empty,
    /// Set when entries were added/updated; the App re-sorts its view.
    dirty: bool = false,

    pub fn init(gpa: std.mem.Allocator) !Store {
        return .{
            .gpa = gpa,
            .map = std.AutoHashMap(u64, *Entry).init(gpa),
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.list.items) |e| e.deinit(self.gpa);
        self.list.deinit(self.gpa);
        self.map.deinit();
    }

    pub fn clear(self: *Store) void {
        for (self.list.items) |e| e.deinit(self.gpa);
        self.list.clearRetainingCapacity();
        self.map.clearRetainingCapacity();
        self.dirty = true;
    }

    pub fn count(self: *const Store) usize {
        return self.list.items.len;
    }

    pub fn get(self: *Store, key: u64) ?*Entry {
        return self.map.get(key);
    }

    /// Fold one advertisement event into the store; frees the event.
    pub fn update(self: *Store, ev: *model.AdvEvent) void {
        defer ev.deinit(self.gpa);
        const key = model.addrKey(ev.addr, ev.addr_type);
        const gop = self.map.getOrPut(key) catch return;
        var e: *Entry = undefined;
        if (gop.found_existing) {
            e = gop.value_ptr.*;
        } else {
            if (self.list.items.len >= max_devices) {
                self.dropOldest();
            }
            e = self.gpa.create(Entry) catch {
                _ = self.map.remove(key); // undo the getOrPut on OOM
                return;
            };
            e.* = .{
                .key = key,
                .addr = ev.addr,
                .addr_type = ev.addr_type,
                .adv_type = ev.adv_type,
                .first_ms = ev.ts_ms,
                .last_ms = ev.ts_ms,
            };
            gop.value_ptr.* = e;
            self.list.append(self.gpa, e) catch {
                _ = self.map.remove(key);
                e.deinit(self.gpa);
                return;
            };
        }

        e.last_ms = ev.ts_ms;
        e.adv_type = ev.adv_type;
        e.count += 1;
        // RSSI of -127/-128 is the stack's "not measured" marker — don't
        // let it poison the statistics, history or radar placement.
        if (ev.rssi > -120) {
            e.rssi_last = ev.rssi;
            if (ev.rssi < e.rssi_min) e.rssi_min = ev.rssi;
            if (ev.rssi > e.rssi_max) e.rssi_max = ev.rssi;
            e.rssi_sum += ev.rssi;
            e.rssi_n += 1;
            e.hist[e.hist_pos % hist_len] = ev.rssi;
            e.hist_pos = (e.hist_pos + 1) % hist_len;
            if (e.hist_fill < hist_len) e.hist_fill += 1;
        } else if (e.count == 1) {
            e.rssi_last = 127; // no valid sample yet
        }

        // Name: prefer explicit, then the 0x09/0x08 section. Distinct new
        // names rotate the previous one into the history list.
        var nm: []const u8 = ev.name orelse "";
        if (nm.len == 0) {
            nm = localNameFromSections(ev.sections);
        }
        if (nm.len > 0) {
            const n = @min(nm.len, e.name_buf.len);
            if (n != e.name_len or !std.mem.eql(u8, nm[0..n], e.name_buf[0..n])) {
                // different name: remember the old one (if any, not a dupe)
                if (e.name_len > 0 and !e.hasAltName(e.name_buf[0..e.name_len])) {
                    e.pushAltName(e.name_buf[0..e.name_len]);
                }
                @memcpy(e.name_buf[0..n], nm[0..n]);
                e.name_len = @intCast(n);
            }
        }

        copySections(self, e, ev.sections);
        self.dirty = true;
    }

    fn dropOldest(self: *Store) void {
        var oldest_idx: usize = 0;
        var oldest_ms: i64 = std.math.maxInt(i64);
        for (self.list.items, 0..) |e, i| {
            if (e.last_ms < oldest_ms) {
                oldest_ms = e.last_ms;
                oldest_idx = i;
            }
        }
        if (self.list.items.len == 0) return;
        const e = self.list.orderedRemove(oldest_idx);
        _ = self.map.remove(e.key);
        e.deinit(self.gpa);
    }

    pub fn entries(self: *const Store) []*Entry {
        return self.list.items;
    }
};

fn localNameFromSections(sections: []const model.AdSection) []const u8 {
    var fallback: []const u8 = "";
    for (sections) |s| {
        if (s.typ == 0x09 and s.data.len > 0) return sanitizeName(s.data);
        if (s.typ == 0x08 and s.data.len > 0) fallback = sanitizeName(s.data);
    }
    return fallback;
}
/// Trim trailing NUL/space, then cut at the first control character
/// (byte < 0x20 or 0x7F). Does NOT validate UTF-8 — a malformed multi-byte
/// sequence can pass through untouched; Screen.text()/textBounded() are
/// the layer responsible for degrading invalid UTF-8 to '?' at render
/// time, not this function.
fn sanitizeName(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == 0 or s[end - 1] == ' ')) end -= 1;
    for (s[0..end], 0..) |c, i| {
        if (c < 0x20 or c == 0x7F) return s[0..i]; // cut at first control
    }
    return s[0..end];
}

/// Merge incoming sections into the entry's snapshot, per section type:
/// BLE devices split their payload between ADV and SCAN_RSP frames, so a
/// name-only scan response must not wipe the manufacturer data from the
/// preceding advertisement. Latest non-empty section of each type wins.
fn copySections(self: *Store, e: *Entry, sections: []const model.AdSection) void {
    var views: [64]model.AdSection = undefined;
    var n = e.sections(&views);
    // Which stored views this event has already replaced. BLE allows
    // several same-type structures in one frame (e.g. two 0x02 UUID-list
    // sections) — they are distinct entries and must all survive, while
    // across separate events latest-per-type still wins.
    var replaced: [64]bool = @splat(false);

    for (sections) |s| {
        if (s.data.len == 0) continue;
        var found = false;
        for (views[0..n], 0..) |*v, vi| {
            if (v.typ == s.typ and !replaced[vi]) {
                v.data = s.data;
                replaced[vi] = true;
                found = true;
                break;
            }
        }
        if (!found and n < views.len) {
            views[n] = .{ .typ = s.typ, .data = s.data };
            replaced[n] = true;
            n += 1;
        }
    }

    // The merged view data can alias e.blob (they were read out of it), so
    // stage the new payload in a scratch buffer first, then rewrite.
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(self.gpa);
    var offs: [64]u32 = undefined;
    var total: usize = 0;
    const max_blob: usize = 4096;
    for (views[0..n], 0..) |v, i| {
        offs[i] = @intCast(total); // valid for all i < n_staged
        if (total + v.data.len > max_blob) break; // stop staging
        scratch.appendSlice(self.gpa, v.data) catch return;
        total += v.data.len;
    }
    // Count only the successfully staged views.
    const n_staged: usize = blk: {
        var cnt: usize = 0;
        for (views[0..n], 0..) |v, i| {
            if (offs[i] + v.data.len > total) break;
            cnt = i + 1;
        }
        break :blk cnt;
    };

    e.blob.clearRetainingCapacity();
    e.sec_typ.clearRetainingCapacity();
    e.sec_off.clearRetainingCapacity();
    e.sec_len.clearRetainingCapacity();
    for (views[0..n_staged], 0..) |v, i| {
        e.blob.appendSlice(self.gpa, scratch.items[offs[i]..][0..v.data.len]) catch return;
        e.sec_typ.append(self.gpa, v.typ) catch return;
        e.sec_off.append(self.gpa, offs[i]) catch return;
        e.sec_len.append(self.gpa, @intCast(v.data.len)) catch return;
    }
}

// tests -----------------------------------------------------------------------

const testing = std.testing;
const widgets_hasRssi = @import("tui/widgets.zig").hasRssi;

test "aggregate events per device" {
    var store = try Store.init(testing.allocator);
    defer store.deinit();

    const mk = struct {
        fn ev(rssi: i8, ts: i64, name: ?[]const u8) *model.AdvEvent {
            const a = testing.allocator;
            const e = a.create(model.AdvEvent) catch unreachable;
            e.* = .{
                .addr = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF },
                .addr_type = .random,
                .adv_type = .connectable_undirected,
                .rssi = rssi,
                .name = name,
                .ts_ms = ts,
            };
            return e;
        }
    };

    store.update(mk.ev(-60, 1000, null));
    store.update(mk.ev(-50, 2000, "Band"));
    store.update(mk.ev(-70, 3000, null));

    try testing.expectEqual(@as(usize, 1), store.count());
    const e = store.get(model.addrKey(.{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF }, .random)).?;
    try testing.expectEqual(@as(u32, 3), e.count);
    try testing.expectEqual(@as(i8, -70), e.rssi_last);
    try testing.expectEqual(@as(i8, -70), e.rssi_min);
    try testing.expectEqual(@as(i8, -50), e.rssi_max);
    try testing.expectEqual(@as(i8, -60), e.rssiAvg());
    try testing.expectEqualStrings("Band", e.name());
    try testing.expectEqual(@as(i64, 1000), e.first_ms);
    try testing.expectEqual(@as(i64, 3000), e.last_ms);
    try testing.expectEqual(@as(u8, 3), e.hist_fill);

    // Names rotate into history when they change.
    store.update(mk.ev(-60, 5000, "Alpha"));
    store.update(mk.ev(-61, 6000, "Beta"));
    store.update(mk.ev(-62, 7000, "Gamma"));
    const e2 = store.get(model.addrKey(.{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF }, .random)).?;
    try testing.expectEqualStrings("Gamma", e2.name());
    try testing.expectEqualStrings("Beta", e2.altName(0).?);
    try testing.expectEqualStrings("Alpha", e2.altName(1).?);
    try testing.expectEqualStrings("Band", e2.altName(2).?); // from the first part of this test
    // Repeating the current name must not duplicate history.
    store.update(mk.ev(-63, 8000, "Gamma"));
    store.update(mk.ev(-64, 9000, "Alpha"));
    try testing.expectEqualStrings("Alpha", e2.name());
    try testing.expectEqualStrings("Gamma", e2.altName(0).?);
    try testing.expectEqualStrings("Beta", e2.altName(1).?);

    // RSSI of -127 ("not measured") must not pollute statistics: a fresh
    // device whose only sample is invalid keeps the sentinel, not garbage.
    const probe = testing.allocator.create(model.AdvEvent) catch unreachable;
    probe.* = .{
        .addr = .{ 2, 2, 2, 2, 2, 2 },
        .addr_type = .random,
        .adv_type = .connectable_undirected,
        .rssi = -127,
        .ts_ms = 500,
    };
    store.update(probe);
    const e3 = store.get(model.addrKey(.{ 2, 2, 2, 2, 2, 2 }, .random)).?;
    try testing.expectEqual(@as(i8, 127), e3.rssi_last);
    try testing.expectEqual(@as(i8, 127), e3.rssiAvg());
    try testing.expectEqual(@as(u32, 0), e3.rssi_n);
    try testing.expectEqual(@as(u32, 1), e3.count);
    try testing.expectEqual(@as(u8, 0), e3.hist_fill);
    try testing.expect(widgets_hasRssi(e3) == false);

    // Different address type → separate device.
    const other = mk.ev(-40, 4000, null);
    other.addr_type = .public;
    store.update(other);
    try testing.expectEqual(@as(usize, 3), store.count());
}

test "sections merge across ADV and SCAN_RSP" {
    var store = try Store.init(testing.allocator);
    defer store.deinit();

    const mkEv = struct {
        fn ev(secs_in: []const model.AdSection) *model.AdvEvent {
            const a = testing.allocator;
            const e = a.create(model.AdvEvent) catch unreachable;
            e.* = .{
                .addr = .{ 1, 2, 3, 4, 5, 6 },
                .addr_type = .random,
                .adv_type = .connectable_undirected,
                .rssi = -60,
                .sections = a.dupe(model.AdSection, secs_in) catch unreachable,
                .ts_ms = 1000,
            };
            return e;
        }
    }.ev;

    // ADV_IND: flags + manufacturer data (Garmin 0x0087).
    const adv_data = [_]u8{ 0x87, 0x00, 0x0C, 0x05 };
    const flags_data = [_]u8{0x06};
    const adv_secs = [_]model.AdSection{
        .{ .typ = 0x01, .data = &flags_data },
        .{ .typ = 0xFF, .data = &adv_data },
    };
    store.update(mkEv(&adv_secs));

    // SCAN_RSP: complete local name only.
    const name_secs = [_]model.AdSection{
        .{ .typ = 0x09, .data = "Forerunner" },
    };
    store.update(mkEv(&name_secs));

    const e = store.get(model.addrKey(.{ 1, 2, 3, 4, 5, 6 }, .random)).?;
    try testing.expectEqualStrings("Forerunner", e.name());

    var out: [8]model.AdSection = undefined;
    const n = e.sections(&out);
    var has_flags = false;
    var has_mfr = false;
    var has_name = false;
    for (out[0..n]) |s| {
        switch (s.typ) {
            0x01 => has_flags = true,
            0xFF => {
                has_mfr = true;
                try testing.expectEqualSlices(u8, &adv_data, s.data);
            },
            0x09 => has_name = true,
            else => {},
        }
    }
    try testing.expect(has_flags and has_mfr and has_name);
}

test "same-type sections within one advertisement are kept distinct" {
    var store = try Store.init(testing.allocator);
    defer store.deinit();

    // Real shape from wild17 (YUNMAI-family scale): two 0x02 UUID-list
    // sections in a single frame. The merge used to collapse them,
    // silently dropping 0x1310 and breaking service-based classification.
    const mkEv = struct {
        fn ev(secs_in: []const model.AdSection) *model.AdvEvent {
            const a = testing.allocator;
            const e = a.create(model.AdvEvent) catch unreachable;
            e.* = .{
                .addr = .{ 0x5C, 0xF8, 0x21, 0xD5, 0xCC, 0x30 },
                .addr_type = .public,
                .adv_type = .connectable_undirected,
                .rssi = -100,
                .sections = a.dupe(model.AdSection, secs_in) catch unreachable,
                .ts_ms = 1000,
            };
            return e;
        }
    }.ev;
    const adv = [_]model.AdSection{
        .{ .typ = 0x01, .data = &.{0x06} },
        .{ .typ = 0x02, .data = &.{ 0x10, 0x13 } },
        .{ .typ = 0x02, .data = &.{ 0x12, 0x58 } },
        .{ .typ = 0xFF, .data = &[_]u8{ 0x30, 0xCC, 0xD5, 0x21, 0xF8, 0x5C, 0x00, 0x00 } },
    };
    store.update(mkEv(&adv));

    const e = store.get(model.addrKey(.{ 0x5C, 0xF8, 0x21, 0xD5, 0xCC, 0x30 }, .public)).?;
    var out: [8]model.AdSection = undefined;
    const n = e.sections(&out);
    try testing.expectEqual(@as(usize, 4), n);
    var seen_1310 = false;
    var seen_5812 = false;
    for (out[0..n]) |s| {
        if (s.typ != 0x02) continue;
        if (std.mem.eql(u8, s.data, &.{ 0x10, 0x13 })) seen_1310 = true;
        if (std.mem.eql(u8, s.data, &.{ 0x12, 0x58 })) seen_5812 = true;
    }
    try testing.expect(seen_1310 and seen_5812);

    // A later event still refreshes per-type across events (latest wins
    // for the first slot) without duplicating.
    const adv2 = [_]model.AdSection{
        .{ .typ = 0x01, .data = &.{0x06} },
    };
    store.update(mkEv(&adv2));
    try testing.expectEqual(@as(usize, 4), e.sections(&out));
}
