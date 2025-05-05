const std = @import("std");

const abi = @import("lib.zig");
const caps = @import("caps.zig");
const sys = @import("sys.zig");

//

pub const FrameVector = std.EnumArray(abi.ChunkSize, caps.Frame);

//

pub fn allocVector(mem: caps.Memory, size: usize) !FrameVector {
    if (size > abi.ChunkSize.@"1GiB".sizeBytes()) return error.SegmentTooBig;
    var frames: FrameVector = .initFill(.{ .cap = 0 });

    inline for (std.meta.fields(abi.ChunkSize)) |f| {
        const variant: abi.ChunkSize = @enumFromInt(f.value);
        const specific_size: usize = variant.sizeBytes();

        if (size & specific_size != 0) {
            const frame = try mem.allocSized(caps.Frame, variant);
            frames.set(variant, frame);
        }
    }

    return frames;
}

pub fn mapVector(v: *const FrameVector, vmem: caps.Vmem, _vaddr: usize, rights: sys.Rights, flags: sys.MapFlags) !void {
    var vaddr = _vaddr;

    var iter = @constCast(v).iterator();
    while (iter.next()) |e| {
        if (e.value.*.cap == 0) continue;

        try vmem.map(
            e.value.*,
            vaddr,
            rights,
            flags,
        );

        vaddr += e.key.sizeBytes();
    }
}

pub fn unmapVector(v: *const FrameVector, vmem: caps.Vmem, _vaddr: usize) !void {
    var vaddr = _vaddr;

    var iter = @constCast(v).iterator();
    while (iter.next()) |e| {
        if (e.value.*.cap == 0) continue;

        try vmem.unmap(
            e.value.*,
            vaddr,
        );

        vaddr += e.key.sizeBytes();
    }
}

pub fn copyForwardsVolatile(comptime T: type, dest: []volatile T, source: []const T) void {
    for (dest[0..source.len], source) |*d, s| d.* = s;
}

// TODO: automatically convert tuples with just one item into that item
// TODO: check extra caps count when deserializing
// TODO: check cap types when deserializing
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

        handler: []const u8,
        // handler: fn (msg: *sys.Message) void,
    };

    var variants: [info.@"struct".fields.len]Variant = undefined;

    var handlers_fields: [info.@"struct".fields.len]std.builtin.Type.StructField = undefined;

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

        const return_ty = @typeInfo(field_info.@"fn".return_type.?);
        if (return_ty == .@"struct" and return_ty.@"struct".is_tuple) {
            for (return_ty.@"struct".fields) |f| {
                _ = output_msg.addType(f.type);
            }
        } else {
            _ = output_msg.addType(field_info.@"fn".return_type.?);
        }

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
        const input_ty = input_msg.MakeIo();
        const output_ty = output_msg.MakeIo();

        variants[i] = Variant{
            .input_converter = input_converter,
            .output_converter = output_converter,
            .input_ty = input_ty,
            .output_ty = output_ty,
            .handler = field.name,
        };

        handlers_fields[i] = std.builtin.Type.StructField{
            .name = field.name,
            .type = fn (ctx: anytype, sender: u32, req: TupleWithoutFirst(input_ty)) output_ty,
            .default_value_ptr = null,
            .alignment = @alignOf(field.type),
            .is_comptime = false,
        };
    }

    const variants_const = variants; // ok zig randomly doesnt like accessing vars from nested things

    const Handlers = @Type(.{ .@"struct" = std.builtin.Type.Struct{
        .layout = .auto,
        .backing_integer = null,
        .fields = &handlers_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
    _ = Handlers;

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

                pub fn call(self: @This(), comptime id: MessageVariant, args: TupleWithoutFirst(VariantOf(id).input_ty)) sys.Error!VariantOf(id).output_ty {
                    const variant = VariantOf(id);

                    var msg: sys.Message = undefined;
                    const inputs = if (@TypeOf(args) == void) .{id} else .{id} ++ args;
                    variant.input_converter.serialize(&msg, inputs);
                    try self.tx.call(&msg);
                    return variant.output_converter.deserialize(&msg).?; // FIXME:
                }
            };
        }

        pub const ServerConfig = struct {
            Context: type = void,
            scope: ?@TypeOf(.enum_literal) = null,
        };

        pub fn Server(comptime config: ServerConfig, comptime handlers: anytype) type {
            return struct {
                rx: caps.Receiver,
                ctx: config.Context,
                comptime logger: ?@TypeOf(.enum_literal) = config.scope,
                comptime handlers: @TypeOf(handlers) = handlers,

                pub fn init(ctx: config.Context, rx: caps.Receiver) @This() {
                    return .{ .ctx = ctx, .rx = rx };
                }

                pub fn process(self: @This(), msg: *sys.Message) void {
                    const variant = variants_const[0].input_converter.deserializeVariant(msg).?; // FIXME:
                    if (self.logger) |s|
                        std.log.scoped(s).debug("handling {s}", .{@tagName(variant)});
                    defer if (self.logger) |s|
                        std.log.scoped(s).debug("handling {s} done", .{@tagName(variant)});

                    // hopefully gets converted into a switch
                    inline for (&variants_const, 0..) |v, i| {
                        if (i == @intFromEnum(variant)) {
                            const sender = msg.cap;
                            const input = v.input_converter.deserialize(msg) orelse {
                                // FIXME: handle invalid input
                                std.log.err("invalid input", .{});
                                return;
                            };

                            const handler = @field(self.handlers, v.handler);
                            // @compileLog(@TypeOf(tuplePopFirst(input)));
                            const output = handler(self.ctx, sender, tuplePopFirst(input));

                            v.output_converter.serialize(msg, output);
                        }
                    }
                }

                pub fn reply(rx: caps.Receiver, comptime id: MessageVariant, output: VariantOf(id).output_ty) sys.Error!void {
                    var msg: sys.Message = undefined;
                    variants_const[@intFromEnum(id)].output_converter.serialize(&msg, output);
                    try rx.reply(&msg);
                }

                pub fn run(self: @This()) !void {
                    var msg: sys.Message = undefined;
                    try self.rx.recv(&msg);
                    while (true) {
                        self.process(&msg);
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
            caps.Notify,
            caps.X86IoPortAllocator,
            caps.X86IoPort,
            caps.X86IrqAllocator,
            caps.X86Irq,
            => {
                real_ty = u32;
                enc = .cap;
            },
            abi.sys.Rights,
            abi.sys.MapFlags,
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

        inline for (self.data[0 .. self.data_cnt - 1]) |data_f| {
            fields[std.fmt.parseInt(usize, data_f.name, 10) catch unreachable] = .{
                .name = data_f.name, // std.fmt.comptimePrint("{}", .{i}),
                .type = data_f.fake_type,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(data_f.fake_type),
            };
            // @compileLog("field", data_f.name, data_f.fake_type);
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

        // @compileLog(Io);

        return struct {
            fn extraCount() comptime_int {
                var extra_count = @max(regs, 5) - 5;

                inline for (self.data[0 .. self.data_cnt - 1]) |f| {
                    if (f.encode_type == .cap) {
                        extra_count += 1;
                    }
                }

                return extra_count;
            }

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
                        const cap_id = @field(inputs, f.name).cap;
                        sys.setExtra(extra_idx, cap_id, cap_id != 0);
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

                std.debug.assert(extra_idx == extraCount());
                msg.extra = extra_idx;
            }

            pub fn deserializeVariant(msg: *const sys.Message) ?self.data[0].fake_type {
                var data_as_regs: [regs]u64 = undefined;
                data_as_regs[0] = msg.arg0;
                const data: Struct = @bitCast(data_as_regs);
                return std.meta.intToEnum(
                    self.data[0].fake_type,
                    @field(data, self.data[0].name),
                ) catch null;
            }

            pub fn deserialize(msg: *const sys.Message) ?Io {
                if (msg.extra != extraCount())
                    return null;

                var ret: Io = undefined;

                var extra_idx: u7 = 0;
                inline for (self.data[0 .. self.data_cnt - 1]) |f| {
                    if (f.encode_type == .cap) {
                        @field(ret, f.name) = .{ .cap = @truncate(sys.getExtra(extra_idx)) };
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

fn TupleWithoutFirst(comptime tuple: type) type {
    // if (@typeInfo(tuple) != .@"struct")
    //     return void;

    var s = @typeInfo(tuple).@"struct";
    if (s.fields.len == 0)
        @compileError("cannot pop the first field from an empty struct");
    if (s.fields.len == 1)
        return void;
    // if (s.fields.len == 2)
    //     return s.fields[1].type;

    var fields: [s.fields.len - 1]std.builtin.Type.StructField = undefined;
    inline for (s.fields[1..], 0..) |f, i| {
        fields[i] = f;
        fields[i].name = s.fields[i].name;
    }
    s.fields = &fields;
    return @Type(.{ .@"struct" = s });
}

fn tuplePopFirst(tuple: anytype) TupleWithoutFirst(@TypeOf(tuple)) {
    // if (@typeInfo(@TypeOf(tuple)) != .@"struct")
    //     return void{};

    const Result = TupleWithoutFirst(@TypeOf(tuple));

    const prev = @typeInfo(@TypeOf(tuple)).@"struct";

    if (prev.fields.len == 0)
        @compileError("cannot pop the first field from an empty struct");
    if (prev.fields.len == 1)
        return void{};
    // if (prev.fields.len == 2)
    //     return tuple.@"1";

    const next = @typeInfo(Result).@"struct";

    var result: Result = undefined;
    inline for (prev.fields[1..], next.fields) |prev_f, next_f| {
        @field(result, next_f.name) = @field(tuple, prev_f.name);
    }

    return result;
}

fn UnwrappedTuple(comptime tuple: type) type {
    if (@typeInfo(tuple) != .@"struct")
        return tuple;
    const s = @typeInfo(tuple).@"struct";
    if (s.fields.len == 0)
        return void;
    if (s.fields.len == 1)
        return s.fields[0].type;
    return tuple;
}

fn unwrapTuple(tuple: anytype) UnwrappedTuple(@TypeOf(tuple)) {
    return tuplePopFirst(.{0} ++ tuple);
}

test "comptime RPC Protocol generator" {
    const Proto = Protocol(struct {
        hello1: fn (val: usize) sys.Error!void,
        hello2: fn () void,
        hello3: fn (frame: caps.Frame) struct { sys.Error!void, usize },
    });

    const client = Proto.Client().init(.{});
    const res1 = client.call(.hello1, .{5});
    const res2 = client.call(.hello2, void{});
    const res3 = client.call(.hello3, .{try caps.ROOT_MEMORY.alloc(caps.Frame)});

    try std.testing.expect(@TypeOf(res1) == sys.Error!struct { sys.Error!void });
    try std.testing.expect(@TypeOf(res2) == sys.Error!struct { void });
    try std.testing.expect(@TypeOf(res3) == sys.Error!struct { sys.Error!void, usize });

    const S = struct {
        fn hello1(_: void, _: u32, request: struct { usize }) struct { sys.Error!void } {
            std.log.info("pm hello1 request: {}", .{request});
            return .{void{}};
        }

        fn hello2(_: void, _: u32, request: void) struct { void } {
            std.log.info("pm hello2 request: {}", .{request});
            return .{void{}};
        }

        fn hello3(_: void, _: u32, request: struct { caps.Frame }) struct { sys.Error!void, usize } {
            std.log.info("pm hello3 request: {}", .{request});
            return .{ void{}, 0 };
        }
    };

    const server = Proto.Server(void, .{
        .hello1 = S.hello1,
        .hello2 = S.hello2,
        .hello3 = S.hello3,
    }).init(void{}, .{});
    try std.testing.expectError(sys.Error.InvalidCapability, server.run());
}
