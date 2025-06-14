const std = @import("std");
const abi = @import("abi");
const limine = @import("limine");

const addr = @import("../addr.zig");
const apic = @import("../apic.zig");
const logs = @import("../logs.zig");
const main = @import("../main.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");

const log = std.log.scoped(.arch);
const conf = abi.conf;

//

pub const IA32_APIC_BASE = 0x1B;
pub const IA32_PAT_MSR = 0x277;
pub const IA32_X2APIC = 0x800; // the low MSR, goes from 0x800 to 0x8FF
pub const IA32_TCS_AUX = 0xC0000103;
pub const EFER = 0xC0000080;
pub const STAR = 0xC0000081;
pub const LSTAR = 0xC0000082;
pub const SFMASK = 0xC0000084;
pub const GS_BASE = 0xC0000101;
pub const KERNELGS_BASE = 0xC0000102;

//

pub export var smp: limine.SmpRequest = .{};
var next: std.atomic.Value(usize) = .init(0);

//

pub fn earlyInit() void {
    // interrupts are always disabled in the kernel
    // there is just one exception to this:
    // waiting while the CPU is out of tasks
    //
    // initializing GDT also requires interrupts to be disabled
    ints.disable();

    // logging uses the GS register to print the cpu id
    // and the GS register contents might be undefined on boot
    // so quickly reset it to 0 temporarily
    wrmsr(GS_BASE, 0);
}

pub fn initCpu(id: u32, smpinfo: ?*limine.SmpInfo) !void {
    const lapic_id = if (smpinfo) |i|
        i.lapic_id
    else if (smp.response) |resp|
        resp.bsp_lapic_id
    else
        0;

    const tls = try pmem.page_allocator.create(main.CpuLocalStorage);
    tls.* = .{
        .self_ptr = tls,
        .cpu_config = undefined,
        .id = id,
        .lapic_id = @truncate(lapic_id),
    };

    try CpuConfig.init(&tls.cpu_config, id);

    wrmsr(GS_BASE, @intFromPtr(tls));
    wrmsr(KERNELGS_BASE, 0);

    // the PAT MSR value is set so that the old modes stay the same
    // log.info("default PAT = 0x{x}", .{rdmsr(IA32_PAT_MSR)});
    wrmsr(IA32_PAT_MSR, abi.sys.CacheType.patMsr());
    // log.info("PAT = 0x{x}", .{abi.sys.CacheType.patMsr()});
}

// launch 2 next processors (snowball)
pub fn smpInit() void {
    if (smp.response) |resp| {
        var idx = next.fetchAdd(2, .monotonic);
        const cpus = resp.cpus();

        if (idx >= cpus.len) return;
        if (cpus[idx].lapic_id != resp.bsp_lapic_id)
            cpus[idx].goto_address = _smpstart;

        idx += 1;
        if (idx >= resp.cpus().len) return;
        if (cpus[idx].lapic_id != resp.bsp_lapic_id)
            cpus[idx].goto_address = _smpstart;
    }
}

export fn _smpstart(smpinfo: *limine.SmpInfo) callconv(.C) noreturn {
    earlyInit();
    main.smpmain(smpinfo);
}

pub fn cpuLocal() *main.CpuLocalStorage {
    return asm volatile (std.fmt.comptimePrint(
            \\ movq %gs:{d}, %[cls]
        , .{@offsetOf(main.CpuLocalStorage, "self_ptr")})
        : [cls] "={rax}" (-> *main.CpuLocalStorage),
    );
}

pub fn swapgs() void {
    asm volatile (
        \\ swapgs
    );
}

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

pub fn ioWait() void {
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

pub fn setCs(sel: u64) void {
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

pub fn setSs(sel: u16) void {
    asm volatile (
        \\ movw %[v], %ss
        :
        : [v] "r" (sel),
    );
}

pub fn setDs(sel: u16) void {
    asm volatile (
        \\ movw %[v], %ds
        :
        : [v] "r" (sel),
    );
}

pub fn setEs(sel: u16) void {
    asm volatile (
        \\ movw %[v], %es
        :
        : [v] "r" (sel),
    );
}

pub fn setFs(sel: u16) void {
    asm volatile (
        \\ movw %[v], %fs
        :
        : [v] "r" (sel),
    );
}

pub fn setGs(sel: u16) void {
    asm volatile (
        \\ movw %[v], %gs
        :
        : [v] "r" (sel),
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

pub const CpuFeatures = packed struct {
    sse3: bool,
    pclmul: bool,
    dtes64: bool,
    monitor: bool,
    ds_cpl: bool,
    vmx: bool,
    smx: bool,
    est: bool,
    tm2: bool,
    ssse3: bool,
    cid: bool,
    sdbg: bool,
    fma: bool,
    cx16: bool,
    xtpr: bool,
    pdcm: bool,
    _reserved0: bool,
    pcid: bool,
    dca: bool,
    sse4_1: bool,
    sse4_2: bool,
    x2apic: bool,
    movbe: bool,
    popcnt: bool,
    tsc_ecx: bool,
    aes: bool,
    xsave: bool,
    osxsave: bool,
    avx: bool,
    f16c: bool,
    rdrand: bool,
    hypervisor: bool,
    fpu: bool,
    vme: bool,
    de: bool,
    pse: bool,
    tsc_edx: bool,
    msr: bool,
    pae: bool,
    mce: bool,
    cx8: bool,
    apic: bool,
    _reserved1: bool,
    sep: bool,
    mtrr: bool,
    pge: bool,
    mca: bool,
    cmov: bool,
    pat: bool,
    pse36: bool,
    psn: bool,
    clflush: bool,
    _reserved2: bool,
    ds: bool,
    acpi: bool,
    mmx: bool,
    fxsr: bool,
    sse: bool,
    sse2: bool,
    ss: bool,
    htt: bool,
    tm: bool,
    ia64: bool,
    pbe: bool,

    pub fn read() @This() {
        const result = cpuid(1, 0);
        return @bitCast([2]u32{ result.ecx, result.edx });
    }
};

pub fn wrcr3(sel: u64) void {
    asm volatile (
        \\ mov %[v], %cr3
        :
        : [v] "N{rdx}" (sel),
        : "memory"
    );
}

pub fn rdcr3() u64 {
    return asm volatile (
        \\ mov %cr3, %[v]
        : [v] "={rdx}" (-> u64),
    );
}

pub fn flushTlb() void {
    wrcr3(rdcr3());
}

pub fn flushTlbAddr(vaddr: usize) void {
    asm volatile (
        \\ invlpg (%[v])
        :
        : [v] "r" (vaddr),
        : "memory"
    );
}

/// processor ID
pub fn cpuId() u32 {
    return cpuLocal().id;
}

pub fn cpuIdSafe() ?u32 {
    const gs = rdmsr(GS_BASE);
    if (gs == 0) return null;
    return cpuLocal().id;
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
        setCs(GdtDescriptor.kernel_code_selector);
        setSs(GdtDescriptor.kernel_data_selector);
        setDs(GdtDescriptor.kernel_data_selector);
        setEs(GdtDescriptor.kernel_data_selector);
        setFs(GdtDescriptor.kernel_data_selector);
        setGs(GdtDescriptor.kernel_data_selector);
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

    fn new() !@This() {
        const Stack = [0x8000]u8;

        var res = @This(){};

        var stack: *Stack = try pmem.page_allocator.create(Stack);
        res.privilege_stacks[0] = @sizeOf(Stack) + @intFromPtr(stack);
        stack = try pmem.page_allocator.create(Stack);
        res.privilege_stacks[1] = @sizeOf(Stack) + @intFromPtr(stack);
        stack = try pmem.page_allocator.create(Stack);
        res.interrupt_stacks[0] = @sizeOf(Stack) + @intFromPtr(stack);

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
    gate_type: u1,
    _1: u3 = 0b111,
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

    /// LLVM generated ISR
    pub fn generate(comptime handler: anytype) Self {
        const HandlerWrapper = struct {
            fn interrupt(interrupt_stack_frame: *const InterruptStackFrame) callconv(.Interrupt) void {
                const is_user = interrupt_stack_frame.code_segment == @as(u16, GdtDescriptor.user_code_selector);
                if (is_user) swapgs();
                defer if (is_user) swapgs();

                handler.handler(interrupt_stack_frame);
            }
        };

        return Self.new(HandlerWrapper.interrupt);
    }

    /// LLVM generated ISR
    pub fn generateWithEc(comptime handler: anytype) Self {
        const HandlerWrapper = struct {
            fn interrupt(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) callconv(.Interrupt) void {
                const is_user = interrupt_stack_frame.code_segment == @as(u16, GdtDescriptor.user_code_selector);
                if (is_user) swapgs();
                defer if (is_user) swapgs();

                handler.handler(interrupt_stack_frame, ec);
            }
        };

        return Self.newWithEc(HandlerWrapper.interrupt);
    }

    /// custom ISR with `*arch.SyscallRegs` support
    pub fn generateTrap(comptime handler: anytype) Self {
        const HandlerWrapper = struct {
            fn interrupt() callconv(.naked) noreturn {
                asm volatile (SyscallRegs.push ++
                        \\ xorq %rbp, %rbp
                        // set up the *SyscallRegs argument
                        \\ movq %rsp, %rdi
                        \\ call {wrapper}
                    ++ SyscallRegs.pop ++
                        \\ iretq
                    :
                    : [wrapper] "r" (@intFromPtr(&wrapper)),
                    : "memory"
                );
            }

            fn wrapper(rsp: u64) void {
                const trap: *SyscallRegs = @ptrFromInt(rsp);
                const interrupt_stack_frame: *const InterruptStackFrame = @ptrFromInt(rsp - @sizeOf(InterruptStackFrame));

                const is_user = interrupt_stack_frame.code_segment == @as(u16, GdtDescriptor.user_code_selector);
                if (is_user) swapgs();
                defer if (is_user) swapgs();

                handler.handler(trap, interrupt_stack_frame);
            }
        };

        return Self.newAny(@intFromPtr(&HandlerWrapper.interrupt));
    }

    /// custom ISR with `*arch.SyscallRegs` support
    pub fn generateTrapWithEc(comptime handler: anytype) Self {
        const HandlerWrapper = struct {
            fn interrupt() callconv(.naked) noreturn {
                const instr =
                    // push a dummy rsp and all other regs
                    \\ push %rax
                ++ SyscallRegs.push ++
                    \\
                    // \\ cld
                    // \\ xorq %rbp, %rbp
                    // set up the *SyscallRegs argument
                    \\ movq %rsp, %rdi
                    \\ movq %[f], %%rax
                    // @sizeOf(SyscallRegs) is 128, so the stack is aligned to 0x10
                    \\ call *%%rax

                    // pop all other regs and discard the dummy rsp and discard the error code
                ++ SyscallRegs.pop ++
                    \\ add $16, %rsp
                    \\ iretq
                ;

                asm volatile (instr
                    :
                    : [f] "i" (&wrapper),
                    : "memory"
                );
            }

            fn wrapper(rsp: u64) callconv(.SysV) void {
                const trap: *SyscallRegs = @ptrFromInt(rsp);
                const ec: *const u64 = @ptrFromInt(rsp + @sizeOf(SyscallRegs));
                const interrupt_stack_frame: *const InterruptStackFrame = @ptrFromInt(rsp + @sizeOf(SyscallRegs) + 8);

                const is_user = interrupt_stack_frame.code_segment == @as(u16, GdtDescriptor.user_code_selector);
                if (is_user) swapgs();
                defer if (is_user) swapgs();

                // replace the dummy values with the real values
                // $$$ FIXME: sysretq doesnt preserve RCX and R11 unlike iretq
                trap.user_instr_ptr = interrupt_stack_frame.ip;
                trap.user_stack_ptr = interrupt_stack_frame.sp;
                trap.rflags = @bitCast(interrupt_stack_frame.cpu_flags);

                handler.handler(trap, interrupt_stack_frame, ec.*);
            }
        };

        return Self.newAny(@intFromPtr(&HandlerWrapper.interrupt));
    }

    fn newAny(isr: usize) Self {
        // log.info("interrupt at : {x}", .{isr});
        return Self{
            .offset_0_15 = @truncate(isr & 0xFFFF),
            .segment_selector = GdtDescriptor.kernel_code_selector,
            .interrupt_stack = 0,
            .gate_type = 0, // 0 for interrupt gate, 1 for trap gate
            .dpl = 0,
            .present = 1,
            .offset_16_31 = @truncate((isr >> 16) & 0xFFFF),
            .offset_32_63 = @truncate((isr >> 32) & 0xFFFFFFFF),
        };
    }

    fn missing() Self {
        return Self{
            .offset_0_15 = 0,
            .segment_selector = 0,
            .interrupt_stack = 0,
            .gate_type = 0,
            .dpl = 0,
            .present = 0,
            .offset_16_31 = 0,
            .offset_32_63 = 0,
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

pub const FaultCause = enum {
    read,
    write,
    exec,
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
                if (conf.LOG_EVERYTHING) log.debug("division error interrupt", .{});

                log.err("division error\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // debug
        entries[1] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EVERYTHING) log.debug("debug interrupt", .{});

                log.err("debug\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // non-maskable interrupt
        entries[2] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EVERYTHING) log.debug("non-maskable interrupt", .{});

                log.info("non-maskable interrupt\nframe: {any}", .{interrupt_stack_frame});
            }
        }).asInt();
        // breakpoint
        entries[3] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EVERYTHING) log.debug("breakpoint interrupt", .{});

                log.info("breakpoint\nframe: {any}", .{interrupt_stack_frame});
            }
        }).asInt();
        // overflow
        entries[4] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EVERYTHING) log.debug("overflow interrupt", .{});

                log.err("overflow\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // bound range exceeded
        entries[5] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EVERYTHING) log.debug("bound range exceeded interrupt", .{});

                log.err("bound range exceeded\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // invalid opcode
        entries[6] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EVERYTHING) log.debug("invalid opcode interrupt", .{});

                log.err("invalid opcode\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // device not available
        entries[7] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EVERYTHING) log.debug("device not available interrupt", .{});

                log.err("device not available\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // double fault
        entries[8] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_EVERYTHING) log.debug("double fault interrupt", .{});

                log.err("double fault (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // coprocessor segment overrun (useless)
        entries[9] = Entry.missing().asInt();
        // invalid tss
        entries[10] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_EVERYTHING) log.debug("invalid TSS interrupt", .{});

                log.err("invalid tss (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // segment not present
        entries[11] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_EVERYTHING) log.debug("segment not present interrupt", .{});

                log.err("segment not present (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // stack-segment fault
        entries[12] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_EVERYTHING) log.debug("stack-segment fault interrupt", .{});

                log.err("stack-segment fault (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // general protection fault
        entries[13] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                const is_user = interrupt_stack_frame.code_segment == @as(u16, GdtDescriptor.user_code_selector);
                if (conf.LOG_EVERYTHING) log.debug("general protection fault interrupt", .{});

                log.warn(
                    \\general protection fault (0x{x})
                    \\ - user: {}
                    \\ - ip: 0x{x}
                    \\ - sp: 0x{x}
                , .{
                    ec,
                    is_user,
                    interrupt_stack_frame.ip,
                    interrupt_stack_frame.sp,
                });

                if (is_user and !conf.KERNEL_PANIC_ON_USER_FAULT) {
                    log.warn("user", .{});
                    cpuLocal().current_thread.?.status = .stopped;
                    proc.enter();
                } else {
                    log.warn("kernel", .{});
                    std.debug.panic(
                        \\unhandled general protection fault (0x{x})
                        \\ - user: {}
                        \\ - ip: 0x{x}
                        \\ - sp: 0x{x}
                        \\ - line:
                        \\{}
                    , .{
                        ec,
                        is_user,
                        interrupt_stack_frame.ip,
                        interrupt_stack_frame.sp,
                        logs.Addr2Line{ .addr = interrupt_stack_frame.ip },
                    });
                }
            }
        }).withStack(2).asInt();
        // page fault
        entries[14] = Entry.generateTrapWithEc(struct {
            fn handler(_: *SyscallRegs, interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                const pfec: PageFaultError = @bitCast(ec);
                const target_addr = Cr2.read().page_fault_addr;

                if (conf.LOG_EVERYTHING) log.debug("general protection fault interrupt", .{});

                const caused_by: FaultCause = if (pfec.caused_by_write)
                    .write
                else if (pfec.instruction_fetch)
                    .exec
                else
                    .read;

                const thread = cpuLocal().current_thread.?;

                const vaddr = addr.Virt.fromUser(target_addr) catch |err| {
                    log.warn("unhandled page fault: {}", .{err});
                    thread.unhandledPageFault(
                        target_addr,
                        caused_by,
                        interrupt_stack_frame.ip,
                        interrupt_stack_frame.sp,
                        err,
                    );
                };

                if (pfec.user_mode and !conf.KERNEL_PANIC_ON_USER_FAULT) {
                    thread.proc.vmem.pageFault(caused_by, vaddr) catch |err| {
                        log.warn("unhandled page fault: {}", .{err});
                        thread.unhandledPageFault(
                            target_addr,
                            caused_by,
                            interrupt_stack_frame.ip,
                            interrupt_stack_frame.sp,
                            err,
                        );
                    };

                    // log.warn(
                    //     \\page fault 0x{x}
                    //     \\ - user: {any}
                    //     \\ - caused by write: {any}
                    //     \\ - instruction fetch: {any}
                    //     \\ - ip: 0x{x}
                    //     \\ - sp: 0x{x}
                    //     \\ - pfec: {}
                    // , .{
                    //     target_addr,
                    //     pfec.user_mode,
                    //     pfec.caused_by_write,
                    //     pfec.instruction_fetch,
                    //     interrupt_stack_frame.ip,
                    //     interrupt_stack_frame.sp,
                    //     pfec,
                    // });

                    // log.info("trap={}", .{trap});
                    // sysret(trap);
                    return;
                }

                std.debug.panic(
                    \\unhandled page fault 0x{x}
                    \\ - user: {any}
                    \\ - caused by write: {any}
                    \\ - instruction fetch: {any}
                    \\ - ip: 0x{x}
                    \\ - sp: 0x{x}
                    \\ - pfec: {}
                    \\ - line:
                    \\{}
                , .{
                    target_addr,
                    pfec.user_mode,
                    pfec.caused_by_write,
                    pfec.instruction_fetch,
                    interrupt_stack_frame.ip,
                    interrupt_stack_frame.sp,
                    pfec,
                    logs.Addr2Line{ .addr = interrupt_stack_frame.ip },
                });
            }
        }).withStack(1).asInt();
        // reserved
        entries[15] = Entry.missing().asInt();
        // x87 fp exception
        entries[16] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_INTERRUPTS) log.debug("x87 fp exception interrupt", .{});

                log.err("x87 fp exception\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // alignment check
        entries[17] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_INTERRUPTS) log.debug("alignment check interrupt", .{});

                log.err("alignment check (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // machine check
        entries[18] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_INTERRUPTS) log.debug("machine check interrupt", .{});

                log.err("machine check\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // simd fp exception
        entries[19] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_INTERRUPTS) log.debug("simd fp exception interrupt", .{});

                log.err("simd fp exception\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // virtualization exception
        entries[20] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_INTERRUPTS) log.debug("virtualization exception interrupt", .{});

                log.err("virtualization exception\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // control protection exception
        entries[21] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_INTERRUPTS) log.debug("control protection exception interrupt", .{});

                log.err("control protection exce (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled GPF", .{});
            }
        }).asInt();
        // reserved
        for (entries[22..27]) |*e| {
            e.* = Entry.missing().asInt();
        }
        // hypervisor injection exception
        entries[28] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_INTERRUPTS) log.debug("hypervisor injection exception interrupt", .{});

                log.err("hypervisor injection exception\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // vmm communication exception
        entries[29] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_INTERRUPTS) log.debug("vmm communication exception interrupt", .{});

                log.err("vmm communication excep (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled GPF", .{});
            }
        }).asInt();
        // security exception
        entries[30] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_INTERRUPTS) log.debug("security exception interrupt", .{});

                log.err("security exception (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled GPF", .{});
            }
        }).asInt();
        // reserved
        entries[31] = Entry.missing().asInt();
        // triple fault, non catchable

        // spurious PIC interrupts
        for (entries[32..41]) |*entry| {
            entry.* = Entry.generate(struct {
                fn handler(_: *const InterruptStackFrame) void {}
            }).asInt();
        }

        entries[apic.IRQ_SPURIOUS] = Entry.generate(struct {
            fn handler(_: *const InterruptStackFrame) void {
                if (conf.LOG_INTERRUPTS) log.debug("APIC spurious interrupt", .{});

                apic.eoi();
            }
        }).asInt();
        entries[apic.IRQ_TIMER] = Entry.generate(struct {
            fn handler(_: *const InterruptStackFrame) void {
                if (conf.LOG_INTERRUPTS) log.debug("APIC timer interrupt", .{});

                apic.eoi();
            }
        }).asInt();
        entries[apic.IRQ_IPI] = Entry.generate(struct {
            fn handler(_: *const InterruptStackFrame) void {
                if (conf.LOG_INTERRUPTS) log.debug("APIC IPI interrupt", .{});

                apic.eoi();
            }
        }).asInt();
        entries[apic.IRQ_IPI_PANIC] = Entry.generate(struct {
            fn handler(_: *const InterruptStackFrame) void {
                if (conf.LOG_INTERRUPTS) log.debug("kernel panic interrupt", .{});

                // log.err("CPU-{} done", .{cpuLocal().id});
                hcf();
            }
        }).asInt();
        entries[apic.IRQ_IPI_TLB_SHOOTDOWN] = Entry.generate(struct {
            fn handler(_: *const InterruptStackFrame) void {
                if (conf.LOG_INTERRUPTS) log.debug("kernel panic interrupt", .{});

                flushTlb();
                apic.eoi();
            }
        }).asInt();

        inline for (0..apic.IRQ_AVAIL_COUNT) |i| {
            entries[i + apic.IRQ_AVAIL_LOW] = Entry.generate(struct {
                pub fn handler(_: *const InterruptStackFrame) void {
                    if (conf.LOG_INTERRUPTS) log.debug("user-space {} interrupt", .{i});

                    // log.info("extra interrupt i=0x{x}", .{i + IRQ_AVAIL_LOW});
                    defer apic.eoi();

                    const notify = cpuLocal().interrupt_handlers[i].load() orelse return;
                    defer notify.deinit();

                    _ = notify.notify();
                }
            }).asInt();
        }

        return Self{
            .ptr = undefined,
            .entries = entries,
        };
    }

    pub fn load(self: *Self, size_override: ?u16) void {
        self.ptr = .{
            .base = @intFromPtr(&self.entries),
            .limit = size_override orelse (self.entries.len * @sizeOf(Entry) - 1),
        };
        loadRaw(&self.ptr.limit);
    }

    fn loadRaw(ptr: *anyopaque) void {
        lidt(@intFromPtr(ptr));
    }
};

pub const InterruptStackFrame = extern struct {
    /// the instruction right after the instruction that caused this interrupt
    ip: usize,

    /// code privilege level before the interrupt
    code_segment: u16,

    /// RFlags
    cpu_flags: Rflags,

    /// stack pointer before the interrupt
    sp: usize,

    /// stack(data) privilege level before the interrupt
    stack_segment: u16,
};

pub const InterruptStackFrameRaw = extern struct {
    ip: usize,
    code_segment: u64,
    cpu_flags: Rflags,
    sp: usize,
    stack_segment: u64,
};

fn interruptEc(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) callconv(.Interrupt) void {
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

    pub fn init(self: *@This(), id: u32) !void {
        self.tss = try Tss.new();
        self.gdt = Gdt.new(&self.tss);
        self.idt = Idt.new();

        // initialize GDT (, TSS) and IDT
        // log.debug("loading new GDT", .{});
        self.gdt.load();
        // log.debug("loading new IDT", .{});
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

        // // initialize CPU identification for scheduling purposes
        // wrmsr(IA32_TCS_AUX, this_cpu_id);
        // log.info("CPU ID set: {d}", .{cpuId()});

        self.rsp_kernel = self.tss.privilege_stacks[0];
        self.rsp_user = 0;

        // initialize syscall and sysret instructions
        wrmsr(
            STAR,
            (@as(u64, GdtDescriptor.user_data_selector - 8) << 48) |
                (@as(u64, GdtDescriptor.kernel_code_selector) << 32),
        );

        // RIP of the syscall jump destination
        wrmsr(LSTAR, @intFromPtr(&syscallHandlerWrapperWrapper));

        // bits that are 1 clear a bit from rflags when a syscall happens
        // setting interrupt_enable here disables interrupts on syscall
        wrmsr(SFMASK, @bitCast(Rflags{ .interrupt_enable = 1 }));

        const efer_flags: u64 = @bitCast(EferFlags{ .system_call_extensions = 1 });
        wrmsr(EFER, rdmsr(EFER) | efer_flags);
        log.info("syscalls initialized for CPU-{}", .{id});
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
    pcid: u12 = 0,
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
    reserved0: u1 = 1,
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
    arg5: u64 = 0, // r10
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

    pub fn readMessage(self: *const @This()) abi.sys.Message {
        return @bitCast([6]u64{
            self.arg0,
            self.arg1,
            self.arg2,
            self.arg3,
            self.arg4,
            self.arg5,
        });
    }

    pub fn writeMessage(self: *@This(), msg: abi.sys.Message) void {
        const regs: [6]u64 = @bitCast(msg);
        self.arg0 = regs[0];
        self.arg1 = regs[1];
        self.arg2 = regs[2];
        self.arg3 = regs[3];
        self.arg4 = regs[4];
        self.arg5 = regs[5];
    }

    pub const push =
        \\
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
        \\
    ;

    pub const pop =
        \\
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
        \\
    ;
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
++ SyscallRegs.push ++
    \\ xorq %rbp, %rbp
    // set up the *SyscallRegs argument
    \\ movq %rsp, %rdi
,
    .{ @offsetOf(CpuConfig, "rsp_user"), @offsetOf(CpuConfig, "rsp_kernel") },
);

const sysret_instr = std.fmt.comptimePrint(
    SyscallRegs.pop ++
        // load the user stack by temporarily storing
        // the user RSP in the kernel GS structure
        \\ popq %gs:{0d}
        \\ movq %gs:{0d}, %rsp
        \\ swapgs

        // and finally the actual sysret
        // FIXME: NMI,MCE interrupt race condition
        // (https://wiki.osdev.org/SYSENTER#Security_of_SYSRET)
        \\ sysretq
    ,
    .{@offsetOf(CpuConfig, "rsp_user")},
);

pub fn sysret(args: *SyscallRegs) noreturn {
    const instr =
        \\ movq %[args], %rsp
        \\
    ++ sysret_instr;
    asm volatile (instr
        :
        : [args] "r" (args),
        : "memory"
    );
    unreachable;
}

fn syscallHandlerWrapperWrapper() callconv(.Naked) noreturn {
    const instr = syscall_enter ++
        \\
        \\ call syscallHandlerWrapper
        \\
    ++ sysret_instr;
    asm volatile (instr ::: "memory");
}

export fn syscallHandlerWrapper(args: *SyscallRegs) callconv(.SysV) void {
    main.syscall(args);
}

test "structure sizes" {
    try std.testing.expectEqual(8, @sizeOf(GdtDescriptor));
    try std.testing.expectEqual(16, @sizeOf(Entry));
    try std.testing.expectEqual(8, @sizeOf(PageFaultError));
}
