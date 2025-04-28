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

    log.info("vm waiting for messages", .{});
    try vm_recv.recv(&msg);
    while (true) {
        log.info("got a msg {}", .{msg});
        msg.extra = 0;
        try vm_recv.replyRecv(&msg);
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
