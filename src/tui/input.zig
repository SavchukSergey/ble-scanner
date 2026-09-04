//! Keyboard input: a byte-level ESC-sequence decoder shared by both
//! platforms (Windows uses ENABLE_VIRTUAL_TERMINAL_INPUT so the console
//! delivers the same byte streams as a Linux terminal), plus the input
//! thread that reads stdin and pushes key events onto the bus.

const std = @import("std");
const bus = @import("../bus.zig");

pub const Code = enum {
    char,
    up,
    down,
    left,
    right,
    page_up,
    page_down,
    home,
    end,
    enter,
    escape,
    backspace,
    delete,
    tab,
    ctrl_c,
};

pub const Key = struct {
    code: Code,
    /// Lowercased ASCII char when code == .char.
    ch: u8 = 0,
};

/// Incremental decoder: feed every byte read from stdin, collect a Key when
/// a complete key press has been assembled.
pub const Decoder = struct {
    const State = enum(u8) { ground, esc, csi, ss3 };

    state: State = .ground,
    param: u8 = 0,
    /// Byte to reprocess at the start of the next feed call (used when a
    /// lone ESC must be emitted and the following byte starts a new key).
    hold: ?u8 = null,

    pub fn feed(self: *Decoder, c: u8) ?Key {
        if (self.hold) |h| {
            // A held byte (rejected mid-ESC) is processed first; if it yields
            // a key, the current byte is parked for the next call so nothing
            // is lost.
            self.hold = null;
            if (self.step(h)) |k| {
                self.hold = c;
                return k;
            }
            // Held byte consumed without producing a key; fall through.
        }
        return self.step(c);
    }

    /// End-of-chunk flush: emits a pending bare ESC or a held byte so a
    /// key press is never stuck waiting for the next read.
    pub fn flushTail(self: *Decoder) ?Key {
        if (self.hold) |h| {
            self.hold = null;
            return self.step(h);
        }
        if (self.state == .esc) {
            self.state = .ground;
            return key(.escape);
        }
        return null;
    }

    fn step(self: *Decoder, b: u8) ?Key {
        switch (self.state) {
            .ground => {
                return switch (b) {
                    0x1B => blk: {
                        self.state = .esc;
                        break :blk null;
                    },
                    0x03 => key(.ctrl_c),
                    0x0D, 0x0A => key(.enter),
                    0x09 => key(.tab),
                    0x7F, 0x08 => key(.backspace),
                    0x20...0x7E => Key{
                        .code = .char,
                        .ch = if (b >= 'A' and b <= 'Z') b + 0x20 else b,
                    },
                    else => null, // UTF-8 and other controls: ignored
                };
            },
            .esc => {
                switch (b) {
                    '[' => {
                        self.state = .csi;
                        self.param = 0;
                        return null;
                    },
                    'O' => {
                        self.state = .ss3;
                        return null;
                    },
                    else => {
                        // Lone ESC followed by another key: emit escape and
                        // reprocess the byte.
                        self.state = .ground;
                        self.hold = b;
                        return key(.escape);
                    },
                }
            },
            .csi => {
                if (b >= '0' and b <= '9') {
                    self.param = self.param *| 10 +| (b - '0');
                    return null;
                }
                self.state = .ground;
                return switch (b) {
                    'A' => key(.up),
                    'B' => key(.down),
                    'C' => key(.right),
                    'D' => key(.left),
                    'H' => key(.home),
                    'F' => key(.end),
                    '~' => switch (self.param) {
                        1, 7 => key(.home),
                        2 => null, // insert
                        3 => key(.delete),
                        4, 8 => key(.end),
                        5 => key(.page_up),
                        6 => key(.page_down),
                        else => null,
                    },
                    else => null, // mouse reports, modifiers, ...
                };
            },
            .ss3 => {
                self.state = .ground;
                return switch (b) {
                    'A' => key(.up),
                    'B' => key(.down),
                    'C' => key(.right),
                    'D' => key(.left),
                    'H' => key(.home),
                    'F' => key(.end),
                    else => null,
                };
            },
        }
    }
};
fn key(c: Code) ?Key {
    return .{ .code = c };
}

/// Input thread main loop. Reads stdin (raw mode is set up by Terminal),
/// decodes keys, pushes them onto the bus. Detached at exit; blocking read
/// is abandoned when the process exits.
pub fn threadMain(io: std.Io, b: *bus.Bus) void {
    var dec: Decoder = .{};
    var buf: [64]u8 = undefined;
    const stdin = std.Io.File.stdin();
    while (true) {
        const n = stdin.readStreaming(io, &.{buf[0..]}) catch break;
        if (n == 0) break;
        for (buf[0..n]) |c| {
            if (dec.feed(c)) |k| b.push(.{ .key = k });
        }
        if (dec.flushTail()) |k| b.push(.{ .key = k });
    }
    b.push(.{ .key = .{ .code = .ctrl_c } }); // stdin closed → quit
}

// tests -----------------------------------------------------------------------

const testing = std.testing;

fn expectKeys(dec: *Decoder, bytes: []const u8, expected: []const Key) !void {
    var got: [8]Key = undefined;
    var n: usize = 0;
    for (bytes) |c| {
        if (dec.feed(c)) |k| {
            got[n] = k;
            n += 1;
        }
    }
    try testing.expectEqual(expected.len, n);
    for (expected, 0..) |e, i| {
        try testing.expectEqual(e.code, got[i].code);
        try testing.expectEqual(e.ch, got[i].ch);
    }
}

test "decode plain keys" {
    var d: Decoder = .{};
    try expectKeys(&d, "jq", &.{ .{ .code = .char, .ch = 'j' }, .{ .code = .char, .ch = 'q' } });
    try expectKeys(&d, "\r", &.{.{ .code = .enter }});
    try expectKeys(&d, "\x03", &.{.{ .code = .ctrl_c }});
}

test "decode escape sequences" {
    var d: Decoder = .{};
    try expectKeys(&d, "\x1b[A", &.{.{ .code = .up }});
    try expectKeys(&d, "\x1b[B", &.{.{ .code = .down }});
    try expectKeys(&d, "\x1b[5~", &.{.{ .code = .page_up }});
    try expectKeys(&d, "\x1b[6~", &.{.{ .code = .page_down }});
    try expectKeys(&d, "\x1bOH", &.{.{ .code = .home }});
}

test "lone escape emits escape then next key" {
    var d: Decoder = .{};
    try expectKeys(&d, "\x1bx", &.{.{ .code = .escape }});
    // The held 'x' flushes at the end of the read chunk.
    const tail = d.flushTail().?;
    try testing.expectEqual(Code.char, tail.code);
    try testing.expectEqual(@as(u8, 'x'), tail.ch);

    // Bare ESC with nothing after → escape on flush.
    var d2: Decoder = .{};
    try expectKeys(&d2, "\x1b", &.{});
    try testing.expectEqual(Code.escape, d2.flushTail().?.code);
}
