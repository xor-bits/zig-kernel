const std = @import("std");

const apic = @import("../apic.zig");

const log = std.log.scoped(.arch);

//

pub const IA32_TCS_AUX = 0xC0000103;
pub const IA32_APIC_BASE = 0x1B;

//

pub const ints = struct {
    pub inline fn disable() void {
        asm volatile (
            \\ cli
        );
    }

    // FIXME: idk how to disable red-zone in zig
    /// UB to enable interrupts in redzone context
    pub inline fn enable() void {
        asm volatile (
            \\ sti
        );
    }

    /// wait for the next interrupt
    pub fn wait() callconv(.C) void {
        asm volatile (
            \\ sti
            \\ hlt
            \\ cli
        );
    }

    pub inline fn int3() void {
        asm volatile (
            \\ int3
        );
    }
};

pub inline fn hcf() noreturn {
    while (true) {
        asm volatile (
            \\ cli
            \\ hlt
        );
    }
}

pub fn outb(port: u16, byte: u8) void {
    asm volatile (
        \\ outb %[byte], %[port]
        :
        : [byte] "{al}" (byte),
          [port] "N{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile (
        \\ inb %[port], %[byte]
        : [byte] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub fn io_wait() void {
    outb(0x80, 0);
}

pub fn lgdt(v: u64) void {
    asm volatile (
        \\ lgdtq (%[v])
        :
        : [v] "N{dx}" (v),
    );
}

pub fn lidt(v: u64) void {
    asm volatile (
        \\ lidtq (%[v])
        :
        : [v] "N{dx}" (v),
    );
}

pub fn ltr(v: u64) void {
    asm volatile (
        \\ ltr %[v]
        :
        : [v] "N{dx}" (v),
    );
}

pub fn set_cs(sel: u64) void {
    asm volatile (
        \\ pushq %[v]
        \\ leaq .reload_CS(%rip), %rax
        \\ pushq %rax
        \\ lretq
        \\ .reload_CS:
        :
        : [v] "N{dx}" (sel),
        : "rax"
    );
}

pub fn set_ss(sel: u16) void {
    asm volatile (
        \\ movw %[v], %ss
        :
        : [v] "N{dx}" (sel),
    );
}

pub fn set_ds(sel: u16) void {
    asm volatile (
        \\ movw %[v], %ds
        :
        : [v] "N{dx}" (sel),
    );
}

pub fn set_es(sel: u16) void {
    asm volatile (
        \\ movw %[v], %es
        :
        : [v] "N{dx}" (sel),
    );
}

pub fn set_fs(sel: u16) void {
    asm volatile (
        \\ movw %[v], %fs
        :
        : [v] "N{dx}" (sel),
    );
}

pub fn set_gs(sel: u16) void {
    asm volatile (
        \\ movw %[v], %gs
        :
        : [v] "N{dx}" (sel),
    );
}

pub fn wrmsr(msr: u32, val: usize) void {
    const hi: u32 = @truncate(val >> 32);
    const lo: u32 = @truncate(val);

    asm volatile (
        \\ wrmsr
        :
        : [val_hi] "{edx}" (hi),
          [val_lo] "{eax}" (lo),
          [msr] "{ecx}" (msr),
          // : [byte] "={al}" (-> u8),
          // : [port] "N{dx}" (port),
    );
}

pub fn rdmsr(msr: u32) usize {
    var hi: u32 = undefined;
    var lo: u32 = undefined;

    asm volatile (
        \\ rdmsr
        : [val_hi] "={edx}" (hi),
          [val_lo] "={eax}" (lo),
        : [msr] "{ecx}" (msr),
    );

    const hi64: usize = @intCast(hi);
    const lo64: usize = @intCast(lo);

    return lo64 | (hi64 << 32);
}

pub fn rdpid() usize {
    return asm volatile (
        \\ rdpid %[pid]
        : [pid] "={rax}" (-> usize),
    );
}

pub const RdTscpRes = struct { counter: u64, pid: u32 };
pub fn rdtscp() RdTscpRes {
    var hi: u32 = undefined;
    var lo: u32 = undefined;
    var pid: u32 = undefined;

    asm volatile (
        \\ rdtscp
        : [counter_hi] "={edx}" (hi),
          [counter_lo] "={eax}" (lo),
          [pid] "={ecx}" (pid),
    );

    const hi64: usize = @intCast(hi);
    const lo64: usize = @intCast(lo);

    return .{
        .counter = lo64 | (hi64 << 32),
        .pid = pid,
    };
}

pub const Cpuid = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

/// cpuid instruction
pub fn cpuid(branch: u32, leaf: u32) Cpuid {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile (
        \\ cpuid
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [branch] "{eax}" (branch),
          [leaf] "{ecx}" (leaf),
    );
    return .{
        .eax = eax,
        .ebx = ebx,
        .ecx = ecx,
        .edx = edx,
    };
}

pub fn wrcr3(sel: u64) void {
    asm volatile (
        \\ mov %[v], %cr3
        :
        : [v] "N{rdx}" (sel),
    );
}

pub fn rdcr3() u64 {
    return asm volatile (
        \\ mov %cr3, %[v]
        : [v] "={rdx}" (-> u64),
    );
}

const cpu_id_mode_ty = enum(u8) {
    rdpid,
    rdtscp,
    rdmsr,
    lazy,
};
var cpu_id_mode = std.atomic.Value(cpu_id_mode_ty).init(.lazy);

/// processor ID
pub fn cpu_id() u32 {
    switch (cpu_id_mode.load(.acquire)) {
        .rdpid => return @intCast(rdpid()),
        .rdtscp => return rdtscp().pid,
        .rdmsr => return @intCast(rdmsr(IA32_TCS_AUX)),
        .lazy => {
            @setCold(true);

            if (cpuid(0x7, 0).ecx & (1 << 22) != 0) {
                log.info("RDPID support", .{});
                cpu_id_mode.store(.rdpid, .release);
                return @intCast(rdpid());
            } else if (cpuid(0x80000001, 0).edx & (1 << 27) != 0) {
                log.info("RDTSCP support", .{});
                cpu_id_mode.store(.rdtscp, .release);
                return rdtscp().pid;
            } else {
                log.info("fallback RDMSR", .{});
                cpu_id_mode.store(.rdmsr, .release);
                return @intCast(rdmsr(IA32_TCS_AUX));
            }
        },
    }
}

pub fn reset() void {
    log.info("triple fault reset", .{});
    ints.disable();
    // load 0 size IDT
    var idt = Idt.new();
    idt.load(0);
    // enable interrupts
    ints.enable();
    // and cause a triple fault if it hasn't already happened
    ints.int3();
}

pub const GdtDescriptor = packed struct {
    raw: u64,

    pub const Self = @This();

    pub fn new(raw: u64) Self {
        return .{ .raw = raw };
    }

    pub const accessed = new(1 << 40);
    pub const writable = new(1 << 41);
    pub const conforming = new(1 << 42);
    pub const executable = new(1 << 43);
    pub const user = new(1 << 44);
    pub const ring_3 = new(3 << 45);
    pub const present = new(1 << 47);

    pub const limit_0_15 = new(0xffff);
    pub const limit_16_19 = new(0xF << 48);

    pub const long_mode = new(1 << 53);
    pub const default_size = new(1 << 54);
    pub const granularity = new(1 << 55);

    pub const common = new(accessed.raw | writable.raw | present.raw | user.raw | limit_0_15.raw | limit_16_19.raw | granularity.raw);

    pub const kernel_data = new(common.raw | default_size.raw);
    pub const kernel_code = new(common.raw | executable.raw | long_mode.raw);
    pub const user_data = new(kernel_data.raw | ring_3.raw);
    pub const user_code = new(kernel_code.raw | ring_3.raw);

    pub const kernel_code_selector = (1 << 3);
    pub const kernel_data_selector = (2 << 3);
    pub const user_data_selector = (3 << 3) | 3;
    pub const user_code_selector = (4 << 3) | 3;

    // pub fn tss() Self {}
};

pub const DescriptorTablePtr = extern struct {
    _pad: [3]u16 = undefined,
    limit: u16,
    base: u64,
};

pub const Gdt = extern struct {
    ptr: DescriptorTablePtr,
    null_descriptor: GdtDescriptor,
    descriptors: [4]GdtDescriptor,

    pub const Self = @This();

    pub fn new() Self {
        return Self{
            .ptr = undefined,
            .null_descriptor = .{ .raw = 0 },
            .descriptors = .{
                GdtDescriptor.kernel_code,
                GdtDescriptor.kernel_data,
                GdtDescriptor.user_data,
                GdtDescriptor.user_code,
            },
        };
    }

    pub fn load(self: *Self) void {
        self.ptr = .{
            .base = @intFromPtr(&self.null_descriptor),
            .limit = 5 * @sizeOf(u64) - 1,
        };
        loadRaw(&self.ptr.limit);
    }

    fn loadRaw(ptr: *anyopaque) void {
        lgdt(@intFromPtr(ptr));
        set_cs(GdtDescriptor.kernel_code_selector);
        set_ss(GdtDescriptor.kernel_data_selector);
        set_ds(GdtDescriptor.kernel_data_selector);
        set_es(GdtDescriptor.kernel_data_selector);
        set_fs(GdtDescriptor.kernel_data_selector);
        set_gs(GdtDescriptor.kernel_data_selector);
    }
};

pub const Tss = packed struct {};

pub const PageFaultError = packed struct {
    /// page protection violation instead of a missing page
    page_protection: bool,
    caused_by_write: bool,
    user_mode: bool,
    malformed_table: bool,
    instruction_fetch: bool,
    protection_key: bool,
    shadow_stack: bool,
    _unused1: u8,
    sgx: bool,
    _unused2: u15,
    rmp: bool,
    _unused3: u32,
};

pub const Entry = packed struct {
    offset_0_15: u16,
    segment_selector: u16,
    interrupt_stack: u3,
    reserved2: u5 = 0,
    gate_type: u4,
    _0: u1 = 0,
    dpl: u2,
    present: u1,
    offset_16_31: u16,
    offset_32_63: u32,
    reserved1: u32 = 0,

    const Self = @This();

    pub fn new(int_handler: *const fn (*const InterruptStackFrame) callconv(.Interrupt) void) Self {
        const isr = @intFromPtr(int_handler);
        return Self.newAny(isr);
    }

    pub fn newWithEc(int_handler: *const fn (*const InterruptStackFrame, u64) callconv(.Interrupt) void) Self {
        const isr = @intFromPtr(int_handler);
        return Self.newAny(isr);
    }

    pub fn generate(comptime handler: anytype) Self {
        const handler_wrapper = struct {
            fn interrupt(interrupt_stack_frame: *const InterruptStackFrame) callconv(.Interrupt) void {
                handler.handler(interrupt_stack_frame);
            }
        };

        return Self.new(handler_wrapper.interrupt);
    }

    pub fn generateWithEc(comptime handler: anytype) Self {
        const handler_wrapper = struct {
            fn interrupt(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) callconv(.Interrupt) void {
                handler.handler(interrupt_stack_frame, ec);
            }
        };

        return Self.newWithEc(handler_wrapper.interrupt);
    }

    fn newAny(isr: usize) Self {
        // log.info("interrupt at : {x}", .{isr});
        return Self{
            .offset_0_15 = @truncate(isr & 0xFFFF),
            .segment_selector = 0x08,
            .interrupt_stack = 0,
            .gate_type = 0xE, // E for interrupt gate, F for trap gate
            .dpl = 0,
            .present = 1,
            .offset_16_31 = @truncate((isr >> 16) & 0xFFFF),
            .offset_32_63 = @truncate((isr >> 32) & 0xFFFFFFFF),
        };
    }

    pub fn asInt(self: Self) u128 {
        return @bitCast(self);
    }
};

pub const Idt = extern struct {
    ptr: DescriptorTablePtr,
    entries: [256]u128,

    const Self = @This();

    pub fn new() Self {
        var entries = std.mem.zeroes([256]u128);

        // division error
        entries[0] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                log.err("division error\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // debug
        entries[1] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                log.err("debug\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // non-maskable interrupt
        entries[2] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                log.info("non-maskable interrupt\nframe: {any}", .{interrupt_stack_frame});
            }
        }).asInt();
        // breakpoint
        entries[3] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                log.info("breakpoint\nframe: {any}", .{interrupt_stack_frame});
            }
        }).asInt();
        // overflow
        entries[4] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                log.err("overflow\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // bound range exceeded
        entries[5] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                log.err("bound range exceeded\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // invalid opcode
        entries[6] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                log.err("invalid opcode\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // device not available
        entries[7] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                log.err("device not available\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // double fault
        entries[8] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                log.err("double fault (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // coprocessor segment overrun (useless)
        // entries[9] = 0;
        // invalid tss
        entries[10] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                log.err("invalid tss (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // segment not present
        entries[11] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                log.err("segment not present (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // stack-segment fault
        entries[12] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                log.err("stack-segment fault (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // general protection fault
        entries[13] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                log.err("general protection fault (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // page fault
        entries[14] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                const pfec: PageFaultError = @bitCast(ec);
                log.err("page fault ({any})\nframe: {any}", .{ pfec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // reserved
        // entries[15] = 0;
        // x87 fp exception
        entries[16] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                log.err("x87 fp exception\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // alignment check
        entries[17] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                log.err("alignment check (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // machine check
        entries[18] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                log.err("machine check\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // simd fp exception
        entries[19] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                log.err("simd fp exception\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // virtualization exception
        entries[20] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                log.err("virtualization exception\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // control protection exception
        entries[21] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                log.err("control protection exce (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled GPF", .{});
            }
        }).asInt();
        // reserved
        // entries[22..27] = 0;
        // hypervisor injection exception
        entries[28] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                log.err("hypervisor injection exception\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // vmm communication exception
        entries[29] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                log.err("vmm communication excep (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled GPF", .{});
            }
        }).asInt();
        // security exception
        entries[30] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                log.err("security exception (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled GPF", .{});
            }
        }).asInt();
        // reserved
        // entries[31] = 0;
        // triple fault, non catchable

        // spurious PIC interrupts
        for (entries[32..41]) |*entry| {
            entry.* = Entry.generate(struct {
                fn handler(_: *const InterruptStackFrame) void {}
            }).asInt();
        }

        entries[apic.IRQ_SPURIOUS] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                apic.spurious(interrupt_stack_frame);
            }
        }).asInt();
        entries[apic.IRQ_TIMER] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                apic.timer(interrupt_stack_frame);
            }
        }).asInt();

        return Self{
            .ptr = undefined,
            .entries = entries,
        };
    }

    pub fn load(self: *Self, size_override: ?u16) void {
        self.ptr = .{
            .base = @intFromPtr(&self.entries),
            .limit = size_override orelse (256 * @sizeOf(Entry) - 1),
        };
        loadRaw(&self.ptr.limit);
    }

    fn loadRaw(ptr: *anyopaque) void {
        lidt(@intFromPtr(ptr));
    }
};

const InterruptStackFrame = extern struct {
    /// the instruction right after the instruction that caused this interrupt
    ip: usize,

    /// code privilege level before the interrupt
    code_segment: u16,

    /// RFlags
    cpu_flags: u64,

    /// stack pointer before the interrupt
    sp: usize,

    /// stack(data) privilege level before the interrupt
    stack_segment: u16,
};

fn interrupt_ec(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) callconv(.Interrupt) void {
    log.err("default interrupt: {any} {any}", .{ interrupt_stack_frame, ec });
}

fn interrupt(interrupt_stack_frame: *const InterruptStackFrame) callconv(.Interrupt) void {
    log.err("default interrupt: {any} ", .{interrupt_stack_frame});
}

pub const CpuConfig = struct {
    gdt: Gdt,
    // tss: Tss,
    idt: Idt,

    pub fn init(self: *@This(), this_cpu_id: usize) void {
        self.gdt = Gdt.new();
        self.idt = Idt.new();

        // extremely important to disable interrupts before modifying GDT
        ints.disable();
        self.gdt.load();
        self.idt.load(null);
        // ints.enable();

        log.info("cpu_id: {d} cpuconfig size: {d}", .{ this_cpu_id, @sizeOf(CpuConfig) });

        wrmsr(IA32_TCS_AUX, this_cpu_id);
        log.info("PID: {d}", .{cpu_id()});
    }
};

test "structure sizes" {
    std.testing.expectEqual(8, @sizeOf(GdtDescriptor));
    std.testing.expectEqual(16, @sizeOf(Entry));
    std.testing.expectEqual(8, @sizeOf(PageFaultError));
}
