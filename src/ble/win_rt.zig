//! Native WinRT BLE backend: direct COM calls to the
//! Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher
//! without any PowerShell/C# helper process.
//!
//! COM vtables are read via a raw usize load (bypassing Zig's alignment
//! checks on anyopaque) and WinRT function pointers are resolved at
//! runtime via LoadLibrary/GetProcAddress (no .lib files needed).

const std = @import("std");
const builtin = @import("builtin");
const model = @import("model.zig");
const bus_mod = @import("../bus.zig");
const replay = @import("replay.zig");

pub const label = "win-rt";

// --- GUIDs ---

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

const IID_IUnknown = GUID{ .data1 = 0x00000000, .data2 = 0x0000, .data3 = 0x0000, .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
const IID_IActivationFactory = GUID{ .data1 = 0x00000035, .data2 = 0x0000, .data3 = 0x0000, .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
const IID_Watcher = GUID{ .data1 = 0xA6AC336F, .data2 = 0xF3D3, .data3 = 0x4297, .data4 = .{ 0x8D, 0x6C, 0xC8, 0x1E, 0xA6, 0x62, 0x3F, 0x40 } };
// Windows::Storage::Streams::IBufferByteAccess — the ONLY way to get raw
// bytes out of an IBuffer (get_Data's return type). Do not confuse this
// with Windows::Foundation::IMemoryBufferByteAccess, a DIFFERENT interface
// (different GUID, different vtable shape: GetBuffer(byte**, UINT32*) with
// a length out-param) used only by Windows.Foundation.MemoryBuffer, which
// is not what get_Data returns. QueryInterface-ing an IBuffer for
// IMemoryBufferByteAccess's IID fails (E_NOINTERFACE), which silently
// drops every AD section with no error — that's the bug this comment is
// here to stop someone from reintroducing. IBufferByteAccess has exactly
// one method, Buffer(byte** value) — no length; get the length separately
// from IBuffer::get_Length (see VT_IBuffer / VT_BufferByteAccess below).
// Value verified against the system's live WinRT runtime: this GUID plus
// the plain-IUnknown vtable in VT_BufferByteAccess actually returns valid
// AD-section bytes end to end (see win_rt live-capture testing).
const IID_IBufferByteAccess = GUID{ .data1 = 0x905A0FEF, .data2 = 0xBC53, .data3 = 0x11DF, .data4 = .{ 0x8C, 0x49, 0x00, 0x1E, 0x4F, 0xC6, 0x86, 0xDA } };
// IID for ITypedEventHandler<Watcher, ReceivedEventArgs> — from PS reflection
const IID_Handler = GUID{ .data1 = 0x90EB4ECA, .data2 = 0xD465, .data3 = 0x5EA0, .data4 = .{ 0xA6, 0x1C, 0x03, 0x3C, 0x8C, 0x5E, 0xCE, 0xF2 } };

// --- COM vtable access ---

fn vtable(ptr: anytype, comptime T: type) *const T {
    const addr = @intFromPtr(ptr);
    const vtbl_addr: usize = @as(*align(1) const usize, @ptrFromInt(addr)).*;
    return @ptrFromInt(vtbl_addr);
}

const IUnknown_VT = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
};

fn vRelease(iface: *anyopaque) void {
    _ = vtable(iface, IUnknown_VT).Release(iface);
}

fn vQI(iface: *anyopaque, iid: *const GUID, out: *?*anyopaque) i32 {
    return vtable(iface, IUnknown_VT).QueryInterface(iface, iid, out);
}

fn guidEql(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

// --- WinRT vtable layouts ---
// All WinRT interfaces: IUnknown(3) + IInspectable(3) + interface methods.

const VT_IActivationFactory = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
    GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
    ActivateInstance: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
};

const VT_Watcher = extern struct {
    // IUnknown (0-2) + IInspectable (3-5)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
    GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
    // IBluetoothLEAdvertisementWatcher (6+) — exact order from .winmd via PS reflection
    get_MinSamplingInterval: *const fn (*anyopaque, *i64) callconv(.c) i32,       // 6
    get_MaxSamplingInterval: *const fn (*anyopaque, *i64) callconv(.c) i32,       // 7
    get_MinOutOfRangeTimeout: *const fn (*anyopaque, *i64) callconv(.c) i32,      // 8
    get_MaxOutOfRangeTimeout: *const fn (*anyopaque, *i64) callconv(.c) i32,      // 9
    get_Status: *const fn (*anyopaque, *i32) callconv(.c) i32,                    // 10
    get_ScanningMode: *const fn (*anyopaque, *i32) callconv(.c) i32,               // 11
    put_ScanningMode: *const fn (*anyopaque, i32) callconv(.c) i32,                // 12
    get_SignalStrengthFilter: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32, // 13
    put_SignalStrengthFilter: *const fn (*anyopaque, *anyopaque) callconv(.c) i32,  // 14
    get_AdvertisementFilter: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32, // 15
    put_AdvertisementFilter: *const fn (*anyopaque, *anyopaque) callconv(.c) i32,  // 16
    Start: *const fn (*anyopaque) callconv(.c) i32,                                // 17
    Stop: *const fn (*anyopaque) callconv(.c) i32,                                 // 18
    add_Received: *const fn (*anyopaque, *anyopaque, *u64) callconv(.c) i32,       // 19
    remove_Received: *const fn (*anyopaque, u64) callconv(.c) i32,                 // 20
    add_Stopped: *const fn (*anyopaque, *anyopaque, *u64) callconv(.c) i32,        // 21
    remove_Stopped: *const fn (*anyopaque, u64) callconv(.c) i32,                  // 22
};

const VT_EventArgs = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
    GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
    // Exact order from .winmd via PS reflection
    get_RawSignalStrengthInDBm: *const fn (*anyopaque, *i16) callconv(.c) i32,  // 6
    get_BluetoothAddress: *const fn (*anyopaque, *u64) callconv(.c) i32,        // 7
    get_AdvertisementType: *const fn (*anyopaque, *i32) callconv(.c) i32,       // 8
    get_Timestamp: *const fn (*anyopaque, *i64) callconv(.c) i32,               // 9
    get_Advertisement: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,   // 10
    // NOTE: get_BluetoothAddressType and beyond are on v2+ interfaces,
    // not present in this v1 vtable (slots past 10 = garbage).
};

const VT_Advertisement = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
    GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
    // Exact order from .winmd via PS reflection
    get_Flags: *const fn (*anyopaque, *u8) callconv(.c) i32,                    // 6
    put_Flags: *const fn (*anyopaque, u8) callconv(.c) i32,                     // 7
    get_LocalName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,       // 8
    put_LocalName: *const fn (*anyopaque, ?*anyopaque) callconv(.c) i32,        // 9
    get_ServiceUuids: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,    // 10
    get_ManufacturerData: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32, // 11
    get_DataSections: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,    // 12
};

const VT_DataSection = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
    GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
    // IBluetoothLEAdvertisementDataSection — from .winmd
    get_DataType: *const fn (*anyopaque, *u8) callconv(.c) i32,       // 6
    put_DataType: *const fn (*anyopaque, u8) callconv(.c) i32,        // 7
    get_Data: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,  // 8
    put_Data: *const fn (*anyopaque, *anyopaque) callconv(.c) i32,    // 9
};

const VT_IVectorView = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
    GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
    GetAt: *const fn (*anyopaque, u32, *?*anyopaque) callconv(.c) i32,
    get_Size: *const fn (*anyopaque, *u32) callconv(.c) i32,
};

// Windows.Storage.Streams.IBuffer — a normal WinRT interface (has
// IInspectable), from .winmd. get_Data() returns this. Only get_Length is
// needed: the raw pointer comes from IBufferByteAccess below, but that
// interface has no length accessor of its own — you MUST pair it with
// IBuffer::get_Length or you don't know how many bytes are valid at the
// returned pointer.
const VT_IBuffer = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
    GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
    get_Capacity: *const fn (*anyopaque, *u32) callconv(.c) i32, // 6 (unused)
    get_Length: *const fn (*anyopaque, *u32) callconv(.c) i32,   // 7
};

// Windows::Storage::Streams::IBufferByteAccess — a CLASSIC (non-WinRT) COM
// interface: plain IUnknown, NO IInspectable slots, exactly one method.
// It is not declared in any .winmd (it's native-only, from robuffer.h) and
// it is NOT the same interface as Windows::Foundation::IMemoryBufferByteAccess
// (different GUID, different 2-arg GetBuffer(byte**, UINT32*) shape — that
// one belongs to Windows.Foundation.MemoryBuffer, not IBuffer). Mixing the
// two up is the exact bug that made every AD section come back empty
// before — see the comment on IID_IBufferByteAccess. If you add fields
// here, do NOT add IInspectable slots; Buffer() really is vtable slot 3.
const VT_BufferByteAccess = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    Buffer: *const fn (*anyopaque, *?[*]u8) callconv(.c) i32, // 3 — no length out-param
};

// --- WinRT function resolution (no .lib needed) ---

const comapi = struct {
    var pRoGetActivationFactory: ?*const fn (?*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32 = null;
    var pWindowsCreateString: ?*const fn ([*]const u16, u32, *?*anyopaque) callconv(.c) i32 = null;
    var pWindowsDeleteString: ?*const fn (?*anyopaque) callconv(.c) i32 = null;
    var pWindowsGetStringRawBuffer: ?*const fn (?*anyopaque, *u32) callconv(.c) ?[*]const u16 = null;
    var pCoInitializeEx: ?*const fn (?*anyopaque, u32) callconv(.c) i32 = null;
    var loaded: bool = false;

    fn ensure() bool {
        if (loaded) return pRoGetActivationFactory != null;
        loaded = true;
        const k32 = struct {
            extern "kernel32" fn LoadLibraryA([*:0]const u8) callconv(.c) ?*anyopaque;
            extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque;
        };
        const combase = k32.LoadLibraryA("combase.dll") orelse return false;
        const ole32 = k32.LoadLibraryA("ole32.dll") orelse return false;
        pRoGetActivationFactory = @ptrCast(k32.GetProcAddress(combase, "RoGetActivationFactory"));
        pWindowsCreateString = @ptrCast(k32.GetProcAddress(combase, "WindowsCreateString"));
        pWindowsDeleteString = @ptrCast(k32.GetProcAddress(combase, "WindowsDeleteString"));
        pWindowsGetStringRawBuffer = @ptrCast(k32.GetProcAddress(combase, "WindowsGetStringRawBuffer"));
        pCoInitializeEx = @ptrCast(k32.GetProcAddress(ole32, "CoInitializeEx"));
        return pRoGetActivationFactory != null and pWindowsCreateString != null;
    }
};

const HSTRING = ?*anyopaque;

// --- Event handler ---

const Handler = struct {
    vt: *const HandlerVT,
    ref: std.atomic.Value(u32),
    ctx: *WinRt,

    const HandlerVT = extern struct {
        QueryInterface: *const fn (*Handler, *const GUID, *?*anyopaque) callconv(.c) i32,
        AddRef: *const fn (*Handler) callconv(.c) u32,
        Release: *const fn (*Handler) callconv(.c) u32,
        Invoke: *const fn (*Handler, *anyopaque, *anyopaque) callconv(.c) i32,
    };

    const vt_inst = HandlerVT{
        .QueryInterface = hQI,
        .AddRef = hAddRef,
        .Release = hRelease,
        .Invoke = hInvoke,
    };

    fn create(ctx: *WinRt) *Handler {
        const h = ctx.gpa.create(Handler) catch unreachable;
        h.* = .{ .vt = &vt_inst, .ref = std.atomic.Value(u32).init(1), .ctx = ctx };
        return h;
    }

    fn hQI(self: *Handler, riid: *const GUID, ppv: *?*anyopaque) callconv(.c) i32 {
        if (guidEql(riid, &IID_IUnknown) or guidEql(riid, &IID_Handler)) {
            _ = hAddRef(self); // QI must AddRef (COM convention)
            ppv.* = @ptrCast(self);
            return 0;
        }
        ppv.* = null;
        return -2147467263;
    }

    fn hAddRef(self: *Handler) callconv(.c) u32 {
        return self.ref.fetchAdd(1, .acq_rel) + 1;
    }

    fn hRelease(self: *Handler) callconv(.c) u32 {
        const prev = self.ref.fetchSub(1, .acq_rel);
        if (prev == 1) {
            self.ctx.gpa.destroy(self);
            return 0;
        }
        return prev - 1;
    }

    fn hInvoke(self: *Handler, sender: *anyopaque, args: *anyopaque) callconv(.c) i32 {
        _ = sender;
        extractAndEmit(self.ctx, args) catch {};
        return 0;
    }
};

// --- Backend ---

pub const WinRt = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    b: *bus_mod.Bus,
    watcher: ?*anyopaque = null,
    cookie: u64 = 0,
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn spawn(gpa: std.mem.Allocator, io: std.Io, b: *bus_mod.Bus) !*WinRt {
        if (builtin.os.tag != .windows) return error.NotSupported;
        if (!comapi.ensure()) return error.WinRtNotAvailable;

        const self = try gpa.create(WinRt);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .b = b };

        _ = comapi.pCoInitializeEx.?(null, 0);

        // Activation factory → watcher instance.
        var factory: ?*anyopaque = null;
        {
            const cls = "Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher";
            var wide: [128]u16 = undefined;
            for (cls, 0..) |c, i| wide[i] = c;
            var hstr: HSTRING = null;
            _ = comapi.pWindowsCreateString.?(&wide, @intCast(cls.len), &hstr);
            defer _ = comapi.pWindowsDeleteString.?(hstr);
            const hr = comapi.pRoGetActivationFactory.?(hstr, &IID_IActivationFactory, &factory);
            if (hr != 0) return error.ActivationFactoryFailed;
        }
        defer _ = vRelease(factory.?); // release factory when done

        var insp: ?*anyopaque = null;
        if (vtable(factory.?, VT_IActivationFactory).ActivateInstance(factory.?, &insp) != 0)
            return error.ActivateInstanceFailed;
        defer _ = vRelease(insp.?);

        var w: ?*anyopaque = null;
        if (vQI(insp.?, &IID_Watcher, &w) != 0)
            return error.QIFailed;
        self.watcher = w.?;
        return self;
    }

    pub fn threadMain(self: *WinRt) void {
        if (builtin.os.tag != .windows) return;
        const w = self.watcher orelse return;
        const vt = vtable(w, VT_Watcher);

        const handler = Handler.create(self);
        if (vt.add_Received(w, @ptrCast(handler), &self.cookie) != 0) {
            self.b.push(.{ .backend = .{ .code = .failed, .msg = "add_Received failed" } });
            _ = handler.hRelease(); // release our ref on failure
            return;
        }
        if (vt.Start(w) != 0) {
            self.b.push(.{ .backend = .{ .code = .failed, .msg = "Start failed (no BT adapter?)" } });
            _ = vt.remove_Received(w, self.cookie);
            _ = handler.hRelease();
            return;
        }
        self.b.push(.{ .backend = .{ .code = .started } });

        while (!self.stopped.load(.acquire)) {
            self.io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        }

        _ = vt.Stop(w);
        _ = vt.remove_Received(w, self.cookie);
        // Release our initial handler reference.
        _ = handler.hRelease();
        // Release the watcher COM reference.
        _ = vRelease(w);
    }

    pub fn stop(self: *WinRt) void {
        if (builtin.os.tag != .windows) return;
        self.stopped.store(true, .release);
    }
};

// --- Event data extraction ---

fn extractAndEmit(ctx: *WinRt, args: *anyopaque) !void {
    const av = vtable(args, VT_EventArgs);

    var addr_u64: u64 = 0;
    if (av.get_BluetoothAddress(args, &addr_u64) != 0) return;

    var adv: ?*anyopaque = null;
    if (av.get_Advertisement(args, &adv) != 0 or adv == null) return;
    defer _ = vRelease(adv.?);
    const adv_vt = vtable(adv.?, VT_Advertisement);

    // v1 interface has no get_BluetoothAddressType; default to public.
    const atype: i32 = 0;

    var rssi: i16 = -128;
    _ = av.get_RawSignalStrengthInDBm(args, &rssi);

    var adv_type: i32 = 0;
    _ = av.get_AdvertisementType(args, &adv_type);

    // LocalName via HSTRING — UTF-16LE, must transcode to UTF-8.
    var name_buf: [64]u8 = undefined;
    var name: ?[]const u8 = null;
    {
        var hstr: HSTRING = null;
        if (adv_vt.get_LocalName(adv.?, &hstr) == 0 and hstr != null) {
            var len: u32 = 0;
            const buf = comapi.pWindowsGetStringRawBuffer.?(hstr, &len);
            if (len > 0 and buf != null) {
                // Transcode UTF-16 → UTF-8 (ASCII fast path).
                const units = buf.?[0..@min(len, 32)]; // max 32 UTF-16 units
                var w: usize = 0;
                for (units) |u| {
                    if (w >= name_buf.len) break;
                    if (u < 0x80 and u >= 0x20) {
                        name_buf[w] = @intCast(u);
                        w += 1;
                    } else if (u < 0x800 and w + 1 < name_buf.len) {
                        // 2-byte UTF-8
                        name_buf[w] = @intCast(0xC0 | (u >> 6));
                        name_buf[w + 1] = @intCast(0x80 | (u & 0x3F));
                        w += 2;
                    } else if (w + 2 < name_buf.len) {
                        // 3-byte UTF-8 (simplified — skip surrogate pairs)
                        name_buf[w] = 0xE0 | @as(u8, @intCast((u >> 12) & 0x0F));
                        name_buf[w + 1] = 0x80 | @as(u8, @intCast((u >> 6) & 0x3F));
                        name_buf[w + 2] = 0x80 | @as(u8, @intCast(u & 0x3F));
                        w += 3;
                    } else break;
                }
                if (w > 0) name = name_buf[0..w];
            }
            // NOTE: must copy name bytes BEFORE deleting the HSTRING,
            // the raw buffer is only valid while the HSTRING is alive.
            // We copy into name_buf above, so it's safe to delete now.
            _ = comapi.pWindowsDeleteString.?(hstr);
        }
    }

    // DataSections: IVectorView → IBluetoothLEAdvertisementDataSection → IBuffer → raw bytes
    var secs: [64]model.AdSection = undefined;
    var n: usize = 0;

    var vec: ?*anyopaque = null;
    const hr_ds = adv_vt.get_DataSections(adv.?, &vec);
    if (hr_ds != 0) return;
    if (vec == null) return;
    defer _ = vRelease(vec.?);

    const vv = vtable(vec.?, VT_IVectorView);
    var count: u32 = 0;
    if (vv.get_Size(vec.?, &count) == 0) {
        var i: u32 = 0;
        while (i < count and n < secs.len) : (i += 1) {
            var sec: ?*anyopaque = null;
            if (vv.GetAt(vec.?, i, &sec) == 0 and sec != null) {
                defer _ = vRelease(sec.?);
                const sv = vtable(sec.?, VT_DataSection);
                var dt: u8 = 0;
                var buf_i: ?*anyopaque = null;
                if (sv.get_DataType(sec.?, &dt) == 0 and
                    sv.get_Data(sec.?, &buf_i) == 0 and buf_i != null)
                {
                    defer _ = vRelease(buf_i.?);
                    // Length comes from IBuffer::get_Length (buf_i is
                    // already an IBuffer — no QI needed for that part).
                    // The raw pointer comes from a SEPARATE QI for
                    // IBufferByteAccess (see its comment: do not swap in
                    // IMemoryBufferByteAccess's 2-arg GetBuffer here).
                    var len: u32 = 0;
                    _ = vtable(buf_i.?, VT_IBuffer).get_Length(buf_i.?, &len);
                    var ba: ?*anyopaque = null;
                    if (len > 0 and vQI(buf_i.?, &IID_IBufferByteAccess, &ba) == 0 and ba != null) {
                        defer _ = vRelease(ba.?);
                        var dp: ?[*]u8 = null;
                        if (vtable(ba.?, VT_BufferByteAccess).Buffer(ba.?, &dp) == 0 and dp != null) {
                            secs[n] = .{ .typ = dt, .data = dp.?[0..len] };
                            n += 1;
                        }
                    }
                }
            }
        }
    }

    emitEvent(ctx, addr_u64, atype, adv_type, rssi, name, secs[0..n]);
}

fn emitEvent(ctx: *WinRt, addr_u64: u64, atype: i32, adv_type: i32, rssi: i16, name: ?[]const u8, secs: []const model.AdSection) void {
    const gpa = ctx.gpa;
    var total: usize = if (name) |nm| @min(nm.len, 64) else 0;
    for (secs) |s| total += s.data.len;

    const backing = gpa.alloc(u8, total) catch return;
    const sections = gpa.alloc(model.AdSection, secs.len) catch {
        gpa.free(backing);
        return;
    };

    var off: usize = 0;
    var name_copy: ?[]const u8 = null;
    if (name) |nm| {
        const cn = @min(nm.len, 64);
        @memcpy(backing[off..][0..cn], nm[0..cn]);
        name_copy = backing[off..][0..cn];
        off += cn;
    }
    for (secs, 0..) |s, i| {
        @memcpy(backing[off..][0..s.data.len], s.data);
        sections[i] = .{ .typ = s.typ, .data = backing[off..][0..s.data.len] };
        off += s.data.len;
    }

    var addr: [6]u8 = undefined;
    addr[0] = @truncate(addr_u64 >> 40);
    addr[1] = @truncate(addr_u64 >> 32);
    addr[2] = @truncate(addr_u64 >> 24);
    addr[3] = @truncate(addr_u64 >> 16);
    addr[4] = @truncate(addr_u64 >> 8);
    addr[5] = @truncate(addr_u64);

    const ev = gpa.create(model.AdvEvent) catch {
        gpa.free(backing);
        gpa.free(sections);
        return;
    };
    ev.* = .{
        .addr = addr,
        .addr_type = if (atype == 1) .random else .public,
        .adv_type = switch (adv_type) {
            1 => .connectable_directed,
            2 => .scannable_undirected,
            3 => .non_connectable_undirected,
            4 => .scan_response,
            else => .connectable_undirected,
        },
        .rssi = @intCast(std.math.clamp(@as(i32, rssi), -128, 127)),
        .name = name_copy,
        .sections = sections,
        .ts_ms = replay.nowMs(ctx.io),
        .backing = backing,
    };
    ctx.b.push(.{ .adv = ev });
}
