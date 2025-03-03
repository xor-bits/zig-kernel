pub const std = @import("std");

pub const spin = @import("spin.zig");
pub const pmem = @import("pmem.zig");
pub const vmem = @import("vmem.zig");
pub const util = @import("util.zig");

const log = std.log.scoped(.slab);

//

pub var global_allocator: SlabAllocator = SlabAllocator.init(
    vmem.KERNEL_HEAP_BOTTOM,
    vmem.KERNEL_HEAP_TOP,
);

//

pub const SlabAllocator = struct {
    // TODO: keep track of allocated slabs and the allocated object counts in them
    // so that slabs can be freed back into some cache of slabs, or back to the pmem alloc

    heap_bottom: pmem.VirtAddr,
    heap_top: pmem.VirtAddr,

    lists: [11]FreeList,

    const Self = @This();

    pub fn init(heap_bottom: pmem.VirtAddr, heap_top: pmem.VirtAddr) Self {
        return .{
            .heap_bottom = heap_bottom,
            .heap_top = heap_top,
            .lists = .{
                FreeList.init(),
                FreeList.init(),
                FreeList.init(),
                FreeList.init(),
                FreeList.init(),
                FreeList.init(),
                FreeList.init(),
                FreeList.init(),
                FreeList.init(),
                FreeList.init(),
                FreeList.init(),
            },
        };
    }

    pub fn print_stats(self: *Self) void {
        const pages = self.counter.load(.acquire);

        log.info("Slab allocator stats:", .{});
        log.info(" - total memory: {}B", .{util.NumberPrefix(usize, .binary).new(pages * 0x1000)});

        for (self.lists[0..], 0..) |*l, i| {
            log.info(" - [{}B]: {} pcs", .{
                util.NumberPrefix(usize, .binary).new(@as(usize, 8) << @as(u6, @truncate(i))),
                l.stats(),
            });
        }
    }

    const List = struct {
        list: *FreeList,
        size: usize,
    };

    pub fn list(self: *Self, size: usize) ?List {
        // std.math.log2_int(size);
        const obj_size = std.math.ceilPowerOfTwo(usize, size) catch return null;
        const idx = std.math.log2_int(usize, obj_size);

        if (idx > self.lists.len) {
            return null;
        }

        return List{
            .list = &self.lists[idx],
            .size = obj_size,
        };
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        const slab_allocator_vtable = std.mem.Allocator.VTable{
            .alloc = &SlabAllocator._alloc,
            .resize = &SlabAllocator._resize,
            .free = &SlabAllocator._free,
        };

        return std.mem.Allocator{
            .ptr = self,
            .vtable = &slab_allocator_vtable,
        };
    }

    fn _alloc(ctx: *anyopaque, len: usize, ptr_align: u8, _: usize) ?[*]u8 {
        const self: *Self = @alignCast(@ptrCast(ctx));
        return self.alloc(len, ptr_align);
    }
    fn _resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, _: usize) bool {
        const self: *Self = @alignCast(@ptrCast(ctx));
        return self.resize(buf.len, new_len, buf_align);
    }
    fn _free(ctx: *anyopaque, buf: []u8, buf_align: u8, _: usize) void {
        const self: *Self = @alignCast(@ptrCast(ctx));
        return self.free(buf.ptr, buf.len, buf_align);
    }

    pub fn alloc(self: *Self, size: usize, ptr_align: usize) ?[*]u8 {
        const correct_list: List = self.list(@max(size, ptr_align)) orelse {
            return self.bigAlloc(size);
        };

        return correct_list.list.pop(correct_list.size, self);
    }

    pub fn resize(self: *Self, old_size: usize, new_size: usize, ptr_align: usize) bool {
        const correct_list: List = self.list(@max(old_size, ptr_align)) orelse {
            return self.bigResize(old_size, new_size);
        };

        return correct_list.size >= new_size;
    }

    pub fn free(self: *Self, ptr: [*]u8, size: usize, ptr_align: usize) void {
        const correct_list: List = self.list(@max(size, ptr_align)) orelse {
            std.debug.panic("TODO: big allocs", .{});
        };

        correct_list.list.push(ptr);
    }

    fn bigAlloc(self: *Self, size: usize) ?[*]u8 {
        const real_size = std.mem.alignForward(usize, size, 0x1000);

        const page_top = pmem.VirtAddr.new(@atomicRmw(usize, &self.heap_top.raw, .Sub, real_size, .monotonic));
        const page_bottom = pmem.VirtAddr.new(page_top.raw - real_size);

        if (page_bottom.raw < self.heap_bottom.raw) {
            log.err("heap out of virtual memory", .{});
            return null;
        }

        const global_as = vmem.AddressSpace.current();
        global_as.map(page_bottom, .{ .lazy = real_size }, .{
            .writeable = 1,
            .no_execute = 1,
        });

        return page_bottom.ptr([*]u8);
    }

    fn bigResize(self: *Self, old_size: usize, new_size: usize) bool {
        _ = self;
        const real_size = std.mem.alignForward(usize, old_size, 0x1000);
        return new_size <= real_size;
    }

    fn bigFree(self: *Self, ptr: [*]u8, size: usize) void {
        const real_size = std.mem.alignForward(usize, size, 0x1000);

        const page_bottom = pmem.VirtAddr.new(@intFromPtr(ptr));

        // FIXME: leaks virtual memory
        const heap_top = @atomicLoad(usize, &self.heap_top.raw, .acquire);
        @cmpxchgStrong(usize, &self.heap_top.raw, heap_top, heap_top + real_size, .seq_cst, .monotonic);

        // remap as lazy to free the physical pages
        const global_as = vmem.AddressSpace.current();
        global_as.map(page_bottom, .{ .lazy = real_size }, .{
            .writeable = 1,
        });
    }
};

const FreeList = struct {
    // object allocation counter
    counter: std.atomic.Value(usize),

    mutex: spin.Mutex,
    next: ?*Node,

    const Self = @This();

    pub fn init() Self {
        return .{
            .counter = std.atomic.Value(usize).init(0),
            .mutex = spin.Mutex.new(),
            .next = null,
        };
    }

    pub fn stats(self: *Self) usize {
        return self.counter.load(.acquire);
    }

    pub fn try_pop(self: *Self) ?[*]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.next) |next| {
            // return the immediately available usable object
            _ = self.counter.fetchAdd(1, .monotonic);
            self.next = next.next;
            return @ptrCast(next);
        } else {
            return null;
        }
    }

    pub fn pop(self: *Self, obj_size: usize, base: *SlabAllocator) ?[*]u8 {
        if (self.try_pop()) |next| {
            return next;
        }

        @setCold(true);

        if (@sizeOf(Node) > obj_size) {
            std.debug.panic("object size larger than node size", .{});
        }

        const page_top = pmem.VirtAddr.new(@atomicRmw(usize, &base.heap_top.raw, .Sub, 0x1000, .monotonic));
        const page_bottom = pmem.VirtAddr.new(page_top.raw - 0x1000);

        if (page_bottom.raw < base.heap_bottom.raw) {
            return null;
        }

        const global_as = vmem.AddressSpace.current();
        global_as.map(page_bottom, .{ .prealloc = 1 }, .{
            .writeable = 1,
            .no_execute = 1,
        });

        const slab: [*]u8 = page_bottom.ptr([*]u8);
        const obj_count: usize = @sizeOf(pmem.Page) / obj_size;

        self.mutex.lock();
        defer self.mutex.unlock();

        // push all except the first one to the object list
        for (1..obj_count) |obj_idx| {
            self.push_locked(@ptrCast(&slab[obj_idx * obj_size]));
        }

        // return the first one
        _ = self.counter.fetchAdd(1, .monotonic);
        return @ptrCast(slab);
    }

    // `ptr` had to have been allocated by this `FreeList`
    pub fn push(self: *Self, ptr: [*]u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.push_locked(ptr);
    }

    // `ptr` had to have been allocated by this `FreeList`
    pub fn push_locked(self: *Self, ptr: [*]u8) void {
        // all alignments are at least 8, required by Node
        const obj: *Node = @alignCast(@ptrCast(ptr));
        obj.next = self.next;
        self.next = obj;
    }
};

const Node = struct {
    next: ?*Node,
};
