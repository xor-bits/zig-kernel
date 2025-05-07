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
    var res: Error!void, const memory: caps.Memory = try root.call(.memory, void{});
    try res;

    // endpoint for pm server <-> unix app communication
    log.debug("allocating pm endpoint", .{});
    const pm_recv = try memory.alloc(caps.Receiver);
    const pm_send = try pm_recv.subscribe();

    // inform the root that pm is ready
    log.debug("pm ready", .{});
    res, const vmem_handle = try root.call(.pmReady, .{pm_send});
    try res;

    log.debug("requesting vm sender", .{});
    res, const vm_sender = try root.call(.vm, void{});
    try res;

    var system: System = .{
        .recv = pm_recv,
        .memory = memory,
        .root_endpoint = pm_send.cap,

        .vm_client = abi.VmProtocol.Client().init(vm_sender),
        .self_vmem_handle = vmem_handle,
    };

    const server = abi.PmProtocol.Server(.{
        .Context = *System,
        .scope = if (abi.conf.LOG_SERVERS) .vm else null,
    }, .{
        .newSender = newSenderHandler,
    }).init(&system, pm_recv);
    try server.run();
}

const System = struct {
    recv: caps.Receiver,
    memory: caps.Memory,
    root_endpoint: u32,

    vm_client: abi.VmProtocol.Client(),
    self_vmem_handle: usize,
};

fn newSenderHandler(ctx: *System, sender: u32, _: void) struct { Error!void, caps.Sender } {
    if (ctx.root_endpoint != sender)
        return .{ Error.PermissionDenied, .{} };

    const pm_sender = ctx.recv.subscribe() catch |err| {
        log.err("failed to subscribe: {}", .{err});
        return .{ err, .{} };
    };

    return .{ void{}, pm_sender };
}

comptime {
    abi.rt.installRuntime();
}
