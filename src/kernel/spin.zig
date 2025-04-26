const std = @import("std");

//

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
        while (null != self.lock_state.cmpxchgWeak(0, 1, .acquire, .monotonic)) {
            while (self.isLocked()) {
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
