export fn _start() linksection(".text._start") callconv(.C) noreturn {
    asm volatile (
        \\ infiniteloop:
        \\ jmp infiniteloop
        // \\ syscall
        \\
    );
    unreachable;
}
