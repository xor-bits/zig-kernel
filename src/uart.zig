const std = @import("std");

const arch = @import("arch.zig");
const lazy = @import("lazy.zig");

//

const outb = arch.x86_64.outb;
const inb = arch.x86_64.inb;
const hcf = arch.hcf;

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

var uart_lazy_init = lazy.LazyInit.new();
fn init() void {
    uart_lazy_init.waitOrInit(Uart.init);
}

const Uart = struct {
    const PORT: u16 = 0x3f8;

    const Self = @This();

    fn init() void {
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

    fn readByte() u8 {
        while (inb(PORT + 5) & 1 == 0) {}
        return inb(PORT);
    }

    fn writeByte(byte: u8) void {
        while (inb(PORT + 5) & 0x20 == 0) {}
        outb(PORT, byte);
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
