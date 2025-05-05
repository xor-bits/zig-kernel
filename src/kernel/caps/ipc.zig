const std = @import("std");
const abi = @import("abi");

const addr = @import("../addr.zig");
const apic = @import("../apic.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");
const spin = @import("../spin.zig");
const util = @import("../util.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const Receiver = struct {
    // TODO: remove a thread from here if gets stopped
    /// the currently waiting receiver thread
    receiver: std.atomic.Value(?*caps.Thread) = .init(null),

    /// a linked list of waiting callers
    queue_lock: spin.Mutex = .{},
    queue: util.Queue(caps.Thread, "next", "prev") = .{},

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

        if (conf.LOG_OBJ_CALLS)
            log.debug("receiver call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .subscribe => {
                const sender = caps.Ref(Sender){ .paddr = paddr };
                trap.arg0 = caps.pushCapability(sender.object(thread));
            },
        }
    }

    // block until something sends
    pub fn recv(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("receiver recv", .{});

        const self = (caps.Ref(@This()){ .paddr = paddr }).ptr();

        self.recvNoFail(thread, trap);
    }

    // might block the user-space thread (kernel-space should only ever block after a syscall is complete)
    fn recvNoFail(self: *@This(), thread: *caps.Thread, trap: *arch.SyscallRegs) void {
        // stop the thread early to hold the lock for a shorter time
        thread.status = .waiting;
        thread.trap = trap.*;

        // check if a sender is already waiting
        self.queue_lock.lock();
        if (self.queue.popFront()) |immediate| {
            self.queue_lock.unlock();

            if (conf.LOG_WAITING)
                log.debug("IPC wake {*}", .{immediate});

            // copy over the message
            const msg = immediate.trap.readMessage();
            trap.writeMessage(msg);
            immediate.moveExtra(thread, @truncate(msg.extra)); // the caps are already locked in `Sender.call`

            // save the reply target
            std.debug.assert(thread.reply == null);
            thread.reply = immediate;

            // undo stopping the thread
            thread.status = .running;
            return;
        }

        if (null != self.receiver.cmpxchgStrong(null, thread, .seq_cst, .monotonic)) {
            unreachable; // the receiver cannot be cloned ... _yet_
        }
        self.queue_lock.unlock();

        // thread is set to waiting and will yield at the end of the main syscall handler
    }

    pub fn reply(_: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("receiver reply", .{});

        // const self = (caps.Ref(@This()){ .paddr = paddr }).ptr();

        const sender = try Receiver.replyGetSender(thread, trap);

        // set the original caller thread as ready to run again, but return to the current thread
        proc.ready(sender);
    }

    fn replyGetSender(thread: *caps.Thread, trap: *arch.SyscallRegs) Error!*caps.Thread {
        // prepare cap transfer
        var msg = trap.readMessage();
        msg.cap = 0; // call doesnt get to know the Receiver capability id
        if (conf.LOG_OBJ_CALLS)
            log.debug("replying {}", .{msg});
        try thread.prelockExtras(@truncate(msg.extra));

        const sender = thread.reply orelse {
            @branchHint(.cold);
            thread.unlockExtras(@truncate(msg.extra));
            return Error.InvalidCapability;
        };
        std.debug.assert(sender.status == .waiting);
        thread.reply = null;

        // copy over the reply message
        sender.trap.writeMessage(msg);
        thread.moveExtra(sender, @truncate(msg.extra));

        return sender;
    }

    pub fn replyRecv(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("receiver reply", .{});

        const sender = try Receiver.replyGetSender(thread, trap);

        const self = (caps.Ref(@This()){ .paddr = paddr }).ptr();
        self.recvNoFail(thread, trap);

        // push the receiver thread into the ready queue
        // if there was a sender queued
        if (thread.status == .running) {
            thread.status = .waiting;
            thread.trap = trap.*;
            proc.ready(thread);
        }

        // switch to the original caller thread
        proc.switchTo(trap, sender, thread);
    }
};

pub const Sender = struct {
    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        // receiver can be cloned to make senders
        return Error.InvalidArgument;
    }

    pub fn init(_: caps.Ref(@This())) void {
        unreachable;
    }

    // block until the receiver is free, then switch to the receiver
    pub fn call(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("sender call", .{});

        const self = (caps.Ref(Receiver){ .paddr = paddr }).ptr();

        // prepare cap transfer
        const msg = trap.readMessage();
        if (conf.LOG_OBJ_CALLS)
            log.debug("sending {}", .{msg});
        try thread.prelockExtras(@truncate(msg.extra)); // keep them locked even if a listener isn't ready

        // acquire a listener or switch threads
        const listener = self.receiver.swap(null, .seq_cst) orelse {
            @branchHint(.cold);

            // first push the thread into the sleep queue
            if (conf.LOG_WAITING)
                log.debug("IPC sleep {*}", .{thread});
            self.queue_lock.lock();
            self.queue.pushBack(thread);
            self.queue_lock.unlock();

            thread.status = .waiting;
            return;
        };
        std.debug.assert(listener.status == .waiting);

        // copy over the message
        listener.trap.writeMessage(msg);
        thread.moveExtra(listener, @truncate(msg.extra));

        // save the reply target
        std.debug.assert(listener.reply == null);
        listener.reply = thread;

        // switch to the listener
        thread.status = .waiting;
        thread.trap = trap.*;
        proc.switchTo(trap, listener, thread);
    }
};

// pub const Reply = struct {};

pub const Notify = struct {
    notified: std.atomic.Value(u32) = .init(0),

    // waiter queue
    queue_lock: spin.Mutex = .{},
    queue: util.Queue(caps.Thread, "next", "prev") = .{},

    pub fn init(self: caps.Ref(@This())) void {
        self.ptr().* = .{};
    }

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return pmem.alloc(@sizeOf(@This())) orelse return Error.OutOfMemory;
    }

    pub fn call(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.NotifyCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (conf.LOG_OBJ_CALLS)
            log.debug("notify call \"{s}\"", .{@tagName(call_id)});

        const self_ref = caps.Ref(Notify){ .paddr = paddr };
        const self = self_ref.ptr();

        switch (call_id) {
            .wait => {
                // early test if its active
                trap.arg1 = self.notified.swap(0, .acquire);
                if (trap.arg1 != 0) {
                    return;
                }

                // save the state and go to sleep
                thread.status = .waiting;
                thread.trap = trap.*;
                self.queue_lock.lock();
                self.queue.pushBack(thread);
                defer self.queue_lock.unlock();

                // while holding the lock: if it became active before locking but after the swap, then test it again
                trap.arg1 = self.notified.swap(0, .acquire);
                if (trap.arg1 != 0) {
                    std.debug.assert(self.queue.popBack() == thread);
                    thread.status = .running;
                    return;
                }
            },
            .poll => {
                trap.arg1 = self.notified.swap(0, .acquire);
            },
            .notify => {
                const notifier: u32 = @truncate(trap.arg0);
                trap.arg1 = @intFromBool(self.notify(notifier));
            },
            .clone => {
                trap.arg1 = caps.pushCapability(self_ref.object(thread));
            },
        }
    }

    pub fn notify(self: *@This(), notifier: u32) bool {
        self.queue_lock.lock();
        if (self.queue.popFront()) |waiter| {
            self.queue_lock.unlock();
            waiter.trap.arg1 = notifier;
            proc.ready(waiter);
            return false;
        } else {
            defer self.queue_lock.unlock();
            return null != self.notified.cmpxchgStrong(0, notifier, .monotonic, .monotonic);
        }
    }
};
