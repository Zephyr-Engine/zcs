const std = @import("std");
const Allocator = std.mem.Allocator;
const entity_mod = @import("entity.zig");
const EntityID = entity_mod.EntityID;
const chunk_mod = @import("chunk_pool.zig");
const Chunk = chunk_mod.Chunk;
const ChunkPool = chunk_mod.ChunkPool;
const chunk_data_size = chunk_mod.chunk_data_size;

/// Returns an Archetype type specialized for the given Registry.
pub fn Archetype(comptime Reg: type) type {
    const component_count = Reg.component_count;
    const ComponentMask = Reg.ComponentMask;

    return struct {
        const Self = @This();

        pub const AppendResult = struct {
            chunk_idx: u32,
            row: u16,
        };

        mask: ComponentMask,
        chunks: std.ArrayListUnmanaged(*Chunk),
        entity_count: u32,
        column_offsets: [component_count]u32,
        capacity: u16,
        add_edges: [component_count]?*Self,
        remove_edges: [component_count]?*Self,
        pool: *ChunkPool,

        pub fn init(mask: ComponentMask, pool: *ChunkPool) Self {
            const layout = computeLayout(mask);
            return .{
                .mask = mask,
                .chunks = .empty,
                .entity_count = 0,
                .column_offsets = layout.offsets,
                .capacity = layout.capacity,
                .add_edges = .{null} ** component_count,
                .remove_edges = .{null} ** component_count,
                .pool = pool,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.chunks.deinit(allocator);
        }

        /// Compute the SoA layout for a given component mask.
        /// Returns capacity (entities per chunk) and column offsets.
        fn computeLayout(mask: ComponentMask) struct { capacity: u16, offsets: [component_count]u32 } {
            // Compute per-entity stride
            var stride: usize = @sizeOf(EntityID);
            for (0..component_count) |i| {
                if (mask.isSet(i) and Reg.component_sizes[i] > 0) {
                    stride += Reg.component_sizes[i];
                }
            }
            if (stride == 0) stride = @sizeOf(EntityID);

            // Estimate capacity
            var capacity: u16 = @intCast(@min(chunk_data_size / stride, std.math.maxInt(u16)));

            // Refine: compute exact layout and verify it fits
            while (capacity > 1) {
                var offset: usize = @as(usize, capacity) * @sizeOf(EntityID);
                for (0..component_count) |i| {
                    if (mask.isSet(i) and Reg.component_sizes[i] > 0) {
                        offset = std.mem.alignForward(usize, offset, Reg.component_aligns[i]);
                        offset += @as(usize, capacity) * Reg.component_sizes[i];
                    }
                }
                if (offset <= chunk_data_size) break;
                capacity -= 1;
            }

            // Compute final offsets
            var offsets: [component_count]u32 = .{0} ** component_count;
            var offset: usize = @as(usize, capacity) * @sizeOf(EntityID);
            for (0..component_count) |i| {
                if (mask.isSet(i) and Reg.component_sizes[i] > 0) {
                    offset = std.mem.alignForward(usize, offset, Reg.component_aligns[i]);
                    offsets[i] = @intCast(offset);
                    offset += @as(usize, capacity) * Reg.component_sizes[i];
                }
            }

            return .{ .capacity = capacity, .offsets = offsets };
        }

        /// Add an entity to this archetype. Returns the chunk index and row.
        pub fn appendEntity(self: *Self, id: EntityID, allocator: Allocator) !AppendResult {
            // Get or allocate the last chunk
            if (self.chunks.items.len == 0 or
                self.chunks.items[self.chunks.items.len - 1].count >= self.capacity)
            {
                const chunk = try self.pool.alloc();
                try self.chunks.append(allocator, chunk);
            }

            const chunk_idx: u32 = @intCast(self.chunks.items.len - 1);
            const chunk = self.chunks.items[chunk_idx];
            const row = chunk.count;

            // Write entity ID
            self.getEntityColumnMut(chunk)[row] = id;
            chunk.count += 1;
            self.entity_count += 1;

            return .{ .chunk_idx = chunk_idx, .row = row };
        }

        /// Remove an entity via swap-remove. Returns the EntityID that was
        /// moved into the vacated slot (so the caller can update its location),
        /// or null if no swap was needed.
        pub fn removeEntity(self: *Self, chunk_idx: u32, row: u16) ?EntityID {
            const last_chunk_idx: u32 = @intCast(self.chunks.items.len - 1);
            const last_chunk = self.chunks.items[last_chunk_idx];
            const last_row: u16 = last_chunk.count - 1;
            const chunk = self.chunks.items[chunk_idx];

            var moved_entity: ?EntityID = null;

            if (chunk_idx != last_chunk_idx or row != last_row) {
                // Swap entity ID
                const entity_col = self.getEntityColumnMut(chunk);
                const last_entity_col = self.getEntityColumnMut(last_chunk);
                moved_entity = last_entity_col[last_row];
                entity_col[row] = last_entity_col[last_row];

                // Swap component data
                for (0..component_count) |comp_id| {
                    if (self.mask.isSet(comp_id)) {
                        const size = Reg.component_sizes[comp_id];
                        if (size > 0) {
                            const offset = self.column_offsets[comp_id];
                            const dst = chunk.data[offset + @as(usize, row) * size ..][0..size];
                            const src = last_chunk.data[offset + @as(usize, last_row) * size ..][0..size];
                            @memcpy(dst, src);
                        }
                    }
                }
            }

            last_chunk.count -= 1;
            self.entity_count -= 1;

            // Recycle empty last chunk
            if (last_chunk.count == 0) {
                _ = self.chunks.pop();
                self.pool.free(last_chunk);
            }

            return moved_entity;
        }

        /// Get a typed column slice from a chunk.
        pub fn getColumn(self: *const Self, chunk: *Chunk, comptime T: type) []T {
            const comp_id = comptime Reg.id(T);
            const offset = self.column_offsets[comp_id];
            const ptr: [*]T = @ptrCast(@alignCast(chunk.data[offset..].ptr));
            return ptr[0..chunk.count];
        }

        /// Get a const typed column slice from a chunk.
        pub fn getColumnConst(self: *const Self, chunk: *const Chunk, comptime T: type) []const T {
            const comp_id = comptime Reg.id(T);
            const offset = self.column_offsets[comp_id];
            const ptr: [*]const T = @ptrCast(@alignCast(chunk.data[offset..].ptr));
            return ptr[0..chunk.count];
        }

        /// Get the entity ID column from a chunk.
        pub fn getEntityColumn(self: *const Self, chunk: *const Chunk) []const EntityID {
            _ = self;
            const ptr: [*]const EntityID = @ptrCast(@alignCast(&chunk.data));
            return ptr[0..chunk.count];
        }

        /// Get a mutable entity ID column from a chunk.
        fn getEntityColumnMut(self: *const Self, chunk: *Chunk) [*]EntityID {
            _ = self;
            return @ptrCast(@alignCast(&chunk.data));
        }

        /// Raw column access by runtime component ID.
        pub fn getColumnRaw(self: *const Self, chunk: *Chunk, comp_id: usize) [*]u8 {
            const offset = self.column_offsets[comp_id];
            return chunk.data[offset..].ptr;
        }

        /// Copy all shared component data from one archetype/row to another.
        pub fn copyComponents(
            src_arch: *const Self,
            src_chunk: *Chunk,
            src_row: u16,
            dst_arch: *const Self,
            dst_chunk: *Chunk,
            dst_row: u16,
        ) void {
            for (0..component_count) |comp_id| {
                if (src_arch.mask.isSet(comp_id) and dst_arch.mask.isSet(comp_id)) {
                    const size = Reg.component_sizes[comp_id];
                    if (size > 0) {
                        const src_off = src_arch.column_offsets[comp_id] + @as(u32, src_row) * @as(u32, @intCast(size));
                        const dst_off = dst_arch.column_offsets[comp_id] + @as(u32, dst_row) * @as(u32, @intCast(size));
                        @memcpy(
                            dst_chunk.data[dst_off..][0..size],
                            src_chunk.data[src_off..][0..size],
                        );
                    }
                }
            }
        }

        /// Set raw component data at a specific row.
        pub fn setComponentRaw(self: *const Self, chunk: *Chunk, row: u16, comp_id: usize, data: []const u8) void {
            const size = Reg.component_sizes[comp_id];
            if (size == 0) return;
            const offset = self.column_offsets[comp_id] + @as(u32, row) * @as(u32, @intCast(size));
            @memcpy(chunk.data[offset..][0..size], data);
        }

        /// Clear all chunks without freeing (for pool reuse).
        pub fn clear(self: *Self) void {
            for (self.chunks.items) |chunk| {
                chunk.count = 0;
                self.pool.free(chunk);
            }
            self.chunks.clearRetainingCapacity();
            self.entity_count = 0;
        }
    };
}

const TestPos = struct { x: f32, y: f32 };
const TestVel = struct { vx: f32, vy: f32 };
const TestTag = struct {}; // ZST

const TestRegistry = struct {
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

test "Archetype layout computation" {
    var pool = ChunkPool.init(std.testing.allocator);
    defer pool.deinit();

    var mask = TestRegistry.ComponentMask.initEmpty();
    mask.set(0); // TestPos
    mask.set(1); // TestVel

    const arch = Archetype(TestRegistry).init(mask, &pool);
    try std.testing.expect(arch.capacity > 0);
    try std.testing.expect(arch.column_offsets[0] > 0);
    try std.testing.expect(arch.column_offsets[1] > 0);
}

test "Archetype append and column access" {
    var pool = ChunkPool.init(std.testing.allocator);
    defer pool.deinit();

    var mask = TestRegistry.ComponentMask.initEmpty();
    mask.set(0); // TestPos

    const ArchType = Archetype(TestRegistry);
    var arch = ArchType.init(mask, &pool);
    defer arch.deinit(std.testing.allocator);

    const e0: EntityID = .{ .index = 0, .generation = 0 };
    const result = try arch.appendEntity(e0, std.testing.allocator);
    try std.testing.expectEqual(0, result.chunk_idx);
    try std.testing.expectEqual(0, result.row);
    try std.testing.expectEqual(1, arch.entity_count);

    // Set component data
    const chunk = arch.chunks.items[0];
    arch.getColumn(chunk, TestPos)[0] = .{ .x = 1.0, .y = 2.0 };

    // Read back
    const pos = arch.getColumnConst(chunk, TestPos);
    try std.testing.expectApproxEqAbs(1.0, pos[0].x, 0.001);
    try std.testing.expectApproxEqAbs(2.0, pos[0].y, 0.001);
}

test "Archetype swap-remove" {
    var pool = ChunkPool.init(std.testing.allocator);
    defer pool.deinit();

    var mask = TestRegistry.ComponentMask.initEmpty();
    mask.set(0);

    const ArchType = Archetype(TestRegistry);
    var arch = ArchType.init(mask, &pool);
    defer arch.deinit(std.testing.allocator);

    const e0: EntityID = .{ .index = 0, .generation = 0 };
    const e1: EntityID = .{ .index = 1, .generation = 0 };
    const e2: EntityID = .{ .index = 2, .generation = 0 };

    _ = try arch.appendEntity(e0, std.testing.allocator);
    _ = try arch.appendEntity(e1, std.testing.allocator);
    _ = try arch.appendEntity(e2, std.testing.allocator);

    const chunk = arch.chunks.items[0];
    arch.getColumn(chunk, TestPos)[0] = .{ .x = 0, .y = 0 };
    arch.getColumn(chunk, TestPos)[1] = .{ .x = 1, .y = 1 };
    arch.getColumn(chunk, TestPos)[2] = .{ .x = 2, .y = 2 };

    // Remove e0 (first) — e2 should swap into its slot
    const moved = arch.removeEntity(0, 0);
    try std.testing.expect(moved != null);
    try std.testing.expect(moved.?.eql(e2));
    try std.testing.expectEqual(2, arch.entity_count);

    // e2's data should now be at row 0
    try std.testing.expectApproxEqAbs(2.0, arch.getColumn(chunk, TestPos)[0].x, 0.001);
}

test "Archetype ZST component" {
    var pool = ChunkPool.init(std.testing.allocator);
    defer pool.deinit();

    var mask = TestRegistry.ComponentMask.initEmpty();
    mask.set(2); // TestTag (ZST)

    const ArchType = Archetype(TestRegistry);
    var arch = ArchType.init(mask, &pool);
    defer arch.deinit(std.testing.allocator);

    const e: EntityID = .{ .index = 0, .generation = 0 };
    const result = try arch.appendEntity(e, std.testing.allocator);
    try std.testing.expectEqual(0, result.row);
    try std.testing.expectEqual(1, arch.entity_count);

    // ZST shouldn't consume column space (offset stays 0)
    try std.testing.expectEqual(0, arch.column_offsets[2]);
}
