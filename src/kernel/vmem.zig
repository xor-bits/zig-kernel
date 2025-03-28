const std = @import("std");

const pmem = @import("pmem.zig");
const arch = @import("arch.zig");
const lazy = @import("lazy.zig");

const log = std.log.scoped(.vmem);

//

pub const KERNEL_BOTTOM = pmem.VirtAddr.fromParts(0, .{ 0, 0, 510, 511 });
pub const KERNEL_HEAP_BOTTOM = pmem.VirtAddr.fromParts(0, .{ 0, 0, 0, 510 });
pub const KERNEL_HEAP_TOP = pmem.VirtAddr.fromParts(0, .{ 0, 0, 0, 511 });

// lvl4 entries from [256..]
var global_higher_half = lazy.Lazy([256]Entry).new();

//

/// create a deep copy of the bootloader given higher half (kernel + modules + HHDM + stack) page map
/// then mark everything in higher half as global
///
/// the deep copy is needed, because the tree structure is stored
/// in bootloader_reclaimable memory, which will be freed
pub fn init() void {
    _ = global_higher_half.getOrInit(struct {
        pub fn init() [256]Entry {
            const current = AddressSpace.current();
            var to_table: [256]Entry = undefined;
            const from_table: *PageTable = physPageAsPageTable(current.cr3);

            // allocate the heap pml4 if the heap has not been used yet
            const heap_entry = &from_table[KERNEL_HEAP_BOTTOM.levels()[3]];
            if (heap_entry.present != 1) {
                const allocated = pmem.HhdmAddr.new(allocZeroedTable()).toPhys().toPage();
                heap_entry.page_index = allocated.page_index;
                heap_entry.present = 1;
                heap_entry.writeable = 1;
                heap_entry.no_execute = 1;
                heap_entry.user_accessible = 0;
            }

            for (0..256) |i| {
                deepClone(&from_table[i + 256], &to_table[i], 3);
            }

            return to_table;
        }
    });
}

/// create a deep copy of the higher half mappings
/// NOTE: does not copy any target pages
fn deepClone(from: *const Entry, to: *Entry, level: usize) void {
    var tmp = from.*;
    tmp.page_index = 0;
    tmp.global = 1;

    if (level != 1 and from.present != 0) {
        const to_table = allocTable();
        const from_table: *const PageTable = physPageAsPageTable(pmem.PhysPage.new(from.page_index));

        for (0..512) |i| {
            deepClone(&from_table[i], &to_table[i], level - 1);
        }
    }

    to.* = from.*;
}

//

pub const Privilege = enum(u3) {
    kernel = 0, // ring 0
    user = 3, // ring 3
};

pub const PageSize = enum {
    size512gib,
    size1gib,
    size2mib,
    size4kib,
};

pub const Entry = packed struct {
    present: u1 = 0,
    writeable: u1 = 0,
    user_accessible: u1 = 0,
    write_through: u1 = 0,
    cache_disable: u1 = 0,
    accessed: u1 = 0,
    dirty: u1 = 0,
    // page_attribute_table: u1 = 0,
    huge_page: u1 = 0,
    global: u1 = 0,

    // more custom bits
    copy_on_write: u1 = 0, // page fault == make a copy of the page and mark it writeable
    lazy_alloc: u1 = 0, //    page fault == allocate now (overcommit)
    no_free: u1 = 0, //       pages that should never be deallocated, like kernel pages

    page_index: u32 = 0,
    reserved: u8 = 0,

    // custom bits
    _free_to_use0: u7 = 0,

    protection_key: u4 = 0,
    no_execute: u1 = 0,
};

pub const PageTable = [512]Entry;

pub const PhysPages = struct {
    first: pmem.PhysPage,
    len: usize,
};

pub const MapSource = union(enum) {
    /// map pages immediately, but the VMM **IS NOT** allowed to free them
    borrow: PhysPages,

    /// map pages immediately, and the VMM **IS** allowed to free them
    owned: PhysPages,

    /// allocate pages immediately, and write bytes into them
    bytes: []const u8,

    /// allocate (n divceil 0x1000) pages on page fault (overcommit) (lazy physical memory allocation)
    lazy: usize,

    /// allocate (n divceil 0x1000) immediately
    prealloc: usize,
};

pub const AddressSpace = struct {
    cr3: pmem.PhysPage,

    const Self = @This();

    pub fn new() Self {

        // TODO: copy the original l4[256..] into some global higher half (kernel address) thing
        // each address space is just the lower part (unique to each address space)
        // and the higher part (shared between all of them, its the kernel and HHDM and things)
        // NOTE: the higher half part can also use the GLOBAL bit to never lose it from the tlb cache
        // because the kernel is always in the virtual address space anyways

        // TODO: process id in CR3

        // TODO: set bit 7 (global enable) in CR4

        const table = allocZeroedTable();
        const cr3 = pmem.HhdmAddr.new(table).toPhys().toPage();
        const res = Self{
            .cr3 = cr3,
        };

        // map global higher half
        res.mapGlobals();

        return res;
    }

    pub fn current() Self {
        const cr3 = arch.x86_64.rdcr3();
        return Self{
            .cr3 = pmem.PhysAddr.new(cr3).toPage(),
        };
    }

    pub fn isCurrent(self: Self) bool {
        const current_cr3: u64 = arch.x86_64.rdcr3();
        const next_cr3: u64 = @as(u64, self.cr3.page_index) << 12;
        return next_cr3 == current_cr3;
    }

    pub fn switchTo(self: Self) void {
        if (self.isCurrent()) {
            return;
        }

        arch.x86_64.wrcr3(@as(u64, self.cr3.page_index) << 12);
        // log.info("cr3 is now 0x{x}", .{arch.x86_64.rdcr3()});
    }

    pub fn deinit(self: Self) void {
        _ = self;
        // TODO:
    }

    pub fn map(self: Self, dst: pmem.VirtAddr, src: MapSource, _flags: Entry) void {
        // TODO: huge page support maybe
        // it would require the pmem allocator to have huge page support aswell

        // FIXME: stop the whole process, IPI other processors out of there and then start it again
        // to avoid race conditions

        switch (src) {
            .borrow, .owned => std.debug.panic("TODO: borrow and owned mapping", .{}),
            .bytes => |bytes| {
                self.mapImmediate(dst, bytes.len, _flags);
                self.writeBytes(dst, bytes, null) catch unreachable;
            },
            .lazy => |bytes| {
                self.mapLazy(dst, bytes, _flags);
            },
            .prealloc => |bytes| {
                self.mapImmediate(dst, bytes, _flags);
            },
        }

        if (self.isCurrent()) {
            arch.x86_64.flush_tlb();
        }
    }

    /// write a slice of bytes `_src` (from the current address space)
    /// into possibly inactive address space `self`
    /// at address `_dst`
    ///
    /// if `perms` is not `null`, URWX permissions get checked using that permission level
    pub fn writeBytes(self: Self, dst: pmem.VirtAddr, _src: []const u8, perms: ?Privilege) error{NotMapped}!void {
        _ = perms; // autofix
        // TODO: use memcpy under some specific cases (mapped & `perms == .kernel`)

        var src = _src;

        const whole_pages_start = std.mem.alignForward(usize, dst.raw, 0x1000);

        // write the first non-whole page
        if (whole_pages_start != dst.raw) {
            const n = @min(whole_pages_start - dst.raw, src.len);
            const paddr = self.translate(dst, true) orelse return error.NotMapped;

            const dst_bytes = paddr.toHhdm().ptr([*]u8);
            std.mem.copyForwards(u8, dst_bytes[0..n], src[0..n]);
            src = src[n..];
        }

        // write the middle whole pages
        const whole_pages = src.len >> 12;
        for (0..whole_pages) |i| {
            const offs = i * 0x1000;
            const paddr = self.translate(pmem.VirtAddr.new(whole_pages_start + offs), true) orelse return error.NotMapped;

            const dst_bytes = paddr.toHhdm().ptr([*]u8);
            std.mem.copyForwards(u8, dst_bytes[0..0x1000], src[offs .. offs + 0x1000]);
        }

        // write the last non-whole page
        const last_page_size = src.len & ((1 << 12) - 1);
        if (last_page_size != 0) {
            const offs = whole_pages * 0x1000;
            const paddr = self.translate(pmem.VirtAddr.new(whole_pages_start + offs), true) orelse return error.NotMapped;

            const dst_bytes = paddr.toHhdm().ptr([*]u8);
            std.mem.copyForwards(u8, dst_bytes[0..last_page_size], src[offs .. offs + last_page_size]);
        }
    }

    pub fn readBytes(self: Self, _dst: []u8, src: pmem.VirtAddr, perms: ?Privilege) error{NotMapped}!void {
        _ = perms; // autofix
        // TODO: use memcpy under some specific cases (mapped & `perms == .kernel`)

        var dst = _dst;

        const whole_pages_start = std.mem.alignForward(usize, src.raw, 0x1000);

        // read the first non-whole page
        if (whole_pages_start != src.raw) {
            const n = @min(whole_pages_start - src.raw, dst.len);
            // TODO: instead of triggering the lazy here,
            // we could read from some global const zero page
            // to avoid allocating
            const paddr = self.translate(src, true) orelse return error.NotMapped;

            const src_bytes = paddr.toHhdm().ptr([*]u8);
            std.mem.copyForwards(u8, dst[0..n], src_bytes[0..n]);
            dst = dst[n..];
        }

        // read the middle whole pages
        const whole_pages = dst.len >> 12;
        for (0..whole_pages) |i| {
            const offs = i * 0x1000;
            const paddr = self.translate(pmem.VirtAddr.new(whole_pages_start + offs), true) orelse return error.NotMapped;

            const src_bytes = paddr.toHhdm().ptr([*]u8);
            std.mem.copyForwards(u8, src_bytes[0..0x1000], dst[offs .. offs + 0x1000]);
        }

        // read the last non-whole page
        const last_page_size = dst.len & ((1 << 12) - 1);
        if (last_page_size != 0) {
            const offs = whole_pages * 0x1000;
            const paddr = self.translate(pmem.VirtAddr.new(whole_pages_start + offs), true) orelse return error.NotMapped;

            const src_bytes = paddr.toHhdm().ptr([*]u8);
            std.mem.copyForwards(u8, src_bytes[0..last_page_size], dst[offs .. offs + last_page_size]);
        }
    }

    pub fn copyBytes(self: Self, dst: pmem.VirtAddr, _src: []const u8, perms: ?Privilege) error{NotMapped}!void {
        _ = self; // autofix
        _ = dst; // autofix
        _ = _src; // autofix
        _ = perms; // autofix
        std.debug.panic("TODO", .{});
    }

    fn mapLazy(self: Self, dst: pmem.VirtAddr, bytes: usize, _flags: Entry) void {
        const flags = Entry{
            .lazy_alloc = 1,
            .writeable = _flags.writeable,
            .no_execute = _flags.no_execute,
            .user_accessible = _flags.user_accessible,
        };

        const first_page = std.mem.alignBackward(usize, dst.raw, 0x1000);
        const zeroes_beg = dst.raw - first_page;
        const n_pages = std.mem.alignForward(usize, zeroes_beg + bytes, 0x1000) >> 12;

        log.info("mapping {d} pages", .{n_pages});
        for (0..n_pages) |i| {
            const offs = i * 0x1000;
            const vaddr = pmem.VirtAddr.new(first_page + offs);
            self.mapSingle(vaddr, flags);
        }
    }

    fn mapImmediate(self: Self, dst: pmem.VirtAddr, bytes: usize, _flags: Entry) void {
        var flags = Entry{
            .present = 1,
            .writeable = _flags.writeable,
            .no_execute = _flags.no_execute,
            .user_accessible = _flags.user_accessible,
        };

        const first_page = std.mem.alignBackward(usize, dst.raw, 0x1000);
        const zeroes_beg = dst.raw - first_page;
        const n_pages = std.mem.alignForward(usize, zeroes_beg + bytes, 0x1000) >> 12;

        log.info("mapping {d} pages", .{n_pages});
        for (0..n_pages) |i| {
            const offs = i * 0x1000;
            const vaddr = pmem.VirtAddr.new(first_page + offs);
            flags.page_index = pmem.HhdmAddr.new(allocZeroedTable()).toPhys().toPage().page_index;
            self.mapSingle(vaddr, flags);
        }
    }

    fn mapSingle(self: Self, dst: pmem.VirtAddr, entry: Entry) void {
        const levels = dst.levels();

        const l4entries = self.root();
        const l4entry = &l4entries[levels[3]];

        if (l4entry.present == 0) {
            const allocated = pmem.HhdmAddr.new(allocZeroedTable()).toPhys().toPage();
            l4entry.page_index = allocated.page_index;
            l4entry.present = 1;
            l4entry.writeable = 1;
            l4entry.user_accessible = 1;
        }

        const l3entries = physPageAsPageTable(pmem.PhysPage.new(l4entry.page_index));
        const l3entry = &l3entries[levels[2]];

        std.debug.assert(l3entry.huge_page == 0);
        if (l3entry.present == 0) {
            const allocated = pmem.HhdmAddr.new(allocZeroedTable()).toPhys().toPage();
            l3entry.page_index = allocated.page_index;
            l3entry.present = 1;
            l3entry.writeable = 1;
            l3entry.user_accessible = 1;
        }

        const l2entries = physPageAsPageTable(pmem.PhysPage.new(l3entry.page_index));
        const l2entry = &l2entries[levels[1]];

        std.debug.assert(l2entry.huge_page == 0);
        if (l2entry.present == 0) {
            const allocated = pmem.HhdmAddr.new(allocZeroedTable()).toPhys().toPage();
            l2entry.page_index = allocated.page_index;
            l2entry.present = 1;
            l2entry.writeable = 1;
            l2entry.user_accessible = 1;
        }

        const l1entries = physPageAsPageTable(pmem.PhysPage.new(l2entry.page_index));
        const l1entry = &l1entries[levels[0]];

        if (l1entry.present == 1 and l1entry.no_free == 0) {
            // map over the old mapping
            freeTable(pmem.PhysPage.new(l1entry.page_index).toPhys().toHhdm().ptr(*PageTable));
        }

        l1entry.* = entry;
    }

    pub fn pageFault(self: Self, vaddr: pmem.VirtAddr, user: bool, write: bool) error{Handled}!void {
        const levels = vaddr.levels();

        const l4entries = self.root();
        const l4entry = &l4entries[levels[3]];

        if (l4entry.present == 0 or
            (user and l4entry.user_accessible == 0) or
            (write and l4entry.writeable == 0))
        {
            return;
        }

        const l3entries = physPageAsPageTable(pmem.PhysPage.new(l4entry.page_index));
        const l3entry = &l3entries[levels[2]];

        std.debug.assert(l3entry.huge_page == 0);
        if (l3entry.present == 0 or
            (user and l3entry.user_accessible == 0) or
            (write and l3entry.writeable == 0))
        {
            return;
        }

        const l2entries = physPageAsPageTable(pmem.PhysPage.new(l3entry.page_index));
        const l2entry = &l2entries[levels[1]];

        std.debug.assert(l2entry.huge_page == 0);
        if (l2entry.present == 0 or
            (user and l2entry.user_accessible == 0) or
            (write and l2entry.writeable == 0))
        {
            return;
        }

        const l1entries = physPageAsPageTable(pmem.PhysPage.new(l2entry.page_index));
        const l1entry = &l1entries[levels[0]];

        if ((user and l1entry.user_accessible == 0) or
            (write and l1entry.writeable == 0))
        {
            return;
        }

        if (l1entry.lazy_alloc != 0) {
            triggerLazyEntry(l1entry);
            return error.Handled;
        }
    }

    pub fn translate(self: Self, vaddr: pmem.VirtAddr, triggers_lazy: bool) ?pmem.PhysAddr {
        const levels = vaddr.levels();

        const l4entries = self.root();
        const l4entry = &l4entries[levels[3]];

        if (l4entry.present == 0) {
            return null;
        }

        const l3entries = physPageAsPageTable(pmem.PhysPage.new(l4entry.page_index));
        const l3entry = &l3entries[levels[2]];

        std.debug.assert(l3entry.huge_page == 0);
        if (l3entry.present == 0) {
            return null;
        }

        const l2entries = physPageAsPageTable(pmem.PhysPage.new(l3entry.page_index));
        const l2entry = &l2entries[levels[1]];

        std.debug.assert(l2entry.huge_page == 0);
        if (l2entry.present == 0) {
            return null;
        }

        const l1entries = physPageAsPageTable(pmem.PhysPage.new(l2entry.page_index));
        const l1entry = &l1entries[levels[0]];

        if (l1entry.present == 0) {
            if (triggers_lazy and l1entry.lazy_alloc != 0) {
                triggerLazyEntry(l1entry);
            } else {
                return null;
            }
        }

        const page_start = pmem.PhysPage.new(l1entry.page_index).toPhys();
        return pmem.PhysAddr.new(page_start.raw + vaddr.offset());
    }

    // trigger a lazy page to allocate,
    // assumes the entry to be lazy
    fn triggerLazyEntry(entry: *Entry) void {
        const allocated = pmem.HhdmAddr.new(allocZeroedTable()).toPhys().toPage();
        entry.page_index = allocated.page_index;
        entry.lazy_alloc = 0;
        entry.present = 1;
    }

    pub fn mapGlobals(self: Self) void {
        const to_table = self.root();
        const from_table = global_higher_half.get().?;

        for (0..256) |i| {
            to_table[i + 256] = from_table[i];
        }
    }

    fn root(self: Self) *PageTable {
        return physPageAsPageTable(self.cr3);
    }

    pub fn printMappings(self: Self) void {
        // go through every single page in this address space,
        // and print contiguous similar chunks.

        // only present and lazy alloc pages are printed

        const Current = struct {
            base: pmem.VirtAddr,
            target: pmem.PhysAddr,
            write: bool,
            exec: bool,
            user: bool,

            fn fromEntry(from: pmem.VirtAddr, e: Entry) @This() {
                return .{
                    .base = from,
                    .target = pmem.PhysPage.new(e.page_index).toPhys(),
                    .write = e.writeable != 0,
                    .exec = e.no_execute == 0,
                    .user = e.user_accessible != 0,
                };
            }

            fn isContiguous(a: @This(), b: @This()) bool {
                if (a.write != b.write or a.exec != b.exec or a.user != b.user) {
                    return false;
                }

                const a_diff: i128 = @truncate(@as(i128, a.base.raw) - @as(i128, a.target.raw));
                const b_diff: i128 = @truncate(@as(i128, a.base.raw) - @as(i128, a.target.raw));

                return a_diff == b_diff;
            }

            fn printRange(from: @This(), to: pmem.VirtAddr) void {
                log.info("{s}R{s}{s} [ 0x{x:0>16}..0x{x:0>16} ] => 0x{x:0>16}", .{
                    if (from.user) "U" else "-",
                    if (from.write) "W" else "-",
                    if (from.exec) "X" else "-",
                    from.base.raw,
                    to.raw,
                    from.target.raw,
                });
            }
        };

        self.walkPages(struct {
            maybe_base: ?Current = null,

            fn missing(s: *@This(), _: PageSize, vaddr: pmem.VirtAddr, _: Entry) void {
                if (s.maybe_base) |base| {
                    base.printRange(vaddr);
                    s.maybe_base = null;
                }
            }

            fn present(s: *@This(), _: PageSize, vaddr: pmem.VirtAddr, entry: Entry) void {
                const cur = Current.fromEntry(vaddr, entry);
                const base: Current = s.maybe_base orelse {
                    s.maybe_base = cur;
                    return;
                };

                if (!base.isContiguous(cur)) {
                    base.printRange(vaddr);
                    s.maybe_base = cur;
                    return;
                }
            }
        }{});
    }

    fn walkPages(self: @This(), _callback: anytype) void {
        var callback = _callback;
        const l4entries: *const PageTable = physPageAsPageTable(self.cr3);

        for (0..512) |_l4| {
            const l4: u9 = @truncate(_l4);
            const l4vaddr = pmem.VirtAddr.fromParts(0, .{ 0, 0, 0, l4 });
            const l4entry = l4entries[l4];

            if (l4entry.present == 0) {
                callback.missing(PageSize.size512gib, l4vaddr, l4entry);
                continue;
            }

            const l3entries: *const PageTable = physPageAsPageTable(pmem.PhysPage.new(l4entry.page_index));

            for (0..512) |_l3| {
                const l3: u9 = @truncate(_l3);
                const l3vaddr = pmem.VirtAddr.fromParts(0, .{ 0, 0, l3, l4 });
                const l3entry = l3entries[l3];

                if (l3entry.present == 0) {
                    callback.missing(PageSize.size1gib, l3vaddr, l3entry);
                    continue;
                }

                if (l3entry.huge_page != 0) {
                    callback.present(PageSize.size1gib, l3vaddr, l3entry);
                    continue;
                }

                const l2entries: *const PageTable = physPageAsPageTable(pmem.PhysPage.new(l3entry.page_index));

                for (0..512) |_l2| {
                    const l2: u9 = @truncate(_l2);
                    const l2vaddr = pmem.VirtAddr.fromParts(0, .{ 0, l2, l3, l4 });
                    const l2entry = l2entries[l2];

                    if (l2entry.present == 0) {
                        callback.missing(PageSize.size2mib, l2vaddr, l2entry);
                        continue;
                    }

                    if (l2entry.huge_page != 0) {
                        callback.present(PageSize.size2mib, l2vaddr, l2entry);
                        continue;
                    }

                    const l1entries: *const PageTable = physPageAsPageTable(pmem.PhysPage.new(l2entry.page_index));

                    for (0..512) |_l1| {
                        const l1: u9 = @truncate(_l1);
                        const l1vaddr = pmem.VirtAddr.fromParts(0, .{ l1, l2, l3, l4 });
                        const l1entry = l1entries[l1];

                        if (l1entry.present == 0) {
                            callback.missing(PageSize.size4kib, l1vaddr, l1entry);
                            continue;
                        }

                        callback.present(PageSize.size4kib, l1vaddr, l1entry);
                    }
                }
            }
        }
    }
};

//

fn physPageAsPageTable(p: pmem.PhysPage) *PageTable {
    return p.toPhys().toHhdm().ptr(*PageTable);
}

fn allocTable() *PageTable {
    const page = pmem.alloc() orelse {
        std.debug.panic("virtual memory page table OOM", .{});
    };
    // log.info("new table 0x{x}", .{@as(u64, @intFromPtr(page))});
    return @ptrCast(page);
}

fn allocZeroedTable() *PageTable {
    const new_table = allocTable();
    new_table.* = std.mem.zeroes(PageTable);
    return new_table;
}

fn freeTable(t: *PageTable) void {
    pmem.free(@ptrCast(t));
}
