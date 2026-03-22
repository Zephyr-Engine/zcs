const std = @import("std");
const entity_mod = @import("entity.zig");
const EntityID = entity_mod.EntityID;
const chunk_mod = @import("chunk_pool.zig");
const Chunk = chunk_mod.Chunk;
const archetype_mod = @import("archetype.zig");

pub const QuerySpec = struct {
    read: []const type = &.{},
    write: []const type = &.{},
    with: []const type = &.{},
    without: []const type = &.{},
};

/// Returns a query iterator type specialized for the given Registry and query spec.
pub fn QueryIterator(comptime Reg: type, comptime spec: QuerySpec) type {
    const ArchetypeType = archetype_mod.Archetype(Reg);
    const ComponentMask = Reg.ComponentMask;

    // Compute masks at comptime
    const required_mask: ComponentMask = comptime blk: {
        var m = ComponentMask.initEmpty();
        for (spec.read) |T| m.set(Reg.id(T));
        for (spec.write) |T| m.set(Reg.id(T));
        for (spec.with) |T| m.set(Reg.id(T));
        break :blk m;
    };

    const exclude_mask: ComponentMask = comptime blk: {
        var m = ComponentMask.initEmpty();
        for (spec.without) |T| m.set(Reg.id(T));
        break :blk m;
    };

    return struct {
        const Self = @This();

        archetypes: []*ArchetypeType,
        arch_idx: usize,
        chunk_idx: usize,
        row_idx: usize,

        pub fn init(archetypes: []*ArchetypeType, _: u32) Self {
            return .{
                .archetypes = archetypes,
                .arch_idx = 0,
                .chunk_idx = 0,
                .row_idx = 0,
            };
        }

        fn matches(arch: *const ArchetypeType) bool {
            return ((arch.mask.mask & required_mask.mask) == required_mask.mask) and
                ((arch.mask.mask & exclude_mask.mask) == 0);
        }

        /// The View provides typed access to columns within a single chunk.
        pub const View = struct {
            archetype: *ArchetypeType,
            chunk: *Chunk,

            /// Get a mutable slice for a write component.
            pub fn write(self: View, comptime T: type) []T {
                comptime {
                    var found = false;
                    for (spec.write) |W| {
                        if (W == T) found = true;
                    }
                    if (!found) @compileError(@typeName(T) ++ " is not in the write set of this query");
                }
                return self.archetype.getColumn(self.chunk, T);
            }

            /// Get a const slice for a read (or write) component.
            pub fn read(self: View, comptime T: type) []const T {
                comptime {
                    var found = false;
                    for (spec.read) |R| {
                        if (R == T) found = true;
                    }
                    for (spec.write) |W| {
                        if (W == T) found = true;
                    }
                    if (!found) @compileError(@typeName(T) ++ " is not in the read or write set of this query");
                }
                return self.archetype.getColumnConst(self.chunk, T);
            }

            /// Get the entity IDs for this chunk.
            pub fn entities(self: View) []const EntityID {
                return self.archetype.getEntityColumn(self.chunk);
            }

            /// Number of entities in this chunk.
            pub fn len(self: View) usize {
                return self.chunk.count;
            }
        };

        /// Batch iterator: yields one View per matching chunk.
        pub fn next(self: *Self) ?View {
            while (self.arch_idx < self.archetypes.len) {
                const arch = self.archetypes[self.arch_idx];

                if (!matches(arch)) {
                    self.arch_idx += 1;
                    self.chunk_idx = 0;
                    continue;
                }

                if (self.chunk_idx < arch.chunks.items.len) {
                    const chunk = arch.chunks.items[self.chunk_idx];
                    self.chunk_idx += 1;
                    if (chunk.count > 0) {
                        return .{ .archetype = arch, .chunk = chunk };
                    }
                    continue;
                }

                self.arch_idx += 1;
                self.chunk_idx = 0;
            }
            return null;
        }

        /// Per-entity row accessor.
        pub const Row = struct {
            archetype: *ArchetypeType,
            chunk: *Chunk,
            index: usize,

            pub fn write(self: Row, comptime T: type) *T {
                comptime {
                    var found = false;
                    for (spec.write) |W| {
                        if (W == T) found = true;
                    }
                    if (!found) @compileError(@typeName(T) ++ " is not in the write set of this query");
                }
                return &self.archetype.getColumn(self.chunk, T)[self.index];
            }

            pub fn read(self: Row, comptime T: type) *const T {
                comptime {
                    var found = false;
                    for (spec.read) |R| {
                        if (R == T) found = true;
                    }
                    for (spec.write) |W| {
                        if (W == T) found = true;
                    }
                    if (!found) @compileError(@typeName(T) ++ " is not in the read or write set of this query");
                }
                return &self.archetype.getColumnConst(self.chunk, T)[self.index];
            }

            pub fn entity(self: Row) EntityID {
                return self.archetype.getEntityColumn(self.chunk)[self.index];
            }
        };

        /// Per-entity iterator: yields one Row per matching entity.
        pub fn each(self: *Self) ?Row {
            while (self.arch_idx < self.archetypes.len) {
                const arch = self.archetypes[self.arch_idx];

                if (!matches(arch)) {
                    self.arch_idx += 1;
                    self.chunk_idx = 0;
                    self.row_idx = 0;
                    continue;
                }

                if (self.chunk_idx < arch.chunks.items.len) {
                    const chunk = arch.chunks.items[self.chunk_idx];

                    if (self.row_idx < chunk.count) {
                        const idx = self.row_idx;
                        self.row_idx += 1;
                        return .{
                            .archetype = arch,
                            .chunk = chunk,
                            .index = idx,
                        };
                    }

                    self.chunk_idx += 1;
                    self.row_idx = 0;
                    continue;
                }

                self.arch_idx += 1;
                self.chunk_idx = 0;
                self.row_idx = 0;
            }
            return null;
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

const WorldType = @import("world.zig").World(TestReg);

test "Query batch iteration" {
    var world = WorldType.init(std.testing.allocator);
    defer world.deinit();

    const e0 = try world.spawn();
    try world.addComponent(e0, TestPos, .{ .x = 1, .y = 0 });
    try world.addComponent(e0, TestVel, .{ .vx = 10, .vy = 0 });

    const e1 = try world.spawn();
    try world.addComponent(e1, TestPos, .{ .x = 2, .y = 0 });
    try world.addComponent(e1, TestVel, .{ .vx = 20, .vy = 0 });

    var iter = world.query(.{ .write = &.{TestPos}, .read = &.{TestVel} });
    var count: usize = 0;

    while (iter.next()) |view| {
        const positions = view.write(TestPos);
        const velocities = view.read(TestVel);
        for (positions, velocities) |*pos, vel| {
            pos.x += vel.vx;
        }
        count += view.len();
    }

    try std.testing.expectEqual(2, count);
    try std.testing.expectApproxEqAbs(11.0, world.getComponent(e0, TestPos).?.x, 0.001);
    try std.testing.expectApproxEqAbs(22.0, world.getComponent(e1, TestPos).?.x, 0.001);
}

test "Query per-entity iteration" {
    var world = WorldType.init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn();
    try world.addComponent(e, TestPos, .{ .x = 5, .y = 10 });
    try world.addComponent(e, TestVel, .{ .vx = 1, .vy = 2 });

    var iter = world.query(.{ .write = &.{TestPos}, .read = &.{TestVel} });
    if (iter.each()) |row| {
        const pos = row.write(TestPos);
        const vel = row.read(TestVel);
        pos.x += vel.vx;
        pos.y += vel.vy;
    }

    try std.testing.expectApproxEqAbs(6.0, world.getComponent(e, TestPos).?.x, 0.001);
    try std.testing.expectApproxEqAbs(12.0, world.getComponent(e, TestPos).?.y, 0.001);
}

test "Query with/without filters" {
    var world = WorldType.init(std.testing.allocator);
    defer world.deinit();

    // Entity with pos + tag
    const e0 = try world.spawn();
    try world.addComponent(e0, TestPos, .{ .x = 1, .y = 0 });
    try world.addComponent(e0, TestTag, .{});

    // Entity with pos only
    const e1 = try world.spawn();
    try world.addComponent(e1, TestPos, .{ .x = 2, .y = 0 });

    // Query: has Pos, exclude Tag
    var iter = world.query(.{ .write = &.{TestPos}, .without = &.{TestTag} });
    var count: usize = 0;
    while (iter.each()) |row| {
        _ = row;
        count += 1;
    }
    try std.testing.expectEqual(1, count);

    // Query: has Pos, require Tag
    var iter2 = world.query(.{ .write = &.{TestPos}, .with = &.{TestTag} });
    count = 0;
    while (iter2.each()) |row| {
        _ = row;
        count += 1;
    }
    try std.testing.expectEqual(1, count);
}
