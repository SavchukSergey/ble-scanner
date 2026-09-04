#!/usr/bin/env python3
"""Generate src/db/{companies,services,appearance}.zig from the official
Bluetooth SIG assigned-numbers YAML (bitbucket.org/bluetooth-SIG/public).

Usage:
    python tools/gen_db.py [path/to/assigned_numbers]

The directory defaults to $SIG_NUMBERS or ./sig/assigned_numbers.
"""
import os, pathlib, re, sys

SIG = pathlib.Path(
    sys.argv[1] if len(sys.argv) > 1
    else os.environ.get("SIG_NUMBERS", "sig/assigned_numbers")
)

def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')

if not SIG.exists():
    sys.exit(
        "assigned-numbers directory not found: " + str(SIG)
        + "\nClone https://bitbucket.org/bluetooth-SIG/public or pass a path / $SIG_NUMBERS."
    )


def parse_entries(path, key):
    txt = path.read_text(encoding="utf-8")
    entries = []
    val = name = None
    sub = None
    for line in txt.splitlines():
        line = line.rstrip()
        m = re.match(r"^\s*-\s+(\w+):\s*(.*)$", line)
        m2 = re.match(r"^\s*(\w+):\s*(.*)$", line)
        if m:
            k, v = m.group(1), m.group(2).strip().strip("'\"")
            if k == key:
                if val is not None:
                    entries.append((val, name or ""))
                val, name = v, None
            elif k == "name":
                name = v
        elif m2 and m2.group(1) == "name" and val is not None and name is None:
            name = m2.group(2).strip().strip("'\"")
    if val is not None:
        entries.append((val, name or ""))
    return entries

# --- companies ---------------------------------------------------------------
comps = []
for v, n in parse_entries(SIG / "company_identifiers/company_identifiers.yaml", "value"):
    m = re.match(r"0[xX]([0-9A-Fa-f]+)", v)
    if not m: continue
    n = re.sub(r"\s+", " ", n).strip()
    if not n: continue
    comps.append((int(m.group(1), 16), n))
comps.sort()
# de-dup (shouldn't happen, but be safe)
dedup = []
for c in comps:
    if not dedup or dedup[-1][0] != c[0]:
        dedup.append(c)
comps = dedup

out = ['//! Bluetooth SIG assigned numbers: company identifiers.',
       '//! GENERATED from the official SIG assigned-numbers YAML (see',
       '//! tools/gen_db.py) — do not edit by hand.',
       '//! Sorted by id; lookup is a binary search (comptime-enforced).',
       '',
       'const std = @import("std");',
       '',
       'pub const Company = struct {',
       '    id: u16,',
       '    name: []const u8,',
       '};',
       '',
       'pub const companies = [_]Company{']
for cid, n in comps:
    out.append(f'    .{{ .id = 0x{cid:04X}, .name = "{esc(n)}" }},')
out.append('};')
out.append('''
/// Binary-search lookup by company id.
pub fn lookup(id: u16) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = companies.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (companies[mid].id == id) return companies[mid].name;
        if (companies[mid].id < id) lo = mid + 1 else hi = mid;
    }
    return null;
}

test "companies sorted, no duplicates, spot checks" {
    for (companies[1..], companies[0 .. companies.len - 1]) |c, prev| {
        try std.testing.expect(prev.id < c.id);
    }
    try std.testing.expectEqualStrings("Apple, Inc.", lookup(0x004C).?);
    try std.testing.expectEqualStrings("Xiaomi Inc.", lookup(0x038F).?);
    try std.testing.expectEqualStrings("Google", lookup(0x00E0).?);
    try std.testing.expectEqualStrings("Ericsson AB", lookup(0x0000).?);
    try std.testing.expect(lookup(0xBEEF) == null);
}
''')
pathlib.Path("src/db/companies.zig").write_text("\n".join(out), encoding="utf-8")
print(f"companies: {len(comps)} entries")

# --- services (base GATT + member/vendor UUIDs) ------------------------------
svcs = []
for v, n in parse_entries(SIG / "uuids/service_uuids.yaml", "uuid"):
    m = re.match(r"0[xX]([0-9A-Fa-f]+)", v)
    if not m: continue
    n = re.sub(r"\s+", " ", n).strip()
    if n: svcs.append((int(m.group(1), 16), n))
for v, n in parse_entries(SIG / "uuids/member_uuids.yaml", "uuid"):
    m = re.match(r"0[xX]([0-9A-Fa-f]+)", v)
    if not m: continue
    n = re.sub(r"\s+", " ", n).strip()
    if n: svcs.append((int(m.group(1), 16), n))
svcs.sort()
dedup = []
for s in svcs:
    if not dedup or dedup[-1][0] != s[0]:
        dedup.append(s)
svcs = dedup

out = ['//! Bluetooth SIG assigned numbers: 16-bit service UUIDs (GATT base',
       '//! services + vendor member UUIDs like 0xFE95 Xiaomi, 0xFEAA Eddystone).',
       '//! GENERATED from the official SIG YAML (see tools/gen_db.py).',
       '//! Sorted by id; binary-search lookup.',
       '',
       'const std = @import("std");',
       '',
       'pub const Svc = struct {',
       '    id: u16,',
       '    name: []const u8,',
       '};',
       '',
       'pub const services = [_]Svc{']
for sid, n in svcs:
    out.append(f'    .{{ .id = 0x{sid:04X}, .name = "{esc(n)}" }},')
out.append('};')
out.append('''
/// Binary-search lookup by service UUID.
pub fn lookup(id: u16) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = services.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (services[mid].id == id) return services[mid].name;
        if (services[mid].id < id) lo = mid + 1 else hi = mid;
    }
    return null;
}

test "services sorted and spot checks" {
    for (services[1..], services[0 .. services.len - 1]) |s, prev| {
        try std.testing.expect(prev.id < s.id);
    }
    try std.testing.expectEqualStrings("Battery", lookup(0x180F).?);
    try std.testing.expectEqualStrings("Heart Rate", lookup(0x180D).?);
    try std.testing.expectEqualStrings("Xiaomi Inc.", lookup(0xFE95).?);
    try std.testing.expectEqualStrings("Google LLC", lookup(0xFEAA).?);
    try std.testing.expect(lookup(0x0000) == null);
}
''')
pathlib.Path("src/db/services.zig").write_text("\n".join(out), encoding="utf-8")
print(f"services: {len(svcs)} entries")

# --- appearance --------------------------------------------------------------
txt = (SIG / "core/appearance_values.yaml").read_text(encoding="utf-8")
cats = []
cur = None
cursub = None
for line in txt.splitlines():
    line = line.rstrip()
    m = re.match(r"^\s*-\s+category:\s*(.+)$", line)
    if m:
        cur = {"cat": int(m.group(1).strip(), 16), "name": None, "subs": []}
        cats.append(cur)
        continue
    m = re.match(r"^\s*subcategory:\s*$", line)
    if m and cur is not None:
        cursub = None
        continue
    m = re.match(r"^\s*-\s+value:\s*(.+)$", line)
    if m and cur is not None and cur.get("subs") is not None:
        cursub = {"v": int(m.group(1).strip(), 16), "name": None}
        cur["subs"].append(cursub)
        continue
    m = re.match(r"^\s*name:\s*(.+)$", line)
    if m:
        n = m.group(1).strip().strip("'\"")
        if cursub is not None and cur["subs"] and cur["subs"][-1]["name"] is None:
            cur["subs"][-1]["name"] = n
        elif cur is not None and cur["name"] is None:
            cur["name"] = n
cats = [c for c in cats if c["name"]]
cats.sort(key=lambda c: c["cat"])

out = ['//! Bluetooth SIG assigned numbers: GAP Appearance values.',
       '//! GENERATED from the official SIG YAML (see tools/gen_db.py).',
       '//! appearance = category << 6 | subcategory.',
       '',
       'const std = @import("std");',
       '',
       'pub const Sub = struct { v: u8, name: []const u8 };',
       'pub const Category = struct {',
       '    id: u8,',
       '    name: []const u8,',
       '    subs: []const Sub = &.{},',
       '};',
       '',
       'pub const categories = [_]Category{']
for c in cats:
    if c["subs"]:
        subname = f"subs_{c['cat']:02X}"
        out.append(f'    .{{ .id = 0x{c["cat"]:02X}, .name = "{esc(c["name"])}", .subs = &{subname} }},')
    else:
        out.append(f'    .{{ .id = 0x{c["cat"]:02X}, .name = "{esc(c["name"])}" }},')
out.append('};')
out.append('')
for c in cats:
    if not c["subs"]:
        continue
    out.append(f"const subs_{c['cat']:02X} = [_]Sub{{")
    for s in c["subs"]:
        if s["name"]:
            out.append(f'    .{{ .v = 0x{s["v"]:02X}, .name = "{esc(s["name"])}" }},')
    out.append('};')
out.append('''
/// Subcategory table flattened: (category, value) -> name.
pub const SubRef = struct { cat: u8, v: u8, name: []const u8 };

pub const sub_table = [_]SubRef{
    .{ .cat = 0x02, .v = 0x01, .name = "Desktop Workstation" },
    .{ .cat = 0x02, .v = 0x03, .name = "Laptop" },
    .{ .cat = 0x02, .v = 0x07, .name = "Tablet" },
};

pub fn category(id: u8) ?[]const u8 {
    for (categories) |c| {
        if (c.id == id) return c.name;
    }
    return null;
}

/// "Watch" / "Sports Watch" for a raw appearance value.
pub fn nameFor(appearance: u16) []const u8 {
    const cat: u8 = @intCast(appearance >> 6);
    const sub: u8 = @intCast(appearance & 0x3F);
    const c = category(cat) orelse return "unknown";
    if (sub == 0) return c;
    for (subsOf(cat)) |s| {
        if (s.v == sub) return s.name;
    }
    return c;
}

/// Subcategories attached to a category (finds the declaration by id).
pub fn subsOf(cat: u8) []const Sub {
    for (categories) |c| {
        if (c.id == cat) return c.subs;
    }
    return &.{};
}

test "appearance lookup" {
    try std.testing.expectEqualStrings("Unknown", nameFor(0));
    try std.testing.expectEqualStrings("Phone", nameFor(0x0040));
    try std.testing.expectEqualStrings("Computer", nameFor(0x0080));
    try std.testing.expectEqualStrings("Laptop", nameFor((0x02 << 6) | 0x03));
    try std.testing.expectEqualStrings("Watch", nameFor(0x00C0));
    try std.testing.expectEqualStrings("Thermometer", nameFor(0x0300));
    try std.testing.expectEqualStrings("Human Interface Device", nameFor(0x03C0));
    try std.testing.expectEqualStrings("Keyboard", nameFor((0x03C0 >> 6 << 6) | 0x01));
}
''')
pathlib.Path("src/db/appearance.zig").write_text("\n".join(out), encoding="utf-8")
print(f"appearance: {len(cats)} categories")
