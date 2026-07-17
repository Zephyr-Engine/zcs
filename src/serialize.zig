const std = @import("std");
const Allocator = std.mem.Allocator;
const entity_mod = @import("entity.zig");
const EntityID = entity_mod.EntityID;
const world_mod = @import("world.zig");
const testing = std.testing;

/// Magic + version tag at the head of a serialized blob.
const magic: [4]u8 = .{ 'Z', 'C', 'S', '2' };

pub const Error = error{
    BadMagic,
    ComponentCountMismatch,
    UnexpectedEof,
    NotEmpty,
};

/// A bounds-checked cursor over a byte slice for decoding.
const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, n: usize) Error![]const u8 {
        if (self.pos + n > self.bytes.len) return Error.UnexpectedEof;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn int(self: *Cursor, comptime T: type) Error!T {
        const n = @sizeOf(T);
        const s = try self.take(n);
        return std.mem.readInt(T, s[0..n], .little);
    }
};

fn putInt(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

/// Binary (de)serializer specialized for a Registry.
///
/// The format is self-describing enough to detect mismatched registries, but it
/// stores component data as raw bytes and the archetype mask in native byte
/// order — it is intended for round-tripping a world with the *same* build, not
/// as a portable cross-platform format.
pub fn Serializer(comptime Reg: type) type {
    const WT = world_mod.World(Reg);
    const ComponentMask = Reg.ComponentMask;
    const MaskInt = ComponentMask.MaskInt;
    const component_count = Reg.component_count;
    const RawComponent = WT.RawComponent;

    return struct {
        /// Serialize `world` into `out` (appended).
        pub fn serialize(world: *WT, allocator: Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
            try out.appendSlice(allocator, &magic);
            try putInt(out, allocator, u32, @intCast(component_count));

            // ── Entity pool snapshot ──────────────────────────────────
            const pool = &world.entity_pool;
            const len: u32 = pool.len;
            try putInt(out, allocator, u32, len);
            try putInt(out, allocator, u32, pool.alive_count);
            for (pool.generations[0..len]) |g| {
                try putInt(out, allocator, u32, g);
            }
            try putInt(out, allocator, u32, @intCast(pool.free_list.items.len));
            for (pool.free_list.items) |idx| {
                try putInt(out, allocator, u32, idx);
            }

            // ── Archetypes (non-empty only) ───────────────────────────
            var nonempty: u32 = 0;
            for (world.archetypes.items) |arch| {
                if (arch.entity_count > 0) nonempty += 1;
            }
            try putInt(out, allocator, u32, nonempty);

            for (world.archetypes.items) |arch| {
                if (arch.entity_count == 0) continue;
                // mask (native-order raw bytes)
                var mask_int: MaskInt = arch.mask.mask;
                try out.appendSlice(allocator, std.mem.asBytes(&mask_int));
                try putInt(out, allocator, u32, arch.entity_count);

                for (arch.chunks.items) |chunk| {
                    const ids = arch.getEntityColumn(chunk);
                    var row: u16 = 0;
                    while (row < chunk.count) : (row += 1) {
                        try putInt(out, allocator, u64, ids[row].toRaw());
                        inline for (0..component_count) |comp_id| {
                            const size = Reg.component_sizes[comp_id];
                            if (size > 0 and arch.mask.isSet(comp_id)) {
                                const col = arch.getColumnRaw(chunk, comp_id);
                                try out.appendSlice(allocator, col[@as(usize, row) * size ..][0..size]);
                            }
                        }
                    }
                }
            }
        }

        /// Reconstruct `world` (which must be freshly initialized / empty) from
        /// `bytes`.
        pub fn deserialize(world: *WT, allocator: Allocator, bytes: []const u8) !void {
            if (world.archetypes.items.len != 0 or world.entity_pool.len != 0) return Error.NotEmpty;

            var cur = Cursor{ .bytes = bytes };

            const got_magic = try cur.take(4);
            if (!std.mem.eql(u8, got_magic, &magic)) return Error.BadMagic;
            const cc = try cur.int(u32);
            if (cc != component_count) return Error.ComponentCountMismatch;

            // ── Entity pool ───────────────────────────────────────────
            const len = try cur.int(u32);
            const alive_count = try cur.int(u32);

            const pool = &world.entity_pool;
            if (len > 0) {
                const gens = try allocator.alloc(u32, len);
                errdefer allocator.free(gens);
                for (gens) |*g| g.* = try cur.int(u32);
                pool.generations = gens;
            }
            pool.len = @intCast(len);
            pool.alive_count = alive_count;

            const free_len = try cur.int(u32);
            try pool.free_list.ensureTotalCapacity(allocator, free_len);
            var fi: u32 = 0;
            while (fi < free_len) : (fi += 1) {
                pool.free_list.appendAssumeCapacity(@intCast(try cur.int(u32)));
            }

            if (len > 0) try world.ensureLocationCapacity(@intCast(len - 1));

            // ── Archetypes ────────────────────────────────────────────
            const arch_count = try cur.int(u32);
            var ai: u32 = 0;
            while (ai < arch_count) : (ai += 1) {
                var mask_int: MaskInt = undefined;
                @memcpy(std.mem.asBytes(&mask_int), try cur.take(@sizeOf(MaskInt)));
                const mask = ComponentMask{ .mask = mask_int };
                const ecount = try cur.int(u32);

                var e: u32 = 0;
                while (e < ecount) : (e += 1) {
                    const id = EntityID.fromRaw(try cur.int(u64));
                    var comps: [component_count]RawComponent = undefined;
                    var nc: usize = 0;
                    inline for (0..component_count) |comp_id| {
                        const size = Reg.component_sizes[comp_id];
                        if (size > 0 and mask.isSet(comp_id)) {
                            comps[nc] = .{ .comp_id = comp_id, .data = try cur.take(size) };
                            nc += 1;
                        }
                    }
                    try world.insertBundleRaw(id, mask, comps[0..nc]);
                }
            }
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

test "serialize round-trip" {
    const alloc = testing.allocator;

    var w1 = WorldType.init(alloc);
    defer w1.deinit();

    const e0 = try w1.spawnWith(.{ TestPos{ .x = 1, .y = 2 }, TestVel{ .vx = 3, .vy = 4 }, TestTag{} });
    const e1 = try w1.spawnWith(.{TestPos{ .x = 5, .y = 6 }});
    const e2 = try w1.spawn(); // alive but componentless
    const dead = try w1.spawn();
    w1.despawn(dead); // exercises generation bump + free list

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    try Serializer(TestReg).serialize(&w1, alloc, &buf);

    var w2 = WorldType.init(alloc);
    defer w2.deinit();
    try Serializer(TestReg).deserialize(&w2, alloc, buf.items);

    try testing.expect(w2.isAlive(e0));
    try testing.expect(w2.isAlive(e1));
    try testing.expect(w2.isAlive(e2));
    try testing.expect(!w2.isAlive(dead));

    try testing.expectApproxEqAbs(1.0, w2.getComponent(e0, TestPos).?.x, 0.001);
    try testing.expectApproxEqAbs(3.0, w2.getComponent(e0, TestVel).?.vx, 0.001);
    try testing.expect(w2.hasComponent(e0, TestTag));

    try testing.expectApproxEqAbs(5.0, w2.getComponent(e1, TestPos).?.x, 0.001);
    try testing.expect(w2.getComponent(e1, TestVel) == null);

    try testing.expect(!w2.hasComponent(e2, TestPos));
    try testing.expectEqual(w1.entity_pool.alive_count, w2.entity_pool.alive_count);

    // A reused index must get a fresh generation that does not collide with
    // the serialized dead handle.
    const reused = try w2.spawn();
    try testing.expectEqual(dead.index, reused.index);
    try testing.expect(!reused.eql(dead));
}

test "deserialize rejects a non-empty world" {
    const alloc = testing.allocator;
    var w = WorldType.init(alloc);
    defer w.deinit();
    _ = try w.spawn();
    try testing.expectError(Error.NotEmpty, Serializer(TestReg).deserialize(&w, alloc, &magic));
}
