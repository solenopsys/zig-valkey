const std = @import("std");
const build_utils = @import("build_utils.zig");

const TargetParts = struct {
    arch: []const u8,
    libc: []const u8,
};

fn getMakeOptimize(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "-O0",
        .ReleaseSafe => "-O2",
        .ReleaseFast => "-O3",
        .ReleaseSmall => "-Os",
    };
}

fn getTargetParts(target: std.Build.ResolvedTarget) TargetParts {
    if (target.result.os.tag != .linux) {
        std.debug.panic("valkey wrapper supports linux targets only, got {s}", .{
            @tagName(target.result.os.tag),
        });
    }

    const arch = switch (target.result.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => std.debug.panic("unsupported cpu arch for valkey: {s}", .{
            @tagName(target.result.cpu.arch),
        }),
    };

    const libc = switch (target.result.abi) {
        .gnu, .gnueabi, .gnueabihf => "gnu",
        .musl, .musleabi, .musleabihf => "musl",
        else => std.debug.panic("unsupported abi for valkey: {s}", .{
            @tagName(target.result.abi),
        }),
    };

    return .{
        .arch = arch,
        .libc = libc,
    };
}

fn addValkeyServerBuild(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exe_name: []const u8,
) *std.Build.Step.InstallFile {
    const target_str = build_utils.getTargetString(target);
    const target_parts = getTargetParts(target);
    const target_triple = b.fmt("{s}-linux-{s}", .{ target_parts.arch, target_parts.libc });
    const optimize_flag = getMakeOptimize(optimize);

    const build_dir = b.fmt(".zig-cache/valkey/{s}/{s}", .{ target_str, @tagName(optimize) });
    const source_dir = b.fmt("{s}/source", .{build_dir});
    const source_src_dir = b.fmt("{s}/src", .{source_dir});

    const prepare = b.addSystemCommand(&[_][]const u8{
        "sh",
        "-c",
        "rm -rf \"$2\" && mkdir -p \"$1\" && cp -a vendor/valkey \"$2\" && sed -i 's/#define HAVE_X86_SIMD 1/#define HAVE_X86_SIMD 0/' \"$2/src/config.h\"",
        "prepare-valkey",
        build_dir,
        source_dir,
    });
    prepare.setName(b.fmt("prepare valkey ({s})", .{target_str}));

    const make_cmd = b.addSystemCommand(&[_][]const u8{
        "make",
        "-C",
        source_src_dir,
        "valkey-server",
        "-j",
        b.fmt("CC={s} cc -target {s}", .{ b.graph.zig_exe, target_triple }),
        b.fmt("AR={s} ar", .{b.graph.zig_exe}),
        b.fmt("RANLIB={s} ranlib", .{b.graph.zig_exe}),
        "MALLOC=libc",
        "BUILD_TLS=no",
        "BUILD_RDMA=no",
        "USE_SYSTEMD=no",
        "USE_LIBBACKTRACE=no",
        "CFLAGS=-fno-sanitize=undefined",
        "OPTIMIZATION=",
        b.fmt("OPT={s}", .{optimize_flag}),
        "DEBUG=",
    });
    make_cmd.setName(b.fmt("build valkey-server ({s})", .{target_str}));
    make_cmd.step.dependOn(&prepare.step);

    const built_server = b.fmt("{s}/valkey-server", .{source_src_dir});
    const install_server = b.addInstallFileWithDir(
        .{ .cwd_relative = built_server },
        .bin,
        exe_name,
    );
    install_server.step.dependOn(&make_cmd.step);

    return install_server;
}

fn buildForTarget(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    artifacts_dir: []const u8,
    hashes: *std.StringHashMap([]const u8),
    json_step: *build_utils.WriteJsonStep,
) void {
    const target_str = build_utils.getTargetString(target);
    const exe_name = build_utils.getExeName(std.heap.page_allocator, "valkey-server", target_str);
    const install_server = addValkeyServerBuild(b, target, optimize, exe_name);

    const hash_step = build_utils.HashAndMoveExeStep.create(
        b,
        exe_name,
        target_str,
        artifacts_dir,
        hashes,
    );
    hash_step.step.dependOn(&install_server.step);

    json_step.step.dependOn(&hash_step.step);
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const artifacts_dir = "../../artifacts/libs";
    const json_path = "current.json";

    const build_all = b.option(bool, "all", "Build for all supported targets") orelse false;

    if (build_all) {
        const hashes = build_utils.createHashMap(b);
        const json_step = build_utils.WriteJsonStep.create(b, hashes, json_path);

        for (build_utils.supported_targets) |query| {
            const target = b.resolveTargetQuery(query);
            buildForTarget(b, target, optimize, artifacts_dir, hashes, json_step);
        }

        b.default_step.dependOn(&json_step.step);
    } else {
        const target = b.standardTargetOptions(.{});
        const install_server = addValkeyServerBuild(b, target, optimize, "valkey-server");
        b.getInstallStep().dependOn(&install_server.step);
    }
}
