pub const Id = enum(usize) {
    log = 1,
};

pub fn log(s: []const u8) void {
    _ = call2(@intFromEnum(Id.log), @intFromPtr(s.ptr), s.len);
}

//

pub fn call2(id: usize, arg1: usize, arg2: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}
