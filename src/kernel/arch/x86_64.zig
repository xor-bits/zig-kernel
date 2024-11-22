const std = @import("std");

const apic = @import("../apic.zig");
const main = @import("../main.zig");
const pmem = @import("../pmem.zig");

const log = std.log.scoped(.arch);

//

pub const IA32_TCS_AUX = 0xC0000103;
pub const IA32_APIC_BASE = 0x1B;
pub const EFER = 0xC0000080;
pub const STAR = 0xC0000081;
pub const LSTAR = 0xC0000082;
pub const SFMASK = 0xC0000084;
pub const GS_BASE = 0xC0000101;
pub const KERNELGS_BASE = 0xC0000102;

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

pub fn ltr(v: u16) void {
    asm volatile (
        \\ ltr %[v]
        :
        : [v] "r" (v),
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

pub fn flush_tlb() void {
    wrcr3(rdcr3());
}

pub fn flush_tlb_addr(addr: usize) void {
    asm volatile (
        \\ invlpg (%[v])
        :
        : [v] "r" (addr),
        : "memory"
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

    pub const kernel_code_selector: u8 = (1 << 3);
    pub const kernel_data_selector: u8 = (2 << 3);
    pub const user_data_selector: u8 = (3 << 3) | 3;
    pub const user_code_selector: u8 = (4 << 3) | 3;

    pub const tss_selector: u8 = (5 << 3);

    pub fn tss(_tss: *const Tss) [2]Self {
        const tss_ptr: u64 = @intFromPtr(_tss);
        const limit: u16 = @truncate(@sizeOf(Tss) - 1);
        const base_0_23: u24 = @truncate(tss_ptr);
        const base_24_32: u8 = @truncate(tss_ptr >> 24);
        const low = present.raw | limit | (@as(u64, base_0_23) << 16) | (@as(u64, base_24_32) << 56) | (@as(u64, 0b1001) << 40);
        const high = tss_ptr >> 32;
        return .{
            .{ .raw = low },
            .{ .raw = high },
        };
    }
};

pub const DescriptorTablePtr = extern struct {
    _pad: [3]u16 = undefined,
    limit: u16,
    base: u64,
};

pub const Gdt = extern struct {
    ptr: DescriptorTablePtr,
    null_descriptor: GdtDescriptor,
    descriptors: [6]GdtDescriptor,

    pub const Self = @This();

    pub fn new(tss: *const Tss) Self {
        return Self{
            .ptr = undefined,
            .null_descriptor = .{ .raw = 0 },
            .descriptors = .{
                GdtDescriptor.kernel_code,
                GdtDescriptor.kernel_data,
                GdtDescriptor.user_data,
                GdtDescriptor.user_code,
            } ++
                GdtDescriptor.tss(tss),
        };
    }

    pub fn load(self: *Self) void {
        self.ptr = .{
            .base = @intFromPtr(&self.null_descriptor),
            .limit = 7 * @sizeOf(GdtDescriptor) - 1,
        };
        loadRaw(&self.ptr.limit);
    }

    fn loadRaw(ptr: *anyopaque) void {
        lgdt(@intFromPtr(ptr));
        set_cs(GdtDescriptor.kernel_code_selector);
        set_ss(GdtDescriptor.kernel_data_selector);
        // set_ds(GdtDescriptor.kernel_data_selector);
        // set_es(GdtDescriptor.kernel_data_selector);
        // set_fs(GdtDescriptor.kernel_data_selector);
        // set_gs(GdtDescriptor.kernel_data_selector);
        ltr(GdtDescriptor.tss_selector);
    }
};

pub const Tss = extern struct {
    reserved0: u32 = 0,
    privilege_stacks: [3]u64 align(4) = std.mem.zeroes([3]u64),
    reserved1: u64 align(4) = 0,
    interrupt_stacks: [7]u64 align(4) = std.mem.zeroes([7]u64),
    reserved2: u64 align(4) = 0,
    reserved3: u16 = 0,
    iomap_base: u16 = @sizeOf(@This()), // no iomap base

    fn new() @This() {
        const Stack = [8 * 0x1000]u8;

        var res = @This(){};

        res.privilege_stacks[0] =
            @intFromPtr(pmem.page_allocator.create(Stack) catch {
            std.debug.panic("not enough memory for a privilege stack", .{});
        });
        res.interrupt_stacks[0] =
            @intFromPtr(pmem.page_allocator.create(Stack) catch {
            std.debug.panic("not enough memory for an interrupt stack", .{});
        });
        // res.interrupt_stacks[1] =
        //     @intFromPtr(pmem.page_allocator.create(Stack) catch {
        //     std.debug.panic("not enough memory for an interrupt stack", .{});
        // });

        return res;
    }
};

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

    pub fn withStack(self: Self, stack: u3) Self {
        var s = self;
        s.interrupt_stack = stack;
        return s;
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
                const target_addr = Cr2.read().page_fault_addr;

                log.err(
                    \\page fault 0x{x}
                    \\ - user: {any}
                    \\ - caused by write: {any}
                    \\ - instruction fetch: {any}
                    \\ - ip: 0x{x}
                    \\ - sp: 0x{x}
                , .{
                    target_addr,
                    pfec.user_mode,
                    pfec.caused_by_write,
                    pfec.instruction_fetch,
                    interrupt_stack_frame.ip,
                    interrupt_stack_frame.sp,
                });

                std.debug.panic("unhandled CPU exception", .{});
            }
        }).withStack(1).asInt();
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
    // KernelGS:0 here
    rsp_kernel: u64 align(0x1000),
    rsp_user: u64,

    gdt: Gdt,
    tss: Tss,
    idt: Idt,

    pub fn init(self: *@This(), this_cpu_id: usize) void {
        self.tss = Tss.new();
        self.gdt = Gdt.new(&self.tss);
        self.idt = Idt.new();

        log.info("CpuConfig size: 0x{x}", .{@sizeOf(@This())});

        // initialize GDT (, TSS) and IDT
        // extremely important to disable interrupts before modifying GDT
        ints.disable();
        log.info("loading new GDT", .{});
        self.gdt.load();
        log.info("loading new IDT", .{});
        self.idt.load(null);
        // ints.enable();

        // enable/disable some features
        var cr0 = Cr0.read();
        cr0.emulate_coprocessor = 0;
        cr0.monitor_coprocessor = 1;
        cr0.write();
        var cr4 = Cr4.read();
        cr4.osfxsr = 1;
        cr4.osxmmexcpt = 1;
        cr4.write();

        // initialize CPU identification for scheduling purposes
        wrmsr(IA32_TCS_AUX, this_cpu_id);
        log.info("CPU ID set: {d}", .{cpu_id()});

        wrmsr(KERNELGS_BASE, @intFromPtr(self));
        wrmsr(GS_BASE, 0);

        // initialize syscall and sysret instructions
        wrmsr(
            STAR,
            (@as(u64, GdtDescriptor.user_data_selector - 8) << 48) |
                (@as(u64, GdtDescriptor.kernel_code_selector) << 32),
        );

        // RIP of the syscall jump destination
        wrmsr(LSTAR, @intFromPtr(&syscall_handler_wrapper));

        // bits that are 1 clear a bit from rflags when a syscall happens
        // setting interrupt_enable here disables interrupts on syscall
        wrmsr(SFMASK, @bitCast(Rflags{ .interrupt_enable = 1 }));

        const efer_flags: u64 = @bitCast(EferFlags{ .system_call_extensions = 1 });
        wrmsr(EFER, rdmsr(EFER) | efer_flags);
        log.info("syscalls initialized", .{});
    }
};

pub const Cr0 = packed struct {
    protected_mode_enable: u1,
    monitor_coprocessor: u1,
    emulate_coprocessor: u1,
    task_switched: u1,
    extension_type: u1,
    numeric_error: u1,
    reserved0: u10,
    write_protect: u1,
    reserved1: u1,
    alignment_mask: u1,
    reserved2: u10,
    not_write_through: u1,
    cache_disable: u1,
    paging: u1,
    reserved: u32,

    const Self = @This();

    pub fn write(val: Self) void {
        const v: u64 = @bitCast(val);
        asm volatile (
            \\ mov %[v], %cr0
            :
            : [v] "r" (v),
        );
    }

    pub fn read() Self {
        return @bitCast(asm volatile (
            \\mov %cr0, %[v]
            : [v] "={rax}" (-> u64),
        ));
    }
};

pub const Cr2 = packed struct {
    page_fault_addr: u64,

    const Self = @This();

    pub fn write(val: Self) void {
        const v: u64 = @bitCast(val);
        asm volatile (
            \\ mov %[v], %cr2
            :
            : [v] "r" (v),
        );
    }

    pub fn read() Self {
        return @bitCast(asm volatile (
            \\ mov %cr2, %[v]
            : [v] "={rax}" (-> u64),
        ));
    }
};

pub const Cr3 = packed struct {
    // reserved0: u3,
    // page_Level_write_through: u1,
    // page_level_cache_disable: u1,
    // reserved1: u7,
    pcid: u12,
    pml4_phys_base: u52,

    const Self = @This();

    pub fn write(val: Self) void {
        const v: u64 = @bitCast(val);
        asm volatile (
            \\ mov %[v], %cr3
            :
            : [v] "r" (v),
        );
    }

    pub fn read() Self {
        return @bitCast(asm volatile (
            \\ mov %cr3, %[v]
            : [v] "={rax}" (-> u64),
        ));
    }
};

pub const Cr4 = packed struct {
    virtual_8086_mode_extensions: u1,
    protected_mode_virtual_interrupts: u1,
    tsc_in_kernel_only: u1,
    debugging_extensions: u1,
    page_size_extension: u1,
    physical_address_extension: u1,
    machine_check_exception: u1,
    page_global_enable: u1,
    performance_monitoring_counter_enable: u1,
    osfxsr: u1,
    osxmmexcpt: u1,
    user_mode_instruction_prevention: u1,
    reserved0: u1,
    virtual_machine_extensions_enable: u1,
    safer_mode_extensions_enable: u1,
    reserved1: u1,
    fsgsbase: u1,
    pcid_enable: u1,
    osxsave_enable: u1,
    reserved2: u1,
    supervisor_mode_executions_protection_enable: u1,
    supervisor_mode_access_protection_enable: u1,
    protection_key_enable: u1,
    controlflow_enforcement_technology: u1,
    protection_keys_for_supervisor: u1,
    reserved3: u39,

    const Self = @This();

    pub fn write(val: Self) void {
        const v: u64 = @bitCast(val);
        asm volatile (
            \\ mov %[v], %cr4
            :
            : [v] "r" (v),
        );
    }

    pub fn read() Self {
        return @bitCast(asm volatile (
            \\ mov %cr4, %[v]
            : [v] "={rax}" (-> u64),
        ));
    }
};

pub const Rflags = packed struct {
    carry_flag: u1 = 0,
    reserved0: u1 = 0,
    parity_flag: u1 = 0,
    reserved1: u1 = 0,
    auxliary_carry_flag: u1 = 0,
    reserved2: u1 = 0,
    zero_flag: u1 = 0,
    sign_flag: u1 = 0,
    trap_flag: u1 = 0,
    interrupt_enable: u1 = 0,
    direction_flag: u1 = 0,
    overflow_flag: u1 = 0,
    io_privilege_flag: u2 = 0,
    nested_task: u1 = 0,
    reserved3: u1 = 0,
    resume_flag: u1 = 0,
    virtual_8086_mode: u1 = 0,
    alignment_check_or_access_control: u1 = 0,
    virtual_interrupt_flag: u1 = 0,
    virtual_interrupt_pending: u1 = 0,
    id_flag: u1 = 0,
    reserved4: u42 = 0,
};

pub const EferFlags = packed struct {
    system_call_extensions: u1 = 0,
    reserved: u63 = 0,
};

pub const SyscallRegs = extern struct {
    _r15: u64 = 0,
    _r14: u64 = 0,
    _r13: u64 = 0,
    _r12: u64 = 0,
    rflags: u64 = @bitCast(Rflags{ .interrupt_enable = 1 }), // r11
    _r10: u64 = 0,
    arg4: u64 = 0, // r9
    arg3: u64 = 0, // r8
    _rbp: u64 = 0,
    arg1: u64 = 0, // rsi
    arg0: u64 = 0, // rdi
    arg2: u64 = 0, // rdx
    user_instr_ptr: u64 = 0, // rcx
    _rbx: u64 = 0,
    syscall_id: u64 = 0, // rax = 0, also the return register
    user_stack_ptr: u64 = 0, // rsp
};

const syscall_enter = std.fmt.comptimePrint(
// interrupts get cleared already
// \\ cli
// save the user stack temporarily into the kernel GS structure
// then load the real kernel stack (because syscall keeps RSP from userland)
// then push the user stack into SyscallRegs
    \\ swapgs
    \\ movq %rsp, %gs:{0d}
    \\ movq %gs:{1d}, %rsp
    \\ pushq %gs:{0d}
    \\ swapgs

    // save all (lol thats a lie) registers
    \\ push %rax
    \\ push %rbx
    \\ push %rcx
    \\ push %rdx
    \\ push %rdi
    \\ push %rsi
    \\ push %rbp
    \\ push %r8
    \\ push %r9
    \\ push %r10
    \\ push %r11
    \\ push %r12
    \\ push %r13
    \\ push %r14
    \\ push %r15

    // set up the *SyscallRegs argument
    \\ movq %rsp, %rdi
, .{ @offsetOf(CpuConfig, "rsp_user"), @offsetOf(CpuConfig, "rsp_kernel") });

const sysret_instr = std.fmt.comptimePrint(
    \\ popq %r15
    \\ popq %r14
    \\ popq %r13
    \\ popq %r12
    \\ popq %r11
    \\ popq %r10
    \\ popq %r9
    \\ popq %r8
    \\ popq %rbp
    \\ popq %rsi
    \\ popq %rdi
    \\ popq %rdx
    \\ popq %rcx
    \\ popq %rbx
    \\ popq %rax

    // load the user stack by temporarily storing
    // the user RSP in the kernel GS structure
    \\ swapgs
    \\ popq %gs:{0d}
    \\ movq %gs:{0d}, %rsp
    \\ swapgs

    // and finally the actual sysret
    // FIXME: NMI,MCE interrupt race condition
    // (https://wiki.osdev.org/SYSENTER#Security_of_SYSRET)
    \\ sysretq
, .{@offsetOf(CpuConfig, "rsp_user")});

pub fn sysret(args: *SyscallRegs) noreturn {
    asm volatile (
    // set stack to be args
        \\ movq %[args], %rsp
        \\
        ++ sysret_instr
        :
        : [args] "r" (args),
        : "memory"
    );

    unreachable;
}

fn syscall_handler_wrapper_wrapper() callconv(.Naked) noreturn {
    asm volatile (syscall_enter ++
            \\
            \\ call syscall_handler_wrapper
            \\
        ++ sysret_instr ::: "memory");

    unreachable;
}

fn syscall_handler_wrapper(args: *SyscallRegs) callconv(.SysV) void {
    main.syscall(args);
}

test "structure sizes" {
    std.testing.expectEqual(8, @sizeOf(GdtDescriptor));
    std.testing.expectEqual(16, @sizeOf(Entry));
    std.testing.expectEqual(8, @sizeOf(PageFaultError));
}
