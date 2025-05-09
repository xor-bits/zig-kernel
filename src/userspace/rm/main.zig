const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.rm);
pub const std_options = abi.std_options;
pub const panic = abi.panic;
pub const name = "rm";
const Error = abi.sys.Error;

//

pub fn main() !void {
    log.info("hello from rm", .{});

    const root = abi.RootProtocol.Client().init(abi.rt.root_ipc);
    const vmem_handle = abi.rt.vmem_handle;

    log.debug("requesting memory", .{});
    var res: Error!void, const memory = try root.call(.memory, void{});
    try res;

    log.debug("requesting vm sender", .{});
    res, const vm_sender = try root.call(.serverSender, .{abi.ServerKind.vm});
    try res;

    log.debug("requesting ioport allocator", .{});
    res, const ioports = try root.call(.ioports, void{});
    try res;

    log.debug("requesting irq allocator", .{});
    res, const irqs = try root.call(.irqs, void{});
    try res;

    log.debug("requesting HPET", .{});
    res, const hpet_frame: caps.DeviceFrame = try root.call(.device, .{abi.Device.hpet});
    try res;

    // endpoint for rm server <-> unix app communication
    log.debug("allocating rm endpoint", .{});
    const rm_recv = try memory.alloc(caps.Receiver);
    const rm_send = try rm_recv.subscribe();

    const vm_client = abi.VmProtocol.Client().init(vm_sender);

    var system = System{
        .recv = rm_recv,
        .memory = memory,
        .ioports = ioports,
        .irqs = irqs,
        .root_endpoint = rm_send.cap,

        .vm_client = vm_client,
        .vmem_handle = vmem_handle,

        .hpet = hpet_frame,
    };

    const server = abi.RmProtocol.Server(.{
        .Context = *System,
        .scope = if (abi.conf.LOG_SERVERS) .rm else null,
    }, .{
        .requestPs2 = requestPs2Handler,
        .requestHpet = requestHpetHandler,
        .requestInterruptHandler = requestInterruptHandlerHandler,
        .newSender = newSenderHandler,
    }).init(&system, rm_recv);

    // inform the root that rm is ready
    log.debug("rm ready", .{});
    res, _ = try root.call(.serverReady, .{ abi.ServerKind.rm, rm_send });
    try res;

    try server.run();
}

const System = struct {
    recv: caps.Receiver,
    memory: caps.Memory,
    ioports: caps.X86IoPortAllocator,
    irqs: caps.X86IrqAllocator,
    root_endpoint: u32,

    vm_client: abi.VmProtocol.Client(),
    vmem_handle: usize,

    ps2: bool = true,
    hpet: ?caps.DeviceFrame = null,

    active_irqs: [256]?caps.X86Irq = .{null} ** 256,
};

fn requestPs2Handler(ctx: *System, _: u32, _: void) struct { Error!void, caps.X86IoPort, caps.X86IoPort } {
    if (!ctx.ps2) return .{ Error.PermissionDenied, .{}, .{} };

    const data = ctx.ioports.alloc(0x60) catch |err| return .{ err, .{}, .{} };
    const cmds = ctx.ioports.alloc(0x64) catch |err| return .{ err, .{}, .{} };

    ctx.ps2 = false;

    return .{ {}, data, cmds };
}

fn requestHpetHandler(ctx: *System, _: u32, _: void) struct { Error!void, caps.DeviceFrame, caps.X86IoPort } {
    const hpet = ctx.hpet orelse return .{ Error.PermissionDenied, .{}, .{} };
    const pit = ctx.ioports.alloc(0x43) catch |err| return .{ err, .{}, .{} };

    ctx.hpet = null;
    return .{ {}, hpet, pit };
}

fn requestInterruptHandlerHandler(ctx: *System, _: u32, req: struct { u8, caps.Notify }) struct { Error!void, caps.Notify } {
    const irq = req.@"0";
    const notify = req.@"1";
    // TODO: share the notify cap if one is already there
    const irq_cap = ctx.irqs.alloc(irq) catch |err| return .{ err, notify };
    irq_cap.subscribe(notify) catch |err| return .{ err, notify };

    return .{ {}, notify };
}

fn newSenderHandler(ctx: *System, sender: u32, _: void) struct { Error!void, caps.Sender } {
    if (ctx.root_endpoint != sender)
        return .{ Error.PermissionDenied, .{} };

    const rm_sender = ctx.recv.subscribe() catch |err| {
        log.err("failed to subscribe: {}", .{err});
        return .{ err, .{} };
    };

    return .{ void{}, rm_sender };
}

comptime {
    abi.rt.installRuntime();
}
