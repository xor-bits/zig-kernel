const std = @import("std");
const abi = @import("abi");
const limine = @import("limine");

const addr = @import("addr.zig");
const args = @import("args.zig");
const arch = @import("arch.zig");
const caps = @import("caps.zig");
const pmem = @import("pmem.zig");
const proc = @import("proc.zig");

const log = std.log.scoped(.init);
const Error = abi.sys.Error;

//

// pub export var memory: limine.MemoryMapRequest = .{};

/// load and exec the root process
pub fn exec(a: args.Args) !void {
    const vmem = try caps.Ref(caps.Vmem).alloc(null);

    (arch.Cr3{
        .pml4_phys_base = vmem.paddr.toParts().page,
    }).write();

    const boot_info = try map_root(vmem.ptr(), a);

    const init_thread = try caps.Ref(caps.Thread).alloc(null);
    init_thread.ptr().* = .{
        .trap = .{
            .user_instr_ptr = abi.ROOT_EXE,
        },
        .vmem = vmem,
    };

    const init_memory = try caps.Ref(caps.Memory).alloc(null);

    var id: u32 = undefined;
    id = caps.push_capability(vmem.object(init_thread.ptr()));
    std.debug.assert(id == abi.caps.ROOT_SELF_VMEM.cap);
    id = caps.push_capability(init_thread.object(init_thread.ptr()));
    std.debug.assert(id == abi.caps.ROOT_SELF_THREAD.cap);
    id = caps.push_capability(init_memory.object(init_thread.ptr()));
    std.debug.assert(id == abi.caps.ROOT_MEMORY.cap);
    id = caps.push_capability(boot_info.object(init_thread.ptr()));
    std.debug.assert(id == abi.caps.ROOT_BOOT_INFO.cap);

    try proc.start(init_thread);
}

fn map_root(vmem: *caps.Vmem, a: args.Args) !caps.Ref(caps.Frame) {
    const data_len = a.root_data.len + a.root_path.len + a.initfs_data.len + a.initfs_path.len;

    const low = addr.Virt.fromInt(abi.ROOT_EXE);
    const high = addr.Virt.fromInt(abi.ROOT_EXE + data_len);

    const boot_info = try caps.Ref(caps.Frame).alloc(abi.ChunkSize.of(@sizeOf(abi.BootInfo)));
    const boot_info_ptr: *volatile abi.BootInfo = @ptrCast(boot_info.ptr());

    boot_info_ptr.* = .{
        .root_data = @ptrFromInt(abi.ROOT_EXE),
        .root_data_len = a.root_data.len,
        .root_path = @ptrFromInt(abi.ROOT_EXE + a.root_data.len),
        .root_path_len = a.root_path.len,
        .initfs_data = @ptrFromInt(abi.ROOT_EXE + a.root_data.len + a.root_path.len),
        .initfs_data_len = a.initfs_data.len,
        .initfs_path = @ptrFromInt(abi.ROOT_EXE + a.root_data.len + a.root_path.len + a.initfs_data.len),
        .initfs_path_len = a.initfs_path.len,
    };

    log.info("root virtual memory size: 0x{x}", .{data_len});
    log.info("mapping root [ 0x{x:0>16}..0x{x:0>16} ]", .{
        @intFromPtr(boot_info_ptr.root_data),
        @intFromPtr(boot_info_ptr.root_data) + boot_info_ptr.root_data_len,
    });
    log.info("mapping initfs    [ 0x{x:0>16}..0x{x:0>16} ]", .{
        @intFromPtr(boot_info_ptr.initfs_data),
        @intFromPtr(boot_info_ptr.initfs_data) + boot_info_ptr.initfs_data_len,
    });
    log.info("root binary path: '{s}'", .{a.root_path});
    log.info("initfs path:           '{s}'", .{a.initfs_path});

    var current = low;
    while (current.raw < high.raw) : (current.raw += addr.Virt.fromParts(.{ .level1 = 1 }).raw) {
        // log.info("mapping level 1 entry", .{});

        try vmem.mapFrame(
            (try caps.Ref(caps.Frame).alloc(.@"4KiB")).paddr,
            current,
            .{
                .readable = true,
                .writable = true,
                .executable = true,
            },
            .{},
        );
    }

    arch.flush_tlb();

    log.info("copying root data", .{});
    std.mem.copyForwards(
        u8,
        @as([]u8, @ptrCast(boot_info_ptr.rootData())),
        a.root_data,
    );
    log.info("copying root path", .{});
    std.mem.copyForwards(
        u8,
        @as([]u8, @ptrCast(boot_info_ptr.rootPath())),
        a.root_path,
    );
    log.info("copying initfs data", .{});
    std.mem.copyForwards(
        u8,
        @as([]u8, @ptrCast(boot_info_ptr.initfsData())),
        a.initfs_data,
    );
    log.info("copying initfs path", .{});
    std.mem.copyForwards(
        u8,
        @as([]u8, @ptrCast(boot_info_ptr.initfsPath())),
        a.initfs_path,
    );

    log.info("root mapped and copied", .{});
    return boot_info;
}
