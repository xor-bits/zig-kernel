const std = @import("std");

//

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

    const opts = options(b, b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = enabled_features,
        .cpu_features_sub = disabled_features,
    }));

    const abi = createAbi(b, &opts);
    const root_bin = createRootBin(b, &opts, abi);
    const kernel_elf = createKernelElf(b, &opts, abi);
    const initfs_tar_gz = createInitfsTarGz(b, &opts, abi);
    const os_iso = createIso(b, kernel_elf, initfs_tar_gz, root_bin);

    runQemu(b, &opts, os_iso);
}

const Opts = struct {
    native_target: std.Build.ResolvedTarget,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    display: bool,
    debug: u2,
    use_ovmf: bool,
    ovmf_fd: []const u8,
    gdb: bool,
    testing: bool,
    cpus: u8,
};

fn options(b: *std.Build, target: std.Build.ResolvedTarget) Opts {
    return .{
        .native_target = b.standardTargetOptions(.{}),
        .target = target,
        .optimize = b.standardOptimizeOption(.{}),
        .display = b.option(bool, "display", "QEMU gui true/false") orelse true,
        .debug = b.option(u2, "debug", "QEMU debug level") orelse 1,
        .use_ovmf = b.option(
            bool,
            "uefi",
            "use OVMF UEFI to boot in QEMU (OVMF is slower, but has more features) (default: false)",
        ) orelse false,
        .ovmf_fd = b.option([]const u8, "ovmf", "OVMF.fd path") orelse "/usr/share/ovmf/x64/OVMF.fd",
        .gdb = b.option(bool, "gdb", "use GDB") orelse false,
        .testing = b.option(bool, "test", "include test runner") orelse false,
        .cpus = b.option(u8, "cpus", "number of SMP processors") orelse 0,
    };
}

fn runQemu(b: *std.Build, opts: *const Opts, os_iso: std.Build.LazyPath) void {
    // run the os in qemu
    const qemu_step = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        // "-enable-kvm",
        "-machine",
        "q35",
        "-cpu",
        "qemu64,+rdrand,+rdseed,+rdtscp,+rdpid",
        "-m",
        "1g", // 3m is the absolute minimum right now
        // "-M",
        // "smm=off,accel=kvm",
        "-no-reboot",
        "-serial",
        "stdio",
        "-rtc",
        "base=localtime",
        "-vga",
        "std",
        "-usb",
        "-device",
        "virtio-sound",
        "-device",
        "usb-tablet",
        "-drive",
    });
    qemu_step.addPrefixedFileArg("format=raw,file=", os_iso);

    if (opts.cpus >= 2) {
        qemu_step.addArgs(&.{
            "-smp",
            b.fmt("{}", .{opts.cpus}),
        });
    }

    if (opts.display) {
        qemu_step.addArgs(&.{
            "-display",
            "gtk,show-cursor=off",
        });
    } else {
        qemu_step.addArgs(&.{
            "-display",
            "none",
        });
    }

    switch (opts.debug) {
        0 => {},
        1 => qemu_step.addArgs(&.{ "-d", "guest_errors" }),
        2 => qemu_step.addArgs(&.{ "-d", "cpu_reset,guest_errors" }),
        3 => qemu_step.addArgs(&.{ "-d", "int,cpu_reset,guest_errors" }),
    }

    if (opts.use_ovmf) {
        const ovmf_fd = opts.ovmf_fd;
        qemu_step.addArgs(&.{ "-bios", ovmf_fd });
    }

    if (opts.gdb) {
        qemu_step.addArgs(&.{ "-s", "-S" });
    }

    const run_step = b.step("run", "Run in QEMU");
    run_step.dependOn(&qemu_step.step);
    run_step.dependOn(b.getInstallStep());
}

fn createIso(
    b: *std.Build,
    kernel_elf: std.Build.LazyPath,
    initfs_tar_gz: std.Build.LazyPath,
    root_bin: std.Build.LazyPath,
) std.Build.LazyPath {

    // clone & configure limine (WARNING: this runs a Makefile from a dependency at compile time)
    const limine_bootloader_pkg = b.dependency("limine_bootloader", .{});
    // const limine_step = b.addSystemCommand(&.{
    //     "make", "-C",
    // });
    // limine_step.addDirectoryArg(limine_bootloader_pkg.path("."));
    // // limine_step.addPrefixedFileArg("_IGNORED=", limine_bootloader_pkg.path(".").path(b, "limine.c"));
    // limine_step.has_side_effects = false;

    // tool that generates the ISO file with everything
    const wrapper = b.addExecutable(.{
        .name = "xorriso_limine_wrapper",
        .root_source_file = b.path("src/tools/xorriso_limine_wrapper.zig"),
        .target = b.graph.host,
    });

    // create virtual iso root
    const wf = b.addNamedWriteFiles("create virtual iso root");
    _ = wf.addCopyFile(kernel_elf, "boot/kernel.elf");
    _ = wf.addCopyFile(initfs_tar_gz, "boot/initfs.tar.gz");
    _ = wf.addCopyFile(root_bin, "boot/root.bin");
    _ = wf.addCopyFile(b.path("cfg/limine.conf"), "boot/limine/limine.conf");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-bios.sys"), "boot/limine/limine-bios.sys");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-bios-cd.bin"), "boot/limine/limine-bios-cd.bin");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-uefi-cd.bin"), "boot/limine/limine-uefi-cd.bin");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("BOOTIA32.EFI"), "EFI/BOOT/BOOTIA32.EFI");

    // create the ISO file (WARNING: this runs a binary from a dependency (limine_bootloader) at compile time)
    const wrapper_run = b.addRunArtifact(wrapper);
    wrapper_run.addDirectoryArg(limine_bootloader_pkg.path("."));
    wrapper_run.addDirectoryArg(wf.getDirectory());
    const os_iso = wrapper_run.addOutputFileArg("os.iso");
    // wrapper_run.step.dependOn(&limine_step.step);

    const install_iso = b.addInstallFile(os_iso, "os.iso");
    b.getInstallStep().dependOn(&install_iso.step);

    return os_iso;
}

fn createInitfsTarGz(
    b: *std.Build,
    opts: *const Opts,
    abi: *std.Build.Module,
) std.Build.LazyPath {
    const initfs_processes = .{
        "vm",
        "pm",
        "rm",
        "vfs",
        "init",
    };

    // create virtual initfs.tar.gz root
    const initfs = b.addNamedWriteFiles("create virtual initfs root");

    inline for (initfs_processes) |name| {
        const source = std.fmt.comptimePrint("src/userspace/{s}/main.zig", .{name});
        const path = std.fmt.comptimePrint("sbin/{s}", .{name});

        const compile = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(source),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        compile.root_module.addImport("abi", abi);
        b.installArtifact(compile);

        _ = initfs.addCopyFile(compile.getEmittedBin(), path);
    }

    const initfs_tar_gz = b.addSystemCommand(&.{
        "tar",
        "-czf",
    });
    const initfs_tar_gz_file = initfs_tar_gz.addOutputFileArg("initfs.tar.gz");
    initfs_tar_gz.addArg("-C");
    initfs_tar_gz.addDirectoryArg(initfs.getDirectory());
    initfs_tar_gz.addArg(".");

    const install_initfs_tar_gz = b.addInstallFile(initfs_tar_gz_file, "initfs.tar.gz");
    b.getInstallStep().dependOn(&install_initfs_tar_gz.step);

    return initfs_tar_gz_file;
}

fn createKernelElf(
    b: *std.Build,
    opts: *const Opts,
    abi: *std.Build.Module,
) std.Build.LazyPath {
    const git_rev_run = b.addSystemCommand(&.{ "git", "rev-parse", "HEAD" });
    const git_rev = git_rev_run.captureStdOut();
    const git_rev_mod = b.createModule(.{
        .root_source_file = git_rev,
    });

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(git_rev, .prefix, "git-rev").step);

    const kernel_module = b.addModule("kernel", .{
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .code_model = .kernel,
    });
    kernel_module.addImport("limine", b.dependency("limine", .{}).module("limine"));
    kernel_module.addImport("abi", abi);
    kernel_module.addImport("font", createFont(b));
    kernel_module.addImport("git-rev", git_rev_mod);

    if (opts.testing) {
        const testkernel_elf_step = b.addTest(.{
            .name = "kernel.elf",
            // .target = target,
            // .optimize = optimize,
            // .test_runner = .{ .path = b.path("src/kernel/main.zig"), .mode = .simple },
            // .root_source_file = b.path("src/kernel/test.zig"),
            .test_runner = .{ .path = b.path("src/kernel/test.zig"), .mode = .simple },
            .root_module = kernel_module,
        });

        testkernel_elf_step.setLinkerScript(b.path("src/kernel/link/x86_64.ld"));
        // testkernel_elf_step.want_lto = false;
        testkernel_elf_step.pie = false;
        testkernel_elf_step.root_module.addImport("kernel", kernel_module);

        b.installArtifact(testkernel_elf_step);

        return testkernel_elf_step.getEmittedBin();
    } else {
        const kernel_elf_step = b.addExecutable(.{
            .name = "kernel.elf",
            .root_module = kernel_module,
        });

        kernel_elf_step.setLinkerScript(b.path("src/kernel/link/x86_64.ld"));
        // kernel_elf_step.want_lto = false;
        kernel_elf_step.pie = false;

        b.installArtifact(kernel_elf_step);

        return kernel_elf_step.getEmittedBin();
    }
}

// create the embedded root.bin
fn createRootBin(
    b: *std.Build,
    opts: *const Opts,
    abi: *std.Build.Module,
) std.Build.LazyPath {
    const root_elf_step = b.addExecutable(.{
        .name = "root.elf",
        .root_source_file = b.path("src/userspace/root/main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    root_elf_step.root_module.addImport("abi", abi);
    root_elf_step.setLinkerScript(b.path("src/userspace/root/link.ld"));

    const root_bin_step = b.addObjCopy(root_elf_step.getEmittedBin(), .{
        .format = .bin,
    });
    root_bin_step.step.dependOn(&root_elf_step.step);

    const root_elf_install = b.addInstallFile(root_elf_step.getEmittedBin(), "root.elf");
    b.getInstallStep().dependOn(&root_elf_install.step);

    const install_root_bin = b.addInstallFile(root_bin_step.getOutput(), "root.bin");
    b.getInstallStep().dependOn(&install_root_bin.step);

    return root_bin_step.getOutput();
}

// create the shared ABI library
fn createAbi(b: *std.Build, opts: *const Opts) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/abi/lib.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });

    mod.addAnonymousImport("build-zon", .{
        .root_source_file = b.path("build.zig.zon"),
    });

    return mod;
}

// convert the font.bmp into a more usable format
fn createFont(b: *std.Build) *std.Build.Module {
    const font_tool = b.addExecutable(.{
        .name = "generate_font",
        .root_source_file = b.path("src/tools/generate_font.zig"),
        .target = b.graph.host,
    });

    const font_tool_run = b.addRunArtifact(font_tool);
    font_tool_run.addFileArg(b.path("asset/font.bmp"));
    const font_zig = font_tool_run.addOutputFileArg("font.zig");
    font_tool_run.has_side_effects = false;

    return b.createModule(.{
        .root_source_file = font_zig,
    });
}
