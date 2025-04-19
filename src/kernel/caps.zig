const std = @import("std");
const abi = @import("abi");

const arch = @import("arch.zig");
const addr = @import("addr.zig");
const spin = @import("spin.zig");
const pmem = @import("pmem.zig");
const proc = @import("proc.zig");

const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

const LOG_OBJ_CALLS: bool = false;

//

// just x86_64 rn
pub const Entry = packed struct {
    present: u1 = 0,
    writable: u1 = 0,
    user_accessible: u1 = 0,
    write_through: u1 = 0,
    cache_disable: u1 = 0,
    accessed: u1 = 0,
    dirty: u1 = 0,
    // page_attribute_table: u1 = 0,
    huge_page: u1 = 0,
    global: u1 = 0,

    // more custom bits
    _free_to_use1: u3 = 0,

    page_index: u32 = 0,
    reserved: u8 = 0,

    // custom bits
    _free_to_use0: u7 = 0,

    protection_key: u4 = 0,
    no_execute: u1 = 0,

    pub fn fromParts(rights: abi.sys.Rights, frame: addr.Phys, flags: abi.sys.MapFlags) Entry {
        std.debug.assert(frame.toParts().reserved0 == 0);
        std.debug.assert(frame.toParts().reserved1 == 0);

        return Entry{
            .present = 1,
            .writable = @intFromBool(rights.writable),
            .user_accessible = @intFromBool(rights.user_accessible),
            .write_through = @intFromBool(flags.write_through),
            .cache_disable = @intFromBool(flags.cache_disable),
            .huge_page = @intFromBool(flags.huge_page),
            .global = @intFromBool(flags.global),
            .page_index = frame.toParts().page,
            .protection_key = @truncate(flags.protection_key),
            .no_execute = @intFromBool(!rights.executable),
        };
    }
};

// kernel objects \/

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

pub fn capability_array() []Object {
    const len = @min(capability_array_len.load(.acquire), 2 << 32);
    return @as([*]Object, @ptrFromInt(CAPABILITY_ARRAY_POINTER))[0..len];

    // if (len >= (2 << u32)) {
    //     @branchHint(.cold);
    //     capability_array_len.fetchSub(1, .release)
    // }
}

pub fn capability_array_unchecked() []Object {
    return @as([*]Object, @ptrFromInt(CAPABILITY_ARRAY_POINTER))[0 .. 2 << 32];
}

pub fn push_capability(obj: Object) u32 {
    const cap = allocate();

    const new_object = &capability_array_unchecked()[cap];
    new_object.* = .{
        // keep the owner as null until everything else is written
        .paddr = obj.paddr,
        .type = obj.type,
        .children = obj.children,
        .next = obj.next,
    };
    new_object.owner.store(obj.owner.raw, .release);

    return cap;
}

/// returns an object from a capability,
/// some other thread might invalidate the capability during or after this
pub fn get_capability(thread: *Thread, cap_id: u32) Error!Object {
    const caps = capability_array();
    if (cap_id >= caps.len) return Error.InvalidCapability;

    const obj = caps[cap_id];
    if (caps[cap_id].owner.load(.seq_cst) != Thread.vmemOf(thread))
        return Error.InvalidCapability;

    return obj;
}

pub fn call(thread: *Thread, cap_id: u32, trap: *arch.SyscallRegs) Error!usize {
    const obj = try get_capability(thread, cap_id);
    return obj.call(thread, trap);
}

fn allocate() u32 {
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

    const current_len = capability_array_len.raw;
    const new_page_addr = addr.Virt.fromPtr(&capability_array_unchecked().ptr[current_len]);

    const last_byte_of_prev = new_page_addr.raw - 1;
    const last_byte_of_next = new_page_addr.raw + @sizeOf(Object) - 1;
    const last_page = addr.Virt.fromInt(last_byte_of_next);

    const lvl3 = (nextLevelFromEntry(kernel_table[255]) catch
        std.debug.panic("invalid kernel page table", .{})).toHhdm().toPtr(*PageTableLevel3);

    const SIZE_1GIB_MASK = ~(@as(usize, 0x40000000 - 1));
    const SIZE_2MIB_MASK = ~(@as(usize, 0x00200000 - 1));
    const SIZE_4KIB_MASK = ~(@as(usize, 0x00001000 - 1));

    const map_level2 = last_byte_of_prev & SIZE_1GIB_MASK != last_byte_of_next & SIZE_1GIB_MASK;
    const map_level1 = last_byte_of_prev & SIZE_2MIB_MASK != last_byte_of_next & SIZE_2MIB_MASK;
    const map_frame = last_byte_of_prev & SIZE_4KIB_MASK != last_byte_of_next & SIZE_4KIB_MASK;

    if (map_level2 or map_level1 or map_level1) {
        @branchHint(.unlikely);
        array_grow_lock.lock();
        defer array_grow_lock.unlock();

        if (map_level2) {
            @branchHint(.cold);
            lvl3.map_level2(alloc_page(), last_page, .{
                .readable = true,
                .writable = true,
                .user_accessible = false,
            }, .{
                .global = true,
            }) catch std.debug.panic("invalid kernel page table L3", .{});
        }
        if (map_level1) {
            @branchHint(.unlikely);
            lvl3.map_level1(alloc_page(), last_page, .{
                .readable = true,
                .writable = true,
                .user_accessible = false,
            }, .{
                .global = true,
            }) catch std.debug.panic("invalid kernel page table L2", .{});
        }
        if (map_frame) {
            lvl3.map_frame(alloc_page(), last_page, .{
                .readable = true,
                .writable = true,
                .user_accessible = false,
            }, .{
                .global = true,
            }) catch std.debug.panic("invalid kernel page table L1", .{});
        }
    }

    const next = capability_array_len.fetchAdd(1, .acquire);
    if (next > std.math.maxInt(u32)) std.debug.panic("too many capabilities", .{});

    return @truncate(next);
}

fn alloc_page() addr.Phys {
    return addr.Virt.fromPtr(pmem.alloc() orelse std.debug.panic("OOM", .{})).hhdmToPhys();
}

fn deallocate(cap: u32, expected_thread: ?*Thread) bool {
    // FIXME: deallocation is more complicated

    free_list_lock.lock();
    defer free_list_lock.unlock();

    if (free_list != 0) {
        const new_head = &capability_array_unchecked()[cap];
        // zero out all fields
        // owner is zeroed first and in an atomic way,
        // because it is used to check if the capability is partially written (in multi cpu contexts)
        if (null != new_head.owner.cmpxchgStrong(expected_thread, null, .acquire, .monotonic))
            return false;

        new_head.* = .{ .next = free_list };
    }

    free_list = cap;
    return true;
}

/// raw physical memory that can be used to allocate
/// things like more `CapabilityNode`s or things
pub const Memory = struct {
    pub fn init(_: *@This()) void {}

    pub fn call(_: addr.Phys, thread: *Thread, trap: *arch.SyscallRegs) Error!usize {
        const call_id = std.meta.intToEnum(abi.sys.MemoryCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (LOG_OBJ_CALLS)
            log.debug("memory call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .alloc => {
                const obj_ty = std.meta.intToEnum(abi.ObjectType, trap.arg2) catch {
                    return Error.InvalidArgument;
                };

                const obj = try Object.alloc(obj_ty, thread);
                const cap = push_capability(obj);

                return cap;
            },
        }
    }
};

/// thread information
pub const Thread = struct {
    /// all context data
    trap: arch.SyscallRegs = .{},
    /// virtual address space
    vmem: ?Ref(PageTableLevel4) = null,
    /// capability space lock
    caps_lock: spin.Mutex = .new(),
    /// scheduler priority
    priority: u2 = 1,
    /// is the thread stopped OR running/ready/waiting
    stopped: bool = true,
    /// scheduler linked list
    next: ?Ref(Thread) = null,
    /// scheduler linked list
    prev: ?Ref(Thread) = null,

    pub fn init(self: *@This()) void {
        self.* = .{};
    }

    // FIXME: pass Ref(Self) instead of addr.Phys
    pub fn call(paddr: addr.Phys, thread: *Thread, trap: *arch.SyscallRegs) Error!usize {
        const call_id = std.meta.intToEnum(abi.sys.ThreadCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        const target_thread = Ref(Thread){ .paddr = paddr };

        if (LOG_OBJ_CALLS)
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
                const vmem = try (try get_capability(thread, @truncate(trap.arg2))).as(PageTableLevel4);
                target_thread.ptr().vmem = vmem;
                return 0;
            },
            .set_prio => {
                target_thread.ptr().priority = @truncate(trap.arg2);
                return 0;
            },
        }
    }

    fn vmemOf(thread: ?*Thread) ?*PageTableLevel4 {
        const t = thread orelse return null;
        const vmem = t.vmem orelse return null;
        return vmem.ptr();
    }
};

fn nextLevel(current: *[512]Entry, i: u9) Error!addr.Phys {
    return nextLevelFromEntry(current[i]);
}

fn nextLevelFromEntry(entry: Entry) Error!addr.Phys {
    if (entry.present == 0) return error.EntryNotPresent;
    if (entry.huge_page == 1) return error.EntryIsHuge;
    return addr.Phys.fromParts(.{ .page = entry.page_index });
}

pub fn init() !void {
    const cr3 = arch.Cr3.read();
    const level4 = addr.Phys.fromInt(cr3.pml4_phys_base << 12)
        .toHhdm().toPtr(*PageTableLevel4);
    std.mem.copyForwards(Entry, kernel_table[0..], level4.entries[256..]);

    // push the null capability
    _ = push_capability(.{});
}

var kernel_table: [256]Entry = undefined;

// FIXME: flush TLB + IPI other CPUs to prevent race conditions
/// a `Thread` points to this
pub const PageTableLevel4 = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn init(self: *@This()) void {
        self.* = .{};
        std.mem.copyForwards(Entry, self.entries[256..], kernel_table[0..]);
    }

    pub fn map(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        self.entries[vaddr.toParts().level4] = Entry.fromParts(rights, paddr, flags);
    }

    pub fn map_level3(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        try self.map(paddr, vaddr, rights, flags);
    }

    pub fn map_level2(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*PageTableLevel3);
        try next.map_level2(paddr, vaddr, rights, flags);
    }

    pub fn map_level1(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*PageTableLevel3);
        try next.map_level1(paddr, vaddr, rights, flags);
    }

    pub fn map_giant_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*PageTableLevel3);
        try next.map_giant_frame(paddr, vaddr, rights, flags);
    }

    pub fn map_huge_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*PageTableLevel3);
        try next.map_huge_frame(paddr, vaddr, rights, flags);
    }

    pub fn map_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*PageTableLevel3);
        try next.map_frame(paddr, vaddr, rights, flags);
    }
};
/// a `PageTableLevel4` points to multiple of these
pub const PageTableLevel3 = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn init(self: *@This()) void {
        self.* = .{};
    }

    pub fn call(paddr: addr.Phys, thread: *Thread, trap: *arch.SyscallRegs) Error!usize {
        const call_id = std.meta.intToEnum(abi.sys.Lvl3CallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (LOG_OBJ_CALLS)
            log.debug("lvl3 call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .map => {
                const vmem = try (try get_capability(thread, @truncate(trap.arg2))).as(PageTableLevel4);
                const vaddr = try addr.Virt.fromUser(trap.arg3);
                const rights: abi.sys.Rights = @bitCast(@as(u32, @truncate(trap.arg4)));
                const flags: abi.sys.MapFlags = @bitCast(@as(u40, @truncate(trap.arg5)));

                try vmem.ptr().map_level3(paddr, vaddr, rights, flags);
                return 0;
            },
        }
    }

    pub fn map(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) void {
        self.entries[vaddr.toParts().level3] = Entry.fromParts(rights, paddr, flags);
    }

    pub fn map_level2(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        self.map(paddr, vaddr, rights, flags);
    }

    pub fn map_level1(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*PageTableLevel2);
        try next.map_level1(paddr, vaddr, rights, flags);
    }

    pub fn map_giant_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        self.map(paddr, vaddr, rights, flags);
    }

    pub fn map_huge_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*PageTableLevel2);
        try next.map_huge_frame(paddr, vaddr, rights, flags);
    }

    pub fn map_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*PageTableLevel2);
        try next.map_frame(paddr, vaddr, rights, flags);
    }
};
/// a `PageTableLevel3` points to multiple of these
pub const PageTableLevel2 = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn init(self: *@This()) void {
        self.* = .{};
    }

    pub fn call(paddr: addr.Phys, thread: *Thread, trap: *arch.SyscallRegs) Error!usize {
        const call_id = std.meta.intToEnum(abi.sys.Lvl2CallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (LOG_OBJ_CALLS)
            log.debug("lvl2 call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .map => {
                const vmem = try (try get_capability(thread, @truncate(trap.arg2))).as(PageTableLevel4);
                const vaddr = try addr.Virt.fromUser(trap.arg3);
                const rights: abi.sys.Rights = @bitCast(@as(u32, @truncate(trap.arg4)));
                const flags: abi.sys.MapFlags = @bitCast(@as(u40, @truncate(trap.arg5)));

                try vmem.ptr().map_level2(paddr, vaddr, rights, flags);
                return 0;
            },
        }
    }

    pub fn map(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) void {
        self.entries[vaddr.toParts().level2] = Entry.fromParts(rights, paddr, flags);
    }

    pub fn map_level1(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        self.map(paddr, vaddr, rights, flags);
    }

    pub fn map_huge_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        self.map(paddr, vaddr, rights, flags);
    }

    pub fn map_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level2)).toHhdm().toPtr(*PageTableLevel1);
        try next.map_frame(paddr, vaddr, rights, flags);
    }
};
/// a `PageTableLevel2` points to multiple of these
pub const PageTableLevel1 = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn init(self: *@This()) void {
        self.* = .{};
    }

    pub fn call(paddr: addr.Phys, thread: *Thread, trap: *arch.SyscallRegs) Error!usize {
        const call_id = std.meta.intToEnum(abi.sys.Lvl1CallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (LOG_OBJ_CALLS)
            log.debug("lvl1 call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .map => {
                const vmem = try (try get_capability(thread, @truncate(trap.arg2))).as(PageTableLevel4);
                const vaddr = try addr.Virt.fromUser(trap.arg3);
                const rights: abi.sys.Rights = @bitCast(@as(u32, @truncate(trap.arg4)));
                const flags: abi.sys.MapFlags = @bitCast(@as(u40, @truncate(trap.arg5)));

                try vmem.ptr().map_level1(paddr, vaddr, rights, flags);
                return 0;
            },
        }
    }

    pub fn map(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) void {
        self.entries[vaddr.toParts().level1] = Entry.fromParts(rights, paddr, flags);
    }

    pub fn map_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        self.map(paddr, vaddr, rights, flags);
    }
};
/// a `PageTableLevel1` points to multiple of these
///
/// raw physical memory again, but now mappable
/// (and can't be used to allocate things)
pub const Frame = struct {
    data: [512]u64 align(0x1000) = std.mem.zeroes([512]u64),

    pub fn init(self: *@This()) void {
        self.* = .{};
    }

    pub fn call(paddr: addr.Phys, thread: *Thread, trap: *arch.SyscallRegs) Error!usize {
        const call_id = std.meta.intToEnum(abi.sys.FrameCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (LOG_OBJ_CALLS)
            log.debug("frame call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .map => {
                const vmem = try (try get_capability(thread, @truncate(trap.arg2))).as(PageTableLevel4);
                const vaddr = try addr.Virt.fromUser(trap.arg3);
                const rights: abi.sys.Rights = @bitCast(@as(u32, @truncate(trap.arg4)));
                const flags: abi.sys.MapFlags = @bitCast(@as(u40, @truncate(trap.arg5)));

                try vmem.ptr().map_frame(paddr, vaddr, rights, flags);
                return 0;
            },
        }
    }
};

pub fn Ref(comptime T: type) type {
    return struct {
        paddr: addr.Phys,

        const Self = @This();

        pub fn alloc() Error!Self {
            std.debug.assert(std.mem.isAligned(0x1000, @alignOf(T)));

            const N_PAGES = comptime std.math.divCeil(usize, @sizeOf(T), 0x1000) catch unreachable;

            const paddr = if (@sizeOf(T) == 0)
                addr.Phys.fromInt(0)
            else
                try @import("init.zig").alloc(N_PAGES);
            const obj = Self{ .paddr = paddr };
            obj.ptr().init();

            return obj;
        }

        pub fn ptr(self: @This()) *T {
            // recursive mapping instead of HHDM later (maybe)
            return self.paddr.toHhdm().toPtr(*T);
        }

        pub fn object(self: @This(), owner: ?*Thread) Object {
            return Object{
                .paddr = self.paddr,
                .type = Object.objectTypeOf(T),
                .owner = .init(Thread.vmemOf(owner)),
            };
        }
    };
}

pub const Object = struct {
    paddr: addr.Phys = .{ .raw = 0 },
    type: abi.ObjectType = .null,
    // lock: spin.Mutex = .new(),
    owner: std.atomic.Value(?*PageTableLevel4) = .init(null),

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
        };
    }

    pub fn call(self: Self, thread: *Thread, trap: *arch.SyscallRegs) Error!usize {
        return switch (self.type) {
            .null => Error.InvalidCapability,
            .memory => Memory.call(self.paddr, thread, trap),
            .thread => Thread.call(self.paddr, thread, trap),
            .page_table_level_4 => Error.Unimplemented,
            .page_table_level_3 => PageTableLevel3.call(self.paddr, thread, trap),
            .page_table_level_2 => PageTableLevel2.call(self.paddr, thread, trap),
            .page_table_level_1 => PageTableLevel1.call(self.paddr, thread, trap),
            .frame => Frame.call(self.paddr, thread, trap),
        };
    }
};

fn debug_type(comptime T: type) void {
    std.log.info("{s}: size={} align={}", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
}
