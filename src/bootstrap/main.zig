export fn _start() linksection(".text._start") callconv(.C) noreturn {
    log("hello world");
    while (true) {}
}

pub fn log(s: []const u8) void {
    _ = syscall2(1, @intFromPtr(s.ptr), s.len);
}

pub fn syscall2(id: usize, arg1: usize, arg2: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}
