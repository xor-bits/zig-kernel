const std = @import("std");
const builtin = @import("builtin");
const limine = @import("limine");

const main = @import("main.zig");
const arch = @import("arch.zig");
const addr = @import("addr.zig");
const util = @import("util.zig");

const log = std.log.scoped(.pmem);

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
    .remap = &_remap,
};

//

pub const Page = [512]u64;

//

pub fn printInfo() void {
    const memory_response: *limine.MemoryMapResponse = memory.response orelse {
        return;
    };

    var usable_memory: usize = 0;
    var kernel_usage: usize = 0;
    var reclaimable: usize = 0;
    for (memory_response.entries()) |memory_map_entry| {
        const from = memory_map_entry.base;
        const to = memory_map_entry.base + memory_map_entry.length;
        const len = memory_map_entry.length;

        if (memory_map_entry.kind == .kernel_and_modules) {
            kernel_usage += len;
        } else if (memory_map_entry.kind == .usable) {
            usable_memory += len;
        } else if (memory_map_entry.kind == .bootloader_reclaimable) {
            reclaimable += len;
        }

        const ty = @tagName(memory_map_entry.kind);
        log.info("{s:>22}: [ 0x{x:0>16}..0x{x:0>16} ]", .{ ty, from, to });
    }

    log.info("usable memory: {0any}B ({0any:.1024}B)", .{
        util.NumberPrefix(usize, .binary).new(usable_memory),
    });
    log.info("bootloader (reclaimable) overhead: {any}B", .{
        util.NumberPrefix(usize, .binary).new(reclaimable),
    });
    log.info("page allocator overhead: {any}B", .{
        util.NumberPrefix(usize, .binary).new(page_refcounts.len),
    });
    log.info("kernel code overhead: {any}B", .{
        util.NumberPrefix(usize, .binary).new(kernel_usage),
    });
}

pub fn usedPages() usize {
    return used.load(.monotonic);
}

pub fn freePages() usize {
    return totalPages() - usedPages();
}

pub fn totalPages() usize {
    return usable.load(.monotonic);
}

//

/// tells if the frame allocator can be used already (debugging)
var initialized = if (IS_DEBUG) false else void{};

/// base physical page from where the refcount array starts from
var base_phys_page: u32 = undefined;

/// each page has a ref counter, 0 = not allocated, N = N process(es) is using it
var page_refcounts: []std.atomic.Value(u8) = undefined;

/// just an atomic index hint to rotate around the memory instead of starting the
/// finding process from 0 every time, because pages arent usually freed almost instantly
var next = std.atomic.Value(u32).init(0);

/// how many pages are currently in use (approx)
var used = std.atomic.Value(u32).init(0);

/// how many pages are usable
var usable = std.atomic.Value(u32).init(0);

fn allocateContiguous(n_pages: u32) ?[]Page {
    const hint: u32 = @truncate(next.fetchAdd(n_pages, .monotonic) % page_refcounts.len);

    if (allocateContiguousFrom(n_pages, hint)) |pages| {
        return pages;
    }

    if (allocateContiguousFrom(0, hint)) |pages| {
        return pages;
    }

    log.err("OOM", .{});
    return null;
}

fn allocateContiguousFrom(n_pages: u32, from: u32) ?[]Page {
    const total_pages = page_refcounts.len;
    var first_page = from;

    while (true) {
        if (total_pages < first_page + n_pages) {
            return null;
        }

        // lock pages in a reverse order
        for (0..n_pages) |_i| {
            const i: u32 = @truncate(n_pages - _i - 1);
            const page = first_page + i;

            if (!allocate(&page_refcounts[page])) {
                // one couldn't be allocated
                // deallocate everything that was allocated and move on
                for (0.._i) |_j| {
                    const j: u32 = @truncate(n_pages - _j - 1);
                    const extra_page = first_page + j;

                    // TODO: deallocaton isn't needed here,
                    // the next slot allocates these immediately again
                    deallocate(&page_refcounts[extra_page]);
                }

                first_page += i + 1;
                break;
            }
        } else {
            _ = used.fetchAdd(n_pages, .monotonic);

            const pages = addr.Phys.fromParts(.{ .page = base_phys_page + first_page }).toHhdm().toPtr([*]Page);
            return pages[0..n_pages];
        }
    }

    // for (0..page_refcounts.len) |_i| {
    //     ;
    // }
}

fn toRefcntIndex(page_index: u32) !usize {
    if (page_index < base_phys_page) {
        @branchHint(.cold);
        return error.OutOfBounds;
    }

    return page_index - page_index;
}

fn deallocateContiguous(pages: []Page) void {
    for (pages) |*page| {
        const page_i = toRefcntIndex(addr.Virt.fromPtr(page).hhdmToPhys().toParts().page) catch unreachable;
        deallocate(&page_refcounts[page_i]);
    }

    _ = used.fetchSub(pages.len, .monotonic);
}

fn deallocateContiguousZeroed(pages: []Page) void {
    for (pages) |*page| {
        const page_i = toRefcntIndex(addr.Virt.fromPtr(page).hhdmToPhys().toParts().page) catch unreachable;
        deallocate(&page_refcounts[page_i]);
    }

    _ = used.fetchSub(@truncate(pages.len), .monotonic);
}

fn allocate(refcount: *std.atomic.Value(u8)) bool {
    return null == refcount.cmpxchgStrong(0, 1, .acquire, .monotonic);
}

fn deallocate(refcount: *std.atomic.Value(u8)) void {
    refcount.store(0, .release);
}

//

pub fn init() void {
    if (IS_DEBUG and initialized) {
        log.err("physical memory manager already initialized", .{});
        return;
    }

    var usable_memory: usize = 0;
    var memory_top: usize = 0;
    var memory_bottom: usize = std.math.maxInt(usize);
    const memory_response: *limine.MemoryMapResponse = memory.response orelse {
        log.err("no memory", .{});
        arch.hcf();
    };

    for (memory_response.entries()) |memory_map_entry| {
        // const from = std.mem.alignBackward(usize, memory_map_entry.base, 1 << 12);
        // const to = std.mem.alignForward(usize, memory_map_entry.base + memory_map_entry.length, 1 << 12);
        // const len = to - from;
        const from = memory_map_entry.base;
        const to = memory_map_entry.base + memory_map_entry.length;
        const len = memory_map_entry.length;

        // const ty = @tagName(memory_map_entry.kind);
        // log.info("{s:>22}: [ 0x{x:0>16}..0x{x:0>16} ]", .{ ty, from, to });

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

    var page_refcounts_null: ?[]std.atomic.Value(u8) = null;
    for (memory_response.entries()) |memory_map_entry| {
        if (memory_map_entry.kind != .usable) {
            continue;
        }

        if (memory_map_entry.length >= page_refcounts_len) {
            const ptr: [*]std.atomic.Value(u8) = addr.Phys.fromInt(memory_map_entry.base)
                .toHhdm().toPtr([*]std.atomic.Value(u8));
            page_refcounts_null = ptr[0..page_refcounts_len];
            memory_map_entry.base += page_refcounts_len;
            memory_map_entry.length -= page_refcounts_len;
            break;
        }
    }
    base_phys_page = addr.Phys.fromInt(memory_bottom).toParts().page;
    page_refcounts = page_refcounts_null orelse {
        log.err("not enough contiguous memory", .{});
        arch.hcf();
    };
    // log.err("page_refcounts at: {*}", .{page_refcounts});
    for (page_refcounts) |*r| {
        r.store(1, .seq_cst);
    }

    // log.err("zeroed", .{});
    for (memory_response.entries()) |memory_map_entry| {
        if (memory_map_entry.kind == .usable) {
            const first_page = toRefcntIndex(addr.Phys.fromInt(memory_map_entry.base).toParts().page) catch unreachable;
            const n_pages: u32 = @truncate(memory_map_entry.length >> 12);
            for (first_page..first_page + n_pages) |page| {
                page_refcounts[page].store(0, .seq_cst);
            }

            _ = usable.fetchAdd(n_pages, .monotonic);
        }
    }

    initialized = if (comptime IS_DEBUG) true else void{};
}

//

pub fn alloc() ?*Page {
    if (debug_assert_initialized()) return null;

    const pages = allocateContiguous(1) orelse return null;
    return @ptrCast(pages.ptr);
}

pub fn free(p: *Page) void {
    if (debug_assert_initialized()) return;

    const pages: [*]Page = @ptrCast(p);
    deallocateContiguousZeroed(pages[0..1]);
}

fn _alloc(_: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    if (debug_assert_initialized()) return null;

    const aligned_len = std.mem.alignForward(usize, len, 1 << 12);

    const pages: []Page = allocateContiguous(@truncate(aligned_len >> 12)) orelse {
        return null;
    };

    return @ptrCast(pages.ptr);
}

fn _resize(_: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    if (debug_assert_initialized()) return false;

    _ = .{ buf, buf_align, new_len, ret_addr };
    // log.err("FIXME: resize", .{});
    // TODO:
    return false;
}

fn _free(_: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
    if (debug_assert_initialized()) return;

    _ = .{ buf_align, ret_addr };

    const aligned_len = std.mem.alignForward(usize, buf.len, 1 << 12);
    const page: [*]Page = @alignCast(@ptrCast(buf.ptr));
    const pages = page[0 .. aligned_len >> 12];
    deallocateContiguousZeroed(pages);
}

fn _remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    // physical memory cant be remapped
    return null;
}

const IS_DEBUG = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

fn debug_assert_initialized() bool {
    if (IS_DEBUG and !initialized) {
        log.err("physical memory manager not initialized", .{});
        return true;
    } else {
        return false;
    }
}
