const std = @import("std");
const abi = @import("abi");

const log = std.log.scoped(.bootstrap);

//

pub const std_options = abi.std_options;
pub const panic = abi.panic;

const heap_ptr: [*]u8 = @ptrFromInt(abi.BOOTSTRAP_HEAP);
var heap = std.heap.FixedBufferAllocator.init(heap_ptr[0..abi.BOOTSTRAP_HEAP_SIZE]);

var initfs_tar = std.ArrayList(u8).init(heap.allocator());

//

fn main(initfs: []const u8) !void {
    log.info("hello from bootstrap {}", .{@sizeOf(abi.sys.SubmissionEntry)});

    var initfs_tar_gz = std.io.fixedBufferStream(initfs);
    try std.compress.flate.inflate.decompress(.gzip, initfs_tar_gz.reader(), initfs_tar.writer());
    std.debug.assert(std.mem.eql(u8, initfs_tar.items[257..][0..8], "ustar\x20\x20\x00"));

    var init = std.io.fixedBufferStream(openFile("/sbin/init").?);

    var maps = std.ArrayList(abi.sys.Map).init(heap.allocator());

    const header = try std.elf.Header.read(&init);
    var program_headers = header.program_header_iterator(&init);

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

        const bytes: []const u8 = init.buffer[program_header.p_offset..][0..program_header.p_filesz];

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

    initfsd();
}

var buf: [0x1000]u8 align(0x1000) = undefined;

fn initfsd() noreturn {
    const io_ring = abi.IoRing.init(64, heap.allocator()) catch unreachable;
    defer io_ring.deinit();

    const proto = abi.sys.vfs_proto_create("initfs") catch |err| {
        std.debug.panic("failed to create VFS proto: {}", .{err});
    };
    log.info("vfs proto handle: {!}", .{proto});

    io_ring.submit(.{
        .user_data = 0,
        .opcode = .vfs_proto_next_open,
        .flags = 0,
        .fd = @truncate(@as(i128, proto)),
        .buffer = &buf,
        .buffer_len = 0x1000,
        .offset = 0,
    }) catch unreachable;

    const result = io_ring.wait();
    log.info("result={any}", .{abi.sys.decode(result.result)});
    const path_len = result.result;

    const path = buf[0..path_len];
    log.info("got initfs open request: {s}", .{path});

    while (true) {
        abi.sys.yield();
    }
}

fn t(a: []const u8, b: []const u8) void {
    log.info("{s} == {s} => {}", .{ a, b, pathEql(a, b) });
}

fn openFile(path: []const u8) ?[]const u8 {
    const Block = [512]u8;
    const len = initfs_tar.items.len / 512;
    const blocks_ptr: [*]const Block = @ptrCast(initfs_tar.items.ptr);
    const blocks = blocks_ptr[0..len];

    var i: usize = 0;
    while (i < len) {
        const header: *const TarEntryHeader = @ptrCast(&blocks[i]);
        const size = std.fmt.parseInt(usize, std.mem.sliceTo(header.size[0..12], 0), 8) catch 0;
        const size_blocks = if (size % 512 == 0) size / 512 else size / 512 + 1;

        i += 1; // skip the header
        if (i + size_blocks > len) {
            log.err("invalid tar file: unexpected EOF", .{});
            // broken tar file
            return null;
        }

        const bytes_blocks = blocks[i .. i + size_blocks];
        const first_byte: [*]const u8 = @ptrCast(bytes_blocks);
        const bytes = first_byte[0..size];
        i += size_blocks; // skip the file data

        if (header.ty != 0 and header.ty != '0') {
            // skip non files
            continue;
        }

        // const this_path = header.name[0..100];
        // var path_iter = std.mem.splitBackwardsScalar(u8, path, '/');
        // const file = path_iter.next() orelse continue;
        // const path = path_iter.rest();
        // if (file.len == 0) {
        //     // skip non files AGAIN, because tar
        //     continue;
        // }

        if (!pathEql(path, std.mem.sliceTo(header.name[0..100], 0))) {
            continue;
        }

        return bytes;

        // const blocks = if (size % 512 == 0) size / 512 else size / 512 + 1;

        // var file = try std.ArrayList(u8).initCapacity(heap.allocator(), blocks * 512);
        // for (0..blocks) |_| {
        //     const block = block_iter.next() orelse return error.TarUnexpectedEof;
        //     if (block.len == 512) {
        //         file.appendSliceAssumeCapacity(block);
        //     }
        // }
        // file.shrinkRetainingCapacity(size);

        // log.info("{s}", .{file.items});
    }

    return null;
}

fn pathEql(a: []const u8, b: []const u8) bool {
    var a_iter = std.mem.splitScalar(u8, a, '/');
    var b_iter = std.mem.splitScalar(u8, b, '/');

    var correct_so_far = false;

    while (a_iter.next()) |a_part| {
        if (pathPartIsNothing(a_part)) {
            continue;
        }

        while (b_iter.next()) |b_part| {
            if (pathPartIsNothing(b_part)) {
                continue;
            }

            if (!std.mem.eql(u8, a_part, b_part)) {
                return false;
            }

            correct_so_far = true;
            break;
        }
    }

    return correct_so_far;
}

fn pathPartIsNothing(s: []const u8) bool {
    return s.len == 0 or (s.len == 1 and s[0] == '.');
}

export fn _start(initfs_ptr: [*]const u8, initfs_len: usize) linksection(".text._start") callconv(.C) noreturn {
    main(initfs_ptr[0..initfs_len]) catch |err| {
        std.debug.panic("{}", .{err});
    };
    while (true) {}
}

const TarEntryHeader = extern struct {
    name: [100]u8 align(1),
    mode: u64 align(1),
    uid: u64 align(1),
    gid: u64 align(1),
    size: [12]u8 align(1),
    modified: [12]u8 align(1),
    checksum: u64 align(1),
    ty: u8 align(1),
    link: [100]u8 align(1),
};
