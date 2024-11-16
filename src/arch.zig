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
                \\ sli
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

    pub const Descriptor = struct {
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

    pub const Gdt = struct {
        null_descriptor: Descriptor,
        descriptors: [4]Descriptor,

        const GdtPtr = packed struct {
            limit: u16,
            base: u64,
        };

        pub const Self = @This();

        pub fn new() Self {
            return Self{
                .null_descriptor = .{ .raw = 0 },
                .descriptors = .{
                    Descriptor.kernel_code,
                    Descriptor.kernel_data,
                    Descriptor.user_data,
                    Descriptor.user_code,
                },
            };
        }

        pub fn load(self: *Self) void {
            loadRaw(&GdtPtr{
                .base = @intFromPtr(self),
                .limit = 5 * @sizeOf(u64) - 1,
            });
        }

        fn loadRaw(ptr: *const GdtPtr) void {
            ints.disable();
            lgdt(@intFromPtr(ptr));
            set_cs(Descriptor.kernel_code_selector);
            set_ss(Descriptor.kernel_data_selector);
            set_ds(Descriptor.kernel_data_selector);
            set_es(Descriptor.kernel_data_selector);
            set_fs(Descriptor.kernel_data_selector);
            set_gs(Descriptor.kernel_data_selector);
        }
    };

    pub const Tss = packed struct {};
};

/// Halt and Catch Fire
pub inline fn hcf() noreturn {
    if (builtin.cpu.arch == .x86_64) {
        x86_64.hcf();
    }
}
