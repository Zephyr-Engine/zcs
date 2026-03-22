const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const chunk_data_size: usize = 16 * 1024;

pub const Chunk = struct {
    data: [chunk_data_size]u8 align(64) = undefined,
    count: u16 = 0,
};

/// Free-list allocator for fixed-size Chunk blocks.
/// O(1) alloc/free, zero fragmentation.
pub const ChunkPool = struct {
    free_list: std.ArrayListUnmanaged(*Chunk),
    allocated: std.ArrayListUnmanaged(*Chunk),
    allocator: Allocator,

    pub fn init(allocator: Allocator) ChunkPool {
        return .{
            .free_list = .empty,
            .allocated = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ChunkPool) void {
        for (self.allocated.items) |chunk| {
            self.allocator.destroy(chunk);
        }
        self.allocated.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
    }

    pub fn alloc(self: *ChunkPool) !*Chunk {
        if (self.free_list.pop()) |chunk| {
            chunk.count = 0;
            return chunk;
        }
        const chunk = try self.allocator.create(Chunk);
        chunk.* = .{};
        try self.allocated.append(self.allocator, chunk);
        return chunk;
    }

    pub fn free(self: *ChunkPool, chunk: *Chunk) void {
        chunk.count = 0;
        self.free_list.append(self.allocator, chunk) catch {};
    }

    pub fn preWarm(self: *ChunkPool, count: usize) !void {
        try self.free_list.ensureTotalCapacity(self.allocator, count);
        try self.allocated.ensureTotalCapacity(self.allocator, self.allocated.items.len + count);
        for (0..count) |_| {
            const chunk = try self.allocator.create(Chunk);
            chunk.* = .{};
            self.allocated.appendAssumeCapacity(chunk);
            self.free_list.appendAssumeCapacity(chunk);
        }
    }
};

test "ChunkPool alloc and free" {
    var pool = ChunkPool.init(testing.allocator);
    defer pool.deinit();

    const c1 = try pool.alloc();
    try testing.expectEqual(@as(u16, 0), c1.count);
    c1.count = 5;
    pool.free(c1);

    // Re-allocating should return the same chunk, reset
    const c2 = try pool.alloc();
    try testing.expectEqual(@as(u16, 0), c2.count);
    try testing.expectEqual(c1, c2);
}

test "ChunkPool preWarm" {
    var pool = ChunkPool.init(testing.allocator);
    defer pool.deinit();

    try pool.preWarm(4);
    try testing.expectEqual(4, pool.free_list.items.len);

    // All pre-warmed chunks should be available
    for (0..4) |_| {
        _ = try pool.alloc();
    }
    try testing.expectEqual(0, pool.free_list.items.len);
}
