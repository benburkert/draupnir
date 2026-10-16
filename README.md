<h1 align="center">
  <br><strong>Draupnir</strong>
</h1>
<p align="center">
  A magic ring buffer for zig reader/writers
</p>

## About

Draupnir is a fast, concurrent, thread-safe ring buffer with an
`std.Io.Reader`/`std.Io.Writer` interface. It implements the [magic ring
buffer](https://en.wikipedia.org/wiki/Circular_buffer#Optimization) pattern to
provide a single contiguous slice for io interface buffers. Reading from and
writing to an interface buffer does not require holding a lock.

```zig

const draupnir = @import("draupnir");

var ring: draupnir.Ring = try .init(io, std.heap.pageSize());
defer ring.deinit() catch unreachable;

// read 128 MiB
var read_future = try io.concurrent(std.Io.Reader.readAllocAll, .{ &ring.reader, gpa, 128 << 20 });

// write 128 MiB
for (0..128) |i| {
    var data: [1 << 20]u8 = @splat(@intCast(i));
    try ring.writer.writeAll(&data);
}

const result = try read_future.await(io);
try gpa.free(result);
```

## Gotchas

* The capacity argument to `draupnir.Ring.init(io, capacity)` must be a
  multiple of the page size returned by `std.heap.pageSize()`.
* The size of the buffer for `draupnir.Ring.reader` and `draupnir.Ring.writer`
  may change any time a method on the interface is called. Be sure to always
  check the size of the buffer before passing arguments that depend on a
  specific buffer size.

## Requirements

**Zig version 0.17 or greater.**

## Usage

In your zig project, add `draupnir` as a dependency:

```bash
zig fetch --save "git+https://codeberg.org/benburkert/draupnir"
```

Create a dependency in your `build.zig`:

```zig
const dep_draupnir = b.dependency("draupnir", .{
    .target = target,
    .optimize = optimize,
});
```

And import the module in your test module:

```zig
mod_tests.root_module.addImport("draupnir", dep_draupnir.module("draupnir"));
```

## Support


| Target | Planned | Supported |
| :--- | :---: | :---: |
| **x86_64-linux** | ✅ | ✅ |
| **aarch64-macos**  | ✅ | ✅ |
| **x86_64-windows** | ✅ | ❌ |

