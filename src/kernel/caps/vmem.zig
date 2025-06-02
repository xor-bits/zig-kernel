const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const spin = @import("../spin.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const Vmem = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    lock: spin.Mutex = .new(),
    cr3: u32,
    mappings: std.ArrayList(Mapping),

    pub const Mapping = struct {
        /// refcounted
        frame: *caps.Frame,
        /// page offset within the Frame object
        frame_first_page: u32,
        /// number of bytes (rounded up to pages) mapped
        pages: u32,
        target: packed struct {
            /// mapping rights
            rights: abi.sys.Rights,
            /// mapping flags
            flags: abi.sys.MapFlags,
            /// virtual address destination of the mapping
            /// `mappings` is sorted by this
            page: u48,
        },

        fn init(
            frame: *caps.Frame,
            frame_first_page: u32,
            vaddr: addr.Virt,
            pages: u32,
            rights: abi.sys.Rights,
            flags: abi.sys.MapFlags,
        ) @This() {
            return .{
                .frame = frame,
                .frame_first_page = frame_first_page,
                .pages = pages,
                .target = .{
                    .rights = rights,
                    .flags = flags,
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

    pub fn init() Error!*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.init", .{});

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        const mappings = std.ArrayList(Mapping).init(caps.slab_allocator.allocator());

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
        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.clone", .{});

        self.refcnt.inc();
        return self;
    }

    pub fn write(self: *@This(), vaddr: addr.Virt, source: []const volatile u8) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.write", .{});

        var bytes: []const volatile u8 = source;

        if (bytes.len == 0)
            return;

        self.lock.lock();
        defer self.lock.unlock();

        const idx_beg, const idx_end = try self.data(vaddr, bytes.len);

        for (idx_beg..idx_end) |idx| {
            std.debug.assert(bytes.len != 0);
            const mapping = &self.mappings.items[idx];

            const offset_bytes: usize = if (idx == idx_beg)
                vaddr.raw - mapping.getVaddr().raw
            else
                0;
            const limit = @min(mapping.pages * 0x1000 - offset_bytes, bytes.len);

            try mapping.frame.write(
                mapping.frame_first_page * 0x1000 + offset_bytes,
                bytes[0..limit],
            );
            bytes = bytes[limit..];
        }
    }

    pub fn read(self: *@This(), vaddr: addr.Virt, dest: []volatile u8) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.read vaddr=0x{x} dest.len={}", .{ vaddr.raw, dest.len });

        var bytes: []volatile u8 = dest;

        if (bytes.len == 0)
            return;

        self.lock.lock();
        defer self.lock.unlock();

        const idx_beg, const idx_end = try self.data(vaddr, bytes.len);

        for (idx_beg..idx_end) |idx| {
            std.debug.assert(bytes.len != 0);
            const mapping = &self.mappings.items[idx];

            // log.info("mapping [ 0x{x}..0x{x} ]", .{
            //     mapping.getVaddr().raw,
            //     mapping.getVaddr().raw + mapping.pages * 0x1000,
            // });

            const offset_bytes: usize = if (idx == idx_beg)
                vaddr.raw - mapping.getVaddr().raw
            else
                0;
            const limit = @min(mapping.pages * 0x1000 - offset_bytes, bytes.len);

            try mapping.frame.read(
                mapping.frame_first_page * 0x1000 + offset_bytes,
                bytes[0..limit],
            );
            bytes = bytes[limit..];
        }
    }

    /// assumes `self` is locked
    fn data(self: *@This(), vaddr: addr.Virt, len: usize) Error!struct { usize, usize } {
        std.debug.assert(len != 0);

        if (self.mappings.items.len == 0)
            return Error.InvalidAddress;

        const vaddr_end_exclusive = try addr.Virt.fromUser(vaddr.raw + len);
        const vaddr_end_inclusive = try addr.Virt.fromUser(vaddr.raw + len - 1);

        const idx_beg: usize = self.find(vaddr) orelse return Error.InvalidAddress;
        const idx_end: usize = 1 + (self.find(vaddr_end_exclusive) orelse (self.mappings.items.len - 1));

        std.debug.assert(self.mappings.items[idx_beg].overlaps(vaddr, 0));
        std.debug.assert(self.mappings.items[idx_end - 1].overlaps(vaddr_end_inclusive, 0));

        // make sure the mappings are contiguous (no unmapped holes)
        for (idx_beg..@max(idx_beg, idx_end - 1)) |idx| {
            const prev_mapping = &self.mappings.items[idx];
            const next_mapping = &self.mappings.items[idx + 1];

            errdefer log.warn("Vmem.write memory not contiguous", .{});
            if (prev_mapping.getVaddr().raw + prev_mapping.pages * 0x1000 != next_mapping.getVaddr().raw)
                return Error.InvalidAddress;
        }

        return .{ idx_beg, idx_end };
    }

    pub fn switchTo(self: *@This()) void {
        std.debug.assert(self.cr3 != 0);
        caps.HalVmem.switchTo(addr.Phys.fromParts(
            .{ .page = self.cr3 },
        ));
    }

    pub fn start(self: *@This()) Error!void {
        if (self.cr3 == 0) {
            @branchHint(.cold);

            const new_cr3 = try caps.HalVmem.alloc(null);
            caps.HalVmem.init(new_cr3);
            self.cr3 = new_cr3.toParts().page;
        }
    }

    pub fn map(
        self: *@This(),
        frame: *caps.Frame,
        frame_first_page: u32,
        vaddr: addr.Virt,
        pages: u32,
        rights: abi.sys.Rights,
        flags: abi.sys.MapFlags,
    ) Error!void {
        errdefer frame.deinit();

        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.map frame={*} frame_first_page={} vaddr=0x{x} pages={} rights={} flags={}", .{
                frame,
                frame_first_page,
                vaddr.raw,
                pages,
                rights,
                flags,
            });

        if (pages == 0 or vaddr.raw == 0)
            return Error.InvalidArgument;

        std.debug.assert(vaddr.toParts().offset == 0);
        try @This().assert_userspace(vaddr, pages);

        {
            frame.lock.lock();
            defer frame.lock.unlock();
            if (pages + frame_first_page > frame.pages.len)
                return Error.OutOfBounds;
        }

        const mapping = Mapping.init(
            frame,
            frame_first_page,
            vaddr,
            pages,
            rights,
            flags,
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

    pub fn unmap(self: *@This(), vaddr: addr.Virt, pages: u32) Error!void {
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

                var cloned = mapping.*;
                cloned.frame = mapping.frame.clone();

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

        const vmem: *volatile caps.HalVmem = addr.Phys.fromParts(.{ .page = self.cr3 })
            .toHhdm()
            .toPtr(*volatile caps.HalVmem);

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
    ) Error!void {
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
            return Error.NotMapped;

        const mapping = self.mappings.items[idx];

        // check if it was user error
        if (!mapping.overlaps(vaddr, 1))
            return Error.NotMapped;

        // check if it was user error
        switch (caused_by) {
            .read => {
                if (!mapping.target.rights.readable)
                    return Error.ReadFault;
            },
            .write => {
                if (!mapping.target.rights.readable)
                    return Error.WriteFault;
            },
            .exec => {
                if (!mapping.target.rights.readable)
                    return Error.ExecFault;
            },
        }

        // check if it is lazy mapping

        const page_offs: u32 = @intCast((vaddr.raw - mapping.getVaddr().raw) / 0x1000);
        std.debug.assert(page_offs < mapping.pages);
        std.debug.assert(self.cr3 != 0);

        const vmem: *volatile caps.HalVmem = addr.Phys.fromParts(.{ .page = self.cr3 })
            .toHhdm()
            .toPtr(*volatile caps.HalVmem);

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
                    mapping.target.flags,
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
                    mapping.target.flags,
                );

                return;

                // TODO: copy on write maps
            },
        }

        // mapping has all rights and is present, the page fault should not have happened
        unreachable;
    }

    fn assert_userspace(vaddr: addr.Virt, pages: u32) Error!void {
        const upper_bound: usize = std.math.add(
            usize,
            vaddr.raw,
            std.math.mul(
                usize,
                pages,
                0x1000,
            ) catch return Error.OutOfBounds,
        ) catch return Error.OutOfBounds;
        if (upper_bound > 0x8000_0000_0000) {
            return Error.OutOfBounds;
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
