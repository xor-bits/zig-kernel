const std = @import("std");
const limine = @import("limine");

const addr = @import("addr.zig");

//

pub export var memory: limine.MemoryMapRequest = .{};

/// load and exec the bootstrap process
pub fn init() !void {
    const init_thread = try alloc(1);
    _ = init_thread;
}

pub fn alloc(pages: usize) !addr.Phys {
    const response = memory.response orelse return error.OutOfMemory;

    const bytes = pages * 0x1000;

    // find the pages from aligned entries first
    for (response.entries()) |entry| {
        // only usable entries are usable
        if (entry.kind != .usable) continue;
        // only aligned entries are usable
        if (!std.mem.isAligned(entry.base, 0x1000)) continue;
        // only entries larger than the requested amount are usable
        if (entry.length < bytes) continue;

        const paddr = addr.Phys{ .raw = @ptrFromInt(entry.base) };

        entry.base += bytes;
        entry.length -= bytes;

        return paddr;
    }

    // find the pages from non-aligned entries then
    for (response.entries()) |entry| {
        // only usable entries are usable
        if (entry.kind != .usable) continue;
        // only non-aligned entries are usable
        const base = std.mem.alignForward(usize, entry.base, 0x1000);
        if (base >= entry.base + entry.length) continue;
        const length = base + entry.length - entry.base;
        // only entries larger than the requested amount are usable
        if (length < bytes) continue;

        const paddr = addr.Phys{ .raw = @ptrFromInt(entry.base) };

        entry.base = base - bytes;
        entry.length = length - bytes;

        return paddr;
    }

    return error.OutOfMemory;
}
