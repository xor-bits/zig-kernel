const std = @import("std");
const limine = @import("limine");

const font = @import("font");

const uart = @import("uart.zig");
const lazy = @import("lazy.zig");

//

const Glyph = font.Glyph;
const glyphs = font.glyphs;

//

pub export var framebuffer: limine.FramebufferRequest = .{};

pub export var base_revision: limine.BaseRevision = .{ .revision = 2 };

pub export var memory: limine.MemoryMapRequest = .{};

//

export fn _start() callconv(.C) noreturn {
    // crash if bootloader is unsupported
    if (!base_revision.is_supported()) {
        uart.print("bootloader unsupported", .{});
        hcf();
    }

    main() catch |err| {
        print("error: {any}", .{err});
    };

    print("done", .{});
    hcf();
}

fn main() !void {
    print("kernel main", .{});

    // TODO: page allocator
    // TODO: GDT + IDT
    // TODO: virtual memory mapper
    // TODO: cpu locals (rdpid, rdtscp)
    // TODO: ACPI + APIC + HPET
    // TODO: scheduler
    // TODO: flat binary loader
    // TODO: userland
    // TODO: syscalls
    // TODO: IPC
    // TODO: elf64 loader
    // TODO: RDRAND,RDSEED,PRNG,CRNG
    // TODO: vfs
    // TODO: ps2 interrupts (kb&m)
    // TODO: RTC time
    // TODO: PCIe
    // TODO: USB
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    uart.print(fmt, args);

    const FbWriter = struct {
        pub const Error = error{OutOfBounds};
        pub const Self = @This();

        pub fn writeAll(_: *const Self, bytes: []const u8) Error!void {
            for (bytes) |b| {
                if (b == '\n') {
                    cursor_x = 5;
                    cursor_y += 16;
                    continue;
                }

                const letter = &glyphs[b];
                var to = try fb.subimage(cursor_x, cursor_y, 8, 16);
                to.fillGlyph(letter);
                cursor_x += 8;
            }
        }

        pub fn writeBytesNTimes(self: *const Self, bytes: []const u8, n: usize) !void {
            for (0..n) |_| {
                try self.writeAll(bytes);
            }
        }
    };

    fb_lazy_init.waitOrInit(init_fb);
    std.fmt.format(FbWriter{}, fmt, args) catch {};
    std.fmt.format(FbWriter{}, "\n", .{}) catch {};
}

fn init_fb() void {
    // crash if there is no framebuffer response
    const framebuffer_response = framebuffer.response orelse {
        uart.print("no framebuffer", .{});
        hcf();
    };

    // crash if there isn't at least 1 framebuffer
    if (framebuffer_response.framebuffer_count < 1) {
        uart.print("no framebuffer", .{});
        hcf();
    }

    const fb_raw = framebuffer_response.framebuffers()[0];
    fb = Image([*]volatile u8){
        .width = @intCast(fb_raw.width),
        .height = @intCast(fb_raw.height),
        .pitch = @intCast(fb_raw.pitch),
        .bits_per_pixel = fb_raw.bpp,
        .pixel_array = fb_raw.address,
    };
}

var cursor_x: u32 = 5;
var cursor_y: u32 = 5;
var fb: Image([*]volatile u8) = undefined;
var fb_lazy_init = lazy.LazyInit.new();

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
                    const dst: *volatile [4]u8 = @ptrCast(&self.pixel_array[x * pixel_size + y * self.pitch]);
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
    };
}

const Pixel = struct {
    red: u8,
    green: u8,
    blue: u8,
};

pub inline fn hcf() noreturn {
    while (true) {
        asm volatile (
            \\ cli
            \\ hlt
        );
    }
}

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
