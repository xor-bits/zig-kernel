const std = @import("std");
const limine = @import("limine");

const main = @import("main.zig");
const arch = @import("arch.zig");
const lazy = @import("lazy.zig");
const NumberPrefix = @import("byte_fmt.zig").NumberPrefix;

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
        NumberPrefix(usize, .binary).new(usable_memory),
    });
    log.info("bootloader (reclaimable) overhead: {any}B", .{
        NumberPrefix(usize, .binary).new(reclaimable),
    });
    log.info("page allocator overhead: {any}B", .{
        NumberPrefix(usize, .binary).new(page_refcounts.len),
    });
    log.info("kernel code overhead: {any}B", .{
        NumberPrefix(usize, .binary).new(kernel_usage),
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

pub const PhysPage = struct {
    page_index: u32, // 2^32-1 of pages (4KiB) is already ~16TiB of physical memory

    const Self = @This();

    pub fn new(page: usize) Self {
        // FIXME: broken with over 16TiB of ram no way
        // anyone is ever going to this os with that much ram
        return .{ .page_index = @truncate(page) };
    }

    pub fn fromPhys(phys: PhysAddr) Self {
        return .{ .page_index = @truncate(phys.raw >> 12) };
    }

    pub fn toPhys(self: Self) PhysAddr {
        return PhysAddr.new(@as(u64, self.page_index) << 12);
    }

    pub fn toRefcntIndex(self: Self) !usize {
        if (self.page_index < base.page_index) {
            @setCold(true);
            return error.OutOfBounds;
        }

        return self.page_index - base.page_index;
    }
};

pub const PhysAddr = struct {
    raw: usize,

    const Self = @This();

    pub fn new(addr: usize) Self {
        return .{ .raw = addr };
    }

    pub fn add(self: Self, b: usize) Self {
        return .{ .raw = self.raw + b };
    }

    pub fn sub(self: Self, b: usize) Self {
        return .{ .raw = self.raw + b };
    }

    pub fn toHhdm(self: Self) HhdmAddr {
        return .{ .raw = self.raw + main.hhdm_offset.load(.monotonic) };
    }

    pub fn toPage(self: Self) PhysPage {
        return PhysPage.new(self.raw >> 12);
    }
};

pub const VirtAddr = struct {
    raw: usize,

    const Self = @This();

    /// sign extends the bit 47 to the last 16 bits,
    /// making the virtual address canonical
    pub fn new(addr: usize) Self {
        const sign_extension: isize = @bitCast(addr << 16);
        return .{ .raw = @bitCast(sign_extension >> 16) };
    }

    pub fn fromParts(_offset: u12, _levels: [4]u9) Self {
        return Self.new(
            @as(usize, _offset) |
                (@as(usize, _levels[0]) << 12) |
                (@as(usize, _levels[1]) << 21) |
                (@as(usize, _levels[2]) << 30) |
                (@as(usize, _levels[3]) << 39),
        );
    }

    pub fn ptr(self: Self, comptime T: type) T {
        return @ptrFromInt(self.raw);
    }

    pub fn offset(self: Self) u12 {
        return @truncate(self.raw);
    }

    pub fn levels(self: Self) [4]u9 {
        return .{
            @truncate(self.raw >> 12),
            @truncate(self.raw >> 21),
            @truncate(self.raw >> 30),
            @truncate(self.raw >> 39),
        };
    }
};

pub const HhdmAddr = struct {
    raw: usize,

    const Self = @This();

    pub fn new(raw_ptr: *anyopaque) Self {
        return .{ .raw = @intFromPtr(raw_ptr) };
    }

    pub fn add(self: Self, b: usize) Self {
        return .{ .raw = self.raw + b };
    }

    pub fn sub(self: Self, b: usize) Self {
        return .{ .raw = self.raw + b };
    }

    pub fn ptr(self: Self, comptime T: type) T {
        return @ptrFromInt(self.raw);
    }

    pub fn toVirt(self: Self) VirtAddr {
        return .{ .raw = self.raw };
    }

    pub fn toPhys(self: Self) PhysAddr {
        return .{ .raw = self.raw - main.hhdm_offset.load(.monotonic) };
    }
};

//

/// tells if the frame allocator can be used already
var pfa_lazy_init = lazy.Lazy(void).new();

/// base physical page from where the refcount array starts from
var base: PhysPage = undefined;

/// each page has a ref counter, 0 = not allocated, N = N process(es) is using it
var page_refcounts: []std.atomic.Value(u8) = undefined;

/// just an atomic index hint to rotate around the memory instead of starting the
/// finding process from 0 every time, because pages arent usually freed almost instantly
var next = std.atomic.Value(usize).init(0);

/// how many pages are currently in use (approx)
var used = std.atomic.Value(usize).init(0);

/// how many pages are usable
var usable = std.atomic.Value(usize).init(0);

fn allocateContiguous(n_pages: usize) ?[]Page {
    const hint = next.fetchAdd(n_pages, .monotonic) % page_refcounts.len;

    if (allocateContiguousFrom(n_pages, hint)) |pages| {
        return pages;
    }

    if (allocateContiguousFrom(0, hint)) |pages| {
        return pages;
    }

    log.err("OOM", .{});
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
            _ = used.fetchAdd(n_pages, .monotonic);
            const pages = PhysPage.new(base.page_index + first_page).toPhys().toHhdm().ptr([*]Page);
            return pages[0..n_pages];
        }
    }

    // for (0..page_refcounts.len) |_i| {
    //     ;
    // }
}

fn deallocateContiguous(pages: []Page) void {
    for (pages) |*page| {
        const page_i = HhdmAddr.new(page).toPhys().toPage().toRefcntIndex() catch unreachable;
        deallocate(&page_refcounts[page_i]);
    }

    _ = used.fetchSub(pages.len, .monotonic);
}

fn deallocateContiguousZeroed(pages: []Page) void {
    for (pages) |*page| {
        const page_i = HhdmAddr.new(page).toPhys().toPage().toRefcntIndex() catch unreachable;
        deallocate(&page_refcounts[page_i]);
    }

    _ = used.fetchSub(pages.len, .monotonic);
}

fn allocate(refcount: *std.atomic.Value(u8)) bool {
    return null == refcount.cmpxchgStrong(0, 1, .acquire, .monotonic);
}

fn deallocate(refcount: *std.atomic.Value(u8)) void {
    refcount.store(0, .release);
}

//

fn tryInit() void {
    _ = pfa_lazy_init.waitOrInit(lazy.fnPtrAsInit(void, init));
}

fn init() void {
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
            const ptr: [*]std.atomic.Value(u8) = PhysAddr.new(memory_map_entry.base)
                .toHhdm().ptr([*]std.atomic.Value(u8));
            page_refcounts_null = ptr[0..page_refcounts_len];
            memory_map_entry.base += page_refcounts_len;
            memory_map_entry.length -= page_refcounts_len;
            break;
        }
    }
    base = PhysAddr.new(memory_bottom).toPage();
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
            const first_page = PhysAddr.new(memory_map_entry.base).toPage().toRefcntIndex() catch unreachable;
            const n_pages = memory_map_entry.length >> 12;
            for (first_page..first_page + n_pages) |page| {
                page_refcounts[page].store(0, .seq_cst);
            }

            _ = usable.fetchAdd(n_pages, .monotonic);
        }
    }
}

//

pub fn alloc() ?*Page {
    tryInit();
    const pages = allocateContiguous(1) orelse return null;
    return @ptrCast(pages.ptr);
}

pub fn free(p: *Page) void {
    const pages: [*]Page = @ptrCast(p);
    deallocateContiguousZeroed(pages[0..1]);
}

fn _alloc(_: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;

    tryInit();

    const aligned_len = std.mem.alignForward(usize, len, 1 << 12);
    if (ptr_align > aligned_len) {
        @setCold(true);
        log.err("FIXME: page alloc with higher than page size alignment", .{});
        return null;
    }

    const pages: []Page = allocateContiguous(aligned_len >> 12) orelse {
        return null;
    };

    return @ptrCast(pages.ptr);
}

fn _resize(_: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
    _ = .{ buf, buf_align, new_len, ret_addr };
    log.err("FIXME: resize", .{});
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
