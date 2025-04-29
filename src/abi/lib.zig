const std = @import("std");
const root = @import("root");

pub const btree = @import("btree.zig");
pub const caps = @import("caps.zig");
pub const ring = @import("ring.zig");
pub const rt = @import("rt.zig");
pub const sys = @import("sys.zig");
pub const util = @import("util.zig");

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

    std.log.scoped(.panic).err("panicked: {s}\nstack trace:", .{msg});
    var iter = std.debug.StackIterator.init(ret_addr, @frameAddress());
    while (iter.next()) |addr| {
        std.log.scoped(.panic).warn("  0x{x}", .{addr});
    }

    asm volatile ("mov 0, %rax"); // read from nullptr to kill the process
    unreachable;
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

    /// request self vmem capability
    /// only vm can use this
    self_vmem,

    /// request a sender to the vm server
    /// only pm can use this
    vm,

    /// provide a sender to the vm server
    /// only vm can use this
    vm_ready,

    /// request a sender to the pm server
    pm,

    /// install a new pm sender that all new .pm requests get
    pm_ready,

    // /// install a new vfs sender that all new .vfs requests get
    // vfs_install,

    /// request a sender to the vfs server
    vfs,
};

pub const VmRequest = enum(u8) {
    /// create a new empty address space
    /// returns an index number that can be used to create threads
    ///
    /// input:
    /// - arg0: .new_vmem
    ///
    /// output:
    /// - arg0: Error!usize (handle)
    new_vmem,

    // TODO: make sure there is only one copy of
    // this frame so that the vm can read it in peace
    /// load an ELF into an address space
    ///
    /// input:
    /// - extra: 1
    /// - extra0: frame capability containing the elf
    /// - arg0: .load_elf
    /// - arg1: handle
    /// - arg2: elf binary offset in extra0
    /// - arg3: elf binary length
    ///
    /// output:
    /// - extra: 0
    /// - arg0: Error!void
    load_elf,

    /// create a new thread from an address space
    /// ip and sp are already set
    ///
    /// input:
    ///  - extra: 0
    ///  - arg0: .new_thread
    ///  - arg1: handle
    ///
    /// output:
    ///  - extra: 1
    ///  - extra0: thread capability
    ///  - arg0: Error!void
    new_thread,
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

pub const VmProtocol = Protocol(struct {
    // TODO: make sure there is only one copy of
    // this frame so that the vm can read it in peace
    /// create a new address space and load an ELF into it
    /// returns an index number that can be used to create threads
    loadElf: fn (frame: caps.Frame, offset: usize, length: usize) sys.Error!void,
    // loadElf: fn (frame: caps.Frame, offset: usize, length: usize) sys.Error!usize,

    /// create a new thread from an address space
    exec: fn (vm_handle: usize) sys.Error!void,
    // exec: fn (vm_handle: usize) sys.Error!caps.Thread,
});

pub const PmProtocol = Protocol(struct {
    hello: fn (val: usize) sys.Error!void,
});

/// this fucking monstrosity converts a simple specification type
/// into a Client and Server based on the hiillos IPC system
/// look at `VmProtocol` for an example
pub fn Protocol(comptime spec: type) type {
    const info = comptime @typeInfo(spec);
    if (info != .@"struct")
        @compileError("Protocol input has to be a struct");

    if (info.@"struct".is_tuple)
        @compileError("Protocol input has to be a struct");

    const Variant = struct {
        /// the tuple input
        input_ty: type,
        /// the tuple output
        output_ty: type,

        /// struct containing `serialize` and `deserialize` fns
        /// to convert `input_ty` to a message
        /// and message to `input_ty`
        input_converter: type,
        /// struct containing `serialize` and `deserialize` fns
        /// to convert `output_ty` to a message
        /// and message to `output_ty`
        output_converter: type,

        handler: fn (msg: *sys.Message) void,
    };

    var variants: [info.@"struct".fields.len]Variant = undefined;

    var server_fields: [info.@"struct".fields.len + 1]struct { [:0]const u8, type } = undefined;
    server_fields[0] = .{ "rx", caps.Receiver };

    var message_variant_fields: [info.@"struct".fields.len]std.builtin.Type.EnumField = undefined;
    var message_variant_field_idx = 0;
    for (&message_variant_fields, info.@"struct".fields) |*enum_field, *spec_field| {
        enum_field.* = .{
            .name = spec_field.name,
            .value = message_variant_field_idx,
        };
        message_variant_field_idx += 1;
    }
    const _message_variant_enum = std.builtin.Type{ .@"enum" = std.builtin.Type.Enum{
        .tag_type = if (message_variant_fields.len == 0) void else u8,
        .fields = &message_variant_fields,
        .decls = &.{},
        .is_exhaustive = true,
    } };
    const MessageVariant: type = @Type(_message_variant_enum);

    inline for (info.@"struct".fields, 0..) |field, i| {
        // RPC call param serializer/deserializer
        var input_msg: MessageUsage = .{};
        // RPC call result serializer/deserializer
        var output_msg: MessageUsage = .{};

        // the arg "0" is an enum of the call type
        _ = input_msg.addType(MessageVariant);

        const field_info = comptime @typeInfo(field.type);
        if (field_info != .@"fn")
            @compileError("Protocol input struct fields have to be of type fn");

        if (field_info.@"fn".is_generic)
            @compileError("Protocol input functions cannot be generic");

        server_fields[i] = .{ field.name, field.type };

        _ = output_msg.addType(field_info.@"fn".return_type.?);

        inline for (field_info.@"fn".params) |param| {
            if (param.is_generic)
                @compileError("Protocol input functions cannot be generic");

            const param_ty = param.type orelse
                @compileError("Protocol input function parameters have to have types");

            _ = input_msg.addType(param_ty);
        }

        input_msg.finish(true);
        output_msg.finish(false);

        // if (true)
        //     @compileError(std.fmt.comptimePrint("input_ty={}", .{input_msg.MakeIo()}));

        const input_converter = input_msg.makeConverter();
        const output_converter = output_msg.makeConverter();

        variants[i] = Variant{
            .input_converter = input_converter,
            .output_converter = output_converter,
            .input_ty = input_msg.MakeIo(),
            .output_ty = output_msg.MakeIo(),
            .handler = struct {
                fn handler(msg: *sys.Message) void {
                    std.log.info("handler {}", .{i});

                    _ = msg;
                    // const input = input_converter.deserialize(msg) orelse {
                    //     // FIXME: handle invalid input
                    //     std.log.err("invalid input", .{});
                    //     return;
                    // };

                }
            }.handler,
        };
    }

    const variants_const = variants; // ok zig randomly doesnt like accessing vars from nested things

    return struct {
        fn ReturnType(comptime id: MessageVariant) type {
            return info.@"struct".fields[@intFromEnum(id)].type;
        }

        fn VariantOf(comptime id: MessageVariant) Variant {
            return variants_const[@intFromEnum(id)];
        }

        pub fn Client() type {
            return struct {
                tx: caps.Sender,

                pub fn init(tx: caps.Sender) @This() {
                    return .{ .tx = tx };
                }

                pub fn call(self: @This(), comptime id: MessageVariant, args: anytype) sys.Error!VariantOf(id).output_ty {
                    const variant = VariantOf(id);

                    var msg: sys.Message = undefined;
                    variant.input_converter.serialize(&msg, .{id} ++ args);
                    try self.tx.call(&msg);
                    return variant.output_converter.deserialize(&msg).?; // FIXME:
                }
            };
        }

        pub fn Server() type {
            return struct {
                rx: caps.Receiver,
                // handlers: []const fn () void = b: {
                //     var _handlers = [info.@"struct".fields.len]fn () void;
                //     inline for ()
                //     break :b;
                // },

                pub fn init(rx: caps.Receiver) @This() {
                    return .{ .rx = rx };
                }

                pub fn run(self: @This()) !void {
                    var msg: sys.Message = undefined;
                    try self.rx.recv(&msg);
                    while (true) {
                        const variant = variants_const[0].input_converter.deserializeVariant(&msg).?; // FIXME:

                        // hopefully gets converted into a switch
                        inline for (0..variants_const.len) |i| {
                            if (i == @intFromEnum(variant)) {
                                variants_const[i].handler(&msg);
                            }
                        }

                        try self.rx.replyRecv(&msg);
                    }
                }
            };
        }
    };
}

const MessageUsage = struct {
    // number of capabilities in the extra regs that the single message transfers
    caps: u7 = 0,
    // number of raw data registers that the single message transfers
    // (over 5 regs starts using extra regs)
    data: [200]DataEntry = undefined,
    data_cnt: u8 = 0,

    finished: ?type = null,

    const DataEntry = struct {
        name: [:0]const u8,
        type: type,
        fake_type: type,
        encode_type: DataEntryEnc,
    };

    const DataEntryEnc = enum {
        raw,
        cap,
        err,
        tagged_enum,
    };

    /// adds a named (named the returned number) field of type to this struct builder
    fn addType(comptime self: *@This(), comptime ty: type) usize {
        if (self.finished != null)
            @compileError("already finished");

        var real_ty: type = undefined;
        var enc: DataEntryEnc = undefined;

        switch (ty) {
            caps.Memory,
            caps.Thread,
            caps.Vmem,
            caps.Frame,
            caps.Receiver,
            caps.Sender,
            => {
                real_ty = u32;
                enc = .cap;
            },
            f64,
            f32,
            f16,
            usize,
            u32,
            u16,
            u8,
            isize,
            i32,
            i16,
            i8,
            void,
            => {
                real_ty = ty;
                enc = .raw;
            },
            sys.Error!void => {
                real_ty = usize;
                enc = .err;
            },
            else => {
                const info = @typeInfo(ty);
                if (info == .@"enum") {
                    real_ty = info.@"enum".tag_type;
                    enc = .tagged_enum;
                } else {
                    @compileError(std.fmt.comptimePrint("unknown type {}", .{ty}));
                }
            },
        }

        self.data[self.data_cnt] = .{
            .name = std.fmt.comptimePrint("{}", .{self.data_cnt}),
            .type = real_ty,
            .fake_type = ty,
            .encode_type = enc,
        };
        self.data_cnt += 1;
        return self.data_cnt;
    }

    /// reorder fields to compact the data
    fn finish(comptime self: *@This(), comptime is_union: bool) void {
        if (self.finished != null)
            @compileError("already finished");

        // make message register use more efficient
        // sorts everything except leaves the union tag (enum) as the first thing, because it has to
        std.sort.pdq(DataEntry, self.data[@intFromBool(is_union)..self.data_cnt], void{}, struct {
            fn lessThanFn(_: void, lhs: DataEntry, rhs: DataEntry) bool {
                return @sizeOf(lhs.type) < @sizeOf(rhs.type);
            }
        }.lessThanFn);

        const size_without_padding = @sizeOf(self.MakeStruct());
        const size_with_padding = std.mem.alignForward(usize, size_without_padding, @sizeOf(usize));

        const padding = @Type(std.builtin.Type{ .array = std.builtin.Type.Array{
            .len = size_with_padding - size_without_padding,
            .child = u8,
            .sentinel_ptr = null,
        } });
        self.data[self.data_cnt] = .{
            .name = "_padding",
            .type = padding,
            .fake_type = padding,
            .encode_type = .raw,
        };
        self.data_cnt += 1;
        self.finished = self.MakeStruct();
    }

    fn MakeStruct(comptime self: @This()) type {
        var fields: [self.data_cnt]std.builtin.Type.StructField = undefined;
        for (self.data[0..self.data_cnt], 0..) |s, i| {
            fields[i] = .{
                .name = s.name,
                .type = s.type,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(s.type),
            };
        }

        const ty: std.builtin.Type = .{ .@"struct" = .{
            .layout = .@"extern",
            .backing_integer = null,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        } };

        return @Type(ty);
    }

    fn MakeIo(comptime self: @This()) type {
        var fields: [self.data_cnt - 1]std.builtin.Type.StructField = undefined;
        inline for (self.data[0 .. self.data_cnt - 1], &fields) |data_f, *tuple_f| {
            tuple_f.* = .{
                .name = data_f.name,
                .type = data_f.fake_type,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(data_f.fake_type),
            };
        }

        const ty: std.builtin.Type = .{ .@"struct" = .{
            .layout = .auto,
            .backing_integer = null,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = true,
        } };

        return @Type(ty);
    }

    fn makeConverter(comptime self: @This()) type {
        const Struct: type = self.finished orelse
            @compileError("not finished");
        const Io: type = self.MakeIo();
        const regs: usize = comptime @sizeOf(Struct) / @sizeOf(usize);

        return struct {
            pub fn serialize(msg: *sys.Message, inputs: Io) void {
                var data: Struct = undefined;

                // const input_fields: []const std.builtin.Type.StructField = @typeInfo(@TypeOf(inputs));
                inline for (self.data[0 .. self.data_cnt - 1]) |f| {
                    // copy every (non cap and non padding) field of `data` from `input`
                    // @compileLog(std.fmt.comptimePrint("name={s} ty={} fakety={} encty={}", .{
                    //     f.name,
                    //     f.type,
                    //     f.fake_type,
                    //     f.encode_type,
                    // }));

                    if (f.encode_type == .err) {
                        @field(data, f.name) =
                            sys.encodeVoid(@field(inputs, f.name));
                    } else if (f.encode_type == .raw) {
                        @field(data, f.name) =
                            @field(inputs, f.name);
                    } else if (f.encode_type == .tagged_enum) {
                        @field(data, f.name) =
                            @intFromEnum(@field(inputs, f.name));
                    }
                }

                const data_as_regs: [regs]u64 = @bitCast(data);

                var extra_idx: u7 = 0;

                inline for (self.data[0 .. self.data_cnt - 1]) |f| {
                    if (f.encode_type == .cap) {
                        sys.setExtra(extra_idx, @field(inputs, f.name).cap, true);
                        extra_idx += 1;
                    }
                }

                inline for (data_as_regs[0..], 0..) |reg, i| {
                    if (i == 0) {
                        msg.arg0 = reg;
                    } else if (i == 1) {
                        msg.arg1 = reg;
                    } else if (i == 2) {
                        msg.arg2 = reg;
                    } else if (i == 3) {
                        msg.arg3 = reg;
                    } else if (i == 4) {
                        msg.arg4 = reg;
                    } else {
                        sys.setExtra(extra_idx, reg, false);
                        extra_idx += 1;
                    }
                }
            }

            pub fn deserializeVariant(msg: *sys.Message) ?self.data[0].fake_type {
                var data_as_regs: [regs]u64 = undefined;
                data_as_regs[0] = msg.arg0;
                const data: Struct = @bitCast(data_as_regs);
                return std.meta.intToEnum(
                    self.data[0].fake_type,
                    @field(data, self.data[0].name),
                ) catch null;
            }

            pub fn deserialize(msg: *sys.Message) ?Io {
                var ret: Io = undefined;

                var extra_idx: u7 = 0;
                inline for (self.data[0 .. self.data_cnt - 1]) |f| {
                    if (f.encode_type == .cap) {
                        @field(ret, f.name) = .{ .cap = sys.getExtra(extra_idx) };
                        extra_idx += 1;
                    }
                }

                var data_as_regs: [regs]u64 = undefined;
                inline for (data_as_regs[0..], 0..) |*reg, i| {
                    if (i == 0) {
                        reg.* = msg.arg0;
                    } else if (i == 1) {
                        reg.* = msg.arg1;
                    } else if (i == 2) {
                        reg.* = msg.arg2;
                    } else if (i == 3) {
                        reg.* = msg.arg3;
                    } else if (i == 4) {
                        reg.* = msg.arg4;
                    } else {
                        reg.* = sys.getExtra(extra_idx);
                        extra_idx += 1;
                    }
                }
                const data: Struct = @bitCast(data_as_regs);

                inline for (self.data[0 .. self.data_cnt - 1]) |f| {
                    if (f.encode_type == .err) {
                        @field(ret, f.name) =
                            sys.decodeVoid(@field(data, f.name));
                    } else if (f.encode_type == .raw) {
                        @field(ret, f.name) =
                            @field(data, f.name);
                    } else if (f.encode_type == .tagged_enum) {
                        @field(ret, f.name) =
                            @enumFromInt(@field(data, f.name));
                        // std.meta.intToEnum(f.fake_type, @field(data, f.name)) orelse return null;
                    }
                }
                return ret;
            }
        };
    }
};
