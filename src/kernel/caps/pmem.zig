const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

/// raw physical memory that can be used to allocate
/// things like more `CapabilityNode`s or things
pub const Memory = struct {
    pub fn init(_: caps.Ref(@This())) void {}

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return pmem.alloc(@sizeOf(@This())) orelse return Error.OutOfMemory;
    }

    pub fn call(_: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.MemoryCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (conf.LOG_OBJ_CALLS)
            log.debug("memory call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .alloc => {
                const obj_ty = std.meta.intToEnum(abi.ObjectType, trap.arg2) catch {
                    return Error.InvalidArgument;
                };

                const dyn_size = std.meta.intToEnum(abi.ChunkSize, trap.arg3) catch {
                    return Error.InvalidArgument;
                };

                const obj = try caps.Object.alloc(obj_ty, thread, dyn_size);
                const cap = caps.pushCapability(obj);
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
    data: [512]u64 align(0x1000),

    pub fn init(self: caps.Ref(@This())) void {
        const ptr = addr.Phys.fromParts(.{ .page = self.paddr.toParts().page });
        const size = @This().sizeOf(self).sizeBytes() / 8;

        const data = ptr.toHhdm().toPtr([*]volatile u64)[0..size];
        std.crypto.secureZero(u64, data);
    }

    pub fn alloc(_dyn_size: ?abi.ChunkSize) Error!addr.Phys {
        const dyn_size = _dyn_size orelse return Error.InvalidArgument;
        // log.info("frame alloc {}", .{dyn_size});
        const chunk: addr.Phys = pmem.allocChunk(dyn_size) orelse return Error.OutOfMemory;
        return new(chunk, dyn_size);
    }

    pub fn new(paddr: addr.Phys, size: abi.ChunkSize) addr.Phys {
        return addr.Phys.fromParts(.{
            .offset = @intFromEnum(size),
            .page = paddr.toParts().page,
        });
    }

    pub fn sizeOf(self: caps.Ref(@This())) abi.ChunkSize {
        return @enumFromInt(self.paddr.toParts().offset);
    }
};
