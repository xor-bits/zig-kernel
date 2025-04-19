const std = @import("std");
const abi = @import("abi");

const initfsd = @import("initfsd.zig");

const log = std.log.scoped(.bootstrap);
const Error = abi.sys.Error;

//

pub const std_options = abi.std_options;
pub const panic = abi.panic;

const heap_ptr: [*]u8 = @ptrFromInt(abi.BOOTSTRAP_HEAP);
pub var heap = std.heap.FixedBufferAllocator.init(heap_ptr[0..abi.BOOTSTRAP_HEAP_SIZE]);

//

pub fn main() !void {
    abi.sys.log("hello");

    try map_naive(0x1000_0000_0000, .{ .writable = true }, .{});
    log.info("mapped", .{});

    const s = @as(*volatile u64, @ptrFromInt(0x1000_0000_0000));
    s.* = 56;
    log.info("val={}", .{s.*});
}

fn map_naive(vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
    return map_naive_fn(abi.sys.map_frame, map_naive_lvl1, .frame, vaddr, rights, flags);
}

fn map_naive_lvl1(vaddr: usize, _: abi.sys.Rights, _: abi.sys.MapFlags) !void {
    return map_naive_fn(abi.sys.map_level1, map_naive_lvl2, .page_table_level_1, vaddr, .{
        .writable = true,
    }, .{});
}

fn map_naive_lvl2(vaddr: usize, _: abi.sys.Rights, _: abi.sys.MapFlags) !void {
    return map_naive_fn(abi.sys.map_level2, map_naive_lvl3, .page_table_level_2, vaddr, .{
        .writable = true,
    }, .{});
}

fn map_naive_lvl3(vaddr: usize, _: abi.sys.Rights, _: abi.sys.MapFlags) !void {
    return map_naive_fn(abi.sys.map_level3, map_naive_fail, .page_table_level_3, vaddr, .{
        .writable = true,
    }, .{});
}

fn map_naive_fail(_: usize, _: abi.sys.Rights, _: abi.sys.MapFlags) !void {
    return error.CannotMap;
}

fn map_naive_fn(comptime map_fn: anytype, comptime if_not_present: anytype, ty: abi.ObjectType, vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
    const obj = try abi.sys.alloc(abi.BOOTSTRAP_MEMORY, ty);
    const err = map_fn(obj, abi.BOOTSTRAP_SELF_VMEM, vaddr, .{
        .writable = true,
    }, .{});

    if (err != error.EntryNotPresent) return err;

    try if_not_present(vaddr, rights, flags);

    return map_fn(obj, abi.BOOTSTRAP_SELF_VMEM, vaddr, .{
        .writable = true,
    }, .{});
}

fn exec_elf(path: []const u8) !void {
    const elf_file = initfsd.openFile(path).?;
    const elf_bytes = initfsd.readFile(elf_file);
    var elf = std.io.fixedBufferStream(elf_bytes);

    var crc: u32 = 0;
    for (elf_bytes) |b| {
        crc = @addWithOverflow(crc, @as(u32, b))[0];
    }
    log.info("xor crc of `{s}` is {d}", .{ path, crc });

    var maps = std.ArrayList(abi.sys.Map).init(heap.allocator());

    const header = try std.elf.Header.read(&elf);
    var program_headers = header.program_header_iterator(&elf);

    try maps.append(abi.sys.Map{
        .dst = 0x7FFF_FFF0_0000,
        .src = abi.sys.MapSource.newLazy(64 * 0x1000),
        .flags = .{
            .write = true,
            .execute = false,
        },
    });

    try maps.append(abi.sys.Map{
        .dst = abi.BOOTSTRAP_HEAP,
        .src = abi.sys.MapSource.newLazy(abi.BOOTSTRAP_HEAP_SIZE),
        .flags = .{
            .write = true,
            .execute = false,
        },
    });

    while (try program_headers.next()) |program_header| {
        if (program_header.p_type != std.elf.PT_LOAD) {
            continue;
        }

        if (program_header.p_memsz == 0) {
            continue;
        }

        const bytes: []const u8 = elf.buffer[program_header.p_offset..][0..program_header.p_filesz];

        const flags = abi.sys.MapFlags{
            .write = program_header.p_flags & std.elf.PF_W != 0,
            .execute = program_header.p_flags & std.elf.PF_X != 0,
        };

        const segment_vaddr_bottom = std.mem.alignBackward(usize, program_header.p_vaddr, 0x1000);
        const segment_vaddr_top = std.mem.alignForward(usize, program_header.p_vaddr + program_header.p_memsz, 0x1000);
        const data_vaddr_bottom = program_header.p_vaddr;
        const data_vaddr_top = data_vaddr_bottom + program_header.p_filesz;
        const zero_vaddr_bottom = std.mem.alignForward(usize, data_vaddr_top, 0x1000);
        const zero_vaddr_top = segment_vaddr_top;

        try maps.append(abi.sys.Map{
            .dst = data_vaddr_bottom,
            .src = abi.sys.MapSource.newBytes(bytes),
            .flags = flags,
        });

        if (zero_vaddr_bottom != zero_vaddr_top) {
            try maps.append(abi.sys.Map{
                .dst = zero_vaddr_bottom,
                .src = abi.sys.MapSource.newLazy(zero_vaddr_top - segment_vaddr_bottom),
                .flags = flags,
            });
        }

        // log.info("flags: {any}, vaddrs: {any}", .{
        //     flags,
        //     .{
        //         segment_vaddr_bottom,
        //         segment_vaddr_top,
        //         data_vaddr_bottom,
        //         data_vaddr_top,
        //         zero_vaddr_bottom,
        //         zero_vaddr_top,
        //     },
        // });
    }

    abi.sys.system_map(1, maps.items);
    abi.sys.system_exec(1, header.entry, 0x7FFF_FFF4_0000);
}

pub export var initial_stack: [0x2000]u8 align(16) linksection(".stack") = @as([0x2000]u8, undefined);

pub export fn _start() linksection(".text._start") callconv(.Naked) noreturn {
    asm volatile (
        \\ movq %[sp], %%rsp
        \\ leaq 0x1, %%rax
        \\ jmp zig_main
        :
        : [sp] "rN" (&initial_stack),
    );
}

export fn zig_main() noreturn {
    // const empty = struct { start: usize }{
    //     .start = 10,
    // };
    // abi.sys.allocate(abi.sys.CapInitMemory, .{
    //     .ty = .page_table_level3,
    //     .dst = abi.sys.CapInitCaps,
    //     .offset = empty.start,
    //     .count = 1,
    // });
    // abi.sys.allocate(abi.sys.CapInitMemory, .{
    //     .ty = .page_table_level2,
    //     .dst = abi.sys.CapInitCaps,
    //     .offset = empty.start + 1,
    //     .count = 1,
    // });
    // abi.sys.allocate(abi.sys.CapInitMemory, .{
    //     .ty = .page_table_level1,
    //     .dst = abi.sys.CapInitCaps,
    //     .offset = empty.start + 2,
    //     .count = 1,
    // });
    // abi.sys.allocate(abi.sys.CapInitMemory, .{
    //     .ty = .frame,
    //     .dst = abi.sys.CapInitCaps,
    //     .offset = empty.start + 3,
    //     .count = 1,
    // });

    // abi.sys.map_level3(abi.sys.CapInitVmem, empty.start + 0, 0x7F8000000000);
    // abi.sys.map_level2(abi.sys.CapInitVmem, empty.start + 1, 0x7FFFC0000000);
    // abi.sys.map_level1(abi.sys.CapInitVmem, empty.start + 2, 0x7FFFFFE00000);
    // abi.sys.map_frame(abi.sys.CapInitVmem, empty.start + 3, 0x7FFFFFFFF000);

    main() catch |err| {
        std.debug.panic("{}", .{err});
    };
    while (true) {}
}

// pub export fn _start(initfs_ptr: [*]const u8, initfs_len: usize) linksection(".text._start") callconv(.C) noreturn {
//     main(initfs_ptr[0..initfs_len]) catch |err| {
//         std.debug.panic("{}", .{err});
//     };
//     while (true) {}
// }
