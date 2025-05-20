const builtin = @import("builtin");

pub const LOG_EVERYTHING: bool = false;
pub const LOG_STATS: bool = LOG_EVERYTHING or false;
pub const LOG_GENERIC: bool = LOG_EVERYTHING or false;
pub const LOG_USER: bool = LOG_EVERYTHING or false;

pub const LOG_SYSCALL_STATS: bool = LOG_STATS or false;
pub const LOG_OBJ_ACCESS_STATS: bool = LOG_STATS or false;
pub const LOG_SYSCALLS: bool = LOG_GENERIC or false;
pub const LOG_OBJ_CALLS: bool = LOG_GENERIC or false;
pub const LOG_VMEM: bool = LOG_GENERIC or false;
pub const LOG_CTX_SWITCHES: bool = LOG_GENERIC or false;
pub const LOG_WAITING: bool = LOG_GENERIC or false;
pub const LOG_APIC: bool = LOG_GENERIC or false;
pub const LOG_INTERRUPTS: bool = LOG_GENERIC or false;
pub const LOG_SERVERS: bool = LOG_USER or false;

pub const KERNEL_PANIC_SYSCALL: bool = true;
pub const STACK_TRACE: bool = true;
pub const KERNEL_PANIC_RSOD: bool = true;
pub const KERNEL_PANIC_ON_USER_FAULT: bool = IS_DEBUG or false;
pub const KERNEL_PANIC_SOURCE_INFO: bool = IS_DEBUG or false;

pub const IS_DEBUG = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
