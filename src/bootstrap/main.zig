export fn _start() linksection(".text._start") callconv(.C) noreturn {
    asm volatile (
        \\ syscall
    );
    unreachable;
}
