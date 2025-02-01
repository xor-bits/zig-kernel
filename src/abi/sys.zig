const std = @import("std");

const ring = @import("ring.zig");

//

pub const Id = enum(usize) {
    /// print debug logs to serial output
    log = 0x1,

    /// give up the CPU for other tasks
    yield = 0x2,

    /// wait on physical memory, depending on the value
    futex_wait = 0x3,

    /// wake waiters on physical memory
    futex_wake = 0x4,

    /// mark the pages as lazy allocated again,
    /// effectively zeroing out the memory and freeing the physical allocation
    lazy_zero = 0x5,

    /// create new io ring
    ring_setup = 0x801,

    /// fork the virtual address space, making both copy on write
    ///
    /// only system processes can use this
    system_fork = 0x8000_0001,

    /// make a ref counted copy of the virtual address space, this is for threads
    ///
    /// only system processes can use this
    system_spawn = 0x8000_0002,

    /// map memory to virtual address space
    ///
    /// only system processes can use this
    system_map = 0x8000_0003,

    /// mark process as ready to run again
    ///
    /// only system processes can use this
    system_exec = 0x8000_0004,
};

pub const Error = error{
    InvalidAddress,
    PermissionDenied,
    BadFileDescriptor,
    InvalidProtocol,
    InvalidArgument,
    InternalError,

    UnknownError,

    // pub fn decode() Self!usize {}
};

pub fn encode(result: Error!usize) usize {
    const val = result catch |err| {
        return encodeError(err);
    };

    return val;
}

pub fn encodeError(err: Error) usize {
    return @bitCast(-@as(isize, switch (err) {
        error.InvalidAddress => 1,
        error.PermissionDenied => 12,
        error.BadFileDescriptor => 16,
        error.InvalidProtocol => 20,
        error.InvalidArgument => 23,
        error.InternalError => 30,
        error.UnknownError => std.debug.panic("unknown error shouldn't be encoded", .{}),
    }));
}

pub fn decode(v: usize) Error!usize {
    const v_isize: isize = @bitCast(v);
    const err = -v_isize;

    return switch (err) {
        std.math.minInt(isize)...0 => v,
        1 => error.InvalidAddress,
        12 => error.PermissionDenied,
        16 => error.BadFileDescriptor,
        20 => error.InvalidProtocol,
        23 => error.InvalidArgument,
        30 => error.InternalError,
        else => return error.UnknownError,
    };
}

//

pub const Page = struct { v: [0x1000]u8 align(0x1000) };

//

pub fn log(s: []const u8) void {
    _ = call(.log, .{ @intFromPtr(s.ptr), s.len }) catch unreachable;
}

pub fn yield() void {
    _ = call(.yield, .{}) catch unreachable;
}

/// goes to sleep if the `[value]` is `expected`
pub fn futex_wait(value: *const usize, expected: usize) void {
    // the only possible error is using an invalid address,
    // which either page faults or GP faults anyways
    _ = call(.futex_wait, .{ @intFromPtr(value), expected }) catch unreachable;
}

/// wake up `n` tasks sleeping on `[value]`
pub fn futex_wake(value: *const usize, n: usize) void {
    _ = call(.futex_wake, .{ @intFromPtr(value), n }) catch unreachable;
}

/// mark the pages as lazy allocated again,
/// effectively zeroing out the memory and freeing the physical allocation
pub fn lazy_zero(pages: []Page) void {
    _ = call(.lazy_zero, .{ @intFromPtr(pages.ptr), pages.len }) catch unreachable; // the only error would be a segfault
}

/// create a I/O ring, the futex is used to wait
pub fn ringSetup(
    submission_queue: *SubmissionQueue,
    completion_queue: *CompletionQueue,
    futex: *std.atomic.Value(usize),
) Error!void {
    _ = try call(.ring_setup, .{ @intFromPtr(submission_queue), @intFromPtr(completion_queue), @intFromPtr(futex) });
}

pub fn ringWait() Error!void {
    _ = try call(.ring_wait, .{});
}

pub fn vfs_proto_create(name: []const u8) Error!usize {
    return try call(.vfs_proto_create, .{ @intFromPtr(name.ptr), name.len });
}

pub fn vfs_proto_next(
    proto_handle: usize,
    request: *ProtocolRequest,
    path_buf: *[4096]u8,
) Error!void {
    _ = try call(.vfs_proto_next, .{ proto_handle, @intFromPtr(request), @intFromPtr(path_buf) });
    // return try
}

// // system processes only
// pub fn system_fork(from_pid: usize, to_pid: usize) void {
//     _ = call2(@intFromEnum(Id.system_fork), from_pid, to_pid);
// }

// system processes only
pub fn system_map(pid: usize, new_maps: []const Map) void {
    _ = call(.system_map, .{ pid, @intFromPtr(new_maps.ptr), new_maps.len }) catch unreachable;
}

// system processes only
pub fn system_exec(pid: usize, ip: usize, sp: usize) void {
    _ = call(.system_exec, .{ pid, ip, sp }) catch unreachable;
}

//

// /// zig doesn't support `extern union(enum)` yet
// pub fn externify(comptime U: type) type {
//     var info = @typeInfo(U);
//     switch (info) {
//         .Union => |*info_union| {
//             const Tag = comptime info_union.tag_type.?;
//             info_union.tag_type = null;
//             info_union.layout = .@"extern";
//             const Data = comptime @Type(info);
//             return extern struct {
//                 tag: Tag,
//                 data: Data,
//             };
//         },
//         else => @compileError("tagged unions only"),
//     }
// }

pub const Fd = u16;

pub const SubmissionQueue = ring.AtomicRing(SubmissionEntry, [*]SubmissionEntry);

/// io operation
pub const SubmissionEntry = extern struct {
    user_data: u64 = 0,
    offset: usize,
    buffer: [*]u8,
    buffer_len: u32,
    fd: Fd,
    opcode: enum(u8) {
        proto_create,
        proto_next_open,
        open,
        _,
    },
    flags: u8,
};

pub const CompletionQueue = ring.AtomicRing(CompletionEntry, [*]CompletionEntry);

/// io operation result
pub const CompletionEntry = extern struct {
    user_data: u64 = 0,
    result: usize,
};

pub const ProtocolRequest = extern struct {
    /// TODO: this is for concurrency later
    id: usize,

    data: Data,
    ty: Tag,

    pub const Tag = enum(u8) {
        open,
        close,
    };

    pub const Data = extern union {
        open: Open,
        close: Close,
    };

    pub const Open = extern struct {
        path_len: usize, // path is stored in a 4096 buffer provided separately
        flags: usize,
        mode: usize,
    };

    pub const Close = extern struct {
        /// the client fd is not known to a vfs proto handler
        local_fd: usize,
    };
};

pub const ProtocolResponse = extern struct {
    id: usize,

    data: Data,
    ty: Tag,

    pub const Tag = enum(u8) {
        open,
        close,
    };

    pub const Data = extern union {
        open: Open,
        close: Close,
    };

    pub const Open = extern struct {
        result: usize,
    };

    pub const Close = extern struct {};
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
        ///
        /// whole pages are filled with zeroes before writing
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

pub fn call(id: Id, args: anytype) Error!usize {
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info != .Struct or !args_type_info.Struct.is_tuple) {
        @compileError("expected tuple argument, found " ++ @typeName(ArgsType));
    }

    const fields = args_type_info.Struct.fields;

    const syscall_id = @intFromEnum(id);
    const result: usize = switch (fields.len) {
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

    return try decode(result);
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
