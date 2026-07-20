const std = @import("std");
const Allocator = std.mem.Allocator;
const world_mod = @import("world.zig");
const cmd_mod = @import("command_buffer.zig");
const query_mod = @import("query.zig");

const Io = std.Io;

/// A persistent worker pool for data-parallel `for` loops over a fixed index
/// range.
///
/// Worker threads are spawned once at `init` and parked on a condition
/// variable between dispatches — `dispatch` only wakes them, it never spawns
/// threads. `std` 0.16 moved the blocking sync primitives behind the
/// `std.Io` interface, so the pool takes an `Io` at init (e.g. from
/// `std.Io.Threaded`) and uses its futex for parking.
///
/// The pool must not be moved after `init` (workers hold a pointer to it).
/// The owner always participates in draining, so work completes even if some
/// or all worker spawns failed.
pub const ThreadPool = struct {
    const RunFn = *const fn (*anyopaque, usize) void;

    io: Io,
    allocator: Allocator,
    /// Backing storage for helper threads; only `threads[0..spawned]` are live.
    threads: []std.Thread,
    spawned: usize,
    mutex: Io.Mutex,
    work_cond: Io.Condition,
    done_cond: Io.Condition,
    /// Bumped once per dispatch so parked workers can tell a new job from a
    /// spurious wakeup. Guarded by `mutex`, like all fields below except
    /// `cursor` (which workers drain lock-free).
    epoch: u64,
    run_fn: RunFn,
    ctx: *anyopaque,
    total: usize,
    cursor: std.atomic.Value(usize),
    /// Helper threads still draining the current job.
    pending: usize,
    stop: bool,

    /// Initialize the pool and spawn its workers. `thread_count` of 0 uses
    /// the detected CPU count. Worker spawning is best effort: on failure the
    /// pool simply runs with fewer helpers.
    pub fn init(self: *ThreadPool, allocator: Allocator, io: Io, thread_count: usize) !void {
        const n = if (thread_count != 0) thread_count else (std.Thread.getCpuCount() catch 1);
        const helpers = if (n > 0) n - 1 else 0;
        self.* = .{
            .io = io,
            .allocator = allocator,
            .threads = try allocator.alloc(std.Thread, helpers),
            .spawned = 0,
            .mutex = .init,
            .work_cond = .init,
            .done_cond = .init,
            .epoch = 0,
            .run_fn = undefined,
            .ctx = undefined,
            .total = 0,
            .cursor = std.atomic.Value(usize).init(0),
            .pending = 0,
            .stop = false,
        };
        for (self.threads) |*t| {
            t.* = std.Thread.spawn(.{}, workerMain, .{self}) catch break;
            self.spawned += 1;
        }
    }

    pub fn deinit(self: *ThreadPool) void {
        const io = self.io;
        if (self.spawned > 0) {
            self.mutex.lockUncancelable(io);
            self.stop = true;
            self.work_cond.broadcast(io);
            self.mutex.unlock(io);
            for (self.threads[0..self.spawned]) |t| t.join();
        }
        self.allocator.free(self.threads);
        self.* = undefined;
    }

    /// Total number of logical workers (helper threads + the calling thread).
    pub fn workerCount(self: *const ThreadPool) usize {
        return self.spawned + 1;
    }

    fn drain(run_fn: RunFn, ctx: *anyopaque, total: usize, cursor: *std.atomic.Value(usize)) void {
        while (true) {
            const i = cursor.fetchAdd(1, .monotonic);
            if (i >= total) break;
            run_fn(ctx, i);
        }
    }

    fn workerMain(self: *ThreadPool) void {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        var seen: u64 = 0;
        while (true) {
            while (!self.stop and self.epoch == seen) {
                self.work_cond.waitUncancelable(io, &self.mutex);
            }
            if (self.stop) break;
            seen = self.epoch;
            const run_fn = self.run_fn;
            const ctx = self.ctx;
            const total = self.total;
            self.mutex.unlock(io);

            drain(run_fn, ctx, total, &self.cursor);

            self.mutex.lockUncancelable(io);
            self.pending -= 1;
            if (self.pending == 0) self.done_cond.signal(io);
        }
        self.mutex.unlock(io);
    }

    /// Run `run_fn(ctx, i)` for every `i` in `[0, total)`, distributing indices
    /// across the pool. Blocks until all indices have been processed. Must only
    /// be called from the owning thread; dispatches never overlap.
    pub fn dispatch(self: *ThreadPool, run_fn: RunFn, ctx: *anyopaque, total: usize) void {
        if (total == 0) return;
        const io = self.io;

        if (self.spawned > 0) {
            self.mutex.lockUncancelable(io);
            self.run_fn = run_fn;
            self.ctx = ctx;
            self.total = total;
            self.cursor.store(0, .monotonic);
            self.pending = self.spawned;
            self.epoch += 1;
            self.work_cond.broadcast(io);
            self.mutex.unlock(io);
        } else {
            self.cursor.store(0, .monotonic);
        }

        drain(run_fn, ctx, total, &self.cursor); // owner participates

        if (self.spawned > 0) {
            // Wait for helpers still mid-item; afterwards every worker is
            // parked again and the job state may be reused.
            self.mutex.lockUncancelable(io);
            while (self.pending != 0) self.done_cond.waitUncancelable(io, &self.mutex);
            self.mutex.unlock(io);
        }
    }
};

/// Returns a Parallel dispatch type specialized for the given Registry.
pub fn Parallel(comptime Reg: type) type {
    return struct {
        const Self = @This();

        pub const ParWorldType = world_mod.World(Reg);
        pub const ParCmdBufType = cmd_mod.CommandBuffer(Reg);
        pub const SystemFn = *const fn (*ParWorldType, *ParCmdBufType) anyerror!void;

        /// Execute a list of systems sequentially.
        pub fn dispatch(
            systems: []const SystemFn,
            world: *ParWorldType,
            cmd: *ParCmdBufType,
        ) !void {
            for (systems) |sys| {
                try sys(world, cmd);
            }
        }

        /// Run `body(context, view)` over every chunk matching `spec`, spread
        /// across `pool`'s threads. Each chunk is disjoint memory, so writes
        /// within a `View` are data-race free. `context` is copied into every
        /// task — if it is a pointer to shared state, the body is responsible
        /// for its own synchronization.
        pub fn forEachChunk(
            pool: *ThreadPool,
            world: *ParWorldType,
            comptime spec: query_mod.QuerySpec,
            context: anytype,
            comptime body: anytype,
        ) !void {
            const Iter = query_mod.QueryIterator(Reg, spec);
            const View = Iter.View;
            const Ctx = @TypeOf(context);

            // Snapshot the matching chunks so worker threads index a stable list.
            var views = std.ArrayListUnmanaged(View).empty;
            defer views.deinit(world.allocator);
            var it = world.query(spec);
            while (it.next()) |v| try views.append(world.allocator, v);
            if (views.items.len == 0) return;

            const Job = struct {
                views: []const View,
                ctx: Ctx,
                fn run(p: *anyopaque, i: usize) void {
                    const job: *const @This() = @ptrCast(@alignCast(p));
                    body(job.ctx, job.views[i]);
                }
            };
            var job = Job{ .views = views.items, .ctx = context };
            pool.dispatch(Job.run, &job, views.items.len);
        }
    };
}

const TestPos = struct { x: f32, y: f32 };

const TestReg = struct {
    pub const component_count = 1;
    pub const ComponentMask = std.bit_set.IntegerBitSet(1);
    pub const component_sizes: [1]usize = .{@sizeOf(TestPos)};
    pub const component_aligns: [1]usize = .{@alignOf(TestPos)};

    pub fn id(comptime T: type) comptime_int {
        if (T == TestPos) return 0;
        @compileError("unknown type");
    }
};

const WorldType = world_mod.World(TestReg);
const CmdBufType = cmd_mod.CommandBuffer(TestReg);

fn incSystem(world: *WorldType, _: *CmdBufType) !void {
    var iter = world.query(.{ .write = &.{TestPos} });
    while (iter.next()) |view| {
        for (view.write(TestPos)) |*pos| {
            pos.x += 1;
        }
    }
}

test "Parallel dispatch (sequential)" {
    var world = WorldType.init(std.testing.allocator);
    defer world.deinit();

    var cmd = CmdBufType.init(&world);
    defer cmd.deinit();

    const e = try world.spawn();
    try world.addComponent(e, TestPos, .{ .x = 0, .y = 0 });

    const systems: []const @TypeOf(&incSystem) = &.{ incSystem, incSystem };
    try Parallel(TestReg).dispatch(systems, &world, &cmd);

    try std.testing.expectApproxEqAbs(2.0, world.getComponent(e, TestPos).?.x, 0.001);
}

test "ThreadPool dispatch covers every index" {
    const allocator = std.testing.allocator;
    const N = 10_000;
    const counts = try allocator.alloc(std.atomic.Value(u32), N);
    defer allocator.free(counts);
    for (counts) |*c| c.* = std.atomic.Value(u32).init(0);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var pool: ThreadPool = undefined;
    try pool.init(allocator, threaded.io(), 4);
    defer pool.deinit();

    const Job = struct {
        counts: []std.atomic.Value(u32),
        fn run(p: *anyopaque, i: usize) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            _ = self.counts[i].fetchAdd(1, .monotonic);
        }
    };
    var job = Job{ .counts = counts };

    // Dispatch twice to exercise pool reuse.
    pool.dispatch(Job.run, &job, N);
    pool.dispatch(Job.run, &job, N);

    for (counts) |*c| {
        try std.testing.expectEqual(@as(u32, 2), c.load(.monotonic));
    }
}

test "Parallel forEachChunk processes all entities" {
    const allocator = std.testing.allocator;
    var world = WorldType.init(allocator);
    defer world.deinit();

    const N = 5000;
    for (0..N) |i| {
        const fx: f32 = @floatFromInt(i);
        _ = try world.spawnWith(.{TestPos{ .x = fx, .y = 0 }});
    }

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var pool: ThreadPool = undefined;
    try pool.init(allocator, threaded.io(), 4);
    defer pool.deinit();

    try Parallel(TestReg).forEachChunk(&pool, &world, .{ .write = &.{TestPos} }, {}, struct {
        fn body(_: void, view: anytype) void {
            for (view.write(TestPos)) |*p| p.x += 1.0;
        }
    }.body);

    var sum: f64 = 0;
    var iter = world.query(.{ .read = &.{TestPos} });
    while (iter.each()) |row| sum += row.read(TestPos).x;

    // Original sum 0+1+..+(N-1), plus +1 per entity.
    const expected = @as(f64, @floatFromInt(N)) * @as(f64, @floatFromInt(N - 1)) / 2.0 + @as(f64, @floatFromInt(N));
    try std.testing.expectApproxEqAbs(expected, sum, 2.0);
}
