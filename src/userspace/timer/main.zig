const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

pub const std_options = abi.std_options;
pub const panic = abi.panic;

const log = std.log.scoped(.timer);
const Error = abi.sys.Error;

//

pub fn main() !void {
    log.info("hello from timer", .{});

    const root = abi.RootProtocol.Client().init(abi.rt.root_ipc);
    const vmem_handle = abi.rt.vmem_handle;

    log.debug("requesting memory", .{});
    var res: Error!void, const memory: caps.Memory = try root.call(.memory, {});
    try res;

    // endpoint for timer server <-> unix app communication
    log.debug("allocating timer endpoint", .{});
    const timer_recv = try memory.alloc(caps.Receiver);
    const timer_send = try timer_recv.subscribe();

    log.debug("requesting vm sender", .{});
    res, const vm_sender = try root.call(.serverSender, .{abi.ServerKind.vm});
    try res;
    const vm_client = abi.VmProtocol.Client().init(vm_sender);

    // log.debug("requesting rm sender", .{});
    // res, const rm_sender = try root.call(.rm, {});
    // try res;
    // const rm_client = abi.RmProtocol.Client().init(rm_sender);

    log.debug("requesting vm sender for HPET", .{});
    res, const vm_hpet_sender = try root.call(.serverSender, .{abi.ServerKind.vm});
    try res;

    log.debug("requesting rm sender for HPET", .{});
    res, const rm_hpet_sender = try root.call(.serverSender, .{abi.ServerKind.rm});
    try res;

    log.debug("requesting initfs sender", .{});
    res, const initfs_sender = try root.call(.initfs, {});
    try res;
    const initfs_client = abi.InitfsProtocol.Client().init(initfs_sender);

    log.debug("reading HPET server ELF", .{});
    res, const hpet_elf_len = try initfs_client.call(.fileSize, .{("/sbin/hpet" ++ .{0} ** 22).*});
    try res;
    const hpet_elf_frame = try memory.allocSized(caps.Frame, abi.ChunkSize.of(hpet_elf_len) orelse return Error.OutOfMemory);
    res, _ = try initfs_client.call(.openFile, .{ ("/sbin/hpet" ++ .{0} ** 22).*, hpet_elf_frame });
    try res;

    log.debug("creating timer endpoint", .{});
    const hpet_recv = try memory.alloc(caps.Receiver);
    const hpet_send = try hpet_recv.subscribe();
    const hpet_client = abi.HpetProtocol.Client().init(hpet_send);

    log.debug("creating HPET server", .{});
    res, const hpet_vmem_handle: usize = try vm_client.call(.newVmem, {});
    try res;
    res, _ = try vm_client.call(.loadElf, .{
        hpet_vmem_handle,
        hpet_elf_frame,
        0,
        hpet_elf_len,
    });
    try res;
    res, const hpet_thread: caps.Thread = try vm_client.call(.newThread, .{ hpet_vmem_handle, 0, 0 });
    try res;
    const hpet_notify = try memory.alloc(caps.Notify);

    log.debug("giving HPET vmem handle to HPET server", .{});
    res, _ = try vm_client.call(.moveOwner, .{ hpet_vmem_handle, vm_hpet_sender.cap });
    try res;

    log.debug("starting HPET server", .{});
    try hpet_thread.transferCap(hpet_recv.cap);
    try hpet_thread.transferCap(vm_hpet_sender.cap);
    try hpet_thread.transferCap(rm_hpet_sender.cap);
    try hpet_thread.transferCap(hpet_notify.cap);
    var regs: abi.sys.ThreadRegs = undefined;
    try hpet_thread.readRegs(&regs);
    regs.arg0 = hpet_recv.cap;
    regs.arg1 = vm_hpet_sender.cap;
    regs.arg2 = rm_hpet_sender.cap;
    regs.arg3 = hpet_notify.cap;
    regs.arg4 = hpet_vmem_handle;
    try hpet_thread.writeRegs(&regs);
    try hpet_thread.setPrio(0);
    try hpet_thread.start();

    var system: System = .{
        .recv = timer_recv,
        .memory = memory,
        .root_endpoint = timer_send.cap,

        .vm_client = abi.VmProtocol.Client().init(vm_sender),
        .self_vmem_handle = vmem_handle,

        .hpet_client = hpet_client,
    };

    const server = abi.TimerProtocol.Server(.{
        .Context = *System,
        .scope = if (abi.conf.LOG_SERVERS) .timer else null,
    }, .{
        .timestamp = timestampHandler,
        .sleep = sleepHandler,
        .sleepDeadline = sleepDeadlineHandler,
        .newSender = newSenderHandler,
    }).init(&system, timer_recv);

    // inform the root that timer is ready
    log.debug("timer ready", .{});
    res, _ = try root.call(.serverReady, .{ abi.ServerKind.timer, timer_send });
    try res;

    log.debug("timer init done, server listening", .{});
    var msg: abi.sys.Message = undefined;
    try server.rx.recv(&msg);
    while (true) {
        server.process(&msg);
        if (server.ctx.no_reply)
            try server.rx.recv(&msg)
        else
            try server.rx.replyRecv(&msg);
    }
}

const System = struct {
    no_reply: bool = false,

    recv: caps.Receiver,
    memory: caps.Memory,
    root_endpoint: u32,

    vm_client: abi.VmProtocol.Client(),
    self_vmem_handle: usize,

    hpet_client: abi.HpetProtocol.Client(),
};

fn timestampHandler(ctx: *System, _: u32, _: void) struct { u128 } {
    const time = ctx.hpet_client.call(.timestamp, {}) catch |err| {
        log.warn("call to HPET server failed: {}", .{err});
        return .{0};
    };
    return time;
}

fn sleepHandler(ctx: *System, _: u32, req: struct { u128 }) struct { void } {
    // no reply, the hpet interrupt handler sends replies
    const reply = ctx.recv.saveCaller() catch |err| {
        log.warn("could not save caller: {}", .{err});
        return .{{}};
    };
    // TODO: non-blocking call
    ctx.no_reply = true;
    _ = ctx.hpet_client.call(.sleep, .{ req.@"0", reply }) catch |err| {
        log.warn("call to HPET server failed: {}", .{err});
        return .{{}};
    };
    return .{{}};
}

fn sleepDeadlineHandler(ctx: *System, _: u32, req: struct { u128 }) struct { void } {
    // no reply, the hpet interrupt handler sends replies
    const reply = ctx.recv.saveCaller() catch |err| {
        log.warn("could not save caller: {}", .{err});
        return .{{}};
    };
    // TODO: non-blocking call
    ctx.no_reply = true;
    _ = ctx.hpet_client.call(.sleepDeadline, .{ req.@"0", reply }) catch |err| {
        log.warn("call to HPET server failed: {}", .{err});
        return .{{}};
    };
    return .{{}};
}

fn newSenderHandler(ctx: *System, sender: u32, _: void) struct { Error!void, caps.Sender } {
    log.info("timer newSender req", .{});
    if (ctx.root_endpoint != sender)
        return .{ Error.PermissionDenied, .{} };

    const timer_sender = ctx.recv.subscribe() catch |err| {
        log.err("failed to subscribe: {}", .{err});
        return .{ err, .{} };
    };

    return .{ {}, timer_sender };
}

comptime {
    abi.rt.installRuntime();
}
