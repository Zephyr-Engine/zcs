const std = @import("std");
const Allocator = std.mem.Allocator;
const entity_mod = @import("entity.zig");
const EntityID = entity_mod.EntityID;
const testing = std.testing;

/// Returns an Events type specialized for the given Registry.
/// Provides ECS lifecycle event definitions and a simple event queue.
/// Designed to be replaced by a `zus` bridge when available.
pub fn Events(comptime Reg: type) type {
    _ = Reg;
    return struct {
        const Self = @This();

        pub const OnSpawn = struct { entity: EntityID };
        pub const OnDespawn = struct { entity: EntityID };

        pub fn OnComponentAdded(comptime T: type) type {
            return struct { entity: EntityID, value: T };
        }

        pub fn OnComponentRemoved(comptime T: type) type {
            _ = T;
            return struct { entity: EntityID };
        }

        /// Simple typed event queue. Stores events for a single type.
        pub fn EventQueue(comptime E: type) type {
            return struct {
                const Q = @This();

                events: std.ArrayListUnmanaged(E),
                allocator: Allocator,

                pub fn init(allocator: Allocator) Q {
                    return .{ .events = .empty, .allocator = allocator };
                }

                pub fn deinit(self: *Q) void {
                    self.events.deinit(self.allocator);
                }

                pub fn push(self: *Q, event: E) !void {
                    try self.events.append(self.allocator, event);
                }

                pub fn drain(self: *Q) []const E {
                    return self.events.items;
                }

                pub fn clear(self: *Q) void {
                    self.events.clearRetainingCapacity();
                }

                pub fn count(self: *const Q) usize {
                    return self.events.items.len;
                }
            };
        }
    };
}

const TestReg = struct {
    pub const component_count = 0;
    pub const ComponentMask = std.bit_set.IntegerBitSet(1);
};

test "EventQueue push and drain" {
    const Evt = Events(TestReg);
    var q = Evt.EventQueue(Evt.OnSpawn).init(testing.allocator);
    defer q.deinit();

    try q.push(.{ .entity = .{ .index = 0, .generation = 0 } });
    try q.push(.{ .entity = .{ .index = 1, .generation = 0 } });

    const events = q.drain();
    try testing.expectEqual(2, events.len);
    try testing.expectEqual(@as(u24, 0), events[0].entity.index);
    try testing.expectEqual(@as(u24, 1), events[1].entity.index);

    q.clear();
    try testing.expectEqual(0, q.count());
}
