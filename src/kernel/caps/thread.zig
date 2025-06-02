const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");
const spin = @import("../spin.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

/// thread information
pub const Thread = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    proc: *caps.Process,
    // lock for modifying / executing the thread
    lock: spin.Mutex = .newLocked(),
    /// all context data
    trap: arch.SyscallRegs = .{},
    /// scheduler priority
    priority: u2 = 1,
    /// is the thread stopped/running/ready/waiting
    status: enum { stopped, running, ready, waiting } = .stopped,
    /// scheduler linked list
    next: ?*Thread = null,
    /// scheduler linked list
    prev: ?*Thread = null,
    /// IPC reply target
    reply: ?*Thread = null,

    pub fn init(from_proc: *caps.Process) !*@This() {
        errdefer from_proc.deinit();

        if (conf.LOG_OBJ_CALLS)
            log.info("Thread.init", .{});

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{ .proc = from_proc };
        obj.lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Thread.deinit", .{});

        if (self.next) |next| next.deinit();
        if (self.prev) |prev| prev.deinit();
        if (self.reply) |reply| reply.deinit();

        self.proc.deinit();

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Thread.clone", .{});

        self.refcnt.inc();
        return self;
    }

    pub fn unhandledPageFault(
        _: *@This(),
        target_addr: usize,
        caused_by: arch.FaultCause,
        ip: usize,
        sp: usize,
        reason: anyerror,
    ) noreturn {
        log.warn(
            \\page fault 0x{x} (user) ({})
            \\ - caused by: {}
            \\ - ip: 0x{x}
            \\ - sp: 0x{x}
        , .{
            target_addr,
            reason,
            caused_by,
            ip,
            sp,
        });

        proc.enter();
    }
};
