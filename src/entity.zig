const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// A unique identifier for an entity, packed into 32 bits.
/// Contains a 24-bit index and an 8-bit generation counter.
pub const EntityID = packed struct {
    index: u24,
    generation: u8,

    pub const nil: EntityID = .{ .index = std.math.maxInt(u24), .generation = 0 };

    pub fn eql(self: EntityID, other: EntityID) bool {
        return self.index == other.index and self.generation == other.generation;
    }

    pub fn toRaw(self: EntityID) u32 {
        return @bitCast(self);
    }

    pub fn fromRaw(raw: u32) EntityID {
        return @bitCast(raw);
    }
};

/// Manages entity allocation, generation tracking, and index reuse.
pub const EntityPool = struct {
    generations: []u8,
    free_list: std.ArrayListUnmanaged(u24),
    alive_count: u32,
    len: u24,
    allocator: Allocator,

    pub fn init(allocator: Allocator) EntityPool {
        return .{
            .generations = &.{},
            .free_list = .empty,
            .alive_count = 0,
            .len = 0,
            .allocator = allocator,
        };
    }

    pub fn initCapacity(allocator: Allocator, capacity: u24) !EntityPool {
        const gens = try allocator.alloc(u8, capacity);
        @memset(gens, 0);
        return .{
            .generations = gens,
            .free_list = .empty,
            .alive_count = 0,
            .len = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EntityPool) void {
        if (self.generations.len > 0) {
            self.allocator.free(self.generations);
        }
        self.free_list.deinit(self.allocator);
    }

    pub fn create(self: *EntityPool) !EntityID {
        if (self.free_list.pop()) |index| {
            self.alive_count += 1;
            return .{ .index = index, .generation = self.generations[index] };
        }

        const index = self.len;
        if (index == std.math.maxInt(u24)) return error.EntityLimitReached;

        if (index >= self.generations.len) {
            const old_len = self.generations.len;
            const new_cap = @max(old_len * 2, 64);
            const new_cap_clamped: usize = @min(new_cap, std.math.maxInt(u24) + 1);
            const new_gens = try self.allocator.alloc(u8, new_cap_clamped);
            @memset(new_gens[old_len..], 0);
            if (old_len > 0) {
                @memcpy(new_gens[0..old_len], self.generations);
                self.allocator.free(self.generations);
            }
            self.generations = new_gens;
        }

        self.len = index + 1;
        self.alive_count += 1;
        return .{ .index = index, .generation = 0 };
    }

    pub fn destroy(self: *EntityPool, id: EntityID) void {
        if (!self.isAlive(id)) return;
        self.generations[id.index] +%= 1;
        self.free_list.append(self.allocator, id.index) catch {};
        self.alive_count -= 1;
    }

    pub fn isAlive(self: *const EntityPool, id: EntityID) bool {
        if (id.eql(EntityID.nil)) return false;
        if (id.index >= self.len) return false;
        return self.generations[id.index] == id.generation;
    }
};

test "EntityID nil sentinel" {
    const nil = EntityID.nil;
    try testing.expect(nil.eql(EntityID.nil));
    try testing.expect(!nil.eql(.{ .index = 0, .generation = 0 }));
}

test "EntityID raw round-trip" {
    const id: EntityID = .{ .index = 42, .generation = 7 };
    const raw = id.toRaw();
    const back = EntityID.fromRaw(raw);
    try testing.expect(id.eql(back));
}

test "EntityPool create and destroy" {
    var pool = EntityPool.init(testing.allocator);
    defer pool.deinit();

    const e0 = try pool.create();
    const e1 = try pool.create();
    try testing.expect(pool.isAlive(e0));
    try testing.expect(pool.isAlive(e1));
    try testing.expect(!e0.eql(e1));
    try testing.expectEqual(2, pool.alive_count);

    pool.destroy(e0);
    try testing.expect(!pool.isAlive(e0));
    try testing.expect(pool.isAlive(e1));
    try testing.expectEqual(1, pool.alive_count);
}

test "EntityPool generation reuse" {
    var pool = EntityPool.init(testing.allocator);
    defer pool.deinit();

    const e0 = try pool.create();
    const old_index = e0.index;
    pool.destroy(e0);

    const e1 = try pool.create();
    try testing.expectEqual(old_index, e1.index);
    try testing.expect(!e0.eql(e1));
    try testing.expect(!pool.isAlive(e0));
    try testing.expect(pool.isAlive(e1));
}

test "EntityPool stale handle detection" {
    var pool = EntityPool.init(testing.allocator);
    defer pool.deinit();

    const e = try pool.create();
    pool.destroy(e);
    try testing.expect(!pool.isAlive(e));
    try testing.expect(!pool.isAlive(EntityID.nil));
}

test "EntityPool initCapacity" {
    var pool = try EntityPool.initCapacity(testing.allocator, 100);
    defer pool.deinit();

    const e = try pool.create();
    try testing.expect(pool.isAlive(e));
    try testing.expectEqual(100, pool.generations.len);
}

test "EntityPool generation wraparound" {
    var pool = EntityPool.init(testing.allocator);
    defer pool.deinit();

    var id = try pool.create();
    const idx = id.index;

    // Cycle through all 256 generations
    for (0..256) |_| {
        pool.destroy(id);
        id = try pool.create();
        try testing.expectEqual(idx, id.index);
    }
    // After 256 destroys, generation wraps to 0
    try testing.expectEqual(@as(u8, 0), id.generation);
}
