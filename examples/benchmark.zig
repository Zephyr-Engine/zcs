const std = @import("std");
const zcs = @import("zcs");
const Io = std.Io;

// ── Components ─────────────────────────────────────────────────────────

const Position = struct { x: f32, y: f32 };
const Velocity = struct { vx: f32, vy: f32 };
const Health = struct { hp: i32, max_hp: i32 };
const Sprite = struct { id: u32, layer: u8, _pad: [3]u8 = .{ 0, 0, 0 } };
const Transform = struct { m: [4]f32 };
const Tag = struct {};

const Ecs = zcs.Registry(&.{ Position, Velocity, Health, Sprite, Transform, Tag });

// ── Config ─────────────────────────────────────────────────────────────

const Config = struct {
    entity_count: usize = 10_000,
    warmup: usize = 3,
    iters: usize = 10,

    fn parse(init: std.process.Init) Config {
        var cfg = Config{};
        var it = std.process.Args.Iterator.init(init.minimal.args);
        _ = it.skip(); // skip argv[0]
        while (it.next()) |arg| {
            if (parseNamedArg(arg, "--entities=")) |v| {
                cfg.entity_count = v;
            } else if (parseNamedArg(arg, "--warmup=")) |v| {
                cfg.warmup = v;
            } else if (parseNamedArg(arg, "--iters=")) |v| {
                cfg.iters = v;
            }
        }
        return cfg;
    }

    fn parseNamedArg(arg: []const u8, prefix: []const u8) ?usize {
        if (std.mem.startsWith(u8, arg, prefix)) {
            return std.fmt.parseInt(usize, arg[prefix.len..], 10) catch null;
        }
        return null;
    }
};

// ── Benchmark harness ──────────────────────────────────────────────────

const BenchResult = struct {
    name: []const u8,
    total_ns: i96,
    iters: usize,
    entity_count: usize,

    fn perIterUs(self: BenchResult) f64 {
        return @as(f64, @floatFromInt(self.total_ns)) / @as(f64, @floatFromInt(self.iters)) / 1000.0;
    }

    fn perEntityNs(self: BenchResult) f64 {
        return @as(f64, @floatFromInt(self.total_ns)) / @as(f64, @floatFromInt(self.iters)) / @as(f64, @floatFromInt(self.entity_count));
    }

    fn print(self: BenchResult) void {
        std.debug.print("  {s:<30} {d:>10.1} us/iter   {d:>6.1} ns/entity\n", .{
            self.name,
            self.perIterUs(),
            self.perEntityNs(),
        });
    }
};

fn timestamp(io: Io) i96 {
    return Io.Timestamp.now(io, .boot).nanoseconds;
}

// ── Benchmarks ─────────────────────────────────────────────────────────

fn benchSpawn(allocator: std.mem.Allocator, io: Io, cfg: Config) BenchResult {
    var total_ns: i96 = 0;

    for (0..cfg.warmup + cfg.iters) |i| {
        var world = Ecs.World.init(allocator);
        defer world.deinit();

        const start = timestamp(io);
        for (0..cfg.entity_count) |_| {
            _ = world.spawn() catch unreachable;
        }
        const elapsed = timestamp(io) - start;
        if (i >= cfg.warmup) total_ns += elapsed;
    }

    return .{ .name = "spawn (empty)", .total_ns = total_ns, .iters = cfg.iters, .entity_count = cfg.entity_count };
}

fn benchSpawnWithComponents(allocator: std.mem.Allocator, io: Io, cfg: Config) BenchResult {
    var total_ns: i96 = 0;

    for (0..cfg.warmup + cfg.iters) |i| {
        var world = Ecs.World.init(allocator);
        defer world.deinit();

        const start = timestamp(io);
        for (0..cfg.entity_count) |j| {
            const e = world.spawn() catch unreachable;
            const fx: f32 = @floatFromInt(j);
            world.addComponent(e, Position, .{ .x = fx, .y = 0 }) catch unreachable;
            world.addComponent(e, Velocity, .{ .vx = 1, .vy = 0 }) catch unreachable;
        }
        const elapsed = timestamp(io) - start;
        if (i >= cfg.warmup) total_ns += elapsed;
    }

    return .{ .name = "spawn + 2 components", .total_ns = total_ns, .iters = cfg.iters, .entity_count = cfg.entity_count };
}

fn benchDespawn(allocator: std.mem.Allocator, io: Io, cfg: Config) BenchResult {
    var total_ns: i96 = 0;

    for (0..cfg.warmup + cfg.iters) |i| {
        var world = Ecs.World.init(allocator);
        defer world.deinit();

        var ids = std.ArrayListUnmanaged(zcs.EntityID).empty;
        defer ids.deinit(allocator);

        for (0..cfg.entity_count) |j| {
            const e = world.spawn() catch unreachable;
            const fx: f32 = @floatFromInt(j);
            world.addComponent(e, Position, .{ .x = fx, .y = 0 }) catch unreachable;
            world.addComponent(e, Velocity, .{ .vx = 1, .vy = 0 }) catch unreachable;
            ids.append(allocator, e) catch unreachable;
        }

        const start = timestamp(io);
        for (ids.items) |id| {
            world.despawn(id);
        }
        const elapsed = timestamp(io) - start;
        if (i >= cfg.warmup) total_ns += elapsed;
    }

    return .{ .name = "despawn", .total_ns = total_ns, .iters = cfg.iters, .entity_count = cfg.entity_count };
}

fn benchIterate2(allocator: std.mem.Allocator, io: Io, cfg: Config) BenchResult {
    var world = Ecs.World.init(allocator);
    defer world.deinit();

    for (0..cfg.entity_count) |j| {
        const e = world.spawn() catch unreachable;
        const fx: f32 = @floatFromInt(j);
        world.addComponent(e, Position, .{ .x = fx, .y = 0 }) catch unreachable;
        world.addComponent(e, Velocity, .{ .vx = 1, .vy = 0 }) catch unreachable;
    }

    var total_ns: i96 = 0;

    for (0..cfg.warmup + cfg.iters) |i| {
        const start = timestamp(io);
        var iter = world.query(.{ .write = &.{Position}, .read = &.{Velocity} });
        while (iter.next()) |view| {
            const positions = view.write(Position);
            const velocities = view.read(Velocity);
            for (positions, velocities) |*pos, vel| {
                pos.x += vel.vx;
                pos.y += vel.vy;
            }
        }
        const elapsed = timestamp(io) - start;
        if (i >= cfg.warmup) total_ns += elapsed;
    }

    return .{ .name = "iterate (2 components)", .total_ns = total_ns, .iters = cfg.iters, .entity_count = cfg.entity_count };
}

fn benchIterate4(allocator: std.mem.Allocator, io: Io, cfg: Config) BenchResult {
    var world = Ecs.World.init(allocator);
    defer world.deinit();

    for (0..cfg.entity_count) |j| {
        const e = world.spawn() catch unreachable;
        const fx: f32 = @floatFromInt(j);
        world.addComponent(e, Position, .{ .x = fx, .y = 0 }) catch unreachable;
        world.addComponent(e, Velocity, .{ .vx = 1, .vy = 0 }) catch unreachable;
        world.addComponent(e, Health, .{ .hp = 100, .max_hp = 100 }) catch unreachable;
        world.addComponent(e, Transform, .{ .m = .{ 1, 0, 0, 1 } }) catch unreachable;
    }

    var total_ns: i96 = 0;

    for (0..cfg.warmup + cfg.iters) |i| {
        const start = timestamp(io);
        var iter = world.query(.{ .write = &.{ Position, Transform }, .read = &.{ Velocity, Health } });
        while (iter.next()) |view| {
            const positions = view.write(Position);
            const transforms = view.write(Transform);
            const velocities = view.read(Velocity);
            const healths = view.read(Health);
            for (positions, transforms, velocities, healths) |*pos, *xform, vel, hp| {
                pos.x += vel.vx;
                pos.y += vel.vy;
                xform.m[0] = pos.x;
                xform.m[3] = @floatFromInt(hp.hp);
            }
        }
        const elapsed = timestamp(io) - start;
        if (i >= cfg.warmup) total_ns += elapsed;
    }

    return .{ .name = "iterate (4 components)", .total_ns = total_ns, .iters = cfg.iters, .entity_count = cfg.entity_count };
}

fn benchArchetypeMove(allocator: std.mem.Allocator, io: Io, cfg: Config) BenchResult {
    var total_ns: i96 = 0;

    for (0..cfg.warmup + cfg.iters) |i| {
        var world = Ecs.World.init(allocator);
        defer world.deinit();

        var ids = std.ArrayListUnmanaged(zcs.EntityID).empty;
        defer ids.deinit(allocator);

        for (0..cfg.entity_count) |_| {
            const e = world.spawn() catch unreachable;
            world.addComponent(e, Position, .{ .x = 0, .y = 0 }) catch unreachable;
            ids.append(allocator, e) catch unreachable;
        }

        const start = timestamp(io);
        for (ids.items) |id| {
            world.addComponent(id, Velocity, .{ .vx = 1, .vy = 0 }) catch unreachable;
        }
        const elapsed = timestamp(io) - start;
        if (i >= cfg.warmup) total_ns += elapsed;
    }

    return .{ .name = "archetype move (add)", .total_ns = total_ns, .iters = cfg.iters, .entity_count = cfg.entity_count };
}

fn benchCommandBuffer(allocator: std.mem.Allocator, io: Io, cfg: Config) BenchResult {
    var total_ns: i96 = 0;

    for (0..cfg.warmup + cfg.iters) |i| {
        var world = Ecs.World.init(allocator);
        defer world.deinit();

        var cmd_buf = Ecs.CommandBuffer.init(&world);
        defer cmd_buf.deinit();

        const start = timestamp(io);
        for (0..cfg.entity_count) |j| {
            const e = cmd_buf.spawn() catch unreachable;
            const fx: f32 = @floatFromInt(j);
            cmd_buf.addComponent(e, Position, .{ .x = fx, .y = 0 }) catch unreachable;
            cmd_buf.addComponent(e, Velocity, .{ .vx = 1, .vy = 0 }) catch unreachable;
        }
        cmd_buf.flush() catch unreachable;
        const elapsed = timestamp(io) - start;
        if (i >= cfg.warmup) total_ns += elapsed;
    }

    return .{ .name = "command buffer spawn+flush", .total_ns = total_ns, .iters = cfg.iters, .entity_count = cfg.entity_count };
}

fn benchGameFrame(allocator: std.mem.Allocator, io: Io, cfg: Config) BenchResult {
    var world = Ecs.World.init(allocator);
    defer world.deinit();

    var cmd_buf = Ecs.CommandBuffer.init(&world);
    defer cmd_buf.deinit();

    for (0..cfg.entity_count) |j| {
        const e = world.spawn() catch unreachable;
        const fx: f32 = @floatFromInt(j);
        world.addComponent(e, Position, .{ .x = fx, .y = 0 }) catch unreachable;
        world.addComponent(e, Velocity, .{ .vx = 1, .vy = -0.5 }) catch unreachable;
        if (j % 3 == 0) {
            world.addComponent(e, Health, .{ .hp = 100, .max_hp = 100 }) catch unreachable;
        }
        if (j % 5 == 0) {
            world.addComponent(e, Tag, .{}) catch unreachable;
        }
    }

    const moveSys = struct {
        fn run(w: *Ecs.World, _: *Ecs.CommandBuffer) anyerror!void {
            var iter = w.query(.{ .write = &.{Position}, .read = &.{Velocity} });
            while (iter.next()) |view| {
                for (view.write(Position), view.read(Velocity)) |*pos, vel| {
                    pos.x += vel.vx;
                    pos.y += vel.vy;
                }
            }
        }
    }.run;

    var total_ns: i96 = 0;

    for (0..cfg.warmup + cfg.iters) |i| {
        const start = timestamp(io);
        Ecs.Schedule.tick(&world, &cmd_buf, .{
            .update = &.{moveSys},
        }) catch unreachable;
        const elapsed = timestamp(io) - start;
        if (i >= cfg.warmup) total_ns += elapsed;
    }

    return .{ .name = "game frame (schedule tick)", .total_ns = total_ns, .iters = cfg.iters, .entity_count = cfg.entity_count };
}

// ── Main ───────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const cfg = Config.parse(init);
    const allocator = init.gpa;
    const io = init.io;

    std.debug.print("\n  ZCS Benchmark -- {d} entities, {d} iters (warmup {d})\n", .{
        cfg.entity_count,
        cfg.iters,
        cfg.warmup,
    });
    std.debug.print("  ------------------------------------------------------------\n", .{});

    const results: [8]BenchResult = .{
        benchSpawn(allocator, io, cfg),
        benchSpawnWithComponents(allocator, io, cfg),
        benchDespawn(allocator, io, cfg),
        benchIterate2(allocator, io, cfg),
        benchIterate4(allocator, io, cfg),
        benchArchetypeMove(allocator, io, cfg),
        benchCommandBuffer(allocator, io, cfg),
        benchGameFrame(allocator, io, cfg),
    };

    for (&results) |r| r.print();

    std.debug.print("  ------------------------------------------------------------\n\n", .{});
}
