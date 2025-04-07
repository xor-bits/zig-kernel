const std = @import("std");
const abi = @import("abi");
const limine = @import("limine");

const arch = @import("arch.zig");
const pmem = @import("pmem.zig");
const addr = @import("addr.zig");
const caps = @import("caps.zig");

const log = std.log.scoped(.init);

//

// pub export var memory: limine.MemoryMapRequest = .{};

/// load and exec the bootstrap process
pub fn exec() !noreturn {
    const _vmem = try caps.Ref(caps.PageTableLevel4).alloc();
    const vmem_lvl4 = _vmem.ptr();
    vmem_lvl4.init();

    (arch.Cr3{
        .pml4_phys_base = _vmem.paddr.toParts().page,
    }).write();
    try map_bootstrap(vmem_lvl4);

    // const boot_info = try caps.Ref(caps.BootInfo).alloc();

    const init_thread = try caps.Ref(caps.Thread).alloc();
    init_thread.ptr().* = .{
        .trap = .{
            .user_instr_ptr = abi.BOOTSTRAP_EXE,
        },
        .vmem = _vmem,
    };

    _ = caps.push_capability(_vmem.object());
    _ = caps.push_capability(init_thread.object());

    log.info("kernel init done, entering user-space", .{});

    arch.cpu_local().current_thread = init_thread.ptr();
    arch.sysret(&init_thread.ptr().trap);
}

fn map_bootstrap(vmem_lvl4: *caps.PageTableLevel4) !void {
    const bootstrap_binary: []const u8 = @embedFile("bootstrap");

    const low = addr.Virt.fromInt(abi.BOOTSTRAP_EXE);
    const high = addr.Virt.fromInt(abi.BOOTSTRAP_EXE + bootstrap_binary.len);

    log.info("bootstrap binary size: 0x{x}", .{bootstrap_binary.len});
    log.info("mapping user-space [ 0x{x:0>16}..0x{x:0>16} ]", .{ low.raw, high.raw });

    var current = low;
    while (current.raw < high.raw) : (current.raw += addr.Virt.fromParts(.{ .level4 = 1 }).raw) {
        // log.info("mapping level 4 entry", .{});

        try vmem_lvl4.map_level3(
            try alloc(1),
            current,
            .{
                .readable = true,
                .writable = true,
                .executable = true,
            },
            .{},
        );
    }

    current = low;
    while (current.raw < high.raw) : (current.raw += addr.Virt.fromParts(.{ .level3 = 1 }).raw) {
        // log.info("mapping level 3 entry", .{});

        try vmem_lvl4.map_level2(
            try alloc(1),
            current,
            .{
                .readable = true,
                .writable = true,
                .executable = true,
            },
            .{},
        );
    }

    current = low;
    while (current.raw < high.raw) : (current.raw += addr.Virt.fromParts(.{ .level2 = 1 }).raw) {
        // log.info("mapping level 2 entry", .{});

        try vmem_lvl4.map_level1(
            try alloc(1),
            current,
            .{
                .readable = true,
                .writable = true,
                .executable = true,
            },
            .{},
        );
    }

    current = low;
    while (current.raw < high.raw) : (current.raw += addr.Virt.fromParts(.{ .level1 = 1 }).raw) {
        // log.info("mapping level 1 entry", .{});

        try vmem_lvl4.map_frame(
            try alloc(1),
            current,
            .{
                .readable = true,
                .writable = true,
                .executable = true,
            },
            .{},
        );
    }

    log.info("copying bootstrap", .{});
    const bootstrap_addr = @as([*]u8, @ptrFromInt(abi.BOOTSTRAP_EXE))[0..bootstrap_binary.len];
    std.mem.copyForwards(u8, bootstrap_addr, bootstrap_binary);
}

pub fn alloc(pages: usize) !addr.Phys {
    if (comptime false) {
        const memory = undefined;
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

            const paddr = addr.Phys.fromInt(entry.base);

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

            const paddr = addr.Phys.fromInt(entry.base);

            entry.base = base - bytes;
            entry.length = length - bytes;

            return paddr;
        }

        return error.OutOfMemory;
    } else {
        return addr.Virt.fromPtr(pmem.alloc() orelse return error.OutOfMemory).hhdmToPhys();
    }
}
