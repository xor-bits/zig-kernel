const std = @import("std");

//

pub const Phys = struct {
    raw: usize,

    pub const Parts = packed struct {
        offset: u12 = 0,
        page: u32 = 0,
        reserved0: u8 = 0,
        reserved1: u12 = 0,
    };

    pub fn fromInt(i: usize) Phys {
        return Phys{
            .raw = i,
        };
    }

    pub fn toHhdm(self: Phys) Virt {
        return Virt{
            .raw = self.raw + 0xffff800000000000,
        };
    }

    pub fn fromParts(parts: Parts) Phys {
        return fromInt(@as(usize, @bitCast(parts)));
    }

    pub fn toParts(self: Phys) Parts {
        return @bitCast(self.raw);
    }
};

pub const Virt = struct {
    raw: usize,

    pub const Parts = packed struct {
        offset: u12 = 0,
        level1: u9 = 0,
        level2: u9 = 0,
        level3: u9 = 0,
        level4: u9 = 0,
        _extra: u16 = 0,
    };

    pub fn fromInt(i: usize) Virt {
        return Virt{
            .raw = i,
        };
    }

    pub fn fromPtr(ptr: anytype) Virt {
        return Virt{
            .raw = @intFromPtr(ptr),
        };
    }

    pub fn toPtr(self: Virt, comptime T: type) T {
        return @ptrFromInt(self.raw);
    }

    pub fn fromParts(parts: Parts) Virt {
        return fromInt(@bitCast(parts));
    }

    pub fn toParts(self: Virt) Parts {
        return @bitCast(self.raw);
    }
};
