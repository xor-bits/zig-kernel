pub const std = @import("std");

pub const spin = @import("spin.zig");
pub const pmem = @import("pmem.zig");

const log = std.log.scoped(.slab);

//

pub var global_allocator: SlabAllocator = SlabAllocator.init();

//

pub const SlabAllocator = struct {
    // TODO: keep track of allocated slabs and the allocated object counts in them
    // so that slabs can be freed back into some cache of slabs, or back to the pmem alloc

    lists: [9]FreeList,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .lists = .{
                .{ .mutex = spin.Mutex.new(), .next = null },
                .{ .mutex = spin.Mutex.new(), .next = null },
                .{ .mutex = spin.Mutex.new(), .next = null },
                .{ .mutex = spin.Mutex.new(), .next = null },
                .{ .mutex = spin.Mutex.new(), .next = null },
                .{ .mutex = spin.Mutex.new(), .next = null },
                .{ .mutex = spin.Mutex.new(), .next = null },
                .{ .mutex = spin.Mutex.new(), .next = null },
                .{ .mutex = spin.Mutex.new(), .next = null },
            },
        };
    }

    const List = struct {
        list: *FreeList,
        size: usize,
    };

    pub fn list(self: *Self, size: usize) ?List {
        // std.math.log2_int(size);
        const obj_size = std.math.ceilPowerOfTwo(usize, size) catch return null;
        const idx = std.math.log2_int(usize, obj_size);

        if (idx >= 9) {
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
            std.debug.panic("TODO: big allocs", .{});
        };

        return correct_list.list.pop(correct_list.size);
    }

    pub fn resize(self: *Self, old_size: usize, new_size: usize, ptr_align: usize) bool {
        const correct_list: List = self.list(@max(old_size, ptr_align)) orelse {
            std.debug.panic("TODO: big allocs", .{});
        };

        return correct_list.size >= new_size;
    }

    pub fn free(self: *Self, ptr: [*]u8, size: usize, ptr_align: usize) void {
        const correct_list: List = self.list(@max(size, ptr_align)) orelse {
            std.debug.panic("TODO: big allocs", .{});
        };

        correct_list.list.push(ptr);
    }
};

const FreeList = struct {
    mutex: spin.Mutex,
    next: ?*Node,

    const Self = @This();

    pub fn try_pop(self: *Self) ?[*]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.next) |next| {
            self.next = next.next;
            return @ptrCast(next);
        } else {
            return null;
        }
    }

    pub fn pop(self: *Self, obj_size: usize) ?[*]u8 {
        if (self.try_pop()) |next| {
            return next;
        }

        @setCold(true);

        if (@sizeOf(Node) > obj_size) {
            std.debug.panic("object size larger than node size", .{});
        }

        const slab: [*]u8 = @ptrCast(pmem.page_allocator.create(pmem.Page) catch return null);
        const obj_count: usize = @sizeOf(pmem.Page) / obj_size;

        self.mutex.lock();
        defer self.mutex.unlock();

        // push all except the first one to the object list
        for (1..obj_count) |obj_idx| {
            self.push_locked(@ptrCast(&slab[obj_idx * obj_size]));
        }

        // return the first one
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
