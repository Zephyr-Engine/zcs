const std = @import("std");
const zcs = @import("zcs");

// ── Component types ────────────────────────────────────────────────────

const Position = struct { x: f32, y: f32 };
const Velocity = struct { vx: f32, vy: f32 };
const Health = struct { hp: i32, max_hp: i32 };
const Gravity = struct { g: f32 };
const Player = struct {}; // ZST tag
const Enemy = struct {}; // ZST tag
const Disabled = struct {}; // ZST tag

const Ecs = zcs.Registry(&.{
    Position,
    Velocity,
    Health,
    Gravity,
    Player,
    Enemy,
    Disabled,
});

// ── Systems ────────────────────────────────────────────────────────────

fn movementSystem(world: *Ecs.World, _: *Ecs.CommandBuffer) !void {
    var iter = world.query(.{ .write = &.{Position}, .read = &.{Velocity} });
    while (iter.next()) |view| {
        const positions = view.write(Position);
        const velocities = view.read(Velocity);
        for (positions, velocities) |*pos, vel| {
            pos.x += vel.vx;
            pos.y += vel.vy;
        }
    }
}

fn gravitySystem(world: *Ecs.World, _: *Ecs.CommandBuffer) !void {
    var iter = world.query(.{ .write = &.{Velocity}, .read = &.{Gravity} });
    while (iter.next()) |view| {
        const velocities = view.write(Velocity);
        const gravities = view.read(Gravity);
        for (velocities, gravities) |*vel, grav| {
            vel.vy += grav.g;
        }
    }
}

fn damageSystem(world: *Ecs.World, cmd: *Ecs.CommandBuffer) !void {
    // Enemies near origin take damage; despawn when dead
    var iter = world.query(.{
        .write = &.{Health},
        .read = &.{Position},
        .with = &.{Enemy},
        .without = &.{Disabled},
    });
    while (iter.each()) |row| {
        const pos = row.read(Position);
        const hp = row.write(Health);
        const dist = @sqrt(pos.x * pos.x + pos.y * pos.y);
        if (dist < 5.0) {
            hp.hp -= 10;
            if (hp.hp <= 0) {
                try cmd.despawn(row.entity());
            }
        }
    }
}

// ── Main ───────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var world = Ecs.World.init(allocator);
    defer world.deinit();

    var cmd = Ecs.CommandBuffer.init(&world);
    defer cmd.deinit();

    // ── Example 1: Spawn entities directly ─────────────────────────

    std.debug.print("=== Example 1: Direct spawn ===\n", .{});

    const player = try world.spawn();
    try world.addComponent(player, Position, .{ .x = 0, .y = 0 });
    try world.addComponent(player, Velocity, .{ .vx = 1, .vy = 0 });
    try world.addComponent(player, Health, .{ .hp = 100, .max_hp = 100 });
    try world.addComponent(player, Player, .{});

    std.debug.print("  Spawned player at (0, 0) with 100 hp\n", .{});

    // ── Example 2: Spawn enemies via CommandBuffer ─────────────────

    std.debug.print("\n=== Example 2: Deferred spawn via CommandBuffer ===\n", .{});

    for (0..5) |i| {
        const e = try cmd.spawn();
        const fx: f32 = @floatFromInt(i);
        try cmd.addComponent(e, Position, .{ .x = fx * 2.0 - 4.0, .y = 0 });
        try cmd.addComponent(e, Velocity, .{ .vx = -0.5, .vy = 0 });
        try cmd.addComponent(e, Health, .{ .hp = 30, .max_hp = 30 });
        try cmd.addComponent(e, Enemy, .{});
    }

    try cmd.flush();
    std.debug.print("  Spawned 5 enemies via command buffer\n", .{});

    // ── Example 3: Query iteration ─────────────────────────────────

    std.debug.print("\n=== Example 3: Query iteration ===\n", .{});

    var count: usize = 0;
    var iter = world.query(.{ .read = &.{ Position, Velocity } });
    while (iter.each()) |row| {
        const pos = row.read(Position);
        const vel = row.read(Velocity);
        std.debug.print("  Entity at ({d:.1}, {d:.1}) moving ({d:.1}, {d:.1})\n", .{
            pos.x, pos.y, vel.vx, vel.vy,
        });
        count += 1;
    }
    std.debug.print("  Total entities with Position+Velocity: {d}\n", .{count});

    // ── Example 4: Run systems via Schedule ────────────────────────

    std.debug.print("\n=== Example 4: Schedule tick ===\n", .{});

    for (0..10) |tick| {
        try Ecs.Schedule.tick(&world, &cmd, .{
            .pre_update = &.{gravitySystem},
            .update = &.{ movementSystem, damageSystem },
        });

        // Print player position every 5 ticks
        if (tick % 5 == 4) {
            if (world.getComponent(player, Position)) |pos| {
                std.debug.print("  Tick {d}: player at ({d:.1}, {d:.1})\n", .{
                    tick + 1, pos.x, pos.y,
                });
            }
        }
    }

    std.debug.print("  Alive entities: {d}\n", .{world.entity_pool.alive_count});

    // ── Example 5: Component add/remove ────────────────────────────

    std.debug.print("\n=== Example 5: Component add/remove ===\n", .{});

    try world.addComponent(player, Disabled, .{});
    std.debug.print("  Player disabled: {}\n", .{world.hasComponent(player, Disabled)});

    try world.removeComponent(player, Disabled);
    std.debug.print("  Player disabled after remove: {}\n", .{world.hasComponent(player, Disabled)});

    // ── Example 6: Resources ───────────────────────────────────────

    std.debug.print("\n=== Example 6: Resources ===\n", .{});

    const DeltaTime = struct { dt: f32 };
    const FrameCount = struct { count: u64 };

    var resources = zcs.Resources.init(allocator);
    defer resources.deinit();

    try resources.set(DeltaTime, .{ .dt = 0.016 });
    try resources.set(FrameCount, .{ .count = 0 });

    std.debug.print("  DeltaTime: {d:.3}s\n", .{resources.get(DeltaTime).dt});
    std.debug.print("  FrameCount: {d}\n", .{resources.get(FrameCount).count});

    // ── Example 7: SparseSet ───────────────────────────────────────

    std.debug.print("\n=== Example 7: SparseSet (debug names) ===\n", .{});

    const DebugName = struct { name: []const u8 };

    var names = zcs.SparseSet(DebugName).init(allocator);
    defer names.deinit();

    try names.set(player, .{ .name = "Hero" });
    if (names.get(player)) |n| {
        std.debug.print("  Player name: {s}\n", .{n.name});
    }

    std.debug.print("\nDone.\n", .{});
}
