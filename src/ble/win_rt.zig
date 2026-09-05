//! Native WinRT BLE backend: direct COM calls to the
//! Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher
//! without any PowerShell/C# helper process.
//!
//! The WinRT ABI is COM: we define the minimal interface vtables we need
//! (with exact GUIDs and vtable slot orders taken from the system
//! WinMetadata store — see below), initialize the Windows Runtime,
//! activate the watcher factory, subscribe to the Received event with a
//! COM callback object, and extract advertisement data from the event
//! args. Events are pushed onto the same EventBus as all backends.
//!
//! Vtable slot order for a WinRT interface is NOT its declaration order in
//! any header — it's the MethodDef order baked into the .winmd metadata,
//! which isn't documented anywhere. The orders and GUIDs below were
//! extracted by reading C:\Windows\System32\WinMetadata\Windows.Devices.winmd
//! (present on every Windows 10/11 install) with
//! System.Reflection.Metadata and listing each interface's methods in
//! declaration order, which for a WinRT interface's MethodDef table is
//! exactly the vtable order used at runtime.

const std = @import("std");
const builtin = @import("builtin");
const model = @import("model.zig");
const bus_mod = @import("../bus.zig");
const replay = @import("replay.zig");

pub const label = "win-rt";

pub const WinRt = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    b: *bus_mod.Bus,
    watcher: ?*anyopaque = null,
    event_cookie: u64 = 0,
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn spawn(gpa: std.mem.Allocator, io: std.Io, b: *bus_mod.Bus) !*WinRt {
        if (builtin.os.tag != .windows) return error.NotSupported;
        if (!comapi.ensureLoaded()) return error.WinRtNotAvailable;
        const self = try gpa.create(WinRt);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .b = b };

        // Initialize COM for this thread (MTA — WinRT events arrive on
        // the threadpool).
        const hr = comapi.CoInitializeEx(null, comapi.COINIT_MULTITHREADED);
        if (hr != 0 and hr != S_FALSE) return error.ComInitFailed;

        // Activate the BluetoothLEAdvertisementWatcher factory.
        const factory = try activateFactory(
            "Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher",
            &IID_IActivationFactory,
        );

        // Create the watcher instance via ActivateInstance.
        const watcher_iface = try createWatcher(factory, &IID_IBluetoothLEAdvertisementWatcher);
        self.watcher = watcher_iface;

        return self;
    }

    pub fn threadMain(self: *WinRt) void {
        if (builtin.os.tag != .windows) return;
        const w = self.watcher orelse return;
        const wvt = vtable(w, IBluetoothLEAdvertisementWatcher);

        // Active scanning: the default is Passive (advertising packets
        // only, no scan responses / local names on many devices). win-ps
        // sets this explicitly too — match it here.
        _ = wvt.put_ScanningMode(w, @intFromEnum(ScanningMode.active));

        // Subscribe to the Received event.
        const handler = Handler.create(self);
        defer handler.release();

        const hr_sub = wvt.add_Received(w, @ptrCast(handler), &self.event_cookie);
        if (hr_sub != 0) {
            self.b.push(.{ .backend = .{ .code = .failed, .msg = "add_Received failed" } });
            return;
        }

        const hr_start = wvt.Start(w);
        if (hr_start != 0) {
            _ = wvt.remove_Received(w, self.event_cookie);
            self.b.push(.{ .backend = .{ .code = .failed, .msg = "watcher.Start() failed (no Bluetooth adapter?)" } });
            return;
        }
        self.b.push(.{ .backend = .{ .code = .started } });

        // Park this thread — events arrive on the threadpool via the
        // COM callback. We just need to keep COM alive.
        while (!self.stopped.load(.acquire)) {
            self.io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        }

        _ = wvt.remove_Received(w, self.event_cookie);
        _ = wvt.Stop(w);
    }

    pub fn stop(self: *WinRt) void {
        if (builtin.os.tag != .windows) return;
        self.stopped.store(true, .release);
    }
};

const ScanningMode = enum(i32) {
    passive = 0,
    active = 1,
};

// --- COM event handler (ITypedEventHandler<Watcher, ReceivedEventArgs>) ---

const Handler = struct {
    // COM object layout: vtable ptr + ref count + context
    vtable: *const HandlerVTable,
    ref_count: u32,
    ctx: *WinRt,

    const HandlerVTable = extern struct {
        // IUnknown
        QueryInterface: *const fn (*Handler, *const GUID, *?*anyopaque) callconv(.c) i32,
        AddRef: *const fn (*Handler) callconv(.c) u32,
        Release: *const fn (*Handler) callconv(.c) u32,
        // ITypedEventHandler (Invoke is the only method; delegates have no
        // IInspectable slots)
        Invoke: *const fn (*Handler, *anyopaque, *anyopaque) callconv(.c) i32,
    };

    const vtable_instance = HandlerVTable{
        .QueryInterface = handlerQI,
        .AddRef = handlerAddRef,
        .Release = handlerRelease,
        .Invoke = handlerInvoke,
    };

    fn create(ctx: *WinRt) *Handler {
        const h = ctx.gpa.create(Handler) catch unreachable;
        h.* = .{ .vtable = &vtable_instance, .ref_count = 1, .ctx = ctx };
        return h;
    }

    fn release(self: *Handler) void {
        _ = handlerRelease(self);
    }

    fn handlerQI(self: *Handler, riid: *const GUID, ppv: *?*anyopaque) callconv(.c) i32 {
        // add_Received QueryInterfaces the handler we pass it for the
        // exact ITypedEventHandler<Watcher, ReceivedEventArgs> IID before
        // storing it (confirmed empirically: without this, add_Received
        // returns E_NOTIMPL instead of registering). That IID isn't in
        // any .winmd — WinRT computes generic instantiation IIDs by
        // hashing a signature string (RFC 4122 v5 UUID, namespace
        // 11f47ad5-7b73-42c0-abae-878b1e16adee) — see IID_ITypedEventHandler.
        // We also answer IAgileObject so COM never tries to marshal calls
        // to this object across apartments/threads.
        if (guidEql(riid, &IID_IUnknown) or guidEql(riid, &IID_IAgileObject) or guidEql(riid, &IID_ITypedEventHandler)) {
            ppv.* = @ptrCast(self);
            _ = handlerAddRef(self);
            return S_OK;
        }
        ppv.* = null;
        return E_NOINTERFACE;
    }

    fn handlerAddRef(self: *Handler) callconv(.c) u32 {
        self.ref_count += 1;
        return self.ref_count;
    }

    fn handlerRelease(self: *Handler) callconv(.c) u32 {
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            self.ctx.gpa.destroy(self);
            return 0;
        }
        return self.ref_count;
    }

    /// The Received event callback — runs on the WinRT threadpool.
    fn handlerInvoke(self: *Handler, sender: *anyopaque, args_iface: *anyopaque) callconv(.c) i32 {
        _ = sender;
        const ctx = self.ctx;

        var args_ptr: ?*anyopaque = null;
        if (vQI(args_iface, &IID_IBluetoothLEAdvertisementReceivedEventArgs, &args_ptr) != 0) return S_OK;
        const args = args_ptr orelse return S_OK;
        defer vRelease(args);
        const avt = vtable(args, IBluetoothLEAdvertisementReceivedEventArgs);

        var rssi: i16 = 0;
        _ = avt.get_RawSignalStrengthInDBm(args, &rssi);
        var bt_addr: u64 = 0;
        _ = avt.get_BluetoothAddress(args, &bt_addr);
        var adv_type_raw: i32 = 0;
        _ = avt.get_AdvertisementType(args, &adv_type_raw);

        // BluetoothAddressType lives on the *2 extension interface, not
        // the base one — a separate QI, not an extra vtable slot.
        var addr_type_raw: i32 = 0;
        var args2_ptr: ?*anyopaque = null;
        if (vQI(args, &IID_IBluetoothLEAdvertisementReceivedEventArgs2, &args2_ptr) == 0) {
            if (args2_ptr) |args2| {
                defer vRelease(args2);
                _ = vtable(args2, IBluetoothLEAdvertisementReceivedEventArgs2).get_BluetoothAddressType(args2, &addr_type_raw);
            }
        }

        var adv_ptr: ?*anyopaque = null;
        if (avt.get_Advertisement(args, &adv_ptr) != 0) {
            emitEvent(ctx, bt_addr, addr_type_raw, adv_type_raw, rssi, null, &.{});
            return S_OK;
        }
        const adv = adv_ptr orelse {
            emitEvent(ctx, bt_addr, addr_type_raw, adv_type_raw, rssi, null, &.{});
            return S_OK;
        };
        defer vRelease(adv);
        const advvt = vtable(adv, IBluetoothLEAdvertisement);

        // Local name.
        var name_buf: [256]u8 = undefined;
        var name_slice: ?[]const u8 = null;
        var hstr: HSTRING = null;
        if (advvt.get_LocalName(adv, &hstr) == 0 and hstr != null) {
            defer _ = comapi.WindowsDeleteString(hstr);
            var wlen: u32 = 0;
            if (comapi.WindowsGetStringRawBuffer(hstr, &wlen)) |wbuf| {
                if (wlen > 0) {
                    const n = std.unicode.utf16LeToUtf8(&name_buf, wbuf[0..wlen]) catch 0;
                    if (n > 0) name_slice = name_buf[0..n];
                }
            }
        }

        // Data sections.
        var secs_buf: [32]model.AdSection = undefined;
        var secs_count: usize = 0;
        var sections_ptr: ?*anyopaque = null;
        if (advvt.get_DataSections(adv, &sections_ptr) == 0) {
            if (sections_ptr) |vec| {
                defer vRelease(vec);
                const vecvt = vtable(vec, IVectorView_DataSection);
                var size: u32 = 0;
                _ = vecvt.get_Size(vec, &size);
                var i: u32 = 0;
                while (i < size and secs_count < secs_buf.len) : (i += 1) {
                    var sec_ptr: ?*anyopaque = null;
                    if (vecvt.GetAt(vec, i, &sec_ptr) != 0) continue;
                    const sec = sec_ptr orelse continue;
                    defer vRelease(sec);
                    const secvt = vtable(sec, IBluetoothLEAdvertisementDataSection);

                    var dtype: u8 = 0;
                    _ = secvt.get_DataType(sec, &dtype);

                    var buf_ptr: ?*anyopaque = null;
                    if (secvt.get_Data(sec, &buf_ptr) != 0) continue;
                    const buf = buf_ptr orelse continue;
                    defer vRelease(buf);

                    var blen: u32 = 0;
                    _ = vtable(buf, IBuffer).get_Length(buf, &blen);

                    var byte_access_ptr: ?*anyopaque = null;
                    if (vQI(buf, &IID_IBufferByteAccess, &byte_access_ptr) != 0) continue;
                    const byte_access = byte_access_ptr orelse continue;
                    defer vRelease(byte_access);

                    var bytes: ?[*]u8 = null;
                    if (vtable(byte_access, IBufferByteAccess).Buffer(byte_access, &bytes) != 0) continue;
                    const ptr = bytes orelse continue;

                    const data_len = @min(blen, 255);
                    secs_buf[secs_count] = .{ .typ = dtype, .data = ptr[0..data_len] };
                    secs_count += 1;
                }
            }
        }

        emitEvent(ctx, bt_addr, addr_type_raw, adv_type_raw, rssi, name_slice, secs_buf[0..secs_count]);
        return S_OK;
    }

    fn emitEvent(ctx: *WinRt, bt_addr: u64, addr_type: i32, adv_type: i32, rssi: i16, name: ?[]const u8, secs: []const model.AdSection) void {
        const gpa = ctx.gpa;

        // Extract sections into owned memory.
        var name_copy: ?[]const u8 = null;
        var total: usize = if (name) |n| @min(n.len, 64) else 0;
        for (secs) |s| total += s.data.len;

        const backing = gpa.alloc(u8, total) catch return;
        const sections = gpa.alloc(model.AdSection, secs.len) catch {
            gpa.free(backing);
            return;
        };

        var off: usize = 0;
        if (name) |n| {
            const cn = @min(n.len, 64);
            @memcpy(backing[off..][0..cn], n[0..cn]);
            name_copy = backing[off..][0..cn];
            off += cn;
        }
        for (secs, 0..) |s, i| {
            @memcpy(backing[off..][0..s.data.len], s.data);
            sections[i] = .{ .typ = s.typ, .data = backing[off..][0..s.data.len] };
            off += s.data.len;
        }

        // BluetoothAddress is a u64: AA-BB-CC-DD-EE-FF as big-endian bytes.
        var addr: [6]u8 = undefined;
        addr[0] = @truncate(bt_addr >> 40);
        addr[1] = @truncate(bt_addr >> 32);
        addr[2] = @truncate(bt_addr >> 24);
        addr[3] = @truncate(bt_addr >> 16);
        addr[4] = @truncate(bt_addr >> 8);
        addr[5] = @truncate(bt_addr);

        const at: model.AddrType = if (addr_type == 1) .random else .public;
        const avt: model.AdvType = switch (adv_type) {
            0 => .connectable_undirected,
            1 => .connectable_directed,
            2 => .scannable_undirected,
            3 => .non_connectable_undirected,
            4 => .scan_response,
            else => .connectable_undirected,
        };

        const ev = gpa.create(model.AdvEvent) catch {
            gpa.free(backing);
            gpa.free(sections);
            return;
        };
        ev.* = .{
            .addr = addr,
            .addr_type = at,
            .adv_type = avt,
            .rssi = @intCast(std.math.clamp(@as(i32, rssi), -128, 127)),
            .name = name_copy,
            .sections = sections,
            .ts_ms = replay.nowMs(ctx.io),
            .backing = backing,
        };
        ctx.b.push(.{ .adv = ev });
    }
};

// --- WinRT activation helpers ---

fn activateFactory(class_name: []const u8, iid: *const GUID) !*anyopaque {
    // HSTRING from literal
    var hstr: HSTRING = null;
    const wide = try std.heap.page_allocator.allocSentinel(u16, class_name.len, 0);
    defer std.heap.page_allocator.free(wide);
    for (class_name, 0..) |c, i| wide[i] = c;
    const hr = comapi.WindowsCreateString(wide.ptr, @as(u32, @intCast(class_name.len)), &hstr);
    if (hr != 0) return error.HstringCreateFailed;
    defer _ = comapi.WindowsDeleteString(hstr);

    var factory: ?*anyopaque = null;
    const hr2 = comapi.RoGetActivationFactory(hstr, iid, @ptrCast(&factory));
    if (hr2 != 0) return error.ActivationFactoryFailed;
    return factory.?;
}

fn vtable(ptr: anytype, comptime T: type) *const T {
    // COM objects start with a vtable pointer. Read it as a raw usize
    // to bypass Zig's alignment checking, then cast to the vtable type.
    const addr = @intFromPtr(ptr);
    const vtbl_addr: usize = @as(*align(1) const usize, @ptrFromInt(addr)).*;
    return @ptrFromInt(vtbl_addr);
}

const IUnknown_VTable = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
};

fn vRelease(iface: *anyopaque) void {
    const vt = vtable(iface, IUnknown_VTable);
    _ = vt.Release(iface);
}

fn vQI(iface: *anyopaque, iid: *const GUID, out: *?*anyopaque) i32 {
    const vt = vtable(iface, IUnknown_VTable);
    return vt.QueryInterface(iface, iid, out);
}

fn guidEql(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

// --- HRESULT constants ---

const S_OK: i32 = 0;
const S_FALSE: i32 = 1;
const E_NOINTERFACE: i32 = -2147467262; // 0x80004002

// --- GUIDs ---
//
// All GUIDs below (except the handful of universal COM constants noted
// inline) were read directly off the [Windows.Foundation.Metadata.GuidAttribute]
// on the corresponding TypeDef in the system's own
// C:\Windows\System32\WinMetadata\*.winmd files — not guessed or copied
// from unverified sources.

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

// Universal COM/WinRT constants (not in any .winmd — these are stable
// well-known values defined in unknwn.idl / inspectable.h).
const IID_IUnknown = GUID{ .data1 = 0x00000000, .data2 = 0x0000, .data3 = 0x0000, .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
const IID_IActivationFactory = GUID{ .data1 = 0x00000035, .data2 = 0x0000, .data3 = 0x0000, .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
const IID_IInspectable = GUID{ .data1 = 0xAF86E2E0, .data2 = 0xB12D, .data3 = 0x4C6A, .data4 = .{ 0x9C, 0x5A, 0xD7, 0xAA, 0x65, 0x10, 0x1E, 0x90 } };
// Answering this in QueryInterface marks an object as free-threaded /
// apartment-agnostic, so COM never tries to marshal calls to it.
const IID_IAgileObject = GUID{ .data1 = 0x94EA2B94, .data2 = 0xE9CC, .data3 = 0x49E0, .data4 = .{ 0xC0, 0xFF, 0xEE, 0x64, 0xCA, 0x8F, 0x5B, 0x90 } };
// Windows::Storage::Streams::IBufferByteAccess — a classic (non-WinRT,
// no IInspectable) COM interface implemented by IBuffer objects; not
// projected in any .winmd since it's declared in the native robuffer.h.
const IID_IBufferByteAccess = GUID{ .data1 = 0x905A0FEF, .data2 = 0xBC53, .data3 = 0x11DF, .data4 = .{ 0x8C, 0x49, 0x00, 0x1E, 0x4F, 0xC6, 0x86, 0xDA } };

// Windows.Devices.Bluetooth.Advertisement.IBluetoothLEAdvertisementWatcher
const IID_IBluetoothLEAdvertisementWatcher = GUID{
    .data1 = 0xA6AC336F, .data2 = 0xF3D3, .data3 = 0x4297,
    .data4 = .{ 0x8D, 0x6C, 0xC8, 0x1E, 0xA6, 0x62, 0x3F, 0x40 },
};

// Windows.Devices.Bluetooth.Advertisement.IBluetoothLEAdvertisementReceivedEventArgs
const IID_IBluetoothLEAdvertisementReceivedEventArgs = GUID{
    .data1 = 0x27987DDF, .data2 = 0xE596, .data3 = 0x41BE,
    .data4 = .{ 0x8D, 0x43, 0x9E, 0x67, 0x31, 0xD4, 0xA9, 0x13 },
};

// Windows.Devices.Bluetooth.Advertisement.IBluetoothLEAdvertisementReceivedEventArgs2
// (extension interface carrying BluetoothAddressType, not on the base).
const IID_IBluetoothLEAdvertisementReceivedEventArgs2 = GUID{
    .data1 = 0x12D9C87B, .data2 = 0x0399, .data3 = 0x5F0E,
    .data4 = .{ 0xA3, 0x48, 0x53, 0xB0, 0x2B, 0x6B, 0x16, 0x2E },
};

// Windows.Devices.Bluetooth.Advertisement.IBluetoothLEAdvertisement
const IID_IBluetoothLEAdvertisement = GUID{
    .data1 = 0x066FB2B7, .data2 = 0x33D1, .data3 = 0x4E7D,
    .data4 = .{ 0x83, 0x67, 0xCF, 0x81, 0xD0, 0xF7, 0x96, 0x53 },
};

// Windows.Devices.Bluetooth.Advertisement.IBluetoothLEAdvertisementDataSection
const IID_IBluetoothLEAdvertisementDataSection = GUID{
    .data1 = 0xD7213314, .data2 = 0x3A43, .data3 = 0x40F9,
    .data4 = .{ 0xB6, 0xF0, 0x92, 0xBF, 0xEF, 0xC3, 0x4A, 0xE3 },
};

// ITypedEventHandler<BluetoothLEAdvertisementWatcher, BluetoothLEAdvertisementReceivedEventArgs>.
// Not in any .winmd — generic (parameterized) WinRT interfaces get their
// IID by hashing a signature string as an RFC 4122 v5 UUID against the
// namespace 11f47ad5-7b73-42c0-abae-878b1e16adee:
//   pinterface({9de1c534-6ae1-11e0-84e1-18a905bcc53f};       <- TypedEventHandler`2's own GUID
//     rc(Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher;{a6ac336f-f3d3-4297-8d6c-c81ea6623f40});
//     rc(Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementReceivedEventArgs;{27987ddf-e596-41be-8d43-9e6731d4a913}))
// This exact algorithm (namespace GUID, SHA1, "pinterface(...)"/"cinterface(...)"
// grammar) was verified against this machine's live WinRT runtime: hashing
// "pinterface({<IMap`2 guid>};string;cinterface(IInspectable))" reproduces
// one of the real IIDs Windows.Foundation.Collections.PropertySet reports
// from IInspectable::GetIids (and likewise for IObservableMap<...> and the
// nested IIterable<IKeyValuePair<...>>) — 3 for 3 exact matches.
const IID_ITypedEventHandler = GUID{
    .data1 = 0x90EB4ECA, .data2 = 0xD465, .data3 = 0x5EA0,
    .data4 = .{ 0xA6, 0x1C, 0x03, 0x3C, 0x8C, 0x5E, 0xCE, 0xF2 },
};

// --- COM interface vtable types ---

const HSTRING = ?*const u16;

const IActivationFactory_VTable = extern struct {
    // IUnknown (slots 0-2)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    // IInspectable (slots 3-5)
    GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
    GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
    // IActivationFactory (slot 6)
    ActivateInstance: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
};

fn createWatcher(factory: *anyopaque, iid: *const GUID) !*anyopaque {
    const vt = vtable(factory, IActivationFactory_VTable);
    var inspectable: ?*anyopaque = null;
    const hr = vt.ActivateInstance(factory, @ptrCast(&inspectable));
    if (hr != 0) return error.ActivateInstanceFailed;
    const insp = inspectable orelse return error.ActivateInstanceFailed;
    defer vRelease(insp);

    var watcher: ?*anyopaque = null;
    const hr2 = vQI(insp, iid, &watcher);
    if (hr2 != 0) return error.QueryInterfaceFailed;
    return watcher orelse error.QueryInterfaceFailed;
}

// IBluetoothLEAdvertisementWatcher — vtable order 6+ verified against
// Windows.Devices.winmd (NOT declaration order from any header/sample).
const IBluetoothLEAdvertisementWatcher = extern struct {
    // IUnknown (0-2)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    // IInspectable (3-5)
    GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
    GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
    // IBluetoothLEAdvertisementWatcher (6+)
    get_MinSamplingInterval: *const fn (*anyopaque, *i64) callconv(.c) i32, // 6 (TimeSpan, unused)
    get_MaxSamplingInterval: *const fn (*anyopaque, *i64) callconv(.c) i32, // 7 (unused)
    get_MinOutOfRangeTimeout: *const fn (*anyopaque, *i64) callconv(.c) i32, // 8 (unused)
    get_MaxOutOfRangeTimeout: *const fn (*anyopaque, *i64) callconv(.c) i32, // 9 (unused)
    get_Status: *const fn (*anyopaque, *i32) callconv(.c) i32, // 10 (unused)
    get_ScanningMode: *const fn (*anyopaque, *i32) callconv(.c) i32, // 11 (unused)
    put_ScanningMode: *const fn (*anyopaque, i32) callconv(.c) i32, // 12
    get_SignalStrengthFilter: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32, // 13 (unused)
    put_SignalStrengthFilter: *const fn (*anyopaque, *anyopaque) callconv(.c) i32, // 14 (unused)
    get_AdvertisementFilter: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32, // 15 (unused)
    put_AdvertisementFilter: *const fn (*anyopaque, *anyopaque) callconv(.c) i32, // 16 (unused)
    Start: *const fn (*anyopaque) callconv(.c) i32, // 17
    Stop: *const fn (*anyopaque) callconv(.c) i32, // 18
    add_Received: *const fn (*anyopaque, *anyopaque, *u64) callconv(.c) i32, // 19
    remove_Received: *const fn (*anyopaque, u64) callconv(.c) i32, // 20
};

const IBluetoothLEAdvertisementReceivedEventArgs = extern struct {
    // IUnknown (0-2)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    // IInspectable (3-5)
    GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
    GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
    // IBluetoothLEAdvertisementReceivedEventArgs (6+)
    get_RawSignalStrengthInDBm: *const fn (*anyopaque, *i16) callconv(.c) i32, // 6
    get_BluetoothAddress: *const fn (*anyopaque, *u64) callconv(.c) i32, // 7
    get_AdvertisementType: *const fn (*anyopaque, *i32) callconv(.c) i32, // 8
    get_Timestamp: *const fn (*anyopaque, *i64) callconv(.c) i32, // 9 (DateTimeOffset, unused)
    get_Advertisement: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32, // 10
};

// IBluetoothLEAdvertisementReceivedEventArgs2 — extension interface, only
// reachable via QueryInterface on the base event args object.
const IBluetoothLEAdvertisementReceivedEventArgs2 = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
    GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
    get_BluetoothAddressType: *const fn (*anyopaque, *i32) callconv(.c) i32, // 6
};

const IBluetoothLEAdvertisement = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
    GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
    // IBluetoothLEAdvertisement (6+)
    get_Flags: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32, // 6 (IReference<Byte>, unused)
    put_Flags: *const fn (*anyopaque, *anyopaque) callconv(.c) i32, // 7 (unused)
    get_LocalName: *const fn (*anyopaque, *HSTRING) callconv(.c) i32, // 8
    put_LocalName: *const fn (*anyopaque, HSTRING) callconv(.c) i32, // 9 (unused)
    get_ServiceUuids: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32, // 10 (unused)
    get_ManufacturerData: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32, // 11 (unused)
    get_DataSections: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32, // 12 (IVector<BluetoothLEAdvertisementDataSection>)
};

const IBluetoothLEAdvertisementDataSection = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
    GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
    get_DataType: *const fn (*anyopaque, *u8) callconv(.c) i32, // 6
    put_DataType: *const fn (*anyopaque, u8) callconv(.c) i32, // 7 (unused)
    get_Data: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32, // 8 (IBuffer)
};

// IVector<T>/IVectorView<T> share GetAt (0) / get_Size (1) at the front of
// their vtables, which is all we need — we don't know or care which of
// the two DataSections actually returns.
const IVectorView_DataSection = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
    GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
    GetAt: *const fn (*anyopaque, u32, *?*anyopaque) callconv(.c) i32, // 6
    get_Size: *const fn (*anyopaque, *u32) callconv(.c) i32, // 7
};

// Windows.Storage.Streams.IBuffer
const IBuffer = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
    GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
    get_Capacity: *const fn (*anyopaque, *u32) callconv(.c) i32, // 6 (unused)
    get_Length: *const fn (*anyopaque, *u32) callconv(.c) i32, // 7
};

// Windows::Storage::Streams::IBufferByteAccess — plain COM (no
// IInspectable): QueryInterface an IBuffer for this to get a raw pointer.
const IBufferByteAccess = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    Buffer: *const fn (*anyopaque, *?[*]u8) callconv(.c) i32, // 3
};

// --- Win32/COM API — dynamically resolved (no .lib needed) ---

const comapi = struct {
    var combase: ?*anyopaque = null;
    var ole32: ?*anyopaque = null;

    var pRoGetActivationFactory: ?*const fn (HSTRING, *const GUID, *?*anyopaque) callconv(.c) i32 = null;
    var pWindowsCreateString: ?*const fn ([*]const u16, u32, *HSTRING) callconv(.c) i32 = null;
    var pWindowsDeleteString: ?*const fn (HSTRING) callconv(.c) i32 = null;
    var pWindowsGetStringRawBuffer: ?*const fn (HSTRING, *u32) callconv(.c) ?[*]const u16 = null;
    var pCoInitializeEx: ?*const fn (?*anyopaque, u32) callconv(.c) i32 = null;

    fn ensureLoaded() bool {
        if (pRoGetActivationFactory != null) return true;
        const k32 = struct {
            extern "kernel32" fn LoadLibraryA([*:0]const u8) callconv(.c) ?*anyopaque;
            extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque;
        };
        combase = k32.LoadLibraryA("combase.dll");
        ole32 = k32.LoadLibraryA("ole32.dll");
        if (combase == null or ole32 == null) return false;
        pRoGetActivationFactory = @ptrCast(k32.GetProcAddress(combase, "RoGetActivationFactory"));
        pWindowsCreateString = @ptrCast(k32.GetProcAddress(combase, "WindowsCreateString"));
        pWindowsDeleteString = @ptrCast(k32.GetProcAddress(combase, "WindowsDeleteString"));
        pWindowsGetStringRawBuffer = @ptrCast(k32.GetProcAddress(combase, "WindowsGetStringRawBuffer"));
        pCoInitializeEx = @ptrCast(k32.GetProcAddress(ole32, "CoInitializeEx"));
        return pRoGetActivationFactory != null and pWindowsCreateString != null;
    }

    fn RoGetActivationFactory(name: HSTRING, iid: *const GUID, factory: *?*anyopaque) callconv(.c) i32 {
        if (pRoGetActivationFactory) |f| return f(name, iid, factory);
        return E_NOINTERFACE;
    }
    fn WindowsCreateString(str: [*]const u16, len: u32, out: *HSTRING) callconv(.c) i32 {
        if (pWindowsCreateString) |f| return f(str, len, out);
        return -2147024894; // E_NOTIMPL
    }
    fn WindowsDeleteString(h: HSTRING) callconv(.c) i32 {
        if (pWindowsDeleteString) |f| return f(h);
        return 0;
    }
    fn WindowsGetStringRawBuffer(h: HSTRING, len: *u32) callconv(.c) ?[*]const u16 {
        if (pWindowsGetStringRawBuffer) |f| return f(h, len);
        return null;
    }
    fn CoInitializeEx(reserved: ?*anyopaque, co_init: u32) callconv(.c) i32 {
        if (pCoInitializeEx) |f| return f(reserved, co_init);
        return E_NOINTERFACE;
    }

    const COINIT_MULTITHREADED: u32 = 0x0;
};
