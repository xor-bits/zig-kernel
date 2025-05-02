<div align="center">

# hiillos

hiillos is an operating system with its own microkernel
all written in pure Zig

</div>

The plan is to have the kernel be just a scheduler, IPC relay,
physical memory manager and (probably) a virtual memory manager.

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
    - [ ] Mapping cache modes with PAT, uncacheable, write-combining,
          write-through, write-protect, write-back and uncached
  - [x] GDT, TSS, IDT
  - [x] ACPI, APIC
  - [x] SMP
  - [x] user space
  - [ ] HPET
  - [ ] TSC
  - [x] scheduler
  - [x] binary loader
  - [x] message IPC, shared memory IPC
    - [ ] multiple parallel recvs and calls to the same endpoint
  - [ ] figure out userland interrupts (ps2 keyboard, ..)
  - [x] capabilities
    - [x] allocate capabilities
    - [ ] deallocate capabilities
    - [x] map capabilities
    - [x] unmap capabilities
    - [x] send capabilities
    - [x] disallow mapping a frame twice without cloning the cap
    - [x] disallow overlapping maps
    - [ ] objects
      - [x] Memory
      - [x] Thread
      - [x] Vmem
      - [x] Frame
      - [x] Receiver
      - [x] Sender
      - [x] Notify
  - [x] syscalls

- [x] root + initfsd process
  - [x] decompress initfs.tar.gz
  - [ ] execute initfs:///sbin/init and give it a capability to IPC with the initfs

- [ ] vmm server process
  - [ ] handles virtual memory for everything

- [ ] proc server process
  - [ ] handles individual processes and their threads

- [ ] initfs:///sbin/initd process
  - [ ] launch initfs:///sbin/rngd
  - [ ] launch initfs:///sbin/vfsd
  - [ ] launch services from initfs://
<!---
  - [ ] launch /bin/wm
-->

- [ ] initfs:///sbin/vfsd process
  - [ ] create fs://
  - [ ] exec required root filesystem drivers
  - [ ] read /etc/fstab before mounting root (root= kernel cli arg)
  - [ ] mount everything according to /etc/fstab
  - [ ] exec other filesystem drivers lazily

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
    
![zig-kernel](https://github.com/user-attachments/assets/e508b174-1ccd-4830-aa00-68ec27faba77)

