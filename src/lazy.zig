const std = @import("std");

//

pub const LazyInit = struct {
    initialized: bool = false,
    initializing: bool = false,

    const Self = @This();

    pub fn new() Self {
        return .{};
    }

    pub fn isInitialized(self: *Self) bool {
        return @atomicLoad(bool, &self.initialized, std.builtin.AtomicOrder.acquire);
    }

    pub fn wait(self: *Self) void {
        while (!self.isInitialized()) {}
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
