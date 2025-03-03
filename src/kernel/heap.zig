// uses the global kernel address space for a SINGLE contiguous,
// growing allocation with a limit
//
// basically a lazy allocator for an array list

const std = @import("std");

//

pub const Heap = struct {
    bottom: usize,
    top: usize,

    pub fn allocator(self: *const @This()) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = {},
        };
    }
};

// const vtable = std.mem.Allocator.VTable{
//     .alloc = &_alloc,
//     .resize = &_resize,
//     .free = &_free,
// };
