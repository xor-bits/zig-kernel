const std = @import("std");
const abi = @import("abi");

//

const log = std.log.scoped(.init);
pub const std_options = abi.std_options;
pub const panic = abi.panic;

const heap_ptr: [*]u8 = @ptrFromInt(abi.BOOTSTRAP_HEAP);
var heap = std.heap.FixedBufferAllocator.init(heap_ptr[0..abi.BOOTSTRAP_HEAP_SIZE]);

//

export fn _start() linksection(".text._start") callconv(.C) noreturn {
    log.info("hello from init", .{});

    const io_ring = abi.IoRing.init(64, heap.allocator()) catch unreachable;
    defer io_ring.deinit();

    const path = "initfs:///sbin/init";
    io_ring.submit(.{
        .user_data = 0,
        .opcode = .open,
        .flags = 0,
        .fd = 3,
        .buffer = @constCast(@ptrCast(path)),
        .buffer_len = path.len,
        .offset = 0,
    }) catch unreachable;

    const r = io_ring.wait();
    log.info("result={any}", .{abi.sys.decode(r.result)});
    log.info("{any}", .{r});

    while (true) {
        // abi.sys.yield();
    }
}
