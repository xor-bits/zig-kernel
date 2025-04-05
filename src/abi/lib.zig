const std = @import("std");
const root = @import("root");

pub const sys = @import("sys.zig");
pub const ring = @import("ring.zig");
pub const io = @import("io.zig");
pub const rt = @import("rt.zig");
pub const btree = @import("btree.zig");

//

pub const BOOTSTRAP_EXE = 0x200_0000;

pub const BOOTSTRAP_HEAP = 0x1000_0000;
pub const BOOTSTRAP_HEAP_SIZE = 0x1000_0000;
pub const BOOTSTRAP_STACK = 0x3000_0000;
pub const BOOTSTRAP_STACK_SIZE = 64 * 0x1000;
pub const BOOTSTRAP_INITFS = 0x5000_0000;

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

//

pub const IoRing = struct {
    inner: *Inner,
    alloc: std.mem.Allocator,

    const Inner = struct {
        submissions: sys.SubmissionQueue,
        completions: sys.CompletionQueue,
        futex: std.atomic.Value(usize),
    };

    const Self = @This();

    pub fn init(entries: usize, alloc: std.mem.Allocator) !Self {
        const self = Self{
            .inner = try alloc.create(Inner),
            .alloc = alloc,
        };
        errdefer alloc.destroy(self.inner);

        const submissions = try alloc.alloc(sys.SubmissionEntry, entries);
        errdefer alloc.free(submissions);
        const completions = try alloc.alloc(sys.CompletionEntry, entries * 2);
        errdefer alloc.free(completions);

        self.inner.submissions = sys.SubmissionQueue.init(submissions.ptr, submissions.len);
        self.inner.completions = sys.CompletionQueue.init(completions.ptr, completions.len);
        self.inner.futex = .{ .raw = 0 };

        return self;
    }

    /// tell the kernel to start listening for submissions
    pub fn setup(self: *const Self) !void {
        try sys.ringSetup(
            &self.inner.submissions,
            &self.inner.completions,
            &self.inner.futex,
        );
    }

    pub fn deinit(self: *const Self) void {
        // FIXME: ringDelete syscall
        std.debug.panic("FIXME missing syscall", .{});

        self.alloc.free(self.inner.submissions);
        self.alloc.free(self.inner.completions);
        self.alloc.destroy(self.inner);
    }

    pub fn submit(self: *const Self, entry: sys.SubmissionEntry) error{Full}!void {
        try push(sys.SubmissionEntry, &self.inner.submissions, entry);
    }

    pub fn next_completion(self: *const Self) ?sys.CompletionEntry {
        return next(sys.CompletionEntry, &self.inner.completions);
    }

    pub fn spin_completion(self: *const Self) sys.CompletionEntry {
        return spin(sys.CompletionEntry, &self.inner.completions);
    }

    pub fn wait_completion(self: *const Self) sys.CompletionEntry {
        return wait(sys.CompletionEntry, &self.inner.completions, &self.inner.futex);
    }

    pub fn complete(self: *const Self, entry: sys.CompletionEntry) error{Full}!void {
        try push(sys.CompletionEntry, &self.inner.completions, entry);
    }

    pub fn next_submission(self: *const Self) ?sys.SubmissionEntry {
        return next(sys.SubmissionEntry, &self.inner.submissions);
    }

    pub fn spin_submission(self: *const Self) sys.SubmissionEntry {
        return spin(sys.SubmissionEntry, &self.inner.submissions);
    }

    pub fn wait_submission(self: *const Self) sys.SubmissionEntry {
        return wait(sys.SubmissionEntry, &self.inner.submissions, &self.inner.futex);
    }
};

fn push(
    comptime T: type,
    queue: *ring.AtomicRing(T, [*]T),
    entry: T,
) error{Full}!void {
    try queue.push(entry);
}

fn next(
    comptime T: type,
    queue: *ring.AtomicRing(T, [*]T),
    // futex: *std.atomic.Value(usize),
) ?T {
    return queue.pop();
}

fn spin(
    comptime T: type,
    queue: *ring.AtomicRing(T, [*]T),
    // futex: *std.atomic.Value(usize),
) T {
    while (true) {
        if (next(T, queue)) |_next| {
            return _next;
        }

        yield_cold();
    }
}

fn yield_cold() void {
    @branchHint(.cold);
    sys.yield();
}

fn wait(
    comptime T: type,
    queue: *ring.AtomicRing(T, [*]T),
    futex: *std.atomic.Value(usize),
) T {
    while (true) {
        const now = futex.load(.acquire);
        if (next(T, queue)) |_next| {
            return _next;
        }

        futex_wait_cold(&futex.raw, now);
    }
}

fn futex_wait_cold(value: *const usize, expected: usize) void {
    @branchHint(.cold);
    sys.futex_wait(value, expected);
}
