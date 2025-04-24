<div align="center">

# hiillos

hiillos is the [hyperion](https://github.com/hyperion-os/hyperion) kernel rewritten as a microkernel in pure Zig

</div>

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

### Developement environment run cmd

```bash
zig build run --prominent-compile-errors --summary none -freference-trace \
 -Doptimize=ReleaseSmall -Duefi=false -Ddebug=1 -Dgdb=false -Ddisplay=false -Dtest=true
```

## Stuff included here

 - kernel: [src/kernel](/src/kernel)
 - bootstrap process: [src/bootstrap](src/bootstrap)
 - kernel/user interface: [src/abi](src/abi)

## TODOs and roadmap

### NOTE: /path/to/something is a short form for fs:///path/to/something

The plan is to have the kernel be just a scheduler, IPC relay,
physical memory manager and maybe a virtual memory manager.

The system uses seL4-like capabilities, but on a global linear array instead of the CNode tree.
And physical memory allocation is managed by the kernel.

- [x] kernel
  - [x] PMM
  - [x] VMM
  - [x] GDT, TSS, IDT
  - [x] ACPI, APIC
  - [ ] SMP
  - [x] user space
  - [ ] HPET
  - [x] scheduler
  - [x] binary loader
  - [ ] message IPC, shared memory IPC
  - [ ] figure out userland interrupts (ps2 keyboard, ..)
  - [x] syscalls:

- [x] bootstrap/initfsd process
  - [x] decompress initfs.tar.gz
  - [x] create initfs:// vfs proto
  - [x] exec initfs:///sbin/initd
  - [ ] rename to initfsd
  - [x] start processing vfs proto cmds

- [x] initfs:///sbin/initd process
  - [ ] launch initfs:///sbin/rngd
  - [ ] launch initfs:///sbin/vfsd
  - [ ] launch services from initfs://
<!---
  - [ ] launch /bin/wm
-->

- [ ] initfs:///sbin/rngd process
  - [ ] create rng:// vfs proto
  - [ ] start processing vfs proto cmds

- [ ] /sbin/inputd process

- [ ] /sbin/outputd process

- [ ] /sbin/kbd process

- [ ] /sbin/moused process

- [ ] /sbin/timed process

- [ ] /sbin/fbd process

- [ ] /sbin/pcid process

- [ ] /sbin/usbd process

- [ ] initfs:///sbin/vfsd process
  - [ ] create fs:// vfs proto
  - [ ] get the root device with syscall (either device or fstab for initfs:///etc/fstab)
  - [ ] exec required root filesystem drivers
  - [ ] mount root (root= kernel cli arg) to /
  - [ ] remount root using /etc/fstab
  - [ ] exec other filesystem drivers lazily
  - [ ] mount everything according to /etc/fstab
  - [ ] start processing vfs proto cmds

- [ ] initfs:///sbin/fsd.fat32
  - [ ] connect to the /sbin/vfsd process using a unix socket
  - [ ] register a fat32 filesystem
  - [ ] start processing cmds
     
![zig-kernel](https://github.com/user-attachments/assets/e508b174-1ccd-4830-aa00-68ec27faba77)

