const std = @import("std");
const Io = std.Io;

pub fn allocRegions(capacity: usize) ![]align(std.heap.page_size_min) u8 {
    const task = std.c.mach_task_self();

    var address: Kernel.c.mach_vm_address_t = undefined;
    try Kernel.call(.mach_vm_allocate, .{
        task,
        &address,
        capacity * 2,
        Kernel.c.VM_FLAGS_ANYWHERE,
    });
    errdefer Kernel.call(.mach_vm_deallocate, .{ task, address, capacity * 2 }) catch {};

    var address2: Kernel.c.mach_vm_address_t = address + capacity;
    try Kernel.call(.mach_vm_deallocate, .{ task, address2, capacity });

    var rw_prot = Kernel.c.VM_PROT_READ | Kernel.c.VM_PROT_WRITE;
    try Kernel.call(.mach_vm_remap, .{
        task,
        &address2,
        capacity,
        0,
        Kernel.c.VM_FLAGS_FIXED | Kernel.c.VM_FLAGS_OVERWRITE,
        task,
        address,
        0,
        &rw_prot,
        &rw_prot,
        Kernel.c.VM_INHERIT_NONE,
    });

    const ptr = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(address));
    return ptr[0 .. capacity * 2];
}

pub fn freeRegions(regions: []align(std.heap.page_size_min) u8) !void {
    try Kernel.call(.mach_vm_deallocate, .{
        std.c.mach_task_self(),
        @as(Kernel.c.mach_vm_address_t, @intFromPtr(regions.ptr)),
        regions.len,
    });
}

const Kernel = struct {
    const c = @import("darwin");

    const Error = error{
        InvalidAddress,
        PermissionDenied,
        OutOfMemory,
        InvalidArgument,
        SystemResources,
        MemoryFailure,
        MemoryError,
        Interrupted,
        TimedOut,
        Terminated,
        Unsupported,
        Unexpected,
    };

    fn call(
        name: @EnumLiteral(),
        args: std.meta.ArgsTuple(@TypeOf(@field(c, @tagName(name)))),
    ) Error!void {
        return switch (@call(.auto, @field(c, @tagName(name)), args)) {
            c.KERN_SUCCESS => {},
            c.KERN_INVALID_ADDRESS => error.InvalidAddress,
            c.KERN_PROTECTION_FAILURE, c.KERN_NO_ACCESS, c.KERN_DENIED => error.PermissionDenied,
            c.KERN_NO_SPACE => error.OutOfMemory,
            c.KERN_INVALID_ARGUMENT, c.KERN_INVALID_VALUE => error.InvalidArgument,
            c.KERN_RESOURCE_SHORTAGE => error.SystemResources,
            c.KERN_MEMORY_FAILURE => error.MemoryFailure,
            c.KERN_MEMORY_ERROR => error.MemoryError,
            c.KERN_ABORTED, c.MACH_SEND_INTERRUPTED, c.MACH_RCV_INTERRUPTED => error.Interrupted,
            c.KERN_OPERATION_TIMED_OUT, c.MACH_SEND_TIMED_OUT, c.MACH_RCV_TIMED_OUT => error.TimedOut,
            c.KERN_TERMINATED => error.Terminated,
            c.KERN_NOT_SUPPORTED => error.Unsupported,
            else => |rc| unexpectedErrno(rc),
        };
    }

    // based on std.posix.unexpectedErrno
    fn unexpectedErrno(rc: c.kern_return_t) !void {
        if (std.options.unexpected_error_tracing) {
            std.debug.print("unexpected mach error: {d}\n", .{rc});
            std.debug.dumpCurrentStackTrace(.{});
        }
        return error.Unexpected;
    }
};
