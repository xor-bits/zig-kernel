const std = @import("std");
const builtin = @import("builtin");
const kernel = @import("kernel");

//

pub const std_options = kernel.std_options;
pub const panic = kernel.panic;

const log = std.log.scoped(.@"test");

//

pub fn runTests() !void {
    // help the LSP
    const test_fns: []const std.builtin.TestFn = builtin.test_functions;

    for (test_fns) |test_fn| {
        if (!isBeforeAll(test_fn)) continue;

        log.info("running test '{s}'", .{test_fn.name});
        test_fn.func() catch |err| {
            log.err("test '{s}' failed: {}", .{ test_fn.name, err });
        };
    }

    for (test_fns) |test_fn| {
        if (isBeforeAll(test_fn) or isAfterAll(test_fn)) continue;

        log.info("running test '{s}'", .{test_fn.name});
        test_fn.func() catch |err| {
            log.err("test '{s}' failed: {}", .{ test_fn.name, err });
        };
    }

    for (test_fns) |test_fn| {
        if (!isAfterAll(test_fn)) continue;

        log.info("running test '{s}'", .{test_fn.name});
        test_fn.func() catch |err| {
            log.err("test '{s}' failed: {}", .{ test_fn.name, err });
        };
    }
}

fn isBeforeAll(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isAfterAll(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}
