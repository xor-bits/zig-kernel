const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");

const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

/// raw physical memory that can be used to allocate
/// things like more `CapabilityNode`s or things
pub const Memory = struct {
    pub fn init(_: *@This()) void {}

    pub fn canAlloc() bool {
        return true;
    }

    pub fn call(_: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.MemoryCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (caps.LOG_OBJ_CALLS)
            log.debug("memory call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .alloc => {
                const obj_ty = std.meta.intToEnum(abi.ObjectType, trap.arg2) catch {
                    return Error.InvalidArgument;
                };

                const obj = try caps.Object.alloc(obj_ty, thread);
                const cap = caps.push_capability(obj);
                trap.arg0 = cap;
            },
        }
    }
};

/// a `PageTableLevel1` points to multiple of these
///
/// raw physical memory again, but now mappable
/// (and can't be used to allocate things)
pub const Frame = struct {
    data: [512]u64 align(0x1000) = std.mem.zeroes([512]u64),

    pub fn canAlloc() bool {
        return true;
    }

    pub fn init(self: *@This()) void {
        self.* = .{};
    }

    pub fn call(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        _ = .{ paddr, thread, trap };
        return Error.InvalidArgument;
    }

    pub fn consume(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const msg = trap.readMessage();

        const call_id = std.meta.intToEnum(abi.sys.FrameCallId, msg.arg0) catch {
            return Error.InvalidArgument;
        };

        if (caps.LOG_OBJ_CALLS)
            log.debug("frame call \"{s}\" msg={}", .{ @tagName(call_id), msg });

        defer if (caps.LOG_OBJ_CALLS)
            log.debug("frame call complete", .{});

        switch (call_id) {
            .map => {
                const vmem = try (try caps.get_capability(thread, @truncate(msg.arg1))).as(caps.PageTableLevel4);
                const vaddr = try addr.Virt.fromUser(msg.arg2);
                const rights: abi.sys.Rights = @bitCast(@as(u32, @truncate(msg.arg3)));
                const flags: abi.sys.MapFlags = @bitCast(@as(u40, @truncate(msg.arg4)));

                try vmem.ptr().map_frame(paddr, vaddr, rights, flags);
            },
        }
    }
};
