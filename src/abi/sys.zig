pub const Id = enum(usize) {
    log = 0x1,
    // system_fork = 0x8000_0001,
    system_map = 0x8000_0002,
    system_exec = 0x8000_0003,
};

pub const Map = extern struct {
    dst: usize,
    src: MapSource,
    flags: MapFlags,
};

pub const MapSource = extern struct {
    tag: enum(u8) {
        bytes,
        lazy,
    },

    data: extern union {
        /// allocate pages immediately, and write bytes into them
        bytes: extern struct {
            first: [*]const u8,
            len: usize,
        },

        /// allocate (n divceil 0x1000) pages lazily (overcommit)
        lazy: usize,
    },

    const Self = @This();

    pub fn newBytes(b: []const u8) Self {
        return Self{
            .tag = .bytes,
            .data = .{ .bytes = .{ .first = b.ptr, .len = b.len } },
        };
    }

    pub fn asBytes(self: Self) ?[]const u8 {
        if (self.tag != .bytes) {
            return null;
        }

        return self.data.bytes.first[0..self.data.bytes.len];
    }

    pub fn newLazy(len: usize) Self {
        return Self{
            .tag = .lazy,
            .data = .{ .lazy = len },
        };
    }

    pub fn asLazy(self: Self) ?usize {
        if (self.tag != .lazy) {
            return null;
        }

        return self.data.lazy;
    }

    pub fn length(self: Self) usize {
        switch (self.tag) {
            .bytes => return self.data.bytes.len,
            .lazy => return self.data.lazy,
        }
    }
};

pub const MapFlags = packed struct {
    write: bool,
    execute: bool,
    _p: u6 = 0,
};

//

pub fn log(s: []const u8) void {
    _ = call2(@intFromEnum(Id.log), @intFromPtr(s.ptr), s.len);
}

// // system processes only
// pub fn system_fork(from_pid: usize, to_pid: usize) void {
//     _ = call2(@intFromEnum(Id.system_fork), from_pid, to_pid);
// }

// system processes only
pub fn system_map(pid: usize, new_maps: []const Map) void {
    _ = call3(@intFromEnum(Id.system_map), pid, @intFromPtr(new_maps.ptr), new_maps.len);
}

// system processes only
pub fn system_exec(pid: usize, ip: usize, sp: usize) void {
    _ = call3(@intFromEnum(Id.system_exec), pid, ip, sp);
}

//

pub fn call2(id: usize, arg1: usize, arg2: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn call3(id: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}
