const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.pm);
pub const std_options = abi.std_options;
pub const panic = abi.panic;

//

pub fn main() !void {
    log.info("hello from pm", .{});

    const root = abi.rt.root_ipc;

    log.debug("requesting memory", .{});
    var msg: abi.sys.Message = .{ .arg0 = @intFromEnum(abi.RootRequest.memory) };
    try root.call(&msg);
    const memory = caps.Memory{ .cap = @truncate(abi.sys.getExtra(0)) };

    // endpoint for pm server <-> unix app communication
    log.debug("allocating pm endpoint", .{});
    const pm_recv = try memory.alloc(caps.Receiver);
    const pm_send = try pm_recv.subscribe();

    // inform the root that pm is ready
    msg = .{ .extra = 1, .arg0 = @intFromEnum(abi.RootRequest.pm_ready) };
    abi.sys.setExtra(0, pm_send.cap, true);
    try root.call(&msg);
    _ = try abi.sys.decode(msg.arg0);
}

comptime {
    abi.rt.install_rt();
}
