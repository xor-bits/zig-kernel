const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.vm);
pub const std_options = abi.std_options;
pub const panic = abi.panic;

//

pub fn main() !void {
    log.info("hello from vm", .{});

    const root = abi.rt.root_ipc;

    var msg: abi.sys.Message = .{ .arg0 = @intFromEnum(abi.RootRequest.memory) };
    try root.call(&msg);
    log.info("got reply: {}", .{msg});

    const mem_cap: u32 = @truncate(abi.sys.getExtra(0));
    const memory = caps.Memory{ .cap = mem_cap };

    // endpoint for pm server <-> vm server communication
    const vm_recv = try memory.alloc(caps.Receiver);
    const vm_send = try vm_recv.subscribe();

    // inform the root that vm is ready
    msg = .{ .extra = 1, .arg0 = @intFromEnum(abi.RootRequest.vm_ready) };
    abi.sys.setExtra(0, vm_send.cap, true);
    try root.call(&msg);
    _ = try abi.sys.decode(msg.arg0);

    // TODO: install page fault handlers

    // benchmarkIpc();

    var system: System = .{
        .memory = memory,
    };

    log.info("vm waiting for messages", .{});
    try vm_recv.recv(&msg);
    while (true) {
        processRequest(&system, &msg);
        try vm_recv.replyRecv(&msg);
    }
}

const System = struct {
    memory: caps.Memory,
    address_spaces: [256]?AddressSpace = .{null} ** 256,
};

const AddressSpace = struct {
    owner: u32, // cap id of the sender
    vmem: caps.Vmem,
    // all frame caps mapped to the vmem, sorted by address
    // used for finding empty slots and whatever
    // memory: []caps.Frame
};

fn processRequest(system: *System, msg: *abi.sys.Message) void {
    const req = std.meta.intToEnum(abi.VmRequest, msg.arg0) catch {
        msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
        msg.extra = 0;
        return;
    };

    log.info("vm got {}", .{req});

    switch (req) {
        .new_vmem => {
            if (msg.extra != 0) {
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                msg.extra = 0;
                return;
            }

            for (&system.address_spaces, 0..) |*entry, i| {
                if (entry.* != null) continue;

                const vmem = system.memory.alloc(caps.Vmem) catch |err| {
                    // FIXME: vm server is responsible for OOMs
                    std.debug.panic("vmem OOM: {}", .{err});
                };

                entry.* = .{
                    .owner = msg.cap,
                    .vmem = vmem,
                };

                msg.arg0 = abi.sys.encode(i);
                return;
            }
        },
        .load_elf => {
            if (msg.extra != 1) {
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                msg.extra = 0;
                return;
            }
            msg.extra = 0;

            // FIXME: verify that it is a cap and not raw data
            const frame_cap: u32 = @truncate(abi.sys.getExtra(0));

            const ty = abi.sys.debug(frame_cap) catch |err| {
                msg.arg0 = abi.sys.encode(err);
                return;
            };
            if (ty != .frame) {
                abi.sys.setExtra(0, frame_cap, true);
                msg.extra = 1;
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                return;
            }

            const frame = abi.caps.Frame{ .cap = frame_cap };
            const offset = msg.arg1;
            const length = msg.arg2;

            log.info("got ELF to load {}", .{.{ frame, offset, length }});

            msg.arg0 = abi.sys.encode(0);
        },
        .new_thread => {
            if (msg.extra != 0) {
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                msg.extra = 0;
                return;
            }

            const handle = msg.arg1;
            if (handle >= 256) {
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                return;
            }
            const addr_spc = &(system.address_spaces[handle] orelse {
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                return;
            });
            if (addr_spc.owner != msg.cap) {
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                return;
            }

            const thread = system.memory.alloc(caps.Thread) catch |err| {
                std.debug.panic("vmem OOM: {}", .{err});
            };
            thread.setVmem(addr_spc.vmem) catch |err| {
                std.debug.panic("new thread cant be running: {}", .{err});
            };

            abi.sys.setExtra(0, thread.cap, true);
            msg.extra = 1;
            msg.arg0 = abi.sys.encode(0);
            return;
        },
    }
}

fn benchmarkIpc() !void {
    var msg: abi.sys.Message = .{ .arg0 = @intFromEnum(abi.RootRequest.pm) };
    var count: usize = 0;
    while (true) {
        try abi.rt.root_ipc.call(&msg);
        count += 1;
        if (count % 100_000 == 1)
            log.info("call done, count={}", .{count});
    }
}

comptime {
    abi.rt.install_rt();
}
