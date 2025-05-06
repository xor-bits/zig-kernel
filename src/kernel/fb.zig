const abi = @import("abi");
const font = @import("font");
const limine = @import("limine");
const std = @import("std");

const addr = @import("addr.zig");
const arch = @import("arch.zig");
const caps = @import("caps.zig");
const lazy = @import("lazy.zig");
const pmem = @import("pmem.zig");
const uart = @import("uart.zig");
const util = @import("util.zig");

const volat = util.volat;

//

pub export var framebuffer: limine.FramebufferRequest = .{};

//

pub fn bootInfoInstallFramebuffer(boot_info: *volatile abi.BootInfo, thread: *caps.Thread) void {
    const resp = framebuffer.response orelse return;
    if (resp.framebuffer_count == 0) return;

    const first_fb = resp.framebuffers()[0];
    const fb_paddr = addr.Virt.fromPtr(first_fb.address).hhdmToPhys();
    const bytes: usize = first_fb.height * first_fb.pitch * (std.math.divCeil(usize, first_fb.bpp, 8) catch unreachable);
    const fb_size = abi.ChunkSize.of(bytes) orelse return;

    const fb_obj: caps.Ref(caps.DeviceFrame) = .{ .paddr = caps.DeviceFrame.new(fb_paddr, fb_size) };

    const id = caps.pushCapability(fb_obj.object(thread));
    volat(&boot_info.framebuffer).* = .{ .cap = id };
    volat(&boot_info.framebuffer_width).* = first_fb.width;
    volat(&boot_info.framebuffer_height).* = first_fb.height;
    volat(&boot_info.framebuffer_pitch).* = first_fb.pitch;
    volat(&boot_info.framebuffer_bpp).* = first_fb.bpp;
}

// EVERYTHING BELOW THIS IS JUST FOR THE KERNEL PANIC WRITER

const Glyph = font.Glyph;
const glyphs = font.glyphs;

//

var fb_lazy_init = lazy.Lazy(void).new();
pub fn print(comptime fmt: []const u8, args: anytype) void {
    _ = fb_lazy_init.getOrInit(lazy.fnPtrAsInit(void, init_fb)) orelse {
        return;
    };
    if (!initialized) return;

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

pub fn clear() void {
    _ = fb_lazy_init.getOrInit(lazy.fnPtrAsInit(void, init_fb)) orelse {
        return;
    };
    if (!initialized) return;

    fb.fill(0x880000);
}

var cursor_x: u32 = 0;
var cursor_y: u32 = 0;
var fb: util.Image([*]volatile u8) = undefined;
var terminal_buf: []u8 = undefined;
var terminal_buf_prev: []u8 = undefined;
var terminal_size: struct { w: u32, h: u32 } = undefined;
var initialized: bool = false;

fn init_fb() void {
    const framebuffer_response = framebuffer.response orelse {
        return;
    };

    if (framebuffer_response.framebuffer_count < 1) {
        return;
    }

    const fb_raw = framebuffer_response.framebuffers()[0];
    fb = util.Image([*]volatile u8){
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
    const whole_terminal_buf = pmem.page_allocator.alloc(u8, terminal_buf_size * 2) catch {
        return;
    };

    for (whole_terminal_buf) |*b| {
        b.* = ' ';
    }

    terminal_buf = whole_terminal_buf[0..terminal_buf_size];
    terminal_buf_prev = whole_terminal_buf[terminal_buf_size..];

    initialized = true;
}

fn writeBytes(bytes: []const u8) void {
    for (bytes) |byte| {
        writeByte(byte);
    }
}

var skipping_escape: bool = false;
fn writeByte(byte: u8) void {
    if (skipping_escape and byte != 'm') {
        return;
    } else if (skipping_escape) {
        skipping_escape = false;
        return;
    }

    switch (byte) {
        '\x1B' => {
            skipping_escape = true;
            return;
        },
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
    // var nth: usize = 0;
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
                return;
            };
            to.fillGlyph(letter, 0xFFFFFF, 0x880000);
            // const nth_f = @as(f32, @floatFromInt(nth)) * 0.014232 * std.math.pi;
            // to.fillGlyph(letter, @bitCast([4]u8{
            //     @intFromFloat((std.math.sin(2.0 * nth_f + 0.0 * std.math.pi / 3.0) * 0.5 + 0.5) * 255),
            //     @intFromFloat((std.math.sin(2.0 * nth_f + 2.0 * std.math.pi / 3.0) * 0.5 + 0.5) * 255),
            //     @intFromFloat((std.math.sin(2.0 * nth_f + 4.0 * std.math.pi / 3.0) * 0.5 + 0.5) * 255),
            //     0,
            // }), 0x880000);
            // nth += 1;
        }
    }
}
