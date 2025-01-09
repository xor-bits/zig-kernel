const std = @import("std");
const abi = @import("abi");

const initfsd = @import("initfsd.zig");

const log = std.log.scoped(.bootstrap);

//

pub const std_options = abi.std_options;
pub const panic = abi.panic;

const heap_ptr: [*]u8 = @ptrFromInt(abi.BOOTSTRAP_HEAP);
pub var heap = std.heap.FixedBufferAllocator.init(heap_ptr[0..abi.BOOTSTRAP_HEAP_SIZE]);

//

fn main(initfs: []const u8) !void {
    log.info("hello from bootstrap {}", .{@sizeOf(abi.sys.SubmissionEntry)});

    try initfsd.init(initfs);

    try exec_elf("/sbin/init");

    initfsd.run();
}

fn exec_elf(path: []const u8) !void {
    var elf = std.io.fixedBufferStream(initfsd.openFile(path).?);

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

export fn _start(initfs_ptr: [*]const u8, initfs_len: usize) linksection(".text._start") callconv(.C) noreturn {
    main(initfs_ptr[0..initfs_len]) catch |err| {
        std.debug.panic("{}", .{err});
    };
    while (true) {}
}
