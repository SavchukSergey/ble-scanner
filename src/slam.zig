//! Range-only SLAM: builds a 2D map of (mostly static) BLE devices from
//! distance estimates gathered while walking around, with no odometry.
//!
//! Pipeline (per docs/rssi-2d-mapping-summary.md):
//!   - observer nodes (one per time step) + device nodes in one graph;
//!     range springs observer↔device, soft motion springs between
//!     consecutive observer nodes
//!   - first solve: classical MDS over the shortest-path distance matrix
//!     (closed-form, no local minima) for initialization
//!   - every update: SMACOF (stress majorization) iterations, Jacobi
//!     update order, confidence- and robustness-weighted springs,
//!     warm-started from the previous solution
//!   - the first observer node is pinned to anchor the frame
//!
//! The solution is correct only up to rotation, translation and mirror —
//! there is no absolute reference without odometry.

const std = @import("std");

pub const NodeKind = enum { observer, device };

pub const Node = struct {
    x: f32 = 0,
    y: f32 = 0,
    kind: NodeKind,
    key: u64 = 0, // store key (devices)
    pinned: bool = false,
};

const Edge = struct {
    a: u16,
    b: u16,
    target: f32, // desired distance in meters
    weight: f32,
    range_edge: bool, // false = soft motion spring
};

pub const max_observer_nodes = 40;
const max_device_nodes = 60;
const motion_target_m = 1.4; // half of a plausible 4 s walking distance
const motion_weight = 0.25;

pub const Slam = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    initialized: bool = false,
    rng: u32 = 0x9E3779B9,
    last_count: std.AutoHashMap(u64, u32),

    pub fn init(gpa: std.mem.Allocator) Slam {
        return .{ .gpa = gpa, .last_count = std.AutoHashMap(u64, u32).init(gpa) };
    }

    pub fn deinit(self: *Slam) void {
        self.nodes.deinit(self.gpa);
        self.edges.deinit(self.gpa);
        self.last_count.deinit();
    }

    pub fn reset(self: *Slam) void {
        self.nodes.clearRetainingCapacity();
        self.edges.clearRetainingCapacity();
        self.last_count.clearRetainingCapacity();
        self.initialized = false;
    }

    fn rand01(self: *Slam) f32 {
        // xorshift32 → [0,1)
        var x = self.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.rng = x;
        return @as(f32, @floatFromInt(x & 0xFFFFFF)) / 16777216.0;
    }

    fn observerCount(self: *const Slam) usize {
        var n: usize = 0;
        for (self.nodes.items) |nd| {
            if (nd.kind == .observer) n += 1;
        }
        return n;
    }

    fn deviceNodeIndex(self: *const Slam, key: u64) ?u16 {
        for (self.nodes.items, 0..) |nd, i| {
            if (nd.kind == .device and nd.key == key) return @intCast(i);
        }
        return null;
    }

    fn lastObserver(self: *const Slam) ?u16 {
        var last: ?u16 = null;
        for (self.nodes.items, 0..) |nd, i| {
            if (nd.kind == .observer) last = @intCast(i);
        }
        return last;
    }

    fn deviceCount(self: *const Slam) usize {
        return self.nodes.items.len - self.observerCount();
    }

    /// Begin a new observer step: adds an observer node linked to the
    /// previous one with a soft motion spring. The very first observer
    /// node is pinned and anchors the frame.
    pub fn beginStep(self: *Slam) void {
        // Prune the oldest non-pinned observer when over the cap.
        if (self.observerCount() >= max_observer_nodes) {
            for (self.nodes.items, 0..) |nd, i| {
                if (nd.kind == .observer and !nd.pinned) {
                    self.removeNode(@intCast(i));
                    break;
                }
            }
        }

        const prev = self.lastObserver();
        const idx: u16 = @intCast(self.nodes.items.len);
        var x: f32 = 0;
        var y: f32 = 0;
        if (prev) |pi| {
            const p = self.nodes.items[pi];
            const a = self.rand01() * 2.0 * std.math.pi;
            x = p.x + @cos(a) * motion_target_m;
            y = p.y + @sin(a) * motion_target_m;
        }
        self.nodes.append(self.gpa, .{
            .kind = .observer,
            .x = x,
            .y = y,
            .pinned = prev == null,
        }) catch return;
        if (prev) |pi| {
            self.edges.append(self.gpa, .{
                .a = pi,
                .b = idx,
                .target = motion_target_m,
                .weight = motion_weight,
                .range_edge = false,
            }) catch {};
        }
    }

    /// Feed one distance observation (meters) for a device during the
    /// current observer step; `events_total` is the device's cumulative
    /// advertisement count (confidence via delta).
    pub fn observe(self: *Slam, key: u64, dist_m: f32, events_total: u32) void {
        if (self.deviceCount() >= max_device_nodes) {
            if (self.deviceNodeIndex(key) == null) return;
        }
        const cur = self.lastObserver() orelse return;

        const di: u16 = self.deviceNodeIndex(key) orelse blk: {
            const idx: u16 = @intCast(self.nodes.items.len);
            // seed on a ring around the current observer
            const a = self.rand01() * 2.0 * std.math.pi;
            const o = self.nodes.items[cur];
            self.nodes.append(self.gpa, .{
                .kind = .device,
                .key = key,
                .x = o.x + @cos(a) * dist_m,
                .y = o.y + @sin(a) * dist_m,
            }) catch return;
            break :blk idx;
        };

        const prev = self.last_count.get(key) orelse 0;
        const delta: f32 = if (events_total > prev) @floatFromInt(events_total - prev) else 0;
        const conf = @min(1.0, 0.15 + delta / 6.0);
        const w = conf / (1.0 + dist_m / 15.0);

        // Refresh an existing edge for this (observer, device) pair, else add.
        for (self.edges.items) |*e| {
            const touches = (e.a == cur and e.b == di) or (e.b == cur and e.a == di);
            if (touches and e.range_edge) {
                e.target = dist_m;
                e.weight = w;
                self.last_count.put(key, events_total) catch {};
                return;
            }
        }
        self.edges.append(self.gpa, .{
            .a = cur,
            .b = di,
            .target = dist_m,
            .weight = w,
            .range_edge = true,
        }) catch {};
        self.last_count.put(key, events_total) catch {};
    }

    fn removeNode(self: *Slam, idx: u16) void {
        _ = self.nodes.orderedRemove(idx);
        // Drop edges touching idx, shift indices above.
        var i: usize = 0;
        while (i < self.edges.items.len) {
            const e = self.edges.items[i];
            if (e.a == idx or e.b == idx) {
                _ = self.edges.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        for (self.edges.items) |*e| {
            if (e.a > idx) e.a -= 1;
            if (e.b > idx) e.b -= 1;
        }
    }

    /// Run a solve: first time MDS init (when the graph is connected),
    /// then SMACOF iterations.
    pub fn solve(self: *Slam, iterations: u8) void {
        if (self.nodes.items.len < 3) return;
        if (!self.initialized) {
            if (!self.mdsInit()) return; // retry next step
            self.initialized = true;
        }
        self.smacof(iterations);
    }

    /// Test hook: how many observer steps have been taken (via the app's
    /// slam_steps counter this doubles as a liveness check).
    pub fn observerStepCount(self: *const Slam) usize {
        return self.observerCount();
    }

    // --- classical MDS initialization -------------------------------------

    fn mdsInit(self: *Slam) bool {
        const n = self.nodes.items.len;
        if (n < 3 or n > 128) return false;

        const gpa = self.gpa;
        const d = gpa.alloc(f32, n * n) catch return false;
        defer gpa.free(d);
        @memset(d, 1e9);
        for (self.nodes.items, 0..) |_, i| d[i * n + i] = 0;
        for (self.edges.items) |e| {
            d[e.a * n + e.b] = e.target;
            d[e.b * n + e.a] = e.target;
        }
        // Floyd–Warshall shortest paths over the observation graph.
        var k: usize = 0;
        while (k < n) : (k += 1) {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                var j: usize = 0;
                while (j < n) : (j += 1) {
                    const alt = d[i * n + k] + d[k * n + j];
                    if (alt < d[i * n + j]) d[i * n + j] = alt;
                }
            }
        }
        // Connected?
        var i: usize = 1;
        while (i < n) : (i += 1) {
            if (d[i] > 1e8) return false;
        }

        // Double-centered squared-distance matrix B = -1/2 J D^2 J.
        const b = gpa.alloc(f32, n * n) catch return false;
        defer gpa.free(b);
        i = 0;
        while (i < n) : (i += 1) {
            var j: usize = 0;
            while (j < n) : (j += 1) {
                const dij = d[i * n + j];
                b[i * n + j] = -0.5 * dij * dij;
            }
        }
        // Row/column means and grand mean.
        const row_mean = gpa.alloc(f32, n) catch return false;
        defer gpa.free(row_mean);
        var grand: f32 = 0;
        i = 0;
        while (i < n) : (i += 1) {
            var s: f32 = 0;
            var j: usize = 0;
            while (j < n) : (j += 1) s += b[i * n + j];
            row_mean[i] = s / @as(f32, @floatFromInt(n));
            grand += row_mean[i];
        }
        grand /= @floatFromInt(n);
        i = 0;
        while (i < n) : (i += 1) {
            var j: usize = 0;
            while (j < n) : (j += 1) {
                b[i * n + j] += -row_mean[i] - row_mean[j] + grand;
            }
        }

        // Eigendecomposition (cyclic Jacobi), take the top-2 components.
        const evals = gpa.alloc(f32, n) catch return false;
        defer gpa.free(evals);
        const evecs = gpa.alloc(f32, n * n) catch return false;
        defer gpa.free(evecs);
        jacobiEigen(b, n, evals, evecs);

        var ev0: usize = 0;
        var ev1: usize = 1;
        if (evals[1] > evals[0]) {
            ev0 = 1;
            ev1 = 0;
        }
        i = 2;
        while (i < n) : (i += 1) {
            if (evals[i] > evals[ev0]) {
                ev1 = ev0;
                ev0 = i;
            } else if (evals[i] > evals[ev1]) {
                ev1 = i;
            }
        }
        const l1: f32 = if (evals[ev0] > 0) @sqrt(evals[ev0]) else 0;
        const l2: f32 = if (evals[ev1] > 0) @sqrt(evals[ev1]) else 0;

        i = 0;
        while (i < n) : (i += 1) {
            self.nodes.items[i].x = evecs[i * n + ev0] * l1;
            self.nodes.items[i].y = evecs[i * n + ev1] * l2;
        }
        self.normalizeFrame();
        return true;
    }

    /// Anchor node 0 at the origin; align the first free node with +x.
    fn normalizeFrame(self: *Slam) void {
        if (self.nodes.items.len < 2) return;
        const o = self.nodes.items[0];
        for (self.nodes.items) |*nd| {
            nd.x -= o.x;
            nd.y -= o.y;
        }
        const ref = self.nodes.items[1];
        const r = @sqrt(ref.x * ref.x + ref.y * ref.y);
        if (r < 1e-4) return;
        const c = ref.x / r;
        const s = ref.y / r;
        for (self.nodes.items) |*nd| {
            const x = nd.x;
            const y = nd.y;
            nd.x = x * c + y * s;
            nd.y = -x * s + y * c;
        }
    }

    // --- SMACOF refinement --------------------------------------------------

    fn smacof(self: *Slam, iterations: u8) void {
        const n = self.nodes.items.len;
        const gpa = self.gpa;
        const sx = gpa.alloc(f32, n) catch return;
        defer gpa.free(sx);
        const sy = gpa.alloc(f32, n) catch return;
        defer gpa.free(sy);
        const sw = gpa.alloc(f32, n) catch return;
        defer gpa.free(sw);

        var it: u8 = 0;
        while (it < iterations) : (it += 1) {
            @memset(sx, 0);
            @memset(sy, 0);
            @memset(sw, 0);

            for (self.edges.items) |e| {
                const na = self.nodes.items[e.a];
                const nb = self.nodes.items[e.b];
                var dx = na.x - nb.x;
                var dy = na.y - nb.y;
                const cur = @sqrt(dx * dx + dy * dy);
                if (cur < 1e-4) {
                    const a = self.rand01() * 2.0 * std.math.pi;
                    dx = @cos(a);
                    dy = @sin(a);
                } else {
                    dx /= cur;
                    dy /= cur;
                }
                // Robustness: downweight springs with large residuals.
                const resid = cur - e.target;
                const sigma = 0.5 + 0.08 * e.target;
                const w = e.weight / (1.0 + resid * resid / (sigma * sigma));

                // Contribution for a from b (and vice versa), Jacobi-style.
                const tx = nb.x + e.target * dx;
                const ty = nb.y + e.target * dy;
                if (!na.pinned) {
                    sx[e.a] += w * tx;
                    sy[e.a] += w * ty;
                    sw[e.a] += w;
                }
                const ux = na.x - e.target * dx;
                const uy = na.y - e.target * dy;
                if (!nb.pinned) {
                    sx[e.b] += w * ux;
                    sy[e.b] += w * uy;
                    sw[e.b] += w;
                }
            }

            for (self.nodes.items, 0..) |*nd, i| {
                if (nd.pinned or sw[i] <= 1e-9) continue;
                nd.x = sx[i] / sw[i];
                nd.y = sy[i] / sw[i];
            }
        }
    }
};

/// Cyclic Jacobi eigendecomposition of a symmetric matrix (row-major,
/// destroyed). `evals[i]` pairs with eigenvector column i of `evecs`
/// (row-major n×n, initialized to identity by this function).
fn jacobiEigen(a: []f32, n: usize, evals: []f32, evecs: []f32) void {
    @memset(evecs, 0);
    for (0..n) |i| evecs[i * n + i] = 1;

    var sweep: usize = 0;
    while (sweep < 40) : (sweep += 1) {
        var off: f32 = 0;
        for (0..n) |p| {
            for (0..p) |q| {
                const v = a[p * n + q];
                off += v * v;
            }
        }
        if (off < 1e-12) break;

        var p: usize = 0;
        while (p < n) : (p += 1) {
            var q: usize = p + 1;
            while (q < n) : (q += 1) {
                const apq = a[p * n + q];
                if (@abs(apq) < 1e-12) continue;
                const app = a[p * n + p];
                const aqq = a[q * n + q];
                const tau = (aqq - app) / (2.0 * apq);
                const t: f32 = if (tau >= 0)
                    1.0 / (tau + @sqrt(1.0 + tau * tau))
                else
                    -1.0 / (-tau + @sqrt(1.0 + tau * tau));
                const c = 1.0 / @sqrt(1.0 + t * t);
                const s = t * c;

                // Rotate rows/columns p and q of A.
                var k: usize = 0;
                while (k < n) : (k += 1) {
                    if (k == p or k == q) continue;
                    const akp = a[k * n + p];
                    const akq = a[k * n + q];
                    a[k * n + p] = c * akp - s * akq;
                    a[p * n + k] = a[k * n + p];
                    a[k * n + q] = s * akp + c * akq;
                    a[q * n + k] = a[k * n + q];
                }
                a[p * n + p] = app - t * apq;
                a[q * n + q] = aqq + t * apq;
                a[p * n + q] = 0;
                a[q * n + p] = 0;

                // Accumulate eigenvectors.
                k = 0;
                while (k < n) : (k += 1) {
                    const vkp = evecs[k * n + p];
                    const vkq = evecs[k * n + q];
                    evecs[k * n + p] = c * vkp - s * vkq;
                    evecs[k * n + q] = s * vkp + c * vkq;
                }
            }
        }
    }
    for (0..n) |i| evals[i] = a[i * n + i];
}

// --- tests --------------------------------------------------------------------

const testing = std.testing;

test "jacobi eigen on known symmetric matrix" {
    // diag(3, 1) rotated by 45°: [[2,1],[1,2]] has eigenvalues 3 and 1.
    var a = [_]f32{ 2, 1, 1, 2 };
    var evals: [2]f32 = undefined;
    var evecs: [4]f32 = undefined;
    jacobiEigen(&a, 2, &evals, &evecs);
    const e0 = @max(evals[0], evals[1]);
    const e1 = @min(evals[0], evals[1]);
    try testing.expectApproxEqAbs(@as(f32, 3), e0, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), e1, 0.001);
}

fn dist(ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const dx = ax - bx;
    const dy = ay - by;
    return @sqrt(dx * dx + dy * dy);
}

test "synthetic L-walk recovers device layout" {
    // True layout (meters).
    const dev = [_][2]f32{ .{ 0, 0 }, .{ 6, 0 }, .{ 0, 4 }, .{ 7, 5 }, .{ 3, 2 } };
    // Observer walks an L: (1,1) -> (5,1) -> (5,4).
    const walk = [_][2]f32{ .{ 1, 1 }, .{ 2, 1 }, .{ 3, 1 }, .{ 4, 1 }, .{ 5, 1 }, .{ 5, 2 }, .{ 5, 3 }, .{ 5, 4 } };

    var rng: u32 = 12345;
    var slam = Slam.init(testing.allocator);
    defer slam.deinit();

    for (walk) |o| {
        slam.beginStep();
        for (dev, 0..) |dv, di| {
            // Noisy range: ±8%.
            var x = rng;
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            rng = x;
            const noise = (@as(f32, @floatFromInt(x & 0xFFFF)) / 32768.0 - 1.0) * 0.08;
            const d_true = dist(o[0], o[1], dv[0], dv[1]);
            const d_meas = d_true * (1.0 + noise);
            slam.observe(@intCast(di + 1), d_meas, 50);
        }
        slam.solve(25);
    }

    // Invariant to rotation/translation/mirror: compare the pairwise
    // device-distance matrix against the truth.
    for (0..dev.len) |i| {
        for (0..i) |j| {
            const ni = slam.deviceNodeIndex(@intCast(i + 1)).?;
            const nj = slam.deviceNodeIndex(@intCast(j + 1)).?;
            const got = dist(
                slam.nodes.items[ni].x,
                slam.nodes.items[ni].y,
                slam.nodes.items[nj].x,
                slam.nodes.items[nj].y,
            );
            const want = dist(dev[i][0], dev[i][1], dev[j][0], dev[j][1]);
            try testing.expectApproxEqAbs(want, got, 0.35 * want + 0.3);
        }
    }
}

test "observer trail grows and prunes" {
    var slam = Slam.init(testing.allocator);
    defer slam.deinit();
    var i: usize = 0;
    while (i < max_observer_nodes + 10) : (i += 1) {
        slam.beginStep();
        slam.observe(1, 3.0, @intCast(i * 3));
        slam.solve(2);
    }
    try testing.expect(slam.observerCount() <= max_observer_nodes);
    try testing.expect(slam.nodes.items.len > 0);
}
