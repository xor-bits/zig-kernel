const abi = @import("abi");
const std = @import("std");

const main = @import("main.zig");

//

const log = std.log.scoped(.spinner);
const caps = abi.caps;
const Error = abi.sys.Error;

//

pub fn spinnerMain() !void {
    log.info("starting spinner thread", .{});

    var res: Error!void, const framebuffer: caps.DeviceFrame, const framebuffer_info: caps.Frame =
        try main.rm.call(.requestFramebuffer, {});
    try res;

    const fb_dev_size = try framebuffer.sizeOf();

    res, const fb_addr, _ = try main.pm.call(.mapDeviceFrame, .{
        framebuffer,
        abi.sys.Rights{ .writable = true },
        abi.sys.MapFlags{ .cache = .write_combining },
    });
    try res;

    res, const fb_info_addr, _ = try main.pm.call(.mapFrame, .{
        framebuffer_info,
        abi.sys.Rights{},
        abi.sys.MapFlags{},
    });
    try res;

    framebufferSplash(
        fb_dev_size,
        @ptrFromInt(fb_addr),
        @ptrFromInt(fb_info_addr),
    ) catch |err| {
        log.warn("spinner failed: {}", .{err});
    };
    abi.sys.stop();
}

fn framebufferSplash(
    fb_dev_size: abi.ChunkSize,
    framebuffer: [*]volatile u32,
    framebuffer_info: *const abi.FramebufferInfoFrame,
) !void {
    const res: Error!void, const backbuffer_addr = try main.pm.call(.growHeap, .{fb_dev_size.sizeBytes()});
    try res;

    if (framebuffer_info.bpp != 32) {
        log.warn("unrecognized framebuffer format", .{});
        return;
    }

    const width = framebuffer_info.width;
    const height = framebuffer_info.height;
    const pitch = framebuffer_info.pitch / 4;
    const backbuffer = @as([*]u32, @ptrFromInt(backbuffer_addr))[0 .. width * pitch];

    const fb_info: FbInfo = .{
        .width = width,
        .height = height,
        .pitch = pitch,
        .buffer = backbuffer,
        .framebuffer = framebuffer[0 .. width * pitch],
    };

    const mid_x = width / 2;
    const mid_y = height / 2;

    var millis: f32 = 0.0;
    while (true) {
        drawFrame(&fb_info, mid_x, mid_y, millis);
        millis += 10.0;
        _ = try main.timer.call(.sleep, .{10_000_000});
        // abi.sys.yield();
    }
}

const speed: f32 = 0.001;

const FbInfo = struct {
    width: usize,
    height: usize,
    pitch: usize,
    buffer: []u32,
    framebuffer: []volatile u32,
};

fn drawFrame(fb: *const FbInfo, mid_x: usize, mid_y: usize, millis: f32) void {
    dim(fb, mid_x, mid_y);

    for (0..20) |i| {
        const phase = @as(f32, @floatFromInt(i)) / 20.0;
        drawTriangleDot(fb, mid_x, mid_y, phase * 3.0 - millis * speed, millis, 0xFF8000);
    }

    blit(fb, mid_x, mid_y);
}

fn dim(fb: *const FbInfo, mid_x: usize, mid_y: usize) void {
    const minx = @max(mid_x, 120) - 120;
    const miny = @max(mid_y, 120) - 120;
    const maxx = mid_x + 121;
    const maxy = mid_y + 121;

    for (miny..maxy) |y| {
        for (minx..maxx) |x| {
            var col: Pixel = @bitCast(fb.buffer[x + y * fb.pitch]);
            col.r = @max(col.r, 7) - 7;
            col.g = @max(col.g, 7) - 7;
            col.b = @max(col.b, 7) - 7;
            fb.buffer[x + y * fb.pitch] = @bitCast(col);
        }
    }
}

fn blit(fb: *const FbInfo, mid_x: usize, mid_y: usize) void {
    const minx = @max(mid_x, 120) - 120;
    const miny = @max(mid_y, 120) - 120;
    const maxx = mid_x + 121;
    const maxy = mid_y + 121;

    for (miny..maxy) |y| {
        for (minx..maxx) |x| {
            fb.framebuffer[x + y * fb.pitch] = fb.buffer[x + y * fb.pitch];
        }
    }
}

const Pixel = extern struct {
    r: u8,
    g: u8,
    b: u8,
    _p: u8,
};

fn drawTriangleDot(fb: *const FbInfo, mid_x: usize, mid_y: usize, t: f32, millis: f32, col: u32) void {
    const a = (std.math.floor(t) + millis * speed) * 2.0 * std.math.pi / 3.0;
    const b = (std.math.ceil(t) + millis * speed) * 2.0 * std.math.pi / 3.0;
    const ft = t - std.math.floor(t);

    const pt_x = ft * std.math.cos(b) + (1.0 - ft) * std.math.cos(a);
    const pt_y = ft * std.math.sin(b) + (1.0 - ft) * std.math.sin(a);

    drawDot(
        fb,
        @as(usize, @intFromFloat(pt_x * 60.0 + @as(f32, @floatFromInt(mid_x)))),
        @as(usize, @intFromFloat(pt_y * 60.0 + @as(f32, @floatFromInt(mid_y)))),
        col,
    );
}

fn drawDot(fb: *const FbInfo, mid_x: usize, mid_y: usize, col: u32) void {
    const minx = @max(mid_x, 5) - 5;
    const miny = @max(mid_y, 5) - 5;
    const maxx = mid_x + 6;
    const maxy = mid_y + 6;

    for (miny..maxy) |y| {
        for (minx..maxx) |x| {
            const dx = if (mid_x > x) mid_x - x else x - mid_x;
            const dy = if (mid_y > y) mid_y - y else y - mid_y;
            const dsqr = dx * dx + dy * dy;

            if (dsqr <= 3 * 3 - 2) {
                fb.buffer[x + y * fb.pitch] = col;
            } else if (dsqr <= 3 * 3 + 2) {
                // fb.buffer[x + y * fb.pitch] = (col >> 4) & 0x0F0F0F0F;
            }
        }
    }
}
