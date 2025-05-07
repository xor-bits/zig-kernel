pub const LOG_EVERYTHING: bool = true;

pub const LOG_SYSCALLS: bool = LOG_EVERYTHING or true;
pub const LOG_OBJ_CALLS: bool = LOG_EVERYTHING or true;
pub const LOG_CTX_SWITCHES: bool = LOG_EVERYTHING or true;
pub const LOG_WAITING: bool = LOG_EVERYTHING or true;
pub const LOG_SERVERS: bool = LOG_EVERYTHING or true;

pub const KERNEL_PANIC_ON_USER_FAULT: bool = true;
