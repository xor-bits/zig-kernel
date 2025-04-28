const std = @import("std");
const abi = @import("abi");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const proc = @import("../proc.zig");
const pmem = @import("../pmem.zig");

const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const Receiver = struct {
    receiver: std.atomic.Value(?*caps.Thread) = .init(null),
    sender: std.atomic.Value(?*caps.Thread) = .init(null),

    pub fn init(self: caps.Ref(@This())) void {
        self.ptr().* = .{};
    }

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return pmem.alloc(@sizeOf(@This())) orelse return Error.OutOfMemory;
    }

    pub fn call(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.ReceiverCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (caps.LOG_OBJ_CALLS)
            log.debug("receiver call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .subscribe => {
                const sender = caps.Ref(Sender){ .paddr = paddr };
                trap.arg0 = caps.push_capability(sender.object(thread));
            },
        }
    }

    // block until something sends
    pub fn recv(paddr: addr.Phys, thread: *caps.Thread, _: *arch.SyscallRegs) Error!void {
        if (caps.LOG_OBJ_CALLS)
            log.debug("receiver recv", .{});

        const self = (caps.Ref(@This()){ .paddr = paddr }).ptr();

        if (null != self.receiver.cmpxchgStrong(null, thread, .seq_cst, .monotonic)) {
            // TODO: already listening
            return Error.Unimplemented;
        }

        thread.status = .waiting;
    }

    pub fn reply(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
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

        var msg = trap.readMessage();
        msg.cap = 0; // call doesnt get to know the Receiver capability id

        try thread.moveExtra(sender, @truncate(msg.extra));

        thread.trap = trap.*;
        proc.ready(thread);
        proc.switchTo(trap, sender);

        trap.writeMessage(msg);
    }

    pub fn replyRecv(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        if (caps.LOG_OBJ_CALLS)
            log.debug("receiver reply", .{});

        const self = (caps.Ref(@This()){ .paddr = paddr }).ptr();

        if (null != self.receiver.cmpxchgStrong(null, thread, .seq_cst, .monotonic)) {
            // TODO: already listening
            return Error.Unimplemented;
        }

        thread.status = .waiting;

        const sender = self.sender.swap(null, .seq_cst) orelse {
            // TODO: not listening
            return Error.Unimplemented;
        };

        if (sender.status != .waiting) {
            // TODO: idk
            return Error.Unimplemented;
        }

        var msg = trap.readMessage();
        msg.cap = 0; // call doesnt get to know the Receiver capability id

        try thread.moveExtra(sender, @truncate(msg.extra));

        thread.status = .waiting;
        thread.trap = trap.*;
        self.sender.store(thread, .seq_cst);
        proc.switchTo(trap, sender);

        trap.writeMessage(msg);
    }
};

pub const Sender = struct {
    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return Error.InvalidArgument;
    }

    // block until the receiver is free, then switch to the receiver
    pub fn call(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
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

        const msg = trap.readMessage();
        // recv gets to know the Sender capability id (just the number)

        try thread.moveExtra(listener, @truncate(msg.extra));

        thread.status = .waiting;
        thread.trap = trap.*;
        self.sender.store(thread, .seq_cst);
        proc.switchTo(trap, listener);

        trap.writeMessage(msg);
    }
};

// pub const Reply = struct {};
