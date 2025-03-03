const std = @import("std");
const abi = @import("abi");

//

const log = std.log.scoped(.init);
pub const std_options = abi.std_options;
pub const panic = abi.panic;
// pub const _start = abi.rt._start;

const heap_ptr: [*]u8 = @ptrFromInt(abi.BOOTSTRAP_HEAP);
var heap = std.heap.FixedBufferAllocator.init(heap_ptr[0..abi.BOOTSTRAP_HEAP_SIZE]);

//

pub fn main() !void {
    abi.sys.system_rename(0, "init");
    log.info("hello from init", .{});

    const io_ring = abi.IoRing.init(64, heap.allocator()) catch unreachable;
    defer io_ring.deinit();
    io_ring.setup() catch unreachable;

    var open = abi.io.Open.new("initfs:///sbin/init");
    open.submit(&io_ring);
    const fd = open.wait() catch |err| {
        log.err("failed to open file: {}", .{err});
        unreachable;
    };

    log.info("file opened, fd={}", .{fd});
}

comptime {
    abi.rt.install_rt();
}
