const std = @import("std");
const builtin = @import("builtin");

//

pub const x86_64 = struct {
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
            ints.disable();
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
            // std.log.info("interrupt at : {x}", .{isr});
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
            entries[0] = Entry.new(interrupt).asInt();
            // debug
            entries[1] = Entry.new(interrupt).asInt();
            // non-maskable interrupt
            entries[2] = Entry.new(interrupt).asInt();
            // breakpoint
            entries[3] = Entry.new(interrupt).asInt();
            // overflow
            entries[4] = Entry.new(interrupt).asInt();
            // bound range exceeded
            entries[5] = Entry.new(interrupt).asInt();
            // invalid opcode
            entries[6] = Entry.new(interrupt).asInt();
            // device not available
            entries[7] = Entry.new(interrupt).asInt();
            // double fault
            entries[8] = Entry.newWithEc(interrupt_ec).asInt();
            // coprocessor segment overrun (useless)
            // entries[9] = 0;
            // invalid tss
            entries[10] = Entry.newWithEc(interrupt_ec).asInt();
            // segment not present
            entries[11] = Entry.newWithEc(interrupt_ec).asInt();
            // stack-segment fault
            entries[12] = Entry.newWithEc(interrupt_ec).asInt();
            // general protection fault
            entries[13] = Entry.newWithEc(interrupt_ec).asInt();
            // page fault
            entries[14] = Entry.generateWithEc(struct {
                fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                    const pfec: PageFaultError = @bitCast(ec);
                    std.log.info("page fault ({any})\nframe: {any}", .{ pfec, interrupt_stack_frame });
                }
            }).asInt();
            // reserved
            // entries[15] = 0;
            // x87 fp exception
            entries[16] = Entry.new(interrupt).asInt();
            // alignment check
            entries[17] = Entry.newWithEc(interrupt_ec).asInt();
            // machine check
            entries[18] = Entry.new(interrupt).asInt();
            // simd fp exception
            entries[19] = Entry.new(interrupt).asInt();
            // virtualization exception
            entries[20] = Entry.new(interrupt).asInt();
            // control protection exception
            entries[21] = Entry.newWithEc(interrupt_ec).asInt();
            // reserved
            // entries[22..27] = 0;
            // hypervisor injection exception
            entries[28] = Entry.new(interrupt).asInt();
            // vmm communication exception
            entries[29] = Entry.newWithEc(interrupt_ec).asInt();
            // security exception
            entries[30] = Entry.newWithEc(interrupt_ec).asInt();
            // reserved
            // entries[31] = 0;
            // triple fault, non catchable

            return Self{
                .ptr = undefined,
                .entries = entries,
            };
        }

        pub fn load(self: *Self) void {
            self.ptr = .{
                .base = @intFromPtr(&self.entries),
                .limit = 256 * @sizeOf(Entry) - 1,
            };
            loadRaw(&self.ptr.limit);
        }

        fn loadRaw(ptr: *anyopaque) void {
            ints.disable();
            lidt(@intFromPtr(ptr));
            ints.enable();
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
        std.log.err("default interrupt: {any} {any}", .{ interrupt_stack_frame, ec });
    }

    fn interrupt(interrupt_stack_frame: *const InterruptStackFrame) callconv(.Interrupt) void {
        std.log.err("default interrupt: {any} ", .{interrupt_stack_frame});
    }

    test "structure sizes" {
        std.testing.expectEqual(8, @sizeOf(GdtDescriptor));
        std.testing.expectEqual(16, @sizeOf(Entry));
        std.testing.expectEqual(8, @sizeOf(PageFaultError));
    }
};

/// Halt and Catch Fire
pub inline fn hcf() noreturn {
    // std.log.info("{*}", .{&x86_64.interrupt});
    if (builtin.cpu.arch == .x86_64) {
        x86_64.hcf();
    }
}
