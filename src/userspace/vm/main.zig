const std = @import("std");
const abi = @import("abi");

//

const log = std.log.scoped(.vm);
pub const std_options = abi.std_options;
pub const panic = abi.panic;

//

pub fn main() !void {
    log.info("hello from vm", .{});

    var msg: abi.sys.Message = .{ .arg0 = @intFromEnum(abi.RootRequest.memory) };
    try abi.rt.root_ipc.call(&msg);
    log.info("got reply: {}", .{msg});

    const mem_cap: u32 = @truncate(abi.sys.getExtra(0));
    const memory = abi.caps.Memory{ .cap = mem_cap };

    const new_vmem = try memory.alloc(abi.caps.Vmem);
    _ = new_vmem;

    msg = .{ .arg0 = @intFromEnum(abi.RootRequest.pm) };
    var count: usize = 0;
    while (true) {
        try abi.rt.root_ipc.call(&msg);
        count += 1;
        if (count % 100_000 == 1)
            log.info("call done, count={}", .{count});
    }
}

comptime {
    abi.rt.install_rt();
}
