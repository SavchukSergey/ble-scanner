//! Cell-grid screen: double-buffered rendering with ANSI diff output.

const std = @import("std");

pub const Style = struct {
    /// 256-color palette index. 0 means "default" (SGR 39/49).
    fg: u8 = 0,
    bg: u8 = 0,
    bold: bool = false,
};

pub const Cell = struct {
    ch: u21 = ' ',
    st: Style = .{},
};

/// Global ASCII fallback mode (--ascii): replaces box-drawing and block
/// glyphs for terminals with hostile fonts. Set once at startup.
pub var ascii: bool = false;

pub const Screen = struct {
    gpa: std.mem.Allocator,
    w: u32,
    h: u32,
    back: []Cell,
    front: []Cell,

    pub fn init(gpa: std.mem.Allocator, w: u32, h: u32) !Screen {
        const cells = try gpa.alloc(Cell, @as(usize, w) * h);
        @memset(cells, .{});
        const cells2 = try gpa.alloc(Cell, @as(usize, w) * h);
        @memset(cells2, .{});
        return .{ .gpa = gpa, .w = w, .h = h, .back = cells, .front = cells2 };
    }

    pub fn deinit(self: *Screen) void {
        self.gpa.free(self.back);
        self.gpa.free(self.front);
    }

    /// Resize buffers; invalidates the front buffer so the next render is
    /// a full repaint.
    pub fn resize(self: *Screen, w: u32, h: u32) !void {
        if (w == self.w and h == self.h) return;
        const cells = try self.gpa.alloc(Cell, @as(usize, w) * h);
        @memset(cells, .{});
        self.gpa.free(self.back);
        self.back = cells;
        self.gpa.free(self.front);
        self.front = try self.gpa.alloc(Cell, @as(usize, w) * h);
        @memset(self.front, .{});
        self.w = w;
        self.h = h;
    }

    pub fn clear(self: *Screen) void {
        @memset(self.back, .{});
    }

    inline fn cell(self: *Screen, x: u32, y: u32) ?*Cell {
        if (x >= self.w or y >= self.h) return null;
        return &self.back[@as(usize, y) * self.w + x];
    }

    pub fn put(self: *Screen, x: u32, y: u32, ch: u21, st: Style) void {
        if (self.cell(x, y)) |c| {
            c.* = .{ .ch = ch, .st = st };
        }
    }

    /// Apply a style to a run of cells without changing their characters
    /// (used for selection bars / titles over existing text).
    pub fn styleRange(self: *Screen, x: u32, y: u32, w: u32, st: Style) void {
        var i: u32 = 0;
        while (i < w) : (i += 1) {
            if (self.cell(x + i, y)) |c| c.st = st;
        }
    }

    pub fn fillRect(self: *Screen, x: u32, y: u32, w: u32, h: u32, st: Style) void {
        var j: u32 = 0;
        while (j < h) : (j += 1) {
            var i: u32 = 0;
            while (i < w) : (i += 1) self.put(x + i, y + j, ' ', st);
        }
    }

    /// Write UTF-8 text starting at (x, y) in one row; stops at the screen
    /// edge. Returns the x position after the last written cell.
    pub fn text(self: *Screen, x: u32, y: u32, s: []const u8, st: Style) u32 {
        var cx = x;
        var i: usize = 0;
        while (i < s.len and cx < self.w) {
            const b = s[i];
            if (b < 0x80) {
                i += 1;
                const ch: u21 = if (b < 0x20 or b == 0x7F) '?' else b;
                self.put(cx, y, ch, st);
                cx += 1;
            } else {
                const len = std.unicode.utf8ByteSequenceLength(b) catch {
                    i += 1;
                    self.put(cx, y, '?', st);
                    cx += 1;
                    continue;
                };
                if (i + len > s.len) break;
                const cp = std.unicode.utf8Decode(s[i..][0..len]) catch {
                    i += len;
                    self.put(cx, y, '?', st);
                    cx += 1;
                    continue;
                };
                i += len;
                self.put(cx, y, cp, st);
                cx += 1;
            }
        }
        return cx;
    }

    /// Truncated text that never passes column limit (x..x+max_w).
    pub fn textBounded(self: *Screen, x: u32, y: u32, s: []const u8, max_w: u32, st: Style) void {
        var sub = s;
        if (max_w == 0) return;
        if (utf8Len(sub) > max_w) {
            // Byte-truncate to max_w codepoints, append ellipsis inside budget.
            var count: u32 = 0;
            var idx: usize = 0;
            const ellipsis_w: u32 = if (ascii) 3 else 1;
            const budget = if (max_w > ellipsis_w) max_w - ellipsis_w else 0;
            while (count < budget) {
                const l = std.unicode.utf8ByteSequenceLength(sub[idx]) catch 1;
                idx += l;
                count += 1;
                if (idx >= sub.len) break;
            }
            sub = sub[0..@min(idx, sub.len)];
            _ = self.text(x, y, sub, st);
            _ = self.text(x + count, y, if (ascii) "..." else "…", st);
        } else {
            _ = self.text(x, y, sub, st);
        }
    }

    pub fn box(self: *Screen, x: u32, y: u32, w: u32, h: u32, st: Style) void {
        if (w == 0 or h == 0) return;
        const right = x + w - 1;
        const bottom = y + h - 1;
        if (ascii) {
            var i: u32 = 0;
            while (i < w) : (i += 1) {
                self.put(x + i, y, '-', st);
                self.put(x + i, bottom, '-', st);
            }
            var j: u32 = 0;
            while (j < h) : (j += 1) {
                self.put(x, y + j, '|', st);
                self.put(right, y + j, '|', st);
            }
            self.put(x, y, '+', st);
            self.put(right, y, '+', st);
            self.put(x, bottom, '+', st);
            self.put(right, bottom, '+', st);
            return;
        }
        var i: u32 = 0;
        while (i < w) : (i += 1) {
            self.put(x + i, y, '─', st);
            self.put(x + i, bottom, '─', st);
        }
        var j: u32 = 0;
        while (j < h) : (j += 1) {
            self.put(x, y + j, '│', st);
            self.put(right, y + j, '│', st);
        }
        self.put(x, y, '┌', st);
        self.put(right, y, '┐', st);
        self.put(x, bottom, '└', st);
        self.put(right, bottom, '┘', st);
    }

    /// Render the diff between front and back into `w` as ANSI escape
    /// sequences, then make front = back.
    pub fn render(self: *Screen, w: *std.Io.Writer) !void {
        var cursor_set = false;
        var cur_style: ?Style = null;
        var utf8: [4]u8 = undefined;

        var y: u32 = 0;
        while (y < self.h) : (y += 1) {
            var x: u32 = 0;
            while (x < self.w) {
                const i = @as(usize, y) * self.w + x;
                if (std.meta.eql(self.back[i], self.front[i])) {
                    x += 1;
                    continue;
                }
                // Start of a dirty run: position the cursor.
                if (!cursor_set) {
                    try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
                    cursor_set = true;
                }
                // Flush the dirty run until the next clean cell.
                while (x < self.w) {
                    const j = @as(usize, y) * self.w + x;
                    if (std.meta.eql(self.back[j], self.front[j])) break;
                    const c = self.back[j];
                    if (cur_style == null or !std.meta.eql(cur_style.?, c.st)) {
                        try emitSgr(w, c.st);
                        cur_style = c.st;
                    }
                    const n = std.unicode.utf8Encode(c.ch, &utf8) catch blk: {
                        utf8[0] = '?';
                        break :blk 1;
                    };
                    try w.writeAll(utf8[0..n]);
                    x += 1;
                    cursor_set = true;
                }
                cursor_set = false; // need explicit move for next run
            }
        }
        if (cur_style != null) try w.writeAll("\x1b[0m");
        @memcpy(self.front, self.back);
    }

    /// Plain-text dump of the back buffer (selftest).
    pub fn dumpText(self: *const Screen, w: *std.Io.Writer) !void {
        var utf8: [4]u8 = undefined;
        var y: u32 = 0;
        while (y < self.h) : (y += 1) {
            var x: u32 = 0;
            var last_non_space: u32 = 0;
            while (x < self.w) : (x += 1) {
                const c = self.back[@as(usize, y) * self.w + x];
                if (c.ch != ' ' and c.ch != 0) last_non_space = x + 1;
            }
            x = 0;
            while (x < last_non_space) : (x += 1) {
                const c = self.back[@as(usize, y) * self.w + x];
                const ch: u21 = if (c.ch == 0) ' ' else c.ch;
                const n = std.unicode.utf8Encode(ch, &utf8) catch blk: {
                    utf8[0] = '?';
                    break :blk 1;
                };
                try w.writeAll(utf8[0..n]);
            }
            try w.writeByte('\n');
        }
    }
};

fn emitSgr(w: *std.Io.Writer, st: Style) !void {
    // "\x1b[0[;1][;38;5;F][;48;5;B]m"
    try w.writeAll("\x1b[0");
    if (st.bold) try w.writeAll(";1");
    if (st.fg != 0) try w.print(";38;5;{d}", .{st.fg});
    if (st.bg != 0) try w.print(";48;5;{d}", .{st.bg});
    try w.writeAll("m");
}

fn utf8Len(s: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += l;
        n += 1;
    }
    return n;
}

// tests -----------------------------------------------------------------------

const testing = std.testing;

test "text writes cells, stops at edge" {
    var s = try Screen.init(testing.allocator, 10, 3);
    defer s.deinit();
    _ = s.text(8, 0, "hello", .{ .fg = 3 });
    try testing.expectEqual(@as(u21, 'h'), s.back[8].ch);
    try testing.expectEqual(@as(u21, 'e'), s.back[9].ch);
    try testing.expectEqual(@as(u21, ' '), s.back[0].ch);
    // UTF-8 codepoints occupy one cell each
    _ = s.text(0, 1, "▂▃", .{});
    try testing.expectEqual(@as(u21, '▂'), s.back[10].ch);
    try testing.expectEqual(@as(u21, '▃'), s.back[11].ch);
}

test "render emits diff and syncs front" {
    var s = try Screen.init(testing.allocator, 5, 2);
    defer s.deinit();
    _ = s.text(0, 0, "AB", .{ .fg = 10 });
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try s.render(&aw.writer);
    try aw.writer.flush();
    try testing.expect(aw.written().len > 0);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "AB") != null);
    // Second render with no changes emits nothing.
    aw.clearRetainingCapacity();
    try s.render(&aw.writer);
    try aw.writer.flush();
    try testing.expectEqual(@as(usize, 0), aw.written().len);
}

test "textBounded truncates with ellipsis" {
    var s = try Screen.init(testing.allocator, 20, 1);
    defer s.deinit();
    s.textBounded(0, 0, "abcdefghij", 5, .{});
    try testing.expectEqual(@as(u21, 'a'), s.back[0].ch);
    try testing.expectEqual(@as(u21, 'd'), s.back[3].ch);
    try testing.expectEqual(@as(u21, '…'), s.back[4].ch);
    try testing.expectEqual(@as(u21, ' '), s.back[5].ch);
}
