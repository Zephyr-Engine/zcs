const std = @import("std");
const Allocator = std.mem.Allocator;
const entity_mod = @import("entity.zig");
const EntityID = entity_mod.EntityID;
const world_mod = @import("world.zig");
const testing = std.testing;

/// Returns a CommandBuffer type specialized for the given Registry.
/// Stores deferred structural mutations for safe iteration.
pub fn CommandBuffer(comptime Reg: type) type {
    return struct {
        const CmdWorldType = world_mod.World(Reg);
        const Self = @This();

        const Command = union(enum) {
            spawn: EntityID,
            despawn: EntityID,
            add_component: struct {
                entity: EntityID,
                comp_id: usize,
                data: []const u8,
            },
            remove_component: struct {
                entity: EntityID,
                comp_id: usize,
            },
        };

        commands: std.ArrayListUnmanaged(Command),
        arena: std.heap.ArenaAllocator,
        world: *CmdWorldType,

        pub fn init(world: *CmdWorldType) Self {
            return .{
                .commands = .empty,
                .arena = std.heap.ArenaAllocator.init(world.allocator),
                .world = world,
            };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.commands.deinit(self.world.allocator);
        }

        /// Spawn a new entity. Returns the EntityID immediately.
        pub fn spawn(self: *Self) !EntityID {
            const id = try self.world.entity_pool.create();
            try self.world.ensureLocationCapacity(id.index);
            self.world.locations.items[id.index] = .{};
            try self.commands.append(self.world.allocator, .{ .spawn = id });
            return id;
        }

        /// Queue a despawn.
        pub fn despawn(self: *Self, id: EntityID) !void {
            try self.commands.append(self.world.allocator, .{ .despawn = id });
        }

        /// Queue a component addition.
        pub fn addComponent(self: *Self, id: EntityID, comptime T: type, value: T) !void {
            const comp_id = comptime Reg.id(T);
            if (@sizeOf(T) > 0) {
                const arena_alloc = self.arena.allocator();
                const data = try arena_alloc.create(T);
                data.* = value;
                try self.commands.append(self.world.allocator, .{
                    .add_component = .{
                        .entity = id,
                        .comp_id = comp_id,
                        .data = std.mem.asBytes(data),
                    },
                });
            } else {
                try self.commands.append(self.world.allocator, .{
                    .add_component = .{
                        .entity = id,
                        .comp_id = comp_id,
                        .data = &.{},
                    },
                });
            }
        }

        /// Queue a component removal.
        pub fn removeComponent(self: *Self, id: EntityID, comptime T: type) !void {
            const comp_id = comptime Reg.id(T);
            try self.commands.append(self.world.allocator, .{
                .remove_component = .{
                    .entity = id,
                    .comp_id = comp_id,
                },
            });
        }

        /// Apply all queued commands to the world, then reset.
        pub fn flush(self: *Self) !void {
            for (self.commands.items) |cmd| {
                switch (cmd) {
                    .spawn => {
                        // Entity was already created in spawn() — nothing to do here.
                    },
                    .despawn => |id| {
                        self.world.despawn(id);
                    },
                    .add_component => |ac| {
                        try self.world.addComponentRaw(ac.entity, ac.comp_id, ac.data);
                    },
                    .remove_component => |rc| {
                        try self.world.removeComponentRaw(rc.entity, rc.comp_id);
                    },
                }
            }
            self.commands.clearRetainingCapacity();
            _ = self.arena.reset(.retain_capacity);
        }
    };
}

const TestPos = struct { x: f32, y: f32 };
const TestVel = struct { vx: f32, vy: f32 };
const TestTag = struct {};

const TestReg = struct {
    pub const component_count = 3;
    pub const ComponentMask = std.bit_set.IntegerBitSet(3);
    pub const component_sizes: [3]usize = .{ @sizeOf(TestPos), @sizeOf(TestVel), @sizeOf(TestTag) };
    pub const component_aligns: [3]usize = .{ @alignOf(TestPos), @alignOf(TestVel), 1 };

    pub fn id(comptime T: type) comptime_int {
        if (T == TestPos) return 0;
        if (T == TestVel) return 1;
        if (T == TestTag) return 2;
        @compileError("unknown type");
    }
};

const WorldType = world_mod.World(TestReg);

test "CommandBuffer deferred spawn" {
    var world = WorldType.init(testing.allocator);
    defer world.deinit();

    var cmd = CommandBuffer(TestReg).init(&world);
    defer cmd.deinit();

    const e = try cmd.spawn();
    try cmd.addComponent(e, TestPos, .{ .x = 1, .y = 2 });

    // Not yet applied
    try testing.expect(world.getComponent(e, TestPos) == null);

    try cmd.flush();

    const pos = world.getComponent(e, TestPos).?;
    try testing.expectApproxEqAbs(1.0, pos.x, 0.001);
}

test "CommandBuffer deferred despawn" {
    var world = WorldType.init(testing.allocator);
    defer world.deinit();

    const e = try world.spawn();
    try world.addComponent(e, TestPos, .{ .x = 1, .y = 2 });

    var cmd = CommandBuffer(TestReg).init(&world);
    defer cmd.deinit();

    try cmd.despawn(e);
    // Still alive before flush
    try testing.expect(world.isAlive(e));

    try cmd.flush();
    try testing.expect(!world.isAlive(e));
}

test "CommandBuffer deferred add and remove component" {
    var world = WorldType.init(testing.allocator);
    defer world.deinit();

    const e = try world.spawn();
    try world.addComponent(e, TestPos, .{ .x = 1, .y = 2 });

    var cmd = CommandBuffer(TestReg).init(&world);
    defer cmd.deinit();

    try cmd.addComponent(e, TestVel, .{ .vx = 10, .vy = 20 });
    try cmd.removeComponent(e, TestPos);

    try cmd.flush();

    try testing.expect(!world.hasComponent(e, TestPos));
    try testing.expect(world.hasComponent(e, TestVel));
    const vel = world.getComponent(e, TestVel).?;
    try testing.expectApproxEqAbs(10.0, vel.vx, 0.001);
}

test "CommandBuffer arena reset after flush" {
    var world = WorldType.init(testing.allocator);
    defer world.deinit();

    var cmd = CommandBuffer(TestReg).init(&world);
    defer cmd.deinit();

    // First batch
    const e0 = try cmd.spawn();
    try cmd.addComponent(e0, TestPos, .{ .x = 1, .y = 2 });
    try cmd.flush();

    // Second batch should work after arena reset
    const e1 = try cmd.spawn();
    try cmd.addComponent(e1, TestPos, .{ .x = 3, .y = 4 });
    try cmd.flush();

    try testing.expectApproxEqAbs(1.0, world.getComponent(e0, TestPos).?.x, 0.001);
    try testing.expectApproxEqAbs(3.0, world.getComponent(e1, TestPos).?.x, 0.001);
}
