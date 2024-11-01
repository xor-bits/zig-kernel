const std = @import("std");
const limine = @import("limine");

//

pub export var framebuffer: limine.FramebufferRequest = .{};

pub export var base_revision: limine.BaseRevision = .{ .revision = 2 };

pub export var memory: limine.MemoryMapRequest = .{};

//

export fn _start() callconv(.C) noreturn {
    // crash if bootloader is unsupported
    if (!base_revision.is_supported()) {
        hcf();
    }

    // crash if there is no framebuffer response
    const framebuffer_response = framebuffer.response orelse hcf();

    // crash if there isn't at least 1 framebuffer
    if (framebuffer_response.framebuffer_count < 1) {
        hcf();
    }

    const fb = framebuffer_response.framebuffers()[0];

    const font = @embedFile("asset/font.bmp");
    parse_bmp(font) catch hcf();

    print("hello\n", .{});
    print("world\n", .{});

    for (0..50) |y| {
        for (0..50) |x| {
            const pixel_offs = (y + 100) * fb.pitch + (x + 100) * 4;
            @as(*u32, @ptrCast(@alignCast(fb.address + pixel_offs))).* = 0xffff_ffff;
        }
    }

    hcf();
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    init_uart();

    const UartWriter = struct {
        pub const Error = error{};
        pub const Self = @This();

        pub fn writeAll(_: *const Self, bytes: []const u8) !void {
            Uart.writeAll(bytes);
        }

        pub fn writeBytesNTimes(self: *const Self, bytes: []const u8, n: usize) !void {
            for (0..n) |_| {
                try self.writeAll(bytes);
            }
        }
    };

    // _ = fmt;
    // _ = args;
    std.fmt.format(UartWriter{}, fmt, args) catch {};
}

fn init_uart() void {
    if (!uart_lazy_init.isInitialized()) {
        // very low chance to not be initialized (only the first time)
        @setCold(true);

        uart_lazy_init.startInit() catch {
            // super low chance to not be initialized and currently initializing
            // (only when one thread accesses it for the first time and the current thread just a short time later)
            @setCold(true);
            uart_lazy_init.wait();
            return;
        };

        Uart.init();
    }
}

pub var uart_lazy_init: LazyInit = LazyInit.new();

pub const LazyInit = struct {
    initialized: bool = false,
    initializing: bool = false,

    const Self = @This();

    pub fn new() Self {
        return .{};
    }

    pub fn isInitialized(self: *Self) bool {
        return @atomicLoad(bool, &self.initialized, std.builtin.AtomicOrder.acquire);
    }

    pub fn wait(self: *Self) void {
        while (!self.isInitialized()) {}
    }

    pub fn startInit(self: *Self) !void {
        if (@atomicRmw(bool, &self.initializing, std.builtin.AtomicRmwOp.Xchg, true, .acquire)) {
            return error.AlreadyInitializing;
        }
    }

    pub fn finishInit(self: *Self) void {
        @atomicStore(bool, &self.initialized, true, .release);
    }
};

pub fn Lazy(comptime T: type, comptime K: type) type {
    return struct {
        value: T = undefined,
        initialized: bool = false,
        initializing: bool = false,

        const Self = @This();

        pub fn new() Self {
            return .{};
        }

        pub fn tryGet(self: *Self) ?*T {
            if (@atomicLoad(bool, &self.initialized, std.builtin.AtomicOrder.acquire)) {
                return &self.value;
            } else {
                @setCold(true);
                return null;
            }
        }

        pub fn wait(self: *Self) *T {
            while (true) {
                if (self.tryGet()) |initialized| {
                    return initialized;
                }
            }
        }

        pub fn get(self: *Self) *T {
            if (self.tryGet()) |initialized| {
                // already initialized
                return initialized;
            }

            if (@atomicRmw(bool, &self.initializing, std.builtin.AtomicRmwOp.Xchg, true, .acquire)) {
                // something else is already initializing it
                return self.wait();
            }

            // now we are initializing it
            self.value = K.call();
            @atomicStore(bool, &self.initialized, true, .release);

            return &self.value;
        }
    };
}

pub var uart = Lazy(Uart, struct {
    fn call() Uart {
        return Uart.init();
    }
}).new();

pub const Uart = struct {
    const PORT: u16 = 0x3f8;

    pub const Self = @This();

    pub fn init() void {
        outb(PORT + 1, 0x00);
        outb(PORT + 3, 0x80);
        outb(PORT + 0, 0x03);
        outb(PORT + 1, 0x00);
        outb(PORT + 3, 0x03);
        outb(PORT + 2, 0xc7);
        outb(PORT + 4, 0x0b);
        outb(PORT + 4, 0x1e);
        outb(PORT + 0, 0xae);

        if (inb(PORT + 0) != 0xAE) {
            hcf();
        }

        outb(PORT + 4, 0x0f);
    }

    pub fn readByte() u8 {
        while (inb(PORT + 5) & 1 == 0) {}
        return inb(PORT);
    }

    pub fn writeByte(byte: u8) void {
        while (inb(PORT + 5) & 0x20 == 0) {}
        outb(PORT, byte);
    }

    pub fn writeAll(bytes: []const u8) void {
        for (bytes) |byte| {
            Self.writeByte(byte);
        }
    }

    pub fn writeBytesNTimes(bytes: []const u8, times: usize) void {
        for (0..times) |_| {
            Self.writeAll(bytes);
        }
    }
};

pub fn outb(port: u16, byte: u8) void {
    asm volatile (
        \\ outb %[byte], %[port]
        :
        : [byte] "{al}" (byte),
          [port] "N{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile (
        \\ inb %[port], %[byte]
        : [byte] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub const BmpError = error{
    UnexpectedEof,
    InvalidIndentifier,
    UnexpectedSize,
};

pub const Parser = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) Parser {
        return .{ .bytes = bytes };
    }

    pub fn read(self: *Parser, comptime T: type) !T {
        switch (@typeInfo(T)) {
            .Int => return try self.readInt(T),
            .Array => return try self.readArray(T),
            .Struct => return try self.readStruct(T),
            else => @compileError("unsupported type"),
        }
    }

    pub fn readInt(self: *Parser, comptime T: type) !T {
        const size = @sizeOf(T);
        if (self.bytes.len <= size) {
            return error.UnexpectedEof;
        }

        const value: *align(1) const T = @ptrCast(self.bytes);
        self.bytes = self.bytes[size..];

        return value.*;
    }

    pub fn readArray(self: *Parser, comptime T: type) !T {
        if (self.bytes.len <= @sizeOf(T)) {
            return error.UnexpectedEof;
        }

        const array = @typeInfo(T).Array;

        var instance: [array.len]array.child = undefined;

        inline for (0..array.len) |i| {
            instance[i] = try self.read(array.child);
        }

        return instance;
    }

    pub fn readStruct(self: *Parser, comptime T: type) !T {
        if (self.bytes.len <= @sizeOf(T)) {
            return error.UnexpectedEof;
        }

        const fields = @typeInfo(T).Struct.fields;

        var instance: T = undefined;

        inline for (fields) |field| {
            @field(instance, field.name) = try self.read(field.type);
        }

        return instance;
    }
};

fn parse_bmp(bmp: []const u8) !void {
    var parser = Parser.init(bmp);

    const bmp_header = parser.readStruct(struct {
        ident: u16,
        bmp_header_size: u32,
        _pad: [2]u16,
        offs: u32,
    }) catch return BmpError.UnexpectedEof;

    const dib_header = parser.readStruct(struct {
        dib_header_size: u32,
        width: u32,
        height: u32,
        color_planes_len: u16,
        bits_per_pixel: u16,
        pixel_array_compression: u32,
        size: u32,
        pixel_per_meter_horizontal: u32,
        pixel_per_meter_vertical: u32,
        colors_len: u32,
        important_colors_len: u32,
        red_mask: u32,
        green_mask: u32,
        blue_mask: u32,
        alpha_mask: u32,
        color_space: u32,
        color_space_endpoints: [0x24]u32,
        red_gamma: u32,
        green_gamma: u32,
        blue_gamma: u32,
    }) catch return BmpError.UnexpectedEof;

    print("{any}\n", .{bmp_header});
    print("{any}\n", .{dib_header});

    if (dib_header.width != 4096 or dib_header.height != 16) {
        return BmpError.UnexpectedSize;
    }

    if (bmp_header.ident != 0x4D42) {
        return BmpError.InvalidIndentifier;
    }
}

inline fn hcf() noreturn {
    while (true) {
        asm volatile (
            \\ cli
            \\ hlt
        );
    }
}
