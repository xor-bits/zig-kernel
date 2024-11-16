const std = @import("std");

//

pub const LazyInit = struct {
    initialized: bool = false,
    initializing: bool = false,

    const Self = @This();

    pub fn new() Self {
        return .{};
    }

    pub fn waitOrInit(self: *Self, init: *const fn () void) void {
        if (!self.isInitialized()) {
            // very low chance to not be initialized (only the first time)
            @setCold(true);

            self.startInit() catch {
                // super low chance to not be initialized and currently initializing
                // (only when one thread accesses it for the first time and the current thread just a short time later)
                @setCold(true);
                self.wait();
                return;
            };

            init();

            self.finishInit();
        }
    }

    pub fn isInitialized(self: *Self) bool {
        return @atomicLoad(bool, &self.initialized, std.builtin.AtomicOrder.acquire);
    }

    pub fn wait(self: *Self) void {
        while (!self.isInitialized()) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn startInit(self: *Self) !void {
        if (@atomicRmw(bool, &self.initializing, std.builtin.AtomicRmwOp.Xchg, true, .acquire)) {
            return error.AlreadyInitializing;
        }
    }

    pub fn finishInit(self: *Self) void {
        @atomicStore(bool, &self.initialized, true, .release);
    }
};
