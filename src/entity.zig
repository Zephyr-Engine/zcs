const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// A unique identifier for an entity, packed into 64 bits.
/// Contains a 32-bit slot index and a 32-bit generation counter.
///
/// Invariants:
/// - Every issued handle has `generation >= 1`; generation 0 is reserved for
///   `nil`, so `nil.toRaw() == 0` and zero-initialized memory is a nil handle.
///   This matches the plugin-ABI shape `EntityHandle = enum(u64) { none = 0 }`
///   (see docs/dynamic-game-architecture.md): an EntityID bitcasts 1:1 into an
///   ABI handle.
/// - `generation == max_generation` is never issued; it marks a retired slot
///   inside `EntityPool`.
/// - All handles must come from an `EntityPool`; hand-constructed handles in
///   tests must use `generation >= 1`.
pub const EntityID = packed struct(u64) {
    index: u32,
    generation: u32,

    pub const nil: EntityID = .{ .index = 0, .generation = 0 };

    /// Reserved generation marking a slot that exhausted its generations and
    /// is permanently retired. Never present in an issued handle.
    pub const max_generation: u32 = std.math.maxInt(u32);

    pub fn eql(self: EntityID, other: EntityID) bool {
        return self.toRaw() == other.toRaw();
    }

    pub fn toRaw(self: EntityID) u64 {
        return @bitCast(self);
    }

    pub fn fromRaw(raw: u64) EntityID {
        return @bitCast(raw);
    }
};

/// Generation value stamped on never-used slots; the first handle for any
/// slot is issued with this generation, keeping generation 0 exclusive to
/// `EntityID.nil`.
const first_generation: u32 = 1;

/// Manages entity allocation, generation tracking, and index reuse.
pub const EntityPool = struct {
    generations: []u32,
    free_list: std.ArrayListUnmanaged(u32),
    alive_count: u32,
    len: u32,
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

    pub fn initCapacity(allocator: Allocator, capacity: u32) !EntityPool {
        const gens = try allocator.alloc(u32, capacity);
        errdefer allocator.free(gens);
        @memset(gens, first_generation);
        var free_list: std.ArrayListUnmanaged(u32) = .empty;
        // Reserve so `destroy` never needs to allocate (and can't silently drop
        // a recycled index): the free list never exceeds `generations.len`.
        errdefer free_list.deinit(allocator);
        try free_list.ensureTotalCapacity(allocator, capacity);
        return .{
            .generations = gens,
            .free_list = free_list,
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

        var index = self.len;
        while (true) {
            if (index == std.math.maxInt(u32)) {
                return error.EntityLimitReached;
            }

            if (index >= self.generations.len) {
                const old_len = self.generations.len;
                const new_cap = @max(old_len * 2, 64);
                const new_cap_clamped: usize = @min(new_cap, @as(usize, std.math.maxInt(u32)) + 1);
                const new_gens = try self.allocator.alloc(u32, new_cap_clamped);
                @memset(new_gens[old_len..], first_generation);
                if (old_len > 0) {
                    @memcpy(new_gens[0..old_len], self.generations);
                    self.allocator.free(self.generations);
                }
                self.generations = new_gens;
                // Keep the free list able to hold every index, so `destroy` is
                // allocation-free and can never drop a recycled index.
                try self.free_list.ensureTotalCapacity(self.allocator, new_cap_clamped);
            }

            // A retired slot exhausted its generations; skip it forever.
            if (self.generations[index] != EntityID.max_generation) {
                break;
            }
            index += 1;
        }

        self.len = index + 1;
        self.alive_count += 1;
        // Read the slot's generation rather than assuming first_generation: a
        // never-used slot is first_generation (memset), but after `clear()`
        // reused slots carry a bumped generation so stale handles stay invalid.
        return .{ .index = index, .generation = self.generations[index] };
    }

    /// Grow the backing storage so that up to `capacity` entity indices can
    /// be created and destroyed without allocating.
    pub fn reserve(self: *EntityPool, capacity: u32) !void {
        if (capacity > self.generations.len) {
            const old_len = self.generations.len;
            const new_gens = try self.allocator.alloc(u32, capacity);
            @memset(new_gens[old_len..], first_generation);
            if (old_len > 0) {
                @memcpy(new_gens[0..old_len], self.generations);
                self.allocator.free(self.generations);
            }
            self.generations = new_gens;
        }
        // Keep the free list able to hold every index (see `destroy`).
        try self.free_list.ensureTotalCapacity(self.allocator, self.generations.len);
    }

    pub fn destroy(self: *EntityPool, id: EntityID) void {
        if (!self.isAlive(id)) return;
        self.alive_count -= 1;
        const next = self.generations[id.index] + 1;
        self.generations[id.index] = next;
        // A slot that reached max_generation is retired: it is never recycled,
        // so no stale handle can ever alias a new one (no ABA wraparound).
        if (next == EntityID.max_generation) {
            return;
        }
        // Capacity was reserved when the index was created, so this never
        // allocates and never drops the index.
        self.free_list.appendAssumeCapacity(id.index);
    }

    /// Reset the pool to empty, retaining the generations allocation. Every
    /// live index's generation is bumped so previously-issued handles remain
    /// invalid and cannot collide with reused indices.
    pub fn clear(self: *EntityPool) void {
        for (self.generations[0..self.len]) |*g| {
            if (g.* != EntityID.max_generation) g.* += 1;
        }
        self.len = 0;
        self.alive_count = 0;
        self.free_list.clearRetainingCapacity();
    }

    pub fn isAlive(self: *const EntityPool, id: EntityID) bool {
        // Generation 0 is reserved for nil and never issued or stored.
        if (id.generation == 0) {
            return false;
        }
        if (id.index >= self.len) {
            return false;
        }
        return self.generations[id.index] == id.generation;
    }
};

test "EntityID nil sentinel is raw zero" {
    const nil = EntityID.nil;
    try testing.expect(nil.eql(EntityID.nil));
    try testing.expectEqual(@as(u64, 0), nil.toRaw());
    try testing.expect(EntityID.fromRaw(0).eql(nil));
    // A live handle at index 0 is distinct from nil because generations
    // start at 1.
    try testing.expect(!nil.eql(.{ .index = 0, .generation = 1 }));
}

test "EntityID raw round-trip" {
    const id: EntityID = .{ .index = 42, .generation = 7 };
    const raw = id.toRaw();
    const back = EntityID.fromRaw(raw);
    try testing.expect(id.eql(back));
}

test "EntityPool issues generations starting at 1" {
    var pool = EntityPool.init(testing.allocator);
    defer pool.deinit();

    const e = try pool.create();
    try testing.expectEqual(@as(u32, 1), e.generation);
    try testing.expect(!e.eql(EntityID.nil));
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

test "EntityPool clear bumps generations and invalidates handles" {
    var pool = EntityPool.init(testing.allocator);
    defer pool.deinit();

    const e0 = try pool.create();
    const e1 = try pool.create();
    try testing.expectEqual(2, pool.alive_count);

    pool.clear();
    try testing.expectEqual(0, pool.alive_count);
    try testing.expect(!pool.isAlive(e0));
    try testing.expect(!pool.isAlive(e1));

    // Reused index 0 must not collide with the old handle.
    const reused = try pool.create();
    try testing.expectEqual(e0.index, reused.index);
    try testing.expect(!reused.eql(e0));
}

test "EntityPool destroy is allocation-free under many recycles" {
    var pool = EntityPool.init(testing.allocator);
    defer pool.deinit();

    // Create and destroy repeatedly; destroy must never drop an index, so the
    // free list always has the recycled index available.
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const e = try pool.create();
        pool.destroy(e);
    }
    try testing.expectEqual(0, pool.alive_count);
    // Exactly one index was used and recycled each time.
    const e = try pool.create();
    try testing.expectEqual(0, e.index);
}

test "EntityPool reserve pre-sizes generations and free list" {
    var pool = EntityPool.init(testing.allocator);
    defer pool.deinit();

    try pool.reserve(100);
    try testing.expect(pool.generations.len >= 100);
    try testing.expect(pool.free_list.capacity >= pool.generations.len);

    // Reserved indices are created and recycled without growing storage.
    const before = pool.generations.len;
    var ids: [100]EntityID = undefined;
    for (&ids) |*id| id.* = try pool.create();
    for (ids) |id| pool.destroy(id);
    try testing.expectEqual(before, pool.generations.len);
    try testing.expectEqual(0, pool.alive_count);
}

test "EntityPool retires a slot at generation exhaustion instead of wrapping" {
    var pool = EntityPool.init(testing.allocator);
    defer pool.deinit();

    const e0 = try pool.create();
    // Simulate an ancient slot one destroy away from exhaustion.
    pool.generations[e0.index] = EntityID.max_generation - 1;
    const old: EntityID = .{ .index = e0.index, .generation = EntityID.max_generation - 1 };
    try testing.expect(pool.isAlive(old));

    pool.destroy(old);
    try testing.expect(!pool.isAlive(old));
    try testing.expectEqual(0, pool.alive_count);
    // The slot was retired, not recycled: no free-list entry, and the next
    // create must use a fresh index.
    try testing.expectEqual(@as(usize, 0), pool.free_list.items.len);
    const e1 = try pool.create();
    try testing.expect(e1.index != e0.index);
    try testing.expect(pool.isAlive(e1));
}

test "EntityPool create skips retired slots after clear" {
    var pool = EntityPool.init(testing.allocator);
    defer pool.deinit();

    const e0 = try pool.create();
    pool.generations[e0.index] = EntityID.max_generation - 1;
    pool.destroy(.{ .index = e0.index, .generation = EntityID.max_generation - 1 });

    pool.clear();
    // len reset to 0, but slot 0 stays retired; the sequential path must
    // skip it.
    const e1 = try pool.create();
    try testing.expect(e1.index != e0.index);
    try testing.expect(pool.isAlive(e1));
}
