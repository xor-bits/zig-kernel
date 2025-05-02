const std = @import("std");
const abi = @import("abi");

const addr = @import("addr.zig");
const arch = @import("arch.zig");
const conf = @import("conf.zig");
const pmem = @import("pmem.zig");
const proc = @import("proc.zig");
const spin = @import("spin.zig");

const caps_ipc = @import("caps/ipc.zig");
const caps_pmem = @import("caps/pmem.zig");
const caps_thread = @import("caps/thread.zig");
const caps_vmem = @import("caps/vmem.zig");

const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const Memory = caps_pmem.Memory;
pub const Frame = caps_pmem.Frame;
pub const Thread = caps_thread.Thread;
pub const Vmem = caps_vmem.Vmem;
pub const Receiver = caps_ipc.Receiver;
pub const Sender = caps_ipc.Sender;
pub const Notify = caps_ipc.Notify;

//

pub fn init() !void {
    // initialize the global kernel address space
    // (required for the capability array)
    try caps_vmem.init();

    // push the null capability
    _ = pushCapability(.{});

    // debugType(Object);
    // debugType(Memory);
    // debugType(Thread);
    // debugType(Vmem);
    // debugType(Receiver);
    // debugType(Sender);
}

/// create a capability out of an object
pub fn pushCapability(obj: Object) u32 {
    const cap_id = allocate();
    const cap = &capabilityArrayUnchecked()[cap_id];

    cap.lock.lock();
    cap.* = obj;
    cap.lock.unlock();

    return cap_id;
}

/// returns an object from a capability,
/// the returned object is locked
pub fn getCapability(thread: *Thread, cap_id: u32) Error!*Object {
    if (cap_id == 0)
        return Error.InvalidCapability;

    const caps = capabilityArray();
    if (cap_id >= caps.len)
        return Error.InvalidCapability;

    const current = Thread.vmemOf(thread);
    const obj = &caps[cap_id];

    errdefer if (conf.LOG_OBJ_CALLS)
        log.debug("obj was cap={} type={} thread={*}", .{ cap_id, obj.type, thread });

    // fast path fail if the capability is not owned or being modified
    if (obj.owner.load(.acquire) != current)
        return Error.InvalidCapability;

    if (!obj.lock.tryLock())
        return Error.ThreadSafety;
    errdefer obj.lock.unlock();

    if (obj.owner.load(.acquire) != current)
        return Error.InvalidCapability;

    return obj;
}

/// gets a capability when its already locked and checked to be owned
pub fn getCapabilityLocked(cap_id: u32) *Object {
    return &capabilityArrayUnchecked()[cap_id];
}

/// a single bidirectional call
pub fn call(thread: *Thread, cap_id: u32, trap: *arch.SyscallRegs) Error!void {
    const obj = try getCapability(thread, cap_id);
    defer obj.lock.unlock();

    return obj.call(thread, trap);
}

/// Receiver specific unidirectional call
pub fn recv(thread: *Thread, cap_id: u32, trap: *arch.SyscallRegs) Error!void {
    const obj = try getCapability(thread, cap_id);
    defer obj.lock.unlock();

    return obj.recv(thread, trap);
}

/// Receiver specific unidirectional call
pub fn reply(thread: *Thread, cap_id: u32, trap: *arch.SyscallRegs) Error!void {
    const obj = try getCapability(thread, cap_id);
    defer obj.lock.unlock();

    return obj.reply(thread, trap);
}

pub fn replyRecv(thread: *Thread, cap_id: u32, trap: *arch.SyscallRegs) Error!void {
    const obj = try getCapability(thread, cap_id);
    defer obj.lock.unlock();

    return obj.replyRecv(thread, trap);
}

pub fn capAssertNotNull(cap: u32, trap: *arch.SyscallRegs) bool {
    if (cap == 0) {
        trap.syscall_id = abi.sys.encode(Error.InvalidCapability);
        return true;
    }
    return false;
}

//

pub fn capabilityArray() []Object {
    const len = @min(capability_array_len.load(.acquire), 2 << 32);
    return @as([*]Object, @ptrFromInt(CAPABILITY_ARRAY_POINTER))[0..len];
}

pub fn capabilityArrayUnchecked() []Object {
    return @as([*]Object, @ptrFromInt(CAPABILITY_ARRAY_POINTER))[0 .. 2 << 32];
}

pub fn allocate() u32 {
    {
        free_list_lock.lock();
        defer free_list_lock.unlock();

        if (free_list != 0) {
            const head = free_list;
            const new_head = capabilityArrayUnchecked()[free_list];
            free_list = new_head.next;
            return head;
        }
    }

    return caps_vmem.growCapArray();
}

pub fn deallocate(cap: u32) void {
    free_list_lock.lock();
    defer free_list_lock.unlock();

    if (free_list != 0) {
        const new_head = &capabilityArrayUnchecked()[cap];
        new_head.* = .{ .next = free_list };
    }

    free_list = cap;
}

//

/// pointer to the first capability in the global capability array (its a null capability)
///
/// it is currently `0xFFFFFFBF80000000`, right before the kernel code at `0xFFFF_FFFF_8000_0000`
/// and capable of holding a maximum of 2^32 capabilities across all processes
pub const CAPABILITY_ARRAY_POINTER: usize = 0xFFFF_FFFF_8000_0000 - (2 << 32) * @sizeOf(Object);
/// the length can only grow
pub var capability_array_len: std.atomic.Value(usize) = .init(0);
/// a linked list of unused slots
pub var array_grow_lock: spin.Mutex = .new();
pub var free_list_lock: spin.Mutex = .new();
pub var free_list: u32 = 0;

//

pub fn Ref(comptime T: type) type {
    return struct {
        paddr: addr.Phys,

        const Self = @This();

        pub fn alloc(dyn_size: ?abi.ChunkSize) Error!Self {
            const paddr = try T.alloc(dyn_size);
            const obj = Self{ .paddr = paddr };
            T.init(obj);
            return obj;
        }

        pub fn ptr(self: @This()) *T {
            // recursive mapping instead of HHDM later (maybe)
            return self.paddr.toHhdm().toPtr(*T);
        }

        pub fn object(self: @This(), owner: ?*Thread) Object {
            return .{
                .paddr = self.paddr,
                .type = Object.objectTypeOf(T),
                .owner = .init(Thread.vmemOf(owner)),
            };
        }
    };
}

pub const Object = struct {
    /// physical address (or metadata for ZST) for the kernel object
    paddr: addr.Phys = .{ .raw = 0 },
    /// capability ownership is tied to virtual address spaces
    owner: std.atomic.Value(?*Vmem) = .init(null),
    /// capability kind, like memory, receiver, .. or thread
    type: abi.ObjectType = .null,
    /// lock for reading/writing the capability slot
    /// the object is just quickly copied while the lock is held
    lock: spin.Mutex = .new(),

    /// a linked list of Objects that are derived from this one
    children: u32 = 0,
    /// the next element in the linked list derived from the parent
    next: u32 = 0,

    const Self = @This();

    pub fn objectTypeOf(comptime T: type) abi.ObjectType {
        return switch (T) {
            Memory => .memory,
            Thread => .thread,
            Vmem => .vmem,
            Frame => .frame,
            Receiver => .receiver,
            Sender => .sender,
            Notify => .notify,
            else => @compileError(std.fmt.comptimePrint("invalid Capability type: {s}", .{@typeName(T)})),
        };
    }

    pub fn as(self: Self, comptime T: type) Error!Ref(T) {
        const expected = objectTypeOf(T);
        if (expected == self.type) {
            return Ref(T){ .paddr = self.paddr };
        } else {
            return Error.InvalidCapability;
        }
    }

    pub fn alloc(ty: abi.ObjectType, owner: *Thread, dyn_size: abi.ChunkSize) Error!Self {
        return switch (ty) {
            .null => Error.InvalidCapability,
            .memory => (try Ref(Memory).alloc(dyn_size)).object(owner),
            .thread => (try Ref(Thread).alloc(dyn_size)).object(owner),
            .vmem => (try Ref(Vmem).alloc(dyn_size)).object(owner),
            .frame => (try Ref(Frame).alloc(dyn_size)).object(owner),
            .receiver => (try Ref(Receiver).alloc(dyn_size)).object(owner),
            .sender => (try Ref(Sender).alloc(dyn_size)).object(owner),
            .notify => (try Ref(Notify).alloc(dyn_size)).object(owner),
        };
    }

    pub fn call(self: Self, thread: *Thread, trap: *arch.SyscallRegs) Error!void {
        // log.debug("call {}", .{self.type});
        return switch (self.type) {
            .null => Error.InvalidCapability,
            .memory => Memory.call(self.paddr, thread, trap),
            .thread => Thread.call(self.paddr, thread, trap),
            .vmem => Vmem.call(self.paddr, thread, trap),
            .frame => Error.InvalidArgument,
            .receiver => Receiver.call(self.paddr, thread, trap),
            .sender => Sender.call(self.paddr, thread, trap),
            .notify => Notify.call(self.paddr, thread, trap),
        };
    }

    pub fn recv(self: Self, thread: *Thread, trap: *arch.SyscallRegs) Error!void {
        return switch (self.type) {
            .null => Error.InvalidCapability,
            .memory => Error.InvalidArgument,
            .thread => Error.InvalidArgument,
            .vmem => Error.InvalidArgument,
            .frame => Error.InvalidArgument,
            .receiver => Receiver.recv(self.paddr, thread, trap),
            .sender => Error.InvalidArgument,
            .notify => Error.InvalidArgument,
        };
    }

    pub fn reply(self: Self, thread: *Thread, trap: *arch.SyscallRegs) Error!void {
        return switch (self.type) {
            .null => Error.InvalidCapability,
            .memory => Error.InvalidArgument,
            .thread => Error.InvalidArgument,
            .vmem => Error.InvalidArgument,
            .frame => Error.InvalidArgument,
            .receiver => Receiver.reply(self.paddr, thread, trap),
            .sender => Error.InvalidArgument,
            .notify => Error.InvalidArgument,
        };
    }

    pub fn replyRecv(self: Self, thread: *Thread, trap: *arch.SyscallRegs) Error!void {
        return switch (self.type) {
            .null => Error.InvalidCapability,
            .memory => Error.InvalidArgument,
            .thread => Error.InvalidArgument,
            .vmem => Error.InvalidArgument,
            .frame => Error.InvalidArgument,
            .receiver => Receiver.replyRecv(self.paddr, thread, trap),
            .sender => Error.InvalidArgument,
            .notify => Error.InvalidArgument,
        };
    }
};

fn debugType(comptime T: type) void {
    std.log.debug("{s}: size={} align={}", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
}
