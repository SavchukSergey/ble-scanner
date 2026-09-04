//! Terminal setup/teardown and raw output for both platforms.
//!
//! Linux:  termios raw mode + ioctl TIOCGWINSZ for size.
//! Windows: console modes via the CONDRV user-IO protocol (std.os.windows
//!         .CONSOLE.USER_IO), UTF-8 output codepage, VT input+output enabled
//!         so the exact same ANSI parser handles keys on both platforms.

const std = @import("std");
const builtin = @import("builtin");

pub const Size = struct { w: u16, h: u16 };

pub const Terminal = struct {
    io: std.Io,
    out: std.Io.File,
    in: std.Io.File,

    saved: Saved,

    const Saved = switch (builtin.os.tag) {
        .windows => struct {
            in_mode: u32 = 0,
            out_mode: u32 = 0,
            out_cp: u32 = 0,
        },
        else => struct {
            termios: std.posix.termios = undefined,
        },
    };

    pub const InitError = error{
        NotATerminal,
        ConsoleModeFailed,
        RawModeFailed,
        WriteFailed,
    };

    pub fn init(io: std.Io) InitError!Terminal {
        const out = std.Io.File.stdout();
        const in = std.Io.File.stdin();

        // Both streams must be terminals (interactive use only; --selftest
        // and dump modes bypass Terminal entirely).
        const out_tty = out.isTty(io) catch return error.NotATerminal;
        const in_tty = in.isTty(io) catch return error.NotATerminal;
        if (!out_tty or !in_tty) return error.NotATerminal;

        var self = Terminal{ .io = io, .out = out, .in = in, .saved = .{} };

        switch (builtin.os.tag) {
            .windows => try self.setupWindows(),
            else => try self.setupPosix(),
        }

        // Alternate screen, hide cursor, reset styles, clear.
        self.writeAll("\x1b[?1049h\x1b[?25l\x1b[0m\x1b[2J\x1b[H") catch
            return error.WriteFailed;
        return self;
    }

    pub fn deinit(self: *Terminal) void {
        // Show cursor, reset SGR, leave alternate screen.
        self.writeAll("\x1b[?25h\x1b[0m\x1b[?1049l") catch {};
        switch (builtin.os.tag) {
            .windows => self.restoreWindows() catch {},
            else => self.restorePosix() catch {},
        }
    }

    pub fn writeAll(self: *Terminal, bytes: []const u8) !void {
        try self.out.writeStreamingAll(self.io, bytes);
    }

    /// Current terminal size; falls back to 80x24 when the query fails.
    pub fn size(self: *Terminal) Size {
        switch (builtin.os.tag) {
            .windows => {
                var op = std.os.windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;
                const st = op.operate(self.io, self.out) catch return .{ .w = 80, .h = 24 };
                if (st != .SUCCESS) return .{ .w = 80, .h = 24 };
                return .{
                    .w = @intCast(@max(1, op.Data.dwWindowSize.X)),
                    .h = @intCast(@max(1, op.Data.dwWindowSize.Y)),
                };
            },
            else => {
                var ws: extern struct { row: u16, col: u16, x: u16, y: u16 } = undefined;
                const TIOCGWINSZ: u32 = 0x5413;
                const rc = std.os.linux.ioctl(self.out.handle, TIOCGWINSZ, @intFromPtr(&ws));
                if (rc != 0 or ws.col == 0 or ws.row == 0) return .{ .w = 80, .h = 24 };
                return .{ .w = ws.col, .h = ws.row };
            },
        }
    }

    // --- Windows -----------------------------------------------------------

    const enable_processed_input: u32 = 0x0001;
    const enable_line_input: u32 = 0x0002;
    const enable_echo_input: u32 = 0x0004;
    const enable_window_input: u32 = 0x0008;
    const enable_mouse_input: u32 = 0x0010;
    const enable_insert_mode: u32 = 0x0020;
    const enable_quick_edit: u32 = 0x0040;
    const enable_extended_flags: u32 = 0x0080;
    const enable_auto_position: u32 = 0x0100;
    const enable_vt_input: u32 = 0x0200;

    const enable_processed_output: u32 = 0x0001;
    const enable_wrap_at_eol: u32 = 0x0002;
    const enable_vt_processing: u32 = 0x0004;
    const disable_newline_auto_return: u32 = 0x0008;
    const enable_lvb_grid_worldwide: u32 = 0x0010;

    fn getMode(self: *Terminal, file: std.Io.File) InitError!u32 {
        var op = std.os.windows.CONSOLE.USER_IO.GET_MODE;
        const st = op.operate(self.io, file) catch return error.ConsoleModeFailed;
        if (st != .SUCCESS) return error.ConsoleModeFailed;
        return op.Data;
    }

    fn setMode(self: *Terminal, file: std.Io.File, mode: u32) InitError!void {
        var op = std.os.windows.CONSOLE.USER_IO.SET_MODE(mode);
        const st = op.operate(self.io, file) catch return error.ConsoleModeFailed;
        if (st != .SUCCESS) return error.ConsoleModeFailed;
    }

    fn setupWindows(self: *Terminal) !void {
        // Input: raw-ish — no line/echo/processed/mouse/window input; VT input
        // so arrow keys arrive as the same ESC sequences Linux sends.
        const in_mode = try self.getMode(self.in);
        self.saved.in_mode = in_mode;
        var new_in: u32 = in_mode;
        new_in &= ~(enable_processed_input | enable_line_input | enable_echo_input |
            enable_window_input | enable_mouse_input | enable_insert_mode |
            enable_quick_edit | enable_auto_position);
        new_in |= enable_extended_flags | enable_vt_input;
        try self.setMode(self.in, new_in);

        // Output: enable VT processing so our ANSI renderer works.
        const out_mode = try self.getMode(self.out);
        self.saved.out_mode = out_mode;
        var new_out: u32 = out_mode;
        new_out |= enable_processed_output | enable_vt_processing |
            disable_newline_auto_return;
        try self.setMode(self.out, new_out);

        // UTF-8 output.
        var get_cp = std.os.windows.CONSOLE.USER_IO.GET_CP(.Output);
        const gst = get_cp.operate(self.io, self.out) catch return error.ConsoleModeFailed;
        if (gst == .SUCCESS) self.saved.out_cp = get_cp.Data.CodePage;
        var set_cp = std.os.windows.CONSOLE.USER_IO.SET_CP(.Output, 65001);
        _ = set_cp.operate(self.io, self.out) catch return error.ConsoleModeFailed;
    }

    fn restoreWindows(self: *Terminal) !void {
        self.setMode(self.in, self.saved.in_mode) catch {};
        self.setMode(self.out, self.saved.out_mode) catch {};
        if (self.saved.out_cp != 0) {
            var set_cp = std.os.windows.CONSOLE.USER_IO.SET_CP(.Output, self.saved.out_cp);
            const st = set_cp.operate(self.io, self.out) catch return;
            if (st != .SUCCESS) return;
        }
    }

    // --- Linux / POSIX -----------------------------------------------------

    fn setupPosix(self: *Terminal) !void {
        const orig = std.posix.tcgetattr(self.in.handle) catch return error.RawModeFailed;
        self.saved.termios = orig;
        var t = orig;

        t.iflag.IGNBRK = false;
        t.iflag.BRKINT = false;
        t.iflag.PARMRK = false;
        t.iflag.ISTRIP = false;
        t.iflag.INLCR = false;
        t.iflag.IGNCR = false;
        t.iflag.ICRNL = false;
        t.iflag.IXON = false;

        t.oflag.OPOST = false;

        t.lflag.ECHO = false;
        t.lflag.ECHONL = false;
        t.lflag.ICANON = false;
        t.lflag.ISIG = false;
        t.lflag.IEXTEN = false;

        t.cflag.PARENB = false;
        t.cflag.CSIZE = .CS8;

        t.cc[@intFromEnum(std.os.linux.V.MIN)] = 1;
        t.cc[@intFromEnum(std.os.linux.V.TIME)] = 0;

        std.posix.tcsetattr(self.in.handle, .FLUSH, t) catch return error.RawModeFailed;
    }

    fn restorePosix(self: *Terminal) !void {
        std.posix.tcsetattr(self.in.handle, .FLUSH, self.saved.termios) catch
            return error.RawModeFailed;
    }
};
