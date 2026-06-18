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

    return .{ .arch = arch, .libc = libc };
}

fn prepareValkeySource(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) struct {
    step: *std.Build.Step.Run,
    build_dir: []const u8,
    source_dir: []const u8,
    source_src_dir: []const u8,
} {
    const target_str = build_utils.getTargetString(target);
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

    return .{
        .step = prepare,
        .build_dir = build_dir,
        .source_dir = source_dir,
        .source_src_dir = source_src_dir,
    };
}

fn addValkeyStaticBuild(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    source_src_dir: []const u8,
    prepare_step: *std.Build.Step,
) *std.Build.Step.Run {
    const target_str = build_utils.getTargetString(target);
    const target_parts = getTargetParts(target);
    const target_triple = b.fmt("{s}-linux-{s}", .{ target_parts.arch, target_parts.libc });
    const optimize_flag = getMakeOptimize(optimize);

    const make_cmd = b.addSystemCommand(&[_][]const u8{
        "make",
        "-C",
        source_src_dir,
        "libvalkey.a",
        "-j",
        b.fmt("CC={s} cc -target {s}", .{ b.graph.zig_exe, target_triple }),
        b.fmt("AR={s} ar", .{b.graph.zig_exe}),
        b.fmt("RANLIB={s} ranlib", .{b.graph.zig_exe}),
        "MALLOC=libc",
        "BUILD_TLS=no",
        "BUILD_RDMA=no",
        "BUILD_LUA=no",
        "USE_SYSTEMD=no",
        "USE_LIBBACKTRACE=no",
        "CFLAGS=-fPIC -fno-sanitize=undefined -Dmain=valkey_embedded_main",
        "OPTIMIZATION=",
        b.fmt("OPT={s}", .{optimize_flag}),
        "DEBUG=",
    });
    make_cmd.setName(b.fmt("build embedded valkey ({s})", .{target_str}));
    make_cmd.step.dependOn(prepare_step);

    return make_cmd;
}

fn addValkeyWrapperLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib_name: []const u8,
) *std.Build.Step.Compile {
    const prepared = prepareValkeySource(b, target, optimize);
    const make_cmd = addValkeyStaticBuild(b, target, optimize, prepared.source_src_dir, &prepared.step.step);

    const lib = b.addLibrary(.{
        .name = lib_name,
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib.step.dependOn(&make_cmd.step);

    lib.root_module.link_libc = true;
    lib.root_module.addIncludePath(b.path("include"));
    lib.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/src", .{prepared.source_dir}) });
    lib.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/deps/libvalkey/include", .{prepared.source_dir}) });
    lib.root_module.addCSourceFile(.{
        .file = b.path("src/valkey_wrapper.c"),
        .flags = &[_][]const u8{
            "-std=c11",
            "-fPIC",
            "-fvisibility=hidden",
            "-D_DEFAULT_SOURCE",
            "-Wno-error",
        },
    });

    lib.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libvalkey.a", .{prepared.source_src_dir}) });
    lib.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/deps/libvalkey/lib/libvalkey.a", .{prepared.source_dir}) });
    lib.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/deps/hdr_histogram/libhdrhistogram.a", .{prepared.source_dir}) });
    lib.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/deps/fpconv/libfpconv.a", .{prepared.source_dir}) });
    lib.root_module.linkSystemLibrary("dl", .{});
    lib.root_module.linkSystemLibrary("pthread", .{});
    lib.root_module.linkSystemLibrary("rt", .{});

    return lib;
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
    const lib_name = build_utils.getLibName(std.heap.page_allocator, "valkey", target_str);
    const lib = addValkeyWrapperLib(b, target, optimize, lib_name);
    const install = b.addInstallArtifact(lib, .{});

    const hash_step = build_utils.HashAndMoveStep.create(
        b,
        lib_name,
        target_str,
        artifacts_dir,
        hashes,
    );
    hash_step.step.dependOn(&install.step);

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
        const lib = addValkeyWrapperLib(b, target, optimize, "valkey");
        b.installArtifact(lib);
        b.installFile("include/valkey_wrapper.h", "include/valkey_wrapper.h");
    }
}
