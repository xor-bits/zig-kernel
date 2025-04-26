const std = @import("std");
const abi = @import("abi");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");
const spin = @import("../spin.zig");

const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub fn init() !void {
    const cr3 = arch.Cr3.read();
    const level4 = addr.Phys.fromInt(cr3.pml4_phys_base << 12)
        .toHhdm().toPtr(*PageTableLevel4);
    std.mem.copyForwards(Entry, kernel_table[0..], level4.entries[256..]);
}

var kernel_table: [256]Entry = undefined;

//

pub fn growCapArray() u32 {
    const current_len = caps.capability_array_len.raw;
    const new_page_addr = addr.Virt.fromPtr(&caps.capability_array_unchecked().ptr[current_len]);

    const last_byte_of_prev = new_page_addr.raw - 1;
    const last_byte_of_next = new_page_addr.raw + @sizeOf(caps.Object) - 1;
    const last_page = addr.Virt.fromInt(last_byte_of_next);

    const lvl3 = (nextLevelFromEntry(kernel_table[255]) catch
        std.debug.panic("invalid kernel page table", .{})).toHhdm().toPtr(*PageTableLevel3);

    const SIZE_1GIB_MASK = ~(@as(usize, 0x40000000 - 1));
    const SIZE_2MIB_MASK = ~(@as(usize, 0x00200000 - 1));
    const SIZE_4KIB_MASK = ~(@as(usize, 0x00001000 - 1));

    const map_level2 = last_byte_of_prev & SIZE_1GIB_MASK != last_byte_of_next & SIZE_1GIB_MASK;
    const map_level1 = last_byte_of_prev & SIZE_2MIB_MASK != last_byte_of_next & SIZE_2MIB_MASK;
    const map_frame = last_byte_of_prev & SIZE_4KIB_MASK != last_byte_of_next & SIZE_4KIB_MASK;

    if (map_level2 or map_level1 or map_frame) {
        @branchHint(.unlikely);
        caps.array_grow_lock.lock();
        defer caps.array_grow_lock.unlock();

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

    const next = caps.capability_array_len.fetchAdd(1, .acquire);
    if (next > std.math.maxInt(u32)) std.debug.panic("too many capabilities", .{});

    return @truncate(next);
}

fn alloc_page() addr.Phys {
    return pmem.alloc(0x1000) orelse std.debug.panic("OOM", .{});
}

fn nextLevel(current: *[512]Entry, i: u9) Error!addr.Phys {
    return nextLevelFromEntry(current[i]);
}

fn nextLevelFromEntry(entry: Entry) Error!addr.Phys {
    if (entry.present == 0) return error.EntryNotPresent;
    if (entry.huge_page == 1) return error.EntryIsHuge;
    return addr.Phys.fromParts(.{ .page = entry.page_index });
}

// FIXME: flush TLB + IPI other CPUs to prevent race conditions
/// a `Thread` points to this
pub const PageTableLevel4 = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn init(self: *@This()) void {
        self.* = .{};
        std.mem.copyForwards(Entry, self.entries[256..], kernel_table[0..]);
    }

    pub fn canAlloc() bool {
        return true;
    }

    pub fn switchTo(self: caps.Ref(@This())) void {
        var cur = arch.Cr3.read();
        if (cur.pml4_phys_base == self.paddr.raw) return;
        cur.pml4_phys_base = self.paddr.toParts().page;
        cur.write();
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

    pub fn canAlloc() bool {
        return true;
    }

    pub fn call(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.Lvl3CallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (caps.LOG_OBJ_CALLS)
            log.debug("lvl3 call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .map => {
                const vmem = try (try caps.get_capability(thread, @truncate(trap.arg2))).as(PageTableLevel4);
                const vaddr = try addr.Virt.fromUser(trap.arg3);
                const rights: abi.sys.Rights = @bitCast(@as(u32, @truncate(trap.arg4)));
                const flags: abi.sys.MapFlags = @bitCast(@as(u40, @truncate(trap.arg5)));

                try vmem.ptr().map_level3(paddr, vaddr, rights, flags);
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

    pub fn canAlloc() bool {
        return true;
    }

    pub fn call(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.Lvl2CallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (caps.LOG_OBJ_CALLS)
            log.debug("lvl2 call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .map => {
                const vmem = try (try caps.get_capability(thread, @truncate(trap.arg2))).as(PageTableLevel4);
                const vaddr = try addr.Virt.fromUser(trap.arg3);
                const rights: abi.sys.Rights = @bitCast(@as(u32, @truncate(trap.arg4)));
                const flags: abi.sys.MapFlags = @bitCast(@as(u40, @truncate(trap.arg5)));

                try vmem.ptr().map_level2(paddr, vaddr, rights, flags);
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

    pub fn canAlloc() bool {
        return true;
    }

    pub fn call(paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.Lvl1CallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (caps.LOG_OBJ_CALLS)
            log.debug("lvl1 call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .map => {
                const vmem = try (try caps.get_capability(thread, @truncate(trap.arg2))).as(PageTableLevel4);
                const vaddr = try addr.Virt.fromUser(trap.arg3);
                const rights: abi.sys.Rights = @bitCast(@as(u32, @truncate(trap.arg4)));
                const flags: abi.sys.MapFlags = @bitCast(@as(u40, @truncate(trap.arg5)));

                try vmem.ptr().map_level1(paddr, vaddr, rights, flags);
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
