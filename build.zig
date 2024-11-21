const std = @import("std");

pub fn build(b: *std.Build) !void {
    const Target = std.Target;
    const Feature = Target.x86.Feature;

    // kernel mode code cannot use fpu so use software impl instead
    var enabled_features = Target.Cpu.Feature.Set.empty;
    enabled_features.addFeature(@intFromEnum(Feature.soft_float));

    // kernel mode code cannot use these features (except maybe after they are enabled)
    var disabled_features = Target.Cpu.Feature.Set.empty;
    disabled_features.addFeature(@intFromEnum(Feature.mmx));
    disabled_features.addFeature(@intFromEnum(Feature.sse));
    disabled_features.addFeature(@intFromEnum(Feature.sse2));
    disabled_features.addFeature(@intFromEnum(Feature.avx));
    disabled_features.addFeature(@intFromEnum(Feature.avx2));
    disabled_features.addFeature(@intFromEnum(Feature.mmx));

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = enabled_features,
        .cpu_features_sub = disabled_features,
    });

    const optimize = b.standardOptimizeOption(.{});

    // convert the font.bmp into a more usable format
    const font_tool = b.addExecutable(.{
        .name = "generate kernel font",
        .root_source_file = b.path("tools/generate_font.zig"),
        .target = b.host,
    });

    const font_tool_run = b.addRunArtifact(font_tool);
    const font_zig = font_tool_run.addOutputFileArg("font.zig");

    // build the bootstrap.bin
    const bootstrap_elf_step = b.addExecutable(.{
        .name = "bootstrap.elf",
        .root_source_file = b.path("./src/bootstrap/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bootstrap_elf_step.setLinkerScript(b.path("./src/bootstrap/link.ld"));

    const bootstrap_bin_step = b.addObjCopy(bootstrap_elf_step.getEmittedBin(), .{
        .format = .bin,
    });

    const install_bootstrap_bin = b.addInstallFile(bootstrap_bin_step.getOutput(), "bootstrap.bin");
    b.getInstallStep().dependOn(&install_bootstrap_bin.step);

    // build the kernel ELF
    const kernel_elf_step = b.addExecutable(.{
        .name = "kernel.elf",
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
    });
    kernel_elf_step.setLinkerScript(b.path("linker/x86_64.ld"));
    kernel_elf_step.want_lto = false;
    kernel_elf_step.root_module.addImport("limine", b.dependency("limine", .{}).module("limine"));
    kernel_elf_step.root_module.addAnonymousImport("font", .{
        .root_source_file = font_zig,
    });
    kernel_elf_step.root_module.addAnonymousImport("bootstrap", .{
        .root_source_file = bootstrap_bin_step.getOutput(),
    });

    kernel_elf_step.step.dependOn(&bootstrap_bin_step.step);
    kernel_elf_step.step.dependOn(&font_tool_run.step);

    b.installArtifact(kernel_elf_step);

    // clone & configure limine (WARNING: this runs a Makefile from a dependency at compile time)
    const limine_bootloader_pkg = b.dependency("limine_bootloader", .{});
    const limine_step = b.addSystemCommand(&.{
        "make", "-C",
    });
    limine_step.addDirectoryArg(limine_bootloader_pkg.path("."));

    // create virtual iso root
    const wf = b.addNamedWriteFiles("create virtual iso root");
    _ = wf.addCopyFile(kernel_elf_step.getEmittedBin(), "boot/kernel.elf");
    _ = wf.addCopyFile(b.path("limine.conf"), "boot/limine/limine.conf");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-bios.sys"), "boot/limine/limine-bios.sys");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-bios-cd.bin"), "boot/limine/limine-bios-cd.bin");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-uefi-cd.bin"), "boot/limine/limine-uefi-cd.bin");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("BOOTIA32.EFI"), "EFI/BOOT/BOOTIA32.EFI");
    wf.step.dependOn(&kernel_elf_step.step);
    wf.step.dependOn(&limine_step.step);

    // create the ISO file
    const xorriso_step = b.addSystemCommand(&.{
        "xorriso",
        "-as",
        "mkisofs",
        "-b",
        "boot/limine/limine-bios-cd.bin",
        "-no-emul-boot",
        "-boot-load-size",
        "4",
        "-boot-info-table",
        "--efi-boot",
        "boot/limine/limine-uefi-cd.bin",
        "-efi-boot-part",
        "--efi-boot-image",
        "--protective-msdos-label",
    });
    xorriso_step.addDirectoryArg(wf.getDirectory());
    xorriso_step.addArg("-o");
    const os_iso = xorriso_step.addOutputFileArg("os.iso");
    xorriso_step.step.dependOn(&wf.step);

    // install limine bootloader BIOS on that ISO file (WARNING: this runs a binary from a dependency at compile time)
    const limine_install_step = b.addSystemCommand(&.{
        limine_bootloader_pkg.path("limine").getPath(b),
        "bios-install",
    });
    limine_install_step.addFileArg(os_iso);
    limine_install_step.step.dependOn(&xorriso_step.step);

    // run the os in qemu
    const qemu_step = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        // "-enable-kvm",
        "-machine",
        "q35",
        "-cpu",
        "qemu64,+rdrand,+rdseed,+rdtscp,+rdpid",
        // "-smp",
        // "4",
        "-m",
        "1g",
        // "-M",
        // "smm=off,accel=kvm",
        "-no-reboot",
        "-serial",
        "stdio",
        "-rtc",
        "base=localtime",
        "-vga",
        "std",
        "-display",
        "gtk,show-cursor=off",
        "-usb",
        "-device",
        "virtio-sound",
        "-device",
        "usb-tablet",
        "-drive",
    });
    qemu_step.addPrefixedFileArg("format=raw,file=", os_iso);
    qemu_step.step.dependOn(&limine_install_step.step);

    const debug = b.option(u2, "debug", "QEMU debug level") orelse 1;
    switch (debug) {
        0 => {},
        1 => {
            qemu_step.addArgs(&.{ "-d", "guest_errors" });
        },
        2 => {
            qemu_step.addArgs(&.{ "-d", "cpu_reset,guest_errors" });
        },
        3 => {
            qemu_step.addArgs(&.{ "-d", "int,cpu_reset,guest_errors" });
        },
    }

    const use_ovmf = b.option(
        bool,
        "uefi",
        "use OVMF UEFI to boot in QEMU (OVMF is slower, but has more features) (default: false)",
    ) orelse false;
    if (use_ovmf) {
        const ovmf_fd = std.posix.getenv("OVMF_FD") orelse "/usr/share/ovmf/x64/OVMF.fd";
        qemu_step.addArgs(&.{ "-bios", ovmf_fd });
    }

    const install_iso = b.addInstallFile(os_iso, "os.iso");
    b.getInstallStep().dependOn(&install_iso.step);

    const run_step = b.step("run", "Run in QEMU");
    run_step.dependOn(&qemu_step.step);

    b.default_step.dependOn(&limine_install_step.step);
}
