//! Device filter: a small query language for the device list.
//!
//! Syntax (terms separated by spaces, AND-combined, case-insensitive):
//!   apple            — substring match against address, name, company, type
//!   mac:AA:BB        — substring of the address
//!   name:airpods     — substring of the advertised name
//!   company:google   — substring of the SIG company name
//!   type:tracker     — substring of the device type label/detail
//!   rssi:-70         — last RSSI >= -70 (closer than)
//!   rssi:>=-70       — explicit comparisons also accepted (>=, >, <=, <)
//!
//! An empty filter matches everything.

const std = @import("std");
const model = @import("ble/model.zig");

pub const Field = enum { any, mac, name, company, kind };

const max_terms = 8;
const raw_cap = 96;

pub const Filter = struct {
    raw: [raw_cap]u8 = @splat(0),
    raw_len: u8 = 0,
    terms: [max_terms]Term = @splat(.{}),
    n_terms: u8 = 0,
    rssi_min: ?i8 = null,
    rssi_max: ?i8 = null,

    const Term = struct {
        field: Field = .any,
        off: u8 = 0,
        len: u8 = 0,
    };

    pub fn rawText(self: *const Filter) []const u8 {
        return self.raw[0..self.raw_len];
    }

    pub fn active(self: *const Filter) bool {
        return self.raw_len > 0;
    }
};

fn termText(f: *const Filter, t: Filter.Term) []const u8 {
    return f.raw[t.off..][0..t.len];
}

/// Parse filter input. Unparseable rssi values and overflowed extra terms
/// are ignored (the filter stays usable).
pub fn parse(input: []const u8) Filter {
    var f: Filter = .{};
    const n = @min(input.len, raw_cap);
    @memcpy(f.raw[0..n], input[0..n]);
    f.raw_len = @intCast(n);

    var it = std.mem.tokenizeScalar(u8, f.raw[0..n], ' ');
    while (it.next()) |tok| {
        if (f.n_terms >= max_terms) break;

        if (std.mem.startsWith(u8, tok, "rssi:")) {
            const v = tok[5..];
            if (std.mem.startsWith(u8, v, ">=")) {
                f.rssi_min = std.fmt.parseInt(i8, v[2..], 10) catch f.rssi_min;
            } else if (std.mem.startsWith(u8, v, "<=")) {
                f.rssi_max = std.fmt.parseInt(i8, v[2..], 10) catch f.rssi_max;
            } else if (std.mem.startsWith(u8, v, ">")) {
                const x = std.fmt.parseInt(i8, v[1..], 10) catch continue;
                f.rssi_min = x +| 1;
            } else if (std.mem.startsWith(u8, v, "<")) {
                const x = std.fmt.parseInt(i8, v[1..], 10) catch continue;
                f.rssi_max = x -| 1;
            } else {
                f.rssi_min = std.fmt.parseInt(i8, v, 10) catch f.rssi_min;
            }
            continue;
        }

        var field: Field = .any;
        var body = tok;
        inline for (.{
            .{ "mac:", Field.mac },
            .{ "addr:", Field.mac },
            .{ "name:", Field.name },
            .{ "company:", Field.company },
            .{ "co:", Field.company },
            .{ "type:", Field.kind },
            .{ "kind:", Field.kind },
        }) |p| {
            if (std.mem.startsWith(u8, tok, p[0])) {
                field = p[1];
                body = tok[p[0].len..];
            }
        }
        if (body.len == 0) continue;

        f.terms[f.n_terms] = .{
            .field = field,
            .off = @intCast(@intFromPtr(body.ptr) - @intFromPtr(&f.raw)),
            .len = @intCast(body.len),
        };
        f.n_terms += 1;
    }
    return f;
}

/// Case-insensitive substring (ASCII case only; hex/MAC text is ASCII).
fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) continue :outer;
        }
        return true;
    }
    return false;
}

pub const Device = struct {
    mac: []const u8,
    name: []const u8,
    company: []const u8, // "" when unknown
    kind: []const u8, // type label (+ detail)
    rssi: i8,
};

pub fn matches(f: *const Filter, d: Device) bool {
    if (!f.active()) return true;
    if (f.rssi_min) |m| {
        if (d.rssi < m) return false;
    }
    if (f.rssi_max) |m| {
        if (d.rssi > m) return false;
    }
    var i: usize = 0;
    while (i < f.n_terms) : (i += 1) {
        const t = f.terms[i];
        const txt = termText(f, t);
        const ok = switch (t.field) {
            .mac => containsCI(d.mac, txt),
            .name => containsCI(d.name, txt),
            .company => containsCI(d.company, txt),
            .kind => containsCI(d.kind, txt),
            .any => containsCI(d.mac, txt) or containsCI(d.name, txt) or
                containsCI(d.company, txt) or containsCI(d.kind, txt),
        };
        if (!ok) return false;
    }
    return true;
}

// --- tests ----------------------------------------------------------------------

const testing = std.testing;

test "parse fields and rssi" {
    var f = parse("name:AirPods rssi:-70");
    try testing.expect(f.active());
    try testing.expectEqual(@as(?i8, -70), f.rssi_min);
    try testing.expectEqual(@as(u8, 1), f.n_terms);
    try testing.expectEqual(Field.name, f.terms[0].field);
    try testing.expectEqualStrings("AirPods", termText(&f, f.terms[0]));

    f = parse("rssi:<=-90");
    try testing.expectEqual(@as(?i8, -90), f.rssi_max);
    try testing.expect(f.rssi_min == null);

    f = parse("company:google type:tracker");
    try testing.expectEqual(@as(u8, 2), f.n_terms);
    try testing.expectEqual(Field.company, f.terms[0].field);
    try testing.expectEqual(Field.kind, f.terms[1].field);

    f = parse("");
    try testing.expect(!f.active());
}

test "match logic" {
    const dev = Device{
        .mac = "AA:BB:CC:DD:EE:FF",
        .name = "Mi Smart Band 4",
        .company = "Anhui Huami Information Technology",
        .kind = "Mi Band",
        .rssi = -55,
    };
    var f = parse("mi");
    try testing.expect(matches(&f, dev)); // any-field: name hits
    f = parse("name:galaxy");
    try testing.expect(!matches(&f, dev));
    f = parse("company:huami mi");
    try testing.expect(matches(&f, dev));
    f = parse("mac:aa:bb");
    try testing.expect(matches(&f, dev));
    f = parse("mac:11:22");
    try testing.expect(!matches(&f, dev));
    f = parse("type:band");
    try testing.expect(matches(&f, dev));
    f = parse("rssi:-60");
    try testing.expect(matches(&f, dev));
    f = parse("rssi:-50");
    try testing.expect(!matches(&f, dev)); // -55 < -50
    f = parse("rssi:<=-90");
    try testing.expect(!matches(&f, dev));
    f = parse("name:mi rssi:-70 type:band");
    try testing.expect(matches(&f, dev));
    f = parse("name:mi rssi:-70 type:watch");
    try testing.expect(!matches(&f, dev));
}
