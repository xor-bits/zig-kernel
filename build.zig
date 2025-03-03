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
    const native_target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const abi = createAbi(b, target, optimize);

    // build the bootstrap.bin
    const bootstrap_bin = createBootstrapBin(b, target, optimize, abi);

    // build the kernel ELF
    const kernel_elf = createKernelElf(b, target, optimize, abi, bootstrap_bin);

    const initfs_tar_gz = createInitfsTarGz(target, optimize, abi, b);

    const os_iso = createIso(b, native_target, optimize, kernel_elf, initfs_tar_gz);

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

    const gdb = b.option(bool, "gdb", "use GDB") orelse false;
    if (gdb) {
        qemu_step.addArgs(&.{ "-s", "-S" });
    }

    const install_iso = b.addInstallFile(os_iso, "os.iso");
    b.getInstallStep().dependOn(&install_iso.step);

    const run_step = b.step("run", "Run in QEMU");
    run_step.dependOn(&qemu_step.step);
}

fn createIso(
    b: *std.Build,
    native_target: std.Build.ResolvedTarget,
    native_optimize: std.builtin.OptimizeMode,
    kernel_elf: std.Build.LazyPath,
    initfs_tar_gz: std.Build.LazyPath,
) std.Build.LazyPath {
    _ = native_optimize; // autofix
    _ = native_target; // autofix

    // clone & configure limine (WARNING: this runs a Makefile from a dependency at compile time)
    const limine_bootloader_pkg = b.dependency("limine_bootloader", .{});
    const limine_step = b.addSystemCommand(&.{
        "make", "-C",
    });
    limine_step.addDirectoryArg(limine_bootloader_pkg.path("."));
    // limine_step.addPrefixedFileArg("_IGNORED=", limine_bootloader_pkg.path(".").path(b, "limine.c"));
    limine_step.has_side_effects = false;

    // tool that generates the ISO file with everything
    const wrapper = b.addExecutable(.{
        .name = "xorriso_limine_wrapper",
        .root_source_file = b.path("./tools/xorriso_limine_wrapper.zig"),
        .target = b.graph.host,
    });

    // create virtual iso root
    const wf = b.addNamedWriteFiles("create virtual iso root");
    _ = wf.addCopyFile(kernel_elf, "boot/kernel.elf");
    _ = wf.addCopyFile(initfs_tar_gz, "boot/initfs.tar.gz");
    _ = wf.addCopyFile(b.path("limine.conf"), "boot/limine/limine.conf");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-bios.sys"), "boot/limine/limine-bios.sys");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-bios-cd.bin"), "boot/limine/limine-bios-cd.bin");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-uefi-cd.bin"), "boot/limine/limine-uefi-cd.bin");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("BOOTIA32.EFI"), "EFI/BOOT/BOOTIA32.EFI");

    // create the ISO file (WARNING: this runs a binary from a dependency (limine_bootloader) at compile time)
    const wrapper_run = b.addRunArtifact(wrapper);
    wrapper_run.addFileArg(limine_bootloader_pkg.path("limine"));
    wrapper_run.addDirectoryArg(wf.getDirectory());
    const os_iso = wrapper_run.addOutputFileArg("os.iso");
    wrapper_run.step.dependOn(&limine_step.step);

    return os_iso;
}

fn createInitfsTarGz(
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    abi: *std.Build.Module,
    b: *std.Build,
) std.Build.LazyPath {
    // create initfs:///sbin/init
    const init = b.addExecutable(.{
        .name = "init",
        .root_source_file = b.path("./src/init/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    init.root_module.addImport("abi", abi);
    b.installArtifact(init);

    // create virtual initfs.tar.gz root
    const initfs = b.addNamedWriteFiles("create virtual initfs root");
    _ = initfs.addCopyFile(init.getEmittedBin(), "sbin/init");
    initfs.step.dependOn(&init.step);

    const initfs_tar_gz = b.addSystemCommand(&.{
        "tar",
        "-czf",
    });
    const initfs_tar_gz_file = initfs_tar_gz.addOutputFileArg("initfs.tar.gz");
    initfs_tar_gz.addArg("-C");
    initfs_tar_gz.addDirectoryArg(initfs.getDirectory());
    initfs_tar_gz.addArg(".");
    initfs_tar_gz.step.dependOn(&init.step);
    initfs_tar_gz.step.dependOn(&initfs.step);

    const install_initfs_tar_gz = b.addInstallFile(initfs_tar_gz_file, "initfs.tar.gz");
    b.getInstallStep().dependOn(&install_initfs_tar_gz.step);

    return initfs_tar_gz_file;
}

fn createKernelElf(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    abi: *std.Build.Module,
    bootstrap_bin: *std.Build.Module,
) std.Build.LazyPath {
    const git_rev_run = b.addSystemCommand(&.{ "git", "rev-parse", "HEAD" });
    const git_rev = git_rev_run.captureStdOut();
    const git_rev_mod = b.createModule(.{
        .root_source_file = git_rev,
    });

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(git_rev, .prefix, "git-rev").step);

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
    kernel_elf_step.root_module.addImport("abi", abi);
    kernel_elf_step.root_module.addImport("font", createFont(b));
    kernel_elf_step.root_module.addImport("bootstrap", bootstrap_bin);
    kernel_elf_step.root_module.addImport("git-rev", git_rev_mod);

    b.installArtifact(kernel_elf_step);

    return kernel_elf_step.getEmittedBin();
}

// create the embedded bootstrap.bin
fn createBootstrapBin(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    abi: *std.Build.Module,
) *std.Build.Module {
    const bootstrap_elf_step = b.addExecutable(.{
        .name = "bootstrap.elf",
        .root_source_file = b.path("./src/bootstrap/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bootstrap_elf_step.root_module.addImport("abi", abi);
    bootstrap_elf_step.setLinkerScript(b.path("./src/bootstrap/link.ld"));

    const bootstrap_bin_step = b.addObjCopy(bootstrap_elf_step.getEmittedBin(), .{
        .format = .bin,
    });
    bootstrap_bin_step.step.dependOn(&bootstrap_elf_step.step);

    const install_bootstrap_bin = b.addInstallFile(bootstrap_bin_step.getOutput(), "bootstrap.bin");
    b.getInstallStep().dependOn(&install_bootstrap_bin.step);

    return b.createModule(.{
        .root_source_file = bootstrap_bin_step.getOutput(),
    });
}

// create the shared ABI library
fn createAbi(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("./src/abi/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
}

// convert the font.bmp into a more usable format
fn createFont(b: *std.Build) *std.Build.Module {
    const font_tool = b.addExecutable(.{
        .name = "generate_font",
        .root_source_file = b.path("tools/generate_font.zig"),
        .target = b.graph.host,
    });

    const font_tool_run = b.addRunArtifact(font_tool);
    font_tool_run.addFileArg(b.path("./tools/font.bmp"));
    const font_zig = font_tool_run.addOutputFileArg("font.zig");
    font_tool_run.has_side_effects = false;

    return b.createModule(.{
        .root_source_file = font_zig,
    });
}
