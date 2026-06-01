const std = @import("std");
const world_mod = @import("world.zig");
const cmd_mod = @import("command_buffer.zig");
const resources_mod = @import("resources.zig");

/// Returns a Schedule type specialized for the given Registry.
pub fn Schedule(comptime Reg: type) type {
    return struct {
        const Self = @This();

        pub const SchedWorldType = world_mod.World(Reg);
        pub const SchedCmdBufType = cmd_mod.CommandBuffer(Reg);
        pub const SystemFn = *const fn (*SchedWorldType, *SchedCmdBufType) anyerror!void;

        pub const Spec = struct {
            pre_update: []const SystemFn = &.{},
            update: []const SystemFn = &.{},
            post_update: []const SystemFn = &.{},
            render: []const SystemFn = &.{},
        };

        /// Run a full tick: execute all phases in order, flushing the
        /// CommandBuffer between each phase.
        pub fn tick(world: *SchedWorldType, cmd: *SchedCmdBufType, comptime spec: Spec) !void {
            world.advanceTick();
            inline for (spec.pre_update) |sys| try sys(world, cmd);
            try cmd.flush();

            inline for (spec.update) |sys| try sys(world, cmd);
            try cmd.flush();

            inline for (spec.post_update) |sys| try sys(world, cmd);
            try cmd.flush();

            inline for (spec.render) |sys| try sys(world, cmd);
            try cmd.flush();
        }

        /// Like `tick`, but first publishes the frame's delta time as the
        /// standard `DeltaTime` resource and increments `FrameCount`, so
        /// systems can read them via `world.getResource(...)`.
        pub fn tickDt(world: *SchedWorldType, cmd: *SchedCmdBufType, dt: f32, comptime spec: Spec) !void {
            try world.setResource(resources_mod.DeltaTime, .{ .seconds = dt });
            if (world.getResourceOrNull(resources_mod.FrameCount)) |fc| {
                fc.value += 1;
            } else {
                try world.setResource(resources_mod.FrameCount, .{ .value = 1 });
            }
            try tick(world, cmd, spec);
        }
    };
}

const TestPos = struct { x: f32, y: f32 };
const TestVel = struct { vx: f32, vy: f32 };

const TestReg = struct {
    pub const component_count = 2;
    pub const ComponentMask = std.bit_set.IntegerBitSet(2);
    pub const component_sizes: [2]usize = .{ @sizeOf(TestPos), @sizeOf(TestVel) };
    pub const component_aligns: [2]usize = .{ @alignOf(TestPos), @alignOf(TestVel) };

    pub fn id(comptime T: type) comptime_int {
        if (T == TestPos) return 0;
        if (T == TestVel) return 1;
        @compileError("unknown type");
    }
};

const WorldType = world_mod.World(TestReg);
const CmdBufType = cmd_mod.CommandBuffer(TestReg);
const SchedType = Schedule(TestReg);

fn movementSystem(world: *WorldType, _: *CmdBufType) !void {
    var iter = world.query(.{ .write = &.{TestPos}, .read = &.{TestVel} });
    while (iter.next()) |view| {
        const positions = view.write(TestPos);
        const velocities = view.read(TestVel);
        for (positions, velocities) |*pos, vel| {
            pos.x += vel.vx;
            pos.y += vel.vy;
        }
    }
}

test "Schedule tick runs systems" {
    var world = WorldType.init(std.testing.allocator);
    defer world.deinit();

    var cmd = CmdBufType.init(&world);
    defer cmd.deinit();

    const e = try world.spawn();
    try world.addComponent(e, TestPos, .{ .x = 0, .y = 0 });
    try world.addComponent(e, TestVel, .{ .vx = 1, .vy = 2 });

    try SchedType.tick(&world, &cmd, .{
        .update = &.{movementSystem},
    });

    const pos = world.getComponent(e, TestPos).?;
    try std.testing.expectApproxEqAbs(1.0, pos.x, 0.001);
    try std.testing.expectApproxEqAbs(2.0, pos.y, 0.001);
}

fn dtMovementSystem(world: *WorldType, _: *CmdBufType) !void {
    const dt = world.getResource(resources_mod.DeltaTime).seconds;
    var iter = world.query(.{ .write = &.{TestPos}, .read = &.{TestVel} });
    while (iter.next()) |view| {
        for (view.write(TestPos), view.read(TestVel)) |*pos, vel| {
            pos.x += vel.vx * dt;
            pos.y += vel.vy * dt;
        }
    }
}

test "Schedule tickDt publishes DeltaTime and FrameCount" {
    var world = WorldType.init(std.testing.allocator);
    defer world.deinit();

    var cmd = CmdBufType.init(&world);
    defer cmd.deinit();

    const e = try world.spawnWith(.{ TestPos{ .x = 0, .y = 0 }, TestVel{ .vx = 10, .vy = 0 } });

    try SchedType.tickDt(&world, &cmd, 0.5, .{ .update = &.{dtMovementSystem} });
    try std.testing.expectApproxEqAbs(5.0, world.getComponent(e, TestPos).?.x, 0.001);
    try std.testing.expectEqual(1, world.getResource(resources_mod.FrameCount).value);

    try SchedType.tickDt(&world, &cmd, 0.5, .{ .update = &.{dtMovementSystem} });
    try std.testing.expectApproxEqAbs(10.0, world.getComponent(e, TestPos).?.x, 0.001);
    try std.testing.expectEqual(2, world.getResource(resources_mod.FrameCount).value);
}

test "Schedule phase ordering" {
    var world = WorldType.init(std.testing.allocator);
    defer world.deinit();

    var cmd = CmdBufType.init(&world);
    defer cmd.deinit();

    const e = try world.spawn();
    try world.addComponent(e, TestPos, .{ .x = 0, .y = 0 });
    try world.addComponent(e, TestVel, .{ .vx = 1, .vy = 2 });

    // Run 3 ticks
    for (0..3) |_| {
        try SchedType.tick(&world, &cmd, .{
            .update = &.{movementSystem},
        });
    }

    const pos = world.getComponent(e, TestPos).?;
    try std.testing.expectApproxEqAbs(3.0, pos.x, 0.001);
    try std.testing.expectApproxEqAbs(6.0, pos.y, 0.001);
}
