const std = @import("std");
const Allocator = std.mem.Allocator;
const entity_mod = @import("entity.zig");
const EntityID = entity_mod.EntityID;
const testing = std.testing;

/// A sparse set mapping EntityIDs to values of type V.
/// Uses a hash map for the sparse layer (entity index -> dense index)
/// and parallel dense arrays for entities and values.
/// Does NOT affect archetype masks — no archetype fragmentation.
pub fn SparseSet(comptime V: type) type {
    return struct {
        const Self = @This();

        dense_entities: std.ArrayListUnmanaged(EntityID),
        dense_values: std.ArrayListUnmanaged(V),
        sparse: std.AutoHashMapUnmanaged(u24, u32),
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .dense_entities = .empty,
                .dense_values = .empty,
                .sparse = .empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.dense_entities.deinit(self.allocator);
            self.dense_values.deinit(self.allocator);
            self.sparse.deinit(self.allocator);
        }

        pub fn set(self: *Self, id: EntityID, value: V) !void {
            const result = try self.sparse.getOrPut(self.allocator, id.index);
            if (result.found_existing) {
                const dense_idx = result.value_ptr.*;
                // Verify generation matches
                if (!self.dense_entities.items[dense_idx].eql(id)) {
                    // Stale entry — overwrite
                    self.dense_entities.items[dense_idx] = id;
                }
                self.dense_values.items[dense_idx] = value;
            } else {
                const dense_idx: u32 = @intCast(self.dense_entities.items.len);
                try self.dense_entities.append(self.allocator, id);
                try self.dense_values.append(self.allocator, value);
                result.value_ptr.* = dense_idx;
            }
        }

        pub fn get(self: *Self, id: EntityID) ?*V {
            const dense_idx = self.sparse.get(id.index) orelse return null;
            if (!self.dense_entities.items[dense_idx].eql(id)) return null;
            return &self.dense_values.items[dense_idx];
        }

        pub fn getConst(self: *const Self, id: EntityID) ?*const V {
            const dense_idx = self.sparse.get(id.index) orelse return null;
            if (!self.dense_entities.items[dense_idx].eql(id)) return null;
            return &self.dense_values.items[dense_idx];
        }

        pub fn contains(self: *const Self, id: EntityID) bool {
            const dense_idx = self.sparse.get(id.index) orelse return false;
            return self.dense_entities.items[dense_idx].eql(id);
        }

        pub fn remove(self: *Self, id: EntityID) void {
            const dense_idx_ptr = self.sparse.getPtr(id.index) orelse return;
            const dense_idx = dense_idx_ptr.*;

            // Verify generation
            if (!self.dense_entities.items[dense_idx].eql(id)) return;

            const last_idx: u32 = @intCast(self.dense_entities.items.len - 1);

            if (dense_idx != last_idx) {
                // Swap-remove: move last element into the vacated slot
                const moved_entity = self.dense_entities.items[last_idx];
                self.dense_entities.items[dense_idx] = moved_entity;
                self.dense_values.items[dense_idx] = self.dense_values.items[last_idx];
                // Update sparse map for the moved entity
                self.sparse.getPtr(moved_entity.index).?.* = dense_idx;
            }

            _ = self.dense_entities.pop();
            _ = self.dense_values.pop();
            _ = self.sparse.remove(id.index);
        }

        pub fn count(self: *const Self) usize {
            return self.dense_entities.items.len;
        }

        pub fn entities(self: *const Self) []const EntityID {
            return self.dense_entities.items;
        }

        pub fn values(self: *Self) []V {
            return self.dense_values.items;
        }

        pub fn valuesConst(self: *const Self) []const V {
            return self.dense_values.items;
        }
    };
}

test "SparseSet set and get" {
    var ss = SparseSet(f32).init(testing.allocator);
    defer ss.deinit();

    const e: EntityID = .{ .index = 5, .generation = 0 };
    try ss.set(e, 3.14);

    const val = ss.get(e).?;
    try testing.expectApproxEqAbs(3.14, val.*, 0.001);
}

test "SparseSet remove with swap" {
    var ss = SparseSet(i32).init(testing.allocator);
    defer ss.deinit();

    const e0: EntityID = .{ .index = 0, .generation = 0 };
    const e1: EntityID = .{ .index = 1, .generation = 0 };
    const e2: EntityID = .{ .index = 2, .generation = 0 };

    try ss.set(e0, 10);
    try ss.set(e1, 20);
    try ss.set(e2, 30);

    ss.remove(e0);

    try testing.expect(!ss.contains(e0));
    try testing.expect(ss.contains(e1));
    try testing.expect(ss.contains(e2));
    try testing.expectEqual(20, ss.get(e1).?.*);
    try testing.expectEqual(30, ss.get(e2).?.*);
    try testing.expectEqual(2, ss.count());
}

test "SparseSet stale generation" {
    var ss = SparseSet(i32).init(testing.allocator);
    defer ss.deinit();

    const e_old: EntityID = .{ .index = 5, .generation = 0 };
    const e_new: EntityID = .{ .index = 5, .generation = 1 };

    try ss.set(e_old, 42);
    try testing.expect(ss.contains(e_old));
    try testing.expect(!ss.contains(e_new));
    try testing.expect(ss.get(e_new) == null);
}

test "SparseSet overwrite existing" {
    var ss = SparseSet(i32).init(testing.allocator);
    defer ss.deinit();

    const e: EntityID = .{ .index = 0, .generation = 0 };
    try ss.set(e, 1);
    try ss.set(e, 2);
    try testing.expectEqual(2, ss.get(e).?.*);
    try testing.expectEqual(1, ss.count());
}

test "SparseSet iteration" {
    var ss = SparseSet(i32).init(testing.allocator);
    defer ss.deinit();

    const e0: EntityID = .{ .index = 0, .generation = 0 };
    const e1: EntityID = .{ .index = 1, .generation = 0 };

    try ss.set(e0, 100);
    try ss.set(e1, 200);

    var sum: i32 = 0;
    for (ss.valuesConst()) |v| {
        sum += v;
    }
    try testing.expectEqual(300, sum);
}
