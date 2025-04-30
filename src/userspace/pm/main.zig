const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.pm);
pub const std_options = abi.std_options;
pub const panic = abi.panic;
pub const name = "pm";
const Error = abi.sys.Error;

//

pub fn main() !void {
    log.info("hello from pm", .{});

    const root = abi.RootProtocol.Client().init(abi.rt.root_ipc);

    log.debug("requesting memory", .{});
    const res0: Error!void, const memory: caps.Memory = try root.call(.memory, void{});
    try res0;

    // endpoint for pm server <-> unix app communication
    log.debug("allocating pm endpoint", .{});
    const pm_recv = try memory.alloc(caps.Receiver);
    const pm_send = try pm_recv.subscribe();

    // inform the root that pm is ready
    log.debug("pm ready", .{});
    const res2: struct { Error!void } = try root.call(.pmReady, .{pm_send});
    try res2.@"0";

    // const server = abi.PmProtocol.Server(.{}).init(pm_recv);
    // try server.run();
}

comptime {
    abi.rt.install_rt();
}
