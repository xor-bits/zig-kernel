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
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    // TODO: remove a thread from here if gets stopped
    /// the currently waiting receiver thread
    receiver: std.atomic.Value(?*caps.Thread) = .init(null),

    /// a linked list of waiting callers
    queue_lock: spin.Mutex = .newLocked(),
    queue: util.Queue(caps.Thread, "next", "prev") = .{},

    pub fn init() !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Receiver.init", .{});

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{};
        obj.queue_lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Receiver.deinit", .{});

        // TODO: wake the waiting threads or what
        if (self.receiver.load(.monotonic)) |receiver| {
            receiver.deinit();
        }
        while (self.queue.popFront()) |waiter| {
            waiter.deinit();
        }

        caps.slab_allocator.allocator().destroy(self);
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
            .save_caller => {
                const caller = thread.reply orelse {
                    return Error.NotMapped;
                };
                thread.reply = null;

                const reply_obj = caps.Ref(Reply){ .paddr = addr.Virt.fromPtr(caller).hhdmToPhys() };
                trap.arg0 = caps.pushCapability(reply_obj.object(thread));
            },
            .load_caller => {
                if (thread.reply != null) {
                    return Error.AlreadyMapped;
                }

                const reply_cap_id: u32 = @truncate(trap.arg2);
                const reply_cap = try caps.getCapability(thread, reply_cap_id);
                defer reply_cap.lock.unlock();

                const reply_obj = try reply_cap.as(Reply);
                const caller = caps.Ref(caps.Thread){ .paddr = reply_obj.paddr };

                thread.reply = caller.ptr();
                reply_cap.owner.store(null, .release);
                caps.deallocate(reply_cap_id);
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
        std.debug.assert(sender != thread);

        // set the original caller thread as ready to run again, but return to the current thread
        proc.ready(sender);
    }

    fn replyGetSender(thread: *caps.Thread, trap: *arch.SyscallRegs) Error!*caps.Thread {
        // prepare cap transfer
        var msg = trap.readMessage();
        msg.cap = 0; // call doesnt get to know the Receiver capability id
        if (conf.LOG_OBJ_CALLS)
            log.debug("replying {} to {*}", .{ msg, thread });
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
            // return back to the server, which is prob more important
            // and keeps the TLB cache warm
            // + ready up the caller thread
            proc.ready(sender);
        } else {
            // if the receiver went to sleep, switch to the original caller thread
            proc.switchTo(trap, sender, thread);
        }
    }
};

pub const Sender = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    recv: *Receiver,
    stamp: usize,

    pub fn init(recv: *Receiver, stamp: usize) !*@This() {
        errdefer recv.deinit(); // FIXME: errdefer in the caller instead

        if (conf.LOG_OBJ_CALLS)
            log.info("Sender.init", .{});

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{
            .recv = recv,
            .stamp = stamp,
        };

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Sender.deinit", .{});

        self.recv.deinit();

        caps.slab_allocator.allocator().destroy(self);
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

pub const Reply = struct {
    // TODO: this shouldn't be cloneable
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    /// only borrows `thread`
    pub fn init(thread: *caps.Thread) !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Reply.init", .{});

        _ = thread;

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{};

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Reply.deinit", .{});

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn reply(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("reply reply", .{});

        const reply_cap_id = trap.readMessage().cap;

        thread.reply = (caps.Ref(caps.Thread){ .paddr = paddr }).ptr();
        const sender = try Receiver.replyGetSender(thread, trap);

        // delete this reply object
        caps.getCapabilityLocked(reply_cap_id).owner.store(null, .release);
        caps.deallocate(reply_cap_id);

        // set the original caller thread as ready to run again, but return to the current thread
        proc.ready(sender);
    }
};

pub const Notify = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    notified: std.atomic.Value(bool) = .init(false),

    // waiter queue
    queue_lock: spin.Mutex = .newLocked(),
    queue: util.Queue(caps.Thread, "next", "prev") = .{},

    pub fn init() !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Notify.init", .{});

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{};
        obj.queue_lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Notify.deinit", .{});

        while (self.queue.popFront()) |waiter| {
            waiter.deinit();
        }

        caps.slab_allocator.allocator().destroy(self);
    }

    /// returns true if the current thread went to sleep
    pub fn wait(self: *@This(), thread: *caps.Thread, trap: *arch.SyscallRegs) bool {
        // early test if its active
        if (self.poll()) {
            return false;
        }

        // save the state and go to sleep
        thread.status = .waiting;
        thread.trap = trap.*;
        self.queue_lock.lock();
        self.queue.pushBack(thread);
        defer self.queue_lock.unlock();

        // while holding the lock: if it became active before locking but after the swap, then test it again
        if (self.poll()) {
            // revert
            std.debug.assert(self.queue.popBack() == thread);
            std.debug.assert(thread.status == .waiting);
            thread.status = .running;
            return false;
        }

        return true;
    }

    pub fn poll(self: *@This()) bool {
        return self.notified.swap(false, .acquire);
    }

    pub fn notify(self: *@This()) bool {
        self.queue_lock.lock();
        if (self.queue.popFront()) |waiter| {
            self.queue_lock.unlock();

            proc.ready(waiter);
            return false;
        } else {
            defer self.queue_lock.unlock();

            return null != self.notified.cmpxchgStrong(false, true, .monotonic, .monotonic);
        }
    }
};
