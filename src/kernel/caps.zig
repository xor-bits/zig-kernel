const std = @import("std");
const abi = @import("abi");

const addr = @import("addr.zig");
const arch = @import("arch.zig");
const pmem = @import("pmem.zig");
const proc = @import("proc.zig");
const spin = @import("spin.zig");

// const caps_ipc = @import("caps/ipc.zig");
// const caps_pmem = @import("caps/pmem.zig");
// const caps_thread = @import("caps/thread.zig");
const caps_vmem = @import("caps/vmem.zig");
// const caps_x86 = @import("caps/x86.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;
const RefCnt = abi.epoch.RefCnt;

//

// pub const Memory = caps_pmem.Memory;
// pub const Frame = caps_pmem.Frame;
// pub const DeviceFrame = caps_pmem.DeviceFrame;
// pub const Thread = caps_thread.Thread;
pub const HalVmem = caps_vmem.Vmem;
// pub const Receiver = caps_ipc.Receiver;
// pub const Sender = caps_ipc.Sender;
// pub const Reply = caps_ipc.Reply;
// pub const Notify = caps_ipc.Notify;
// pub const X86IoPortAllocator = caps_x86.X86IoPortAllocator;
// pub const X86IoPort = caps_x86.X86IoPort;
// pub const X86IrqAllocator = caps_x86.X86IrqAllocator;
// pub const X86Irq = caps_x86.X86Irq;

//

pub fn init() !void {
    // initialize the global kernel address space
    // (required for the capability array)
    try caps_vmem.init();

    // initialize the dedupe lazyinit readonly zero page
    const page = pmem.allocChunk(.@"4KiB") orelse return error.OutOfMemory;
    readonly_zero_page.store(page.toParts().page, .release);

    // push the null capability
    _ = try pushCapability(.{
        .ptr = @ptrFromInt(0xFFFF_8000_0000_0000),
        .type = .null,
    });

    var cap: CapabilitySlot = .{};
    cap.object.store(.{}, .seq_cst);
    const s = cap.object.load(.acquire);
    // s.ptr;
    // s.type;
    debugType(@TypeOf(s));
    debugType(CapabilitySlot);
    debugType(Generic);
    debugType(Process);
    debugType(Thread);
    debugType(Frame);
    debugType(Vmem);
    debugType(Vmem.Mapping);
    // debugType(Object);
    // debugType(Memory);
    // debugType(Frame);
    // debugType(DeviceFrame);
    // debugType(Thread);
    // debugType(Vmem);
    // debugType(Receiver);
    // debugType(Sender);
    // debugType(Reply);
    // debugType(Notify);
    // debugType(X86IoPortAllocator);
    // debugType(X86IoPort);
    // debugType(X86IrqAllocator);
    // debugType(X86Irq);
}

// FIXME: process local capability arrays, now all processes can use all capabilities
/// create a capability out of an object
pub fn pushCapability(cap: Capability) !u32 {
    const cap_id = allocate();
    const cap_slot = &capabilityArrayUnchecked()[cap_id];

    try cap_slot.store(cap);

    return cap_id;
}

// FIXME: process local capability arrays, now all processes can use all capabilities
pub fn getCapability(id: u32, current: *Process) Error!Capability {
    _ = current;

    if (id == 0) return Error.InvalidCapability;

    const caps = capabilityArray();
    if (id >= caps.len) return Error.InvalidCapability;

    const cap = &caps[id];

    const handle = cap.load() orelse return Error.InvalidCapability;
    return handle;
}

//

// FIXME: process local capability arrays, now all processes can use all capabilities
pub fn capabilityArray() []CapabilitySlot {
    const len = @min(capability_array_len.load(.acquire), 2 << 32);
    return @as([*]CapabilitySlot, @ptrFromInt(CAPABILITY_ARRAY_POINTER))[0..len];
}

// FIXME: process local capability arrays, now all processes can use all capabilities
pub fn capabilityArrayUnchecked() []CapabilitySlot {
    return @as([*]CapabilitySlot, @ptrFromInt(CAPABILITY_ARRAY_POINTER))[0 .. 2 << 32];
}

pub fn allocate() u32 {
    {
        free_list_lock.lock();
        defer free_list_lock.unlock();

        log.err("FIXME: reimpl capability free list", .{});
    }

    return caps_vmem.growCapArray();
}

pub fn deallocate(cap: u32) void {
    std.debug.assert(cap != 0);

    free_list_lock.lock();
    defer free_list_lock.unlock();

    if (free_list != 0) {
        log.err("FIXME: reimpl capability free list", .{});
    }

    free_list = cap;
}

//

// TODO: make this local per process (process, not thread)

/// pointer to the first capability in the global capability array (its a null capability)
///
/// it is currently `0xFFFFFFBF80000000`, right before the kernel code at `0xFFFF_FFFF_8000_0000`
/// and capable of holding a maximum of 2^32 capabilities across all processes
pub const CAPABILITY_ARRAY_POINTER: usize = 0xFFFF_FFFF_8000_0000 - (2 << 32) * @sizeOf(CapabilitySlot);
/// the length can only grow
pub var capability_array_len: std.atomic.Value(usize) = .init(0);
/// a linked list of unused slots
pub var array_grow_lock: spin.Mutex = .new();
pub var free_list_lock: spin.Mutex = .new();
pub var free_list: u32 = 0;
pub var obj_accesses: std.EnumArray(abi.ObjectType, std.atomic.Value(usize)) = .initFill(.init(0));

//

// pub fn Ref(comptime T: type) type {
//     return struct {
//         paddr: addr.Phys,

//         const Self = @This();

//         pub fn alloc(dyn_size: ?abi.ChunkSize) Error!Self {
//             const paddr = try T.alloc(dyn_size);
//             const obj = Self{ .paddr = paddr };
//             T.init(obj);
//             return obj;
//         }

//         pub fn ptr(self: @This()) *T {
//             // recursive mapping instead of HHDM later (maybe)
//             return self.paddr.toHhdm().toPtr(*T);
//         }

//         pub fn object(self: @This(), owner: ?*Thread) Object {
//             return .{
//                 .paddr = self.paddr,
//                 .type = Object.objectTypeOf(T),
//                 .owner = .init(Thread.vmemOf(owner)),
//             };
//         }
//     };
// }

pub const CapabilitySlot = struct {
    /// the actual kernel object data, possibly shared between multiple capabilities
    object: std.atomic.Value(ObjectPointer) = .init(.{}),

    const ObjectPointer = packed struct {
        /// object pointer's low 56 bits, the upper 8 (actually 17) bits are always 1 in kernel space
        ptr: u56 = 0,
        /// object type
        type: abi.ObjectType = .null,

        fn fromHandle(handle: Capability) @This() {
            std.debug.assert((@intFromPtr(handle.ptr) >> 56) == 0xFF);

            return .{
                .ptr = @truncate(@intFromPtr(handle.ptr)),
                .type = handle.type,
            };
        }

        fn getHandle(self: *const @This()) ?Capability {
            if (self.type == .null) return null;

            return .{
                .ptr = @ptrFromInt(@as(u64, self.ptr) | 0xFF00_0000_0000_0000),
                .type = self.type,
            };
        }
    };

    const Self = @This();

    pub fn load(self: *Self) ?Capability {
        const guard = abi.epoch.pin();
        defer abi.epoch.unpin(guard);

        const object = self.object.load(.monotonic);
        const handle = object.getHandle() orelse return null;
        handle.refcnt().inc();

        return handle;
    }

    pub fn store(self: *Self, handle: Capability) !void {
        const guard = abi.epoch.pin();
        defer abi.epoch.unpin(guard);

        const new_object = ObjectPointer.fromHandle(handle);

        const old_object = self.object.swap(new_object, .seq_cst);
        const old_handle = old_object.getHandle() orelse return;
        if (!old_handle.refcnt().dec()) return;

        switch (old_handle.type) {
            .frame => try abi.epoch.deferCtxFunc(
                guard,
                old_handle.as(Frame).?,
                Frame.deinit,
            ),
            .vmem => try abi.epoch.deferCtxFunc(
                guard,
                old_handle.as(Vmem).?,
                Vmem.deinit,
            ),
            .process => try abi.epoch.deferCtxFunc(
                guard,
                old_handle.as(Process).?,
                Process.deinit,
            ),
            .thread => try abi.epoch.deferCtxFunc(
                guard,
                old_handle.as(Thread).?,
                Thread.deinit,
            ),
            else => unreachable,
        }
    }
};

pub const Capability = struct {
    ptr: *void,
    type: abi.ObjectType = .null,
    // rights: abi.sys.Rights = .{},

    pub fn init(obj: anytype) @This() {
        return switch (@TypeOf(obj)) {
            *Frame => .{
                .ptr = @ptrCast(obj),
                .type = .frame,
            },
            *Vmem => .{
                .ptr = @ptrCast(obj),
                .type = .vmem,
            },
            *Process => .{
                .ptr = @ptrCast(obj),
                .type = .process,
            },
            *Thread => .{
                .ptr = @ptrCast(obj),
                .type = .thread,
            },
            else => @compileError("invalid type"),
        };
    }

    pub fn deinit(self: @This()) void {
        switch (self.type) {
            .frame => &self.as(Frame).?.deinit(),
            .vmem => &self.as(Vmem).?.deinit(),
            .process => &self.as(Process).?.deinit(),
            .thread => &self.as(Thread).?.deinit(),
        }
    }

    pub fn as(self: @This(), comptime T: type) ?*T {
        const expected_type: abi.ObjectType = switch (T) {
            Frame => .frame,
            Vmem => .vmem,
            Process => .process,
            Thread => .thread,
            else => @compileError("invalid type"),
        };

        if (self.type != expected_type) {
            return null;
        }

        return @ptrCast(@alignCast(self.ptr));
    }

    pub fn refcnt(self: @This()) *abi.epoch.RefCnt {
        if (0 != @offsetOf(Frame, "refcnt") or
            0 != @offsetOf(Vmem, "refcnt") or
            0 != @offsetOf(Process, "refcnt") or
            0 != @offsetOf(Thread, "refcnt"))
        {
            // FIXME: prevent reordering so that the offset would be same on all objects
            return switch (self.type) {
                .frame => &self.as(Frame).?.ptr.refcnt,
                .vmem => &self.as(Vmem).?.ptr.refcnt,
                .process => &self.as(Process).?.ptr.refcnt,
                .thread => &self.as(Thread).?.ptr.refcnt,
            };
        }

        return @ptrCast(@alignCast(self.ptr));
    }
};

pub const Generic = struct {
    refcnt: abi.epoch.RefCnt,
};

// pub const ShortFrameObject = extern struct {
//     refcnt: abi.epoch.RefCnt = .{},
//     lock: spin.Mutex = .new(),
//     pages: [2:0]u32, //
// };

pub const Frame = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    lock: spin.Mutex = .new(),
    pages: []u32,

    pub fn init(size_bytes: usize) !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Frame.init size={}", .{size_bytes});

        const size_pages = std.math.divCeil(usize, size_bytes, 0x1000) catch unreachable;
        if (size_pages > std.math.maxInt(u32)) return error.OutOfMemory;

        const obj: *@This() = try slab_allocator.allocator().create(@This());
        const pages = try slab_allocator.allocator().alloc(u32, size_pages);

        @memset(pages, 0);

        obj.* = .{
            .lock = .newLocked(),
            .pages = pages,
        };
        obj.lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Frame.deinit", .{});

        for (self.pages) |page| {
            if (page == 0) continue;

            pmem.deallocChunk(
                addr.Phys.fromParts(.{ .page = page }),
                .@"4KiB",
            );
        }

        slab_allocator.allocator().free(self.pages);
        slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) void {
        if (conf.LOG_OBJ_CALLS)
            log.info("Frame.clone", .{});

        self.refcnt.inc();
    }

    pub fn write(self: *@This(), offset_bytes: usize, source: []const volatile u8) Error!void {
        var bytes = source;

        if (conf.LOG_OBJ_CALLS)
            log.info("Frame.write offset_bytes={} source.len={}", .{
                offset_bytes,
                source.len,
            });

        const limit = std.math.divCeil(usize, offset_bytes + bytes.len, 0x1000) catch
            return Error.OutOfBounds;

        {
            self.lock.lock();
            defer self.lock.unlock();

            if (limit > self.pages.len)
                return Error.OutOfBounds;
        }

        var it = self.data(offset_bytes, true);
        while (try it.next()) |dst_chunk| {
            if (dst_chunk.len == bytes.len) {
                @memcpy(dst_chunk, bytes);
                break;
            } else if (dst_chunk.len > bytes.len) {
                @memcpy(dst_chunk[0..bytes.len], bytes);
                break;
            } else { // dst_chunk.len < bytes.len
                @memcpy(dst_chunk, bytes[0..dst_chunk.len]);
                bytes = bytes[dst_chunk.len..];
            }
        }
    }

    pub fn read(self: *@This(), offset_bytes: usize, dest: []volatile u8) Error!void {
        var bytes = dest;

        if (conf.LOG_OBJ_CALLS)
            log.info("Frame.read offset_bytes={} dest.len={}", .{
                offset_bytes,
                dest.len,
            });

        const limit = std.math.divCeil(usize, offset_bytes + bytes.len, 0x1000) catch
            return Error.OutOfBounds;

        {
            self.lock.lock();
            defer self.lock.unlock();

            if (limit >= self.pages.len)
                return Error.OutOfBounds;
        }

        var it = self.data(offset_bytes, false);
        while (try it.next()) |src_chunk| {
            if (src_chunk.len == bytes.len) {
                @memcpy(bytes, src_chunk);
                break;
            } else if (src_chunk.len > bytes.len) {
                @memcpy(bytes, src_chunk[0..bytes.len]);
                break;
            } else { // src_chunk.len < bytes.len
                @memcpy(bytes[0..src_chunk.len], src_chunk);
                bytes = bytes[src_chunk.len..];
            }
        }
    }

    pub const DataIterator = struct {
        frame: *Frame,
        offset_within_first: ?u32,
        idx: u32,
        is_write: bool,

        pub fn next(self: *@This()) !?[]volatile u8 {
            if (self.idx >= self.frame.pages.len)
                return null;

            defer self.idx += 1;
            defer self.offset_within_first = null;

            const page = try self.frame.page_hit(self.idx, self.is_write);

            return addr.Phys.fromParts(.{ .page = page })
                .toHhdm()
                .toPtr([*]volatile u8)[0 .. self.offset_within_first orelse 0x1000];
        }
    };

    pub fn data(self: *@This(), offset_bytes: usize, is_write: bool) DataIterator {
        if (offset_bytes >= self.pages.len * 0x1000) {
            return .{
                .frame = self,
                .offset_within_first = null,
                .idx = @intCast(self.pages.len),
                .is_write = is_write,
            };
        }

        const first_byte = std.mem.alignBackward(usize, offset_bytes, 0x1000);
        const offset_within_page: ?u32 = if (first_byte == offset_bytes)
            null
        else
            @intCast(offset_bytes - first_byte);

        return .{
            .frame = self,
            .offset_within_first = offset_within_page,
            .idx = @intCast(first_byte / 0x1000),
            .is_write = is_write,
        };
    }

    pub fn page_hit(self: *@This(), idx: u32, is_write: bool) !u32 {
        self.lock.lock();
        defer self.lock.unlock();

        std.debug.assert(idx < self.pages.len);
        const page = &self.pages[idx];

        // const readonly_zero_page_now = readonly_zero_page.load(.monotonic);
        _ = is_write;

        // TODO: (page.* == readonly_zero_page_now or page.* == 0) and is_write
        if (page.* == 0) {
            // writing to a lazy allocated zeroed page
            // => allocate a new exclusive page and set it be the mapping
            // FIXME: modify existing mappings

            const new_page = pmem.allocChunk(.@"4KiB") orelse return error.OutOfMemory;
            page.* = new_page.toParts().page;
            return page.*;
        } else {
            // already mapped AND write to a page that isnt readonly_zero_page or read from any page
            // => use the existing page
            return page.*;
        }

        // else { // page.* == 0
        //     // not mapped and isnt write
        //     // => use the shared readonly zero page

        //     page.* = readonly_zero_page_now;
        //     return page.*;
        // }
    }
};

pub const Vmem = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    lock: spin.Mutex = .new(),
    cr3: u32,
    mappings: std.ArrayList(Mapping),

    const Mapping = struct {
        /// refcounted
        frame: *Frame,
        /// page offset within the Frame object
        frame_first_page: u32,
        /// number of bytes (rounded up to pages) mapped
        pages: u32,
        target: packed struct {
            /// mapping flags
            rights: abi.sys.Rights,
            _: u4 = 0,
            /// virtual address destination of the mapping
            /// `mappings` is sorted by this
            page: u52,
        },

        fn init(
            frame: *Frame,
            frame_first_page: u32,
            vaddr: addr.Virt,
            pages: u32,
            rights: abi.sys.Rights,
        ) @This() {
            return .{
                .frame = frame,
                .frame_first_page = frame_first_page,
                .pages = pages,
                .target = .{
                    .rights = rights,
                    .page = @truncate(vaddr.raw >> 12),
                },
            };
        }

        fn setVaddr(self: *@This(), vaddr: addr.Virt) void {
            self.target.page = @truncate(vaddr.raw >> 12);
        }

        fn getVaddr(self: *const @This()) addr.Virt {
            return addr.Virt.fromInt(self.target.page << 12);
        }

        /// this is a `any(self AND other)`
        fn overlaps(self: *const @This(), vaddr: addr.Virt, pages: u32) bool {
            const a_beg: usize = self.getVaddr().raw;
            const a_end: usize = self.getVaddr().raw + self.pages * 0x1000;
            const b_beg: usize = vaddr.raw;
            const b_end: usize = vaddr.raw + pages * 0x1000;

            if (a_end <= b_beg)
                return false;
            if (b_end <= a_beg)
                return false;
            return true;
        }

        fn isEmpty(self: *const @This()) bool {
            return self.pages == 0;
        }
    };

    pub fn init() !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.init", .{});

        const obj: *@This() = try slab_allocator.allocator().create(@This());
        const mappings = std.ArrayList(Mapping).init(slab_allocator.allocator());

        obj.* = .{
            .lock = .newLocked(),
            .cr3 = 0,
            .mappings = mappings,
        };
        obj.lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.deinit", .{});

        for (self.mappings.items) |mapping| {
            mapping.frame.deinit();
        }

        self.mappings.deinit();
        slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) void {
        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.clone", .{});

        self.refcnt.inc();
    }

    pub fn switchTo(self: *@This()) void {
        std.debug.assert(self.cr3 != 0);
        HalVmem.switchTo(addr.Phys.fromParts(
            .{ .page = self.cr3 },
        ));
    }

    pub fn start(self: *@This()) !void {
        if (self.cr3 == 0) {
            @branchHint(.cold);

            const new_cr3 = try HalVmem.alloc(null);
            HalVmem.init(new_cr3);
            self.cr3 = new_cr3.toParts().page;
        }
    }

    pub fn map(
        self: *@This(),
        frame: *Frame,
        frame_first_page: u32,
        vaddr: addr.Virt,
        pages: u32,
        rights: abi.sys.Rights,
    ) !void {
        errdefer frame.deinit();

        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.map frame={*} frame_first_page={} vaddr=0x{x} pages={} rights={}", .{
                frame,
                frame_first_page,
                vaddr.raw,
                pages,
                rights,
            });

        if (pages == 0 or vaddr.raw == 0)
            return error.InvalidArguments;

        std.debug.assert(vaddr.toParts().offset == 0);
        try @This().assert_userspace(vaddr, pages);

        {
            frame.lock.lock();
            defer frame.lock.unlock();
            if (pages + frame_first_page > frame.pages.len)
                return error.OutOfBounds;
        }

        const mapping = Mapping.init(
            frame,
            frame_first_page,
            vaddr,
            pages,
            rights,
        );

        self.lock.lock();
        defer self.lock.unlock();

        if (self.find(vaddr)) |idx| {
            const old_mapping = &self.mappings.items[idx];
            if (vaddr.raw == old_mapping.getVaddr().raw) {
                // replace old mapping
                old_mapping.frame.deinit();
                old_mapping.* = mapping;
            } else {
                // insert new mapping
                try self.mappings.insert(idx, mapping);
            }
        } else {
            // push new mapping
            try self.mappings.append(mapping);
        }
    }

    pub fn unmap(self: *@This(), vaddr: addr.Virt, pages: u32) !void {
        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.unmap vaddr=0x{x} pages={}", .{ vaddr.raw, pages });

        if (pages == 0) return;
        std.debug.assert(vaddr.toParts().offset == 0);
        try @This().assert_userspace(vaddr, pages);

        self.lock.lock();
        defer self.lock.unlock();

        var idx = self.find(vaddr) orelse return;

        while (true) {
            if (idx >= self.mappings.items.len)
                break;
            const mapping = &self.mappings.items[idx];

            // cut the mapping into 0, 1 or 2 mappings

            const a_beg: usize = mapping.getVaddr().raw;
            const a_end: usize = mapping.getVaddr().raw + mapping.pages * 0x1000;
            const b_beg: usize = vaddr.raw;
            const b_end: usize = vaddr.raw + pages * 0x1000;

            if (a_end <= b_beg or b_end <= a_beg) {
                // case 0: no overlaps

                break;
            } else if (b_beg <= a_beg and b_end <= a_end) {
                // case 1:
                // b: |---------|
                // a:      |=====-----|

                const shift: u32 = @intCast((b_end - a_beg) / 0x1000);
                mapping.setVaddr(addr.Virt.fromInt(b_end));
                mapping.pages -= shift;
                mapping.frame_first_page += shift;
                break;
            } else if (a_beg >= b_beg and a_end <= a_end) {
                // case 2:
                // b: |---------------------|
                // a:      |==========|

                mapping.pages = 0;
            } else if (b_beg >= a_beg and b_end >= a_end) {
                // case 3:
                // b:            |---------|
                // a:      |-----=====|

                const trunc: u32 = @intCast((a_end - b_beg) / 0x1000);
                mapping.pages -= trunc;
            } else {
                std.debug.assert(a_beg < b_beg);
                std.debug.assert(a_end > b_end);
                // case 4:
                // b:      |----------|
                // a: |----============-----|
                // cases 1,2,3 already cover equal start/end bounds

                mapping.frame.clone();
                var cloned = mapping.*;

                const trunc: u32 = @intCast((a_end - b_beg) / 0x1000);
                mapping.pages -= trunc;

                const shift: u32 = @intCast((b_end - a_beg) / 0x1000);
                cloned.setVaddr(addr.Virt.fromInt(b_end));
                cloned.pages -= shift;
                cloned.frame_first_page += shift;

                _ = try self.mappings.insert(idx + 1, cloned);
                break;
            }

            if (mapping.pages == 0) {
                mapping.frame.deinit();
                _ = self.mappings.orderedRemove(idx); // TODO: batch remove
            } else {
                idx += 1;
            }
        }

        // FIXME: track CPUs using this page map
        // and IPI them out while unmapping

        if (self.cr3 == 0)
            return;

        const vmem: *volatile HalVmem = addr.Phys.fromParts(.{ .page = self.cr3 })
            .toHhdm()
            .toPtr(*volatile HalVmem);

        for (0..pages) |page_idx| {
            // already checked to be in bounds
            const page_vaddr = addr.Virt.fromInt(vaddr.raw + page_idx * 0x1000);
            vmem.unmapFrame(page_vaddr) catch |err| {
                log.warn("unmap err: {}, should be ok", .{err});
            };
        }
    }

    pub fn pageFault(
        self: *@This(),
        caused_by: arch.FaultCause,
        vaddr_unaligned: addr.Virt,
    ) !void {
        const vaddr: addr.Virt = addr.Virt.fromInt(std.mem.alignBackward(
            usize,
            vaddr_unaligned.raw,
            0x1000,
        ));

        self.lock.lock();
        defer self.lock.unlock();

        // for (self.mappings.items) |mapping| {
        //     const va = mapping.getVaddr().raw;
        //     log.info("mapping [ 0x{x:0>16}..0x{x:0>16} ]", .{
        //         va,
        //         va + 0x1000 * mapping.pages,
        //     });
        // }

        // check if it was user error
        const idx = self.find(vaddr) orelse
            return error.NotMapped;

        const mapping = self.mappings.items[idx];

        // check if it was user error
        if (!mapping.overlaps(vaddr, 1))
            return error.NotMapped;

        // check if it was user error
        switch (caused_by) {
            .read => {
                if (!mapping.target.rights.readable)
                    return error.ReadFault;
            },
            .write => {
                if (!mapping.target.rights.readable)
                    return error.WriteFault;
            },
            .exec => {
                if (!mapping.target.rights.readable)
                    return error.ExecFault;
            },
        }

        // check if it is lazy mapping

        const page_offs: u32 = @intCast((vaddr.raw - mapping.getVaddr().raw) / 0x1000);
        std.debug.assert(page_offs < mapping.pages);
        std.debug.assert(self.cr3 != 0);

        const vmem: *volatile HalVmem = addr.Phys.fromParts(.{ .page = self.cr3 })
            .toHhdm()
            .toPtr(*volatile HalVmem);

        const entry = (try vmem.entryFrame(vaddr)).*;

        switch (caused_by) {
            .read, .exec => {
                // was mapped but only now accessed using a read/exec
                std.debug.assert(entry.present == 0);

                const wanted_page_index = try mapping.frame.page_hit(
                    mapping.frame_first_page + page_offs,
                    false,
                );
                std.debug.assert(entry.page_index != wanted_page_index); // mapping error from a previous fault

                try vmem.mapFrame(
                    addr.Phys.fromParts(.{ .page = wanted_page_index }),
                    vaddr,
                    mapping.target.rights,
                    .{},
                );

                return;
            },
            .write => {
                // was mapped but only now accessed using a write

                // a read from a lazy
                const wanted_page_index = try mapping.frame.page_hit(
                    mapping.frame_first_page + page_offs,
                    true,
                );
                std.debug.assert(entry.page_index != wanted_page_index); // mapping error from a previous fault

                try vmem.mapFrame(
                    addr.Phys.fromParts(.{ .page = wanted_page_index }),
                    vaddr,
                    mapping.target.rights,
                    .{},
                );

                return;

                // TODO: copy on write maps
            },
        }

        // mapping has all rights and is present, the page fault should not have happened
        unreachable;
    }

    fn assert_userspace(vaddr: addr.Virt, pages: u32) !void {
        const upper_bound: usize = std.math.add(
            usize,
            vaddr.raw,
            std.math.mul(
                usize,
                pages,
                0x1000,
            ) catch return error.OutOfBounds,
        ) catch return error.OutOfBounds;
        if (upper_bound > 0x8000_0000_0000) {
            return error.OutOfBounds;
        }
    }

    fn find(self: *@This(), vaddr: addr.Virt) ?usize {
        const idx = std.sort.partitionPoint(
            Mapping,
            self.mappings.items,
            vaddr,
            struct {
                fn pred(target_vaddr: addr.Virt, val: Mapping) bool {
                    return (val.getVaddr().raw + 0x1000 * val.pages) < target_vaddr.raw;
                }
            }.pred,
        );

        if (idx == self.mappings.items.len)
            return null;

        return idx;
    }
};

pub const Process = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    vmem: *Vmem,
    lock: spin.Mutex = .newLocked(),
    // caps: std.ArrayList(Capability),

    pub fn init(from_vmem: *Vmem) !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Process.init", .{});

        const obj: *@This() = try slab_allocator.allocator().create(@This());
        obj.* = .{ .vmem = from_vmem };
        obj.lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Process.deinit", .{});

        self.vmem.deinit();

        slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) void {
        if (conf.LOG_OBJ_CALLS)
            log.info("Process.clone", .{});

        self.refcnt.inc();
    }
};

pub const Thread = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    proc: *Process,
    // lock for modifying / executing the thread
    lock: spin.Mutex = .newLocked(),
    /// all context data
    trap: arch.SyscallRegs = .{},
    /// scheduler priority
    priority: u2 = 1,
    /// is the thread stopped/running/ready/waiting
    status: enum { stopped, running, ready, waiting } = .stopped,
    /// scheduler linked list
    next: ?*Thread = null,
    /// scheduler linked list
    prev: ?*Thread = null,

    pub fn init(from_proc: *Process) !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Thread.init", .{});

        const obj: *@This() = try slab_allocator.allocator().create(@This());
        obj.* = .{ .proc = from_proc };
        obj.lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Thread.deinit", .{});

        self.proc.deinit();

        slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) void {
        if (conf.LOG_OBJ_CALLS)
            log.info("Thread.clone", .{});

        self.refcnt.inc();
    }
};

var slab_allocator = abi.mem.SlabAllocator.init(pmem.page_allocator);
/// written once by the BSP with .release before any other CPU runs
/// only read after that with .monotonic
var readonly_zero_page: std.atomic.Value(u32) = .init(0);

fn debugType(comptime T: type) void {
    std.log.debug("{s}: size={} align={}", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
}

test "new VmemObject and FrameObject" {
    const vmem = try Vmem.init();
    const frame = try Frame.init(0x8000);
    frame.clone();
    try vmem.map(frame, 1, addr.Virt.fromInt(0x1000), 6, .{
        .readable = true,
        .writable = true,
        .executable = true,
    });
    try vmem.start();
    vmem.switchTo();
    vmem.pageFault(
        .write,
        addr.Virt.fromInt(0x1000),
    ) catch unreachable;
    vmem.pageFault(
        .write,
        addr.Virt.fromInt(0x4000),
    ) catch unreachable;
    try vmem.unmap(addr.Virt.fromInt(0x2000), 1);
    std.debug.assert(error.NotMapped == vmem.pageFault(
        .write,
        addr.Virt.fromInt(0x2000),
    ));
    vmem.pageFault(
        .write,
        addr.Virt.fromInt(0x5000),
    ) catch unreachable;
    const a = try frame.page_hit(4, true);
    const b = try frame.page_hit(4, false);
    std.debug.assert(a == b);
    std.debug.assert(a != 0);
    frame.deinit();
    vmem.deinit();
}
