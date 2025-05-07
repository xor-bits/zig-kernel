const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.vfs);
pub const std_options = abi.std_options;
pub const panic = abi.panic;
pub const name = "vfs";
const Error = abi.sys.Error;

//

pub fn main() !void {
    log.info("hello from vfs", .{});

    const root = abi.RootProtocol.Client().init(abi.rt.root_ipc);

    log.debug("requesting memory", .{});
    var res: Error!void, const memory: caps.Memory = try root.call(.memory, void{});
    try res;

    // endpoint for vfs server <-> unix app communication
    log.debug("allocating vfs endpoint", .{});
    const vfs_recv = try memory.alloc(caps.Receiver);
    const vfs_send = try vfs_recv.subscribe();

    // inform the root that vfs is ready
    log.debug("vfs ready", .{});
    res, const vm_sender = try root.call(.serverReady, .{ abi.ServerKind.vfs, vfs_send });
    try res;

    _ = vm_sender;

    // const server = abi.vfsProtocol.Server(.{}).init(vfs_recv);
    // try server.run();
}

comptime {
    abi.rt.installRuntime();
}
