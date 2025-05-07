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
    /// all context data
    trap: arch.SyscallRegs = .{},
    /// virtual address space
    vmem: ?caps.Ref(caps.Vmem) = null,
    /// capability space lock
    caps_lock: spin.Mutex = .new(),
    /// scheduler priority
    priority: u2 = 1,
    /// is the thread stopped/running/ready/waiting
    status: enum { stopped, running, ready, waiting } = .stopped,
    /// scheduler linked list
    next: ?*Thread = null,
    /// scheduler linked list
    prev: ?*Thread = null,
    /// ipc reply target
    reply: ?*Thread = null,

    /// extra ipc registers
    /// controlled by Receiver and Sender
    extra_regs: [128]u64 = std.mem.zeroes([128]u64),
    /// extra ipc register types, 0=raw 1=cap
    /// controlled by Receiver and Sender
    extra_types: u128 = 0,

    pub fn init(self: caps.Ref(@This())) void {
        self.ptr().* = .{};
    }

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return pmem.alloc(@sizeOf(@This())) orelse return Error.OutOfMemory;
    }

    pub fn getExtra(self: *@This(), idx: u7) usize {
        // current thread is locked

        const val = self.extra_regs[idx];
        self.extra_regs[idx] = 0;
        self.extra_types &= ~(@as(u128, 1) << idx);
        return val;
    }

    pub fn setExtra(self: *@This(), idx: u7, val: usize, is_cap: bool) void {
        // current thread is locked

        self.extra_regs[idx] = val;
        if (is_cap) {
            self.extra_types |= @as(u128, 1) << idx;
        } else {
            self.extra_types &= ~(@as(u128, 1) << idx);
        }
    }

    pub fn prelockExtras(self: *@This(), count: u7) Error!void {
        if (count == 0) {
            @branchHint(.likely);
            return;
        }

        var partially_locked_count: usize = 0;

        // unlock everything that was locked, if one couldn't be locked
        errdefer {
            for (0..count) |idx| {
                if ((self.extra_types & (@as(u128, 1) << @as(u7, @truncate(idx)))) == 0) continue;
                if (partially_locked_count == 0) break;
                partially_locked_count -= 1;

                const cap_id: u32 = @truncate(self.extra_regs[idx]);
                const obj = caps.getCapabilityLocked(cap_id);
                obj.lock.unlock();
            }
        }

        // lock all caps
        for (0..count) |idx| {
            if ((self.extra_types & (@as(u128, 1) << @as(u7, @truncate(idx)))) == 0) continue;

            const cap_id: u32 = @truncate(self.extra_regs[idx]);
            _ = try caps.getCapability(self, cap_id);

            partially_locked_count += 1;
        }
    }

    pub fn unlockExtras(self: *@This(), count: u7) void {
        for (0..count) |idx| {
            if ((self.extra_types & (@as(u128, 1) << @as(u7, @truncate(idx)))) == 0) continue;

            const cap_id: u32 = @truncate(self.extra_regs[idx]);
            const obj = caps.getCapabilityLocked(cap_id);
            std.debug.assert(obj.lock.isLocked());
            obj.lock.unlock();
        }
    }

    /// requires `prelockExtras` to be called before
    pub fn moveExtra(self: *@This(), target: *@This(), count: u7) void {
        // both current and target threads are locked

        if (count == 0) {
            @branchHint(.likely);
            return;
        }

        // transfer ownership
        for (0..count) |idx| {
            if ((self.extra_types & (@as(u128, 1) << @as(u7, @truncate(idx)))) == 0) continue;

            const cap_id: u32 = @truncate(self.extra_regs[idx]);
            const obj = caps.getCapabilityLocked(cap_id);
            std.debug.assert(obj.lock.isLocked());
            obj.owner.store(Thread.vmemOf(target), .release);
        }

        // resets all target extra registers and moves `count` registers over
        target.extra_regs = std.mem.zeroes([128]u64);
        target.extra_types = self.extra_types;
        std.mem.copyForwards(u64, target.extra_regs[0..], self.extra_regs[0..count]);
        self.extra_regs = std.mem.zeroes([128]u64);

        // unlock all transferred caps
        target.unlockExtras(count);
    }

    // FIXME: pass Ref(Self) instead of addr.Phys
    pub fn call(paddr: addr.Phys, thread: *Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.ThreadCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        const target_thread = caps.Ref(Thread){ .paddr = paddr };

        if (conf.LOG_OBJ_CALLS)
            log.debug("thread call \"{s}\" from {*} on {*}", .{ @tagName(call_id), thread, target_thread.ptr() });

        switch (call_id) {
            .start => {
                if (target_thread.ptr().status != .stopped) return Error.NotStopped;
                if (target_thread.ptr().vmem == null) return Error.NoVmem;
                 proc.start(target_thread.ptr());
            },
            .stop => {
                if (target_thread.ptr().status == .stopped) return Error.IsStopped;
                proc.stop(target_thread.ptr());
            },
            .read_regs => {
                if (!std.mem.isAligned(trap.arg2, @alignOf(abi.sys.ThreadRegs))) {
                    return Error.InvalidAddress;
                }

                var tmp: arch.SyscallRegs = undefined;
                if (target_thread.ptr() == thread) {
                    tmp = trap.*;
                } else {
                    tmp = target_thread.ptr().trap;
                }
                tmp.rflags = 0;

                comptime std.debug.assert(@sizeOf(arch.SyscallRegs) == @sizeOf(abi.sys.ThreadRegs));

                // abi.sys.ThreadRegs is written as if it was arch.SyscallRegs
                const ptr = @as(*volatile arch.SyscallRegs, @ptrFromInt(trap.arg2));
                ptr.* = tmp;

                trap.arg0 = @sizeOf(arch.SyscallRegs);
            },
            .write_regs => {
                if (!std.mem.isAligned(trap.arg2, @alignOf(abi.sys.ThreadRegs))) {
                    return Error.InvalidAddress;
                }

                comptime std.debug.assert(@sizeOf(arch.SyscallRegs) == @sizeOf(abi.sys.ThreadRegs));

                // abi.sys.ThreadRegs is read as if it was arch.SyscallRegs
                const ptr = @as(*volatile arch.SyscallRegs, @ptrFromInt(trap.arg2));
                var tmp: arch.SyscallRegs = ptr.*;
                tmp.rflags = (arch.SyscallRegs{}).rflags;
                if (target_thread.ptr() == thread) {
                    trap.* = tmp;
                } else {
                    target_thread.ptr().trap = tmp;
                }

                trap.arg0 = @sizeOf(arch.SyscallRegs);
            },
            .set_vmem => {
                if (target_thread.ptr().status != .stopped) return Error.NotStopped;

                // TODO: require stopping the thread or something
                const vmem_obj = try caps.getCapability(thread, @truncate(trap.arg2));
                defer vmem_obj.lock.unlock();
                const vmem = try vmem_obj.as(caps.Vmem);

                target_thread.ptr().vmem = vmem;
            },
            .set_prio => {
                target_thread.ptr().priority = @truncate(trap.arg2);
            },
            .transfer_cap => {
                const cap = try caps.getCapability(thread, @truncate(trap.arg2));
                defer cap.lock.unlock();

                if (Thread.vmemOf(target_thread.ptr())) |vmem| {
                    cap.owner.store(vmem, .seq_cst);
                } else {
                    return Error.NoVmem;
                }
            },
        }
    }

    pub fn vmemOf(thread: ?*Thread) ?*caps.Vmem {
        const t = thread orelse return null;
        const vmem = t.vmem orelse return null;
        return vmem.ptr();
    }
};
