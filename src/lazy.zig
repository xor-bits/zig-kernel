const std = @import("std");

//

pub const LazyInit = struct {
    initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    initializing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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

    /// does not wait but can fail
    pub fn getOrInit(self: *Self, init: *const fn () void) !void {
        if (!self.isInitialized()) {
            // very low chance to not be initialized (only the first time)
            @setCold(true);

            self.startInit() catch {
                @setCold(true);
                return error.NotInitialized;
            };

            init();

            self.finishInit();
        }
    }

    pub fn isInitialized(self: *Self) bool {
        return self.initialized.load(.acquire);
    }

    pub fn wait(self: *Self) void {
        while (!self.isInitialized()) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn startInit(self: *Self) !void {
        if (self.initializing.swap(true, .acquire)) {
            return error.AlreadyInitializing;
        }
    }

    pub fn finishInit(self: *Self) void {
        self.initialized.store(true, .release);
    }
};
