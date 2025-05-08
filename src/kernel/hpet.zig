const std = @import("std");

const arch = @import("arch.zig");
const addr = @import("addr.zig");
const acpi = @import("acpi.zig");
const lazy = @import("lazy.zig");
const spin = @import("spin.zig");
const caps = @import("caps.zig");

const log = std.log.scoped(.hpet);

//

var hpet_once: spin.Once = .{};

pub fn init(hpet: *const Hpet) !void {
    if (!hpet_once.tryRun()) {
        hpet_once.wait();
        return;
    }
    defer hpet_once.complete();

    log.info("found HPET addr: 0x{x}", .{hpet.address});

    const hpet_phys: caps.Ref(caps.DeviceFrame) = .{ .paddr = caps.DeviceFrame.new(addr.Phys.fromInt(hpet.address), .@"4KiB") };
    hpet_frame = hpet_phys;
    const regs: *volatile HpetRegs = @ptrCast(hpet_phys.ptr());

    const config = @as(*volatile Config, &regs.config);
    var tmp = config.*;
    tmp.enable_config = 1;
    config.* = tmp;

    log.info("HPET speed: 1ms = {d} ticks", .{1_000_000_000_000 / @as(u64, @as(*volatile u32, &regs.caps_and_id.counter_period_femtoseconds).*)});
}

// TODO: something useful could be done while waiting
// + only one CPU has to measure the APIC timer speed afaik
pub fn hpetSpinWait(micros: u32, just_before: anytype) void {
    const regs: *volatile HpetRegs = @ptrCast(hpet_frame.?.ptr());

    const ticks = (@as(u64, micros) * 1_000_000_000) / @as(*volatile u32, &regs.caps_and_id.counter_period_femtoseconds).*;

    just_before.run();
    const deadline = @as(*volatile u64, &regs.main_counter_value).* + ticks;
    while (@as(*volatile u64, &regs.main_counter_value).* <= deadline) {
        std.atomic.spinLoopHint();
    }
}

pub fn hpetFrame() caps.Ref(caps.DeviceFrame) {
    return hpet_frame.?;
}

var hpet_frame: ?caps.Ref(caps.DeviceFrame) = null;

const Hpet = extern struct {
    header: acpi.SdtHeader align(1),
    flags: Flags align(1),
    hardware_rev_id: u8 align(1),
    pci_vendor_id: u16 align(1),
    address_space_id: u8 align(1),
    address_register_bit_width: u8 align(1),
    address_register_bit_offset: u8 align(1),
    address_reserved: u8 align(1),
    address: u64 align(1),
    hpet_number: u8 align(1),
    minimum_tick: u16 align(1),
    page_protection: u8 align(1),
};

const Flags = packed struct {
    comparator_count: u5,
    counter_size: u1,
    reserved: u1,
    legacy_replacement: u1,
};

const HpetRegs = extern struct {
    caps_and_id: Caps,
    pad0: u64,
    config: Config,
    pad1: u64,
    interrupt_status: u64,
    pad2: [25]u64,
    main_counter_value: u64,
};

const Caps = packed struct {
    rev_id: u8,
    n_timers_minus_one: u5,
    u64_capable: u1,
    reserved: u1,
    legacy_replacement_capable: u1,
    vendor_id: u16,
    counter_period_femtoseconds: u32,
};

const Config = packed struct {
    enable_config: u1,
    legacy_replacement_config: u1,
    reserved: u62,
};
