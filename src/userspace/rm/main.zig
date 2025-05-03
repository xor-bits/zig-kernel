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

    log.debug("requesting memory", .{});
    const res0: Error!void, const memory: caps.Memory = try root.call(.memory, void{});
    try res0;

    log.debug("requesting ioport allocator", .{});
    const res1: Error!void, const ioports: caps.X86IoPortAllocator = try root.call(.ioports, void{});
    try res1;

    log.debug("requesting irq allocator", .{});
    const res2: Error!void, const irqs: caps.X86IrqAllocator = try root.call(.irqs, void{});
    try res2;

    // endpoint for rm server <-> unix app communication
    log.debug("allocating rm endpoint", .{});
    const rm_recv = try memory.alloc(caps.Receiver);
    const rm_send = try rm_recv.subscribe();

    // inform the root that rm is ready
    log.debug("rm ready", .{});
    const res3: struct { Error!void } = try root.call(.rmReady, .{rm_send});
    try res3.@"0";

    const kb_port_data = try ioports.alloc(0x60);
    const kb_port_status = try ioports.alloc(0x64);
    const kb_irq = try irqs.alloc(1);
    const kb_irq_notify = try memory.alloc(caps.Notify);

    try kb_irq.subscribe(kb_irq_notify);

    while (true) {
        log.info("waiting for keyboard interrupt", .{});
        _ = try kb_irq_notify.wait();

        while (try kb_port_status.inb() & 0b1 == 1) {
            const inb = try kb_port_data.inb();
            log.info("keyboard: 0b{b:0>8}", .{inb});
        }
    }

    // const server = abi.RmProtocol.Server(.{}).init(rm_recv);
    // try server.run();
}

comptime {
    abi.rt.installRuntime();
}
