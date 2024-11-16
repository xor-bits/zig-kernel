const std = @import("std");
const limine = @import("limine");
const font = @import("font");

const main = @import("main.zig");
const lazy = @import("lazy.zig");

//

pub export var framebuffer: limine.FramebufferRequest = .{};

//

const Glyph = font.Glyph;
const glyphs = font.glyphs;

//

pub fn print(comptime fmt: []const u8, args: anytype) void {
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
}

var cursor_x: u32 = 5;
var cursor_y: u32 = 5;
var fb: main.Image([*]volatile u8) = undefined;
var fb_lazy_init = lazy.LazyInit.new();

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
}
