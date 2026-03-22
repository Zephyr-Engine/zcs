const std = @import("std");
const world_mod = @import("world.zig");
const cmd_mod = @import("command_buffer.zig");

/// Returns a Parallel dispatch type specialized for the given Registry.
/// Currently executes systems sequentially. When `zob` integration is
/// available, this will dispatch independent systems concurrently using
/// zob's work-stealing scheduler.
pub fn Parallel(comptime Reg: type) type {
    return struct {
        const Self = @This();

        pub const ParWorldType = world_mod.World(Reg);
        pub const ParCmdBufType = cmd_mod.CommandBuffer(Reg);
        pub const SystemFn = *const fn (*ParWorldType, *ParCmdBufType) anyerror!void;

        /// Execute a list of systems. Currently runs sequentially.
        /// In the future, systems with non-overlapping write sets will be
        /// dispatched as parallel task groups via `zob`.
        pub fn dispatch(
            systems: []const SystemFn,
            world: *ParWorldType,
            cmd: *ParCmdBufType,
        ) !void {
            for (systems) |sys| {
                try sys(world, cmd);
            }
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
