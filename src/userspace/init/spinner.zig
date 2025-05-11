const abi = @import("abi");
const std = @import("std");

const main = @import("main.zig");

//

const log = std.log.scoped(.spinner);
const caps = abi.caps;
const Error = abi.sys.Error;
const dark_mode: bool = true;

//

pub fn spinnerMain() !void {
    log.info("starting spinner thread", .{});

    var res: Error!void, const framebuffer: caps.DeviceFrame, const framebuffer_info: caps.Frame =
        try main.rm.call(.requestFramebuffer, {});
    try res;

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

    res, const key_thread: caps.Thread = try main.pm.call(.spawn, .{ @intFromPtr(&tickKey), 0 });
    try res;

    try key_thread.start();

    framebufferSplash(
        @ptrFromInt(fb_addr),
        @ptrFromInt(fb_info_addr),
    ) catch |err| {
        log.warn("spinner failed: {}", .{err});
    };
    abi.sys.stop();
}

var dir: std.atomic.Value(i32) = .init(1);

fn tickKey() noreturn {
    while (true) {
        const res, _, const state: abi.input.KeyState = main.input.call(.nextKey, {}) catch break;
        res catch break;

        if (state == .release) continue;
        _ = dir.fetchXor(1, .seq_cst);
    }

    abi.sys.stop();
}

fn framebufferSplash(
    framebuffer: [*]volatile u32,
    framebuffer_info: *const abi.FramebufferInfoFrame,
) !void {
    if (framebuffer_info.bpp != 32) {
        log.warn("unrecognized framebuffer format", .{});
        return;
    }

    const width = framebuffer_info.width;
    const height = framebuffer_info.height;
    const pitch = framebuffer_info.pitch / 4;

    const res: Error!void, const backbuffer_addr = try main.pm.call(
        .growHeap,
        .{4 * FbInfo.width * FbInfo.height},
    );
    try res;

    const fb_info: FbInfo = .{
        .buffer = @as([*]u32, @ptrFromInt(backbuffer_addr))[0 .. FbInfo.width * FbInfo.height],
        .fb_width = width,
        .fb_height = height,
        .fb_pitch = pitch,
        .fb = framebuffer[0 .. width * pitch],
    };

    @memset(fb_info.fb, if (dark_mode) 0x0 else 0xFFFFFF);
    @memset(fb_info.buffer, if (dark_mode) 0x0 else 0xFFFFFF);

    log.info("done", .{});

    const mid_x = width / 2;
    const mid_y = height / 2;

    const _nanos = try main.timer.call(.timestamp, {});
    var nanos: u128 = _nanos.@"0";
    var phase: i128 = 0;
    while (true) {
        drawFrame(&fb_info, mid_x, mid_y, @floatCast(@as(f64, @floatFromInt(phase)) / 1_000_000.0));

        phase += (dir.load(.monotonic) * 2 - 1) * 16_666_667;
        nanos += 16_666_667;
        _ = main.timer.call(.sleepDeadline, .{nanos}) catch break;
    }
}

const speed: f32 = 0.001;

const FbInfo = struct {
    const width = 480;
    const height = 480;

    buffer: []u32,

    fb_width: usize,
    fb_height: usize,
    fb_pitch: usize,
    fb: []volatile u32,
};

fn drawFrame(fb: *const FbInfo, mid_x: usize, mid_y: usize, millis: f32) void {
    dim(fb);

    for (0..20) |i| {
        const phase = @as(f32, @floatFromInt(i)) / 20.0;
        drawTriangleDot(fb, FbInfo.width / 2, FbInfo.height / 2, phase * 3.0 - millis * speed, millis, 0xFF8000);
    }

    blit(fb, mid_x, mid_y);
}

fn dim(fb: *const FbInfo) void {
    for (0..FbInfo.height) |y| {
        for (0..FbInfo.width) |x| {
            var col: Pixel = @bitCast(fb.buffer[x + y * FbInfo.width]);
            if (dark_mode) {
                col.r = @max(col.r, 10) - 10;
                col.g = @max(col.g, 10) - 10;
                col.b = @max(col.b, 10) - 10;
            } else {
                col.r = @min(col.r, 245) + 10;
                col.g = @min(col.g, 245) + 10;
                col.b = @min(col.b, 245) + 10;
            }
            fb.buffer[x + y * FbInfo.width] = @bitCast(col);
        }
    }
}

fn blit(fb: *const FbInfo, mid_x: usize, mid_y: usize) void {
    for (0..FbInfo.height / 2) |y| {
        for (0..FbInfo.width / 2) |x| {
            const px0: Pixel = @bitCast(fb.buffer[(x * 2 + 0) + (y * 2 + 0) * FbInfo.width]);
            const px1: Pixel = @bitCast(fb.buffer[(x * 2 + 1) + (y * 2 + 0) * FbInfo.width]);
            const px2: Pixel = @bitCast(fb.buffer[(x * 2 + 0) + (y * 2 + 1) * FbInfo.width]);
            const px3: Pixel = @bitCast(fb.buffer[(x * 2 + 1) + (y * 2 + 1) * FbInfo.width]);

            const multisampled = Pixel{
                .r = @truncate((@as(u16, px0.r) + px1.r + px2.r + px3.r) / 4),
                .g = @truncate((@as(u16, px0.g) + px1.g + px2.g + px3.g) / 4),
                .b = @truncate((@as(u16, px0.b) + px1.b + px2.b + px3.b) / 4),
            };

            // const target_x = x;
            // const target_y = y;
            // _ = .{ mid_x, mid_y };
            const target_x = x + mid_x - FbInfo.width / 4;
            const target_y = y + mid_y - FbInfo.height / 4;
            fb.fb[target_x + target_y * fb.fb_pitch] =
                @bitCast(multisampled);
        }
    }
}

const Pixel = extern struct {
    r: u8,
    g: u8,
    b: u8,
    _p: u8 = 0,
};

fn drawTriangleDot(fb: *const FbInfo, mid_x: usize, mid_y: usize, t: f32, millis: f32, col: u32) void {
    const a = (std.math.floor(t) + millis * speed) * 2.0 * std.math.pi / 3.0;
    const b = (std.math.ceil(t) + millis * speed) * 2.0 * std.math.pi / 3.0;
    const ft = t - std.math.floor(t);

    const pt_x = ft * std.math.cos(b) + (1.0 - ft) * std.math.cos(a);
    const pt_y = ft * std.math.sin(b) + (1.0 - ft) * std.math.sin(a);

    drawDot(
        fb,
        @as(usize, @intFromFloat(pt_x * 120.0 + @as(f32, @floatFromInt(mid_x)))),
        @as(usize, @intFromFloat(pt_y * 120.0 + @as(f32, @floatFromInt(mid_y)))),
        col,
    );
}

fn drawDot(fb: *const FbInfo, mid_x: usize, mid_y: usize, col: u32) void {
    const minx = @max(mid_x, 10) - 10;
    const miny = @max(mid_y, 10) - 10;
    const maxx = mid_x + 11;
    const maxy = mid_y + 11;

    for (miny..maxy) |y| {
        for (minx..maxx) |x| {
            const dx = if (mid_x > x) mid_x - x else x - mid_x;
            const dy = if (mid_y > y) mid_y - y else y - mid_y;
            const dsqr = dx * dx + dy * dy;

            if (dsqr <= 7 * 7 - 3) {
                fb.buffer[x + y * FbInfo.width] = col;
            }
        }
    }
}
