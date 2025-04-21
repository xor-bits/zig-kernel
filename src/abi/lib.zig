const std = @import("std");
const root = @import("root");

pub const sys = @import("sys.zig");
pub const ring = @import("ring.zig");
pub const rt = @import("rt.zig");
pub const btree = @import("btree.zig");

//

pub const BOOTSTRAP_EXE = 0x200_0000;

// some hardcoded capability handles

pub const BOOTSTRAP_SELF_VMEM: u32 = 1;
pub const BOOTSTRAP_SELF_THREAD: u32 = 2;
pub const BOOTSTRAP_MEMORY: u32 = 3;
pub const BOOTSTRAP_BOOT_INFO: u32 = 4;

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

pub const ObjectType = enum(u8) {
    null = 0,
    memory,
    thread,
    page_table_level_4,
    page_table_level_3,
    page_table_level_2,
    page_table_level_1,
    frame,
    receiver,
    sender,
};

pub const BootInfo = extern struct {
    bootstrap_data: [*]u8,
    bootstrap_data_len: usize,
    bootstrap_path: [*]u8,
    bootstrap_path_len: usize,
    initfs_data: [*]u8,
    initfs_data_len: usize,
    initfs_path: [*]u8,
    initfs_path_len: usize,

    pub fn bootstrapData(self: @This()) []u8 {
        return self.bootstrap_data[0..self.bootstrap_data_len];
    }

    pub fn bootstrapPath(self: @This()) []u8 {
        return self.bootstrap_path[0..self.bootstrap_path_len];
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
