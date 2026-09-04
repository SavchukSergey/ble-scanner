//! Application state: view routing, key handling, event folding, and the
//! detail-view content builder.

const std = @import("std");
const store_mod = @import("store.zig");
const model = @import("ble/model.zig");
const ad = @import("decode/ad.zig");
const classify = @import("decode/classify.zig");
const vendors = @import("decode/vendors.zig");
const services = @import("db/services.zig");
const appearance_db = @import("db/appearance.zig");
const widgets = @import("tui/widgets.zig");
const input = @import("tui/input.zig");
const filter_mod = @import("filter.zig");
const slam_mod = @import("slam.zig");

pub const SortMode = enum(u2) {
    last_seen,
    rssi,
    name,
    mac,

    pub fn label(self: SortMode) []const u8 {
        return switch (self) {
            .last_seen => "last seen",
            .rssi => "rssi",
            .name => "name",
            .mac => "mac",
        };
    }
};

pub const View = enum { list, detail, radar };

pub const BackendCode = enum { starting, started, stopped, failed };

/// Detail-view construction budgets. Lines reference slices into
/// `detail_txt`; both arrays are pre-reserved to these capacities so
/// pointers stay valid for the lifetime of a build (no realloc).
const detail_txt_cap: usize = 32 * 1024;
const detail_line_cap: usize = 300;

pub const App = struct {
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    backend_label: []const u8,

    view: View = .list,
    overlay_help: bool = false,
    quit: bool = false,
    paused: bool = false,
    show_raw: bool = false,
    sort: SortMode = .last_seen,
    backend_code: BackendCode = .starting,
    backend_msg: [512]u8 = @splat(0),
    backend_msg_len: usize = 0,

    /// Device filter ('/' prompt; see filter.zig for the syntax).
    filter: filter_mod.Filter = .{},
    filter_edit: bool = false,
    filter_buf: [96]u8 = @splat(0),
    filter_len: usize = 0,

    /// Range-only SLAM map ('s' inside the radar view).
    slam: slam_mod.Slam,
    map_mode: bool = false,
    slam_last_step_ms: i64 = 0,
    slam_steps: usize = 0,

    ordered: std.ArrayList(*store_mod.Entry) = .empty,
    radar_order: std.ArrayList(*store_mod.Entry) = .empty,
    sel_key: ?u64 = null,
    /// Where Esc from the detail view returns to (list or radar).
    detail_return: View = .list,

    detail_key: ?u64 = null,
    detail_scroll: u32 = 0,
    detail_lines: std.ArrayList(widgets.Line) = .empty,
    detail_txt: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, s: *store_mod.Store, backend: []const u8) App {
        return .{ .gpa = gpa, .store = s, .backend_label = backend, .slam = slam_mod.Slam.init(gpa) };
    }

    pub fn deinit(self: *App) void {
        self.ordered.deinit(self.gpa);
        self.radar_order.deinit(self.gpa);
        self.detail_lines.deinit(self.gpa);
        self.detail_txt.deinit(self.gpa);
        self.slam.deinit();
    }

    pub fn handleAdv(self: *App, ev: *model.AdvEvent) void {
        if (self.paused) {
            ev.deinit(self.gpa);
            return;
        }
        self.store.update(ev);
    }

    pub fn handleBackend(self: *App, ev: @import("bus.zig").BackendEvent) void {
        self.backend_code = switch (ev.code) {
            .started => .started,
            .stopped => .stopped,
            .failed => .failed,
        };
        if (ev.msg) |m| {
            const n = @min(m.len, self.backend_msg.len);
            @memcpy(self.backend_msg[0..n], m[0..n]);
            self.backend_msg_len = n;
        } else {
            self.backend_msg_len = 0;
        }
    }

    pub fn handleKey(self: *App, k: input.Key) void {
        if (self.overlay_help) {
            self.overlay_help = false;
            return;
        }
        if (k.code == .ctrl_c) {
            self.quit = true;
            return;
        }
        if (self.filter_edit) {
            self.handleFilterEditKey(k);
            return;
        }
        if (k.code == .char and k.ch == 'q') {
            self.quit = true;
            return;
        }
        if (k.code == .char and k.ch == '?') {
            self.overlay_help = true;
            return;
        }
        switch (self.view) {
            .list => self.handleListKey(k),
            .radar => self.handleRadarKey(k),
            .detail => self.handleDetailKey(k),
        }
    }

    fn handleRadarKey(self: *App, k: input.Key) void {
        switch (k.code) {
            .escape => self.view = .list,
            .up => self.moveRadarSel(false),
            .down => self.moveRadarSel(true),
            .page_up => self.moveRadarSel(false),
            .page_down => self.moveRadarSel(true),
            .home => {
                if (self.radar_order.items.len > 0) self.sel_key = self.radar_order.items[0].key;
            },
            .end => {
                if (self.radar_order.items.len > 0) {
                    self.sel_key = self.radar_order.items[self.radar_order.items.len - 1].key;
                }
            },
            .enter => self.openDetail(.radar),
            .char => switch (k.ch) {
                'm' => self.view = .list,
                's' => {
                    self.map_mode = !self.map_mode;
                    if (self.map_mode) self.slam_last_step_ms = 0; // step immediately
                },
                'x' => {
                    self.slam.reset();
                    self.slam_steps = 0;
                },
                'j', 'k' => {
                    const down = k.ch == 'j';
                    self.moveRadarSel(down);
                },
                // Sorting/raw are list-only presentations; everything else
                // behaves like the list so navigation stays uniform.
                'r' => {},
                else => self.handleListKey(k),
            },
            else => self.handleListKey(k),
        }
    }

    fn moveRadarSel(self: *App, down: bool) void {
        const n = self.radar_order.items.len;
        if (n == 0) return;
        const idx = self.radarSelIndex();
        const new_idx = if (down) @min(idx + 1, n - 1) else idx -| 1;
        self.sel_key = self.radar_order.items[new_idx].key;
    }

    fn openDetail(self: *App, from: View) void {
        const list = switch (from) {
            .radar => self.radar_order.items,
            else => self.ordered.items,
        };
        if (list.len == 0) return;
        const idx = switch (from) {
            .radar => self.radarSelIndex(),
            else => self.selIndex(),
        };
        self.detail_key = list[idx].key;
        self.detail_scroll = 0;
        self.detail_return = from;
        self.view = .detail;
    }

    fn handleFilterEditKey(self: *App, k: input.Key) void {
        switch (k.code) {
            .enter => {
                self.filter = filter_mod.parse(self.filter_buf[0..self.filter_len]);
                self.filter_edit = false;
                self.store.dirty = true; // re-filter
            },
            .escape => self.filter_edit = false,
            .backspace => {
                if (self.filter_len > 0) self.filter_len -= 1;
            },
            .char => |c| {
                _ = c;
                if (self.filter_len < self.filter_buf.len) {
                    self.filter_buf[self.filter_len] = k.ch;
                    self.filter_len += 1;
                }
            },
            else => {},
        }
    }

    /// True when this entry passes the active filter.
    fn filterMatches(self: *App, e: *store_mod.Entry) bool {
        if (!self.filter.active()) return true;
        var secs_buf: [40]model.AdSection = undefined;
        const n = e.sections(&secs_buf);
        const secs = secs_buf[0..n];
        const m = classify.classify(secs, e.name());
        var mac: [17]u8 = undefined;
        return filter_mod.matches(&self.filter, .{
            .mac = model.formatMac(e.addr, &mac),
            .name = e.name(),
            .company = classify.companyHint(secs) orelse "",
            .kind = m.detail orelse m.kind.label(),
            .rssi = e.rssi_last,
        });
    }

    fn handleListKey(self: *App, k: input.Key) void {
        const n = self.ordered.items.len;
        switch (k.code) {
            .up => self.moveSel(false),
            .down => self.moveSel(true),
            .page_up => {
                if (n > 0) {
                    const idx = self.selIndex() -| 10;
                    self.sel_key = self.ordered.items[idx].key;
                }
            },
            .page_down => {
                if (n > 0) {
                    const idx = @min(self.selIndex() + 10, n - 1);
                    self.sel_key = self.ordered.items[idx].key;
                }
            },
            .home => if (n > 0) {
                self.sel_key = self.ordered.items[0].key;
            },
            .end => if (n > 0) {
                self.sel_key = self.ordered.items[n - 1].key;
            },
            .enter => self.openDetail(.list),
            .escape => {
                if (self.filter.active()) {
                    self.filter = .{}; // clear filter
                    self.store.dirty = true;
                }
            },
            .char => switch (k.ch) {
                '/' => {
                    self.filter_edit = true;
                    self.filter_len = self.filter.raw_len;
                    @memcpy(self.filter_buf[0..self.filter_len], self.filter.rawText());
                },
                'j' => self.moveSel(true),
                'k' => self.moveSel(false),
                's' => {
                    self.sort = switch (self.sort) {
                        .last_seen => .rssi,
                        .rssi => .name,
                        .name => .mac,
                        .mac => .last_seen,
                    };
                    self.store.dirty = true;
                },
                'c' => {
                    self.store.clear();
                    self.sel_key = null;
                    self.slam.reset();
                    self.slam_steps = 0;
                },
                'p' => self.paused = !self.paused,
                'r' => self.show_raw = !self.show_raw,
                'm' => self.view = .radar,
                'f' => {
                    self.filter_edit = true;
                    self.filter_len = self.filter.raw_len;
                    @memcpy(self.filter_buf[0..self.filter_len], self.filter.rawText());
                },
                else => {},
            },
            else => {},
        }
    }

    /// Feed the SLAM solver: one observer step every few seconds while
    /// map mode is active, using current distance estimates as ranges.
    fn slamTick(self: *App, now_ms: i64) void {
        if (now_ms - self.slam_last_step_ms < 4000) return;
        self.slam_last_step_ms = now_ms;
        self.slam.beginStep();
        for (self.ordered.items) |e| {
            if (!widgets.hasRssi(e)) continue;
            self.slam.observe(e.key, widgets.estDistanceMeters(e), e.count);
        }
        self.slam.solve(12);
        self.slam_steps += 1;
    }

    fn moveSel(self: *App, down: bool) void {
        const n = self.ordered.items.len;
        if (n == 0) return;
        const idx = self.selIndex();
        const new_idx = if (down) @min(idx + 1, n - 1) else idx -| 1;
        self.sel_key = self.ordered.items[new_idx].key;
    }

    fn handleDetailKey(self: *App, k: input.Key) void {
        const max_scroll: u32 = if (self.detail_lines.items.len > 2)
            @intCast(self.detail_lines.items.len - 2)
        else
            0;
        switch (k.code) {
            .escape => self.view = self.detail_return,
            .up => self.detail_scroll -|= 1,
            .down => self.detail_scroll = @min(self.detail_scroll + 1, max_scroll),
            .page_up => self.detail_scroll -|= 10,
            .page_down => self.detail_scroll = @min(self.detail_scroll + 10, max_scroll),
            .home => self.detail_scroll = 0,
            .end => self.detail_scroll = max_scroll,
            .char => switch (k.ch) {
                'j' => self.detail_scroll = @min(self.detail_scroll + 1, max_scroll),
                'k' => self.detail_scroll -|= 1,
                'g' => self.detail_scroll = 0,
                'G' => self.detail_scroll = max_scroll,
                else => {},
            },
            else => {},
        }
    }

    pub fn selIndex(self: *App) usize {
        return self.selIndexIn(self.ordered.items);
    }

    pub fn radarSelIndex(self: *App) usize {
        return self.selIndexIn(self.radar_order.items);
    }

    fn selIndexIn(self: *App, list: []*store_mod.Entry) usize {
        const n = list.len;
        if (n == 0) return 0;
        const want = self.sel_key orelse {
            self.sel_key = list[0].key;
            return 0;
        };
        for (list, 0..) |e, i| {
            if (e.key == want) return i;
        }
        self.sel_key = list[0].key;
        return 0;
    }

    /// Re-sort the view if the store changed.
    pub fn refreshOrder(self: *App) void {
        if (!self.store.dirty) return;
        self.store.dirty = false;
        self.ordered.clearRetainingCapacity();
        self.ordered.appendSlice(self.gpa, self.store.entries()) catch return;
        const Ctx = struct {
            mode: SortMode,
            fn lessThan(ctx: @This(), a: *store_mod.Entry, b: *store_mod.Entry) bool {
                switch (ctx.mode) {
                    .last_seen => {
                        if (a.last_ms != b.last_ms) return a.last_ms > b.last_ms;
                        return a.key < b.key;
                    },
                    .rssi => {
                        if (a.rssi_last != b.rssi_last) return a.rssi_last > b.rssi_last;
                        return a.key < b.key;
                    },
                    .name => {
                        const an = a.name();
                        const bn = b.name();
                        if (an.len == 0 and bn.len == 0) return a.key < b.key;
                        if (an.len == 0) return false;
                        if (bn.len == 0) return true;
                        const c = std.mem.order(u8, an, bn);
                        if (c != .eq) return c == .lt;
                        return a.key < b.key;
                    },
                    .mac => return a.key < b.key,
                }
            }
        };
        std.mem.sort(*store_mod.Entry, self.ordered.items, Ctx{ .mode = self.sort }, Ctx.lessThan);

        // Apply the device filter (in place).
        if (self.filter.active()) {
            var w: usize = 0;
            for (self.ordered.items) |e| {
                if (self.filterMatches(e)) {
                    self.ordered.items[w] = e;
                    w += 1;
                }
            }
            self.ordered.shrinkRetainingCapacity(w);
        }

        // Radar navigation order: nearest (strongest signal) first.
        self.radar_order.clearRetainingCapacity();
        self.radar_order.appendSlice(self.gpa, self.ordered.items) catch return;
        const RadarCtx = struct {
            fn lessThan(_: void, a: *store_mod.Entry, b: *store_mod.Entry) bool {
                return a.rssiAvg() > b.rssiAvg();
            }
        };
        std.mem.sort(*store_mod.Entry, self.radar_order.items, {}, RadarCtx.lessThan);
    }

    pub fn draw(self: *App, s: *widgets.Screen, now_ms: i64) void {
        s.clear();
        if (self.view == .list) {
            widgets.drawTopBar(s, self.backend_label, self.store.count(), now_ms, self.paused, self.sort.label(), if (self.filter.active()) self.filter.rawText() else null);
            widgets.drawListBody(s, self.ordered.items, self.selIndex(), self.listTop(s), now_ms, self.show_raw);
            if (self.store.count() == 0) {
                widgets.drawEmpty(s, switch (self.backend_code) {
                    .starting => "starting backend…",
                    .failed => "backend failed — press q to quit",
                    .stopped => "backend stopped",
                    .started => if (self.paused) "paused — press p to resume" else "listening for BLE advertisements…",
                });
            } else if (self.ordered.items.len == 0) {
                widgets.drawEmpty(s, "no devices match the filter");
            }
            if (self.filter_edit) {
                widgets.drawFilterInput(s, self.filter_buf[0..self.filter_len]);
            } else {
                widgets.drawHints(s, widgets.Hints.list);
            }
        } else if (self.view == .radar) {
            widgets.drawTopBar(s, self.backend_label, self.store.count(), now_ms, self.paused, self.sort.label(), if (self.filter.active()) self.filter.rawText() else null);
            if (self.map_mode) {
                self.slamTick(now_ms);
                widgets.drawMap(s, &self.slam, self.radar_order.items, self.radarSelIndex(), self.slam_steps);
            } else {
                widgets.drawRadar(s, self.radar_order.items, self.radarSelIndex(), now_ms);
            }
            if (self.ordered.items.len == 0) {
                widgets.drawEmpty(s, if (self.store.count() == 0) "listening for BLE advertisements…" else "no devices match the filter");
            }
            if (self.filter_edit) {
                widgets.drawFilterInput(s, self.filter_buf[0..self.filter_len]);
            } else if (self.view == .radar and self.map_mode) {
                widgets.drawHints(s, "↑↓ select · ⏎ details · s rings · x reset map · m list · ? help · q quit");
            } else {
                widgets.drawHints(s, widgets.Hints.radar);
            }
        } else if (self.detail_key != null and self.store.get(self.detail_key.?) != null) {
            self.buildDetail(self.store.get(self.detail_key.?).?, now_ms);
            widgets.drawDetailBody(s, self.detail_lines.items, self.detail_scroll);
            widgets.drawHints(s, widgets.Hints.detail);
        } else {
            self.view = .list;
            widgets.drawTopBar(s, self.backend_label, self.store.count(), now_ms, self.paused, self.sort.label(), if (self.filter.active()) self.filter.rawText() else null);
            widgets.drawHints(s, widgets.Hints.list);
        }
        if (self.overlay_help) widgets.drawHelpOverlay(s);
        if (self.backend_code == .failed and self.backend_msg_len > 0) {
            widgets.drawErrorBox(s, "backend failed", self.backend_msg[0..self.backend_msg_len]);
        }
    }

    fn listTop(self: *App, s: *widgets.Screen) usize {
        const vh: usize = if (s.h > 3) s.h - 3 else 0;
        const idx = self.selIndex();
        const n = self.ordered.items.len;
        if (n == 0 or vh == 0) return 0;
        if (idx >= vh / 2 and n > vh) {
            return @min(idx - vh / 2, n - vh);
        }
        return 0;
    }

    // --- detail view construction ------------------------------------------

    fn put(self: *App, kind: widgets.LineKind, comptime fmt: []const u8, args: anytype) void {
        if (self.detail_lines.items.len >= detail_line_cap) return;
        var tmp: [480]u8 = undefined;
        const str = std.fmt.bufPrint(&tmp, fmt, args) catch tmp[0..0];
        if (self.detail_txt.items.len + str.len > detail_txt_cap) return;
        const start = self.detail_txt.items.len;
        self.detail_txt.appendSlice(self.gpa, str) catch return;
        self.detail_lines.append(self.gpa, .{
            .kind = kind,
            .text = self.detail_txt.items[start..],
        }) catch {};
    }

    fn buildDetail(self: *App, e: *store_mod.Entry, now_ms: i64) void {
        self.detail_lines.clearRetainingCapacity();
        self.detail_txt.clearRetainingCapacity();
        self.detail_txt.ensureTotalCapacity(self.gpa, detail_txt_cap) catch {};
        self.detail_lines.ensureTotalCapacity(self.gpa, detail_line_cap) catch {};

        var secs_buf: [40]model.AdSection = undefined;
        const nsecs = e.sections(&secs_buf);
        const secs = secs_buf[0..nsecs];

        var mac: [17]u8 = undefined;
        self.put(.title, "Device {s}  ({s} address, last {s})", .{
            model.formatMac(e.addr, &mac),
            @tagName(e.addr_type),
            e.adv_type.short(),
        });

        const match = classify.classify(secs, e.name());

        self.put(.section, "IDENTITY", .{});
        self.put(.label, "  Name           {s}", .{if (e.name().len > 0) e.name() else "(none advertised)"});
        if (e.alt_count > 0) {
            var nb: [200]u8 = undefined;
            var w: usize = 0;
            var i: usize = 0;
            while (i < e.alt_count) : (i += 1) {
                const an = e.altName(i) orelse continue;
                if (w > 0 and w < nb.len) {
                    nb[w] = ',';
                    w += 1;
                    if (w < nb.len) {
                        nb[w] = ' ';
                        w += 1;
                    }
                }
                const n = @min(an.len, nb.len - w);
                @memcpy(nb[w..][0..n], an[0..n]);
                w += n;
            }
            self.put(.dim, "  also seen      {s}", .{nb[0..w]});
        }
        self.put(.label, "  Type           {s}", .{match.detail orelse match.kind.label()});
        if (ad.manufacturer(secs)) |m| {
            const cn = classify.companyHint(secs);
            self.put(.label, "  Manufacturer   0x{X:0>4} {s}", .{ m.company, cn orelse "" });
        }
        if (ad.appearance(secs)) |ap| {
            self.put(.label, "  Appearance     {s} (0x{X:0>4})", .{ appearance_db.nameFor(ap), ap });
        }
        var tb: [12]u8 = undefined;
        var cb: [12]u8 = undefined;
        self.put(.label, "  First seen     {s}  ({d} events)", .{ widgets.fmtClock(e.first_ms, &tb), e.count });
        self.put(.label, "  Last seen      {s} ago", .{ widgets.fmtAge(now_ms - e.last_ms, &cb) });

        self.put(.section, "RADIO", .{});
        self.put(.label, "  RSSI  now {d}  min {d}  avg {d}  max {d} dBm", .{ e.rssi_last, e.rssi_min, e.rssiAvg(), e.rssi_max });
        self.put(.text, "  history  {s}", .{histSpark(e)});

        if (ad.txPower(secs)) |tx| {
            self.put(.label, "  TX power       {d} dBm (advertised)", .{tx});
        }

        // Services (16/32/128-bit, complete or incomplete lists alike).
        var uuids: [16]u16 = undefined;
        const nu = ad.serviceUuids16(secs, &uuids);
        var uuids32: [4]u32 = undefined;
        const n32 = ad.serviceUuids32(secs, &uuids32);
        var uuids128: [2][16]u8 = undefined;
        const n128 = ad.serviceUuids128(secs, &uuids128);
        if (nu > 0 or n32 > 0 or n128 > 0 or ad.serviceData16(secs) != null) {
            self.put(.section, "SERVICES", .{});
            for (uuids[0..nu]) |u| {
                self.put(.text, "  0x{X:0>4}  {s}", .{ u, services.lookup(u) orelse "vendor-specific" });
            }
            for (uuids32[0..n32]) |u| {
                self.put(.text, "  0x{X:0>8}  vendor-specific", .{u});
            }
            for (uuids128[0..n128]) |u| {
                var ub: [36]u8 = undefined;
                self.put(.text, "  {s}  vendor-specific", .{uuid128Str(&u, &ub)});
            }
            if (ad.serviceData16(secs)) |sd| {
                self.put(.text, "  service data on 0x{X:0>4} {s}", .{ sd.uuid, services.lookup(sd.uuid) orelse "vendor-specific" });
            }
        }

        self.putVendorDecodes(e, secs);
        self.putDecodedPayloads(secs);

        // Raw sections, with interpreted values where the format is known.
        self.put(.section, "RAW ADVERTISING DATA", .{});
        var hexbuf: [512]u8 = undefined;
        var valbuf: [160]u8 = undefined;
        for (secs) |sec| {
            const nm = ad.sectionName(sec.typ);
            const val: []const u8 = rawSectionValue(sec, &valbuf) orelse model.hexEncode(sec.data, &hexbuf);
            self.put(.hex, "  0x{X:0>2} {s: <28} {s}", .{ sec.typ, nm orelse "-", val });
        }
    }

    /// Human-readable value for a raw AD section where the format is known
    /// (UUID lists get decoded from little-endian, names become text, tx
    /// power becomes dBm, appearance gets its name); null -> caller falls
    /// back to hex.
    fn rawSectionValue(sec: model.AdSection, buf: []u8) ?[]const u8 {
        switch (sec.typ) {
            0x01 => { // flags
                if (sec.data.len < 1) return null;
                var fb: [96]u8 = undefined;
                const s = ad.flagDescriptions(sec.data[0], &fb);
                const n = copyTo(buf, s);
                return buf[0..n];
            },
            0x02, 0x03, 0x14, 0x1F => { // 16-bit UUID lists
                var w: usize = 0;
                w += copyTo(buf[w..], "[");
                var i: usize = 0;
                var n: usize = 0;
                while (i + 2 <= sec.data.len and n < 8) : ({
                    i += 2;
                    n += 1;
                }) {
                    if (n > 0) w += copyTo(buf[w..], ", ");
                    const s = std.fmt.bufPrint(buf[w..][0..8], "0x{X:0>4}", .{std.mem.readInt(u16, sec.data[i..][0..2], .little)}) catch break;
                    w += s.len;
                }
                if (i < sec.data.len) w += copyTo(buf[w..], " …");
                w += copyTo(buf[w..], "]");
                return buf[0..w];
            },
            0x04, 0x05, 0x20 => { // 32-bit UUID lists
                if (sec.data.len < 4) return null;
                return std.fmt.bufPrint(buf, "[0x{X:0>8}]", .{std.mem.readInt(u32, sec.data[0..4], .little)}) catch null;
            },
            0x06, 0x07, 0x21 => { // 128-bit UUIDs
                if (sec.data.len < 16) return null;
                var u: [16]u8 = undefined;
                for (0..16) |k| u[k] = sec.data[15 - k];
                var ub: [36]u8 = undefined;
                const s = uuid128Str(&u, &ub);
                if (sec.data.len > 16) {
                    return std.fmt.bufPrint(buf, "{s} (+{d} more)", .{ s, (sec.data.len / 16) - 1 }) catch null;
                }
                const n = copyTo(buf, s);
                return buf[0..n];
            },
            0x08, 0x09 => { // local names
                if (sec.data.len == 0) return null;
                var w: usize = 0;
                for (sec.data) |c| {
                    if (w >= buf.len - 1) break;
                    buf[w] = if (c >= 0x20 and c < 0x7F) c else '?';
                    w += 1;
                }
                return buf[0..w];
            },
            0x0A => { // tx power
                if (sec.data.len < 1) return null;
                return std.fmt.bufPrint(buf, "{d} dBm", .{@as(i8, @bitCast(sec.data[0]))}) catch null;
            },
            0x19 => { // appearance
                if (sec.data.len < 2) return null;
                const ap = std.mem.readInt(u16, sec.data[0..2], .little);
                return std.fmt.bufPrint(buf, "0x{X:0>4} ({s})", .{ ap, appearance_db.nameFor(ap) }) catch null;
            },
            else => return null,
        }
    }

    fn copyTo(buf: []u8, s: []const u8) usize {
        const n = @min(s.len, buf.len);
        @memcpy(buf[0..n], s[0..n]);
        return n;
    }

    fn putVendorDecodes(self: *App, e: *store_mod.Entry, secs: []const model.AdSection) void {
        if (ad.manufacturer(secs)) |m| {
            if (m.company == 0x004C) {
                if (classify.parseIBeacon(m)) |b| {
                    self.put(.section, "IBEACON", .{});
                    var ub: [40]u8 = undefined;
                    var w: usize = 0;
                    for (b.uuid, 0..) |byte, idx| {
                        if (idx > 0 and idx % 4 == 0 and w < ub.len) {
                            ub[w] = '-';
                            w += 1;
                        }
                        const s = std.fmt.bufPrint(ub[w..][0..2], "{X:0>2}", .{byte}) catch break;
                        w += s.len;
                    }
                    self.put(.text, "  UUID     {s}", .{ub[0..w]});
                    self.put(.text, "  major {d}  minor {d}  tx@1m {d} dBm", .{ b.major, b.minor, b.tx_1m });
                    self.put(.accent, "  estimated distance ~ {d:.1} m", .{classify.estimateDistance(b.tx_1m, e.rssi_last)});
                }
            }
        }
        if (ad.serviceData16(secs)) |sd| {
            if (sd.uuid == 0xFEAA) {
                self.put(.section, "EDDYSTONE", .{});
                var url_buf: [128]u8 = undefined;
                switch (classify.parseEddystone(sd.data, &url_buf)) {
                    .url => |u| self.put(.accent, "  URL      {s}", .{u.url}),
                    .uid => |u| {
                        var nb: [24]u8 = undefined;
                        const hex = model.hexEncode(&u.namespace, &nb);
                        self.put(.text, "  UID      namespace {s}", .{hex});
                    },
                    .tlm => |t| self.put(.text, "  TLM      battery {d} mV, temp {d}.{d} °C, adv {d}, uptime {d} s", .{ t.vbatt, @divTrunc(t.temp_cx10, 10), @abs(@mod(t.temp_cx10, 10)), t.adv_cnt, t.sec_cnt }),
                    .unknown_frame => self.put(.dim, "  (unrecognized frame)", .{}),
                }
            }
        }
    }

    /// Vendor payload decoders (decode/vendors.zig) rendered as a
    /// "DECODED PAYLOAD" section.
    fn putDecodedPayloads(self: *App, secs: []const model.AdSection) void {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var wrote = false;

        if (ad.manufacturer(secs)) |m| {
            if (vendors.decodeMfr(m.company, m.payload, &aw.writer)) wrote = true;
        }
        if (ad.serviceData16(secs)) |sd| {
            if (vendors.decodeSvcData(sd.uuid, sd.data, &aw.writer)) wrote = true;
        }
        if (!wrote) return;
        aw.writer.flush() catch return;

        self.put(.section, "DECODED PAYLOAD", .{});
        var it = std.mem.splitScalar(u8, aw.written(), '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            self.put(.text, "  {s}", .{line});
        }
    }

    fn uuid128Str(bytes: *const [16]u8, buf: *[36]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}-{s}-{s}-{s}-{s}", .{
            std.fmt.bytesToHex(bytes[0..4].*, .lower),
            std.fmt.bytesToHex(bytes[4..6].*, .lower),
            std.fmt.bytesToHex(bytes[6..8].*, .lower),
            std.fmt.bytesToHex(bytes[8..10].*, .lower),
            std.fmt.bytesToHex(bytes[10..16].*, .lower),
        }) catch "?";
    }

    fn histSpark(e: *store_mod.Entry) []const u8 {
        const S = struct {
            var buf: [128]u8 = undefined;
        };
        const want: u8 = 48;
        var w: usize = 0;
        const fill = e.hist_fill;
        const start: u8 = if (fill > want) e.hist_pos + store_mod.hist_len - want else e.hist_pos + store_mod.hist_len - fill;
        const count = @min(fill, want);
        var i: u8 = 0;
        while (i < count) : (i += 1) {
            const r = e.hist[(start + i) % store_mod.hist_len];
            const g = widgets.barGlyph(widgets.rssiBucket(r));
            if (w + g.len > S.buf.len) break;
            @memcpy(S.buf[w..][0..g.len], g);
            w += g.len;
        }
        return S.buf[0..w];
    }
};
