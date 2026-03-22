const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Type-erased singleton resource storage.
/// Stores one value per type, accessible by comptime type key.
pub const Resources = struct {
    const ErasedResource = struct {
        ptr: *anyopaque,
        deinit_fn: *const fn (*anyopaque, Allocator) void,
    };

    map: std.AutoHashMapUnmanaged(usize, ErasedResource),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Resources {
        return .{
            .map = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Resources) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit_fn(entry.value_ptr.ptr, self.allocator);
        }
        self.map.deinit(self.allocator);
    }

    pub fn set(self: *Resources, comptime T: type, value: T) !void {
        const key = typeId(T);
        if (self.map.getPtr(key)) |existing| {
            const typed: *T = @ptrCast(@alignCast(existing.ptr));
            typed.* = value;
            return;
        }
        const ptr = try self.allocator.create(T);
        ptr.* = value;
        try self.map.put(self.allocator, key, .{
            .ptr = ptr,
            .deinit_fn = makeDeinitFn(T),
        });
    }

    pub fn get(self: *Resources, comptime T: type) *T {
        return self.getOrNull(T) orelse @panic("Resource not found: " ++ @typeName(T));
    }

    pub fn getOrNull(self: *Resources, comptime T: type) ?*T {
        const entry = self.map.get(typeId(T)) orelse return null;
        return @ptrCast(@alignCast(entry.ptr));
    }

    pub fn getConst(self: *const Resources, comptime T: type) *const T {
        return self.getConstOrNull(T) orelse @panic("Resource not found: " ++ @typeName(T));
    }

    pub fn getConstOrNull(self: *const Resources, comptime T: type) ?*const T {
        const entry = self.map.get(typeId(T)) orelse return null;
        return @ptrCast(@alignCast(entry.ptr));
    }

    pub fn remove(self: *Resources, comptime T: type) void {
        if (self.map.fetchRemove(typeId(T))) |kv| {
            kv.value.deinit_fn(kv.value.ptr, self.allocator);
        }
    }

    pub fn contains(self: *const Resources, comptime T: type) bool {
        return self.map.contains(typeId(T));
    }

    fn typeId(comptime T: type) usize {
        const H = struct {
            // Use T to make this struct unique per type instantiation.
            comptime {
                _ = T;
            }
            var byte: u8 = 0;
        };
        return @intFromPtr(&H.byte);
    }

    fn makeDeinitFn(comptime T: type) *const fn (*anyopaque, Allocator) void {
        return struct {
            fn deinit(ptr: *anyopaque, allocator: Allocator) void {
                const typed: *T = @ptrCast(@alignCast(ptr));
                allocator.destroy(typed);
            }
        }.deinit;
    }
};

test "Resources set and get" {
    var res = Resources.init(testing.allocator);
    defer res.deinit();

    try res.set(f32, 3.14);
    try testing.expectApproxEqAbs(3.14, res.get(f32).*, 0.001);
}

test "Resources overwrite" {
    var res = Resources.init(testing.allocator);
    defer res.deinit();

    try res.set(i32, 10);
    try res.set(i32, 20);
    try testing.expectEqual(20, res.get(i32).*);
}

test "Resources getOrNull" {
    var res = Resources.init(testing.allocator);
    defer res.deinit();

    try testing.expect(res.getOrNull(i32) == null);
    try res.set(i32, 42);
    try testing.expectEqual(42, res.getOrNull(i32).?.*);
}

test "Resources remove" {
    var res = Resources.init(testing.allocator);
    defer res.deinit();

    try res.set(i32, 99);
    try testing.expect(res.contains(i32));
    res.remove(i32);
    try testing.expect(!res.contains(i32));
}

test "Resources multiple types" {
    var res = Resources.init(testing.allocator);
    defer res.deinit();

    const DeltaTime = struct { dt: f32 };
    const FrameCount = struct { count: u64 };

    try res.set(DeltaTime, .{ .dt = 0.016 });
    try res.set(FrameCount, .{ .count = 100 });

    try testing.expectApproxEqAbs(0.016, res.get(DeltaTime).dt, 0.0001);
    try testing.expectEqual(100, res.get(FrameCount).count);
}
