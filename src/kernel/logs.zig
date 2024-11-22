const std = @import("std");

const arch = @import("arch.zig");
const uart = @import("uart.zig");
const fb = @import("fb.zig");

//

pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn logFn(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const level_txt = comptime message_level.asText();
    const scope_txt = if (scope == .default) "" else " " ++ @tagName(scope);
    const fmt = "[ " ++ level_txt ++ scope_txt ++ " ]: " ++ format ++ "\n";

    uart.print(fmt, args);
    if (scope != .critical) {
        fb.print(fmt, args);
    }
}

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
