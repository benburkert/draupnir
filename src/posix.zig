const std = @import("std");
const Io = std.Io;
const posix = std.posix;

pub fn allocRegions(io: Io, capacity: usize) ![]align(std.heap.page_size_min) u8 {
    const file: Io.File = .{
        .handle = try posix.memfd_create("draupnir", posix.FD_CLOEXEC),
        .flags = undefined,
    };
    defer file.close(io);
    try file.setLength(io, capacity);

    var regions = try posix.mmap(
        null,
        capacity * 2,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    errdefer posix.munmap(regions);

    _ = try posix.mmap(
        regions.ptr,
        capacity,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED, .FIXED = true },
        file.handle,
        0,
    );
    _ = try posix.mmap(
        @as([]align(std.heap.page_size_min) u8, @alignCast(regions[capacity..])).ptr,
        capacity,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED, .FIXED = true },
        file.handle,
        0,
    );

    return regions;
}

pub fn freeRegions(regions: []align(std.heap.page_size_min) u8) !void {
    return posix.munmap(regions);
}
