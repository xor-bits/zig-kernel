const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const spin = @import("../spin.zig");

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

    pub const Flags = packed struct {
        /// is this frame cap mapped to some vmem
        is_mapped: bool = false,
        /// is this frame cap a derivation, revoking which doesn't free the physical memory
        is_derived: bool = false,
        _: u14 = 0,
    };

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

    pub fn addrOf(self: caps.Ref(@This())) u64 {
        return self.paddr.raw & 0xFFFF_FFFF_FFFF_F000;
    }

    pub fn sizeOf(self: caps.Ref(@This())) abi.ChunkSize {
        return @enumFromInt(self.paddr.toParts().offset);
    }

    pub fn call(self: *caps.Object, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.FrameCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (conf.LOG_OBJ_CALLS)
            log.debug("frame call \"{s}\"", .{@tagName(call_id)});

        const self_ref = self.as(@This()) catch unreachable;

        switch (call_id) {
            .size_of => {
                trap.arg1 = @intFromEnum(Frame.sizeOf(self_ref));
            },
            .subframe => {
                const size = std.meta.intToEnum(abi.ChunkSize, trap.arg3) catch return Error.InvalidArgument;
                const paddr = trap.arg2;

                var child_obj = try createSubframe(self_ref, thread, paddr, size);
                child_obj.prev = self.capOf() orelse unreachable;

                // log.info("subframe={}", .{child});

                if (self.children == 0) {
                    const child = caps.pushCapability(child_obj);

                    self.children = child;
                    trap.arg1 = child;
                } else {
                    child_obj.next = self.children;

                    const child = caps.pushCapability(child_obj);

                    const first_obj = caps.getCapabilityDerivation(self.children);
                    first_obj.lock.lock(); // FIXME: lockless, at least spinlockless
                    first_obj.prev = child;
                    first_obj.lock.unlock();

                    self.children = child;
                    trap.arg1 = child;
                }
            },
            .revoke => {
                revokeRecurse(self.children);

                caps.deallocate(self.capOf() orelse unreachable);

                if (!@as(Flags, @bitCast(self.flags)).is_derived) {
                    pmem.deallocChunk(addr.Phys.fromInt(Frame.addrOf(self_ref)), Frame.sizeOf(self_ref));
                }
            },
        }
    }

    fn createSubframe(
        self: caps.Ref(@This()),
        owner: ?*caps.Thread,
        _sub_paddr: usize,
        new_chunksize: abi.ChunkSize,
    ) !caps.Object {
        const paddr = @This().addrOf(self);
        const fsize = @This().sizeOf(self).sizeBytes();

        const sub_paddr = if (_sub_paddr == 0) paddr else _sub_paddr;

        const sub_fsize = new_chunksize.sizeBytes();

        const end = std.math.add(usize, paddr, fsize) catch return Error.OutOfBounds;
        const sub_end = std.math.add(usize, sub_paddr, sub_fsize) catch return Error.OutOfBounds;

        if (sub_paddr < paddr) return Error.OutOfBounds;
        if (sub_fsize > fsize) return Error.OutOfBounds;
        if (sub_end > end) return Error.OutOfBounds;

        const subframe: caps.Ref(Frame) = .{ .paddr = Frame.new(addr.Phys.fromInt(sub_paddr), new_chunksize) };
        var subframe_obj = subframe.object(owner);
        subframe_obj.flags = @bitCast(Flags{
            .is_derived = true,
        });
        return subframe_obj;
    }

    fn revokeRecurse(cap_id: u32) void {
        var cur_id = cap_id;
        while (cur_id != 0) {
            const cur = caps.getCapabilityDerivation(cur_id);
            cur.lock.lock(); // FIXME: lockless, at least spinlockless
            defer cur.lock.unlock();
            cur.owner.store(null, .release);
            const next_id = cur.next;
            const children = cur.children;
            caps.deallocate(cur_id);

            cur_id = next_id;
            revokeRecurse(children);
        }
    }
};

var frame_linked_list_lock: spin.Mutex = .{};

// TODO: DeviceFrame doesn't have to be separate
/// a `PageTableLevel1` points to multiple of these
///
/// raw physical memory again, but now mappable
/// (and can't be used to allocate things)
pub const DeviceFrame = struct {
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

    pub fn addrOf(self: caps.Ref(@This())) u64 {
        return self.paddr.raw & 0xFFFF_FFFF_FFFF_F000;
    }

    pub fn sizeOf(self: caps.Ref(@This())) abi.ChunkSize {
        return @enumFromInt(self.paddr.toParts().offset);
    }

    pub fn call(info: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.DeviceFrameCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (conf.LOG_OBJ_CALLS)
            log.debug("device_frame call \"{s}\"", .{@tagName(call_id)});

        const self = caps.Ref(DeviceFrame){ .paddr = info };

        switch (call_id) {
            .addr_of => {
                trap.arg1 = DeviceFrame.addrOf(self);
            },
            .size_of => {
                trap.arg1 = @intFromEnum(DeviceFrame.sizeOf(self));
            },
            .subframe => {
                const new_chunksize = std.meta.intToEnum(abi.ChunkSize, trap.arg3) catch return Error.InvalidArgument;

                const paddr = DeviceFrame.addrOf(self);
                const fsize = DeviceFrame.sizeOf(self).sizeBytes();

                const sub_paddr = trap.arg2;
                const sub_fsize = new_chunksize.sizeBytes();

                const end = std.math.add(usize, paddr, fsize) catch return Error.OutOfBounds;
                const sub_end = std.math.add(usize, sub_paddr, sub_fsize) catch return Error.OutOfBounds;

                if (sub_paddr < paddr) return Error.OutOfBounds;
                if (sub_fsize > fsize) return Error.OutOfBounds;
                if (sub_end > end) return Error.OutOfBounds;

                const subframe: caps.Ref(DeviceFrame) = .{ .paddr = DeviceFrame.new(addr.Phys.fromInt(sub_paddr), new_chunksize) };
                const cap_id = caps.pushCapability(subframe.object(thread));
                trap.arg1 = cap_id;
            },
        }
    }
};
