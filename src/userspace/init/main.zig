const std = @import("std");
const abi = @import("abi");

//

const log = std.log.scoped(.init);
pub const std_options = abi.std_options;
pub const panic = abi.panic;
pub const name = "init";

//

pub fn main() !void {
    log.info("hello from init", .{});

    const root = abi.RootProtocol.Client().init(abi.rt.root_ipc);

    const res, const sender = try root.call(.serverSender, .{abi.ServerKind.timer});
    try res;

    const timer = abi.TimerProtocol.Client().init(sender);

    log.info("waiting 5 seconds", .{});
    _ = try timer.call(.sleep, .{5_000_000_000});
    log.info("waiting done", .{});
}

comptime {
    abi.rt.installRuntime();
}
