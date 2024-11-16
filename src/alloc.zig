const std = @import("std");
const limine = @import("limine");

const main = @import("main.zig");
const lazy = @import("lazy.zig");

//

pub export var memory: limine.MemoryMapRequest = .{};

//

pub const page_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &page_allocator_vtable,
};
const page_allocator_vtable = std.mem.Allocator.VTable{
    .alloc = &_alloc,
    .resize = &_resize,
    .free = &_free,
};

//

pub const Page = [512]u64;

//

pub fn printInfo() void {
    const memory_response: *limine.MemoryMapResponse = memory.response orelse {
        return;
    };

    var usable_memory: usize = 0;
    for (memory_response.entries()) |memory_map_entry| {
        const from = memory_map_entry.base;
        const to = memory_map_entry.base + memory_map_entry.length;
        const len = memory_map_entry.length;

        usable_memory += len;
        const ty = @tagName(memory_map_entry.kind);
        std.log.scoped(.alloc).info("{s:>22}: [ 0x{x:0>16}..0x{x:0>16} ]", .{ ty, from, to });
    }

    std.log.scoped(.alloc).info("usable memory: {d}kB", .{usable_memory >> 12});
}

//

/// tells if the frame allocator can be used already
var pfa_lazy_init = lazy.LazyInit.new();

/// base physical address from where the refcount array starts from
var base: usize = undefined;

/// each page has a ref counter, 0 = not allocated, N = N process(es) is using it
var page_refcounts: []u8 = undefined;

/// just an atomic index hint to rotate around the memory instead of starting the
/// finding process from 0 every time, because pages arent usually freed almost instantly
var next: usize = 0;

fn physToPtr(comptime T: type, phys: usize) *T {
    return @ptrFromInt(phys + main.hhdm_offset);
}

fn ptrToPhys(ptr: *anyopaque) usize {
    return @intFromPtr(ptr) - main.hhdm_offset;
}

fn physToIndex(phys: usize) !usize {
    if (phys < base) {
        @setCold(true);
        return error.OutOfBounds;
    }

    return (phys - base) >> 12;
}

fn allocateContiguous(n_pages: usize) ?[]Page {
    const hint = @atomicRmw(
        usize,
        &next,
        std.builtin.AtomicRmwOp.Add,
        n_pages,
        std.builtin.AtomicOrder.monotonic,
    ) % page_refcounts.len;

    if (allocateContiguousFrom(n_pages, hint)) |pages| {
        return pages;
    }

    if (allocateContiguousFrom(0, hint)) |pages| {
        return pages;
    }

    std.log.scoped(.alloc).err("OOM", .{});
    return null;
}

fn allocateContiguousFrom(n_pages: usize, from: usize) ?[]Page {
    const total_pages = page_refcounts.len;
    var first_page = from;

    while (true) {
        if (total_pages < first_page + n_pages) {
            return null;
        }

        // lock pages in a reverse order
        for (0..n_pages) |_i| {
            const i = n_pages - _i - 1;
            const page = first_page + i;

            if (!allocate(&page_refcounts[page])) {
                // one couldn't be allocated
                // deallocate everything that was allocated and move on
                for (0.._i) |_j| {
                    const j = n_pages - _j - 1;
                    const extra_page = first_page + j;

                    // TODO: deallocaton isn't needed here,
                    // the next slot allocates these immediately again
                    deallocate(&page_refcounts[extra_page]);
                }

                first_page += i + 1;
                break;
            }
        } else {
            const pages: [*]Page = @ptrCast(physToPtr(Page, base + first_page * (1 << 12)));
            return pages[0..n_pages];
        }
    }

    // for (0..page_refcounts.len) |_i| {
    //     ;
    // }
}

fn deallocateContiguous(pages: []Page) void {
    for (pages) |*page| {
        const page_i = physToIndex(ptrToPhys(page)) catch unreachable;
        deallocate(&page_refcounts[page_i]);
    }
}

fn deallocateContiguousZeroed(pages: []Page) void {
    for (pages) |*page| {
        const page_i = physToIndex(ptrToPhys(page)) catch unreachable;
        deallocate(&page_refcounts[page_i]);
    }
}

fn allocate(refcount: *u8) bool {
    // std.log.scoped(.alloc).err("{any}", .{page_refcounts});
    // const bef = @atomicLoad(u8, refcount, std.builtin.AtomicOrder.acquire);
    const val = @cmpxchgStrong(u8, refcount, 0, 1, std.builtin.AtomicOrder.acquire, std.builtin.AtomicOrder.monotonic);
    // std.log.scoped(.alloc).err("{any} {any}", .{ bef, val });
    return val == null;
}

fn deallocate(refcount: *u8) void {
    @atomicStore(u8, refcount, 0, std.builtin.AtomicOrder.release);
}

//

fn tryInit() void {
    pfa_lazy_init.waitOrInit(init);
}

fn init() void {
    var usable_memory: usize = 0;
    var memory_top: usize = 0;
    var memory_bottom: usize = std.math.maxInt(usize);
    const memory_response: *limine.MemoryMapResponse = memory.response orelse {
        std.log.scoped(.alloc).err("no memory", .{});
        main.hcf();
    };

    for (memory_response.entries()) |memory_map_entry| {
        // const from = std.mem.alignBackward(usize, memory_map_entry.base, 1 << 12);
        // const to = std.mem.alignForward(usize, memory_map_entry.base + memory_map_entry.length, 1 << 12);
        // const len = to - from;
        const from = memory_map_entry.base;
        const to = memory_map_entry.base + memory_map_entry.length;
        const len = memory_map_entry.length;

        // const ty = @tagName(memory_map_entry.kind);
        // std.log.scoped(.alloc).info("{s:>22}: [ 0x{x:0>16}..0x{x:0>16} ]", .{ ty, from, to });

        if (memory_map_entry.kind == .usable) {
            usable_memory += len;
            memory_bottom = @min(from, memory_bottom);
            memory_top = @max(to, memory_top);
        } else if (memory_map_entry.kind == .bootloader_reclaimable) {
            memory_bottom = @min(from, memory_bottom);
            memory_top = @max(to, memory_top);
        }
    }

    const memory_pages = (memory_top - memory_bottom) >> 12;
    const page_refcounts_len: usize = memory_pages / @sizeOf(u8); // u8 is the physical page refcounter for forks

    var page_refcounts_null: ?[]u8 = null;
    for (memory_response.entries()) |memory_map_entry| {
        if (memory_map_entry.kind != .usable) {
            continue;
        }

        if (memory_map_entry.length >= page_refcounts_len) {
            const ptr: [*]u8 = @ptrCast(physToPtr(u8, memory_map_entry.base));
            page_refcounts_null = ptr[0..page_refcounts_len];
            memory_map_entry.base += page_refcounts_len;
            memory_map_entry.length -= page_refcounts_len;
            break;
        }
    }
    base = memory_bottom;
    page_refcounts = page_refcounts_null orelse {
        std.log.scoped(.alloc).err("not enough contiguous memory", .{});
        main.hcf();
    };
    // std.log.scoped(.alloc).err("page_refcounts at: {*}", .{page_refcounts});
    for (page_refcounts) |*r| {
        r.* = 1;
    }

    // std.log.scoped(.alloc).err("zeroed", .{});
    for (memory_response.entries()) |memory_map_entry| {
        if (memory_map_entry.kind == .usable) {
            const first_page = physToIndex(memory_map_entry.base) catch unreachable;
            const n_pages = memory_map_entry.length >> 12;
            for (first_page..first_page + n_pages) |page| {
                page_refcounts[page] = 0;
            }
        }
    }
}

//

fn _alloc(_: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;

    tryInit();

    const aligned_len = std.mem.alignForward(usize, len, 1 << 12);
    if (ptr_align > aligned_len) {
        @setCold(true);
        std.log.scoped(.alloc).err("FIXME: page alloc with higher than page size alignment", .{});
        return null;
    }

    const pages: []Page = allocateContiguous(aligned_len >> 12) orelse {
        return null;
    };

    return @ptrCast(pages.ptr);
}

fn _resize(_: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
    _ = .{ buf, buf_align, new_len, ret_addr };
    std.log.scoped(.alloc).err("FIXME: resize", .{});
    // TODO:
    return false;
}

fn _free(_: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
    _ = .{ buf_align, ret_addr };

    const aligned_len = std.mem.alignForward(usize, buf.len, 1 << 12);
    const page: [*]Page = @alignCast(@ptrCast(buf.ptr));
    const pages = page[0 .. aligned_len >> 12];
    deallocateContiguousZeroed(pages);
}
