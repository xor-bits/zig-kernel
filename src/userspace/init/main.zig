const std = @import("std");
const abi = @import("abi");

const spinner = @import("spinner.zig");

//

const caps = abi.caps;
const log = std.log.scoped(.init);
pub const std_options = abi.std_options;
pub const panic = abi.panic;
pub const name = "init";

//

// pub var vm: abi.VmProtocol.Client() = undefined;
pub var rm: abi.RmProtocol.Client() = undefined;
pub var pm: abi.PmProtocol.Client() = undefined;
pub var timer: abi.TimerProtocol.Client() = undefined;
pub var root: abi.RootProtocol.Client() = undefined;

//

pub fn main() !void {
    log.info("hello from init", .{});

    root = abi.RootProtocol.Client().init(abi.rt.root_ipc);
    pm = abi.PmProtocol.Client().init(.{ .cap = @truncate(abi.rt.vmem_handle) });

    var res, var sender: caps.Sender = try root.call(.serverSender, .{abi.ServerKind.timer});
    try res;
    timer = abi.TimerProtocol.Client().init(sender);

    res, sender = try root.call(.serverSender, .{abi.ServerKind.rm});
    try res;
    rm = abi.RmProtocol.Client().init(sender);

    try spinner.spinnerMain();
}

comptime {
    abi.rt.installRuntime();
}
