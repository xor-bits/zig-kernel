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

pub export var manifest: Manifest = .{
    .magic = .{
        0x5b9061e5c940d983,
        0xc47d27b79d2c8bb9,
        0x40299f5bb0c53988,
        0x3e49068027c442fb,
    },
    .name = ("root" ++ .{'\x00'} ** 60).*,
};

pub const Manifest = extern struct {
    magic: [4]u64,
    name: [64]u8,
};

//

pub fn main() !void {
    log.info("hello from pm", .{});

    const root = abi.RootProtocol.Client().init(abi.rt.root_ipc);
    const vm_client = abi.VmProtocol.Client().init(abi.rt.vm_ipc);
    const vmem_handle = abi.rt.vmem_handle;

    log.debug("requesting memory", .{});
    var res: Error!void, const memory: caps.Memory = try root.call(.memory, {});
    try res;

    // endpoint for pm server <-> unix app communication
    log.debug("allocating pm endpoint", .{});
    const pm_recv = try caps.Receiver.create();
    const pm_send = try pm_recv.subscribe();

    log.debug("requesting initfs sender", .{});
    res, const initfs_sender: caps.Sender = try root.call(.initfs, {});
    try res;
    const initfs_client = abi.InitfsProtocol.Client().init(initfs_sender);

    log.debug("opening init ELF", .{});
    res, const init_elf_len: usize = try initfs_client.call(.fileSize, .{("/sbin/init" ++ .{0} ** 22).*});
    try res;
    const init_elf_frame: caps.Frame = try memory.allocSized(caps.Frame, abi.ChunkSize.of(init_elf_len) orelse return Error.OutOfMemory);
    res, _ = try initfs_client.call(.openFile, .{ ("/sbin/init" ++ .{0} ** 22).*, init_elf_frame });
    try res;

    // init (normal) (process)
    // all the critial system servers are running, so now "normal" Linux-like init can run
    // gets a Sender capability to access the initfs part of this root process
    // just runs normal processes according to the init configuration
    // launches stuff like the window manager and virtual TTYs
    log.debug("creating init process", .{});
    res, const init_vmem_handle: usize = try vm_client.call(.newVmem, {});
    try res;
    res, _ = try vm_client.call(.loadElf, .{ init_vmem_handle, init_elf_frame, 0, init_elf_len });
    try res;
    res, const init_thread: caps.Thread = try vm_client.call(.newThread, .{ init_vmem_handle, 0, 0 });
    try res;

    log.debug("requesting root sender for init", .{});
    res, const init_root_sender: caps.Sender = try root.call(.newSender, {});
    try res;

    const init_send: caps.Sender = try pm_recv.subscribe();

    log.debug("starting init process", .{});
    var regs: abi.sys.ThreadRegs = undefined;
    try init_thread.transferCap(init_root_sender.cap);
    try init_thread.transferCap(init_send.cap);
    try init_thread.setPrio(0);
    try init_thread.readRegs(&regs);
    regs.arg0 = init_root_sender.cap;
    regs.arg2 = init_send.cap;
    try init_thread.writeRegs(&regs);
    try init_thread.start();

    var system: System = .{
        .recv = pm_recv,
        .memory = memory,
        .root_endpoint = pm_send.cap,

        .vm_client = vm_client,
        .self_vmem_handle = vmem_handle,
    };

    system.processes[1] = Process{
        .pm_endpoint = init_send.cap,
        .vmem_handle = init_vmem_handle,
        .main_thread = init_thread,
    };

    const server = abi.PmProtocol.Server(.{
        .Context = *System,
        .scope = if (abi.conf.LOG_SERVERS) .vm else null,
    }, .{
        .spawn = spawnHandler,
        .growHeap = growHeapHandler,
        .mapFrame = mapFrameHandler,
        .mapDeviceFrame = mapDeviceFrameHandler,
        .newSender = newSenderHandler,
    }).init(&system, pm_recv);

    // inform the root that pm is ready
    log.debug("pm ready", .{});
    res, _ = try root.call(.serverReady, .{ abi.ServerKind.pm, pm_send });
    try res;

    try server.run();
}

const System = struct {
    recv: caps.Receiver,
    memory: caps.Memory,
    root_endpoint: u32,

    vm_client: abi.VmProtocol.Client(),
    self_vmem_handle: usize,

    processes: [256]?Process = .{null} ** 256,
};

const Process = struct {
    pm_endpoint: u32,
    vmem_handle: usize,
    main_thread: caps.Thread,
};

fn spawnHandler(ctx: *System, sender: u32, req: struct { usize, usize }) struct { Error!void, caps.Thread } {
    const ip_override = req.@"0";
    const sp_override = req.@"1";

    for (ctx.processes[1..]) |proc| {
        const process = proc orelse continue;
        if (process.pm_endpoint != sender) continue;

        const res, const thread = ctx.vm_client.call(.newThread, .{
            process.vmem_handle,
            ip_override,
            sp_override,
        }) catch |err| {
            log.err("failed to spawn a thread: {}", .{err});
            return .{ Error.Internal, .{} };
        };
        res catch |err| {
            log.err("failed to spawn a thread: {}", .{err});
            return .{ Error.Internal, .{} };
        };

        return .{ {}, thread };
    }

    return .{ Error.PermissionDenied, .{} };
}

fn growHeapHandler(ctx: *System, sender: u32, req: struct { usize }) struct { Error!void, usize } {
    const by = req.@"0";
    for (ctx.processes[1..]) |proc| {
        const process = proc orelse continue;
        if (process.pm_endpoint != sender) continue;

        const res, const addr = ctx.vm_client.call(.mapAnon, .{
            process.vmem_handle,
            by,
            abi.sys.Rights{ .writable = true },
            abi.sys.MapFlags{},
        }) catch |err| {
            log.err("failed to grow heap: {}", .{err});
            return .{ Error.Internal, 0 };
        };
        res catch |err| {
            log.err("failed to grow heap: {}", .{err});
            return .{ Error.Internal, 0 };
        };

        return .{ {}, addr };
    }

    return .{ Error.PermissionDenied, 0 };
}

fn mapFrameHandler(
    ctx: *System,
    sender: u32,
    req: struct { caps.Frame, abi.sys.Rights, abi.sys.MapFlags },
) struct { Error!void, usize, caps.Frame } {
    const frame = req.@"0";
    const rights = req.@"1";
    const flags = req.@"2";

    // TODO: give each sender some id that the sender itself cannot change
    for (ctx.processes[1..]) |proc| {
        const process = proc orelse continue;
        if (process.pm_endpoint != sender) continue;

        const res, const addr, _ = ctx.vm_client.call(.mapFrame, .{
            process.vmem_handle,
            frame,
            rights,
            flags,
        }) catch |err| {
            log.err("failed to map a frame: {}", .{err});
            return .{ Error.Internal, 0, frame };
        };
        res catch |err| {
            log.err("failed to map a frame: {}", .{err});
            return .{ Error.Internal, 0, frame };
        };

        return .{ {}, addr, .{} };
    }

    return .{ Error.PermissionDenied, 0, frame };
}

fn mapDeviceFrameHandler(
    ctx: *System,
    sender: u32,
    req: struct { caps.DeviceFrame, abi.sys.Rights, abi.sys.MapFlags },
) struct { Error!void, usize, caps.DeviceFrame } {
    const frame = req.@"0";
    const rights = req.@"1";
    const flags = req.@"2";

    // TODO: give each sender some id that the sender itself cannot change
    for (ctx.processes[1..]) |proc| {
        const process = proc orelse continue;
        if (process.pm_endpoint != sender) continue;

        const res, const addr, _ = ctx.vm_client.call(.mapDeviceFrame, .{
            process.vmem_handle,
            frame,
            rights,
            flags,
        }) catch |err| {
            log.err("failed to map a device frame: {}", .{err});
            return .{ Error.Internal, 0, frame };
        };
        res catch |err| {
            log.err("failed to map a device frame: {}", .{err});
            return .{ Error.Internal, 0, frame };
        };

        return .{ {}, addr, .{} };
    }

    return .{ Error.PermissionDenied, 0, frame };
}

fn newSenderHandler(ctx: *System, sender: u32, _: void) struct { Error!void, caps.Sender } {
    if (ctx.root_endpoint != sender)
        return .{ Error.PermissionDenied, .{} };

    const pm_sender = ctx.recv.subscribe() catch |err| {
        log.err("failed to subscribe: {}", .{err});
        return .{ err, .{} };
    };

    return .{ {}, pm_sender };
}

comptime {
    // abi.rt.installRuntime();
}
