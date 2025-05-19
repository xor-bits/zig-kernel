const std = @import("std");
const abi = @import("abi");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");
const spin = @import("../spin.zig");
const util = @import("../util.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;
const volat = util.volat;

//

pub fn init() !void {
    const cr3 = arch.Cr3.read();
    const level4 = addr.Phys.fromInt(cr3.pml4_phys_base << 12)
        .toHhdm().toPtr(*Vmem);
    // TODO: make a deep copy instead and make every higher half mapping global
    abi.util.copyForwardsVolatile(Entry, kernel_table.entries[256..], level4.entries[256..]);
}

var kernel_table: Vmem = undefined;

//

pub fn growCapArray() u32 {
    caps.array_grow_lock.lock();
    defer caps.array_grow_lock.unlock();

    const current_len = caps.capability_array_len.raw;
    const new_page_addr = addr.Virt.fromPtr(&caps.capabilityArrayUnchecked().ptr[current_len]);

    const last_byte_of_prev = new_page_addr.raw - 1;
    const last_byte_of_next = new_page_addr.raw + @sizeOf(caps.Object) - 1;
    const last_page = addr.Virt.fromInt(last_byte_of_next);

    const SIZE_4KIB_MASK = ~(@as(usize, 0x00001000 - 1));
    const map_frame = last_byte_of_prev & SIZE_4KIB_MASK != last_byte_of_next & SIZE_4KIB_MASK;

    if (map_frame) {
        kernel_table.mapFrame(allocPage(), last_page, .{
            .readable = true,
            .writable = true,
            .user_accessible = false,
        }, .{
            .global = true,
        }) catch std.debug.panic("invalid kernel page table", .{});
    }

    const cap_id = &caps.capabilityArrayUnchecked()[current_len];
    cap_id.* = .{};

    const next = caps.capability_array_len.fetchAdd(1, .acquire);
    if (next > std.math.maxInt(u32)) std.debug.panic("too many capabilities", .{});

    std.debug.assert(next == current_len);

    return @truncate(next);
}

fn allocPage() addr.Phys {
    return pmem.allocChunk(.@"4KiB") orelse std.debug.panic("OOM", .{});
}

fn allocTable() addr.Phys {
    const table = allocPage();
    const entries: []volatile Entry = table.toHhdm().toPtr([*]volatile Entry)[0..512];
    abi.util.fillVolatile(Entry, entries, .{});
    return table;
}

fn nextLevel(comptime create: bool, current: *volatile [512]Entry, i: u9) Error!addr.Phys {
    return nextLevelFromEntry(create, &current[i]);
}

fn deallocLevel(current: *volatile [512]Entry, i: u9) void {
    const entry = volat(&current[i]).*;
    volat(&current[i]).* = .{};
    pmem.deallocChunk(addr.Phys.fromParts(.{ .page = entry.page_index }), .@"4KiB");
}

fn nextLevelFromEntry(comptime create: bool, entry: *volatile Entry) Error!addr.Phys {
    const entry_r = entry.*;
    if (entry_r.present == 0 and create) {
        const table = allocTable();
        entry.* = Entry.fromParts(
            false,
            false,
            .{
                .writable = true,
                .executable = true,
            },
            table,
            .{},
        );
        return table;
    } else if (entry_r.present == 0) {
        return error.EntryNotPresent;
    } else if (entry_r.huge_page_or_pat == 1) {
        return error.EntryIsHuge;
    } else {
        return addr.Phys.fromParts(.{ .page = entry_r.page_index });
    }
}

fn isEmpty(entries: *volatile [512]Entry) bool {
    for (entries) |*entry| {
        if (volat(entry).*.present == 1)
            return false;
    }
    return true;
}

// FIXME: flush TLB + IPI other CPUs to prevent race conditions
/// a `Thread` points to this
pub const Vmem = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn init(self: caps.Ref(@This())) void {
        const ptr = self.ptr();
        abi.util.fillVolatile(Entry, ptr.entries[0..256], .{});
        abi.util.copyForwardsVolatile(Entry, ptr.entries[256..], kernel_table.entries[256..]);
    }

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return pmem.alloc(@sizeOf(@This())) orelse return Error.OutOfMemory;
    }

    pub fn call(self_paddr: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.VmemCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (conf.LOG_OBJ_CALLS)
            log.debug("vmem call \"{s}\" {}", .{ @tagName(call_id), trap.readMessage() });

        const self = (caps.Ref(@This()){ .paddr = self_paddr }).ptr();

        switch (call_id) {
            .map => {
                // lock the frame temporarily, mark it as mapped and unmark it if an error occurs
                const frame_obj = try caps.getCapability(thread, @truncate(trap.arg2));
                if (frame_obj.flags & 1 != 0) {
                    frame_obj.lock.unlock();
                    return Error.AlreadyMapped;
                }
                frame_obj.flags |= 1;
                errdefer frame_obj.flags &= ~@as(u16, 1);
                defer frame_obj.lock.unlock();

                const paddr: addr.Phys, const size: usize = b: {
                    if (frame_obj.as(caps.Frame)) |frame| {
                        break :b .{
                            addr.Phys.fromInt(caps.Frame.addrOf(frame)),
                            caps.Frame.sizeOf(frame).sizeBytes(),
                        };
                    } else |_| {
                        @branchHint(.unlikely); // normal frames are more likely than MMIO frames
                    }

                    if (frame_obj.as(caps.DeviceFrame)) |frame| {
                        break :b .{
                            addr.Phys.fromInt(caps.DeviceFrame.addrOf(frame)),
                            caps.DeviceFrame.sizeOf(frame).sizeBytes(),
                        };
                    } else |_| {
                        @branchHint(.unlikely);
                    }

                    return Error.InvalidCapability;
                };

                const vaddr = try addr.Virt.fromUser(trap.arg3);
                const rights: abi.sys.Rights = .fromInt(@truncate(trap.arg4));
                const flags: abi.sys.MapFlags = .fromInt(@truncate(trap.arg5));

                const size_1gib = comptime abi.ChunkSize.@"1GiB".sizeBytes();
                const size_2mib = comptime abi.ChunkSize.@"2MiB".sizeBytes();
                const size_4kib = comptime abi.ChunkSize.@"4KiB".sizeBytes();

                if (conf.LOG_OBJ_CALLS)
                    log.info("mapping 0x{x} from 0x{x} to 0x{x}", .{ size, paddr.raw, vaddr.raw });

                if (size >= size_1gib) {
                    try self.mapAnyFrame(
                        @This().canMapGiantFrame,
                        @This().mapGiantFrame,
                        size,
                        size_1gib,
                        paddr,
                        vaddr,
                        rights,
                        flags,
                    );
                } else if (size >= size_2mib) {
                    try self.mapAnyFrame(
                        @This().canMapHugeFrame,
                        @This().mapHugeFrame,
                        size,
                        size_2mib,
                        paddr,
                        vaddr,
                        rights,
                        flags,
                    );
                } else {
                    try self.mapAnyFrame(
                        @This().canMapFrame,
                        @This().mapFrame,
                        size,
                        size_4kib,
                        paddr,
                        vaddr,
                        rights,
                        flags,
                    );
                }
            },
            .unmap => {
                // lock the frame temporarily, check that it is mapped here and unmark it
                const frame_obj = try caps.getCapability(thread, @truncate(trap.arg2));
                // TODO: maybe check if it is the correct frame cap that gets unmapped
                if (frame_obj.flags & 1 == 0) {
                    frame_obj.lock.unlock();
                    return Error.AlreadyMapped;
                }
                frame_obj.flags &= ~@as(u16, 1);
                errdefer frame_obj.flags |= 1;
                defer frame_obj.lock.unlock();

                const paddr: addr.Phys, const size: usize = b: {
                    if (frame_obj.as(caps.Frame)) |frame| {
                        break :b .{
                            addr.Phys.fromInt(caps.Frame.addrOf(frame)),
                            caps.Frame.sizeOf(frame).sizeBytes(),
                        };
                    } else |_| {
                        @branchHint(.unlikely); // normal frames are more likely than MMIO frames
                    }

                    if (frame_obj.as(caps.DeviceFrame)) |frame| {
                        break :b .{
                            addr.Phys.fromInt(caps.DeviceFrame.addrOf(frame)),
                            caps.DeviceFrame.sizeOf(frame).sizeBytes(),
                        };
                    } else |_| {
                        @branchHint(.unlikely);
                    }

                    return Error.InvalidCapability;
                };

                const vaddr = try addr.Virt.fromUser(trap.arg3);

                const size_1gib = comptime abi.ChunkSize.@"1GiB".sizeBytes();
                const size_2mib = comptime abi.ChunkSize.@"2MiB".sizeBytes();
                const size_4kib = comptime abi.ChunkSize.@"4KiB".sizeBytes();

                if (conf.LOG_OBJ_CALLS)
                    log.info("unmapping 0x{x} from 0x{x} to 0x{x}", .{ size, paddr.raw, vaddr.raw });

                if (size >= size_1gib) {
                    try self.unmapAnyFrame(
                        @This().canUnmapGiantFrame,
                        @This().unmapGiantFrame,
                        size,
                        size_1gib,
                        paddr,
                        vaddr,
                    );
                } else if (size >= size_2mib) {
                    try self.unmapAnyFrame(
                        @This().canUnmapHugeFrame,
                        @This().unmapHugeFrame,
                        size,
                        size_2mib,
                        paddr,
                        vaddr,
                    );
                } else {
                    try self.unmapAnyFrame(
                        @This().canUnmapFrame,
                        @This().unmapFrame,
                        size,
                        size_4kib,
                        paddr,
                        vaddr,
                    );
                }
            },
        }
    }

    fn mapAnyFrame(
        self: *volatile @This(),
        comptime canMap: anytype,
        comptime doMap: anytype,
        frame_size: usize,
        comptime page_size: usize,
        _paddr: addr.Phys,
        _vaddr: addr.Virt,
        rights: abi.sys.Rights,
        flags: abi.sys.MapFlags,
    ) Error!void {
        const count = frame_size / page_size;
        var paddr = _paddr;
        var vaddr = _vaddr;

        // first check if mapping would fail (dry-run)
        for (0..count) |_| {
            if (conf.LOG_OBJ_CALLS)
                log.info("canMap(0x{x})", .{vaddr.raw});
            try canMap(self, vaddr);
            vaddr.raw += page_size;
        }
        if (conf.LOG_OBJ_CALLS)
            log.info("canUnmap pass", .{});

        paddr = _paddr;
        vaddr = _vaddr;

        // then actually map
        for (0..count) |_| {
            doMap(self, paddr, vaddr, rights, flags) catch |err| {
                log.err("canMap() returned true but doMap() failed: {}", .{err});
                unreachable;
            };
            arch.flushTlbAddr(vaddr.raw);
            paddr.raw += page_size;
            vaddr.raw += page_size;
        }
    }

    fn unmapAnyFrame(
        self: *volatile @This(),
        comptime canUnmap: anytype,
        comptime doUnmap: anytype,
        frame_size: usize,
        comptime page_size: usize,
        _paddr: addr.Phys,
        _vaddr: addr.Virt,
    ) Error!void {
        const count = frame_size / page_size;
        var paddr = _paddr;
        var vaddr = _vaddr;

        // first check if unmapping would fail (dry-run)
        for (0..count) |_| {
            if (conf.LOG_OBJ_CALLS)
                log.info("canUnmap(0x{x}, 0x{x})", .{ paddr.raw, vaddr.raw });
            try canUnmap(self, paddr, vaddr);
            paddr.raw += page_size;
            vaddr.raw += page_size;
        }
        if (conf.LOG_OBJ_CALLS)
            log.info("canUnmap pass", .{});

        paddr = _paddr;
        vaddr = _vaddr;

        // then actually unmap
        for (0..count) |_| {
            doUnmap(self, vaddr) catch |err| {
                log.err("canUnmap() returned true but doUnmap() failed: {}", .{err});
                unreachable;
            };
            arch.flushTlbAddr(vaddr.raw); // FIXME: this is not enough with SMP
            vaddr.raw += page_size;
        }
    }

    pub fn switchTo(self: caps.Ref(@This())) void {
        const cur = arch.Cr3.read();
        if (cur.pml4_phys_base == self.paddr.toParts().page) {
            // log.info("context switch avoided", .{});
            return;
        }

        (arch.Cr3{
            .pml4_phys_base = self.paddr.toParts().page,
        }).write();
    }

    pub fn mapGiantFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        try next.mapGiantFrame(paddr, vaddr, rights, flags);
    }

    pub fn mapHugeFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        try next.mapHugeFrame(paddr, vaddr, rights, flags);
    }

    pub fn mapFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        try next.mapFrame(paddr, vaddr, rights, flags);
    }

    pub fn canMapGiantFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.canMapGiantFrame(vaddr);
    }

    pub fn canMapHugeFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.canMapHugeFrame(vaddr);
    }

    pub fn canMapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.canMapFrame(vaddr);
    }

    pub fn unmapGiantFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const current, const i = .{ &self.entries, vaddr.toParts().level4 };
        const next = (try nextLevel(true, current, i)).toHhdm().toPtr(*volatile PageTableLevel3);
        if (next.unmapGiantFrame(vaddr))
            deallocLevel(current, i);
    }

    pub fn unmapHugeFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const current, const i = .{ &self.entries, vaddr.toParts().level4 };
        const next = (try nextLevel(true, current, i)).toHhdm().toPtr(*volatile PageTableLevel3);
        if (try next.unmapHugeFrame(vaddr))
            deallocLevel(current, i);
    }

    pub fn unmapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const current, const i = .{ &self.entries, vaddr.toParts().level4 };
        const next = (try nextLevel(true, current, i)).toHhdm().toPtr(*volatile PageTableLevel3);
        if (try next.unmapFrame(vaddr))
            deallocLevel(current, i);
    }

    pub fn canUnmapGiantFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.canUnmapGiantFrame(paddr, vaddr);
    }

    pub fn canUnmapHugeFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.canUnmapHugeFrame(paddr, vaddr);
    }

    pub fn canUnmapFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.canUnmapFrame(paddr, vaddr);
    }
};

/// a `PageTableLevel4` points to multiple of these
pub const PageTableLevel3 = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn mapGiantFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const entry = Entry.fromParts(true, false, rights, paddr, flags);
        volat(&self.entries[vaddr.toParts().level3]).* = entry;
    }

    pub fn mapHugeFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        try next.mapHugeFrame(paddr, vaddr, rights, flags);
    }

    pub fn mapFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        try next.mapFrame(paddr, vaddr, rights, flags);
    }

    pub fn canMapGiantFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const entry = volat(&self.entries[vaddr.toParts().level3]).*;
        if (entry.present == 1) return Error.MappingOverlap;
    }

    pub fn canMapHugeFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        return next.canMapHugeFrame(vaddr);
    }

    pub fn canMapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        return next.canMapFrame(vaddr);
    }

    pub fn unmapGiantFrame(self: *volatile @This(), vaddr: addr.Virt) bool {
        volat(&self.entries[vaddr.toParts().level3]).* = .{};
        return isEmpty(&self.entries);
    }

    pub fn unmapHugeFrame(self: *volatile @This(), vaddr: addr.Virt) Error!bool {
        const current, const i = .{ &self.entries, vaddr.toParts().level3 };
        const next = (try nextLevel(true, current, i)).toHhdm().toPtr(*volatile PageTableLevel2);
        if (next.unmapHugeFrame(vaddr))
            deallocLevel(current, i);
        return isEmpty(&self.entries);
    }

    pub fn unmapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!bool {
        const current, const i = .{ &self.entries, vaddr.toParts().level3 };
        const next = (try nextLevel(true, current, i)).toHhdm().toPtr(*volatile PageTableLevel2);
        if (try next.unmapFrame(vaddr))
            deallocLevel(current, i);
        return isEmpty(&self.entries);
    }

    pub fn canUnmapGiantFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt) Error!void {
        const entry = volat(&self.entries[vaddr.toParts().level3]).*;
        if (entry.present != 1) return Error.NotMapped;
        if (entry.huge_page_or_pat != 1) return Error.NotMapped;
        if (entry.page_index & 0xFFFF_FFFE != paddr.toParts().page) return Error.NotMapped;
    }

    pub fn canUnmapHugeFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        return next.canUnmapHugeFrame(paddr, vaddr);
    }

    pub fn canUnmapFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        return next.canUnmapFrame(paddr, vaddr);
    }
};

/// a `PageTableLevel3` points to multiple of these
pub const PageTableLevel2 = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn mapHugeFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const entry = Entry.fromParts(true, false, rights, paddr, flags);
        volat(&self.entries[vaddr.toParts().level2]).* = entry;
    }

    pub fn mapFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level2)).toHhdm().toPtr(*volatile PageTableLevel1);
        next.mapFrame(paddr, vaddr, rights, flags);
    }

    pub fn canMapHugeFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const entry = volat(&self.entries[vaddr.toParts().level2]).*;
        if (entry.present == 1) return Error.MappingOverlap;
    }

    pub fn canMapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level2)).toHhdm().toPtr(*volatile PageTableLevel1);
        return next.canMapFrame(vaddr);
    }

    pub fn unmapHugeFrame(self: *volatile @This(), vaddr: addr.Virt) bool {
        volat(&self.entries[vaddr.toParts().level2]).* = .{};
        return isEmpty(&self.entries);
    }

    pub fn unmapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!bool {
        const current, const i = .{ &self.entries, vaddr.toParts().level2 };
        const next = (try nextLevel(true, current, i)).toHhdm().toPtr(*volatile PageTableLevel1);
        if (next.unmapFrame(vaddr))
            deallocLevel(current, i);
        return isEmpty(&self.entries);
    }

    pub fn canUnmapHugeFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt) Error!void {
        const entry: Entry = volat(&self.entries[vaddr.toParts().level2]).*;
        if (entry.present != 1) return Error.NotMapped;
        if (entry.huge_page_or_pat != 1) return Error.NotMapped;
        if (entry.page_index & 0xFFFF_FFFE != paddr.toParts().page) return Error.NotMapped;
    }

    pub fn canUnmapFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level2)).toHhdm().toPtr(*volatile PageTableLevel1);
        return next.canUnmapFrame(paddr, vaddr);
    }
};

/// a `PageTableLevel2` points to multiple of these
pub const PageTableLevel1 = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn mapFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) void {
        const entry = Entry.fromParts(false, true, rights, paddr, flags);
        volat(&self.entries[vaddr.toParts().level1]).* = entry;
    }

    pub fn canMapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const entry: Entry = volat(&self.entries[vaddr.toParts().level1]).*;
        if (entry.present == 1) return Error.MappingOverlap;
    }

    pub fn unmapFrame(self: *volatile @This(), vaddr: addr.Virt) bool {
        volat(&self.entries[vaddr.toParts().level1]).* = Entry{};
        return isEmpty(&self.entries);
    }

    pub fn canUnmapFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt) Error!void {
        const entry: Entry = volat(&self.entries[vaddr.toParts().level1]).*;
        if (entry.present != 1) return Error.NotMapped;
        if (entry.page_index != paddr.toParts().page) return Error.NotMapped;
    }
};

// just x86_64 rn
pub const Entry = packed struct {
    present: u1 = 0,
    writable: u1 = 0,
    user_accessible: u1 = 0,
    write_through: u1 = 0,
    cache_disable: u1 = 0,
    accessed: u1 = 0,
    dirty: u1 = 0,
    huge_page_or_pat: u1 = 0,
    global: u1 = 0,

    // more custom bits
    _free_to_use1: u3 = 0,

    page_index: u32 = 0,
    reserved: u8 = 0,

    // custom bits
    _free_to_use0: u7 = 0,

    protection_key: u4 = 0,
    no_execute: u1 = 0,

    pub fn getCacheMode(self: @This(), comptime is_last_level: bool) abi.sys.CacheType {
        var idx: u3 = 0;
        if (is_last_level)
            idx |= @as(u3, self.huge_page_or_pat) << 2
        else
            idx |= @as(u3, @truncate(self.page_index & 0b1)) << 2;
        idx |= @as(u3, self.cache_disable) << 1;
        idx |= @as(u3, self.write_through) << 0;
        return std.meta.intToEnum(abi.sys.CacheType, idx) catch unreachable;
    }

    pub fn fromParts(
        comptime is_huge: bool,
        comptime is_last_level: bool,
        rights: abi.sys.Rights,
        frame: addr.Phys,
        flags: abi.sys.MapFlags,
    ) Entry {
        std.debug.assert(frame.toParts().reserved0 == 0);
        std.debug.assert(frame.toParts().reserved1 == 0);

        var page_index = frame.toParts().page;
        var pwt: u1 = 0;
        var pcd: u1 = 0;
        var huge_page_or_pat: u1 = 0;
        const pat_index = @as(u3, @truncate(@intFromEnum(flags.cache)));
        if (is_last_level) {
            if (pat_index & 0b001 != 0) pwt = 1;
            if (pat_index & 0b010 != 0) pcd = 1;
            if (pat_index & 0b100 != 0) huge_page_or_pat = 1;
        } else if (is_huge) {
            if (pat_index & 0b001 != 0) pwt = 1;
            if (pat_index & 0b010 != 0) pcd = 1;
            if (pat_index & 0b100 != 0) page_index |= 1;
            huge_page_or_pat = 1;
        } else {
            // huge on last level is illegal
            // and intermediary tables dont have cache modes (prob)
        }

        return Entry{
            .present = 1,
            .writable = @intFromBool(rights.writable),
            .user_accessible = @intFromBool(rights.user_accessible),
            .write_through = pwt,
            .cache_disable = pcd,
            .huge_page_or_pat = huge_page_or_pat,
            .global = @intFromBool(flags.global),
            .page_index = page_index,
            .protection_key = @truncate(flags.protection_key),
            .no_execute = @intFromBool(!rights.executable),
        };
    }
};
