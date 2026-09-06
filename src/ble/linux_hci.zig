//! Linux backend: raw HCI socket capture.
//!
//! Opens an AF_BLUETOOTH/BTPROTO_HCI raw socket bound to the chosen adapter
//! (default hci0), starts an active LE scan with the duplicate filter off,
//! and converts LE advertising reports (legacy 0x02 and extended 0x0D
//! subevents) into AdvEvents. The AD-structure payload is split with the
//! same decoder the Windows path uses, so downstream decoding is identical.
//!
//! Requires root or:  setcap cap_net_raw,cap_net_admin+ep <binary>

const std = @import("std");
const builtin = @import("builtin");
const model = @import("model.zig");
const ad = @import("../decode/ad.zig");
const bus_mod = @import("../bus.zig");
const replay = @import("replay.zig");

pub const label = "linux-hci";

const af_bluetooth: u32 = 31; // AF_BLUETOOTH
const btpROTO_HCI: u32 = 1; // BTPROTO_HCI
const hci_channel_raw: u16 = 0;

// HCI commands (little-endian opcode: OGF<<10 | OCF)
const ogf_le = 0x08;
const opc_le_set_scan_params: u16 = (ogf_le << 10) | 0x000B;
const opc_le_set_scan_enable: u16 = (ogf_le << 10) | 0x000C;

// Events
const evt_cmd_complete: u8 = 0x0E;
const evt_le_meta: u8 = 0x3E;

pub const SpawnError = error{
    PermissionDenied,
    NoSuchDevice,
    SocketFailed,
    BindFailed,
    OutOfMemory,
};

pub const LinuxHci = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    b: *bus_mod.Bus,
    fd: std.posix.fd_t,
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Static failure message (reported through the bus before EOF).
    fail_msg: [256]u8 = @splat(0),

    pub fn spawn(gpa: std.mem.Allocator, io: std.Io, b: *bus_mod.Bus, adapter: []const u8) SpawnError!*LinuxHci {
        const fd: SpawnError!std.posix.fd_t = switch (builtin.os.tag) {
            .linux => linux_open: {
                const dev_id = parseAdapter(adapter);

                const rc = std.os.linux.socket(
                    af_bluetooth,
                    std.posix.SOCK.RAW | std.posix.SOCK.CLOEXEC,
                    btpROTO_HCI,
                );
                if (std.os.linux.errno(rc) != .SUCCESS) {
                    break :linux_open switch (std.os.linux.errno(rc)) {
                        .PERM, .ACCES => error.PermissionDenied,
                        else => error.SocketFailed,
                    };
                }
                const fd_res: std.posix.fd_t = @intCast(rc);
                errdefer std.posix.close(fd_res);

                // struct sockaddr_hci { sa_family_t; u16 hci_dev; u16 hci_channel; }
                var sa: std.posix.sockaddr = undefined;
                sa.family = af_bluetooth;
                std.mem.writeInt(u16, sa.data[0..2], dev_id, .little);
                std.mem.writeInt(u16, sa.data[2..4], hci_channel_raw, .little);
                const brc = std.os.linux.bind(fd_res, &sa, 6);
                switch (std.os.linux.errno(brc)) {
                    .SUCCESS => {},
                    .PERM, .ACCES => break :linux_open error.PermissionDenied,
                    .NOENT, .NODEV => break :linux_open error.NoSuchDevice,
                    else => break :linux_open error.BindFailed,
                }
                break :linux_open fd_res;
            },
            else => error.SocketFailed,
        };

        const self = try gpa.create(LinuxHci);
        self.* = .{ .gpa = gpa, .io = io, .b = b, .fd = try fd };
        return self;
    }

    pub fn hint(e: SpawnError) []const u8 {
        return switch (e) {
            error.PermissionDenied =>
                \\opening the raw HCI socket requires privileges.
                \\Either run with sudo or grant the binary the capabilities once:
                \\  sudo setcap cap_net_raw,cap_net_admin+ep <path-to>/ble-scanner
            ,
            error.NoSuchDevice => "no such Bluetooth adapter (try --adapter hciN)",
            else => "could not open the raw HCI socket",
        };
    }

    fn file(self: *LinuxHci) std.Io.File {
        return .{ .handle = self.fd, .flags = .{ .nonblocking = false } };
    }

    fn writeCmd(self: *LinuxHci, cmd: []const u8) void {
        self.file().writeStreamingAll(self.io, cmd) catch {};
    }

    /// Reader thread: start the scan, then consume events until EOF/stop.
    pub fn threadMain(self: *LinuxHci) void {
        switch (comptime builtin.os.tag) {
            .linux => self.threadMainLinux(),
            else => {},
        }
    }

    fn threadMainLinux(self: *LinuxHci) void {
        // LE Set Scan Parameters: active, 10 ms interval/window, public
        // address, accept all advertisements.
        const scan_params = [_]u8{
            opc_le_set_scan_params & 0xFF, opc_le_set_scan_params >> 8,
            0x07, // param length
            0x01, // scan type: active
            0x10, 0x00, // interval (x0.625 ms = 10 ms)
            0x10, 0x00, // window
            0x00, // own address type: public
            0x00, // filter: accept all
        };
        const scan_enable = [_]u8{
            opc_le_set_scan_enable & 0xFF, opc_le_set_scan_enable >> 8,
            0x02, // param length
            0x01, // enable
            0x00, // duplicate filter off (we aggregate per device)
        };
        self.writeCmd(&scan_params);
        self.writeCmd(&scan_enable);

        var buf: [512]u8 = undefined;
        while (!self.stopped.load(.acquire)) {
            const n = self.file().readStreaming(self.io, &.{&buf}) catch break;
            if (n == 0) break;
            self.handleEvent(buf[0..n]);
        }

        // Best-effort scan disable (only meaningful when we stopped cleanly).
        if (!self.stopped.load(.acquire)) {
            const disable = [_]u8{
                opc_le_set_scan_enable & 0xFF, opc_le_set_scan_enable >> 8,
                0x02, 0x00, 0x00,
            };
            self.writeCmd(&disable);
        }
        self.pushFailed("HCI socket closed");
    }

    fn handleEvent(self: *LinuxHci, pkt: []const u8) void {
        if (pkt.len < 2) return;
        const plen = pkt[1];
        if (pkt.len < 2 + @as(usize, plen)) return;
        const payload = pkt[2 .. 2 + plen];

        switch (pkt[0]) {
            evt_cmd_complete => {
                // [num_pkts u8, opcode u16 LE, return params (status first)]
                if (payload.len < 4) return;
                const opcode = std.mem.readInt(u16, payload[1..3], .little);
                if ((opcode == opc_le_set_scan_params or
                    opcode == opc_le_set_scan_enable) and payload[3] == 0x00)
                {
                    if (opcode == opc_le_set_scan_enable) {
                        self.b.push(.{ .backend = .{ .code = .started } });
                    }
                } else if (opcode == opc_le_set_scan_enable and payload[3] != 0x00) {
                    const msg = std.fmt.bufPrint(&self.fail_msg, "LE Set Scan Enable failed with status 0x{X:0>2}", .{payload[3]}) catch "scan enable failed";
                    self.pushFailed(msg);
                    self.stopped.store(true, .release);
                }
            },
            evt_le_meta => {
                if (payload.len < 1) return;
                switch (payload[0]) {
                    0x02 => self.handleLegacyReports(payload[1..]),
                    0x0D => self.handleExtendedReports(payload[1..]),
                    else => {},
                }
            },
            else => {},
        }
    }

    fn handleLegacyReports(self: *LinuxHci, body: []const u8) void {
        if (body.len < 1) return;
        const n = body[0];
        var p: usize = 1;
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            if (p + 10 > body.len) return; // evt_type, addr_type, addr[6], len
            const evt_type = body[p];
            const addr_type = body[p + 1];
            var addr: [6]u8 = undefined;
            for (0..6) |k| addr[k] = body[p + 2 + 5 - k]; // LE → display order
            const dlen = body[p + 8];
            p += 9;
            if (p + dlen + 1 > body.len) return;
            const data = body[p .. p + dlen];
            const rssi: i8 = @bitCast(body[p + dlen]);
            p += dlen + 1;

            self.emit(addr, addr_type, model.AdvType.fromHci(evt_type) orelse return, rssi, null, data);
        }
    }

    fn handleExtendedReports(self: *LinuxHci, body: []const u8) void {
        if (body.len < 1) return;
        const n = body[0];
        var p: usize = 1;
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            // evt_type u16, addr_type u8, addr[6], primary_phy u8, secondary_phy u8,
            // sid u8, tx i8, rssi i8, period u16, dir_type u8, dir_addr[6],
            // data_len u8, data
            if (p + 24 > body.len) return; // header before data: 2+1+6+1+1+1+1+1+2+1+6+1 = 24
            const evt_type = std.mem.readInt(u16, body[p..][0..2], .little);
            // Bits 0-1: 0x00/0x02 public, 0x01/0x03 random (2|3 = identity
            // addresses) — only bit 0 decides public vs random.
            const addr_type = body[p + 2] & 0x01;
            var addr: [6]u8 = undefined;
            for (0..6) |k| addr[k] = body[p + 3 + 5 - k];
            const tx: i8 = @bitCast(body[p + 12]);
            const rssi: i8 = @bitCast(body[p + 13]);
            const dlen = body[p + 23];
            p += 24;
            if (p + dlen > body.len) return;
            const data = body[p .. p + dlen];
            p += dlen;

            // Extended reports carry a bit-field evt_type, not the legacy
            // 0-4 enum — including for legacy PDUs (bit 4 set).
            // extAdvType() decodes both; AdvType.fromHci must never be used
            // here: non-legacy reports legitimately have evt_type 0-4 and
            // would be misread through the legacy enum.
            self.emit(addr, addr_type, extAdvType(evt_type) orelse return, rssi, tx, data);
        }
    }

    fn emit(self: *LinuxHci, addr: [6]u8, addr_type: u8, adv_type: model.AdvType, rssi: i8, tx: ?i8, data: []const u8) void {
        // Split + extract name first (into stack views), then allocate one
        // backing blob for name + section payloads — same layout as replay.
        var views: [32]ad.SecView = undefined;
        const nsecs = ad.splitSections(data, &views);
        var name: []const u8 = "";
        for (views[0..nsecs]) |v| {
            if (v.typ == 0x09 and v.data.len > 0) {
                name = v.data;
                break;
            }
            if (v.typ == 0x08 and v.data.len > 0 and name.len == 0) name = v.data;
        }

        const ev = self.gpa.create(model.AdvEvent) catch return;
        var total: usize = @min(name.len, 64);
        for (views[0..nsecs]) |v| total += v.data.len;
        const backing = self.gpa.alloc(u8, total) catch {
            self.gpa.destroy(ev);
            return;
        };
        const sections = self.gpa.alloc(model.AdSection, nsecs) catch {
            self.gpa.free(backing);
            self.gpa.destroy(ev);
            return;
        };

        var off: usize = 0;
        var ev_name: ?[]const u8 = null;
        if (name.len > 0) {
            const cn = @min(name.len, 64);
            @memcpy(backing[off..][0..cn], name[0..cn]);
            ev_name = backing[off..][0..cn];
            off += cn;
        }
        for (views[0..nsecs], 0..) |v, i| {
            @memcpy(backing[off..][0..v.data.len], v.data);
            sections[i] = .{ .typ = v.typ, .data = backing[off..][0..v.data.len] };
            off += v.data.len;
        }

        ev.* = .{
            .addr = addr,
            .addr_type = if (addr_type == 1) .random else .public,
            .adv_type = adv_type,
            .rssi = rssi,
            .name = ev_name,
            .tx_power = tx,
            .sections = sections,
            .ts_ms = replay.nowMs(self.io),
            .backing = backing,
        };
        self.b.push(.{ .adv = ev });
    }

    fn pushFailed(self: *LinuxHci, msg: []const u8) void {
        self.b.push(.{ .backend = .{ .code = .failed, .msg = msg } });
    }

    /// Disable scanning and close the socket (called on app exit).
    pub fn stop(self: *LinuxHci) void {
        self.stopped.store(true, .release);
        const disable = [_]u8{
            opc_le_set_scan_enable & 0xFF, opc_le_set_scan_enable >> 8,
            0x02, 0x00, 0x00,
        };
        self.writeCmd(&disable);
        // Close wakes the blocked readStreaming on most kernels; on
        // those where it doesn't, the process _exit() will.
        self.file().close(self.io);
    }
};

/// Extended advertising report evt_type bits → AdvType.
fn extAdvType(evt_type: u16) ?model.AdvType {
    if (evt_type & 0x08 != 0) return .scan_response; // scan response
    const connectable = evt_type & 0x01 != 0;
    const scannable = evt_type & 0x02 != 0;
    const directed = evt_type & 0x04 != 0;
    if (directed) return .connectable_directed;
    if (connectable and scannable) return .connectable_undirected;
    if (scannable) return .scannable_undirected;
    if (connectable) return .connectable_undirected;
    return .non_connectable_undirected;
}

fn parseAdapter(name: []const u8) u16 {
    // "hci0" → 0; bare numbers also accepted.
    const digits = if (std.mem.startsWith(u8, name, "hci")) name[3..] else name;
    return std.fmt.parseInt(u16, digits, 10) catch 0;
}

// --- pure parser tests (cross-platform) ----------------------------------------

const testing = std.testing;

test "parseAdapter" {
    try testing.expectEqual(@as(u16, 0), parseAdapter("hci0"));
    try testing.expectEqual(@as(u16, 3), parseAdapter("hci3"));
    try testing.expectEqual(@as(u16, 7), parseAdapter("7"));
    try testing.expectEqual(@as(u16, 0), parseAdapter("nonsense"));
}

test "extAdvType bits" {
    try testing.expectEqual(model.AdvType.connectable_undirected, extAdvType(0x0011).?); // legacy ADV_IND | legacy flag
    try testing.expectEqual(model.AdvType.non_connectable_undirected, extAdvType(0x0010).?);
    try testing.expectEqual(model.AdvType.scan_response, extAdvType(0x001B).?); // scan rsp | legacy
    try testing.expectEqual(model.AdvType.connectable_directed, extAdvType(0x0004).?);
    try testing.expectEqual(model.AdvType.scannable_undirected, extAdvType(0x0002).?);
}

// Building a synthetic legacy LE meta event and running it through the
// parse+emit path requires the full struct; instead we validate the raw
// report walker indirectly through handleEvent — covered by the splitSections
// test plus manual capture replay on hardware (see ARCHITECTURE.md).

test "command complete for LE Set Scan Enable is honored (plen 4)" {
    // Real on-air shape: HCI Event 0x0E, plen 4 = num_cmd_pkts(1) + opcode(2)
    // + status(1). LE Set Scan Enable opcode 0x200C, status 0x00.
    var bus = bus_mod.Bus.init(std.testing.io, testing.allocator);
    defer bus.deinit();
    var h = LinuxHci{ .gpa = testing.allocator, .io = std.testing.io, .b = &bus, .fd = @ptrFromInt(@as(usize, 0xDEADBEEF)) };

    const ok = [_]u8{ 0x0E, 0x04, 0x01, 0x0C, 0x20, 0x00 };
    h.handleEvent(&ok);
    try testing.expectEqual(@as(usize, 1), bus.pending()); // .started
    var evs: std.ArrayList(bus_mod.Event) = .empty;
    defer evs.deinit(testing.allocator);
    bus.popAll(&evs);
    try testing.expect(evs.items[0] == .backend and evs.items[0].backend.code == .started);

    // Failure status (0x0C = Command Disallowed) must be surfaced.
    var bus2 = bus_mod.Bus.init(std.testing.io, testing.allocator);
    defer bus2.deinit();
    var h2 = LinuxHci{ .gpa = testing.allocator, .io = std.testing.io, .b = &bus2, .fd = @ptrFromInt(@as(usize, 0xDEADBEEF)) };
    const fail = [_]u8{ 0x0E, 0x04, 0x01, 0x0C, 0x20, 0x0C };
    h2.handleEvent(&fail);
    try testing.expect(h2.stopped.load(.acquire));
    try testing.expectEqual(@as(usize, 1), bus2.pending()); // .failed
}

test "extended report: non-legacy evt_type 0 stays non-connectable, random identity maps to random" {
    // LE Meta 0x3E, subevent 0x0D, 1 report, evt_type 0x0000 (non-legacy,
    // non-connectable — the most common extended beacon), addr_type 0x03
    // (random identity), one AD section 02 01 06.
    var bus = bus_mod.Bus.init(std.testing.io, testing.allocator);
    defer bus.deinit();
    var h = LinuxHci{ .gpa = testing.allocator, .io = std.testing.io, .b = &bus, .fd = @ptrFromInt(@as(usize, 0xDEADBEEF)) };

    var pkt: [2 + 1 + 1 + 24 + 3]u8 = @splat(0);
    pkt[0] = 0x3E;
    pkt[1] = @intCast(pkt.len - 2);
    pkt[2] = 0x0D; // LE extended advertising report
    pkt[3] = 1; // num reports
    // report begins at 4
    pkt[4] = 0x00; // evt_type lo
    pkt[5] = 0x00; // evt_type hi
    pkt[6] = 0x03; // addr_type: random identity
    const le_addr = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
    @memcpy(pkt[7..13], &le_addr);
    pkt[16] = 0xFF; // tx power = -1
    pkt[17] = @bitCast(@as(i8, -70)); // rssi
    pkt[27] = 3; // data_len
    pkt[28] = 0x02;
    pkt[29] = 0x01;
    pkt[30] = 0x06;
    h.handleEvent(&pkt);

    var evs: std.ArrayList(bus_mod.Event) = .empty;
    defer {
        for (evs.items) |ev| switch (ev) {
            .adv => |a| a.deinit(testing.allocator),
            else => {},
        };
        evs.deinit(testing.allocator);
    }
    bus.popAll(&evs);
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    const a = evs.items[0].adv;
    try testing.expectEqual(model.AdvType.non_connectable_undirected, a.adv_type);
    try testing.expectEqual(model.AddrType.random, a.addr_type);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 }, &a.addr);
    try testing.expectEqual(@as(i8, -70), a.rssi);
    try testing.expectEqual(@as(i8, -1), a.tx_power.?);
    try testing.expectEqual(@as(usize, 1), a.sections.len);
}
