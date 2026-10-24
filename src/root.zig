const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const darwin = @import("darwin.zig");
const posix = @import("posix.zig");

pub const Ring = struct {
    regions: []align(std.heap.page_size_min) u8,

    io: Io,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,

    consumed: usize = 0,
    staged: usize = 0,

    reader: Io.Reader,
    writer: Io.Writer,

    pub fn init(io: Io, capacity: usize) !Ring {
        assert(capacity % std.heap.pageSize() == 0);

        var regions = switch (builtin.os.tag) {
            .linux => try posix.allocRegions(io, capacity),
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => try darwin.allocRegions(capacity),
            else => @compileError("unsupported platform"),
        };

        return .{
            .regions = regions,
            .io = io,
            .reader = .{
                .vtable = &.{
                    .stream = stream,
                    .rebase = rebaseReader,
                },
                .buffer = regions[0..0],
                .seek = 0,
                .end = 0,
            },
            .writer = .{
                .vtable = &.{
                    .drain = drain,
                    .rebase = rebaseWriter,
                },
                .buffer = regions[0..capacity],
                .end = 0,
            },
        };
    }

    pub fn deinit(self: @This()) !void {
        switch (builtin.os.tag) {
            .linux => try posix.freeRegions(self.regions),
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => try darwin.freeRegions(self.regions),
            else => unreachable,
        }
    }

    fn rebaseReader(r: *Io.Reader, capacity: usize) Io.Reader.RebaseError!void {
        var self: *Ring = @fieldParentPtr("reader", r);
        self.mutex.lock(self.io) catch return error.ReadFailed;
        defer self.mutex.unlock(self.io);

        self.compactReader();
        self.reader.buffer.len += self.staged;
        self.reader.end += self.staged;
        self.staged = 0;
        self.cond.signal(self.io);

        while (self.reader.buffer.len - self.reader.seek < capacity) {
            self.cond.wait(self.io, &self.mutex) catch return error.ReadFailed;

            self.reader.buffer.len += self.staged;
            self.reader.end += self.staged;
            self.staged = 0;
        }
    }

    fn rebaseWriter(w: *Io.Writer, preserve: usize, capacity: usize) Io.Writer.Error!void {
        var self: *Ring = @fieldParentPtr("writer", w);
        self.mutex.lock(self.io) catch return error.WriteFailed;
        defer self.mutex.unlock(self.io);

        self.compactWriter(preserve);
        self.writer.buffer.len += self.consumed;
        self.consumed = 0;
        self.cond.signal(self.io);

        while (self.writer.buffer.len - self.writer.end < capacity) {
            self.cond.wait(self.io, &self.mutex) catch return error.WriteFailed;

            self.writer.buffer.len += self.consumed;
            self.consumed = 0;
        }
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        var self: *Ring = @fieldParentPtr("reader", r);
        self.mutex.lock(self.io) catch return error.ReadFailed;
        defer self.mutex.unlock(self.io);

        const capacity = self.regions.len >> 1;

        // block until readable space is available
        while (self.consumed + self.writer.buffer.len == capacity) {
            self.cond.wait(self.io, &self.mutex) catch return error.ReadFailed;
        }

        // grow readable buffer
        self.reader.buffer.len += self.staged;
        self.reader.end += self.staged;
        self.staged = 0;

        // consume read bytes, shift to first region
        defer {
            self.compactReader();
            self.cond.signal(self.io);
        }

        // write buffered bytes to w
        const n = try w.write(limit.slice(self.reader.buffered()));
        self.reader.seek += n;
        return n;
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        var self: *Ring = @fieldParentPtr("writer", w);
        self.mutex.lock(self.io) catch return error.WriteFailed;
        defer self.mutex.unlock(self.io);

        const capacity = self.regions.len >> 1;
        const regions_start = @intFromPtr(self.regions.ptr);

        // block until writable space is available
        if (Io.Writer.countSplat(data, splat) > 0) {
            while (self.staged + self.reader.buffer.len == capacity) {
                self.cond.wait(self.io, &self.mutex) catch return error.WriteFailed;
            }
        }

        // grow writable buffer
        self.writer.buffer.len += self.consumed;
        self.consumed = 0;

        // stage buffer contents, shift to first region
        defer {
            self.staged += self.writer.end;
            self.writer.buffer = self.writer.buffer[self.writer.end..];
            self.writer.end = 0;

            self.writer.buffer.ptr = @ptrFromInt(
                regions_start + ((@intFromPtr(self.writer.buffer.ptr) - regions_start) % capacity),
            );
            self.cond.signal(self.io);
        }

        // move data to buffer
        var cap: usize = self.writer.buffer.len - self.writer.end;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            const buffer = Io.Limit.limited(cap).sliceConst(slice);
            @memcpy(self.writer.buffer[self.writer.end..][0..buffer.len], buffer);
            self.writer.end += buffer.len;
            n += buffer.len;
            cap -= buffer.len;
            if (cap == 0) {
                return n;
            }
        }
        for (0..splat) |_| {
            const buffer = Io.Limit.limited(cap).sliceConst(data[data.len - 1]);
            @memcpy(self.writer.buffer[self.writer.end..][0..buffer.len], buffer);
            self.writer.end += buffer.len;
            n += buffer.len;
            cap -= buffer.len;
            if (cap == 0) {
                return n;
            }
        }
        return n;
    }

    fn compactReader(self: *Ring) void {
        const capacity = self.regions.len >> 1;
        const regions_start = @intFromPtr(self.regions.ptr);

        self.reader.buffer = self.reader.buffer[self.reader.seek..];
        self.reader.end = self.reader.buffer.len;
        self.consumed += self.reader.seek;
        self.reader.seek = 0;

        self.reader.buffer.ptr = @ptrFromInt(
            regions_start + ((@intFromPtr(self.reader.buffer.ptr) - regions_start) % capacity),
        );
    }

    fn compactWriter(self: *Ring, preserve: usize) void {
        const capacity = self.regions.len >> 1;
        const regions_start = @intFromPtr(self.regions.ptr);
        const seek = self.writer.end -| preserve;

        self.staged += seek;
        self.writer.buffer = self.writer.buffer[seek..];
        self.writer.end -= seek;

        self.writer.buffer.ptr = @ptrFromInt(
            regions_start + ((@intFromPtr(self.writer.buffer.ptr) - regions_start) % capacity),
        );
    }
};

test "basic" {
    const io = std.testing.io;

    const capacity = std.heap.pageSize();
    var ring: Ring = try .init(io, capacity);
    defer ring.deinit() catch unreachable;

    try std.testing.expectEqual(0, ring.reader.buffer.len);
    try std.testing.expectEqual(capacity, ring.writer.buffer.len);

    try ring.writer.writeAll(&.{ 1, 2, 3 });
    try ring.writer.flush();

    var buf: [3]u8 = undefined;
    try ring.reader.readSliceAll(&buf);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &buf);
}

test "concurrent" {
    const io = std.testing.io;

    const capacity = std.heap.pageSize();
    var ring: Ring = try .init(io, capacity);
    defer ring.deinit() catch unreachable;

    var source: [1 << 20]u8 = @splat(1);
    var sink: [1 << 20]u8 = undefined;

    var write_future = try io.concurrent(Io.Writer.writeAll, .{ &ring.writer, &source });

    try ring.reader.readSliceAll(&sink);

    try write_future.await(io);
    try std.testing.expectEqual({}, write_future.result);

    try std.testing.expectEqualSlices(u8, &source, &sink);
}

test "128 MiB" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var ring: Ring = try .init(io, std.heap.pageSize());
    defer ring.deinit() catch unreachable;

    // read 128 MiB
    var read_future = try io.concurrent(Io.Reader.readAllocAll, .{ &ring.reader, gpa, 128 << 20 });

    for (0..128) |i| {
        var data: [1 << 20]u8 = @splat(@intCast(i));
        try ring.writer.writeAll(&data);
    }

    const result = try read_future.await(io);
    defer gpa.free(result);

    for (0..128) |i| {
        const data: [1 << 20]u8 = @splat(@intCast(i));
        try std.testing.expectEqualSlices(u8, &data, result[(i << 20)..((i + 1) << 20)]);
    }
}

test "peek" {
    const io = std.testing.io;

    var ring: Ring = try .init(io, std.heap.pageSize());
    defer ring.deinit() catch unreachable;

    try ring.writer.writeAll(&.{42});
    try ring.writer.flush();

    const buf = try ring.reader.peek(1);
    try std.testing.expectEqual(42, buf[0]);
}

test "writer rebase with preserved bytes" {
    const io = std.testing.io;
    const capacity = std.heap.pageSize();

    var ring: Ring = try .init(io, capacity);
    defer ring.deinit() catch unreachable;

    // fill the ring, then force a rebase that preserves the last byte
    {
        var initial: [capacity - 4]u8 = @splat(1);
        try ring.writer.writeAll(&initial);
        try ring.writer.flush();

        var sink: [capacity - 4]u8 = undefined;
        try ring.reader.readSliceAll(&sink);

        try ring.writer.writeAll(&.{ 2, 3, 4, 5 });
        try ring.writer.writeBytePreserve(2, 6);
        try ring.writer.flush();
    }

    var result: [5]u8 = undefined;
    try ring.reader.readSliceAll(&result);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4, 5, 6 }, &result);
}

test "concurrent write and read" {
    const io = std.testing.io;

    var ring: Ring = try .init(io, std.heap.pageSize());
    defer ring.deinit() catch unreachable;

    const Tester = union(enum) {
        read: std.Io.Reader.Error!void,
        write: std.Io.Writer.Error!void,

        const n = 1024;

        pub fn doRead(r: *std.Io.Reader) std.Io.Reader.Error!void {
            var buf: [n]u8 = undefined;
            try r.readSliceAll(&buf);
        }
        pub fn doWrite(w: *std.Io.Writer) std.Io.Writer.Error!void {
            var data: [n]u8 = @splat(1);
            try w.writeAll(&data);
            try w.flush();
        }
    };

    const rounds = 64;
    var select_buffer: [2]Tester = undefined;
    var select: std.Io.Select(Tester) = .init(io, &select_buffer);

    for (0..rounds) |_| {
        try select.concurrent(.write, Tester.doWrite, .{&ring.writer});
        try select.concurrent(.read, Tester.doRead, .{&ring.reader});
        for (0..2) |_| {
            switch (try select.await()) {
                .read => |read| try read,
                .write => |write| try write,
            }
        }
    }
}
