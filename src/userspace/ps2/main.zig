const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

pub const std_options = abi.std_options;
pub const panic = abi.panic;
pub const log_level = .info;

const log = std.log.scoped(.ps2);
const Error = abi.sys.Error;
const KeyEvent = abi.input.KeyEvent;
const KeyCode = abi.input.KeyCode;
const KeyState = abi.input.KeyState;

var waiting_lock: abi.lock.YieldMutex = .{};
var waiting: std.ArrayList(caps.Reply) = .init(abi.mem.slab_allocator);

//

pub export var manifest = abi.loader.Manifest.new(.{
    .name = "ps2",
});

pub export var export_ps2 = abi.loader.Resource.new(.{
    .name = "hiillos.ps2.ipc",
    .ty = .receiver,
});

pub export var import_ps2_primary_irq = abi.loader.Resource.new(.{
    .name = "hiillos.ps2.primary_irq",
    .ty = .x86_irq,
    .note = 1,
});

pub export var import_ps2_data_port = abi.loader.Resource.new(.{
    .name = "hiillos.ps2.data_port",
    .ty = .x86_ioport,
    .note = 0x60,
});

pub export var import_ps2_status_port = abi.loader.Resource.new(.{
    .name = "hiillos.ps2.status_port",
    .ty = .x86_ioport,
    .note = 0x64,
});

//

pub fn main() !void {
    log.info("hello from ps2", .{});

    // const port = caps.X86IoPort{ .cap = import_ps2_cmd_port.handle };
    // try port.outb(0xFE);

    log.info("spawning keyboard thread", .{});
    const vmem = try caps.Vmem.self();
    defer vmem.close();
    const proc = try caps.Process.self();
    defer proc.close();
    try abi.loader.spawn(vmem, proc, @intFromPtr(&keyboardMain));

    log.info("ps2 init done, server listening", .{});
    var server = abi.Ps2Protocol.Server(
        .{
            .scope = if (abi.conf.LOG_SERVERS) .ps2 else null,
        },
        .{
            .nextKey = nextKeyHandler,
        },
    ).init({}, caps.Receiver{ .cap = export_ps2.handle });

    var msg: abi.sys.Message = undefined;
    while (true) {
        msg = try server.rx.recv();
        try server.process(&msg);
    }
}

fn nextKeyHandler(_: void, _: u32, _: void) struct { Error!void, KeyCode, KeyState } {
    waiting_lock.lock();
    defer waiting_lock.unlock();

    // FIXME: keyboard inputs can be missed
    // TODO: create IPC pipes for each input listener

    const reply = caps.Reply.create() catch unreachable;

    waiting.append(reply) catch |err| {
        log.err("failed to add a reply cap: {}", .{err});
    };

    // the reply doesnt happen from here
    return undefined;
}

fn keyboardMain() callconv(.SysV) noreturn {
    _ = b: {
        var keyboard = Keyboard.init() catch |err| break :b err;
        keyboard.run() catch |err| break :b err;
    } catch |err| {
        log.err("ps2 server error: {}", .{err});
    };
    @panic("ps2 server died");
}

//

const ControllerConfig = packed struct {
    keyboard_interrupt: enum(u1) { disable, enable },
    mouse_interrupt: enum(u1) { disable, enable },
    system_flag: enum(u1) { post_pass, post_fail },
    zero0: u1 = 0,
    keyboard_clock: enum(u1) { enable, disable }, // yes, they are flipped
    mouse_clock: enum(u1) { enable, disable },
    keyboard_translation: enum(u1) { disable, enable },
    zero1: u1 = 0,
};

const Keyboard = struct {
    /// port 0x60
    data: caps.X86IoPort,
    /// port 0x64
    status: caps.X86IoPort,
    /// irq 1
    notify: caps.Notify,

    is_dual: bool = false,

    state: enum {
        ready,
        ext1,
        ext2,
        release,
        ext1release,
        ext2release,
    } = .ready,

    shift: bool = false,
    caps: bool = false,

    pub fn init() !@This() {
        log.debug("keyboard init", .{});

        const data = caps.X86IoPort{ .cap = import_ps2_data_port.handle };
        errdefer data.close();
        const status = caps.X86IoPort{ .cap = import_ps2_status_port.handle };
        errdefer status.close();
        const irq = caps.X86Irq{ .cap = import_ps2_primary_irq.handle };
        defer irq.close();

        const notify = try irq.subscribe();
        errdefer notify.close();

        var self = @This(){
            .data = data,
            .status = status,
            .notify = notify,
        };

        log.debug("disabling keyboard and mouse temporarily", .{});
        try self.controllerWrite(0xa7); // disable mouse
        try self.controllerWrite(0xad); // disable keyboard

        log.debug("flushing output", .{});

        try self.flush();

        log.debug("reading controller config", .{});
        try self.controllerWrite(0x20);
        log.debug("reading result", .{});
        var config: ControllerConfig = @bitCast(try self.readPoll());
        log.debug("controller config = {}", .{config});
        config.keyboard_translation = .disable;
        config.keyboard_interrupt = .disable;
        config.keyboard_clock = .enable;
        try self.controllerWrite(0x60);
        try self.write(@bitCast(config));

        log.debug("checking mouse support", .{});
        try self.controllerWrite(0xa8); // check mouse support
        try self.controllerWrite(0x20);
        config = @bitCast(try self.readPoll());
        if (config.mouse_clock == .enable) {
            log.debug("has mouse", .{});
            config.mouse_interrupt = .disable;
            config.mouse_clock = .enable;
            try self.controllerWrite(0xa7);
            try self.controllerWrite(0x60);
            try self.write(@bitCast(config));
            self.is_dual = true;
        }

        log.debug("keyboard self test", .{});
        try self.controllerWrite(0xab);
        if (try self.readPoll() != 0)
            return error.KeyboardSelfTestFail;
        if (self.is_dual) {
            log.debug("mouse self test", .{});
            try self.controllerWrite(0xa9);
            if (try self.readPoll() != 0) {
                log.warn("mouse self test fail", .{});
                self.is_dual = false;
            }
        }

        log.debug("enable keyboard and mouse", .{});
        try self.controllerWrite(0xae);
        if (self.is_dual)
            try self.controllerWrite(0xa8);

        try self.flush();

        log.debug("disable scanning", .{});
        for (0..3) |_| {
            try self.write(0xf5);
            if (try check(try self.readWait()) == .resend) continue;
            break;
        } else {
            return error.BadKeyboard;
        }

        try self.flush();

        log.debug("enable interrupts", .{});
        try self.controllerWrite(0x20);
        config = @bitCast(try self.readPoll());
        config.keyboard_interrupt = .enable;
        if (self.is_dual)
            config.mouse_interrupt = .enable;
        try self.controllerWrite(0x60);
        try self.write(@bitCast(config));

        log.debug("reset keyboard", .{});
        try self.write(0xff);
        var res0 = try self.readWait();
        if (res0 == 0xfc)
            return error.KeyboardSelfTestFail;
        var res1 = try self.readWait();
        if (res1 == 0xfc)
            return error.KeyboardSelfTestFail;
        if (!(res0 == 0xfa and res1 == 0xaa) and !(res1 == 0xfa and res0 == 0xaa))
            return error.KeyboardSelfTestFail;
        try self.write(0xf2);
        var device_id = try self.readWait();
        log.debug("keyboard type: {}", .{device_id});
        if (self.is_dual) b: {
            log.debug("reset mouse", .{});
            try self.controllerWrite(0xd4);
            try self.write(0xff);
            res0 = try self.readWait();
            if (res0 == 0xfc) {
                self.is_dual = false;
                break :b;
            }
            res1 = try self.readWait();
            if (res1 == 0xfc) {
                self.is_dual = false;
                break :b;
            }
            if (!(res0 == 0xfa and res1 == 0xaa) and !(res1 == 0xfa and res0 == 0xaa)) {
                self.is_dual = false;
                break :b;
            }
            try self.controllerWrite(0xd4);
            try self.write(0xf2);
            device_id = try self.readWait();
            log.debug("mouse type: {}", .{device_id});
        }

        try self.flush();

        log.debug("disable scanning", .{});
        for (0..3) |_| {
            try self.write(0xf5);
            if (try check(try self.readWait()) == .resend) continue;
            break;
        } else {
            return error.BadKeyboard;
        }

        try self.flush();

        log.debug("setting scancode set", .{});
        for (0..3) |_| {
            try self.write(0xf0); // set current scan code set
            if (try check(try self.readWait()) == .resend) continue;
            try self.write(2); // to 2
            if (try check(try self.readWait()) == .resend) continue;
            // log.debug("{}", .{try self.readWait()});
            break;
        } else {
            return error.BadKeyboard;
        }

        log.debug("setting typematic byte", .{});
        for (0..3) |_| {
            try self.write(0xf3); // set current typematic
            if (try check(try self.readWait()) == .resend) continue;
            try self.write(0b0_01_00010); // to 25hz, 500ms
            if (try check(try self.readWait()) == .resend) continue;
            break;
        } else {
            return error.BadKeyboard;
        }

        log.debug("resetting LEDs", .{});
        for (0..3) |_| {
            try self.write(0xed); // set LEDs
            if (try check(try self.readWait()) == .resend) continue;
            try self.write(0b000); // to all off
            if (try check(try self.readWait()) == .resend) continue;
            break;
        } else {
            return error.BadKeyboard;
        }

        log.debug("enable scanning", .{});
        for (0..3) |_| {
            try self.write(0xF4);
            if (try check(try self.readWait()) == .resend) continue;
            break;
        } else {
            return error.BadKeyboard;
        }

        return self;
    }

    pub fn run(self: *@This()) !void {
        while (true) {
            const inb = try self.readWait();
            if (try self.runOn(inb)) |ev| {
                if (abi.conf.LOG_KEYS)
                    log.info("keyboard ev: {}", .{ev});

                if (ev.code == .print_screen and abi.conf.KERNEL_PANIC_SYSCALL)
                    abi.sys.kernelPanic();

                waiting_lock.lock();
                defer waiting_lock.unlock();

                for (waiting.items) |reply| {
                    abi.Ps2Protocol.replyTo(reply, .nextKey, .{
                        {},
                        ev.code,
                        ev.state,
                    }) catch |err| {
                        log.warn("ps2 failed to reply: {}", .{err});
                    };
                }
                waiting.clearRetainingCapacity();
                // log.info("key event {}", .{ev});
            }
        }
    }

    fn controllerWrite(self: *@This(), byte: u8) !void {
        while (!try self.isInputEmpty()) abi.sys.selfYield();
        try self.status.outb(byte);
    }

    fn write(self: *@This(), byte: u8) !void {
        while (!try self.isInputEmpty()) abi.sys.selfYield();
        try self.data.outb(byte);
    }

    fn flush(self: *@This()) !void {
        while (try self.read()) |_| {}
    }

    fn read(self: *@This()) !?u8 {
        if (!try self.isOutputEmpty()) {
            const b = try self.data.inb();
            log.debug("got byte 0x{x}", .{b});
            return b;
        } else {
            return null;
        }
    }

    fn readWait(self: *@This()) !u8 {
        while (true) {
            if (try self.read()) |byte| return byte;
            try self.wait();
        }
    }

    fn readPoll(self: *@This()) !u8 {
        while (true) {
            if (try self.read()) |byte| return byte;
            abi.sys.selfYield();
        }
    }

    fn isOutputEmpty(self: *@This()) !bool {
        return try self.status.inb() & 0b01 == 0;
    }

    fn isInputEmpty(self: *@This()) !bool {
        return try self.status.inb() & 0b10 == 0;
    }

    fn wait(self: *@This()) !void {
        log.debug("waiting for keyboard interrupt", .{});
        _ = try self.notify.wait();
    }

    fn check(byte: u8) !enum { ack, resend } {
        switch (byte) {
            0xfa => return .ack,
            0xfe => return .resend,
            0x00 => return error.BufferOverrun,
            0xff => return error.KeyDetectionError,
            else => {
                log.err("unexpected response: 0x{x}", .{byte});
                return error.UnexpectedResponse;
            },
        }
    }

    fn runOn(self: *@This(), byte: u8) !?KeyEvent {
        switch (self.state) {
            .ready => {
                if (byte == 0xe0) {
                    self.state = .ext1;
                    return null;
                }
                if (byte == 0xe1) {
                    self.state = .ext2;
                    return null;
                }
                if (byte == 0xf0) {
                    self.state = .release;
                    return null;
                }

                const code = KeyCode.fromScancode0(byte) orelse return null;
                if (code == .too_many_keys or code == .power_on) {
                    return .{ .code = code, .state = .single };
                } else {
                    return .{ .code = code, .state = .press };
                }
            },
            .ext1 => {
                if (byte == 0xf0) {
                    self.state = .ext1release;
                    return null;
                }
                self.state = .ready;
                const code = KeyCode.fromScancode1(byte) orelse return null;
                return .{ .code = code, .state = .press };
            },
            .ext2 => {
                if (byte == 0xf0) {
                    self.state = .ext2release;
                    return null;
                }
                self.state = .ready;
                const code = KeyCode.fromScancode2(byte) orelse return null;
                return .{ .code = code, .state = .press };
            },
            .release => {
                self.state = .ready;
                const code = KeyCode.fromScancode0(byte) orelse return null;
                return .{ .code = code, .state = .release };
            },
            .ext1release => {
                self.state = .ready;
                const code = KeyCode.fromScancode1(byte) orelse return null;
                return .{ .code = code, .state = .release };
            },
            .ext2release => {
                self.state = .ready;
                const code = KeyCode.fromScancode2(byte) orelse return null;
                return .{ .code = code, .state = .release };
            },
        }
    }
};

comptime {
    abi.rt.installRuntime();
}
