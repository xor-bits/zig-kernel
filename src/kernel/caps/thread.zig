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

    // TODO: IPC buffer Frame where the userspace can write data freely
    // and on send, the kernel copies it (with CoW) to the destination IPC buffer
    // and replaces all handles with the target handles (u32 -> handle -> giveCap -> handle -> u32)

    /// extra ipc registers
    /// controlled by Receiver and Sender
    extra_regs: std.MultiArrayList(CapOrVal) = .{},

    pub const CapOrVal = union(enum) {
        cap: caps.CapabilitySlot,
        val: u64,

        pub fn deinit(self: @This()) void {
            switch (self) {
                .cap => |cap| cap.deinit(),
                else => {},
            }
        }
    };

    pub fn init(from_proc: *caps.Process) !*@This() {
        errdefer from_proc.deinit();

        if (conf.LOG_OBJ_CALLS)
            log.info("Thread.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.thread);

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{ .proc = from_proc };

        try obj.extra_regs.resize(caps.slab_allocator.allocator(), 128);
        for (0..128) |i| obj.extra_regs.set(i, .{ .val = 0 });

        obj.lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Thread.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.thread);

        if (self.next) |next| next.deinit();
        if (self.prev) |prev| prev.deinit();
        if (self.reply) |reply| reply.deinit();

        self.proc.deinit();

        for (0..128) |i| self.getExtra(@truncate(i)).deinit();
        self.extra_regs.deinit(caps.slab_allocator.allocator());

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Thread.clone", .{});

        self.refcnt.inc();
        return self;
    }

    pub fn getExtra(self: *@This(), idx: u7) CapOrVal {
        self.lock.lock();
        defer self.lock.unlock();

        const val = self.extra_regs.get(idx);
        self.extra_regs.set(idx, .{ .val = 0 });
        return val;
    }

    pub fn setExtra(self: *@This(), idx: u7, data: CapOrVal) void {
        self.lock.lock();
        defer self.lock.unlock();

        self.extra_regs.get(idx).deinit();
        self.extra_regs.set(idx, data);
    }

    /// prepareExtras has to be called for `dst` first
    pub fn moveExtra(src: *@This(), dst: *@This(), count: u7) void {
        if (count == 0) {
            return;
        } else {
            @branchHint(.cold);
        }

        src.lock.lock();
        defer src.lock.unlock();
        dst.lock.lock();
        defer dst.lock.unlock();

        for (0..count) |idx| {
            const val = src.extra_regs.get(@truncate(idx));
            src.extra_regs.set(@truncate(idx), .{ .val = 0 });

            const old_val = dst.extra_regs.get(idx);
            dst.extra_regs.set(@truncate(idx), val);

            old_val.deinit();
        }
    }

    pub fn takeReply(self: *@This()) ?*Thread {
        const sender = self.reply orelse return null;
        std.debug.assert(sender.status == .waiting);
        self.reply = null;
        return sender;
    }

    pub fn unhandledPageFault(
        self: *@This(),
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

        self.proc.vmem.dump();

        proc.enter();
    }
};
