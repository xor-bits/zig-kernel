const std = @import("std");

const main = @import("main.zig");
const lazy = @import("lazy.zig");

//

pub fn print(comptime fmt: []const u8, args: anytype) void {
    init();

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

    std.fmt.format(UartWriter{}, fmt, args) catch {};
}

fn init() void {
    uart_lazy_init.waitOrInit(Uart.init);
}

var uart_lazy_init = lazy.LazyInit.new();

const Uart = struct {
    const PORT: u16 = 0x3f8;

    const Self = @This();

    fn init() void {
        main.outb(PORT + 1, 0x00);
        main.outb(PORT + 3, 0x80);
        main.outb(PORT + 0, 0x03);
        main.outb(PORT + 1, 0x00);
        main.outb(PORT + 3, 0x03);
        main.outb(PORT + 2, 0xc7);
        main.outb(PORT + 4, 0x0b);
        main.outb(PORT + 4, 0x1e);
        main.outb(PORT + 0, 0xae);

        if (main.inb(PORT + 0) != 0xAE) {
            main.hcf();
        }

        main.outb(PORT + 4, 0x0f);
    }

    fn readByte() u8 {
        while (main.inb(PORT + 5) & 1 == 0) {}
        return main.inb(PORT);
    }

    fn writeByte(byte: u8) void {
        while (main.inb(PORT + 5) & 0x20 == 0) {}
        main.outb(PORT, byte);
    }

    fn writeAll(bytes: []const u8) void {
        for (bytes) |byte| {
            Self.writeByte(byte);
        }
    }

    fn writeBytesNTimes(bytes: []const u8, times: usize) void {
        for (0..times) |_| {
            Self.writeAll(bytes);
        }
    }
};
