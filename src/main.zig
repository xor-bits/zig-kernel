const std = @import("std");
const limine = @import("limine");
const Glyph = @import("font").Glyph;

const uart = @import("uart.zig");
const fb = @import("fb.zig");
const lazy = @import("lazy.zig");
const mem = @import("alloc.zig");
const arch = @import("arch.zig");
const NumberPrefix = @import("byte_fmt.zig").NumberPrefix;

const log = std.log;

//

pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn logFn(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const level_txt = comptime message_level.asText();
    const scope_txt = if (scope == .default) "" else " " ++ @tagName(scope);
    const fmt = "[ " ++ level_txt ++ scope_txt ++ " ]: " ++ format ++ "\n";

    uart.print(fmt, args);
    if (scope != .critical) {
        fb.print(fmt, args);
    }
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    log.scoped(.panic).err("CPU panicked: {s} ({?x})", .{ msg, ret_addr });
    arch.hcf();
}

//

pub export var base_revision: limine.BaseRevision = .{ .revision = 2 };
pub export var hhdm: limine.HhdmRequest = .{};

pub var hhdm_offset: usize = undefined;

//

export fn _start() callconv(.C) noreturn {
    // crash if bootloader is unsupported
    if (!base_revision.is_supported()) {
        log.scoped(.critical).err("bootloader unsupported", .{});
        arch.hcf();
    }

    const hhdm_response = hhdm.response orelse {
        log.scoped(.critical).err("no HHDM", .{});
        arch.hcf();
    };
    hhdm_offset = hhdm_response.offset;

    main() catch |err| {
        log.scoped(._start).err("failed to initialize: {any}", .{err});
    };

    log.scoped(._start).info("done", .{});
    arch.hcf();
}

// pub fn blackBox(comptime T: type, value: anytype) T {
//     asm volatile ("" ::: "memory");
//     return value;
// }

fn main() !void {
    log.scoped(.main).info("kernel main", .{});

    mem.printInfo();
    log.scoped(.main).info("used memory: {any}B", .{
        NumberPrefix(usize, .binary).new(mem.usedPages() << 12),
    });
    log.scoped(.main).info("free memory: {any}B", .{
        NumberPrefix(usize, .binary).new(mem.freePages() << 12),
    });
    log.scoped(.main).info("total memory: {any}B", .{
        NumberPrefix(usize, .binary).new(mem.totalPages() << 12),
    });

    try arch.init();

    arch.x86_64.ints.int3();

    arch.reset();

    asm volatile (
        \\ mov %rax, (0)
    );

    // TODO: virtual memory mapper
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

pub fn Image(storage: type) type {
    return struct {
        width: u32,
        height: u32,
        pitch: u32,
        bits_per_pixel: u16,
        pixel_array: storage,

        const Self = @This();

        pub fn debug(self: *const Self) void {
            std.log.debug("addr: {*}, size: {d}", .{ self.pixel_array, self.height * self.pitch });
        }

        pub fn subimage(self: *const Self, x: u32, y: u32, w: u32, h: u32) error{OutOfBounds}!Image(@TypeOf(self.pixel_array[0..])) {
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

        pub fn fill(self: *const Self, r: u8, g: u8, b: u8) void {
            const pixel = [4]u8{ r, g, b, 0 }; // 4 becomes a u32
            const pixel_size = self.bits_per_pixel / 8;

            for (0..self.height) |y| {
                for (0..self.width) |x| {
                    const dst: *[4]u8 = @ptrCast(&self.pixel_array[x * pixel_size + y * self.pitch]);
                    dst.* = pixel;
                }
            }
        }

        pub fn fillGlyph(self: *const Self, glyph: *const Glyph) void {
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

        pub fn copyTo(from: *const Self, to: anytype) error{ SizeMismatch, BppMismatch }!void {
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

        pub fn copyPixelsTo(from: *const Self, to: anytype) error{SizeMismatch}!void {
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
