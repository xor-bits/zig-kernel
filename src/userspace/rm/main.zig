const std = @import("std");
const abi = @import("abi");

const hpet = @import("hpet.zig");
const ps2 = @import("ps2.zig");

const caps = abi.caps;

//

const log = std.log.scoped(.rm);
pub const std_options = abi.std_options;
pub const panic = abi.panic;
pub const name = "rm";
const Error = abi.sys.Error;
pub const log_level = .info;

pub var memory: caps.Memory = .{};
pub var ioports: caps.X86IoPortAllocator = .{};
pub var irqs: caps.X86IrqAllocator = .{};

pub var vm_client: abi.VmProtocol.Client() = undefined;
pub var vmem_handle: usize = 0;

//

pub fn main() !void {
    log.info("hello from rm", .{});

    const root = abi.RootProtocol.Client().init(abi.rt.root_ipc);

    log.debug("requesting memory", .{});
    var res: Error!void, memory = try root.call(.memory, void{});
    try res;

    log.debug("requesting vm sender", .{});
    res, const vm_sender = try root.call(.vm, void{});
    try res;

    log.debug("requesting ioport allocator", .{});
    res, ioports = try root.call(.ioports, void{});
    try res;

    log.debug("requesting irq allocator", .{});
    res, irqs = try root.call(.irqs, void{});
    try res;

    log.debug("requesting HPET", .{});
    res, var hpet_frame: caps.Frame = try root.call(.device, .{abi.Device.hpet});
    try res;

    // endpoint for rm server <-> unix app communication
    log.debug("allocating rm endpoint", .{});
    const rm_recv = try memory.alloc(caps.Receiver);
    const rm_send = try rm_recv.subscribe();

    // inform the root that rm is ready
    log.debug("rm ready", .{});
    res, vmem_handle = try root.call(.rmReady, .{rm_send});
    try res;

    vm_client = abi.VmProtocol.Client().init(vm_sender);

    log.debug("spawning keyboard thread", .{});
    try spawn(&ps2.keyboardThread);

    log.info("mapping HPET", .{});
    res, const hpet_addr: usize, hpet_frame = try vm_client.call(.mapFrame, .{
        vmem_handle,
        hpet_frame,
        abi.sys.Rights{
            .writable = true,
        },
        abi.sys.MapFlags{
            .cache = .uncacheable,
        },
    });

    log.info("HPET mapped at 0x{x}", .{hpet_addr});
    try hpet.init(hpet_addr);

    log.debug("spawning HPET thread", .{});
    try spawn(&hpet.hpetThread);

    while (true) {
        hpet.hpetSpinWait(1_000_000);
        log.info("SEC", .{});
    }

    // const server = abi.RmProtocol.Server(.{}).init(rm_recv);
    // try server.run();
}

fn spawn(f: *const fn (self: caps.Thread) callconv(.SysV) noreturn) !void {
    const res, const kb_thread: caps.Thread = try vm_client.call(.newThread, .{
        vmem_handle,
        @intFromPtr(f),
        0,
    });
    try res;

    var regs: abi.sys.ThreadRegs = undefined;
    try kb_thread.readRegs(&regs);
    regs.arg0 = kb_thread.cap;
    try kb_thread.writeRegs(&regs);
    try kb_thread.setPrio(0);
    try kb_thread.start();
}

comptime {
    abi.rt.installRuntime();
}
