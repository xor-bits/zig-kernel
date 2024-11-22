export fn _start() linksection(".text._start") callconv(.C) noreturn {
    asm volatile (
        \\ infiniteloop:
        \\ syscall
        \\ jmp infiniteloop
        \\
    );
    unreachable;
}
