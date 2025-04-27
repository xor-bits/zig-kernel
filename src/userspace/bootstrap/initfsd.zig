const std = @import("std");
const abi = @import("abi");

const main = @import("main.zig");

const log = std.log.scoped(.initfsd);

//

const vmm_vector = std.mem.Allocator{
    .ptr = &vmm_vector_top,
    .vtable = &.{
        .alloc = vmm_vector_alloc,
        .resize = vmm_vector_resize,
        .remap = vmm_vector_remap,
        .free = vmm_vector_free,
    },
};

var vmm_vector_top: usize = main.INITFS_TAR;

fn vmm_vector_alloc(_top: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const top: *usize = @alignCast(@ptrCast(_top));
    const ptr: [*]u8 = @ptrFromInt(top.*);
    vmm_vector_grow(top, std.math.divCeil(
        usize,
        len,
        0x10000,
    ) catch return null) catch return null;
    return ptr;
}

fn vmm_vector_resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}

fn vmm_vector_remap(_top: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    const top: *usize = @alignCast(@ptrCast(_top));
    vmm_vector_grow(top, std.math.divCeil(
        usize,
        new_len,
        0x10000,
    ) catch return null) catch return null;
    return memory.ptr;
}

fn vmm_vector_free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

fn vmm_vector_grow(top: *usize, n_pages: usize) !void {
    for (0..n_pages) |_| {
        try main.map_naive(
            try abi.sys.alloc(abi.BOOTSTRAP_MEMORY, .frame, .@"64KiB"),
            top.*,
            .{ .writable = true },
            .{},
        );
        top.* += 0x10000;
    }
}

var initfs_tar: std.ArrayList(u8) = .init(vmm_vector);

//

pub fn init(initfs: []const u8) !void {
    var initfs_tar_gz = std.io.fixedBufferStream(initfs);
    log.info("decompressing", .{});
    try std.compress.flate.inflate.decompress(.gzip, initfs_tar_gz.reader(), initfs_tar.writer());
    std.debug.assert(std.mem.eql(u8, initfs_tar.items[257..][0..8], "ustar\x20\x20\x00"));
}

pub fn run() noreturn {
    abi.sys.system_rename(0, "initfsd");

    const heap = 2;

    // io ring for sending requests elsewhere
    const io_ring = abi.IoRing.init(64, heap.allocator()) catch unreachable;
    defer io_ring.deinit();
    io_ring.setup() catch unreachable;

    // each request has 8 pages of room for copying the request buffer data over
    // all of them are lazy allocated, and lazy zeroed once handled
    const multi_buffer = heap.allocator().alloc(abi.sys.Page, 128 * 8) catch unreachable;
    defer heap.allocator().free(multi_buffer);

    // io ring for receiving protocol requests
    const proto_io_ring = abi.IoRing.init(128, heap.allocator()) catch unreachable;
    defer proto_io_ring.deinit();

    // initialize the initfs protocol and wait for it to be created
    abi.io.sync(abi.io.ProtoCreate.new(
        "initfs",
        &proto_io_ring,
        @as([*]u8, @ptrCast(multi_buffer.ptr))[0 .. multi_buffer.len * 0x1000],
    ), &io_ring) catch |err| {
        std.debug.panic("failed to create a protocol: {}", .{err});
    };

    while (true) {
        log.info("waiting for request", .{});
        const request = proto_io_ring.wait_submission();
        handle_request(&request, &proto_io_ring);
    }
}

fn handle_request(req: *const abi.sys.SubmissionEntry, proto_io_ring: *const abi.IoRing) void {
    // log.info("got request: {any}", .{req});

    const result = switch (req.opcode) {
        .open => handle_open(req),
        else => 0,
    };

    log.info("returning {any}", .{result});

    proto_io_ring.complete(.{
        .user_data = req.user_data,
        .result = abi.sys.encode(result),
    }) catch unreachable;

    defer {
        // mark the pages as lazy allocated again,
        // effectively zeroing out the memory and freeing the physical allocation
        const buffer_page_count = std.math.divCeil(usize, req.buffer_len, 0x1000) catch unreachable;
        const buffer_pages: []abi.sys.Page = @as([*]abi.sys.Page, @alignCast(@ptrCast(req.buffer)))[0..buffer_page_count];
        abi.sys.lazy_zero(buffer_pages);
    }
}

fn handle_open(req: *const abi.sys.SubmissionEntry) abi.sys.Error!usize {
    const path = req.buffer[0..req.buffer_len];
    log.info("got open: {s}", .{path});

    const file = openFile(path) orelse {
        return abi.sys.Error.NotFound;
    };
    return file; // returns the file index as the file descriptor number
}

pub fn openFile(path: []const u8) ?usize {
    const Block = [512]u8;
    const len = initfs_tar.items.len / 512;
    const blocks_ptr: [*]const Block = @ptrCast(initfs_tar.items.ptr);
    const blocks = blocks_ptr[0..len];

    var i: usize = 0;
    while (i < len) {
        const header_i = i;
        const header: *const TarEntryHeader = @ptrCast(&blocks[header_i]);
        const size = std.fmt.parseInt(usize, std.mem.sliceTo(header.size[0..12], 0), 8) catch 0;
        const size_blocks = if (size % 512 == 0) size / 512 else size / 512 + 1;

        i += 1; // skip the header
        if (i + size_blocks > len) {
            log.err("invalid tar file: unexpected EOF", .{});
            // broken tar file
            return null;
        }

        i += size_blocks; // skip the file data
        if (header.ty != 0 and header.ty != '0') {
            // skip non files
            continue;
        }

        if (!pathEql(path, std.mem.sliceTo(header.name[0..100], 0))) {
            continue;
        }

        return header_i;
    }

    return null;
}

pub fn readFile(header_i: usize) []const u8 {
    const Block = [512]u8;
    const len = initfs_tar.items.len / 512;
    const blocks_ptr: [*]const Block = @ptrCast(initfs_tar.items.ptr);
    const blocks = blocks_ptr[0..len];

    const header: *const TarEntryHeader = @ptrCast(&blocks[header_i]);
    const size = std.fmt.parseInt(usize, std.mem.sliceTo(header.size[0..12], 0), 8) catch 0;
    const size_blocks = if (size % 512 == 0) size / 512 else size / 512 + 1;

    const bytes_blocks = blocks[header_i + 1 .. header_i + size_blocks + 1];
    const first_byte: [*]const u8 = @ptrCast(bytes_blocks);
    const bytes = first_byte[0..size];

    return bytes;
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
