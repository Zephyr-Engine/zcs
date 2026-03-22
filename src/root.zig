const std = @import("std");

pub const EntityID = @import("entity.zig").EntityID;
pub const EntityPool = @import("entity.zig").EntityPool;
pub const ChunkPool = @import("chunk_pool.zig").ChunkPool;
pub const Chunk = @import("chunk_pool.zig").Chunk;
pub const chunk_data_size = @import("chunk_pool.zig").chunk_data_size;
pub const Resources = @import("resources.zig").Resources;
pub const QuerySpec = @import("query.zig").QuerySpec;

pub fn SparseSet(comptime V: type) type {
    return @import("sparse_set.zig").SparseSet(V);
}

/// Top-level comptime generic that returns a namespace of specialized ECS
/// types for the given component set.
///
/// Usage:
/// ```
/// const Ecs = zcs.Registry(&.{ Position, Velocity, Health, Player });
/// var world = Ecs.World.init(allocator);
/// ```
pub fn Registry(comptime component_types: []const type) type {
    const count = component_types.len;

    return struct {
        pub const component_count = count;
        pub const mask_len = @max(count, 1);
        pub const ComponentMask = std.bit_set.IntegerBitSet(mask_len);

        pub const component_sizes: [count]usize = blk: {
            var sizes: [count]usize = undefined;
            for (component_types, 0..) |T, i| {
                sizes[i] = @sizeOf(T);
            }
            break :blk sizes;
        };

        pub const component_aligns: [count]usize = blk: {
            var aligns: [count]usize = undefined;
            for (component_types, 0..) |T, i| {
                aligns[i] = if (@sizeOf(T) == 0) 1 else @alignOf(T);
            }
            break :blk aligns;
        };

        /// Returns the comptime component index for type T.
        pub fn id(comptime T: type) comptime_int {
            inline for (component_types, 0..) |CT, i| {
                if (CT == T) return i;
            }
            @compileError("Type " ++ @typeName(T) ++ " is not a registered component");
        }

        /// Build a ComponentMask from a list of types.
        pub fn componentMask(comptime types: []const type) ComponentMask {
            comptime {
                var m = ComponentMask.initEmpty();
                for (types) |T| {
                    m.set(id(T));
                }
                return m;
            }
        }

        /// Get the type of component at index i.
        pub fn componentType(comptime i: comptime_int) type {
            return component_types[i];
        }

        // ── Specialized sub-types ──────────────────────────────────────

        pub const Archetype = @import("archetype.zig").Archetype(@This());
        pub const World = @import("world.zig").World(@This());
        pub const CommandBuffer = @import("command_buffer.zig").CommandBuffer(@This());
        pub const Schedule = @import("schedule.zig").Schedule(@This());
        pub const Events = @import("events.zig").Events(@This());
        pub const Parallel = @import("parallel.zig").Parallel(@This());
    };
}

test {
    _ = @import("entity.zig");
    _ = @import("chunk_pool.zig");
    _ = @import("archetype.zig");
    _ = @import("world.zig");
    _ = @import("query.zig");
    _ = @import("command_buffer.zig");
    _ = @import("resources.zig");
    _ = @import("schedule.zig");
    _ = @import("events.zig");
    _ = @import("parallel.zig");
    _ = @import("sparse_set.zig");
    std.testing.refAllDecls(@This());
}

const Position = struct { x: f32, y: f32 };
const Velocity = struct { vx: f32, vy: f32 };
const Player = struct {};

test "Registry end-to-end" {
    const Ecs = Registry(&.{ Position, Velocity, Player });

    // Comptime checks
    comptime {
        try std.testing.expectEqual(0, Ecs.id(Position));
        try std.testing.expectEqual(1, Ecs.id(Velocity));
        try std.testing.expectEqual(2, Ecs.id(Player));

        const m = Ecs.componentMask(&.{ Position, Velocity });
        try std.testing.expect(m.isSet(0));
        try std.testing.expect(m.isSet(1));
        try std.testing.expect(!m.isSet(2));
    }

    // Runtime world usage
    var world = Ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn();
    try world.addComponent(e, Position, .{ .x = 0, .y = 0 });
    try world.addComponent(e, Velocity, .{ .vx = 1, .vy = 2 });
    try world.addComponent(e, Player, .{});

    try std.testing.expect(world.hasComponent(e, Player));

    // Query and update
    var iter = world.query(.{ .write = &.{Position}, .read = &.{Velocity} });
    while (iter.each()) |row| {
        const pos = row.write(Position);
        const vel = row.read(Velocity);
        pos.x += vel.vx;
        pos.y += vel.vy;
    }

    try std.testing.expectApproxEqAbs(1.0, world.getComponent(e, Position).?.x, 0.001);
    try std.testing.expectApproxEqAbs(2.0, world.getComponent(e, Position).?.y, 0.001);
}
