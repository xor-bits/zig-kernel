const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.rm);
pub const std_options = abi.std_options;
pub const panic = abi.panic;
pub const name = "rm";
const Error = abi.sys.Error;
pub const log_level = .info;

//

pub fn main() !void {
    log.info("hello from rm", .{});

    const root = abi.RootProtocol.Client().init(abi.rt.root_ipc);

    log.debug("requesting memory", .{});
    var res: Error!void, const memory = try root.call(.memory, void{});
    try res;

    log.debug("requesting vm sender", .{});
    res, const vm_sender = try root.call(.vm, void{});
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

    // inform the root that rm is ready
    log.debug("rm ready", .{});
    res, const self_vmem_handle = try root.call(.rmReady, .{rm_send});
    try res;

    const vm_client = abi.VmProtocol.Client().init(vm_sender);

    // log.debug("spawning keyboard thread", .{});
    // try spawn(&ps2.keyboardThread);

    // log.info("mapping HPET", .{});
    // res, const hpet_addr: usize, hpet_frame = try vm_client.call(.mapDeviceFrame, .{
    //     vmem_handle,
    //     hpet_frame,
    //     abi.sys.Rights{
    //         .writable = true,
    //     },
    //     abi.sys.MapFlags{
    //         .cache = .uncacheable,
    //     },
    // });
    // try res;

    // log.info("HPET mapped at 0x{x}", .{hpet_addr});
    // try hpet.init(hpet_addr);

    // log.debug("spawning HPET thread", .{});
    // try spawn(&hpet.hpetThread);

    // while (true) {
    //     hpet.hpetSpinWait(1_000_000);
    //     log.info("SEC", .{});
    // }

    var system = System{
        .recv = rm_recv,
        .memory = memory,
        .ioports = ioports,
        .irqs = irqs,
        .root_endpoint = rm_send.cap,

        .vm_client = vm_client,
        .self_vmem_handle = self_vmem_handle,

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
    try server.run();
}

const System = struct {
    recv: caps.Receiver,
    memory: caps.Memory,
    ioports: caps.X86IoPortAllocator,
    irqs: caps.X86IrqAllocator,
    root_endpoint: u32,

    vm_client: abi.VmProtocol.Client(),
    self_vmem_handle: usize,

    ps2: bool = false,
    hpet: ?caps.DeviceFrame = null,
};

fn requestPs2Handler(ctx: *System, _: u32, _: void) struct { Error!void, caps.X86IoPort, caps.X86IoPort } {
    if (!ctx.ps2) return .{ Error.PermissionDenied, .{}, .{} };
    ctx.ps2 = false;

    const data = ctx.ioports.alloc(0x60) catch |err| return .{ err, .{}, .{} };
    const cmds = ctx.ioports.alloc(0x64) catch |err| return .{ err, .{}, .{} };

    return .{ {}, data, cmds };
}

fn requestHpetHandler(ctx: *System, _: u32, _: void) struct { Error!void, caps.DeviceFrame } {
    const hpet = ctx.hpet orelse return .{ Error.PermissionDenied, .{} };
    ctx.hpet = null;
    return .{ {}, hpet };
}

fn requestInterruptHandlerHandler(ctx: *System, _: u32, req: struct { u8 }) struct { Error!void, caps.Notify } {
    const irq = req.@"0";
    // TODO: share the notify cap if one is already there
    const irq_cap = ctx.irqs.alloc(irq) catch |err| return .{ err, .{} };
    const notify = ctx.memory.alloc(caps.Notify) catch |err| return .{ err, .{} };
    irq_cap.subscribe(notify) catch |err| return .{ err, .{} };

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

// fn spawn(f: *const fn (self: caps.Thread) callconv(.SysV) noreturn) !void {
//     const res, const kb_thread: caps.Thread = try ctx.vm_client.call(.newThread, .{
//         vmem_handle,
//         @intFromPtr(f),
//         0,
//     });
//     try res;

//     var regs: abi.sys.ThreadRegs = undefined;
//     try kb_thread.readRegs(&regs);
//     regs.arg0 = kb_thread.cap;
//     try kb_thread.writeRegs(&regs);
//     try kb_thread.setPrio(0);
//     try kb_thread.start();
// }

comptime {
    abi.rt.installRuntime();
}
