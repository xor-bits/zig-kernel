<div align="center">

# hiillos

hiillos is an operating system with its own microkernel
all written in pure Zig

</div>

The plan is for the kernel to be just a scheduler, IPC relay and a physical memory manager.

The system uses seL4-like capabilities, but on a global linear array instead of the CNode tree.
And physical memory allocation is managed by the kernel.

## Running in QEMU

```bash
zig build run # thats it

# read 'Project-Specific Options' from `zig build --help` for more options
zig build run -Dtest=true # include custom unit test runner
```

## Building an ISO

```bash
zig build # generates the os.iso in zig-out/os.iso
```

### Development environment run cmd

```bash
zig build run --prominent-compile-errors --summary none -freference-trace \
 -Doptimize=ReleaseSmall -Duefi=false -Ddebug=1 -Dgdb=false -Ddisplay=false -Dtest=true
```

## Stuff included here

 - kernel: [src/kernel](/src/kernel)
 - kernel/user interface: [src/abi](src/abi)
 - root process: [src/userspace/root](src/userspace/root)

## TODOs and roadmap

### NOTE: /path/to/something is a short form for fs:///path/to/something

- [x] kernel
  - [x] PMM
  - [x] VMM
    - [x] VMM arch implementation back in the kernel,
          user-space vmm manages mapping of capabilities
          to the (single per thread) vmem capability.
          Frame should be the only mappable capability
          and it is dynamically sized: `0x1000 * 2^size`.
    - [x] Mapping cache modes with PAT, uncacheable, write-combining,
          write-through, write-protect, write-back and uncached
  - [x] GDT, TSS, IDT
  - [x] ACPI, APIC
  - [x] SMP
  - [x] HPET
  - [ ] TSC
  - [x] scheduler
  - [x] binary loader
  - [x] stack tracer with line info
  - [x] message IPC, shared memory IPC
    - [ ] multiple parallel recvs to the same endpoint
    - [x] multiple parallel calls to the same endpoint
  - [x] figure out userland interrupts (ps2 keyboard, ..)
  - [x] capabilities
    - [x] allocate capabilities
    - [ ] deallocate capabilities
    - [x] map capabilities
    - [x] unmap capabilities
    - [x] send capabilities
    - [x] disallow mapping a frame twice without cloning the cap
    - [x] disallow overlapping maps
    - [ ] restrict capability rights, ex: read-only frame can only create read-only frames
    - [ ] scrap the derivation tree, use refcounts like Zircon
    - [ ] per process handle tables, allowing more dynamic kernel object metadata (user handle (u32) is an index to process local table, which holds a pointer (and rights) to a kernel object)
    - [ ] objects
      - [x] Memory
      - [x] Thread
      - [x] Vmem
      - [x] Frame
        - [ ] multiple Frame caps to the same physical memory (for shared memory)
        - [ ] lazy alloc
      - [x] DeviceFrame
      - [x] Receiver
      - [x] Sender
      - [x] Reply
      - [x] Notify
  - [x] syscalls
    - [ ] move all object methods to be syscalls
    - [ ] syscall tracker
    - [ ] method call tracker

- [x] user-space
  - [ ] stack traces with line info

- [x] root + initfsd process
  - [x] decompress initfs.tar.gz
  - [ ] execute initfs:///sbin/init and give it a capability to IPC with the initfs

- [x] initfs:///sbin/vm server process
  - [ ] handles virtual memory for everything

- [x] initfs:///sbin/pm server process
  - [ ] handles individual processes and their threads

- [x] initfs:///sbin/rm server process
  - [ ] launches a PS/2 keyboard driver if it detects a PS/2 keyboard

- [ ] initfs:///sbin/timer server process
  - [ ] launches a HPET driver

- [x] initfs:///sbin/vfs server process
  - [ ] create fs://
  - [ ] exec required root filesystem drivers
  - [ ] read /etc/fstab before mounting root (root= kernel cli arg)
  - [ ] mount everything according to /etc/fstab
  - [ ] exec other filesystem drivers lazily

- [x] initfs:///sbin/init process
  - [ ] launch initfs:///sbin/rngd
  - [ ] launch initfs:///sbin/vfsd
  - [ ] launch services from initfs://
<!---
  - [ ] launch /bin/wm
-->

- [ ] initfs:///sbin/fsd.fat32

- [ ] initfs:///sbin/rngd process

- [ ] /sbin/inputd process

- [ ] /sbin/outputd process

- [ ] /sbin/kbd process

- [ ] /sbin/moused process

- [ ] /sbin/timed process

- [ ] /sbin/fbd process

- [ ] /sbin/pcid process

- [ ] /sbin/usbd process

## IPC performance

Approximate synchronous IPC performance: `call` + `replyRecv`
loop takes about 10µs (100 000 per second):

```zig
// server
while (true) {
    try rx.replyRecv(&msg);
}
// client
while (true) {
    try tx.call(&msg);
}
```

## Gallery
    
![image](https://github.com/user-attachments/assets/e508b174-1ccd-4830-aa00-68ec27faba77)
![image](https://github.com/user-attachments/assets/a11dbcd1-6afb-4f2f-ba08-40af514a712b)

