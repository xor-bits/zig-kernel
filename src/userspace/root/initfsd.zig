const std = @import("std");
const abi = @import("abi");

const main = @import("main.zig");

const log = std.log.scoped(.initfsd);
const caps = abi.caps;

//

const vmm_vector = std.mem.Allocator{
    .ptr = &vmm_vector_top,
    .vtable = &.{
        .alloc = vmmVectorAlloc,
        .resize = vmmVectorResize,
        .remap = vmmVectorRemap,
        .free = vmmVectorFree,
    },
};

var vmm_vector_top: usize = main.INITFS_TAR;

fn vmmVectorAlloc(_top: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const top: *usize = @alignCast(@ptrCast(_top));
    const ptr: [*]u8 = @ptrFromInt(top.*);
    vmmVectorGrow(top, std.math.divCeil(
        usize,
        len,
        0x10000,
    ) catch return null) catch return null;
    return ptr;
}

fn vmmVectorResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}

fn vmmVectorRemap(_top: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    const top: *usize = @alignCast(@ptrCast(_top));
    const current_len = top.* - main.INITFS_TAR;
    if (current_len < new_len) {
        vmmVectorGrow(top, std.math.divCeil(
            usize,
            new_len - current_len,
            0x10000,
        ) catch return null) catch return null;
    }

    return memory.ptr;
}

fn vmmVectorFree(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

fn vmmVectorGrow(top: *usize, n_pages: usize) !void {
    for (0..n_pages) |_| {
        const frame = try abi.caps.ROOT_MEMORY.allocSized(abi.caps.Frame, .@"64KiB");
        try abi.caps.ROOT_SELF_VMEM.map(
            frame,
            top.*,
            .{ .writable = true },
            .{},
        );
        top.* += 0x10000;
    }
}

var initfs_tar: std.ArrayList(u8) = .init(vmm_vector);

//

pub fn init() !void {
    const _boot_info: *const volatile abi.BootInfo = @ptrFromInt(main.BOOT_INFO);
    const boot_info = _boot_info.*;
    const initfs: []const u8 = boot_info.initfsData();

    log.info("starting initfs thread", .{});
    initfs_tar_gz = std.io.fixedBufferStream(initfs);

    initfs_ready = try caps.ROOT_MEMORY.alloc(caps.Notify);

    const stack = try caps.ROOT_MEMORY.allocSized(caps.Frame, .@"256KiB");
    try caps.ROOT_SELF_VMEM.map(stack, main.INITFS_STACK_BOTTOM, .{ .writable = true }, .{});

    thread = try caps.ROOT_MEMORY.alloc(caps.Thread);
    try thread.setPrio(0);
    try thread.setVmem(caps.ROOT_SELF_VMEM);
    try thread.writeRegs(&.{
        .user_stack_ptr = main.INITFS_STACK_TOP - 0x10, // fixing a bug in Zig where @returnAddress() in noreturn underflows the stack
        .user_instr_ptr = @intFromPtr(&run),
    });
    try thread.start();
}

pub fn wait() !void {
    _ = try initfs_ready.wait();
}

var thread: caps.Thread = undefined;
var initfs_tar_gz: std.io.FixedBufferStream([]const u8) = undefined;
var initfs_ready: caps.Notify = .{};

fn run() callconv(.SysV) noreturn {
    log.info("decompressing", .{});
    std.compress.flate.inflate.decompress(.gzip, initfs_tar_gz.reader(), initfs_tar.writer()) catch |err| {
        log.err("failed to decompress initfs: {}", .{err});
        thread.stop() catch {};
        unreachable;
    };
    std.debug.assert(std.mem.eql(u8, initfs_tar.items[257..][0..8], "ustar\x20\x20\x00"));
    log.info("decompressed initfs size: 0x{x}", .{initfs_tar.items.len});

    _ = initfs_ready.notify() catch |err| {
        log.err("failed to notify that initfs is ready: {}", .{err});
        thread.stop() catch {};
        unreachable;
    };

    thread.stop() catch {};
    unreachable;
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
