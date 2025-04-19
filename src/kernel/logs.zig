const std = @import("std");

const arch = @import("arch.zig");
const main = @import("main.zig");
const uart = @import("uart.zig");
const spin = @import("spin.zig");

//

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

fn logFn(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const level_txt = comptime message_level.asText();
    const scope_txt = if (scope == .default) "" else " " ++ @tagName(scope);
    const level_col = comptime switch (message_level) {
        .debug => "\x1B[96m",
        .info => "\x1B[92m",
        .warn => "\x1B[93m",
        .err => "\x1B[91m",
    };
    const fmt = "\x1B[90m[ " ++ level_col ++ level_txt ++ "\x1B[90m" ++ scope_txt ++ " ]: \x1B[0m" ++ format ++ "\n";

    log_lock.lock();
    defer log_lock.unlock();

    uart.print(fmt, args);
}
var log_lock: spin.Mutex = .{};

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    const log = std.log.scoped(.panic);

    if (ret_addr) |at| {
        log.err("CPU panicked at 0x{x}:\n{s}", .{ at, msg });
    } else {
        log.err("CPU panicked:\n{s}", .{msg});
    }

    arch.hcf();
}
