const std = @import("std");
const Io = std.Io;

const draupnir = @import("draupnir");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var ring: draupnir.Ring = try .init(io, std.heap.pageSize());

    var read_future = io.async(Io.Reader.discardAll, .{ &ring.reader, 1 << 20 });

    for (0..(1 << 20)) |_| {
        try ring.writer.writeByte(0x0);
        try ring.writer.flush();
    }
    try ring.writer.flush();
    try read_future.await(io);
}
