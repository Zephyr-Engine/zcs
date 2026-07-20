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
const Resources = @import("resources.zig").Resources;

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

        /// A type-erased component payload: a component id plus its raw bytes.
        /// Used by the CommandBuffer to defer bundle insertion.
        pub const RawComponent = struct { comp_id: usize, data: []const u8 };

        /// Optional lifecycle observers. All callbacks are null by default, so
        /// an unobserved world pays only a single null check per mutation.
        ///
        /// - `on_spawn`   fires when an entity is created (spawn/spawnWith,
        ///   including the CommandBuffer variants).
        /// - `on_despawn` fires just before an entity is destroyed.
        /// - `on_add`     fires when a component is added to an existing entity.
        /// - `on_remove`  fires just before a component is removed.
        ///
        /// `ctx` is passed back to every callback (e.g. an event bus pointer).
        pub const Observers = struct {
            ctx: *anyopaque = undefined,
            on_spawn: ?*const fn (*anyopaque, EntityID) void = null,
            on_despawn: ?*const fn (*anyopaque, EntityID) void = null,
            on_add: ?*const fn (*anyopaque, EntityID, usize) void = null,
            on_remove: ?*const fn (*anyopaque, EntityID, usize) void = null,
        };

        /// Key identifying a query shape by its required/exclude mask pair.
        const QueryKey = struct { required: MaskInt, exclude: MaskInt };

        /// A cached list of archetypes matching a query, valid as long as
        /// `generation` equals the world's `archetype_generation`.
        const CachedArchetypes = struct {
            generation: u32,
            list: std.ArrayListUnmanaged(*ArchetypeType),
        };

        entity_pool: EntityPool,
        locations: std.ArrayListUnmanaged(EntityLocation),
        archetypes: std.ArrayListUnmanaged(*ArchetypeType),
        archetype_map: std.AutoHashMapUnmanaged(MaskInt, *ArchetypeType),
        query_cache: std.AutoHashMapUnmanaged(QueryKey, CachedArchetypes),
        chunk_pool: ChunkPool,
        resources: Resources,
        observers: Observers,
        archetype_generation: u32,
        /// Monotonic change tick. Stamped onto a component column whenever a
        /// query writes it; advance it once per frame for change detection.
        tick: u64,
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .entity_pool = EntityPool.init(allocator),
                .locations = .empty,
                .archetypes = .empty,
                .archetype_map = .empty,
                .query_cache = .empty,
                .chunk_pool = ChunkPool.init(allocator),
                .resources = Resources.init(allocator),
                .observers = .{},
                .archetype_generation = 0,
                .tick = 1,
                .allocator = allocator,
            };
        }

        /// Pre-allocate `chunk_count` chunks and reserve entity-pool and
        /// location storage for `entity_hint` entities, to avoid hot-path
        /// allocations during play.
        pub fn preWarm(self: *Self, entity_hint: u32, chunk_count: usize) !void {
            if (chunk_count > 0) try self.chunk_pool.preWarm(chunk_count);
            if (entity_hint > 0) {
                try self.entity_pool.reserve(entity_hint);
                try self.ensureLocationCapacity(entity_hint - 1);
            }
        }

        /// Reset the world to empty for reuse (e.g. scene reload), retaining
        /// archetype, chunk, and query-cache allocations. All entity handles
        /// become invalid. Resources are left untouched.
        pub fn clear(self: *Self) void {
            for (self.archetypes.items) |arch| {
                arch.clear();
            }
            self.entity_pool.clear();
            self.locations.clearRetainingCapacity();
            self.tick = 1;
            // Archetypes and archetype_generation are retained, so cached query
            // match lists stay valid (they now point at empty archetypes).
        }

        /// Advance the world change tick. Call once per frame (Schedule does
        /// this automatically) so `changedSince` queries can detect writes.
        pub fn advanceTick(self: *Self) void {
            self.tick += 1;
        }

        pub fn currentTick(self: *const Self) u64 {
            return self.tick;
        }

        /// Install lifecycle observers (see `Observers`).
        pub fn setObservers(self: *Self, observers: Observers) void {
            self.observers = observers;
        }

        inline fn fireSpawn(self: *Self, id: EntityID) void {
            if (self.observers.on_spawn) |f| f(self.observers.ctx, id);
        }
        inline fn fireDespawn(self: *Self, id: EntityID) void {
            if (self.observers.on_despawn) |f| f(self.observers.ctx, id);
        }
        inline fn fireAdd(self: *Self, id: EntityID, comp_id: usize) void {
            if (self.observers.on_add) |f| f(self.observers.ctx, id, comp_id);
        }
        inline fn fireRemove(self: *Self, id: EntityID, comp_id: usize) void {
            if (self.observers.on_remove) |f| f(self.observers.ctx, id, comp_id);
        }

        /// Fire the `on_spawn` observer for an entity created out-of-band (used
        /// by the CommandBuffer, which creates entities directly).
        pub fn notifySpawn(self: *Self, id: EntityID) void {
            self.fireSpawn(id);
        }

        pub fn deinit(self: *Self) void {
            for (self.archetypes.items) |arch| {
                arch.deinit(self.allocator);
                self.allocator.destroy(arch);
            }
            self.archetypes.deinit(self.allocator);
            self.archetype_map.deinit(self.allocator);
            var cache_it = self.query_cache.valueIterator();
            while (cache_it.next()) |cached| {
                cached.list.deinit(self.allocator);
            }
            self.query_cache.deinit(self.allocator);
            self.locations.deinit(self.allocator);
            self.entity_pool.deinit();
            self.chunk_pool.deinit();
            self.resources.deinit();
        }

        // ── Resources (singleton global data) ──────────────────────────

        /// Store (or overwrite) a singleton resource of type T.
        pub fn setResource(self: *Self, comptime T: type, value: T) !void {
            return self.resources.set(T, value);
        }

        /// Get a resource pointer, panicking if it is not present.
        pub fn getResource(self: *Self, comptime T: type) *T {
            return self.resources.get(T);
        }

        /// Get a resource pointer, or null if not present.
        pub fn getResourceOrNull(self: *Self, comptime T: type) ?*T {
            return self.resources.getOrNull(T);
        }

        pub fn hasResource(self: *const Self, comptime T: type) bool {
            return self.resources.contains(T);
        }

        pub fn removeResource(self: *Self, comptime T: type) void {
            self.resources.remove(T);
        }

        pub fn spawn(self: *Self) !EntityID {
            const id = try self.entity_pool.create();
            try self.ensureLocationCapacity(id.index);
            self.locations.items[id.index] = .{};
            self.fireSpawn(id);
            return id;
        }

        /// Spawn an entity with a full component bundle in a single archetype
        /// insertion. `components` is a tuple/struct literal of component
        /// values, e.g. `world.spawnWith(.{ Position{...}, Velocity{...} })`.
        ///
        /// Unlike calling `addComponent` repeatedly, this computes the final
        /// archetype once and performs exactly one append — no per-component
        /// archetype moves.
        pub fn spawnWith(self: *Self, components: anytype) !EntityID {
            const fields = switch (@typeInfo(@TypeOf(components))) {
                .@"struct" => |s| s.fields,
                else => @compileError("spawnWith expects a tuple/struct of component values"),
            };

            const mask = comptime blk: {
                var m = ComponentMask.initEmpty();
                for (fields) |f| m.set(Reg.id(f.type));
                break :blk m;
            };

            const id = try self.entity_pool.create();
            errdefer self.entity_pool.destroy(id);
            try self.ensureLocationCapacity(id.index);

            if (comptime mask.mask == 0) {
                // Empty bundle behaves like a plain spawn.
                self.locations.items[id.index] = .{};
                self.fireSpawn(id);
                return id;
            }

            const arch = try self.getOrCreateArchetype(mask);
            const result = try arch.appendEntity(id, self.allocator);
            const chunk = arch.chunks.items[result.chunk_idx];

            inline for (fields) |f| {
                if (@sizeOf(f.type) > 0) {
                    arch.getColumn(chunk, f.type)[result.row] = @field(components, f.name);
                }
            }
            self.stampChunk(arch, result.chunk_idx);

            self.locations.items[id.index] = .{
                .archetype = arch,
                .chunk_idx = result.chunk_idx,
                .row = result.row,
            };
            self.fireSpawn(id);
            return id;
        }

        pub fn despawn(self: *Self, id: EntityID) void {
            if (!self.entity_pool.isAlive(id)) return;
            self.fireDespawn(id);

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
                    src_arch.chunkChangeTicks(loc.chunk_idx)[comp_id] = self.tick;
                    return;
                }

                // Archetype move: add component, reusing the cached edge when
                // one exists so the common case skips the archetype-map lookup.
                const dst_arch = src_arch.add_edges[comp_id] orelse blk: {
                    var new_mask = src_arch.mask;
                    new_mask.set(comp_id);
                    const dst = try self.getOrCreateArchetype(new_mask);
                    src_arch.add_edges[comp_id] = dst;
                    break :blk dst;
                };

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
                arch.chunkChangeTicks(result.chunk_idx)[comp_id] = self.tick;

                loc.* = .{
                    .archetype = arch,
                    .chunk_idx = result.chunk_idx,
                    .row = result.row,
                };
            }
            self.fireAdd(id, comp_id);
        }

        /// Remove a component from an entity. Performs archetype move.
        pub fn removeComponent(self: *Self, id: EntityID, comptime T: type) !void {
            const comp_id = comptime Reg.id(T);

            if (!self.entity_pool.isAlive(id)) return;
            const loc = &self.locations.items[id.index];

            const src_arch = loc.archetype orelse return;
            if (!src_arch.mask.isSet(comp_id)) return;
            self.fireRemove(id, comp_id);

            var new_mask = src_arch.mask;
            new_mask.unset(comp_id);

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
                const dst_arch = src_arch.remove_edges[comp_id] orelse blk: {
                    const dst = try self.getOrCreateArchetype(new_mask);
                    src_arch.remove_edges[comp_id] = dst;
                    break :blk dst;
                };
                try self.moveEntity(id, loc, src_arch, dst_arch);
            }
        }

        /// Get a mutable pointer to an entity's component. Returns null if not present.
        ///
        /// Writes through this pointer bypass change detection (use a query's
        /// `View.write`/`Row.write`, or `addComponent`, to stamp change ticks).
        /// The pointer is invalidated by any structural change (spawn,
        /// despawn, add/remove component) — do not hold it across one.
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

        /// Place a freshly-spawned (archetype-less) entity directly into the
        /// archetype for `mask`, setting raw component bytes — one append, no
        /// archetype moves. Used by deferred `CommandBuffer.spawnWith`.
        ///
        /// If the entity acquired an archetype since the bundle was queued
        /// (e.g. a direct `addComponent` before the flush), the bundle is
        /// applied as individual component adds instead.
        pub fn insertBundleRaw(self: *Self, id: EntityID, mask: ComponentMask, comps: []const RawComponent) !void {
            if (!self.entity_pool.isAlive(id)) return;
            if (mask.mask == 0) return;
            const loc = &self.locations.items[id.index];
            if (loc.archetype != null) {
                var it = mask.iterator(.{});
                outer: while (it.next()) |comp_id| {
                    for (comps) |c| {
                        if (c.comp_id == comp_id) {
                            try self.addComponentRaw(id, comp_id, c.data);
                            continue :outer;
                        }
                    }
                    // ZST components carry no payload in `comps`.
                    try self.addComponentRaw(id, comp_id, &.{});
                }
                return;
            }

            const arch = try self.getOrCreateArchetype(mask);
            const result = try arch.appendEntity(id, self.allocator);
            const chunk = arch.chunks.items[result.chunk_idx];
            for (comps) |c| {
                arch.setComponentRaw(chunk, result.row, c.comp_id, c.data);
            }
            self.stampChunk(arch, result.chunk_idx);
            loc.* = .{
                .archetype = arch,
                .chunk_idx = result.chunk_idx,
                .row = result.row,
            };
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
                    src_arch.chunkChangeTicks(loc.chunk_idx)[comp_id] = self.tick;
                    return;
                }

                // Archetype move, via the cached edge when one exists.
                const dst_arch = src_arch.add_edges[comp_id] orelse blk: {
                    var new_mask = src_arch.mask;
                    new_mask.set(comp_id);
                    const dst = try self.getOrCreateArchetype(new_mask);
                    src_arch.add_edges[comp_id] = dst;
                    break :blk dst;
                };

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
                arch.chunkChangeTicks(result.chunk_idx)[comp_id] = self.tick;
                loc.* = .{
                    .archetype = arch,
                    .chunk_idx = result.chunk_idx,
                    .row = result.row,
                };
            }
            self.fireAdd(id, comp_id);
        }

        pub fn removeComponentRaw(self: *Self, id: EntityID, comp_id: usize) !void {
            if (!self.entity_pool.isAlive(id)) return;
            const loc = &self.locations.items[id.index];

            const src_arch = loc.archetype orelse return;
            if (!src_arch.mask.isSet(comp_id)) return;
            self.fireRemove(id, comp_id);

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
                const dst_arch = src_arch.remove_edges[comp_id] orelse blk: {
                    const dst = try self.getOrCreateArchetype(new_mask);
                    src_arch.remove_edges[comp_id] = dst;
                    break :blk dst;
                };
                try self.moveEntity(id, loc, src_arch, dst_arch);
            }
        }

        /// Build an iterator over all entities matching `spec`.
        ///
        /// Structural changes (spawn, despawn, add/remove component) while an
        /// iterator is live invalidate it — queue them on a CommandBuffer and
        /// flush after iteration instead.
        pub fn query(self: *Self, comptime spec: query_mod.QuerySpec) query_mod.QueryIterator(Reg, spec) {
            const Iter = query_mod.QueryIterator(Reg, spec);
            const list = self.matchedArchetypes(Iter) catch {
                // Allocation failed building the cache — fall back to a
                // non-cached scan that filters archetypes inline. Correct,
                // just without the cache speedup.
                return Iter.initScan(self.archetypes.items, self.tick);
            };
            return Iter.init(list, self.tick);
        }

        /// Return the cached list of archetypes matching query iterator type
        /// `Iter`, rebuilding it if a new archetype has been created since the
        /// list was last computed.
        fn matchedArchetypes(self: *Self, comptime Iter: type) ![]*ArchetypeType {
            const key = QueryKey{ .required = Iter.req_mask_int, .exclude = Iter.exc_mask_int };
            const gop = try self.query_cache.getOrPut(self.allocator, key);
            if (!gop.found_existing) {
                // Seed with a defined-but-stale generation so a failed rebuild
                // below leaves the entry safely invalid, never undefined.
                gop.value_ptr.* = .{ .generation = self.archetype_generation -% 1, .list = .empty };
            }
            const cached = gop.value_ptr;
            if (cached.generation == self.archetype_generation) {
                return cached.list.items;
            }

            // (Re)build the matched set. Only happens when a new archetype was
            // created since the last query of this shape.
            cached.list.clearRetainingCapacity();
            for (self.archetypes.items) |arch| {
                if (Iter.matches(arch)) {
                    try cached.list.append(self.allocator, arch);
                }
            }
            cached.generation = self.archetype_generation;
            return cached.list.items;
        }

        pub fn ensureLocationCapacity(self: *Self, index: u32) !void {
            const needed = @as(usize, index) + 1;
            if (needed > self.locations.items.len) {
                try self.locations.appendNTimes(self.allocator, .{}, needed - self.locations.items.len);
            }
        }

        fn getOrCreateArchetype(self: *Self, mask: ComponentMask) !*ArchetypeType {
            if (self.archetype_map.get(mask.mask)) |arch| {
                return arch;
            }

            // On failure, fully unwind: a half-registered archetype (in the
            // list but not the map) would let a later call create a duplicate
            // for the same mask and silently split its entities.
            const arch = try self.allocator.create(ArchetypeType);
            errdefer self.allocator.destroy(arch);
            arch.* = ArchetypeType.init(mask, &self.chunk_pool);
            try self.archetypes.append(self.allocator, arch);
            errdefer _ = self.archetypes.pop();
            try self.archetype_map.put(self.allocator, mask.mask, arch);
            self.archetype_generation += 1;
            return arch;
        }

        /// Mark every component column of one chunk as written at the current
        /// tick. Called when rows are inserted into or moved between chunks,
        /// so chunk-granular change detection cannot miss the new data.
        fn stampChunk(self: *Self, arch: *ArchetypeType, chunk_idx: u32) void {
            const ticks = arch.chunkChangeTicks(chunk_idx);
            var it = arch.mask.iterator(.{});
            while (it.next()) |comp_id| ticks[comp_id] = self.tick;
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
            // The destination chunk now holds data it did not have before;
            // stamp it so change detection sees the move.
            self.stampChunk(dst_arch, dst_result.chunk_idx);

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

        // ── Diagnostics ────────────────────────────────────────────────

        pub const Stats = struct {
            /// Live entities.
            entity_count: u32,
            /// Archetypes that have ever been created (includes empty ones).
            archetype_count: usize,
            /// Archetypes currently holding at least one entity.
            nonempty_archetype_count: usize,
            /// Chunks currently in use across all archetypes.
            chunk_count: usize,
            /// Chunks held by the pool (in use + free list).
            pooled_chunk_count: usize,
            /// Bytes backing in-use chunks (chunk_count * chunk_data_size).
            chunk_bytes: usize,
            /// Total entity slots available across in-use chunks.
            slot_capacity: usize,
            /// Entity slots actually filled.
            slots_used: usize,
            /// slots_used / slot_capacity in [0,1]; 1.0 means perfectly packed.
            occupancy: f32,
        };

        /// Snapshot of world-level memory and population statistics. O(archetypes).
        pub fn stats(self: *const Self) Stats {
            var s = Stats{
                .entity_count = self.entity_pool.alive_count,
                .archetype_count = self.archetypes.items.len,
                .nonempty_archetype_count = 0,
                .chunk_count = 0,
                .pooled_chunk_count = self.chunk_pool.allocated.items.len,
                .chunk_bytes = 0,
                .slot_capacity = 0,
                .slots_used = 0,
                .occupancy = 0,
            };
            for (self.archetypes.items) |arch| {
                const chunks = arch.chunks.items.len;
                s.chunk_count += chunks;
                s.slots_used += arch.entity_count;
                s.slot_capacity += chunks * arch.capacity;
                if (arch.entity_count > 0) s.nonempty_archetype_count += 1;
            }
            s.chunk_bytes = s.chunk_count * chunk_mod.chunk_data_size;
            if (s.slot_capacity > 0) {
                s.occupancy = @as(f32, @floatFromInt(s.slots_used)) /
                    @as(f32, @floatFromInt(s.slot_capacity));
            }
            return s;
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

const ObsCounts = struct {
    spawns: u32 = 0,
    despawns: u32 = 0,
    adds: u32 = 0,
    removes: u32 = 0,

    fn onSpawn(ctx: *anyopaque, _: EntityID) void {
        const self: *ObsCounts = @ptrCast(@alignCast(ctx));
        self.spawns += 1;
    }
    fn onDespawn(ctx: *anyopaque, _: EntityID) void {
        const self: *ObsCounts = @ptrCast(@alignCast(ctx));
        self.despawns += 1;
    }
    fn onAdd(ctx: *anyopaque, _: EntityID, _: usize) void {
        const self: *ObsCounts = @ptrCast(@alignCast(ctx));
        self.adds += 1;
    }
    fn onRemove(ctx: *anyopaque, _: EntityID, _: usize) void {
        const self: *ObsCounts = @ptrCast(@alignCast(ctx));
        self.removes += 1;
    }
};

test "World lifecycle observers" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    var counts = ObsCounts{};
    world.setObservers(.{
        .ctx = &counts,
        .on_spawn = ObsCounts.onSpawn,
        .on_despawn = ObsCounts.onDespawn,
        .on_add = ObsCounts.onAdd,
        .on_remove = ObsCounts.onRemove,
    });

    const e = try world.spawn(); // spawns=1
    try world.addComponent(e, TestPos, .{ .x = 1, .y = 2 }); // adds=1
    try world.addComponent(e, TestPos, .{ .x = 3, .y = 4 }); // upsert: no add
    try world.addComponent(e, TestVel, .{ .vx = 0, .vy = 0 }); // adds=2
    try world.removeComponent(e, TestPos); // removes=1
    world.despawn(e); // despawns=1

    _ = try world.spawnWith(.{TestPos{ .x = 0, .y = 0 }}); // spawns=2 (bundle: no per-component add)

    try std.testing.expectEqual(2, counts.spawns);
    try std.testing.expectEqual(1, counts.despawns);
    try std.testing.expectEqual(2, counts.adds);
    try std.testing.expectEqual(1, counts.removes);
}

test "World clear resets entities and invalidates handles" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    const e0 = try world.spawnWith(.{ TestPos{ .x = 1, .y = 2 }, TestVel{ .vx = 3, .vy = 4 } });
    _ = try world.spawnWith(.{TestPos{ .x = 5, .y = 6 }});
    try std.testing.expectEqual(2, world.stats().entity_count);

    world.clear();

    try std.testing.expectEqual(0, world.stats().entity_count);
    try std.testing.expectEqual(0, world.stats().chunk_count);
    try std.testing.expect(!world.isAlive(e0)); // old handle invalid

    // World is reusable; a reused index gets a fresh, non-colliding handle.
    const e_new = try world.spawnWith(.{TestPos{ .x = 9, .y = 9 }});
    try std.testing.expect(world.isAlive(e_new));
    try std.testing.expect(!e_new.eql(e0));
    try std.testing.expectApproxEqAbs(9.0, world.getComponent(e_new, TestPos).?.x, 0.001);
}

test "World preWarm" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    try world.preWarm(1000, 8);
    try std.testing.expect(world.locations.items.len >= 1000);
    try std.testing.expect(world.entity_pool.generations.len >= 1000);
    try std.testing.expect(world.entity_pool.free_list.capacity >= 1000);
    try std.testing.expectEqual(8, world.chunk_pool.free_list.items.len);

    // Spawning reuses pre-warmed chunks (no new allocation needed).
    _ = try world.spawnWith(.{TestPos{ .x = 0, .y = 0 }});
    try std.testing.expectEqual(7, world.chunk_pool.free_list.items.len);
}

test "World stats" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    _ = try world.spawnWith(.{ TestPos{ .x = 1, .y = 2 }, TestVel{ .vx = 3, .vy = 4 } });
    _ = try world.spawnWith(.{TestPos{ .x = 5, .y = 6 }});

    const s = world.stats();
    try std.testing.expectEqual(2, s.entity_count);
    try std.testing.expectEqual(2, s.archetype_count); // {Pos,Vel} and {Pos}
    try std.testing.expectEqual(2, s.nonempty_archetype_count);
    try std.testing.expectEqual(2, s.chunk_count);
    try std.testing.expectEqual(2, s.slots_used);
    try std.testing.expect(s.occupancy > 0 and s.occupancy <= 1.0);
    try std.testing.expect(s.chunk_bytes == s.chunk_count * 16 * 1024);
}

test "World spawnWith bundle" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawnWith(.{ TestPos{ .x = 1, .y = 2 }, TestVel{ .vx = 3, .vy = 4 }, TestTag{} });
    try std.testing.expect(world.hasComponent(e, TestPos));
    try std.testing.expect(world.hasComponent(e, TestVel));
    try std.testing.expect(world.hasComponent(e, TestTag));
    try std.testing.expectApproxEqAbs(1.0, world.getComponent(e, TestPos).?.x, 0.001);
    try std.testing.expectApproxEqAbs(3.0, world.getComponent(e, TestVel).?.vx, 0.001);

    // Exactly one archetype should exist (no churn through intermediates).
    try std.testing.expectEqual(1, world.archetypes.items.len);
}

test "World spawnWith empty bundle behaves like spawn" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawnWith(.{});
    try std.testing.expect(world.isAlive(e));
    try std.testing.expectEqual(0, world.archetypes.items.len);
}

test "World archetype transition edges are cached and reused" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    const vel_id = comptime TestReg.id(TestVel);

    const e0 = try world.spawn();
    try world.addComponent(e0, TestPos, .{ .x = 1, .y = 2 });
    const src = world.locations.items[e0.index].archetype.?;
    try world.addComponent(e0, TestVel, .{ .vx = 3, .vy = 4 });
    const dst = world.locations.items[e0.index].archetype.?;

    // The add edge {Pos} --Vel--> {Pos,Vel} is populated after the first move.
    try std.testing.expectEqual(dst, src.add_edges[vel_id].?);

    // A second entity taking the same transition lands in the cached target.
    const e1 = try world.spawn();
    try world.addComponent(e1, TestPos, .{ .x = 5, .y = 6 });
    try world.addComponent(e1, TestVel, .{ .vx = 7, .vy = 8 });
    try std.testing.expectEqual(dst, world.locations.items[e1.index].archetype.?);

    // Removing Vel populates the reverse edge back to {Pos}.
    try world.removeComponent(e0, TestVel);
    try std.testing.expectEqual(src, dst.remove_edges[vel_id].?);
    try std.testing.expectEqual(src, world.locations.items[e0.index].archetype.?);
}

test "World spawned entities count as changed" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    world.advanceTick();
    const t_spawn = world.currentTick();
    _ = try world.spawnWith(.{ TestPos{ .x = 1, .y = 2 }, TestVel{ .vx = 3, .vy = 4 } });

    {
        var it = world.query(.{ .read = &.{ TestPos, TestVel } });
        var found = false;
        while (it.next()) |view| {
            found = true;
            try std.testing.expect(view.changedSince(TestPos, t_spawn));
            try std.testing.expect(view.changedSince(TestVel, t_spawn));
        }
        try std.testing.expect(found);
    }

    // A threshold after the spawn sees no change.
    world.advanceTick();
    const t_later = world.currentTick();
    var it = world.query(.{ .read = &.{TestPos} });
    while (it.next()) |view| {
        try std.testing.expect(!view.changedSince(TestPos, t_later));
    }
}

test "World addComponent stamps change ticks" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn();
    try world.addComponent(e, TestPos, .{ .x = 1, .y = 2 });

    // Upsert on a later tick re-stamps the column.
    world.advanceTick();
    const t = world.currentTick();
    try world.addComponent(e, TestPos, .{ .x = 3, .y = 4 });

    var it = world.query(.{ .read = &.{TestPos} });
    var found = false;
    while (it.next()) |view| {
        found = true;
        try std.testing.expect(view.changedSince(TestPos, t));
    }
    try std.testing.expect(found);
}

test "World archetype move keeps entity visible to change detection" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawnWith(.{TestPos{ .x = 1, .y = 2 }});

    world.advanceTick();
    const t = world.currentTick();
    // Moving to {Pos,Vel} copies Pos into a chunk of the new archetype; the
    // copied data must register as changed there.
    try world.addComponent(e, TestVel, .{ .vx = 3, .vy = 4 });

    var it = world.query(.{ .read = &.{ TestPos, TestVel } });
    var found = false;
    while (it.next()) |view| {
        found = true;
        try std.testing.expect(view.changedSince(TestPos, t));
        try std.testing.expect(view.changedSince(TestVel, t));
    }
    try std.testing.expect(found);
}

test "World swap-remove across chunks merges change ticks" {
    var world = World(TestReg).init(std.testing.allocator);
    defer world.deinit();

    // Fill one chunk of {Pos} plus one overflow entity in a second chunk.
    const first = try world.spawnWith(.{TestPos{ .x = 0, .y = 0 }});
    const cap = world.archetypes.items[0].capacity;
    var i: usize = 1;
    while (i < @as(usize, cap) + 1) : (i += 1) {
        _ = try world.spawnWith(.{TestPos{ .x = @floatFromInt(i), .y = 0 }});
    }
    try std.testing.expectEqual(2, world.archetypes.items[0].chunks.items.len);

    // Write only the second (overflow) chunk on a later tick.
    world.advanceTick();
    const t = world.currentTick();
    {
        var it = world.query(.{ .write = &.{TestPos} });
        var view_idx: usize = 0;
        while (it.next()) |view| : (view_idx += 1) {
            if (view_idx == 1) _ = view.write(TestPos);
        }
    }

    // Despawning an entity in chunk 0 swaps the overflow row (recently
    // written) into chunk 0, whose tick must absorb the newer value.
    world.despawn(first);
    var it = world.query(.{ .read = &.{TestPos} });
    const view = it.next().?;
    try std.testing.expect(view.changedSince(TestPos, t));
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
