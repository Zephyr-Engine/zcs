const std = @import("std");
const Allocator = std.mem.Allocator;
const entity_mod = @import("entity.zig");
const EntityID = entity_mod.EntityID;
const EntityPool = entity_mod.EntityPool;
const chunk_mod = @import("chunk_pool.zig");
const ChunkPool = chunk_mod.ChunkPool;
const Chunk = chunk_mod.Chunk;
const archetype_mod = @import("archetype.zig");
const query_mod = @import("query.zig");

/// Returns a World type specialized for the given Registry.
pub fn World(comptime Reg: type) type {
    const ArchetypeType = archetype_mod.Archetype(Reg);
    const ComponentMask = Reg.ComponentMask;
    const MaskInt = ComponentMask.MaskInt;

    return struct {
        const Self = @This();

        pub const EntityLocation = struct {
            archetype: ?*ArchetypeType = null,
            chunk_idx: u32 = 0,
            row: u16 = 0,
        };

        entity_pool: EntityPool,
        locations: std.ArrayListUnmanaged(EntityLocation),
        archetypes: std.ArrayListUnmanaged(*ArchetypeType),
        archetype_map: std.AutoHashMapUnmanaged(MaskInt, *ArchetypeType),
        chunk_pool: ChunkPool,
        archetype_generation: u32,
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .entity_pool = EntityPool.init(allocator),
                .locations = .empty,
                .archetypes = .empty,
                .archetype_map = .empty,
                .chunk_pool = ChunkPool.init(allocator),
                .archetype_generation = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.archetypes.items) |arch| {
                arch.deinit(self.allocator);
                self.allocator.destroy(arch);
            }
            self.archetypes.deinit(self.allocator);
            self.archetype_map.deinit(self.allocator);
            self.locations.deinit(self.allocator);
            self.entity_pool.deinit();
            self.chunk_pool.deinit();
        }

        pub fn spawn(self: *Self) !EntityID {
            const id = try self.entity_pool.create();
            try self.ensureLocationCapacity(id.index);
            self.locations.items[id.index] = .{};
            return id;
        }

        pub fn despawn(self: *Self, id: EntityID) void {
            if (!self.entity_pool.isAlive(id)) return;

            const loc = self.locations.items[id.index];
            if (loc.archetype) |arch| {
                const moved = arch.removeEntity(loc.chunk_idx, loc.row);
                if (moved) |moved_id| {
                    self.locations.items[moved_id.index] = .{
                        .archetype = arch,
                        .chunk_idx = loc.chunk_idx,
                        .row = loc.row,
                    };
                }
            }

            self.locations.items[id.index] = .{};
            self.entity_pool.destroy(id);
        }

        pub fn isAlive(self: *const Self, id: EntityID) bool {
            return self.entity_pool.isAlive(id);
        }

        /// Add or update a component on an entity. Performs archetype move if needed.
        pub fn addComponent(self: *Self, id: EntityID, comptime T: type, value: T) !void {
            const comp_id = comptime Reg.id(T);

            if (!self.entity_pool.isAlive(id)) return;
            const loc = &self.locations.items[id.index];

            if (loc.archetype) |src_arch| {
                if (src_arch.mask.isSet(comp_id)) {
                    // Already has component — just update value
                    if (@sizeOf(T) > 0) {
                        src_arch.getColumn(src_arch.chunks.items[loc.chunk_idx], T)[loc.row] = value;
                    }
                    return;
                }

                // Archetype move: add component
                var new_mask = src_arch.mask;
                new_mask.set(comp_id);
                const dst_arch = try self.getOrCreateArchetype(new_mask);

                // Check edge cache
                if (src_arch.add_edges[comp_id] == null) {
                    src_arch.add_edges[comp_id] = dst_arch;
                }

                try self.moveEntity(id, loc, src_arch, dst_arch);

                // Set the new component value
                if (@sizeOf(T) > 0) {
                    dst_arch.getColumn(
                        dst_arch.chunks.items[loc.chunk_idx],
                        T,
                    )[loc.row] = value;
                }
            } else {
                // No archetype yet — create one
                var mask = ComponentMask.initEmpty();
                mask.set(comp_id);
                const arch = try self.getOrCreateArchetype(mask);
                const result = try arch.appendEntity(id, self.allocator);

                // Set component value
                if (@sizeOf(T) > 0) {
                    arch.getColumn(arch.chunks.items[result.chunk_idx], T)[result.row] = value;
                }

                loc.* = .{
                    .archetype = arch,
                    .chunk_idx = result.chunk_idx,
                    .row = result.row,
                };
            }
        }

        /// Remove a component from an entity. Performs archetype move.
        pub fn removeComponent(self: *Self, id: EntityID, comptime T: type) !void {
            const comp_id = comptime Reg.id(T);

            if (!self.entity_pool.isAlive(id)) return;
            const loc = &self.locations.items[id.index];

            const src_arch = loc.archetype orelse return;
            if (!src_arch.mask.isSet(comp_id)) return;

            var new_mask = src_arch.mask;
            new_mask.unset(comp_id);

            // Check edge cache
            if (src_arch.remove_edges[comp_id] == null) {
                if (new_mask.mask != 0) {
                    src_arch.remove_edges[comp_id] = try self.getOrCreateArchetype(new_mask);
                }
            }

            if (new_mask.mask == 0) {
                // No components left — remove from archetype
                const moved = src_arch.removeEntity(loc.chunk_idx, loc.row);
                if (moved) |moved_id| {
                    self.locations.items[moved_id.index] = .{
                        .archetype = src_arch,
                        .chunk_idx = loc.chunk_idx,
                        .row = loc.row,
                    };
                }
                loc.* = .{};
            } else {
                const dst_arch = src_arch.remove_edges[comp_id].?;
                try self.moveEntity(id, loc, src_arch, dst_arch);
            }
        }

        /// Get a mutable pointer to an entity's component. Returns null if not present.
        pub fn getComponent(self: *Self, id: EntityID, comptime T: type) ?*T {
            comptime if (@sizeOf(T) == 0) @compileError("Use hasComponent for zero-sized types");

            if (!self.entity_pool.isAlive(id)) return null;
            const loc = self.locations.items[id.index];
            const arch = loc.archetype orelse return null;
            if (!arch.mask.isSet(Reg.id(T))) return null;

            return &arch.getColumn(arch.chunks.items[loc.chunk_idx], T)[loc.row];
        }

        /// Check whether an entity has a component (works for ZSTs and non-ZSTs).
        pub fn hasComponent(self: *const Self, id: EntityID, comptime T: type) bool {
            if (!self.entity_pool.isAlive(id)) return false;
            const loc = self.locations.items[id.index];
            const arch = loc.archetype orelse return false;
            return arch.mask.isSet(Reg.id(T));
        }

        pub fn addComponentRaw(self: *Self, id: EntityID, comp_id: usize, data: []const u8) !void {
            if (!self.entity_pool.isAlive(id)) return;
            const loc = &self.locations.items[id.index];

            if (loc.archetype) |src_arch| {
                if (src_arch.mask.isSet(comp_id)) {
                    // Update existing
                    src_arch.setComponentRaw(
                        src_arch.chunks.items[loc.chunk_idx],
                        loc.row,
                        comp_id,
                        data,
                    );
                    return;
                }

                // Archetype move
                var new_mask = src_arch.mask;
                new_mask.set(comp_id);
                const dst_arch = try self.getOrCreateArchetype(new_mask);

                if (src_arch.add_edges[comp_id] == null) {
                    src_arch.add_edges[comp_id] = dst_arch;
                }

                try self.moveEntity(id, loc, src_arch, dst_arch);

                // Set the new component
                dst_arch.setComponentRaw(
                    dst_arch.chunks.items[loc.chunk_idx],
                    loc.row,
                    comp_id,
                    data,
                );
            } else {
                var mask = ComponentMask.initEmpty();
                mask.set(comp_id);
                const arch = try self.getOrCreateArchetype(mask);
                const result = try arch.appendEntity(id, self.allocator);
                arch.setComponentRaw(arch.chunks.items[result.chunk_idx], result.row, comp_id, data);
                loc.* = .{
                    .archetype = arch,
                    .chunk_idx = result.chunk_idx,
                    .row = result.row,
                };
            }
        }

        pub fn removeComponentRaw(self: *Self, id: EntityID, comp_id: usize) !void {
            if (!self.entity_pool.isAlive(id)) return;
            const loc = &self.locations.items[id.index];

            const src_arch = loc.archetype orelse return;
            if (!src_arch.mask.isSet(comp_id)) return;

            var new_mask = src_arch.mask;
            new_mask.unset(comp_id);

            if (new_mask.mask == 0) {
                const moved = src_arch.removeEntity(loc.chunk_idx, loc.row);
                if (moved) |moved_id| {
                    self.locations.items[moved_id.index] = .{
                        .archetype = src_arch,
                        .chunk_idx = loc.chunk_idx,
                        .row = loc.row,
                    };
                }
                loc.* = .{};
            } else {
                const dst_arch = try self.getOrCreateArchetype(new_mask);
                try self.moveEntity(id, loc, src_arch, dst_arch);
            }
        }

        pub fn query(self: *Self, comptime spec: query_mod.QuerySpec) query_mod.QueryIterator(Reg, spec) {
            return query_mod.QueryIterator(Reg, spec).init(self.archetypes.items, self.archetype_generation);
        }

        pub fn ensureLocationCapacity(self: *Self, index: u24) !void {
            const needed = @as(usize, index) + 1;
            if (needed > self.locations.items.len) {
                try self.locations.appendNTimes(self.allocator, .{}, needed - self.locations.items.len);
            }
        }

        fn getOrCreateArchetype(self: *Self, mask: ComponentMask) !*ArchetypeType {
            if (self.archetype_map.get(mask.mask)) |arch| {
                return arch;
            }

            const arch = try self.allocator.create(ArchetypeType);
            arch.* = ArchetypeType.init(mask, &self.chunk_pool);
            try self.archetypes.append(self.allocator, arch);
            try self.archetype_map.put(self.allocator, mask.mask, arch);
            self.archetype_generation += 1;
            return arch;
        }

        /// Move an entity from src_arch to dst_arch, copying shared component data.
        fn moveEntity(
            self: *Self,
            id: EntityID,
            loc: *EntityLocation,
            src_arch: *ArchetypeType,
            dst_arch: *ArchetypeType,
        ) !void {
            const src_chunk = src_arch.chunks.items[loc.chunk_idx];

            // Append to destination
            const dst_result = try dst_arch.appendEntity(id, self.allocator);
            const dst_chunk = dst_arch.chunks.items[dst_result.chunk_idx];

            // Copy shared component data
            ArchetypeType.copyComponents(
                src_arch,
                src_chunk,
                loc.row,
                dst_arch,
                dst_chunk,
                dst_result.row,
            );

            // Remove from source (swap-remove)
            const moved = src_arch.removeEntity(loc.chunk_idx, loc.row);
            if (moved) |moved_id| {
                self.locations.items[moved_id.index] = .{
                    .archetype = src_arch,
                    .chunk_idx = loc.chunk_idx,
                    .row = loc.row,
                };
            }

            // Update this entity's location
            loc.* = .{
                .archetype = dst_arch,
                .chunk_idx = dst_result.chunk_idx,
                .row = dst_result.row,
            };
        }

        /// Expose internals for command buffer.
        pub fn getEntityPool(self: *Self) *EntityPool {
            return &self.entity_pool;
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

test "World spawn and despawn" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    const e0 = try world.spawn();
    const e1 = try world.spawn();
    try std.testing.expect(world.isAlive(e0));
    try std.testing.expect(world.isAlive(e1));

    world.despawn(e0);
    try std.testing.expect(!world.isAlive(e0));
    try std.testing.expect(world.isAlive(e1));
}

test "World addComponent and getComponent" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn();
    try world.addComponent(e, TestPos, .{ .x = 1.0, .y = 2.0 });

    const pos = world.getComponent(e, TestPos).?;
    try std.testing.expectApproxEqAbs(1.0, pos.x, 0.001);
    try std.testing.expectApproxEqAbs(2.0, pos.y, 0.001);
}

test "World addComponent upsert" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn();
    try world.addComponent(e, TestPos, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e, TestPos, .{ .x = 3.0, .y = 4.0 });

    const pos = world.getComponent(e, TestPos).?;
    try std.testing.expectApproxEqAbs(3.0, pos.x, 0.001);
}

test "World archetype move on addComponent" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn();
    try world.addComponent(e, TestPos, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e, TestVel, .{ .vx = 3.0, .vy = 4.0 });

    // Both components should be accessible
    const pos = world.getComponent(e, TestPos).?;
    const vel = world.getComponent(e, TestVel).?;
    try std.testing.expectApproxEqAbs(1.0, pos.x, 0.001);
    try std.testing.expectApproxEqAbs(3.0, vel.vx, 0.001);
}

test "World removeComponent" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn();
    try world.addComponent(e, TestPos, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e, TestVel, .{ .vx = 3.0, .vy = 4.0 });

    try world.removeComponent(e, TestPos);
    try std.testing.expect(!world.hasComponent(e, TestPos));
    try std.testing.expect(world.hasComponent(e, TestVel));

    const vel = world.getComponent(e, TestVel).?;
    try std.testing.expectApproxEqAbs(3.0, vel.vx, 0.001);
}

test "World hasComponent with ZST" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn();
    try world.addComponent(e, TestTag, .{});
    try std.testing.expect(world.hasComponent(e, TestTag));

    try world.removeComponent(e, TestTag);
    try std.testing.expect(!world.hasComponent(e, TestTag));
}

test "World stale handle rejection" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn();
    try world.addComponent(e, TestPos, .{ .x = 1.0, .y = 2.0 });
    world.despawn(e);

    try std.testing.expect(world.getComponent(e, TestPos) == null);
    try std.testing.expect(!world.hasComponent(e, TestPos));
}

test "World multi-entity stress" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    var ids: [100]EntityID = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = try world.spawn();
        try world.addComponent(id.*, TestPos, .{ .x = @floatFromInt(i), .y = 0 });
    }

    // Despawn every other entity
    for (0..50) |i| {
        world.despawn(ids[i * 2]);
    }

    // Remaining entities should still be valid
    for (0..50) |i| {
        const id = ids[i * 2 + 1];
        try std.testing.expect(world.isAlive(id));
        try std.testing.expect(world.hasComponent(id, TestPos));
    }
}

test "World despawn entity with no components" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn();
    try std.testing.expect(world.isAlive(e));
    world.despawn(e);
    try std.testing.expect(!world.isAlive(e));
}

test "World removeComponent to empty" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn();
    try world.addComponent(e, TestPos, .{ .x = 1, .y = 2 });
    try world.removeComponent(e, TestPos);

    try std.testing.expect(world.isAlive(e));
    try std.testing.expect(!world.hasComponent(e, TestPos));
}
