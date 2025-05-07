const std = @import("std");
const builtin = @import("builtin");

const logs = @import("logs.zig");

const log = std.log.scoped(.spin);

//

pub const Once = struct {
    entry_mutex: Mutex = .new(),
    wait_mutex: Mutex = .newLocked(),

    const Self = @This();

    pub fn new() Self {
        return .{};
    }

    /// try init whatever resource
    /// false => some other CPU did it, call `wait`
    /// true  => this CPU is doing it, call `complete` once done
    pub fn tryRun(self: *Self) bool {
        return self.entry_mutex.tryLock();
    }

    pub fn wait(self: *Self) void {
        // some other cpu is already working on this,
        // wait for it to be complete and then return
        self.wait_mutex.lock();
        self.wait_mutex.unlock();
    }

    pub fn complete(self: *Self) void {
        // unlock wait_spin to signal others
        self.wait_mutex.unlock();
    }
};

pub const Mutex = struct {
    lock_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    const Self = @This();

    pub fn new() Self {
        return .{ .lock_state = std.atomic.Value(u8).init(0) };
    }

    pub fn newLocked() Self {
        return .{ .lock_state = std.atomic.Value(u8).init(1) };
    }

    pub fn lock(self: *Self) void {
        var counter = if (IS_DEBUG) @as(usize, 0) else void{};
        while (null != self.lock_state.cmpxchgWeak(0, 1, .acquire, .monotonic)) {
            while (self.isLocked()) {
                if (IS_DEBUG) {
                    counter += 1;
                    if (counter % 10_000 == 0) {
                        log.warn("possible deadlock {}", .{logs.Addr2Line{ .addr = @returnAddress() }});
                    }
                }
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn tryLock(self: *Self) bool {
        return null == self.lock_state.cmpxchgStrong(0, 1, .acquire, .monotonic);
    }

    pub fn isLocked(self: *Self) bool {
        return self.lock_state.load(.monotonic) == 1;
    }

    pub fn unlock(self: *Self) void {
        self.lock_state.store(0, .release);
    }
};

const IS_DEBUG = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
