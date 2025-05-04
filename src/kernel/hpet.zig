const std = @import("std");

const arch = @import("arch.zig");
const addr = @import("addr.zig");
const acpi = @import("acpi.zig");
const lazy = @import("lazy.zig");
const spin = @import("spin.zig");

const log = std.log.scoped(.hpet);

//

pub fn init(hpet: *const Hpet) !void {
    if (arch.cpuId() == 0)
        log.info("found HPET addr: 0x{x}", .{hpet.address});

    hpet_regs = addr.Phys.fromInt(hpet.address).toHhdm().toPtr(*volatile HpetRegs);
    const regs = hpet_regs.?;

    const config = @as(*volatile Config, &regs.config);
    var tmp = config.*;
    tmp.enable_config = 1;
    config.* = tmp;

    if (arch.cpuId() == 0)
        log.info("HPET speed: 1ms = {d} ticks", .{1_000_000_000_000 / @as(u64, @as(*volatile u32, &regs.caps_and_id.counter_period_femtoseconds).*)});
}

pub fn hpetSpinWait(micros: u32, just_before: anytype) void {
    const regs = hpet_regs.?;

    const ticks = (@as(u64, micros) * 1_000_000_000) / @as(*volatile u32, &regs.caps_and_id.counter_period_femtoseconds).*;

    just_before.run();
    const deadline = @as(*volatile u64, &regs.main_counter_value).* + ticks;
    while (@as(*volatile u64, &regs.main_counter_value).* <= deadline) {
        std.atomic.spinLoopHint();
    }
}

// pub fn now() u64 {
//     const regs = hpet_regs.?;
//     return regs.main_counter_value;
// }

// pub fn asNanos(t: u64) u128 {
//     const regs = hpet_regs.?;
//     return @as(u128, t) * regs.caps_and_id.counter_period_femtoseconds / 1_000_000;
// }

// pub fn elapsedNanos(from_then: u64) u128 {
//     const regs = hpet_regs.?;
//     return @as(u128, regs.main_counter_value - from_then) * regs.caps_and_id.counter_period_femtoseconds / 1_000_000;
// }

// pub fn timestampNanos() u128 {
//     const regs = hpet_regs.?;
//     regs.caps_and_id.counter_period_femtoseconds;
//     return regs.main_counter_value * regs.caps_and_id.counter_period_femtoseconds / 1_000_000;
// }

// pub fn sleepDeadline(timestamp_nanos: u128) void {
//     const regs = hpet_regs.?;
//     const counter = timestamp_nanos * 1_000_000 / regs.caps_and_id.counter_period_femtoseconds;
//     if (counter > std.math.maxInt(u64)) {
//         @branchHint(.cold);
//         log.err("FIXME: deadline val is bigger than max main counter val", .{});
//         return;
//     }

//     const n_timers: usize = regs.caps_and_id.n_timers_minus_one + 1;
//     const timer_i = arch.cpuId() % n_timers;
//     const timer_regs = regs.timer(timer_i); // distribute comparators a bit
//     const timer = &timers[timer_i];
// }

//

var hpet_regs: ?*volatile HpetRegs = null;

// var timers: [32]Timer = &.{.{}} ** 32;

//

// const Timer = struct {
//     lock: spin.Mutex = .{},
//     deadlines: std.PriorityQueue(u64, void, struct {
//         fn inner(_: void, a: u64, b: u64) std.math.Order {
//             return std.math.order(a, b);
//         }
//     }.inner) = .{},
// };

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
