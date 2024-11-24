const std = @import("std");
const abi = @import("abi");

//

const log = std.log.scoped(.bootstrap);
pub const std_options = abi.std_options;
pub const panic = abi.panic;

//

export fn _start() linksection(".text._start") callconv(.C) noreturn {
    log.info("hello from init", .{});
    while (true) {}
}
