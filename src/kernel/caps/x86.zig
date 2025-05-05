const std = @import("std");
const abi = @import("abi");

const addr = @import("../addr.zig");
const apic = @import("../apic.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");

//

const conf = abi.conf;
const log = std.log.scoped(.ioport);
const Error = abi.sys.Error;

//

pub const X86IoPortAllocator = struct {
    pub fn init(_: caps.Ref(@This())) void {}

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return Error.InvalidArgument;
    }

    pub fn call(_: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.X86IoPortAllocatorCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (conf.LOG_OBJ_CALLS)
            log.debug("x86_ioport_allocator call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .alloc => {
                const port: u16 = @truncate(trap.arg2);
                try allocPort(&port_bitmap, port);

                const cap_id = caps.pushCapability((caps.Ref(X86IoPort){ .paddr = .fromInt(port) }).object(thread));
                trap.arg1 = cap_id;
            },
            .clone => {
                const cap_id = caps.pushCapability((caps.Ref(X86IoPortAllocator){ .paddr = .fromInt(0) }).object(thread));
                trap.arg1 = cap_id;
            },
        }
    }
};

pub const X86IoPort = struct {
    pub fn init(_: caps.Ref(@This())) void {}

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return Error.InvalidArgument;
    }

    pub fn call(port: addr.Phys, _: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.X86IoPortCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (conf.LOG_OBJ_CALLS)
            log.debug("x86_ioport call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .inb => {
                trap.arg1 = arch.inb(@truncate(port.raw));
            },
            .outb => {
                arch.outb(@truncate(port.raw), @truncate(trap.arg2));
            },
            // .free
        }
    }
};

pub const X86IrqAllocator = struct {
    pub fn init(_: caps.Ref(@This())) void {}

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return Error.InvalidArgument;
    }

    pub fn call(_: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.X86IrqAllocatorCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (conf.LOG_OBJ_CALLS)
            log.debug("x86_irq_allocator call \"{s}\"", .{@tagName(call_id)});

        switch (call_id) {
            .alloc => {
                const irq: u8 = @truncate(trap.arg2);
                try allocIrq(&irq_bitmap, irq);

                const cap_id = caps.pushCapability((caps.Ref(X86Irq){ .paddr = .fromInt(irq) }).object(thread));
                trap.arg1 = cap_id;
            },
            .clone => {
                const cap_id = caps.pushCapability((caps.Ref(X86IrqAllocator){ .paddr = .fromInt(0) }).object(thread));
                trap.arg1 = cap_id;
            },
        }
    }
};

pub const X86Irq = struct {
    pub fn init(_: caps.Ref(@This())) void {}

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return Error.InvalidArgument;
    }

    pub fn call(_irq: addr.Phys, thread: *caps.Thread, trap: *arch.SyscallRegs) Error!void {
        const call_id = std.meta.intToEnum(abi.sys.X86IrqCallId, trap.arg1) catch {
            return Error.InvalidArgument;
        };

        if (conf.LOG_OBJ_CALLS)
            log.debug("x86_irq call \"{s}\"", .{@tagName(call_id)});

        const irq: u8 = @truncate(_irq.raw);

        switch (call_id) {
            .subscribe => {
                const notify_obj = try caps.getCapability(thread, @truncate(trap.arg2));
                defer notify_obj.lock.unlock();

                const notify = try notify_obj.as(caps.Notify);

                const this_obj = caps.getCapabilityLocked(@truncate(trap.arg0));

                if (notify_obj.next != 0) return Error.NotifyAlreadySubscribed;
                if (this_obj.next != 0) return Error.IrqAlreadySubscribed;

                apic.registerExternalInterrupt(irq, notify.ptr()) orelse {
                    return Error.TooManyIrqs;
                };

                notify_obj.next = @truncate(trap.arg0);
                this_obj.next = @truncate(trap.arg2);
            },
            .unsubscribe => {
                return Error.Unimplemented;
            },
        }
    }
};

//

// 0=free 1=used
const port_bitmap_len = 0x300 / 8;
var port_bitmap: [port_bitmap_len]std.atomic.Value(u8) = b: {
    var bitmap: [port_bitmap_len]std.atomic.Value(u8) = .{std.atomic.Value(u8).init(0xFF)} ** port_bitmap_len;

    // PS/2 controller
    for (0x0060..0x0065) |port|
        freePort(&bitmap, @truncate(port)) catch unreachable;
    // CMOS and RTC registers
    for (0x0070..0x0072) |port|
        freePort(&bitmap, @truncate(port)) catch unreachable;
    // second serial port
    for (0x02F8..0x0300) |port|
        freePort(&bitmap, @truncate(port)) catch unreachable;

    break :b bitmap;
};

const irq_bitmap_len = 0x100 / 8;
var irq_bitmap: [irq_bitmap_len]std.atomic.Value(u8) = b: {
    var bitmap: [irq_bitmap_len]std.atomic.Value(u8) = .{std.atomic.Value(u8).init(0xFF)} ** irq_bitmap_len;

    for (0..apic.IRQ_AVAIL_COUNT + 1) |i|
        freeIrq(&bitmap, @truncate(i)) catch unreachable;

    break :b bitmap;
};

fn allocPort(bitmap: *[port_bitmap_len]std.atomic.Value(u8), port: u16) Error!void {
    if (port >= 0x300)
        return Error.AlreadyMapped;
    const byte = &bitmap[port / 8];
    if (byte.bitSet(@truncate(port % 8), .acquire) == 1)
        return Error.AlreadyMapped;
}

fn freePort(bitmap: *[port_bitmap_len]std.atomic.Value(u8), port: u16) Error!void {
    if (port >= 0x300)
        return Error.NotMapped;
    const byte = &bitmap[port / 8];
    if (byte.bitReset(@truncate(port % 8), .release) == 0)
        return Error.NotMapped;
}

fn allocIrq(bitmap: *[irq_bitmap_len]std.atomic.Value(u8), irq: u8) Error!void {
    const byte = &bitmap[irq / 8];
    if (byte.bitSet(@truncate(irq % 8), .acquire) == 1)
        return Error.AlreadyMapped;
}

fn freeIrq(bitmap: *[irq_bitmap_len]std.atomic.Value(u8), irq: u8) Error!void {
    const byte = &bitmap[irq / 8];
    if (byte.bitReset(@truncate(irq % 8), .release) == 0)
        return Error.NotMapped;
}
