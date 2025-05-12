const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.input);
pub const std_options = abi.std_options;
pub const panic = abi.panic;
pub const name = "input";
const Error = abi.sys.Error;

//

pub fn main() !void {
    log.info("hello from input", .{});

    const root = abi.RootProtocol.Client().init(abi.rt.root_ipc);
    const vm_client = abi.VmProtocol.Client().init(abi.rt.vm_ipc);

    log.debug("requesting memory", .{});
    var res: Error!void, const memory: caps.Memory = try root.call(.memory, {});
    try res;

    // endpoint for root,unix app <-> input communication
    log.debug("allocating input endpoint", .{});
    const input_recv = try memory.alloc(caps.Receiver);
    const input_send = try input_recv.subscribe();

    // log.debug("requesting rm sender", .{});
    // res, const rm_sender = try root.call(.rm, {});
    // try res;
    // const rm_client = abi.RmProtocol.Client().init(rm_sender);

    log.debug("requesting vm sender for ps2", .{});
    res, const vm_ps2_sender = try root.call(.serverSender, .{.vm});
    try res;

    log.debug("requesting rm sender for ps2", .{});
    res, const rm_ps2_sender = try root.call(.serverSender, .{.rm});
    try res;

    log.debug("requesting initfs sender", .{});
    res, const initfs_sender = try root.call(.initfs, {});
    try res;
    const initfs_client = abi.InitfsProtocol.Client().init(initfs_sender);

    log.debug("reading ps2 server ELF", .{});
    res, const ps2_elf_len = try initfs_client.call(.fileSize, .{("/sbin/ps2" ++ .{0} ** 23).*});
    try res;
    const ps2_elf_frame = try memory.allocSized(caps.Frame, abi.ChunkSize.of(ps2_elf_len) orelse return Error.OutOfMemory);
    res, _ = try initfs_client.call(.openFile, .{ ("/sbin/ps2" ++ .{0} ** 23).*, ps2_elf_frame });
    try res;

    log.debug("creating ps2 endpoint", .{});
    const ps2_recv = try memory.alloc(caps.Receiver);
    const ps2_send = try ps2_recv.subscribe();
    const ps2_client = abi.Ps2Protocol.Client().init(ps2_send);

    log.debug("creating ps2 server", .{});
    res, const ps2_vmem_handle: usize = try vm_client.call(.newVmem, {});
    try res;
    res, _ = try vm_client.call(.loadElf, .{
        ps2_vmem_handle,
        ps2_elf_frame,
        0,
        ps2_elf_len,
    });
    try res;
    res, const ps2_thread: caps.Thread = try vm_client.call(.newThread, .{ ps2_vmem_handle, 0, 0 });
    try res;
    const ps2_notify = try memory.alloc(caps.Notify);

    log.debug("giving ps2 vmem handle to ps2 server", .{});
    res, _ = try vm_client.call(.moveOwner, .{ ps2_vmem_handle, vm_ps2_sender.cap });
    try res;

    log.debug("starting ps2 server", .{});
    try ps2_thread.transferCap(ps2_recv.cap);
    try ps2_thread.transferCap(vm_ps2_sender.cap);
    try ps2_thread.transferCap(rm_ps2_sender.cap);
    try ps2_thread.transferCap(ps2_notify.cap);
    var regs: abi.sys.ThreadRegs = undefined;
    try ps2_thread.readRegs(&regs);
    regs.arg0 = ps2_recv.cap;
    regs.arg1 = vm_ps2_sender.cap;
    regs.arg2 = rm_ps2_sender.cap;
    regs.arg3 = ps2_notify.cap;
    regs.arg4 = ps2_vmem_handle;
    try ps2_thread.writeRegs(&regs);
    try ps2_thread.setPrio(0);
    try ps2_thread.start();

    // inform the root that input is ready
    log.debug("input ready", .{});
    res, _ = try root.call(.serverReady, .{ abi.ServerKind.input, input_send });
    try res;

    var system: System = .{
        .recv = input_recv,
        .ps2_client = ps2_client,
        .root_endpoint = input_send.cap,
    };

    const server = abi.InputProtocol.Server(.{
        .Context = *System,
        .scope = if (abi.conf.LOG_SERVERS) .input else null,
    }, .{
        .nextKey = nextKeyHandler,
        .newSender = newSenderHandler,
    }).init(&system, input_recv);

    log.debug("input init done, server listening", .{});
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
    ps2_client: abi.Ps2Protocol.Client(),
    root_endpoint: u32,
};

fn nextKeyHandler(ctx: *System, _: u32, _: void) struct { Error!void, abi.input.KeyCode, abi.input.KeyState } {
    // no reply, the ps2 interrupt handler sends replies
    const reply = ctx.recv.saveCaller() catch |err| {
        log.warn("could not save caller: {}", .{err});
        return .{ {}, .too_many_keys, .single };
    };
    // TODO: non-blocking call
    ctx.no_reply = true;
    _ = ctx.ps2_client.call(.nextKey, .{reply}) catch |err| {
        log.warn("call to ps2 server failed: {}", .{err});
        return .{ {}, .too_many_keys, .single };
    };
    return .{ {}, .too_many_keys, .single };
}

fn newSenderHandler(ctx: *System, sender: u32, _: void) struct { Error!void, caps.Sender } {
    log.info("input newSender req", .{});
    if (ctx.root_endpoint != sender)
        return .{ Error.PermissionDenied, .{} };

    const input_sender = ctx.recv.subscribe() catch |err| {
        log.err("failed to subscribe: {}", .{err});
        return .{ err, .{} };
    };

    return .{ {}, input_sender };
}

comptime {
    abi.rt.installRuntime();
}
