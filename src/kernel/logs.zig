const std = @import("std");

const arch = @import("arch.zig");
const main = @import("main.zig");
const uart = @import("uart.zig");
const proc = @import("proc.zig");
const spin = @import("spin.zig");
const fb = @import("fb.zig");

//

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

fn logFn(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const level_txt = comptime message_level.asText();
    const scope_txt = if (scope == .default) "" else " " ++ @tagName(scope);
    const fmt = "[ " ++ level_txt ++ scope_txt ++ " {} ]: ";

    var pid: usize = 0;
    if (main.all_cpus_ininitalized.load(.acquire)) {
        if (arch.cpu_local().current_pid) |_pid| {
            pid = _pid;
        }
    }

    log_lock.lock();
    defer log_lock.unlock();

    uart.print(fmt, .{pid});
    uart.print(format ++ "\n", args);
    if (scope != .critical) {
        fb.print(fmt, .{pid});
        fb.print(format ++ "\n", args);
    }
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
