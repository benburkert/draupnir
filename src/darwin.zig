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

    fn call(
        name: @EnumLiteral(),
        args: std.meta.ArgsTuple(@TypeOf(@field(c, @tagName(name)))),
    ) !void {
        return switch (@call(.auto, @field(c, @tagName(name)), args)) {
            0 => {},
            else => |rc| std.debug.panic("unexpected darwin error: {d}", .{rc}),
        };
    }
};
