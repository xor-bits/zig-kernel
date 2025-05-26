const std = @import("std");
const abi = @import("abi");

const addr = @import("addr.zig");
const arch = @import("arch.zig");
const pmem = @import("pmem.zig");
const proc = @import("proc.zig");
const spin = @import("spin.zig");

const caps_ipc = @import("caps/ipc.zig");
const caps_pmem = @import("caps/pmem.zig");
const caps_thread = @import("caps/thread.zig");
const caps_vmem = @import("caps/vmem.zig");
const caps_x86 = @import("caps/x86.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const Memory = caps_pmem.Memory;
pub const Frame = caps_pmem.Frame;
pub const DeviceFrame = caps_pmem.DeviceFrame;
pub const Thread = caps_thread.Thread;
pub const Vmem = caps_vmem.Vmem;
pub const Receiver = caps_ipc.Receiver;
pub const Sender = caps_ipc.Sender;
pub const Reply = caps_ipc.Reply;
pub const Notify = caps_ipc.Notify;
pub const X86IoPortAllocator = caps_x86.X86IoPortAllocator;
pub const X86IoPort = caps_x86.X86IoPort;
pub const X86IrqAllocator = caps_x86.X86IrqAllocator;
pub const X86Irq = caps_x86.X86Irq;

//

pub fn init() !void {
    // initialize the global kernel address space
    // (required for the capability array)
    try caps_vmem.init();

    // initialize the dedupe lazyinit readonly zero page
    const page = pmem.allocChunk(.@"4KiB") orelse return error.OutOfMemory;
    readonly_zero_page.store(page.toParts().page, .release);

    const frame = try FrameObject.init(0x8000);
    const a = try frame.page_hit(4);
    const b = try frame.page_hit(4);
    std.debug.assert(a == b);
    std.debug.assert(a != 0);
    frame.deinit();

    // push the null capability
    _ = pushCapability(.{});

    var cap: Capability = .{};
    cap.object.store(.{}, .seq_cst);
    const s = cap.object.load(.acquire);
    // s.ptr;
    // s.type;
    debugType(@TypeOf(s));
    debugType(Capability);
    debugType(GenericObject);
    debugType(FrameObject);
    // debugType(Object);
    // debugType(Memory);
    // debugType(Frame);
    // debugType(DeviceFrame);
    // debugType(Thread);
    // debugType(Vmem);
    // debugType(Receiver);
    // debugType(Sender);
    // debugType(Reply);
    // debugType(Notify);
    // debugType(X86IoPortAllocator);
    // debugType(X86IoPort);
    // debugType(X86IrqAllocator);
    // debugType(X86Irq);
}

// FIXME: keep the capability locked
/// create a capability out of an object
pub fn pushCapability(_obj: Object) u32 {
    var obj = _obj;
    obj.lock = .newLocked();

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

    if (conf.LOG_OBJ_ACCESS_STATS) {
        _ = obj_accesses.getPtr(obj.type).fetchAdd(1, .monotonic);

        log.debug("obj accesses:", .{});
        var it = obj_accesses.iterator();
        while (it.next()) |e| {
            log.debug(" - {}: {}", .{ e.key, e.value.load(.monotonic) });
        }
    }

    return obj;
}

pub fn getCapabilityDerivation(cap_id: u32) *Object {
    std.debug.assert(cap_id != 0);

    const caps = capabilityArray();
    std.debug.assert(cap_id < caps.len);

    const obj = &caps[cap_id];

    errdefer if (conf.LOG_OBJ_CALLS)
        log.debug("obj was cap={} type={}", .{ cap_id, obj.type });

    if (conf.LOG_OBJ_ACCESS_STATS) {
        _ = obj_accesses.getPtr(obj.type).fetchAdd(1, .monotonic);

        log.debug("obj accesses:", .{});
        var it = obj_accesses.iterator();
        while (it.next()) |e| {
            log.debug(" - {}: {}", .{ e.key, e.value.load(.monotonic) });
        }
    }

    return obj;
}

/// gets a capability when its already locked and checked to be owned
pub fn getCapabilityLocked(cap_id: u32) *Object {
    const obj = &capabilityArrayUnchecked()[cap_id];
    std.debug.assert(obj.lock.isLocked());
    return obj;
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
            // the capability might be locked still
            return head;
        }
    }

    return caps_vmem.growCapArray();
}

pub fn deallocate(cap: u32) void {
    std.debug.assert(cap != 0);

    free_list_lock.lock();
    defer free_list_lock.unlock();

    if (free_list != 0) {
        const new_head = &capabilityArrayUnchecked()[cap];
        new_head.next = free_list;
        // the capability might be locked still
    }

    free_list = cap;
}

//

// TODO: make this local per process (process, not thread)

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
pub var obj_accesses: std.EnumArray(abi.ObjectType, std.atomic.Value(usize)) = .initFill(.init(0));

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

pub const Capability = struct {
    /// the actual kernel object data, possibly shared between multiple capabilities
    object: std.atomic.Value(ObjectPointer) = .init(.{}),
    /// capability ownership is tied to virtual address spaces
    owner: std.atomic.Value(?*Vmem) = .init(null), // TODO: will be removed with per-process caps

    const ObjectPointer = packed struct {
        /// object pointer's low 56 bits, the upper 8 (actually 17) bits are always 1 in kernel space
        ptr: u56 = 0,
        /// object type
        type: abi.ObjectType = .null,

        fn getRefcntPtr(self: *@This()) *abi.epoch.RefCnt {
            // FIXME: prevent reordering so that the offset would be same on all objects
            switch (self.type) {
                .frame => &@as(*FrameObject, @ptrFromInt(self.ptr)).refcnt,
            }
        }
    };

    const Self = @This();

    pub fn load(self: *Self) void {
        const guard = abi.epoch.pin();
        defer abi.epoch.unpin(guard);

        const object = self.object.load(.monotonic);
        object.getRefcntPtr().inc();
        return object.ptr;
    }

    pub fn store(self: *Self) void {
        const guard = abi.epoch.pin();
        defer abi.epoch.unpin(guard);

        const old_object = self.object.swap(.{}, .seq_cst);
        if (old_object.getRefcntPtr().dec()) {
            @branchHint(.unlikely);
            // abi.epoch.deferFunc(guard, func: *const fn(data:*[3]usize)void, data: [3]usize)
        }
    }
};

pub const GenericObject = struct {
    refcnt: abi.epoch.RefCnt,
};

// pub const ShortFrameObject = extern struct {
//     refcnt: abi.epoch.RefCnt = .{},
//     lock: spin.Mutex = .new(),
//     pages: [2:0]u32, //
// };

pub const FrameObject = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    lock: spin.Mutex = .new(),
    pages: []u32,

    pub fn init(size_bytes: usize) !*@This() {
        const size_pages = std.math.divCeil(usize, size_bytes, 0x1000) catch unreachable;
        if (size_pages > std.math.maxInt(u32)) return error.OutOfMemory;

        const obj: *@This() = try slab_allocator.allocator().create(@This());
        const pages = try slab_allocator.allocator().alloc(u32, size_pages);

        @memset(pages, 0);

        obj.* = .{
            .lock = .newLocked(),
            .pages = pages,
        };
        obj.lock.unlock();

        return obj;
    }

    pub fn page_hit(self: *@This(), idx: u32) !u32 {
        self.lock.lock();
        defer self.lock.unlock();

        std.debug.assert(idx < self.pages.len);

        if (self.pages[idx] != 0)
            return self.pages[idx];

        const new_page = pmem.allocChunk(.@"4KiB") orelse return error.OutOfMemory;
        self.pages[idx] = new_page.toParts().page;

        return new_page.toParts().page;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        for (self.pages) |page| {
            if (page == 0) continue;

            pmem.deallocChunk(
                addr.Phys.fromParts(.{ .page = page }),
                .@"4KiB",
            );
        }

        slab_allocator.allocator().free(self.pages);
        slab_allocator.allocator().destroy(self);
    }
};

pub const VmemObject = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    lock: spin.Mutex = .new(),
    cr3: u32,
    mappings: std.ArrayList(Mapping),

    const Mapping = struct {
        /// refcounted
        frame: *FrameObject,
        /// page offset within the Frame object
        frame_first_page: u32,
        /// virtual address destination of the mapping
        /// `mappings` is sorted by this
        vaddr: addr.Virt,
        /// number of bytes (rounded up to pages) mapped
        pages: u32,

        fn overlaps(self: *@This(), vaddr: addr.Virt, pages: u32) bool {
            const a_beg: usize = self.vaddr.raw;
            const a_end: usize = self.vaddr.raw + self.pages * 0x1000;
            const b_beg: usize = vaddr.raw;
            const b_end: usize = vaddr.raw + pages * 0x1000;

            if (a_end <= b_beg)
                return false;
            if (b_end <= a_beg)
                return false;
            return true;
        }
    };

    pub fn init() !*@This() {
        const obj: *@This() = try slab_allocator.allocator().create(@This());
        const mappings = std.ArrayList(Mapping).init(slab_allocator);

        obj.* = .{
            .lock = .newLocked(),
            .cr3 = 0,
            .mappings = mappings,
        };
        obj.lock.unlock();

        return obj;
    }

    pub fn map(
        self: *@This(),
        frame: *FrameObject,
        frame_first_page: u32,
        vaddr: addr.Virt,
        pages: u32,
    ) !void {
        errdefer frame.deinit();

        std.debug.assert(vaddr.toParts().offset == 0);

        {
            frame.lock.lock();
            defer frame.lock.unlock();
            if (pages + frame_first_page >= frame.pages.len)
                return error.OutOfBounds;
        }

        const mapping = Mapping{
            .frame = frame,
            .frame_first_page = frame_first_page,
            .vaddr = vaddr,
            .pages = pages,
        };

        self.lock.lock();
        defer self.lock.unlock();

        if (self.find(vaddr)) |idx| {
            if (vaddr.raw == self.mappings.items[idx.?].vaddr.raw) {
                // replace old mapping
                self.mappings.items[idx].frame.deinit();
                self.mappings.items[idx] = mapping;
            } else {
                // insert new mapping
                self.mappings.insert(idx, mapping);
            }
        } else {
            // push new mapping
            self.mappings.append(mapping);
        }
    }

    pub fn unmap(self: *@This(), vaddr: addr.Virt, pages: u32) void {
        self.lock.lock();
        defer self.lock.unlock();

        const idx = self.find(vaddr) orelse return;

        while (true) {
            if (idx >= self.mappings.items.len)
                break;

            if (!self.mappings.items[idx].overlaps(vaddr, pages))
                break;

            self.mappings.items[idx].frame.deinit();
            self.mappings.orderedRemove(idx); // TODO: batch remove
        }

        // FIXME: update hardware page tables
    }

    pub fn page_fault(self: *@This(), vaddr: addr.Virt) bool {
        self.lock.lock();
        defer self.lock.unlock();

        const idx = self.find(vaddr) orelse return false;

        self.mappings.items[idx].overlaps(vaddr, 1);

        // FIXME: update hardware page tables
        self.cr3;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        for (self.mappings.items) |mapping| {
            mapping.frame.deinit();
        }

        self.mappings.deinit();
        slab_allocator.allocator().destroy(self);
    }

    fn find(self: *@This(), vaddr: addr.Virt) ?usize {
        const idx = std.sort.partitionPoint(
            Mapping,
            self.mappings,
            vaddr,
            struct {
                fn pred(target_vaddr: addr.Virt, val: Mapping) bool {
                    return val.vaddr.raw < target_vaddr.raw;
                }
            }.pred,
        );

        if (idx == self.mappings.items.len)
            return null;

        return idx;
    }
};

var slab_allocator = abi.mem.SlabAllocator.init(pmem.page_allocator);
var readonly_zero_page: std.atomic.Value(u32) = .init(0);

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

    flags: u16 = 0,

    /// a linked list of Objects that are derived from this one
    children: u32 = 0,
    /// the next element or the parent in the linked list derived from the parent
    prev: u32 = 0,
    /// the next element in the linked list derived from the parent
    next: u32 = 0,

    const Self = @This();

    pub fn capOf(obj: *@This()) ?u32 {
        if (@intFromPtr(obj) < CAPABILITY_ARRAY_POINTER)
            return null;

        const relative_addr: usize = @intFromPtr(obj) - CAPABILITY_ARRAY_POINTER;
        const index: usize = relative_addr / @sizeOf(@This());

        if (index > std.math.maxInt(u32))
            return null;

        return @truncate(index);
    }

    pub fn objectTypeOf(comptime T: type) abi.ObjectType {
        return switch (T) {
            Memory => .memory,
            Thread => .thread,
            Vmem => .vmem,
            Frame => .frame,
            DeviceFrame => .device_frame,
            Receiver => .receiver,
            Sender => .sender,
            Reply => .reply,
            Notify => .notify,
            X86IoPortAllocator => .x86_ioport_allocator,
            X86IoPort => .x86_ioport,
            X86IrqAllocator => .x86_irq_allocator,
            X86Irq => .x86_irq,
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

    // pub fn asUnion(self: Self) Error!union(enum) {} {
    //     return switch (self.type) {
    //         .null => Error.InvalidCapability,
    //         .memory => ,
    //     };
    // }

    pub fn alloc(ty: abi.ObjectType, owner: *Thread, dyn_size: abi.ChunkSize) Error!Self {
        return switch (ty) {
            .null => Error.InvalidCapability,
            .memory => (try Ref(Memory).alloc(dyn_size)).object(owner),
            .thread => (try Ref(Thread).alloc(dyn_size)).object(owner),
            .vmem => (try Ref(Vmem).alloc(dyn_size)).object(owner),
            .frame => (try Ref(Frame).alloc(dyn_size)).object(owner),
            .device_frame => (try Ref(DeviceFrame).alloc(dyn_size)).object(owner),
            .receiver => (try Ref(Receiver).alloc(dyn_size)).object(owner),
            .sender => (try Ref(Sender).alloc(dyn_size)).object(owner),
            .reply => (try Ref(Reply).alloc(dyn_size)).object(owner),
            .notify => (try Ref(Notify).alloc(dyn_size)).object(owner),
            .x86_ioport_allocator => (try Ref(X86IoPortAllocator).alloc(dyn_size)).object(owner),
            .x86_ioport => (try Ref(X86IoPort).alloc(dyn_size)).object(owner),
            .x86_irq_allocator => (try Ref(X86IrqAllocator).alloc(dyn_size)).object(owner),
            .x86_irq => (try Ref(X86Irq).alloc(dyn_size)).object(owner),
        };
    }

    pub fn call(self: *Self, thread: *Thread, trap: *arch.SyscallRegs) Error!void {
        // log.debug("call {}", .{self.type});
        return switch (self.type) {
            .null => Error.InvalidCapability,
            .memory => Memory.call(self.paddr, thread, trap),
            .thread => Thread.call(self.paddr, thread, trap),
            .vmem => Vmem.call(self.paddr, thread, trap),
            .frame => Frame.call(self, thread, trap),
            .device_frame => DeviceFrame.call(self.paddr, thread, trap),
            .receiver => Receiver.call(self.paddr, thread, trap),
            .sender => Sender.call(self.paddr, thread, trap),
            .reply => Error.InvalidArgument,
            .notify => Notify.call(self.paddr, thread, trap),
            .x86_ioport_allocator => X86IoPortAllocator.call(self.paddr, thread, trap),
            .x86_ioport => X86IoPort.call(self.paddr, thread, trap),
            .x86_irq_allocator => X86IrqAllocator.call(self.paddr, thread, trap),
            .x86_irq => X86Irq.call(self.paddr, thread, trap),
        };
    }

    pub fn recv(self: Self, thread: *Thread, trap: *arch.SyscallRegs) Error!void {
        return switch (self.type) {
            .null => Error.InvalidCapability,
            .memory => Error.InvalidArgument,
            .thread => Error.InvalidArgument,
            .vmem => Error.InvalidArgument,
            .frame => Error.InvalidArgument,
            .device_frame => Error.InvalidArgument,
            .receiver => Receiver.recv(self.paddr, thread, trap),
            .sender => Error.InvalidArgument,
            .reply => Error.InvalidArgument,
            .notify => Error.InvalidArgument,
            .x86_ioport_allocator => Error.InvalidArgument,
            .x86_ioport => Error.InvalidArgument,
            .x86_irq_allocator => Error.InvalidArgument,
            .x86_irq => Error.InvalidArgument,
        };
    }

    pub fn reply(self: Self, thread: *Thread, trap: *arch.SyscallRegs) Error!void {
        return switch (self.type) {
            .null => Error.InvalidCapability,
            .memory => Error.InvalidArgument,
            .thread => Error.InvalidArgument,
            .vmem => Error.InvalidArgument,
            .frame => Error.InvalidArgument,
            .device_frame => Error.InvalidArgument,
            .receiver => Receiver.reply(self.paddr, thread, trap),
            .sender => Error.InvalidArgument,
            .reply => Reply.reply(self.paddr, thread, trap),
            .notify => Error.InvalidArgument,
            .x86_ioport_allocator => Error.InvalidArgument,
            .x86_ioport => Error.InvalidArgument,
            .x86_irq_allocator => Error.InvalidArgument,
            .x86_irq => Error.InvalidArgument,
        };
    }

    pub fn replyRecv(self: Self, thread: *Thread, trap: *arch.SyscallRegs) Error!void {
        return switch (self.type) {
            .null => Error.InvalidCapability,
            .memory => Error.InvalidArgument,
            .thread => Error.InvalidArgument,
            .vmem => Error.InvalidArgument,
            .frame => Error.InvalidArgument,
            .device_frame => Error.InvalidArgument,
            .receiver => Receiver.replyRecv(self.paddr, thread, trap),
            .sender => Error.InvalidArgument,
            .reply => Error.InvalidArgument,
            .notify => Error.InvalidArgument,
            .x86_ioport_allocator => Error.InvalidArgument,
            .x86_ioport => Error.InvalidArgument,
            .x86_irq_allocator => Error.InvalidArgument,
            .x86_irq => Error.InvalidArgument,
        };
    }
};

fn debugType(comptime T: type) void {
    std.log.debug("{s}: size={} align={}", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
}
