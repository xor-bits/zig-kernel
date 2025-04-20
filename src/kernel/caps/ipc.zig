const std = @import("std");
const abi = @import("abi");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const proc = @import("../proc.zig");

const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const Receiver = struct {
    receiver: std.atomic.Value(?*caps.Thread) = .init(null),
    sender: std.atomic.Value(?*caps.Thread) = .init(null),

    pub fn init(self: *@This()) void {
        self.* = .{};
    }

    pub fn canAlloc() bool {
        return true;
    }

    pub fn call(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!usize {
        const call_id = std.meta.intToEnum(abi.sys.ReceiverCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (caps.LOG_OBJ_CALLS)
            log.debug("receiver call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .subscribe => {
                const sender = caps.Ref(Sender){ .paddr = paddr };
                return caps.push_capability(sender.object(thread));
            },
        }
    }

    // block until something sends
    pub fn recv(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!usize {
        if (caps.LOG_OBJ_CALLS)
            log.debug("receiver recv", .{});

        const self = (caps.Ref(@This()){ .paddr = paddr }).ptr();

        if (null != self.receiver.cmpxchgStrong(null, thread, .seq_cst, .monotonic)) {
            // TODO: already listening
            return Error.Unimplemented;
        }

        thread.status = .waiting;
        proc.yield(trap);
        return trap.syscall_id;
    }

    pub fn reply(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!usize {
        if (caps.LOG_OBJ_CALLS)
            log.debug("receiver reply", .{});

        const self = (caps.Ref(@This()){ .paddr = paddr }).ptr();

        const sender = self.sender.swap(null, .seq_cst) orelse {
            // TODO: not listening
            return Error.Unimplemented;
        };

        if (sender.status != .waiting) {
            // TODO: idk
            return Error.Unimplemented;
        }

        thread.status = .waiting;
        thread.trap = trap.*;
        const args = .{ trap.arg1, trap.arg2, trap.arg3, trap.arg4, trap.arg5 };
        self.sender.store(thread, .seq_cst);
        proc.switchTo(trap, sender);
        trap.arg1, trap.arg2, trap.arg3, trap.arg4, trap.arg5 = args;
        return trap.arg0;
    }
};

pub const Sender = struct {
    pub fn init(_: *@This()) void {}

    pub fn canAlloc() bool {
        return false;
    }

    // block until the receiver is free, then switch to the receiver
    pub fn call(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!usize {
        if (caps.LOG_OBJ_CALLS)
            log.debug("sender call", .{});

        const self = (caps.Ref(Receiver){ .paddr = paddr }).ptr();

        const listener = self.receiver.swap(null, .seq_cst) orelse {
            // TODO: not listening
            return Error.Unimplemented;
        };

        if (listener.status != .waiting) {
            // TODO: idk
            return Error.Unimplemented;
        }

        thread.status = .waiting;
        thread.trap = trap.*;
        const args = .{ trap.arg1, trap.arg2, trap.arg3, trap.arg4, trap.arg5 };
        self.sender.store(thread, .seq_cst);
        proc.switchTo(trap, listener);
        trap.arg1, trap.arg2, trap.arg3, trap.arg4, trap.arg5 = args;
        return trap.arg0;
    }
};

// pub const Reply = struct {};
