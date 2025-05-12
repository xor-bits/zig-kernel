const std = @import("std");

const rt = @import("rt.zig");
const abi = @import("lib.zig");

//

pub const server_page_allocator = std.mem.Allocator{
    .ptr = @ptrFromInt(0x1000),
    .vtable = &.{
        .alloc = _alloc,
        .resize = _resize,
        .remap = _remap,
        .free = _free,
    },
};

fn _alloc(_: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const vm_client = abi.VmProtocol.Client().init(rt.vm_ipc);
    const res, const addr = vm_client.call(.mapAnon, .{
        rt.vmem_handle,
        len,
        abi.sys.Rights{ .writable = true },
        abi.sys.MapFlags{},
    }) catch return null;
    res catch return null;
    return @ptrFromInt(addr);
}

fn _resize(_: *anyopaque, mem: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    const n = abi.ChunkSize.of(mem.len) orelse return false;
    return n.sizeBytes() >= new_len;
}

fn _remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

fn _free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {
    std.log.scoped(.server_page_allocator).warn("TODO: free pages", .{});
}
