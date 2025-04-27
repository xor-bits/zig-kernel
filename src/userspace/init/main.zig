const std = @import("std");
const abi = @import("abi");

//

const log = std.log.scoped(.init);
pub const std_options = abi.std_options;
pub const panic = abi.panic;

//

pub fn main() !void {
    log.info("hello from init", .{});
}

comptime {
    abi.rt.install_rt();
}
