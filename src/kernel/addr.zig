pub const Phys = struct {
    raw: *u8,

    pub fn fromInt(i: usize) Phys {
        return Phys{
            .raw = @ptrFromInt(i),
        };
    }

    pub fn toHhdm(self: Phys) Virt {
        return Virt{
            .raw = @ptrFromInt(@intFromPtr(self.raw) + 0xffff800000000000),
        };
    }
};

pub const Virt = struct {
    raw: *u8,

    pub fn fromPtr(ptr: anytype) Virt {
        return Virt{
            .raw = @ptrCast(ptr),
        };
    }

    pub fn toPtr(self: Virt, comptime T: type) T {
        return @ptrCast(self.raw);
    }
};
