const std = @import("std");

const Lib = struct {
    name: []const u8,
    root: []const u8,
    system: []const []const u8,
    deps: []const []const u8,
};

const libs = [_]Lib{
    .{ .name = "gstreamer-1.0", .root = "gst/core.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gmodule-2.0" }, .deps = &.{} },
};

fn gstIncludeDir(b: *std.Build) []const u8 {
    const dir = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=includedir", "gstreamer-1.0" }), " \n");
    return b.pathJoin(&.{ dir, "gstreamer-1.0" });
}

fn gstModule(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, system: []const []const u8) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .link_libc = true,
    });
    mod.addIncludePath(.{ .cwd_relative = gstIncludeDir(b) });
    mod.addIncludePath(b.path("gst"));
    for (system) |s| mod.linkSystemLibrary(s, .{});
    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "run tests");

    for (libs) |l| {
        const lib = b.addLibrary(.{
            .name = l.name,
            .linkage = .dynamic,
            .version = .{ .major = 0, .minor = 2802, .patch = 0 },
            .root_module = gstModule(b, l.root, target, optimize, l.system),
        });
        b.installArtifact(lib);
        const t = b.addTest(.{ .root_module = gstModule(b, l.root, target, optimize, l.system) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const c_mod = gstModule(b, "tests/diff/c.zig", target, optimize, &.{ "gobject-2.0", "glib-2.0" });
    const diff_step = b.step("diff", "build the differential tests");
    for ([_][]const u8{ "object", "buffer", "caps", "misc", "pool", "taglist", "toc", "streams", "event", "message", "query", "clock" }) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    const gate = b.addExecutable(.{
        .name = "abi-gate",
        .root_module = b.createModule(.{ .root_source_file = b.path("abi/gate.zig"), .target = target, .optimize = optimize }),
    });
    const run_gate = b.addRunArtifact(gate);
    run_gate.addFileArg(b.path("abi/required.txt"));
    run_gate.addArg(b.getInstallPath(.lib, ""));
    if (b.args) |a| run_gate.addArgs(a);
    run_gate.step.dependOn(b.getInstallStep());
    b.step("gate", "compare exported symbols with the required GStreamer ABI").dependOn(&run_gate.step);
}
