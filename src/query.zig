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

        /// Comptime mask integers exposed so the World can build/key a cache
        /// of matching archetypes for this query shape.
        pub const req_mask_int = required_mask.mask;
        pub const exc_mask_int = exclude_mask.mask;

        archetypes: []*ArchetypeType,
        arch_idx: usize,
        chunk_idx: usize,
        row_idx: usize,
        /// Current world change tick, stamped onto a column when written.
        world_tick: u64,
        /// When true the archetype list is unfiltered and `matches()` must be
        /// applied while iterating (OOM fallback). When false the list is a
        /// pre-filtered cache and no per-archetype check is needed.
        filter: bool,

        /// Iterate a pre-filtered list of matching archetypes (the cached path).
        pub fn init(archetypes: []*ArchetypeType, world_tick: u64) Self {
            return .{
                .archetypes = archetypes,
                .arch_idx = 0,
                .chunk_idx = 0,
                .row_idx = 0,
                .world_tick = world_tick,
                .filter = false,
            };
        }

        /// Iterate an unfiltered archetype list, applying `matches()` per
        /// archetype. Used as a fallback when the query cache cannot allocate.
        pub fn initScan(archetypes: []*ArchetypeType, world_tick: u64) Self {
            var self: Self = .{
                .archetypes = archetypes,
                .arch_idx = 0,
                .chunk_idx = 0,
                .row_idx = 0,
                .world_tick = world_tick,
                .filter = true,
            };
            self.skipNonMatching();
            return self;
        }

        pub fn matches(arch: *const ArchetypeType) bool {
            return ((arch.mask.mask & required_mask.mask) == required_mask.mask) and
                ((arch.mask.mask & exclude_mask.mask) == 0);
        }

        /// Advance `arch_idx` past any non-matching archetypes (no-op unless
        /// in scan/fallback mode). Called only on archetype transitions, so
        /// `matches()` runs O(archetypes), never per entity.
        fn skipNonMatching(self: *Self) void {
            if (!self.filter) return;
            while (self.arch_idx < self.archetypes.len and !matches(self.archetypes[self.arch_idx])) {
                self.arch_idx += 1;
            }
        }

        /// The View provides typed access to columns within a single chunk.
        pub const View = struct {
            archetype: *ArchetypeType,
            chunk: *Chunk,
            change_ticks: *ArchetypeType.ChangeTicks,
            world_tick: u64,

            /// Get a mutable slice for a write component. Accessing it stamps
            /// the column's change tick with the current world tick.
            pub fn write(self: View, comptime T: type) []T {
                comptime {
                    var found = false;
                    for (spec.write) |W| {
                        if (W == T) found = true;
                    }
                    if (!found) @compileError(@typeName(T) ++ " is not in the write set of this query");
                }
                self.change_ticks[comptime Reg.id(T)] = self.world_tick;
                return self.archetype.getColumn(self.chunk, T);
            }

            /// Whether component T in this chunk was written at or after `since`.
            pub fn changedSince(self: View, comptime T: type, since: u64) bool {
                return self.change_ticks[comptime Reg.id(T)] >= since;
            }

            /// The last-write tick of component T in this chunk.
            pub fn changeTick(self: View, comptime T: type) u64 {
                return self.change_ticks[comptime Reg.id(T)];
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

                if (self.chunk_idx < arch.chunks.items.len) {
                    const ci = self.chunk_idx;
                    const chunk = arch.chunks.items[ci];
                    self.chunk_idx += 1;
                    if (chunk.count > 0) {
                        return .{
                            .archetype = arch,
                            .chunk = chunk,
                            .change_ticks = arch.chunkChangeTicks(ci),
                            .world_tick = self.world_tick,
                        };
                    }
                    continue;
                }

                self.arch_idx += 1;
                self.chunk_idx = 0;
                self.skipNonMatching();
            }
            return null;
        }

        /// Per-entity row accessor.
        pub const Row = struct {
            archetype: *ArchetypeType,
            chunk: *Chunk,
            index: usize,
            change_ticks: *ArchetypeType.ChangeTicks,
            world_tick: u64,

            pub fn write(self: Row, comptime T: type) *T {
                comptime {
                    var found = false;
                    for (spec.write) |W| {
                        if (W == T) found = true;
                    }
                    if (!found) @compileError(@typeName(T) ++ " is not in the write set of this query");
                }
                self.change_ticks[comptime Reg.id(T)] = self.world_tick;
                return &self.archetype.getColumn(self.chunk, T)[self.index];
            }

            /// Whether component T in this row's chunk was written at/after `since`.
            pub fn changedSince(self: Row, comptime T: type, since: u64) bool {
                return self.change_ticks[comptime Reg.id(T)] >= since;
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

                if (self.chunk_idx < arch.chunks.items.len) {
                    const chunk = arch.chunks.items[self.chunk_idx];

                    if (self.row_idx < chunk.count) {
                        const idx = self.row_idx;
                        self.row_idx += 1;
                        return .{
                            .archetype = arch,
                            .chunk = chunk,
                            .index = idx,
                            .change_ticks = arch.chunkChangeTicks(self.chunk_idx),
                            .world_tick = self.world_tick,
                        };
                    }

                    self.chunk_idx += 1;
                    self.row_idx = 0;
                    continue;
                }

                self.arch_idx += 1;
                self.chunk_idx = 0;
                self.row_idx = 0;
                self.skipNonMatching();
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

test "Query change detection via changedSince" {
    var world = WorldType.init(std.testing.allocator);
    defer world.deinit();

    _ = try world.spawnWith(.{ TestPos{ .x = 1, .y = 0 }, TestVel{ .vx = 1, .vy = 0 } });

    world.advanceTick();
    const t_before = world.currentTick();

    // Write Position only — stamps the Position column at the current tick.
    {
        var it = world.query(.{ .write = &.{TestPos}, .read = &.{TestVel} });
        while (it.next()) |view| {
            for (view.write(TestPos)) |*p| p.x += 1;
        }
    }

    // Position is marked changed since t_before; Velocity (never written) is not.
    {
        var it = world.query(.{ .read = &.{ TestPos, TestVel } });
        var found = false;
        while (it.next()) |view| {
            found = true;
            try std.testing.expect(view.changedSince(TestPos, t_before));
            try std.testing.expect(!view.changedSince(TestVel, t_before));
        }
        try std.testing.expect(found);
    }

    // A threshold at a later tick sees no change.
    world.advanceTick();
    const t_after = world.currentTick();
    {
        var it = world.query(.{ .read = &.{TestPos} });
        while (it.next()) |view| {
            try std.testing.expect(!view.changedSince(TestPos, t_after));
        }
    }
}

test "Query cache rebuilds when a new archetype appears" {
    var world = WorldType.init(std.testing.allocator);
    defer world.deinit();

    const a = try world.spawn();
    try world.addComponent(a, TestPos, .{ .x = 1, .y = 0 });

    // First query of this shape populates the cache: one matching archetype.
    {
        var iter = world.query(.{ .read = &.{TestPos} });
        var count: usize = 0;
        while (iter.each()) |_| count += 1;
        try std.testing.expectEqual(1, count);
    }

    // Create a new archetype {Pos,Vel} — this bumps archetype_generation and
    // must invalidate the cached match list for the Pos query.
    const b = try world.spawn();
    try world.addComponent(b, TestPos, .{ .x = 2, .y = 0 });
    try world.addComponent(b, TestVel, .{ .vx = 1, .vy = 0 });

    {
        var iter = world.query(.{ .read = &.{TestPos} });
        var count: usize = 0;
        while (iter.each()) |_| count += 1;
        try std.testing.expectEqual(2, count);
    }

    // Repeated identical query (cache hit) returns the same result.
    {
        var iter = world.query(.{ .read = &.{TestPos} });
        var count: usize = 0;
        while (iter.each()) |_| count += 1;
        try std.testing.expectEqual(2, count);
    }
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
