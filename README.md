# zcs (Zephyr Component System)

An archetype-based Entity Component System for Zig 0.16, with SoA memory layout and comptime query validation.

Designed for the [Zephyr Game Engine](https://github.com/Zephyr-Engine/zephyr) but fully standalone — usable in any Zig project that needs high-performance ECS.

## Features

- **Archetype SoA layout** — components are stored in Structure-of-Arrays within 16KB cache-aligned chunks for maximum iteration throughput.
- **Comptime query validation** — read vs write access is enforced at compile time. Accessing a component you didn't declare is a compile error.
- **Zero-sized type (ZST) tags** — tag components like `Player` or `Enemy` affect archetype matching but allocate no storage.
- **O(1) entity operations** — generational `EntityID` (24-bit index + 8-bit generation) with free-list reuse and stale handle detection.
- **Edge-cached archetype transitions** — adding or removing a component reuses a cached pointer to the target archetype.
- **Swap-remove deletion** — O(1) unordered entity removal with automatic back-fill from the last slot.
- **CommandBuffer** — deferred structural mutations (spawn, despawn, add/remove component) safe to use during iteration.
- **Schedule** — phased system execution (pre_update, update, post_update, render) with automatic CommandBuffer flushing.
- **Resources** — type-erased singleton storage for global game state (delta time, frame count, etc.).
- **SparseSet** — generation-aware associative container for per-entity side data (debug names, editor metadata).
- **Zero dependencies** — built entirely on `std`.

## Requirements

- Zig 0.16+

## Installing

Add zcs as a dependency in your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/Zephyr-Engine/zcs.git
```

Then in your `build.zig`:

```zig
const zcs_dep = b.dependency("zcs", .{
    .target = target,
    .optimize = optimize,
});
const zcs_mod = zcs_dep.module("zcs");
exe.root_module.addImport("zcs", zcs_mod);
```

## Running the example

```sh
zig build example
```

## Running tests

```sh
zig build test --summary all
```

## Usage

### Defining components

Components are plain Zig structs. Zero-sized structs work as tags:

```zig
const Position = struct { x: f32, y: f32 };
const Velocity = struct { vx: f32, vy: f32 };
const Health = struct { hp: i32, max_hp: i32 };
const Player = struct {}; // ZST tag
const Enemy = struct {};  // ZST tag
```

### Creating a registry and world

Register component types at comptime, then create a world at runtime:

```zig
const zcs = @import("zcs");

const Ecs = zcs.Registry(&.{ Position, Velocity, Health, Player, Enemy });

var world = Ecs.World.init(allocator);
defer world.deinit();
```

### Spawning entities

```zig
const entity = try world.spawn();
try world.addComponent(entity, Position, .{ .x = 0, .y = 0 });
try world.addComponent(entity, Velocity, .{ .vx = 1, .vy = 2 });
try world.addComponent(entity, Player, .{});
```

### Querying — batch iteration

Batch iteration yields one `View` per chunk, giving you slices for SIMD-friendly loops:

```zig
var iter = world.query(.{ .write = &.{Position}, .read = &.{Velocity} });
while (iter.next()) |view| {
    const positions = view.write(Position);
    const velocities = view.read(Velocity);
    for (positions, velocities) |*pos, vel| {
        pos.x += vel.vx;
        pos.y += vel.vy;
    }
}
```

### Querying — per-entity iteration

Per-entity iteration yields one `Row` at a time, convenient for logic that needs `entity()`:

```zig
var iter = world.query(.{
    .write = &.{Health},
    .read = &.{Position},
    .with = &.{Enemy},
    .without = &.{Disabled},
});
while (iter.each()) |row| {
    const pos = row.read(Position);
    const hp = row.write(Health);
    if (@sqrt(pos.x * pos.x + pos.y * pos.y) < 5.0) {
        hp.hp -= 10;
    }
}
```

### Deferred mutations with CommandBuffer

Structural changes during iteration are buffered and applied on `flush()`:

```zig
var cmd = Ecs.CommandBuffer.init(&world);
defer cmd.deinit();

const e = try cmd.spawn();
try cmd.addComponent(e, Position, .{ .x = 0, .y = 0 });
try cmd.addComponent(e, Enemy, .{});

try cmd.flush();
```

### Systems and Schedule

Systems are plain functions. The Schedule runs them in phases with automatic CommandBuffer flushing between each:

```zig
fn movementSystem(world: *Ecs.World, _: *Ecs.CommandBuffer) !void {
    var iter = world.query(.{ .write = &.{Position}, .read = &.{Velocity} });
    while (iter.next()) |view| {
        const positions = view.write(Position);
        const velocities = view.read(Velocity);
        for (positions, velocities) |*pos, vel| {
            pos.x += vel.vx;
            pos.y += vel.vy;
        }
    }
}

try Ecs.Schedule.tick(&world, &cmd, .{
    .pre_update = &.{gravitySystem},
    .update = &.{ movementSystem, damageSystem },
    .post_update = &.{collisionSystem},
    .render = &.{renderSystem},
});
```

### Resources

Type-safe singleton storage for global state:

```zig
const DeltaTime = struct { dt: f32 };
const FrameCount = struct { count: u64 };

var resources = zcs.Resources.init(allocator);
defer resources.deinit();

try resources.set(DeltaTime, .{ .dt = 0.016 });
try resources.set(FrameCount, .{ .count = 0 });

const dt = resources.get(DeltaTime).dt;
```

### SparseSet

Generation-aware associative container for per-entity side data:

```zig
const DebugName = struct { name: []const u8 };

var names = zcs.SparseSet(DebugName).init(allocator);
defer names.deinit();

try names.set(entity, .{ .name = "Hero" });
if (names.get(entity)) |n| {
    std.debug.print("Name: {s}\n", .{n.name});
}
```

## Query spec

| Field | Type | Description |
|-------|------|-------------|
| `read` | `[]const type` | Components accessed as `[]const T` |
| `write` | `[]const type` | Components accessed as `[]T` (also readable) |
| `with` | `[]const type` | Required components (not accessed) |
| `without` | `[]const type` | Excluded components |

## Schedule phases

| Phase | Intended use |
|-------|-------------|
| `pre_update` | Physics forces, input processing |
| `update` | Core game logic, movement, AI |
| `post_update` | Collision resolution, cleanup |
| `render` | Drawing, UI updates |

## Benchmarks

Run the built-in benchmark suite:

```sh
zig build bench
```

### Configuration

All parameters are optional:

```sh
zig build bench -- [options]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--entities=N` | 10000 | Number of entities for iteration benchmarks |
| `--iters=N` | 100 | Measured samples per benchmark |
| `--warmup=N` | 10 | Warmup iterations before measuring |

### What it measures

- **Spawn empty** — entity creation overhead
- **Spawn with components** — entity creation + component assignment
- **Despawn** — entity removal with swap-remove
- **Iterate 2 components** — batch query over Position + Velocity
- **Iterate 4 components** — batch query over four component types
- **Archetype move** — add/remove component triggering archetype transition
- **Command buffer** — deferred spawn + component add + flush
- **Game frame** — full Schedule tick with multiple systems
