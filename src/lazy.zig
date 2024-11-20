const std = @import("std");

//

pub fn fnPtrAsInit(comptime T: type, comptime f: fn () T) type {
    return struct {
        fn init() void {
            f();
        }
    };
}

pub fn Lazy(comptime T: type) type {
    return struct {
        val: T = undefined,
        initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        initializing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        const Self = @This();

        pub fn new() Self {
            return .{};
        }

        pub fn initNow(self: *Self, val: T) void {
            _ = self.getOrInit(struct {
                val: T,

                fn init(s: *const @This()) T {
                    return s.val;
                }
            }{
                .val = val,
            });
        }

        pub fn waitOrInit(self: *Self, init: anytype) *T {
            if (self.getOrInit(init)) |v| {
                return v;
            }

            @setCold(true);
            self.wait();
            return &self.val;
        }

        pub fn get(self: *Self) ?*T {
            if (!self.isInitialized()) {
                @setCold(true);
                return null;
            }

            return &self.val;
        }

        pub fn getOrInit(self: *Self, init: anytype) ?*T {
            if (!self.isInitialized()) {
                // very low chance to not be initialized (only the first time)
                @setCold(true);

                self.startInit() catch {
                    // super low chance to not be initialized and currently initializing
                    // (only when one thread accesses it for the first time and the current thread just a short time later)
                    @setCold(true);
                    return null;
                };

                self.val = init.init();

                self.finishInit();
            }

            return &self.val;
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
}
