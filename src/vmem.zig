const std = @import("std");

const pmem = @import("pmem.zig");
const arch = @import("arch.zig");
const lazy = @import("lazy.zig");

const log = std.log.scoped(.vmem);

//

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
            const from_table: *const PageTable = physPageAsPageTable(current.cr3);

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

    /// allocate pages on page fault (overcommit) (lazy physical memory allocation)
    lazy: void,
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

        const table = allocTable();
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

    pub fn switchTo(self: Self) void {
        arch.x86_64.wrcr3(@as(u64, self.cr3.page_index) << 12);
        log.info("cr3 is now 0x{x}", .{arch.x86_64.rdcr3()});
    }

    pub fn deinit(self: Self) void {
        _ = self;
        // TODO:
    }

    pub fn map(addr_space: Self, dst: pmem.VirtAddr, src: MapSource, flags: Entry) void {
        _ = .{ addr_space, dst, src, flags };
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
                if (from.base.raw > 0xffff_8000_3000_0000 and from.base.raw < 0xffff_ffff_8000_0000) {
                    return;
                }

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

fn freeTable(t: *PageTable) void {
    pmem.free(@ptrCast(t));
}
