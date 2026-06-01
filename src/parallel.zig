const std = @import("std");
const Allocator = std.mem.Allocator;
const world_mod = @import("world.zig");
const cmd_mod = @import("command_buffer.zig");
const query_mod = @import("query.zig");

/// A worker pool for data-parallel `for` loops over a fixed index range.
///
/// `std` 0.16 dropped `std.Thread.Pool` and moved the blocking sync primitives
/// (Mutex/Condition) behind the `std.Io` interface, so this is a self-contained
/// implementation built on just `std.Thread` + atomics. Each `dispatch` spawns
/// helper threads that, together with the calling thread, drain a shared atomic
/// cursor; completion is detected by `join`. The owner always participates, so
/// the work completes correctly even if thread spawning fails.
///
/// Note: this spawns/joins helper threads per dispatch. That is fine for coarse,
/// heavy systems; a persistent `std.Io`-backed pool would lower the per-dispatch
/// overhead for very fine-grained work (a natural future `zob` integration point).
pub const ThreadPool = struct {
    const RunFn = *const fn (*anyopaque, usize) void;

    const Shared = struct {
        run_fn: RunFn,
        ctx: *anyopaque,
        total: usize,
        cursor: std.atomic.Value(usize),
    };

    /// Scratch storage for helper threads (length = workerCount - 1).
    threads: []std.Thread = &.{},
    allocator: Allocator = undefined,

    /// Initialize the pool. `thread_count` of 0 uses the detected CPU count.
    pub fn init(self: *ThreadPool, allocator: Allocator, thread_count: usize) !void {
        const n = if (thread_count != 0) thread_count else (std.Thread.getCpuCount() catch 1);
        const helpers = if (n > 0) n - 1 else 0;
        self.* = .{
            .threads = try allocator.alloc(std.Thread, helpers),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ThreadPool) void {
        self.allocator.free(self.threads);
        self.threads = &.{};
    }

    /// Total number of logical workers (helper threads + the calling thread).
    pub fn workerCount(self: *const ThreadPool) usize {
        return self.threads.len + 1;
    }

    fn drain(shared: *Shared) void {
        while (true) {
            const i = shared.cursor.fetchAdd(1, .monotonic);
            if (i >= shared.total) break;
            shared.run_fn(shared.ctx, i);
        }
    }

    /// Run `run_fn(ctx, i)` for every `i` in `[0, total)`, distributing indices
    /// across the pool. Blocks until all indices have been processed.
    pub fn dispatch(self: *ThreadPool, run_fn: RunFn, ctx: *anyopaque, total: usize) void {
        if (total == 0) return;

        var shared = Shared{
            .run_fn = run_fn,
            .ctx = ctx,
            .total = total,
            .cursor = std.atomic.Value(usize).init(0),
        };

        // Spawn helper threads (best effort). If a spawn fails, the owner still
        // drains every remaining index, so the result is always complete.
        var spawned: usize = 0;
        for (self.threads) |*t| {
            t.* = std.Thread.spawn(.{}, drain, .{&shared}) catch break;
            spawned += 1;
        }

        drain(&shared); // owner participates

        for (self.threads[0..spawned]) |t| t.join();
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

    var pool: ThreadPool = undefined;
    try pool.init(allocator, 4);
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

    var pool: ThreadPool = undefined;
    try pool.init(allocator, 4);
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
