//! Windows backend: spawns the embedded PowerShell watcher script (which
//! runs a WinRT BluetoothLEAdvertisementWatcher as inline C#) and converts
//! its JSONL output into AdvEvents on the bus.

const std = @import("std");
const model = @import("model.zig");
const replay = @import("replay.zig");
const bus_mod = @import("../bus.zig");

const ps_script = @embedFile("win_scanner.ps1");

pub const label = "win-ps";

pub const WinPs = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    b: *bus_mod.Bus,
    child: std.process.Child,

    /// Set by the stderr drain thread; surfaced on failure.
    err_buf: [1024]u8 = @splat(0),
    err_len: usize = 0,
    err_mutex: std.Io.Mutex = .init,
    /// Set once before pushing a failure event; message points into err_buf
    /// (or is static), valid until the app consumes it.
    fail_msg: []const u8 = "",

    pub fn spawn(gpa: std.mem.Allocator, io: std.Io, b: *bus_mod.Bus) !*WinPs {
        const enc = try encodeCommand(gpa, ps_script);
        defer gpa.free(enc);

        const argv = [_][]const u8{
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-EncodedCommand",
            enc,
        };

        const child = try std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        });

        const self = try gpa.create(WinPs);
        self.* = .{ .gpa = gpa, .io = io, .b = b, .child = child };

        // stderr drain (diagnostics only; the script reports errors in-band)
        const t = std.Thread.spawn(.{}, stderrMain, .{self}) catch |e| {
            var child_mut = child;
            child_mut.kill(io);
            gpa.destroy(self);
            return e;
        };
        t.detach();

        return self;
    }

    /// Reader thread: consumes stdout lines until EOF.
    pub fn threadMain(self: *WinPs) void {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.gpa);
        var buf: [4096]u8 = undefined;

        const out = self.child.stdout orelse return;
        outer: while (true) {
            const n = out.readStreaming(self.io, &.{buf[0..]}) catch break;
            if (n == 0) break;
            for (buf[0..n]) |c| {
                if (c == '\n') {
                    self.handleLine(std.mem.trim(u8, line.items, " \r\t"));
                    line.clearRetainingCapacity();
                } else {
                    line.append(self.gpa, c) catch break :outer;
                }
            }
        }
        if (line.items.len > 0) self.handleLine(std.mem.trim(u8, line.items, " \r\t"));

        // EOF: surface stderr (if any) as the failure reason.
        self.pushFailure("backend process exited");
    }

    fn handleLine(self: *WinPs, line: []const u8) void {
        if (line.len == 0) return;
        if (std.mem.startsWith(u8, line, "{\"status\"")) {
            if (std.mem.indexOf(u8, line, "started") != null) {
                self.b.push(.{ .backend = .{ .code = .started } });
            } else if (std.mem.indexOf(u8, line, "stopped") != null) {
                self.b.push(.{ .backend = .{ .code = .stopped } });
            }
            return;
        }
        if (std.mem.startsWith(u8, line, "{\"error\"")) {
            // {"error":"..."} — extract the message for display.
            const open = std.mem.indexOfScalar(u8, line, ':') orelse return;
            var msg = std.mem.trim(u8, line[open + 1 ..], " \"}");
            const m = self.copyErr(msg) catch msg;
            msg = m;
            self.pushFailure(msg);
            return;
        }
        const ev = replay.parseLine(self.gpa, line, 0) catch return;
        self.b.push(.{ .adv = ev });
    }

    fn pushFailure(self: *WinPs, msg: []const u8) void {
        if (msg.len == 0) {
            self.err_mutex.lockUncancelable(self.io);
            const err = self.err_buf[0..self.err_len];
            self.err_mutex.unlock(self.io);
            if (err.len > 0) {
                self.b.push(.{ .backend = .{ .code = .failed, .msg = err } });
                return;
            }
        }
        self.b.push(.{ .backend = .{ .code = .failed, .msg = msg } });
    }

    fn copyErr(self: *WinPs, msg: []const u8) ![]const u8 {
        if (msg.len == 0 or msg.len > self.err_buf.len) return msg;
        self.err_mutex.lockUncancelable(self.io);
        defer self.err_mutex.unlock(self.io);
        const start = if (self.err_len + msg.len + 1 > self.err_buf.len) 0 else self.err_len;
        @memcpy(self.err_buf[start..][0..msg.len], msg);
        self.err_len = start + msg.len;
        return self.err_buf[start..][0..msg.len];
    }

    fn stderrMain(self: *WinPs) void {
        const f = self.child.stderr orelse return;
        var buf: [512]u8 = undefined;
        while (true) {
            const n = f.readStreaming(self.io, &.{buf[0..]}) catch break;
            if (n == 0) break;
            _ = self.copyErr(buf[0..n]) catch break;
        }
    }

    /// Kill the child process (called on app exit).
    pub fn stop(self: *WinPs) void {
        self.child.kill(self.io);
    }
};

/// Base64 (UTF-16LE) encoding required by powershell -EncodedCommand.
fn encodeCommand(gpa: std.mem.Allocator, script: []const u8) ![]u8 {
    // The script is ASCII; UTF-16LE is a simple 2-byte-per-char expansion.
    const wide_len = script.len * 2;
    const wide = try gpa.alloc(u8, wide_len);
    defer gpa.free(wide);
    for (script, 0..) |c, i| {
        wide[i * 2] = c;
        wide[i * 2 + 1] = 0;
    }
    const enc = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, enc.calcSize(wide_len));
    _ = enc.encode(out, wide);
    return out;
}

test "encodeCommand produces decodable base64" {
    const enc = try encodeCommand(std.testing.allocator, "Write-Output 'hi'");
    defer std.testing.allocator.free(enc);
    const dec = std.base64.standard.Decoder;
    const size = try dec.calcSizeForSlice(enc);
    const wide = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(wide);
    try dec.decode(wide, enc);
    try std.testing.expectEqual(@as(usize, 2 * "Write-Output 'hi'".len), size);
    // UTF-16LE round trip
    try std.testing.expectEqual(@as(u8, 'W'), wide[0]);
    try std.testing.expectEqual(@as(u8, 0), wide[1]);
}
