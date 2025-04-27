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
    const memory = abi.caps.Memory{ .cap = @truncate(try abi.sys.decode(msg.arg0)) };

    const new_vmem = try memory.alloc(abi.caps.Vmem);
    _ = new_vmem;
}

comptime {
    abi.rt.install_rt();
}
