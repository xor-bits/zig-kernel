const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.vm);
pub const std_options = abi.std_options;
pub const panic = abi.panic;

//

pub fn main() !void {
    log.info("hello from pm", .{});
}

comptime {
    abi.rt.install_rt();
}
