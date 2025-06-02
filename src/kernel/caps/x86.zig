const std = @import("std");
const abi = @import("abi");

const addr = @import("../addr.zig");
const apic = @import("../apic.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const util = @import("../util.zig");

//

const conf = abi.conf;
const log = std.log.scoped(.ioport);
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

//

// FIXME: flush TLB + IPI other CPUs to prevent race conditions
/// a `Thread` points to this
pub const Vmem = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn init(self: addr.Phys) void {
        const ptr = self.toHhdm().toPtr(*volatile @This());
        abi.util.fillVolatile(Entry, ptr.entries[0..256], .{});
        abi.util.copyForwardsVolatile(Entry, ptr.entries[256..], kernel_table.entries[256..]);
    }

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return pmem.alloc(@sizeOf(@This())) orelse return Error.OutOfMemory;
    }

    pub fn switchTo(self: addr.Phys) void {
        const cur = arch.Cr3.read();
        if (cur.pml4_phys_base == self.toParts().page) {
            // log.info("context switch avoided", .{});
            return;
        }

        (arch.Cr3{
            .pml4_phys_base = self.toParts().page,
        }).write();
    }

    pub fn entryGiantFrame(self: *volatile @This(), vaddr: addr.Virt) Error!*volatile Entry {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.entryGiantFrame(vaddr);
    }

    pub fn entryHugeFrame(self: *volatile @This(), vaddr: addr.Virt) Error!*volatile Entry {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.entryHugeFrame(vaddr);
    }

    pub fn entryFrame(self: *volatile @This(), vaddr: addr.Virt) Error!*volatile Entry {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.entryFrame(vaddr);
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

    pub fn entryGiantFrame(self: *volatile @This(), vaddr: addr.Virt) *volatile Entry {
        return &self.entries[vaddr.toParts().level3];
    }

    pub fn entryHugeFrame(self: *volatile @This(), vaddr: addr.Virt) Error!*volatile Entry {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        return next.entryHugeFrame(vaddr);
    }

    pub fn entryFrame(self: *volatile @This(), vaddr: addr.Virt) Error!*volatile Entry {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        return next.entryFrame(vaddr);
    }

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

    pub fn entryHugeFrame(self: *volatile @This(), vaddr: addr.Virt) *volatile Entry {
        return &self.entries[vaddr.toParts().level2];
    }

    pub fn entryFrame(self: *volatile @This(), vaddr: addr.Virt) Error!*volatile Entry {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level2)).toHhdm().toPtr(*volatile PageTableLevel1);
        return next.entryFrame(vaddr);
    }

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

    pub fn entryFrame(self: *volatile @This(), vaddr: addr.Virt) *volatile Entry {
        return &self.entries[vaddr.toParts().level1];
    }

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
            .global = 0,
            .page_index = page_index,
            .protection_key = 0,
            .no_execute = @intFromBool(!rights.executable),
        };
    }
};

//

var kernel_table: Vmem = undefined;

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

//

pub const X86IoPortAllocator = struct {
    pub fn init(_: caps.Ref(@This())) void {}

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return Error.InvalidArgument;
    }

    pub fn call(_: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.X86IoPortAllocatorCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (conf.LOG_OBJ_CALLS)
            log.debug("x86_ioport_allocator call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .alloc => {
                const port: u16 = @truncate(trap.arg2);
                try allocPort(&port_bitmap, port);

                const cap_id = caps.pushCapability((caps.Ref(X86IoPort){ .paddr = .fromInt(port) }).object(thread));
                trap.arg1 = cap_id;
            },
            .clone => {
                const cap_id = caps.pushCapability((caps.Ref(X86IoPortAllocator){ .paddr = .fromInt(0) }).object(thread));
                trap.arg1 = cap_id;
            },
        }
    }
};

pub const X86IoPort = struct {
    pub fn init(_: caps.Ref(@This())) void {}

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return Error.InvalidArgument;
    }

    pub fn call(port: addr.Phys, _: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.X86IoPortCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (conf.LOG_OBJ_CALLS)
            log.debug("x86_ioport call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .inb => {
                trap.arg1 = arch.inb(@truncate(port.raw));
            },
            .outb => {
                arch.outb(@truncate(port.raw), @truncate(trap.arg2));
            },
            // .free
        }
    }
};

pub const X86IrqAllocator = struct {
    pub fn init(_: caps.Ref(@This())) void {}

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return Error.InvalidArgument;
    }

    pub fn call(_: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.X86IrqAllocatorCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (conf.LOG_OBJ_CALLS)
            log.debug("x86_irq_allocator call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .alloc => {
                const irq: u8 = @truncate(trap.arg2);
                try allocIrq(&irq_bitmap, irq);

                const cap_id = caps.pushCapability((caps.Ref(X86Irq){ .paddr = .fromInt(irq) }).object(thread));
                trap.arg1 = cap_id;
            },
            .clone => {
                const cap_id = caps.pushCapability((caps.Ref(X86IrqAllocator){ .paddr = .fromInt(0) }).object(thread));
                trap.arg1 = cap_id;
            },
        }
    }
};

pub const X86Irq = struct {
    pub fn init(_: caps.Ref(@This())) void {}

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return Error.InvalidArgument;
    }

    pub fn call(_irq: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.X86IrqCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (conf.LOG_OBJ_CALLS)
            log.debug("x86_irq call \"{s}\"", .{@tagName(call_id)});

        const irq: u8 = @truncate(_irq.raw);

        switch (call_id) {
            .subscribe => {
                const notify_obj = try caps.getCapability(thread, @truncate(trap.arg2));
                defer notify_obj.lock.unlock();

                const notify = try notify_obj.as(caps.Notify);

                const this_obj = caps.getCapabilityLocked(@truncate(trap.arg0));

                if (notify_obj.next != 0) return Error.NotifyAlreadySubscribed;
                if (this_obj.next != 0) return Error.IrqAlreadySubscribed;

                apic.registerExternalInterrupt(irq, notify.ptr()) orelse {
                    return Error.TooManyIrqs;
                };

                notify_obj.next = @truncate(trap.arg0);
                this_obj.next = @truncate(trap.arg2);
            },
            .unsubscribe => {
                return Error.Unimplemented;
            },
        }
    }
};

//

// 0=free 1=used
const port_bitmap_len = 0x300 / 8;
var port_bitmap: [port_bitmap_len]std.atomic.Value(u8) = b: {
    var bitmap: [port_bitmap_len]std.atomic.Value(u8) = .{std.atomic.Value(u8).init(0xFF)} ** port_bitmap_len;

    // https://wiki.osdev.org/I/O_Ports

    // the PIT
    for (0x0040..0x0048) |port|
        freePort(&bitmap, @truncate(port)) catch unreachable;
    // PS/2 controller
    for (0x0060..0x0065) |port|
        freePort(&bitmap, @truncate(port)) catch unreachable;
    // CMOS and RTC registers
    for (0x0070..0x0072) |port|
        freePort(&bitmap, @truncate(port)) catch unreachable;
    // second serial port
    for (0x02F8..0x0300) |port|
        freePort(&bitmap, @truncate(port)) catch unreachable;

    break :b bitmap;
};

const irq_bitmap_len = 0x100 / 8;
var irq_bitmap: [irq_bitmap_len]std.atomic.Value(u8) = b: {
    var bitmap: [irq_bitmap_len]std.atomic.Value(u8) = .{std.atomic.Value(u8).init(0xFF)} ** irq_bitmap_len;

    for (0..apic.IRQ_AVAIL_COUNT + 1) |i|
        freeIrq(&bitmap, @truncate(i)) catch unreachable;

    break :b bitmap;
};

fn allocPort(bitmap: *[port_bitmap_len]std.atomic.Value(u8), port: u16) Error!void {
    if (port >= 0x300)
        return Error.AlreadyMapped;
    const byte = &bitmap[port / 8];
    if (byte.bitSet(@truncate(port % 8), .acquire) == 1)
        return Error.AlreadyMapped;
}

fn freePort(bitmap: *[port_bitmap_len]std.atomic.Value(u8), port: u16) Error!void {
    if (port >= 0x300)
        return Error.NotMapped;
    const byte = &bitmap[port / 8];
    if (byte.bitReset(@truncate(port % 8), .release) == 0)
        return Error.NotMapped;
}

fn allocIrq(bitmap: *[irq_bitmap_len]std.atomic.Value(u8), irq: u8) Error!void {
    const byte = &bitmap[irq / 8];
    if (byte.bitSet(@truncate(irq % 8), .acquire) == 1)
        return Error.AlreadyMapped;
}

fn freeIrq(bitmap: *[irq_bitmap_len]std.atomic.Value(u8), irq: u8) Error!void {
    const byte = &bitmap[irq / 8];
    if (byte.bitReset(@truncate(irq % 8), .release) == 0)
        return Error.NotMapped;
}
