const std = @import("std");

//

pub const Id = enum(usize) {
    log = 0x1,
    yield = 0x2,

    vfs_proto_create = 0x1001,

    // system_fork = 0x8000_0001,
    system_map = 0x8000_0002,
    system_exec = 0x8000_0003,
};

//

pub fn log(s: []const u8) void {
    _ = call(Id.log, .{ @intFromPtr(s.ptr), s.len });
}

pub fn yield() void {
    _ = call(Id.yield, .{});
}

pub fn vfs_proto_create(name: []const u8) usize {
    return call(Id.vfs_proto_create, .{ @intFromPtr(name.ptr), name.len });
}

// // system processes only
// pub fn system_fork(from_pid: usize, to_pid: usize) void {
//     _ = call2(@intFromEnum(Id.system_fork), from_pid, to_pid);
// }

// system processes only
pub fn system_map(pid: usize, new_maps: []const Map) void {
    _ = call(Id.system_map, .{ pid, @intFromPtr(new_maps.ptr), new_maps.len });
}

// system processes only
pub fn system_exec(pid: usize, ip: usize, sp: usize) void {
    _ = call(Id.system_exec, .{ pid, ip, sp });
}

//

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

pub fn call(id: Id, args: anytype) usize {
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info != .Struct or !args_type_info.Struct.is_tuple) {
        @compileError("expected tuple argument, found " ++ @typeName(ArgsType));
    }

    const fields = args_type_info.Struct.fields;

    const syscall_id = @intFromEnum(id);
    return switch (fields.len) {
        0 => call0(
            syscall_id,
        ),
        1 => call1(
            syscall_id,
            @field(args, fields[0].name),
        ),
        2 => call2(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
        ),
        3 => call3(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
            @field(args, fields[2].name),
        ),
        4 => call4(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
            @field(args, fields[2].name),
            @field(args, fields[3].name),
        ),
        5 => call5(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
            @field(args, fields[2].name),
            @field(args, fields[3].name),
            @field(args, fields[4].name),
        ),
        else => @compileError("expected 5 or less syscall arguments, found " ++ fields.len),
    };
}

// TODO: move intFromEnum to here
pub fn call0(id: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn call1(id: usize, arg1: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

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

pub fn call4(id: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r8}" (arg4),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn call5(id: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r8}" (arg4),
          [arg5] "{r9}" (arg5),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}
