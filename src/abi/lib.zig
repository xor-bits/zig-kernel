const std = @import("std");
const root = @import("root");

pub const btree = @import("btree.zig");
pub const caps = @import("caps.zig");
pub const ring = @import("ring.zig");
pub const rt = @import("rt.zig");
pub const sys = @import("sys.zig");

//

/// where the kernel places the root binary
pub const ROOT_EXE = 0x200_0000;

//

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

fn logFn(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    var bw = std.io.bufferedWriter(SysLog{});
    const writer = bw.writer();

    // FIXME: lock the log
    nosuspend {
        writer.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        bw.flush() catch return;
    }
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;

    if (ret_addr) |at| {
        std.log.scoped(.panic).err("panicked at 0x{x}:\n{s}", .{ at, msg });
    } else {
        std.log.scoped(.panic).err("panicked:\n{s}", .{msg});
    }

    while (true) {}
}

//

/// kernel object variant that a capability points to
pub const ObjectType = enum(u8) {
    /// an unallocated/invalid capability
    null = 0,
    /// capability that allows kernel object allocation
    memory,
    /// capability to manage a single thread control block (TCB)
    thread,
    /// capability to the virtual memory structure
    vmem,
    /// capability to a physical memory region (sized `ChunkSize`)
    frame,
    /// capability to **the** receiver end of an endpoint,
    /// there can only be a single receiver
    receiver,
    /// capability to **a** sender end of an endpoint,
    /// there can be multiple senders
    sender,
};

/// kernel object size in bit-width (minus 12)
pub const ChunkSize = enum(u5) {
    @"4KiB",
    @"8KiB",
    @"16KiB",
    @"32KiB",
    @"64KiB",
    @"128KiB",
    @"256KiB",
    @"512KiB",
    @"1MiB",
    @"2MiB",
    @"4MiB",
    @"8MiB",
    @"16MiB",
    @"32MiB",
    @"64MiB",
    @"128MiB",
    @"256MiB",
    @"512MiB",
    @"1GiB",

    pub fn of(n_bytes: usize) ?ChunkSize {
        // 0 = 4KiB, 1 = 8KiB, ..
        const page_size = @max(12, std.math.log2_int_ceil(usize, n_bytes)) - 12;
        if (page_size >= 18) return null;
        return @enumFromInt(page_size);
    }

    pub fn next(self: @This()) ?@This() {
        return std.meta.intToEnum(@This(), @intFromEnum(self) + 1) catch return null;
    }

    pub fn sizeBytes(self: @This()) usize {
        return @as(usize, 0x1000) << @intFromEnum(self);
    }
};

/// data structure in the boot info frame provided to the root process
pub const BootInfo = extern struct {
    root_data: [*]u8,
    root_data_len: usize,
    root_path: [*]u8,
    root_path_len: usize,
    initfs_data: [*]u8,
    initfs_data_len: usize,
    initfs_path: [*]u8,
    initfs_path_len: usize,

    pub fn rootData(self: @This()) []u8 {
        return self.root_data[0..self.root_data_len];
    }

    pub fn rootPath(self: @This()) []u8 {
        return self.root_path[0..self.root_path_len];
    }

    pub fn initfsData(self: @This()) []u8 {
        return self.initfs_data[0..self.initfs_data_len];
    }

    pub fn initfsPath(self: @This()) []u8 {
        return self.initfs_path[0..self.initfs_path_len];
    }
};

//

pub const SysLog = struct {
    pub const Error = error{};
    pub fn write(self: @This(), bytes: []const u8) Error!usize {
        try self.writeAll(bytes);
        return bytes.len;
    }
    pub fn writeAll(_: @This(), bytes: []const u8) Error!void {
        sys.log(bytes);
    }
    pub fn flush(_: @This()) Error!void {}
};

//

pub const RootRequest = enum(u8) {
    /// request a physical memory allocator capability
    /// only system processes are allowed request this
    memory,

    /// request a sender to the vm server
    /// only pm can use this
    vm,

    /// provide a sender to the vm server
    /// only vm can use this
    vm_ready,

    // /// install a new pm sender that all new .pm requests get
    // pm_install,

    /// request a sender to the pm server
    pm,

    // /// install a new vfs sender that all new .vfs requests get
    // vfs_install,

    /// request a sender to the vfs server
    vfs,
};

pub const VmRequest = enum(u8) {
    ///
    /// input:
    /// - extra: 1
    /// - extra0: frame capability containing the elf
    /// - arg0: elf binary offset in extra0
    /// - arg1: elf binary length
    ///
    /// output:
    /// - extra: 0
    /// - arg0: Error!handle
    load_elf,

    ///
    /// input:
    ///  - extra: 0
    ///  - arg0: handle
    ///
    /// output:
    ///  - extra: 1
    ///  - extra0: thread capability
    ///  - arg0: Error!void
    exec,
};

// TODO: some RCP style prototype thing that generates
// a serializer and a deserializer for messages and also
// a functions to call the server and server loop
//
// most servers are just:
// ```
// recv(&msg);
// while (true) {
//   handle(&msg)
//   replyRecv(&msg);
// }
// ```

// pub fn Protocol(comptime spec: type) type {
//     const info = comptime @typeInfo(spec);
//     if (info != .@"struct")
//         @compileError("Protocol input has to be a struct");

//     if (info.@"struct".is_tuple)
//         @compileError("Protocol input has to be a struct");

//     var input_msg: MessageUsage = .{};
//     var output_msg: MessageUsage = .{};

//     var server_fields: [info.@"struct".fields.len + 1]struct { [:0]const u8, type } = undefined;
//     server_fields[0] = .{ "rx", caps.Receiver };

//     var message_variant_fields: [info.@"struct".fields.len]std.builtin.Type.EnumField = undefined;
//     for (&message_variant_fields, info.@"struct".fields) |*enum_field, *spec_field| {
//         enum_field.name = spec_field.name;
//     }
//     const message_variant_enum = std.builtin.Type.Enum{
//         .tag_type = if (message_variant_fields.len == 0) void else u8,
//         .fields = &message_variant_fields,
//     };

//     output_msg;

//     inline for (info.@"struct".fields, 0..) |field, i| {
//         const field_info = comptime @typeInfo(field.type);
//         if (field_info != .@"fn")
//             @compileError("Protocol input struct fields have to be of type fn");

//         if (field_info.@"fn".is_generic)
//             @compileError("Protocol input functions cannot be generic");

//         server_fields[i] = .{ field.name, field_info.@"fn" };

//         inline for (field_info.@"fn".params) |param| {
//             if (param.is_generic)
//                 @compileError("Protocol input functions cannot be generic");

//             const param_ty = param.type orelse
//                 @compileError("Protocol input function parameters have to have types");

//             param_ty;
//         }

//         output_msg;
//     }

//     return struct {
//         pub fn Client() type {
//             return struct {
//                 tx: caps.Sender,
//             };
//         }

//         pub fn Server() type {
//             return struct {
//                 rx: caps.Receiver,
//             };
//         }
//     };
// }

// const MessageUsage = struct {
//     // number of capabilities in the extra regs that the single message transfers
//     caps: u7 = 0,
//     // number of raw data registers that the single message transfers
//     // (over 5 regs starts using extra regs)
//     data: [200]DataEntry,
//     data_cnt: u8 = 0,

//     const DataEntry = struct { usize, type };

//     fn addType(comptime self: @This(), comptime ty: type) usize {
//         // caps.Memory,
//         // caps.Thread,
//         // caps.Vmem,
//         // caps.Frame,
//         // caps.Receiver,
//         // caps.Sender,
//         self.data[self.data_cnt] = .{ self.data_cnt, ty };
//         self.data_cnt;
//     }

//     fn finish(comptime self: @This()) void {
//         // make message register use more efficient
//         std.sort.pdq(DataEntry, self.data[0..self.data_cnt], void{}, struct {
//             fn lessThanFn(_: void, lhs: DataEntry, rhs: DataEntry) bool {
//                 return @sizeOf(lhs.@"1") < @sizeOf(rhs.@"1");
//             }
//         }.lessThanFn);
//     }

//     fn Blob(comptime self: @This()) type {
//         var fields: [self.data_cnt]std.builtin.Type.StructField = undefined;
//         for (&self.data, 0..) |s, i| {
//             fields[i] = .{
//                 .name = std.fmt.comptimePrint("{}", .{s.@"0"}),
//                 .type = s.@"1",

//                 .default_value_ptr = null,
//                 .is_comptime = false,
//                 .alignment = @alignOf(s.@"1"),
//             };
//         }

//         const blob: std.builtin.Type.Struct = .{
//             .layout = .@"extern",
//             .fields = &fields,
//         };

//         return @Type(blob);
//     }

//     fn makeSerializer(comptime self: @This()) type {
//         const _Blob = self.Blob();

//         // const func: std.builtin.Type.Fn = .{
//         //     .return_type =
//         // };
//         return struct {
//             fn serialize(inputs: anytype) sys.Error!void {
//                 var blob: _Blob = undefined;
//                 blob;

//                 const blob_info = @typeInfo(_Blob);

//                 inline for (blob_info.@"struct".fields) |f| {
//                     @field(blob, f.name) = @field(blob, inputs.name);
//                 }
//             }
//         };
//     }
// };

// fn allocType(comptime T: type, comptime msg: *MessageUsage) void {
//     const info = @typeInfo(T);

//     switch (info) {
//         .error_union => |v| {
//             if (v.error_set != sys.Error)
//                 @compileError("Error sets must be abi.sys.Error");

//             _ = msg.addType(v.error_set);

//             allocType(v.payload, msg);
//             return;
//         },
//         else => {},
//     }

//     switch (T) {
//         caps.Memory,
//         caps.Thread,
//         caps.Vmem,
//         caps.Frame,
//         caps.Receiver,
//         caps.Sender,
//         => {
//             msg.caps += 1;
//         },

//         void => {},
//     }
// }

// const VmProtocol = Protocol(struct {
//     // TODO: make sure there is only one copy of
//     // this frame so that the vm can read it in peace
//     /// create a new address space and load an ELF into it
//     /// returns an index number that can be used to create threads
//     loadElf: fn (frame: caps.Frame, offset: usize, length: usize) sys.Error!usize,

//     /// create a new thread from an address space
//     exec: fn (vm_handle: usize) sys.Error!caps.Thread,
// });
