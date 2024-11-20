const std = @import("std");
const limine = @import("limine");
const Glyph = @import("font").Glyph;

const uart = @import("uart.zig");
const fb = @import("fb.zig");
const lazy = @import("lazy.zig");
const pmem = @import("pmem.zig");
const arch = @import("arch.zig");
const acpi = @import("acpi.zig");
const NumberPrefix = @import("byte_fmt.zig").NumberPrefix;

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
    const log = std.log.scoped(.panic);

    if (ret_addr) |at| {
        log.err("CPU panicked at 0x{x}:\n{s}", .{ at, msg });
    } else {
        log.err("CPU panicked:\n{s}", .{msg});
    }

    arch.hcf();
}

//

pub export var base_revision: limine.BaseRevision = .{ .revision = 2 };
pub export var hhdm: limine.HhdmRequest = .{};

pub var hhdm_offset = std.atomic.Value(usize).init(undefined);

//

export fn _start() callconv(.C) noreturn {
    const log = std.log.scoped(.critical);

    // crash if bootloader is unsupported
    if (!base_revision.is_supported()) {
        log.err("bootloader unsupported", .{});
        arch.hcf();
    }

    const hhdm_response = hhdm.response orelse {
        log.err("no HHDM", .{});
        arch.hcf();
    };
    hhdm_offset.store(hhdm_response.offset, .seq_cst);
    @fence(.seq_cst);

    main();
    arch.hcf();
}

// pub fn blackBox(comptime T: type, value: anytype) T {
//     asm volatile ("" ::: "memory");
//     return value;
// }

fn main() void {
    const log = std.log.scoped(.main);

    log.info("kernel main", .{});

    pmem.printInfo();
    log.info("used memory: {any}B", .{
        NumberPrefix(usize, .binary).new(pmem.usedPages() << 12),
    });
    log.info("free memory: {any}B", .{
        NumberPrefix(usize, .binary).new(pmem.freePages() << 12),
    });
    log.info("total memory: {any}B", .{
        NumberPrefix(usize, .binary).new(pmem.totalPages() << 12),
    });

    arch.init() catch |err| {
        std.debug.panic("failed to initialize CPU: {any}", .{err});
    };

    arch.x86_64.ints.int3();

    acpi.init() catch |err| {
        std.debug.panic("failed to initialize ACPI: {any}", .{err});
    };

    log.info("done", .{});

    // NOTE: /path/to/something is a short form for fs:///path/to/something
    // TODO: kernel
    //  - virtual memory mapping
    //  - ACPI, APIC, HPET
    //  - scheduler
    //  - binary loader
    //  - message IPC, shared memory IPC
    //  - userland
    //  - figure out userland interrupts (ps2 keyboard, ..)
    //  - syscalls:
    //    - syscall for bootstrap to grow the heap
    //    - syscall to print logs
    //    - syscall to exec a binary (based on a provided mem map)
    //    - syscall to create a vfs proto
    //    - syscall to accept a vfs proto cmd
    //    - syscall to return a vfs proto cmd result
    //    - syscall to read the root kernel cli arg
    //    - syscalls for unix sockets
    //
    // TODO: bootstrap/initfsd process
    //  - map flat binary to 0x200_000
    //  - map initfs.tar.gz to 0x400_000
    //  - map heap to 0x1_000_000
    //  - enter bootstrap in ring3
    //  - inflate&initialize initfs in heap
    //  - create initfs:// vfs proto
    //  - exec flat binary initfs:///sbin/initd
    //  - rename to initfsd
    //  - start processing vfs proto cmds
    //
    // TODO: initfs:///sbin/initd process
    //  - launch initfs:///sbin/rngd
    //  - launch initfs:///sbin/vfsd
    //  - launch services from initfs://
    //  // - launch /bin/wm
    //
    // TODO: initfs:///sbin/rngd process
    //  - create rng:// vfs proto
    //  - start processing vfs proto cmds
    //
    // TODO: /sbin/inputd process
    //
    // TODO: /sbin/outputd process
    //
    // TODO: /sbin/kbd process
    //
    // TODO: /sbin/moused process
    //
    // TODO: /sbin/timed process
    //
    // TODO: /sbin/fbd process
    //
    // TODO: /sbin/pcid process
    //
    // TODO: /sbin/usbd process
    //
    // TODO: initfs:///sbin/vfsd process
    //  - create fs:// vfs proto
    //  - get the root device with syscall (either device or fstab for initfs:///etc/fstab)
    //  - exec required root filesystem drivers
    //  - mount root (root= kernel cli arg) to /
    //  - remount root using /etc/fstab
    //  - exec other filesystem drivers lazily
    //  - mount everything according to /etc/fstab
    //  - start processing vfs proto cmds
    //
    // TODO: initfs:///sbin/fsd.fat32
    //  - connect to the /sbin/vfsd process using a unix socket
    //  - register a fat32 filesystem
    //  - start processing cmds
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
