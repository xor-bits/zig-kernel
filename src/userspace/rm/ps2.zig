const abi = @import("abi");
const std = @import("std");

const main = @import("main.zig");

const caps = abi.caps;
const log = std.log.scoped(.ps2);

//

pub fn keyboardThread(self: caps.Thread) callconv(.SysV) noreturn {
    keyboardThreadMain() catch |err| {
        log.err("keyboard thread error: {}", .{err});
    };
    self.stop() catch {};
    unreachable;
}

pub fn keyboardThreadMain() !void {
    var keyboard = try Keyboard.init();
    try keyboard.run();
}

const KeyCode = enum(u8) {
    escape,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,

    print_screen,
    sysrq,
    scroll_lock,
    pause_break,

    /// backtick `~
    oem8,
    key1,
    key2,
    key3,
    key4,
    key5,
    key6,
    key7,
    key8,
    key9,
    key0,
    /// -_
    oem_minus,
    /// =+
    oem_plus,
    backspace,

    insert,
    home,
    page_up,

    numpad_lock,
    numpad_div,
    numpad_mul,
    numpad_sub,

    tab,
    q,
    w,
    e,
    r,
    t,
    y,
    u,
    i,
    o,
    p,
    /// [{
    oem4,
    /// ]}
    oem6,
    /// \|
    oem5,
    /// #~ ISO layout
    oem7,

    delete,
    end,
    page_down,

    numpad7,
    numpad8,
    numpad9,
    numpad_add,

    caps_lock,
    a,
    s,
    d,
    f,
    g,
    h,
    j,
    k,
    l,
    /// ;:
    oem1,
    /// '"
    oem3,

    enter,

    numpad4,
    numpad5,
    numpad6,

    left_shift,
    z,
    x,
    c,
    v,
    b,
    n,
    m,
    /// ,<
    oem_comma,
    /// .>
    oem_period,
    /// /?
    oem2,
    right_shift,

    arrow_up,

    numpad1,
    numpad2,
    numpad3,
    numpad_enter,

    left_control,
    left_super,
    left_alt,
    space,
    right_altgr,
    right_super,
    menu,
    right_control,

    arrow_left,
    arrow_down,
    arrow_right,

    numpad0,
    numpad_period,

    oem9,
    oem10,
    oem11,
    oem12,
    oem13,

    prev_track,
    next_track,
    mute,
    calculator,
    play,
    stop,
    volume_down,
    volume_up,
    browser,

    power_on,
    too_many_keys,
    right_control2,
    right_alt2,

    pub fn fromScancode0(code: u8) ?@This() {
        return switch (code) {
            0x00 => .too_many_keys,
            0x01 => .f9,
            0x03 => .f5,
            0x04 => .f3,
            0x05 => .f1,
            0x06 => .f2,
            0x07 => .f12,
            0x09 => .f10,
            0x0a => .f8,
            0x0b => .f6,
            0x0c => .f4,
            0x0d => .tab,
            0x0e => .oem8,
            0x11 => .left_alt,
            0x12 => .left_shift,
            0x13 => .oem11,
            0x14 => .left_control,
            0x15 => .q,
            0x16 => .key1,
            0x1a => .z,
            0x1b => .s,
            0x1c => .a,
            0x1d => .w,
            0x1e => .key2,
            0x21 => .c,
            0x22 => .x,
            0x23 => .d,
            0x24 => .e,
            0x25 => .key4,
            0x26 => .key3,
            0x29 => .space,
            0x2a => .v,
            0x2b => .f,
            0x2c => .t,
            0x2d => .r,
            0x2e => .key5,
            0x31 => .n,
            0x32 => .b,
            0x33 => .h,
            0x34 => .g,
            0x35 => .y,
            0x36 => .key6,
            0x3a => .m,
            0x3b => .j,
            0x3c => .u,
            0x3d => .key7,
            0x3e => .key8,
            0x41 => .oem_comma,
            0x42 => .k,
            0x43 => .i,
            0x44 => .o,
            0x45 => .key0,
            0x46 => .key9,
            0x49 => .oem_period,
            0x4a => .oem2,
            0x4b => .l,
            0x4c => .oem1,
            0x4d => .p,
            0x4e => .oem_minus,
            0x51 => .oem12,
            0x52 => .oem3,
            0x54 => .oem4,
            0x55 => .oem_plus,
            0x58 => .caps_lock,
            0x59 => .right_shift,
            0x5a => .enter,
            0x5b => .oem6,
            0x5d => .oem7,
            0x61 => .oem5,
            0x64 => .oem10,
            0x66 => .backspace,
            0x67 => .oem9,
            0x69 => .numpad1,
            0x6a => .oem13,
            0x6b => .numpad4,
            0x6c => .numpad7,
            0x70 => .numpad0,
            0x71 => .numpad_period,
            0x72 => .numpad2,
            0x73 => .numpad5,
            0x74 => .numpad6,
            0x75 => .numpad8,
            0x76 => .escape,
            0x77 => .numpad_lock,
            0x78 => .f11,
            0x79 => .numpad_add,
            0x7a => .numpad3,
            0x7b => .numpad_sub,
            0x7c => .numpad_mul,
            0x7d => .numpad9,
            0x7e => .scroll_lock,
            0x7f => .sysrq,
            0x83 => .f7,
            0xaa => .power_on,
            else => null,
        };
    }

    /// prefixed with 0xe0
    pub fn fromScancode1(code: u8) ?@This() {
        return switch (code) {
            0x11 => .right_altgr,
            0x12 => .right_alt2,
            0x14 => .right_control,
            0x15 => .prev_track,
            0x1f => .left_super,
            0x21 => .volume_down,
            0x23 => .mute,
            0x27 => .right_super,
            0x2b => .calculator,
            0x2f => .menu,
            0x32 => .volume_up,
            0x34 => .play,
            0x3a => .browser,
            0x3b => .stop,
            0x4a => .numpad_div,
            0x4d => .next_track,
            0x5a => .numpad_enter,
            0x69 => .end,
            0x6b => .arrow_left,
            0x6c => .home,
            0x70 => .insert,
            0x71 => .delete,
            0x72 => .arrow_down,
            0x74 => .arrow_right,
            0x75 => .arrow_up,
            0x7a => .page_down,
            0x7c => .print_screen,
            0x7d => .page_up,
            else => null,
        };
    }

    /// prefixed with 0xe1
    pub fn fromScancode2(code: u8) ?@This() {
        return switch (code) {
            0x14 => .right_control2,
            else => null,
        };
    }
};

pub const KeyState = enum(u8) {
    press,
    release,
    single,
};

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

const KeyEvent = struct {
    code: KeyCode,
    state: KeyState,
};

const Keyboard = struct {
    kb_port_data: caps.X86IoPort,
    kb_port_status: caps.X86IoPort,
    kb_irq: caps.X86Irq,
    kb_irq_notify: caps.Notify,

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
        const kb_port_data = try main.ioports.alloc(0x60);
        const kb_port_status = try main.ioports.alloc(0x64);
        const kb_irq = try main.irqs.alloc(1);
        const kb_irq_notify = try main.memory.alloc(caps.Notify);

        try kb_irq.subscribe(kb_irq_notify);

        var self = @This(){
            .kb_port_data = kb_port_data,
            .kb_port_status = kb_port_status,
            .kb_irq = kb_irq,
            .kb_irq_notify = kb_irq_notify,
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
                log.info("key event {}", .{ev});
            }
        }
    }

    fn controllerWrite(self: *@This(), byte: u8) !void {
        while (!try self.isInputEmpty()) abi.sys.yield();
        try self.kb_port_status.outb(byte);
    }

    fn write(self: *@This(), byte: u8) !void {
        while (!try self.isInputEmpty()) abi.sys.yield();
        try self.kb_port_data.outb(byte);
    }

    fn flush(self: *@This()) !void {
        while (try self.read()) |_| {}
    }

    fn read(self: *@This()) !?u8 {
        if (!try self.isOutputEmpty()) {
            const b = try self.kb_port_data.inb();
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
            abi.sys.yield();
        }
    }

    fn isOutputEmpty(self: *@This()) !bool {
        return try self.kb_port_status.inb() & 0b01 == 0;
    }

    fn isInputEmpty(self: *@This()) !bool {
        return try self.kb_port_status.inb() & 0b10 == 0;
    }

    fn wait(self: *@This()) !void {
        log.debug("waiting for keyboard interrupt", .{});
        _ = try self.kb_irq_notify.wait();
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
