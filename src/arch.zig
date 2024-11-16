const builtin = @import("builtin");

//

pub const x86_64 = struct {
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
};

/// Halt and Catch Fire
pub inline fn hcf() noreturn {
    if (builtin.cpu.arch == .x86_64) {
        x86_64.hcf();
    }
}
