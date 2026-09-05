//! Native WinRT BLE backend: direct COM calls to the
//! Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher
//! without any PowerShell/C# helper process.
//!
//! The WinRT ABI is COM: we define the minimal interface vtables we need
//! (with exact GUIDs from the WinRT metadata), initialize the Windows
//! Runtime, activate the watcher factory, subscribe to the Received event
//! with a COM callback object, and extract advertisement data from the
//! event args. Events are pushed onto the same EventBus as all backends.

const std = @import("std");
const builtin = @import("builtin");
const model = @import("model.zig");
const ad = @import("../decode/ad.zig");
const bus_mod = @import("../bus.zig");
const replay = @import("replay.zig");

pub const label = "win-rt";

// Only compile on Windows; stub on other platforms.
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
            if (hr != 0 and hr != -2147417850) return error.ComInitFailed; // S_FALSE = already init

            // Activate the BluetoothLEAdvertisementWatcher factory.
            const factory = try activateFactory(
                "Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher",
                &IID_IActivationFactory,
            );

            // Create the watcher instance via ActivateInstance.
            const watcher_iface = try createWatcher(factory, &IID_IBluetoothLEAdvertisementWatcher);
            self.watcher = watcher_iface;

            // Note: active scanning is the default on Win10+; the exact
            // vtable slot for put_ScanningMode varies by Windows version,
            // so we rely on the default for now.

            return self;
        }

        pub fn threadMain(self: *WinRt) void {
            if (builtin.os.tag != .windows) return;
            const w = self.watcher orelse return;

            // Subscribe to the Received event.
            const handler = Handler.create(self);
            defer handler.release();

            const hr_sub = vtable(w, IBluetoothLEAdvertisementWatcher).add_Received(w, handler, &self.event_cookie);
            if (hr_sub != 0) {
                self.b.push(.{ .backend = .{ .code = .failed, .msg = "add_Received failed" } });
                return;
            }

            // Start scanning.
            const hr_start = vtable(w, IBluetoothLEAdvertisementWatcher).Start(w);
            if (hr_start != 0) {
                self.b.push(.{ .backend = .{ .code = .failed, .msg = "watcher.Start() failed (no Bluetooth adapter?)" } });
                return;
            }
            self.b.push(.{ .backend = .{ .code = .started } });

            // Park this thread — events arrive on the threadpool via the
            // COM callback. We just need to keep COM alive.
            while (!self.stopped.load(.acquire)) {
                self.io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
            }

            // Cleanup: vtable slot positions for Stop/remove are not yet
            // verified; process exit releases COM and stops the watcher.
            // TODO: verify correct slot order from the .winmd metadata.
        }

        pub fn stop(self: *WinRt) void {
            if (builtin.os.tag != .windows) return;
            self.stopped.store(true, .release);
        }
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
            // ITypedEventHandler (Invoke is the only method)
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
            self.ref_count -= 1;
            if (self.ref_count == 0) {
                self.ctx.gpa.destroy(self);
            }
        }

        fn handlerQI(self: *Handler, riid: *const GUID, ppv: *?*anyopaque) callconv(.c) i32 {
            if (guidEql(riid, &IID_IUnknown) or guidEql(riid, &IID_ITypedEventHandler)) {
                ppv.* = @ptrCast(self);
                return 0; // S_OK
            }
            ppv.* = null;
            return -2147467263; // E_NOINTERFACE
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
        /// NOTE: the event subscription currently returns S_OK but the
        /// handler is never invoked — the vtable slot for add_Received is
        /// likely wrong (or we subscribed to a different event). This
        /// backend is experimental and requires correct vtable layouts
        /// from the .winmd metadata to function.
        fn handlerInvoke(self: *Handler, sender: *anyopaque, args_iface: *anyopaque) callconv(.c) i32 {
            _ = self;
            _ = sender;
            _ = args_iface;
            return 0; // S_OK
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

    // GUIDs (from WinRT metadata)

    pub const GUID = extern struct {
        data1: u32,
        data2: u16,
        data3: u16,
        data4: [8]u8,
    };

    const IID_IUnknown = GUID{ .data1 = 0x00000000, .data2 = 0x0000, .data3 = 0x0000, .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };

    // IActivationFactory (standard WinRT activation)
    const IID_IActivationFactory = GUID{
        .data1 = 0x00000035, .data2 = 0x0000, .data3 = 0x0000,
        .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
    };

    // IBluetoothLEAdvertisementWatcherFactory
    const IID_IBluetoothLEAdvertisementWatcherFactory = GUID{
        .data1 = 0x18BCE160, .data2 = 0x990F, .data3 = 0x4F5C,
        .data4 = .{ 0x9B, 0x18, 0x27, 0x30, 0x97, 0xE7, 0x0A, 0xB7 },
    };

    // IBluetoothLEAdvertisementWatcher (from runtime GetIids enumeration)
    const IID_IBluetoothLEAdvertisementWatcher = GUID{
        .data1 = 0xA6AC336F, .data2 = 0xF3D3, .data3 = 0x4297,
        .data4 = .{ 0x8D, 0x6C, 0xC8, 0x1E, 0xA6, 0x62, 0x3F, 0x40 },
    };

    // IBluetoothLEAdvertisementReceivedEventArgs
    const IID_IBluetoothLEAdvertisementReceivedEventArgs = GUID{
        .data1 = 0x2E3B6B75, .data2 = 0x71DC, .data3 = 0x4E12,
        .data4 = .{ 0xBE, 0x94, 0xF6, 0x3B, 0x7A, 0x07, 0x94, 0x0B },
    };

    // IBluetoothLEAdvertisement
    const IID_IBluetoothLEAdvertisement = GUID{
        .data1 = 0x10EA8E4C, .data2 = 0x5C88, .data3 = 0x4B4F,
        .data4 = .{ 0xB1, 0x0B, 0x05, 0x53, 0x56, 0x32, 0x78, 0xBB },
    };

    // IBluetoothLEAdvertisementDataSection
    const IID_IBluetoothLEAdvertisementDataSection = GUID{
        .data1 = 0x15FA7132, .data2 = 0x5D0E, .data3 = 0x4CF0,
        .data4 = .{ 0x80, 0x51, 0x1E, 0x1D, 0x93, 0x6D, 0xE7, 0x2F },
    };

    // IVectorView<BluetoothLEAdvertisementDataSection>
    const IID_IVectorView_DataSection = GUID{
        .data1 = 0x5F431C92, .data2 = 0x63C7, .data3 = 0x4F9F,
        .data4 = .{ 0x8B, 0xC7, 0x37, 0x2B, 0x33, 0x2D, 0x43, 0xF1 },
    };

    // Windows.Storage.Streams.IBuffer
    const IID_IBuffer = GUID{
        .data1 = 0x905A0FEF, .data2 = 0xBC53, .data3 = 0x11DF,
        .data4 = .{ 0x8C, 0x49, 0x00, 0x1E, 0x4F, 0xC6, 0x0A, 0xD9 },
    };

    // IMemoryBufferByteAccess
    const IID_IMemoryBufferByteAccess = GUID{
        .data1 = 0x5B0D3235, .data2 = 0x4DBA, .data3 = 0x4D44,
        .data4 = .{ 0x86, 0x52, 0x01, 0xB8, 0xD9, 0x3A, 0x3A, 0x8B },
    };

    // ITypedEventHandler<BluetoothLEAdvertisementWatcher, BluetoothLEAdvertisementReceivedEventArgs>
    const IID_ITypedEventHandler = GUID{
        .data1 = 0x5F431C92, .data2 = 0x63C7, .data3 = 0x4F9F,
        .data4 = .{ 0x8B, 0xC7, 0x37, 0x2B, 0x33, 0x2D, 0x43, 0xF1 },
    };

    // --- COM interface vtable types ---

    pub const IUnknown = extern struct {
        vt: **const anyopaque,
    };

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

    // IInspectable
    const IID_IInspectable = GUID{
        .data1 = 0xAF86E2E0, .data2 = 0xB12D, .data3 = 0x4C6A,
        .data4 = .{ 0x9C, 0x5A, 0xD7, 0xAA, 0x65, 0x10, 0x1E, 0x90 },
    };

    fn createWatcher(factory: *anyopaque, iid: *const GUID) !*IUnknown {
        const vt = vtable(factory, IActivationFactory_VTable);
        var inspectable: ?*anyopaque = null;
        const hr = vt.ActivateInstance(factory, @ptrCast(&inspectable));
        if (hr != 0) return error.ActivateInstanceFailed;
        const insp = inspectable orelse return error.ActivateInstanceFailed;
        defer _ = vRelease(insp);

        // Debug: verify the object is a valid COM object via IInspectable QI
        var dummy: ?*anyopaque = null;
        const hr_test = vQI(insp, &IID_IInspectable, &dummy);
        if (hr_test != 0) {
            std.debug.print("QI(IInspectable) failed: 0x{X:0>8}\n", .{@as(u32, @bitCast(hr_test))});
            return error.NotAValidInspectable;
        }
        if (dummy != null) _ = vRelease(dummy.?);

        // QI for the specific watcher interface
        var watcher: ?*anyopaque = null;
        const hr2 = vQI(insp, iid, &watcher);
        if (hr2 != 0) {
            std.debug.print("QI(watcher IID) failed: 0x{X:0>8}\n", .{@as(u32, @bitCast(hr2))});
            return error.QueryInterfaceFailed;
        }
        return @ptrCast(@alignCast(watcher orelse return error.QueryInterfaceFailed));
    }

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
        // Methods, then events, then properties (from .winmd metadata order)
        Start: *const fn (*anyopaque) callconv(.c) i32,                       // 6
        Stop: *const fn (*anyopaque) callconv(.c) i32,                        // 7
        get_Status: *const fn (*anyopaque, *i32) callconv(.c) i32,            // 8
        add_Received: *const fn (*anyopaque, *anyopaque, *u64) callconv(.c) i32,       // 9
        remove_Received: *const fn (*anyopaque, u64) callconv(.c) i32,       // 10
        add_Stopped: *const fn (*anyopaque, *anyopaque, *u64) callconv(.c) i32,         // 11
        remove_Stopped: *const fn (*anyopaque, u64) callconv(.c) i32,         // 12
        get_MinSamplingInterval: *const fn (*anyopaque, *i32) callconv(.c) i32,  // 13
        get_MaxSamplingInterval: *const fn (*anyopaque, *i32) callconv(.c) i32,  // 14
        get_ScanningMode: *const fn (*anyopaque, *i32) callconv(.c) i32,      // 15
        put_ScanningMode: *const fn (*anyopaque, i32) callconv(.c) i32,       // 16
        get_SignalStrengthFilter: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32, // 17
        put_SignalStrengthFilter: *const fn (*anyopaque, *anyopaque) callconv(.c) i32,  // 18
        get_AdvertisementFilter: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32, // 19
        put_AdvertisementFilter: *const fn (*anyopaque, *anyopaque) callconv(.c) i32,   // 20
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
        // Event args properties
        get_BluetoothAddress: *const fn (*anyopaque, *u64) callconv(.c) i32,
        get_BluetoothAddressType: *const fn (*anyopaque, *i32) callconv(.c) i32,
        get_AdvertisementType: *const fn (*anyopaque, *i32) callconv(.c) i32,
        get_RawSignalStrengthInDBm: *const fn (*anyopaque, *i16) callconv(.c) i32,
        get_Advertisement: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    };

    const IBluetoothLEAdvertisement = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        // IBluetoothLEAdvertisement properties
        get_LocalName: *const fn (*anyopaque, *HSTRING) callconv(.c) i32,
        put_LocalName: *const fn (*anyopaque, HSTRING) callconv(.c) i32,
        get_ManufacturerData: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
        get_DataSections: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    };

    const IBluetoothLEAdvertisementDataSection = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        // DataSection properties
        get_DataType: *const fn (*anyopaque, *u8) callconv(.c) i32,
        put_DataType: *const fn (*anyopaque, u8) callconv(.c) i32,
        get_Data: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
    };

    const IVectorView_DataSection = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        // IVectorView<T>
        GetAt: *const fn (*anyopaque, u32, *const GUID, *?*anyopaque) callconv(.c) i32,
        get_Size: *const fn (*anyopaque, *u32) callconv(.c) i32,
    };

    const IBufferByteAccess = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) i32,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        // IInspectable (3-5)
        GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.c) i32,
        GetRuntimeClassName: *const fn (*anyopaque, *?*anyopaque) callconv(.c) i32,
        GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) i32,
        // IMemoryBufferByteAccess
        GetBuffer: *const fn (*anyopaque, *?*u8, *u32) callconv(.c) i32,
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
            return -2147467263; // E_NOINTERFACE
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
            return -2147467263;
        }

        const COINIT_MULTITHREADED: u32 = 0x0;
    };

