const std = @import("std");

const pmem = @import("pmem.zig");
const arch = @import("arch.zig");

const log = std.log.scoped(.vmem);

//

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

        const table = allocTable();
        const cr3 = pmem.HhdmAddr.new(table).toPhys().toPage();
        const res = Self{
            .cr3 = cr3,
        };

        log.info("cr3: 0x{x}", .{arch.x86_64.rdcr3()});

        // map global higher half
        // res.map();

        return res;
    }

    pub fn map(dst: pmem.VirtAddr, src: MapSource, flags: Entry) void {
        _ = .{ dst, src, flags };
    }
};

    pub fn map(addr_space: *const Self, dst: pmem.VirtAddr, src: MapSource, flags: Entry) void {
        _ = .{ addr_space, dst, src, flags };

        log.info("0b{b}", .{dst.raw});

        log.info("{any}", .{.{
            dst.raw,
            dst.offset(),
            dst.levels(),
        }});
    }
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

//

pub fn allocTable() *PageTable {
    const page = pmem.alloc() orelse {
        std.debug.panic("virtual memory page table OOM", .{});
    };
    return @ptrCast(page);
}

pub fn freeTable(t: *PageTable) void {
    pmem.free(@ptrCast(t));
}
