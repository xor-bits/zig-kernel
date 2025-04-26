const std = @import("std");
const abi = @import("abi");

const arch = @import("arch.zig");
const addr = @import("addr.zig");
const spin = @import("spin.zig");
const pmem = @import("pmem.zig");
const proc = @import("proc.zig");

const caps_ipc = @import("caps/ipc.zig");
const caps_pmem = @import("caps/pmem.zig");
const caps_thread = @import("caps/thread.zig");
const caps_vmem = @import("caps/vmem.zig");

const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const LOG_OBJ_CALLS: bool = false;

//

pub const Memory = caps_pmem.Memory;
pub const Frame = caps_pmem.Frame;
pub const HugeFrame = caps_pmem.HugeFrame;
pub const GiantFrame = caps_pmem.GiantFrame;
pub const Thread = caps_thread.Thread;
pub const PageTableLevel4 = caps_vmem.PageTableLevel4;
pub const PageTableLevel3 = caps_vmem.PageTableLevel3;
pub const PageTableLevel2 = caps_vmem.PageTableLevel2;
pub const PageTableLevel1 = caps_vmem.PageTableLevel1;
pub const Receiver = caps_ipc.Receiver;
pub const Sender = caps_ipc.Sender;

//

pub fn init() !void {
    // initialize the global kernel address space
    // (required for the capability array)
    try caps_vmem.init();

    // push the null capability
    _ = push_capability(.{});

    debug_type(Object);
}

/// create a capability out of an object
pub fn push_capability(obj: Object) u32 {
    const cap_id = allocate();
    const cap = &capability_array_unchecked()[cap_id];

    cap.lock.lock();
    cap.* = obj;
    cap.lock.unlock();

    return cap_id;
}

/// returns an object from a capability,
/// some other thread might invalidate the capability during or after this
pub fn get_capability(thread: *Thread, cap_id: u32) Error!Object {
    const caps = capability_array();
    if (cap_id >= caps.len) return Error.InvalidCapability;

    const current = Thread.vmemOf(thread);
    const cap = &caps[cap_id];

    // fast path fail if the capability is not owned or being modified
    if (cap.owner != current)
        return Error.InvalidCapability;

    cap.lock.lock();
    const obj = cap.*;
    cap.lock.unlock();

    if (obj.owner != current)
        return Error.InvalidCapability;

    return obj;
}

/// a single bidirectional call
pub fn call(thread: *Thread, cap_id: u32, trap: *arch.SyscallRegs) Error!void {
    const obj = try get_capability(thread, cap_id);
    return obj.call(thread, trap);
}

/// Receiver specific unidirectional call
pub fn recv(thread: *Thread, cap_id: u32, trap: *arch.SyscallRegs) Error!usize {
    const obj = try get_capability(thread, cap_id);
    return obj.recv(thread, trap);
}

/// Receiver specific unidirectional call
pub fn reply(thread: *Thread, cap_id: u32, trap: *arch.SyscallRegs) Error!usize {
    const obj = try get_capability(thread, cap_id);
    return obj.reply(thread, trap);
}

pub fn replyRecv() Error!void {
    // TODO:
}

pub fn capAssertNotNull(cap: u32, trap: *arch.SyscallRegs) bool {
    if (cap == 0) {
        trap.syscall_id = abi.sys.encode(Error.InvalidCapability);
        return true;
    }
    return false;
}

//

pub fn capability_array() []Object {
    const len = @min(capability_array_len.load(.acquire), 2 << 32);
    return @as([*]Object, @ptrFromInt(CAPABILITY_ARRAY_POINTER))[0..len];
}

pub fn capability_array_unchecked() []Object {
    return @as([*]Object, @ptrFromInt(CAPABILITY_ARRAY_POINTER))[0 .. 2 << 32];
}

pub fn allocate() u32 {
    {
        free_list_lock.lock();
        defer free_list_lock.unlock();

        if (free_list != 0) {
            const head = free_list;
            const new_head = capability_array_unchecked()[free_list];
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
        const new_head = &capability_array_unchecked()[cap];
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

        pub fn alloc() Error!Self {
            std.debug.assert(std.mem.isAligned(0x1000, @alignOf(T)));

            if (!T.canAlloc())
                return Error.InvalidType;

            const obj = Self{
                .paddr = pmem.alloc(@sizeOf(T)) orelse return Error.OutOfMemory,
            };
            obj.ptr().init();

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
                .owner = Thread.vmemOf(owner),
            };
        }
    };
}

pub const Object = struct {
    /// physical address (or metadata for ZST) for the kernel object
    paddr: addr.Phys = .{ .raw = 0 },
    /// capability ownership is tied to virtual address spaces
    owner: ?*PageTableLevel4 = null,
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
            PageTableLevel4 => .page_table_level_4,
            PageTableLevel3 => .page_table_level_3,
            PageTableLevel2 => .page_table_level_2,
            PageTableLevel1 => .page_table_level_1,
            Frame => .frame,
            HugeFrame => .huge_frame,
            GiantFrame => .giant_frame,
            Receiver => .receiver,
            Sender => .sender,
            else => @compileError(std.fmt.comptimePrint("invalid Capability type: {}", .{@typeName(T)})),
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

    pub fn alloc(ty: abi.ObjectType, owner: *Thread) Error!Self {
        return switch (ty) {
            .null => Error.InvalidCapability,
            .memory => (try Ref(Memory).alloc()).object(owner),
            .thread => (try Ref(Thread).alloc()).object(owner),
            .page_table_level_4 => (try Ref(PageTableLevel4).alloc()).object(owner),
            .page_table_level_3 => (try Ref(PageTableLevel3).alloc()).object(owner),
            .page_table_level_2 => (try Ref(PageTableLevel2).alloc()).object(owner),
            .page_table_level_1 => (try Ref(PageTableLevel1).alloc()).object(owner),
            .frame => (try Ref(Frame).alloc()).object(owner),
            .huge_frame => (try Ref(HugeFrame).alloc()).object(owner),
            .giant_frame => (try Ref(GiantFrame).alloc()).object(owner),
            .receiver => (try Ref(Receiver).alloc()).object(owner),
            .sender => Error.InvalidType, // receiver can be cloned to make senders
        };
    }

    pub fn call(self: Self, thread: *Thread, trap: *arch.SyscallRegs) Error!void {
        // log.debug("call {}", .{self.type});
        return switch (self.type) {
            .null => Error.InvalidCapability,
            .memory => Memory.call(self.paddr, thread, trap),
            .thread => Thread.call(self.paddr, thread, trap),
            .page_table_level_4 => Error.InvalidArgument,
            .page_table_level_3 => PageTableLevel3.call(self.paddr, thread, trap),
            .page_table_level_2 => PageTableLevel2.call(self.paddr, thread, trap),
            .page_table_level_1 => PageTableLevel1.call(self.paddr, thread, trap),
            .frame => Frame.call(self.paddr, thread, trap),
            .huge_frame => HugeFrame.call(self.paddr, thread, trap),
            .giant_frame => GiantFrame.call(self.paddr, thread, trap),
            .receiver => Receiver.call(self.paddr, thread, trap),
            .sender => Sender.call(self.paddr, thread, trap),
        };
    }

    pub fn recv(self: Self, thread: *Thread, trap: *arch.SyscallRegs) Error!usize {
        return switch (self.type) {
            .null => Error.InvalidCapability,
            .memory => Error.InvalidArgument,
            .thread => Error.InvalidArgument,
            .page_table_level_4 => Error.InvalidArgument,
            .page_table_level_3 => Error.InvalidArgument,
            .page_table_level_2 => Error.InvalidArgument,
            .page_table_level_1 => Error.InvalidArgument,
            .frame => Error.InvalidArgument,
            .huge_frame => Error.InvalidArgument,
            .giant_frame => Error.InvalidArgument,
            .receiver => Receiver.recv(self.paddr, thread, trap),
            .sender => Error.InvalidArgument,
        };
    }

    pub fn reply(self: Self, thread: *Thread, trap: *arch.SyscallRegs) Error!usize {
        return switch (self.type) {
            .null => Error.InvalidCapability,
            .memory => Error.InvalidArgument,
            .thread => Error.InvalidArgument,
            .page_table_level_4 => Error.InvalidArgument,
            .page_table_level_3 => Error.InvalidArgument,
            .page_table_level_2 => Error.InvalidArgument,
            .page_table_level_1 => Error.InvalidArgument,
            .frame => Error.InvalidArgument,
            .huge_frame => Error.InvalidArgument,
            .giant_frame => Error.InvalidArgument,
            .receiver => Receiver.reply(self.paddr, thread, trap),
            .sender => Error.InvalidArgument,
        };
    }
};

fn debug_type(comptime T: type) void {
    std.log.info("{s}: size={} align={}", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
}
