<div align="center">

# zig-kernel

zig-kernel is the [hyperion](https://github.com/hyperion-os/hyperion) kernel rewritten as a microkernel in pure Zig

the name is very temporary

</div>

## Running in QEMU

```bash
zig build run # thats it
```

## Building an ISO

```bash
zig build # generates the os.iso in zig-out/os.iso
```

## Stuff included here

Despite the name, this repo holds more than just the kernel

 - kernel: [src/kernel](/src/kernel)
 - bootstrap process: [src/bootstrap](src/bootstrap)
 - kernel/user interface: [src/abi](src/abi)

## TODOs and roadmap

### NOTE: /path/to/something is a short form for fs:///path/to/something

The plan is to have the kernel be just a scheduler, IPC relay, vfs protocol "loadbalancer" and a virtual memory manager.

Every path is a URI, where the protocol part (proto://) tells the kernel, which service handles that path. This is kind of like how Redox os does things.

- [x] kernel
  - [x] PMM
  - [x] VMM
  - [x] GDT, TSS, IDT
  - [x] ACPI, APIC
  - [x] user space
  - [ ] HPET
  - [ ] scheduler
  - [ ] binary loader
  - [ ] message IPC, shared memory IPC
  - [ ] figure out userland interrupts (ps2 keyboard, ..)
  - [x] syscalls:
    - [ ] syscall to exec a binary (based on a provided mem map)
    - [ ] syscall to create a vfs proto
    - [ ] syscall to accept a vfs proto cmd
    - [ ] syscall to return a vfs proto cmd result
    - [ ] syscall to read the root kernel cli arg
    - [ ] syscalls for unix sockets

- [x] bootstrap/initfsd process
  - [x] decompress initfs.tar.gz
  - [ ] create initfs:// vfs proto
  - [ ] exec flat binary initfs:///sbin/initd
  - [ ] rename to initfsd
  - [ ] start processing vfs proto cmds

- [ ] initfs:///sbin/initd process
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
