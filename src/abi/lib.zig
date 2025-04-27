const std = @import("std");
const root = @import("root");

pub const btree = @import("btree.zig");
pub const caps = @import("caps.zig");
pub const ring = @import("ring.zig");
pub const rt = @import("rt.zig");
pub const sys = @import("sys.zig");

//

/// where the kernel places the root binary
pub const ROOT_EXE = 0x200_0000;

//

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

fn logFn(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    var bw = std.io.bufferedWriter(SysLog{});
    const writer = bw.writer();

    // FIXME: lock the log
    nosuspend {
        writer.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        bw.flush() catch return;
    }
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;

    if (ret_addr) |at| {
        std.log.scoped(.panic).err("panicked at 0x{x}:\n{s}", .{ at, msg });
    } else {
        std.log.scoped(.panic).err("panicked:\n{s}", .{msg});
    }

    while (true) {}
}

//

/// kernel object variant that a capability points to
pub const ObjectType = enum(u8) {
    /// an unallocated/invalid capability
    null = 0,
    /// capability that allows kernel object allocation
    memory,
    /// capability to manage a single thread control block (TCB)
    thread,
    /// capability to the virtual memory structure
    vmem,
    /// capability to a physical memory region (sized `ChunkSize`)
    frame,
    /// capability to **the** receiver end of an endpoint,
    /// there can only be a single receiver
    receiver,
    /// capability to **a** sender end of an endpoint,
    /// there can be multiple senders
    sender,
};

/// kernel object size in bit-width (minus 12)
pub const ChunkSize = enum(u5) {
    @"4KiB",
    @"8KiB",
    @"16KiB",
    @"32KiB",
    @"64KiB",
    @"128KiB",
    @"256KiB",
    @"512KiB",
    @"1MiB",
    @"2MiB",
    @"4MiB",
    @"8MiB",
    @"16MiB",
    @"32MiB",
    @"64MiB",
    @"128MiB",
    @"256MiB",
    @"512MiB",
    @"1GiB",

    pub fn of(n_bytes: usize) ?ChunkSize {
        // 0 = 4KiB, 1 = 8KiB, ..
        const page_size = @max(12, std.math.log2_int_ceil(usize, n_bytes)) - 12;
        if (page_size >= 18) return null;
        return @enumFromInt(page_size);
    }

    pub fn next(self: @This()) ?@This() {
        return std.meta.intToEnum(@This(), @intFromEnum(self) + 1) catch return null;
    }

    pub fn sizeBytes(self: @This()) usize {
        return @as(usize, 0x1000) << @intFromEnum(self);
    }
};

/// data structure in the boot info frame provided to the root process
pub const BootInfo = extern struct {
    root_data: [*]u8,
    root_data_len: usize,
    root_path: [*]u8,
    root_path_len: usize,
    initfs_data: [*]u8,
    initfs_data_len: usize,
    initfs_path: [*]u8,
    initfs_path_len: usize,

    pub fn rootData(self: @This()) []u8 {
        return self.root_data[0..self.root_data_len];
    }

    pub fn rootPath(self: @This()) []u8 {
        return self.root_path[0..self.root_path_len];
    }

    pub fn initfsData(self: @This()) []u8 {
        return self.initfs_data[0..self.initfs_data_len];
    }

    pub fn initfsPath(self: @This()) []u8 {
        return self.initfs_path[0..self.initfs_path_len];
    }
};

//

pub const SysLog = struct {
    pub const Error = error{};
    pub fn write(self: @This(), bytes: []const u8) Error!usize {
        try self.writeAll(bytes);
        return bytes.len;
    }
    pub fn writeAll(_: @This(), bytes: []const u8) Error!void {
        sys.log(bytes);
    }
    pub fn flush(_: @This()) Error!void {}
};
