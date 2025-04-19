const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
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
    vmem: ?caps.Ref(caps.PageTableLevel4) = null,
    /// capability space lock
    caps_lock: spin.Mutex = .new(),
    /// scheduler priority
    priority: u2 = 1,
    /// is the thread stopped OR running/ready/waiting
    stopped: bool = true,
    /// scheduler linked list
    next: ?caps.Ref(Thread) = null,
    /// scheduler linked list
    prev: ?caps.Ref(Thread) = null,

    pub fn init(self: *@This()) void {
        self.* = .{};
    }

    // FIXME: pass Ref(Self) instead of addr.Phys
    pub fn call(paddr: addr.Phys, thread: *Thread, trap: *arch.SyscallRegs) Error!usize {
        const call_id = std.meta.intToEnum(abi.sys.ThreadCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        const target_thread = caps.Ref(Thread){ .paddr = paddr };

        if (caps.LOG_OBJ_CALLS)
            log.debug("thread call \"{s}\" from {*} on {*}", .{ @tagName(call_id), thread, target_thread.ptr() });

        switch (call_id) {
            .start => {
                proc.start(target_thread);
                return 0;
            },
            .stop => {
                proc.stop(target_thread);
                return 0;
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
                return @sizeOf(arch.SyscallRegs);
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

                return @sizeOf(arch.SyscallRegs);
            },
            .set_vmem => {
                // TODO: require stopping the thread or something
                const vmem = try (try caps.get_capability(thread, @truncate(trap.arg2))).as(caps.PageTableLevel4);
                target_thread.ptr().vmem = vmem;
                return 0;
            },
            .set_prio => {
                target_thread.ptr().priority = @truncate(trap.arg2);
                return 0;
            },
        }
    }

    pub fn vmemOf(thread: ?*Thread) ?*caps.PageTableLevel4 {
        const t = thread orelse return null;
        const vmem = t.vmem orelse return null;
        return vmem.ptr();
    }
};
