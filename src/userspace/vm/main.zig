const std = @import("std");
const abi = @import("abi");

//

const log = std.log.scoped(.init);
pub const std_options = abi.std_options;
pub const panic = abi.panic;

//

pub fn main() !void {
    log.info("hello from vm", .{});

    var msg: abi.sys.Message = .{ .arg2 = 5 };
    try abi.rt.root_ipc.call(&msg);

    log.info("got reply: {}", .{msg});
}

comptime {
    abi.rt.install_rt();
}
