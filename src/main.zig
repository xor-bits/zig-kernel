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

    main() catch |err| {
        print("error: {any}", .{err});
    };

    print("done", .{});
    hcf();
}

fn main() !void {
    // crash if there is no framebuffer response
    const framebuffer_response = framebuffer.response orelse {
        return error.NoFramebuffer;
    };

    // crash if there isn't at least 1 framebuffer
    if (framebuffer_response.framebuffer_count < 1) {
        return error.NoFramebuffer;
    }

    const fb_raw = framebuffer_response.framebuffers()[0];
    const fb = Image([*]u8){
        .width = @intCast(fb_raw.width),
        .height = @intCast(fb_raw.height),
        .pitch = @intCast(fb_raw.pitch),
        .bits_per_pixel = fb_raw.bpp,
        .pixel_array = fb_raw.address,
    };

    print("fb: {*}..{*}", .{ fb_raw.address, fb_raw.address + fb_raw.height * fb_raw.pitch });

    var cursor_x: u32 = 50;
    for ("hello world") |b| {
        const letter_f = &glyphs[b];
        var to = try fb.subimage(cursor_x, 50, 8, 16);
        to.fillGlyph(letter_f);
        cursor_x += 8;
    }
}

const glyphs = generateGlyphs();

const Glyph = struct {
    img: [16]u16,
    wide: bool,
};

fn generateGlyphs() [256]Glyph {
    @setEvalBranchQuota(75000);
    const font_raw = try parse_bmp(@embedFile("asset/font.bmp"));
    var font = std.mem.zeroes([256]Glyph);

    for (0..16) |y| {
        for (0..256) |i| {
            for (0..16) |x| {
                // the weird for loop order is for cache locality
                const is_white: u16 =
                    @intCast(@intFromBool(255 != font_raw.pixel_array[x * 3 + i * 16 * 3 + y * font_raw.pitch]));
                font[i].img[15 - y] |= is_white << x;
            }
        }
    }

    for (0..256) |i| {
        for (0..16) |y| {
            if (font[i].img[y] >= 0x100) {
                font[i].wide = true;
                break;
            }
        }
    }

    return font;
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
    Uart.writeByte('\n');
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

        uart_lazy_init.finishInit();
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

    pub fn bytesLeft(self: *const Parser) []const u8 {
        return self.bytes;
    }
};

fn Image(storage: type) type {
    return struct {
        width: u32,
        height: u32,
        pitch: u32,
        bits_per_pixel: u16,
        pixel_array: storage,

        const Self = @This();

        fn debug(self: *const Self) void {
            print("addr: {*}, size: {d}", .{ self.pixel_array, self.height * self.pitch });
        }

        fn subimage(self: *const Self, x: u32, y: u32, w: u32, h: u32) error{OutOfBounds}!Image(@TypeOf(self.pixel_array[0..])) {
            if (self.width < x + w or self.height < y + h) {
                return error.OutOfBounds;
            }

            const offs = x * self.bits_per_pixel / 8 + y * self.pitch;

            return .{
                .width = w,
                .height = h,
                .pitch = self.pitch,
                .bits_per_pixel = self.bits_per_pixel,
                .pixel_array = @ptrCast(self.pixel_array[offs..]),
            };
        }

        fn fill(self: *const Self, r: u8, g: u8, b: u8) void {
            const pixel = [4]u8{ r, g, b, 0 }; // 4 becomes a u32
            const pixel_size = self.bits_per_pixel / 8;

            for (0..self.height) |y| {
                for (0..self.width) |x| {
                    const dst: *[4]u8 = @ptrCast(&self.pixel_array[x * pixel_size + y * self.pitch]);
                    dst.* = pixel;
                }
            }
        }

        fn fillGlyph(self: *const Self, glyph: *const Glyph) void {
            // if (self.width != 16) {
            //     return
            // }

            const pixel_size = self.bits_per_pixel / 8;

            for (0..self.height) |y| {
                for (0..self.width) |x| {
                    const bit: u8 = @truncate((glyph.img[y] >> @intCast(x)) & 1);
                    const is_white: u8 = bit * 255;
                    const dst: *[4]u8 = @ptrCast(&self.pixel_array[x * pixel_size + y * self.pitch]);
                    dst.* = [4]u8{ is_white, is_white, is_white, 0 };
                }
            }
        }

        fn copyTo(from: *const Self, to: anytype) error{ SizeMismatch, BppMismatch }!void {
            if (from.width != to.width or from.height != to.height) {
                return error.SizeMismatch;
            }

            if (from.bits_per_pixel != to.bits_per_pixel) {
                return error.BppMismatch;
            }

            const from_row_width = from.width * from.bits_per_pixel / 8;
            const to_row_width = to.width * to.bits_per_pixel / 8;

            for (0..to.height) |y| {
                const from_row = y * from.pitch;
                const to_row = y * to.pitch;
                const from_row_slice = from.pixel_array[from_row .. from_row + from_row_width];
                const to_row_slice = to.pixel_array[to_row .. to_row + to_row_width];
                std.mem.copyForwards(u8, to_row_slice, from_row_slice);
            }
        }

        fn copyPixelsTo(from: *const Self, to: anytype) error{SizeMismatch}!void {
            if (from.width != to.width or from.height != to.height) {
                return error.SizeMismatch;
            }

            if (from.bits_per_pixel == to.bits_per_pixel) {
                return copyTo(from, to) catch unreachable;
            }

            const from_pixel_size = from.bits_per_pixel / 8;
            const to_pixel_size = to.bits_per_pixel / 8;

            for (0..to.height) |y| {
                for (0..to.width) |x| {
                    const from_idx = x * from_pixel_size + y * from.pitch;
                    const from_pixel: *const Pixel = @ptrCast(&from.pixel_array[from_idx]);

                    const to_idx = x * to_pixel_size + y * to.pitch;
                    const to_pixel: *Pixel = @ptrCast(&to.pixel_array[to_idx]);

                    // print("loc: {d},{d}", .{ x, y });
                    // print("from: {*} to: {*}", .{ from_pixel, to_pixel });

                    to_pixel.* = from_pixel.*;
                }
            }
        }

        // fn pixel_at(x: u32, y: u32) void {}
    };
}

const Pixel = struct {
    red: u8,
    green: u8,
    blue: u8,
};

fn parse_bmp(bmp: []const u8) !Image([]const u8) {
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
        image_size: u32,
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

    // TODO: if either is zero
    if (dib_header.width != 4096 or dib_header.height != 16) {
        return BmpError.UnexpectedSize;
    }

    if (bmp_header.ident != 0x4D42) {
        return BmpError.InvalidIndentifier;
    }

    if (bmp.len < bmp_header.offs + dib_header.image_size) {
        return BmpError.UnexpectedEof;
    }

    return .{
        .width = dib_header.width,
        .height = dib_header.height,
        .pitch = dib_header.image_size / dib_header.height,
        .bits_per_pixel = dib_header.bits_per_pixel,
        .pixel_array = @constCast(bmp[bmp_header.offs .. bmp_header.offs + dib_header.image_size]),
    };
}

inline fn hcf() noreturn {
    while (true) {
        asm volatile (
            \\ cli
            \\ hlt
        );
    }
}
