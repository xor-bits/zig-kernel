const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");
const spin = @import("../spin.zig");

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
    next: ?caps.Ref(Thread) = null,
    /// scheduler linked list
    prev: ?caps.Ref(Thread) = null,

    pub fn init(self: caps.Ref(@This())) void {
        self.ptr().* = .{};
    }

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return pmem.alloc(@sizeOf(@This())) orelse return Error.OutOfMemory;
    }

    // FIXME: pass Ref(Self) instead of addr.Phys
    pub fn call(paddr: addr.Phys, thread: *Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.ThreadCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        const target_thread = caps.Ref(Thread){ .paddr = paddr };

        if (caps.LOG_OBJ_CALLS)
            log.debug("thread call \"{s}\" from {*} on {*}", .{ @tagName(call_id), thread, target_thread.ptr() });

        switch (call_id) {
            .start => {
                try proc.start(target_thread);
            },
            .stop => {
                try proc.stop(target_thread);
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
                const vmem = try (try caps.get_capability(thread, @truncate(trap.arg2))).as(caps.Vmem);
                target_thread.ptr().vmem = vmem;
            },
            .set_prio => {
                target_thread.ptr().priority = @truncate(trap.arg2);
            },
        }
    }

    pub fn vmemOf(thread: ?*Thread) ?*caps.Vmem {
        const t = thread orelse return null;
        const vmem = t.vmem orelse return null;
        return vmem.ptr();
    }
};
