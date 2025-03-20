const std = @import("std");

const arch = @import("arch.zig");

//

/// forms a tree of capabilities
pub const Capabilities = struct {
    // N capabilities based on how many can fit in a page
    caps: [0x1000 / @sizeOf(Object)]Object,
};

pub const BootInfo = struct {};

/// raw physical memory that can be used to allocate
/// things like more `CapabilityNode`s or things
pub const Memory = struct {};

/// thread information
pub const Thread = struct {
    trap: arch.SyscallRegs,
    caps: Capability(Capabilities),
    vmem: Capability(PageTableLevel4),
    priority: u2,
};

/// a `Thread` points to this
pub const PageTableLevel4 = struct {};
/// a `PageTableLevel4` points to multiple of these
pub const PageTableLevel3 = struct {};
/// a `PageTableLevel3` points to multiple of these
pub const PageTableLevel2 = struct {};
/// a `PageTableLevel2` points to multiple of these
pub const PageTableLevel1 = struct {};
/// a `PageTableLevel1` points to multiple of these
///
/// raw physical memory again, but now mappable
/// (and can't be used to allocate things)
pub const Frame = struct {};

pub fn Capability(comptime T: type) type {
    return struct {
        paddr: usize,

        pub fn ptr(self: @This()) *T {
            // recursive mapping instead of HHDM later (maybe)
            self.paddr;
        }
    };
}

pub const Object = struct {
    paddr: usize,
    type: enum {
        capabilities,
        boot_info,
        memory,
        thread,
        page_table_level_4,
        page_table_level_3,
        page_table_level_2,
        page_table_level_1,
        frame,
    },
};

pub fn debug_type(comptime T: type) void {
    std.log.info("{s}: size={} align={}", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
}
