const std = @import("std");
const limine = @import("limine");
const font = @import("font");

const main = @import("main.zig");
const lazy = @import("lazy.zig");
const alloc = @import("alloc.zig");
const uart = @import("uart.zig");

//

pub export var framebuffer: limine.FramebufferRequest = .{};

//

const Glyph = font.Glyph;
const glyphs = font.glyphs;

//

var fb_lazy_init = lazy.LazyInit.new();
pub fn print(comptime fmt: []const u8, args: anytype) void {
    fb_lazy_init.getOrInit(init_fb) catch {
        return;
    };

    const FbWriter = struct {
        pub const Error = error{};
        pub const Self = @This();

        pub fn writeAll(_: *const Self, bytes: []const u8) Error!void {
            writeBytes(bytes);
        }

        pub fn writeBytesNTimes(_: *const Self, bytes: []const u8, n: usize) Error!void {
            for (0..n) |_| {
                writeBytes(bytes);
            }
        }
    };

    std.fmt.format(FbWriter{}, fmt, args) catch {};
    flush();
}

var cursor_x: u32 = 0;
var cursor_y: u32 = 0;
var fb: main.Image([*]volatile u8) = undefined;
var terminal_buf: []u8 = undefined;
var terminal_buf_prev: []u8 = undefined;
var terminal_size: struct { w: u32, h: u32 } = undefined;

fn init_fb() void {

    // crash if there is no framebuffer response
    const framebuffer_response = framebuffer.response orelse {
        std.log.scoped(.fb).err("no framebuffer", .{});
        main.hcf();
    };

    // crash if there isn't at least 1 framebuffer
    if (framebuffer_response.framebuffer_count < 1) {
        std.log.scoped(.fb).err("no framebuffer", .{});
        main.hcf();
    }

    const fb_raw = framebuffer_response.framebuffers()[0];
    fb = main.Image([*]volatile u8){
        .width = @intCast(fb_raw.width),
        .height = @intCast(fb_raw.height),
        .pitch = @intCast(fb_raw.pitch),
        .bits_per_pixel = fb_raw.bpp,
        .pixel_array = fb_raw.address,
    };

    terminal_size = .{
        .w = fb.width / 8,
        .h = fb.height / 16,
    };
    const terminal_buf_size = terminal_size.w * terminal_size.h;
    const whole_terminal_buf = alloc.page_allocator.alloc(u8, terminal_buf_size * 2) catch {
        std.log.scoped(.fb).err("OOM", .{});
        main.hcf();
    };

    for (whole_terminal_buf) |*b| {
        b.* = ' ';
    }

    terminal_buf = whole_terminal_buf[0..terminal_buf_size];
    terminal_buf_prev = whole_terminal_buf[terminal_buf_size..];
}

fn writeBytes(bytes: []const u8) void {
    for (bytes) |byte| {
        writeByte(byte);
    }
}

fn writeByte(byte: u8) void {
    switch (byte) {
        '\n' => {
            cursor_x = terminal_size.w;
        },
        ' ' => {
            cursor_x += 1;
        },
        '\t' => {
            cursor_x = std.mem.alignForward(u32, cursor_x + 1, 4);
        },
        else => {
            // uart.print("writing {d} to {d},{d}", .{ byte, cursor_x, cursor_y });
            terminal_buf[cursor_x + cursor_y * terminal_size.w] = byte;
            cursor_x += 1;
        },
    }

    if (cursor_x >= terminal_size.w) {
        // wrap back to a new line
        cursor_x = 0;
        cursor_y += 1;
    }
    if (cursor_y >= terminal_size.h) {
        // scroll down, because the cursor went off screen
        const len = terminal_buf.len;
        cursor_y -= 1;

        std.mem.copyForwards(u8, terminal_buf[0..], terminal_buf[terminal_size.w..]);
        for (terminal_buf[len - terminal_size.w ..]) |*b| {
            b.* = ' ';
        }
    }
}

fn flush() void {
    for (0..terminal_size.h) |_y| {
        for (0..terminal_size.w) |_x| {
            const x: u32 = @truncate(_x);
            const y: u32 = @truncate(_y);

            const i = x + y * terminal_size.w;
            if (terminal_buf[i] == terminal_buf_prev[i]) {
                continue;
            }
            terminal_buf_prev[i] = terminal_buf[i];

            // update the physical pixel
            const letter = &glyphs[terminal_buf[i]];
            var to = fb.subimage(x * 8, y * 16, 8, 16) catch {
                std.log.scoped(.fb).err("fb subimage unexpectedly out of bounds", .{});
                return;
            };
            to.fillGlyph(letter);
        }
    }
}
