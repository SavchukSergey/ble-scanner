//! ble-scanner — TUI BLE advertising scanner.
//!
//! Backends: replay (any OS), win-ps (Windows, embedded PowerShell + WinRT
//! watcher). linux-hci is planned (M1).

const std = @import("std");

const model = @import("ble/model.zig");
const replay_mod = @import("ble/replay.zig");
const win_ps_mod = @import("ble/win_ps.zig");
const linux_hci_mod = @import("ble/linux_hci.zig");
const scanner = @import("ble/scanner.zig");
const bus_mod = @import("bus.zig");
const store_mod = @import("store.zig");
const app_mod = @import("app.zig");
const log_mod = @import("log.zig");
const terminal_mod = @import("tui/terminal.zig");
const screen_mod = @import("tui/screen.zig");
const input = @import("tui/input.zig");

const usage =
    \\ble-scanner — TUI BLE advertising scanner
    \\
    \\usage:
    \\  ble-scanner                      live scan (win-ps on Windows, linux-hci on Linux)
    \\  ble-scanner --replay FILE        run from a recorded JSONL capture
    \\  ble-scanner --log FILE           also record events to FILE (any mode)
    \\  ble-scanner --seconds N --log F  headless capture for N seconds (no terminal)
    \\  ble-scanner --selftest           headless render test (needs --replay)
    \\  ble-scanner --ascii              ASCII glyphs (hostile terminal fonts)
    \\  ble-scanner --size WxH           virtual size for --selftest (default 110x32)
    \\  ble-scanner --backend KIND       auto | linux-hci | win-ps | replay
    \\  ble-scanner --adapter NAME       BLE adapter to use (linux-hci, M1)
    \\  ble-scanner --help               this help
    \\
    \\keys:
    \\  ↑↓/jk select · ⏎ details · s sort · c clear · p pause · ? help · q quit
    \\
;

const Options = struct {
    replay: ?[]const u8 = null,
    log: ?[]const u8 = null,
    seconds: ?u32 = null,
    selftest: bool = false,
    ascii: bool = false,
    width: u32 = 110,
    height: u32 = 32,
    backend: scanner.Kind = .auto,
    adapter: []const u8 = "hci0",
    help: bool = false,
};

fn parseArgs(args: []const [:0]const u8) ?Options {
    var o: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            o.help = true;
        } else if (std.mem.eql(u8, a, "--selftest")) {
            o.selftest = true;
        } else if (std.mem.eql(u8, a, "--ascii")) {
            o.ascii = true;
        } else if (std.mem.eql(u8, a, "--replay")) {
            i += 1;
            if (i >= args.len) return null;
            o.replay = args[i];
        } else if (std.mem.startsWith(u8, a, "--replay=")) {
            o.replay = a["--replay=".len..];
        } else if (std.mem.eql(u8, a, "--log")) {
            i += 1;
            if (i >= args.len) return null;
            o.log = args[i];
        } else if (std.mem.startsWith(u8, a, "--log=")) {
            o.log = a["--log=".len..];
        } else if (std.mem.eql(u8, a, "--seconds")) {
            i += 1;
            if (i >= args.len) return null;
            o.seconds = std.fmt.parseInt(u32, args[i], 10) catch return null;
        } else if (std.mem.startsWith(u8, a, "--seconds=")) {
            o.seconds = std.fmt.parseInt(u32, a["--seconds=".len..], 10) catch return null;
        } else if (std.mem.eql(u8, a, "--size")) {
            i += 1;
            if (i >= args.len) return null;
            const x = std.mem.indexOfScalar(u8, args[i], 'x') orelse return null;
            o.width = std.fmt.parseInt(u32, args[i][0..x], 10) catch return null;
            o.height = std.fmt.parseInt(u32, args[i][x + 1 ..], 10) catch return null;
        } else if (std.mem.eql(u8, a, "--backend")) {
            i += 1;
            if (i >= args.len) return null;
            o.backend = scanner.Kind.parse(args[i]) orelse return null;
        } else if (std.mem.startsWith(u8, a, "--backend=")) {
            o.backend = scanner.Kind.parse(a["--backend=".len..]) orelse return null;
        } else if (std.mem.eql(u8, a, "--adapter")) {
            i += 1;
            if (i >= args.len) return null;
            o.adapter = args[i];
        } else {
            return null; // unknown flag
        }
    }
    return o;
}

/// A running capture backend (only one per process).
const Runner = struct {
    impl: Impl,
    thread: std.Thread,

    const Impl = union(enum) {
        replay: *replay_mod.Replay,
        win_ps: *win_ps_mod.WinPs,
        linux_hci: *linux_hci_mod.LinuxHci,
    };

    fn label(self: Runner) []const u8 {
        return switch (self.impl) {
            .replay => "replay",
            .win_ps => win_ps_mod.label,
            .linux_hci => linux_hci_mod.label,
        };
    }

    fn stop(self: Runner) void {
        switch (self.impl) {
            .replay => |r| {
                r.requestStop();
                self.thread.join();
                r.close();
            },
            .win_ps => |w| {
                w.stop();
                self.thread.join();
                w.gpa.destroy(w);
            },
            .linux_hci => |h| {
                h.stop();
                // The blocked read may not wake on close on all kernels;
                // detach and let process exit clean up.
                self.thread.detach();
                h.gpa.destroy(h);
            },
        }
    }
};

fn startRunner(io: std.Io, gpa: std.mem.Allocator, b: *bus_mod.Bus, opts: Options) !Runner {
    var kind = opts.backend;
    if (opts.replay != null and kind == .auto) kind = .replay;
    if (kind == .auto) kind = scanner.Kind.defaultForOs();
    switch (kind) {
        .replay => {
            const path = opts.replay orelse return error.ReplayFileRequired;
            const r = try replay_mod.Replay.open(gpa, io, path, true);
            const t = std.Thread.spawn(.{}, replayThreadMain, .{ r, b }) catch |e| {
                r.close();
                return e;
            };
            return .{ .impl = .{ .replay = r }, .thread = t };
        },
        .win_ps => {
            const w = try win_ps_mod.WinPs.spawn(gpa, io, b);
            const t = std.Thread.spawn(.{}, winPsThreadMain, .{w}) catch |e| {
                w.stop();
                gpa.destroy(w);
                return e;
            };
            return .{ .impl = .{ .win_ps = w }, .thread = t };
        },
        .linux_hci => {
            const h = linux_hci_mod.LinuxHci.spawn(gpa, io, b, opts.adapter) catch |e| {
                try errPrint(io, "error: {s}\n", .{linux_hci_mod.LinuxHci.hint(e)});
                return e;
            };
            const t = std.Thread.spawn(.{}, linuxHciThreadMain, .{h}) catch |e| {
                h.stop();
                gpa.destroy(h);
                return e;
            };
            return .{ .impl = .{ .linux_hci = h }, .thread = t };
        },
        else => return error.NotImplemented,
    }
}

fn replayThreadMain(rep: *replay_mod.Replay, b: *bus_mod.Bus) void {
    rep.run(b, true);
}

fn winPsThreadMain(w: *win_ps_mod.WinPs) void {
    w.threadMain();
}

fn linuxHciThreadMain(h: *linux_hci_mod.LinuxHci) void {
    h.threadMain();
}

/// Free any events still queued after a backend stopped (adv events carry
/// heap allocations that must be released to keep the debug allocator
/// quiet).
fn drainFree(b: *bus_mod.Bus, gpa: std.mem.Allocator, events: *std.ArrayList(bus_mod.Event)) void {
    events.clearRetainingCapacity();
    b.popAll(events);
    for (events.items) |ev| switch (ev) {
        .adv => |a| a.deinit(gpa),
        .key, .backend => {},
    };
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(args) orelse {
        try errPrint(io, "error: bad arguments\n\n{s}", .{usage});
        return 2;
    };
    if (opts.help) {
        try outPrint(io, "{s}", .{usage});
        return 0;
    }
    screen_mod.ascii = opts.ascii;

    if (opts.selftest) return runSelftest(io, gpa, opts);
    if (opts.seconds != null) return runCapture(io, gpa, opts);

    const kind = if (opts.replay != null and opts.backend == .auto) .replay else opts.backend;
    if (!kind.implemented()) {
        try errPrint(io,
            \\error: backend '{s}' is not available on this OS.
            \\
            \\Available here: replay (always), win-ps (Windows), linux-hci (Linux).
            \\
            \\Run from a recording:
            \\  ble-scanner --replay fixtures/demo.jsonl
            \\or headless-capture with the default backend:
            \\  ble-scanner --seconds 30 --log capture.jsonl
            \\
        , .{kind.label()});
        return 1;
    }
    if (kind == .replay and opts.replay == null) {
        try errPrint(io, "error: --replay FILE is required with the replay backend\n\n{s}", .{usage});
        return 2;
    }

    return runInteractive(io, gpa, opts);
}

// --- headless capture ---------------------------------------------------------

fn runCapture(io: std.Io, gpa: std.mem.Allocator, opts: Options) !u8 {
    const log_path = opts.log orelse {
        try errPrint(io, "error: --seconds N requires --log FILE\n\n{s}", .{usage});
        return 2;
    };

    var bus = bus_mod.Bus.init(io, gpa);
    var runner = startRunner(io, gpa, &bus, opts) catch |e| {
        try errPrint(io, "error: cannot start backend: {t}\n", .{e});
        return 1;
    };
    errdefer runner.stop();

    var log_file = std.Io.Dir.cwd().createFile(io, log_path, .{}) catch |e| {
        try errPrint(io, "error: cannot open log file '{s}': {t}\n", .{ log_path, e });
        return 1;
    };
    defer log_file.close(io);

    var n_events: usize = 0;
    var n_devices: usize = 0;
    var seen = std.AutoHashMap(u64, void).init(gpa);
    defer seen.deinit();

    var logw: std.Io.Writer.Allocating = .init(gpa);
    defer logw.deinit();

    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(
        std.Io.Duration.fromSeconds(@intCast(opts.seconds.?)),
    );
    var events: std.ArrayList(bus_mod.Event) = .empty;
    defer events.deinit(gpa);

    while (true) {
        const now = std.Io.Timestamp.now(io, .awake);
        if (now.nanoseconds >= deadline.nanoseconds) break;

        events.clearRetainingCapacity();
        bus.popAll(&events);
        var failed = false;
        for (events.items) |ev| {
            switch (ev) {
                .adv => |a| {
                    logw.clearRetainingCapacity();
                    log_mod.writeEvent(&logw.writer, a) catch {};
                    logw.writer.flush() catch {};
                    log_file.writeStreamingAll(io, logw.written()) catch {};
                    n_events += 1;
                    const key = model.addrKey(a.addr, a.addr_type);
                    const gop = seen.getOrPut(key) catch continue;
                    if (!gop.found_existing) n_devices += 1;
                    a.deinit(gpa);
                },
                .backend => |be| if (be.code == .failed) {
                    failed = true;
                    if (be.msg) |m| try errPrint(io, "backend failed: {s}\n", .{m});
                },
                .key => {},
            }
        }
        if (failed) break;
        io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }

    // Stop the backend, then free everything still queued.
    runner.stop();
    drainFree(&bus, gpa, &events);
    bus.deinit();

    try outPrint(io, "captured {d} events from {d} devices -> {s}\n", .{ n_events, n_devices, log_path });
    return 0;
}

// --- interactive ---------------------------------------------------------------

fn runInteractive(io: std.Io, gpa: std.mem.Allocator, opts: Options) !u8 {
    var term = terminal_mod.Terminal.init(io) catch |e| {
        try errPrint(io, "error: {t} (both stdin and stdout must be a terminal)\n", .{e});
        return 1;
    };
    defer term.deinit();

    const sz = term.size();
    var screen = try screen_mod.Screen.init(gpa, sz.w, sz.h);
    defer screen.deinit();

    var bus = bus_mod.Bus.init(io, gpa);
    var store = try store_mod.Store.init(gpa);
    defer store.deinit();

    var runner = startRunner(io, gpa, &bus, opts) catch |e| {
        try errPrint(io, "error: cannot start backend: {t}\n", .{e});
        return 1;
    };

    var app = app_mod.App.init(gpa, &store, runner.label());
    defer app.deinit();

    const input_thread = std.Thread.spawn(.{}, input.threadMain, .{ io, &bus }) catch |e| {
        try errPrint(io, "error: cannot spawn input thread: {t}\n", .{e});
        return 1;
    };
    input_thread.detach();

    var log_file: ?std.Io.File = null;
    var log_err = false;
    if (opts.log) |lp| {
        log_file = std.Io.Dir.cwd().createFile(io, lp, .{}) catch |e| blk: {
            log_err = true;
            try errPrint(io, "warning: cannot open log file '{s}': {t} (continuing without)\n", .{ lp, e });
            break :blk null;
        };
    }
    defer if (log_file) |f| f.close(io);
    _ = &log_err;

    var events: std.ArrayList(bus_mod.Event) = .empty;
    defer events.deinit(gpa);
    var frame: std.Io.Writer.Allocating = .init(gpa);
    defer frame.deinit();
    var logbuf: std.Io.Writer.Allocating = .init(gpa);
    defer logbuf.deinit();

    var need_draw = true;
    var last_hb: i64 = 0;

    while (!app.quit) {
        const now = replay_mod.nowMs(io);

        events.clearRetainingCapacity();
        bus.popAll(&events);
        var had_events = false;
        for (events.items) |ev| {
            had_events = true;
            switch (ev) {
                .adv => |a| {
                    if (log_file != null) {
                        logbuf.clearRetainingCapacity();
                        log_mod.writeEvent(&logbuf.writer, a) catch {};
                        logbuf.writer.flush() catch {};
                        log_file.?.writeStreamingAll(io, logbuf.written()) catch {};
                    }
                    app.handleAdv(a);
                },
                .key => |k| app.handleKey(k),
                .backend => |be| app.handleBackend(be),
            }
        }
        if (had_events) {
            app.refreshOrder();
            need_draw = true;
        }

        const cur = term.size();
        if (cur.w != screen.w or cur.h != screen.h) {
            try screen.resize(cur.w, cur.h);
            need_draw = true;
        }
        if (now - last_hb >= 500) {
            last_hb = now;
            need_draw = true; // clock + ages
        }

        if (need_draw and !app.quit) {
            app.draw(&screen, now);
            frame.clearRetainingCapacity();
            try screen.render(&frame.writer);
            try frame.writer.flush();
            try term.writeAll(frame.written());
            need_draw = false;
        }

        if (!had_events) {
            io.sleep(std.Io.Duration.fromMilliseconds(15), .awake) catch {};
        }
    }

    runner.stop();
    drainFree(&bus, gpa, &events);
    bus.deinit();
    if (log_file) |f| f.close(io);
    log_file = null;
    return 0;
}

// --- selftest ------------------------------------------------------------------

fn runSelftest(io: std.Io, gpa: std.mem.Allocator, opts: Options) !u8 {
    const path = opts.replay orelse "fixtures/demo.jsonl";
    const rep = replay_mod.Replay.open(gpa, io, path, false) catch |e| {
        try errPrint(io, "error: cannot read replay file '{s}': {t}\n", .{ path, e });
        return 1;
    };
    defer rep.close();

    var store = try store_mod.Store.init(gpa);
    defer store.deinit();
    var app = app_mod.App.init(gpa, &store, "replay(selftest)");
    defer app.deinit();
    var screen = try screen_mod.Screen.init(gpa, opts.width, opts.height);
    defer screen.deinit();

    // Feed all events synchronously, tracking the max timestamp.
    var max_ts: i64 = 0;
    var it = std.mem.splitScalar(u8, rep.data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        const ev = replay_mod.parseLine(gpa, trimmed, 0) catch continue;
        if (ev.ts_ms > max_ts) max_ts = ev.ts_ms;
        app.handleAdv(ev);
    }
    const now = max_ts + 2000;
    app.refreshOrder();
    if (store.count() == 0) {
        try errPrint(io, "selftest: no events parsed from {s}\n", .{path});
        return 1;
    }

    const press = struct {
        fn key(a: *app_mod.App, code: input.Code, ch: u8) void {
            a.handleKey(.{ .code = code, .ch = ch });
        }
    }.key;

    // Frame 1: initial list.
    app.draw(&screen, now);
    try dumpFrame(io, gpa, &screen, "frame 1: list (initial)");
    if (app.selIndex() != 0) {
        try errPrint(io, "selftest: initial selection {d} != 0\n", .{app.selIndex()});
        return 1;
    }

    // Small screen: the scrollbar must appear on the right edge.
    {
        var small = try screen_mod.Screen.init(gpa, opts.width, 12);
        defer small.deinit();
        app.draw(&small, now);
        try dumpFrame(io, gpa, &small, "frame 1b: small screen (scrollbar)");
        var saw_scrollbar = false;
        var y: u32 = 2;
        while (y < 12 - 1) : (y += 1) {
            const cell = small.back[@as(usize, y) * small.w + (small.w - 1)];
            if (cell.ch == '┆' or cell.ch == '█' or cell.ch == '|' or cell.ch == '#') saw_scrollbar = true;
        }
        if (!saw_scrollbar and store.count() > 9) {
            try errPrint(io, "selftest: scrollbar not rendered on small screen\n", .{});
            return 1;
        }
    }

    // Move down twice, draw.
    press(&app, .char, 'j');
    press(&app, .char, 'j');
    app.draw(&screen, now);
    if (store.count() >= 3) {
        if (app.selIndex() != 2) {
            try errPrint(io, "selftest: selection after jj {d} != 2\n", .{app.selIndex()});
            return 1;
        }
    }

    // Open details of the third entry.
    press(&app, .enter, 0);
    app.draw(&screen, now);
    if (app.view != .detail) {
        try errPrint(io, "selftest: enter did not open detail view\n", .{});
        return 1;
    }
    try dumpFrame(io, gpa, &screen, "frame 2: detail (3rd device)");

    // Scroll the detail view.
    press(&app, .char, 'j');
    press(&app, .char, 'j');
    app.draw(&screen, now);

    // Back to list.
    press(&app, .escape, 0);
    if (app.view != .list) {
        try errPrint(io, "selftest: esc did not return to list\n", .{});
        return 1;
    }
    app.draw(&screen, now);
    try dumpFrame(io, gpa, &screen, "frame 3: list (after esc)");

    // Raw view toggle.
    press(&app, .char, 'r');
    if (!app.show_raw) {
        try errPrint(io, "selftest: r did not toggle raw view\n", .{});
        return 1;
    }
    app.draw(&screen, now);
    try dumpFrame(io, gpa, &screen, "frame 3b: list (raw view)");
    press(&app, .char, 'r');

    // Filter: open '/', type "apple", apply, verify fewer devices remain.
    const unfiltered = app.ordered.items.len;
    press(&app, .char, '/');
    for ("apple") |ch| press(&app, .char, ch);
    press(&app, .enter, 0);
    if (app.filter_edit) {
        try errPrint(io, "selftest: enter did not apply the filter\n", .{});
        return 1;
    }
    app.refreshOrder();
    app.draw(&screen, now);
    try dumpFrame(io, gpa, &screen, "frame 3c: list (filter: apple)");
    if (app.ordered.items.len == 0 or app.ordered.items.len >= unfiltered) {
        try errPrint(io, "selftest: filter did not narrow the list ({d} -> {d})\n", .{ unfiltered, app.ordered.items.len });
        return 1;
    }
    // Esc clears the filter.
    press(&app, .escape, 0);
    app.refreshOrder();
    if (app.ordered.items.len != unfiltered) {
        try errPrint(io, "selftest: esc did not clear the filter\n", .{});
        return 1;
    }
    app.draw(&screen, now);

    // Radar view toggle.
    press(&app, .char, 'm');
    if (app.view != .radar) {
        try errPrint(io, "selftest: m did not open the radar view\n", .{});
        return 1;
    }
    app.draw(&screen, now);
    try dumpFrame(io, gpa, &screen, "frame 3d: radar view");
    {
        var saw_center = false;
        var saw_rings = false;
        var y: u32 = 0;
        while (y < screen.h) : (y += 1) {
            var x: u32 = 0;
            while (x < screen.w) : (x += 1) {
                const ch = screen.back[@as(usize, y) * screen.w + x].ch;
                if (ch == '⌖' or ch == '@') saw_center = true;
                if (ch == '·' or ch == '.') saw_rings = true;
            }
        }
        if (!saw_center or !saw_rings) {
            try errPrint(io, "selftest: radar center/rings not rendered\n", .{});
            return 1;
        }
    }
    const radar_before = app.radarSelIndex();
    press(&app, .char, 'j');
    const radar_expect = @min(radar_before + 1, app.radar_order.items.len - 1);
    if (app.radarSelIndex() != radar_expect) {
        try errPrint(io, "selftest: j did not move the radar selection ({d} != {d})\n", .{ app.radarSelIndex(), radar_expect });
        return 1;
    }
    app.draw(&screen, now);

    // Walk to the far end: the panel scrolls, selection reaches the last.
    press(&app, .end, 0);
    const n_dev = app.radar_order.items.len;
    if (app.radarSelIndex() != n_dev - 1) {
        try errPrint(io, "selftest: end did not jump to the farthest device ({d}/{d})\n", .{ app.radarSelIndex(), n_dev });
        return 1;
    }
    app.draw(&screen, now);
    try dumpFrame(io, gpa, &screen, "frame 3d2: radar (panel scrolled to end)");
    press(&app, .home, 0);
    if (app.radarSelIndex() != 0) {
        try errPrint(io, "selftest: home did not return to the nearest\n", .{});
        return 1;
    }

    // Enter opens details; Esc returns to the radar, not the list.
    press(&app, .enter, 0);
    if (app.view != .detail) {
        try errPrint(io, "selftest: enter did not open details from radar\n", .{});
        return 1;
    }
    app.draw(&screen, now);
    try dumpFrame(io, gpa, &screen, "frame 3e: detail opened from radar");
    press(&app, .escape, 0);
    if (app.view != .radar) {
        try errPrint(io, "selftest: esc from detail did not return to radar\n", .{});
        return 1;
    }
    app.draw(&screen, now);

    press(&app, .escape, 0);
    if (app.view != .list) {
        try errPrint(io, "selftest: esc did not leave the radar view\n", .{});
        return 1;
    }
    app.draw(&screen, now);

    // Map mode: cycle in (m: list->rings, m: rings->map), SLAM steps render.
    press(&app, .char, 'm');
    if (app.view != .radar or app.map_mode) {
        try errPrint(io, "selftest: m cycle did not reach rings\n", .{});
        return 1;
    }
    press(&app, .char, 'm');
    if (app.view != .radar or !app.map_mode) {
        try errPrint(io, "selftest: m cycle did not reach map mode\n", .{});
        return 1;
    }
    app.draw(&screen, now);
    try dumpFrame(io, gpa, &screen, "frame 3f: map mode (first step)");
    {
        var saw_marker = false;
        var y2: u32 = 0;
        while (y2 < screen.h) : (y2 += 1) {
            var x2: u32 = 0;
            while (x2 < screen.w) : (x2 += 1) {
                const ch = screen.back[@as(usize, y2) * screen.w + x2].ch;
                if (ch == '⌖' or ch == '@' or ch == '◎' or ch == 'O') saw_marker = true;
            }
        }
        if (!saw_marker) {
            try errPrint(io, "selftest: map view missing observer marker\n", .{});
            return 1;
        }
    }
    // Second step after the throttle window elapses.
    app.slam_last_step_ms = now - 5000;
    app.draw(&screen, now + 5000);
    try dumpFrame(io, gpa, &screen, "frame 3g: map mode (second step)");
    if (app.slam.observerStepCount() < 2) {
        try errPrint(io, "selftest: SLAM did not take a second step\n", .{});
        return 1;
    }
    // 's' toggles rings <-> map; then 'm' cycles map -> list.
    press(&app, .char, 's');
    if (app.map_mode) {
        try errPrint(io, "selftest: s did not toggle back to rings\n", .{});
        return 1;
    }
    press(&app, .char, 's');
    if (!app.map_mode) {
        try errPrint(io, "selftest: s did not re-enter map\n", .{});
        return 1;
    }
    press(&app, .char, 'm');
    if (app.view != .list or app.map_mode) {
        try errPrint(io, "selftest: m cycle did not close the loop to list\n", .{});
        return 1;
    }
    app.draw(&screen, now);

    // Help overlay.
    press(&app, .char, '?');
    app.draw(&screen, now);
    try dumpFrame(io, gpa, &screen, "frame 4: help overlay");
    press(&app, .char, ' '); // close

    // Quit.
    press(&app, .char, 'q');
    if (!app.quit) {
        try errPrint(io, "selftest: q did not set quit\n", .{});
        return 1;
    }
    try outPrint(io, "selftest OK ({d} devices)\n", .{store.count()});
    return 0;
}

fn dumpFrame(io: std.Io, gpa: std.mem.Allocator, screen: *screen_mod.Screen, title: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.print("\n=== {s} ===\n", .{title});
    try screen.dumpText(&aw.writer);
    try aw.writer.flush();
    try std.Io.File.stdout().writeStreamingAll(io, aw.written());
}

fn outPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&buf);
    try fw.print(fmt, args);
    try std.Io.File.stdout().writeStreamingAll(io, fw.buffered());
}

fn errPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&buf);
    try fw.print(fmt, args);
    try std.Io.File.stderr().writeStreamingAll(io, fw.buffered());
}

test {
    _ = @import("ble/model.zig");
    _ = @import("ble/replay.zig");
    _ = @import("ble/scanner.zig");
    _ = @import("ble/win_ps.zig");
    _ = @import("ble/linux_hci.zig");
    _ = @import("bus.zig");
    _ = @import("store.zig");
    _ = @import("app.zig");
    _ = @import("log.zig");
    _ = @import("filter.zig");
    _ = @import("slam.zig");
    _ = @import("slam_stress_test.zig");
    _ = @import("tui/terminal.zig");
    _ = @import("tui/screen.zig");
    _ = @import("tui/widgets.zig");
    _ = @import("tui/input.zig");
    _ = @import("decode/ad.zig");
    _ = @import("decode/classify.zig");
    _ = @import("decode/vendors.zig");
    _ = @import("db/companies.zig");
    _ = @import("db/services.zig");
    _ = @import("db/appearance.zig");
    _ = @import("db/devices.zig");
}
