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
    var initfs_tar_gz = std.io.fixedBufferStream(initfs);
    try std.compress.flate.inflate.decompress(.gzip, initfs_tar_gz.reader(), initfs_tar.writer());
    std.debug.assert(std.mem.eql(u8, initfs_tar.items[257..][0..8], "ustar\x20\x20\x00"));

    const init = openFile("/sbin/init").?;
    log.info("{any}", .{init.len});
    // _ = init;
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
