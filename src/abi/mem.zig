const std = @import("std");

const rt = @import("rt.zig");
const abi = @import("lib.zig");

//

pub const server_page_allocator = std.mem.Allocator{
    .ptr = @ptrFromInt(0x1000),
    .vtable = &.{
        .alloc = ServerPageAllocator.alloc,
        .resize = ServerPageAllocator.resize,
        .remap = ServerPageAllocator.remap,
        .free = ServerPageAllocator.free,
    },
};

pub const slab_allocator = std.mem.Allocator{
    .ptr = &slab_allocator_inst,
    .vtable = &.{
        .alloc = SlabAllocator.alloc,
        .resize = SlabAllocator.resize,
        .remap = SlabAllocator.remap,
        .free = SlabAllocator.free,
    },
};

var slab_allocator_inst: SlabAllocator = .{};

const ServerPageAllocator = struct {
    fn alloc(_: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        const vm_client = abi.VmProtocol.Client().init(rt.vm_ipc);
        const res, const addr = vm_client.call(.mapAnon, .{
            rt.vmem_handle,
            len,
            abi.sys.Rights{ .writable = true },
            abi.sys.MapFlags{},
        }) catch return null;
        res catch return null;
        return @ptrFromInt(addr);
    }

    fn resize(_: *anyopaque, mem: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        const n = abi.ChunkSize.of(mem.len) orelse return false;
        return n.sizeBytes() >= new_len;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {
        std.log.scoped(.server_page_allocator).warn("TODO: free pages", .{});
    }
};

const SlabAllocator = struct {
    // chunks broken into smaller pieces
    locks: [8]abi.lock.YieldMutex = .{abi.lock.YieldMutex{}} ** 8,
    slabs: [8]FreeList = .{FreeList{}} ** 8,

    // // bigger chunks
    // chunk_locks: [18]abi.lock.YieldMutex = .{abi.lock.YieldMutex{}} ** 18,
    // chunks: [18]FreeList = .{FreeList{}} ** 18,

    fn alloc(p: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(p));

        if (SlabSize.of(len)) |slab_size| {
            const i = @intFromEnum(slab_size);
            const lock = &self.locks[i];
            const slab = &self.slabs[i];

            {
                lock.lock();
                defer lock.unlock();

                if (slab.next) |next| {
                    slab.next = next.next;
                    return @ptrCast(next);
                }
            }

            // 4 pages per chunk
            const chunk: []u8 = server_page_allocator.alloc(u8, 0x4000) catch return null;

            // form a linked list out of the items
            // but keep one of them
            for (1..0x4000 / slab_size.sizeBytes() - 1) |item_idx| {
                const prev = @as(*FreeList, @alignCast(@ptrCast(&chunk[item_idx * slab_size.sizeBytes()])));
                const next = @as(*FreeList, @alignCast(@ptrCast(&chunk[(item_idx + 1) * slab_size.sizeBytes()])));
                prev.next = next;
            }

            const first = @as(*FreeList, @alignCast(@ptrCast(&chunk[0])));
            const second = @as(*FreeList, @alignCast(@ptrCast(&chunk[1 * slab_size.sizeBytes()])));
            const last = @as(*FreeList, @alignCast(@ptrCast(&chunk[(0x4000 / slab_size.sizeBytes() - 1) * slab_size.sizeBytes()])));

            lock.lock();
            defer lock.unlock();

            last.next = slab.next;
            slab.next = second;

            return @ptrCast(first);
        } else {
            return null;
        }
    }

    fn resize(_: *anyopaque, mem: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        // const self: *@This() = @ptrCast(@alignCast(p));

        if (SlabSize.of(mem.len)) |slab_size| {
            return slab_size.sizeBytes() >= new_len;
        } else {
            return false;
        }
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        // const self: *@This() = @ptrCast(@alignCast(p));

        return null;
    }

    fn free(p: *anyopaque, mem: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *@This() = @ptrCast(@alignCast(p));

        if (SlabSize.of(mem.len)) |slab_size| {
            const i = @intFromEnum(slab_size);
            const lock = &self.locks[i];
            const slab = &self.slabs[i];

            const new_head: *FreeList = @alignCast(@ptrCast(mem.ptr));

            lock.lock();
            defer lock.unlock();

            new_head.next = slab.next;
            slab.next = new_head;
        } else {}
    }
};

const FreeList = struct {
    next: ?*FreeList = null,
};

pub const SlabSize = enum(u5) {
    @"8B",
    @"16B",
    @"32B",
    @"64B",
    @"128B",
    @"256B",
    @"512B",
    @"1KiB",
    @"2KiB",

    pub fn of(n_bytes: usize) ?SlabSize {
        const slab_size = @max(3, std.math.log2_int_ceil(usize, n_bytes)) - 3;
        if (slab_size >= 9) return null;
        return @enumFromInt(slab_size);
    }

    pub fn next(self: @This()) ?@This() {
        return std.meta.intToEnum(@This(), @intFromEnum(self) + 1) catch return null;
    }

    pub fn sizeBytes(self: @This()) usize {
        return @as(usize, 8) << @intFromEnum(self);
    }
};
