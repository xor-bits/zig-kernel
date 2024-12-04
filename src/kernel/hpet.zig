const std = @import("std");

const arch = @import("arch.zig");
const acpi = @import("acpi.zig");
const pmem = @import("pmem.zig");
const lazy = @import("lazy.zig");

const log = std.log.scoped(.hpet);

//

pub fn init(hpet: *const Hpet) !void {
    log.info("found HPET addr: 0x{x}", .{hpet.address});

    const hpet_regs = pmem.PhysAddr.new(hpet.address).toHhdm().ptr(*volatile HpetRegs);
    hpet_regs_lazy.initNow(hpet_regs);

    hpet_regs.config.enable_config = 1;
    log.info("HPET speed: 1ms = {d} ticks", .{1_000_000_000_000 / @as(u64, hpet_regs.caps_and_id.counter_period_femtoseconds)});
}

pub fn hpet_spin_wait(micros: u32, just_before: anytype) void {
    const hpet_regs = hpet_regs_lazy.get().?.*;
    const ticks = (@as(u64, micros) * 1_000_000_000) / hpet_regs.caps_and_id.counter_period_femtoseconds;

    just_before.run();
    const deadline = hpet_regs.main_counter_value + ticks;
    while (hpet_regs.main_counter_value <= deadline) {
        std.atomic.spinLoopHint();
    }
}

pub fn now() u64 {
    const regs = hpet_regs_lazy.get().?.*;
    return regs.main_counter_value;
}

pub fn asNanos(t: u64) u128 {
    const regs = hpet_regs_lazy.get().?.*;
    return @as(u128, t) * regs.caps_and_id.counter_period_femtoseconds / 1_000_000;
}

pub fn elapsedNanos(from_then: u64) u128 {
    const regs = hpet_regs_lazy.get().?.*;
    return @as(u128, regs.main_counter_value - from_then) * regs.caps_and_id.counter_period_femtoseconds / 1_000_000;
}

//

var hpet_regs_lazy = lazy.Lazy(*volatile HpetRegs).new();

//

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
    interrupt_status: InterruptStatus,
    pad2: [25]u64,
    main_counter_value: u64,

    fn timer(self: *volatile @This(), n: usize) *volatile TimerRegs {
        const timer_base: usize = @intFromPtr(self);
        return @ptrFromInt(timer_base + 0x20 * n);
    }
};

const TimerRegs = extern struct {
    config_and_caps: TimerNConfigAndCaps,
    comparator_value: u64,
    // fsb_interrupt_route: FsbInterruptRoute,
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

const InterruptStatus = packed struct {
    timer_n_status: u32,
    reserved: u32,
};

const TimerNConfigAndCaps = packed struct {
    reserved0: u1,
    int_type_config: u1,
    int_enable_config: u1,
    type_config: u1,
    periodic_int_cap: u1,
    u64_cap: u1,
    value_set_config: u1,
    reserved1: u1,
    u32_mode_forced_config: u1,
    int_route_config: u5,
    fsb_enable_config: u1,
    fsb_interrupt_mapping_cap: u1,
    reserved: u16,
    int_route_cap: u32,
};
