const std = @import("std");

const Lib = struct {
    name: []const u8,
    root: []const u8,
    system: []const []const u8,
    deps: []const []const u8,
    dest: ?[]const u8 = null,
};

const libs = [_]Lib{
    .{ .name = "gstreamer-1.0", .root = "gst/core.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gmodule-2.0" }, .deps = &.{} },
    .{ .name = "gstbase-1.0", .root = "gst/base.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0" }, .deps = &.{} },
    .{ .name = "gsttag-1.0", .root = "gst/tag.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "zlib" }, .deps = &.{} },
    .{ .name = "gstaudio-1.0", .root = "gst/audio.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-tag-1.0", "m" }, .deps = &.{}, .dest = "staging" },
    .{ .name = "gstapp-1.0", .root = "gst/app.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0" }, .deps = &.{} },
};

fn gstIncludeDir(b: *std.Build) []const u8 {
    const dir = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=includedir", "gstreamer-1.0" }), " \n");
    return b.pathJoin(&.{ dir, "gstreamer-1.0" });
}

fn pkgVar(b: *std.Build, name: []const u8, fallback: []const u8) []const u8 {
    var code: u8 = 0;
    const r = b.runAllowFail(&.{ "pkg-config", b.fmt("--variable={s}", .{name}), "gstreamer-1.0" }, &code, .ignore) catch return fallback;
    const v = std.mem.trim(u8, r, " \n");
    return if (v.len == 0) fallback else v;
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

    const config = b.addOptions();
    config.addOption([]const u8, "plugin_dir", b.option([]const u8, "plugin-dir", "system plugin directory") orelse pkgVar(b, "pluginsdir", "/usr/lib/gstreamer-1.0"));
    config.addOption([]const u8, "scanner_dir", b.option([]const u8, "scanner-dir", "directory of gst-plugin-scanner") orelse pkgVar(b, "pluginscannerdir", "/usr/libexec/gstreamer-1.0"));

    for (libs) |l| {
        const root = gstModule(b, l.root, target, optimize, l.system);
        root.addOptions("config", config);
        const lib = b.addLibrary(.{
            .name = l.name,
            .linkage = .dynamic,
            .version = .{ .major = 0, .minor = 2802, .patch = 0 },
            .root_module = root,
            .use_llvm = true,
        });
        if (l.dest) |d| {
            b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = d } } }).step);
        } else {
            b.installArtifact(lib);
        }
        const tm = gstModule(b, l.root, target, optimize, l.system);
        tm.addOptions("config", config);
        const t = b.addTest(.{ .root_module = tm, .use_llvm = true });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const c_mod = gstModule(b, "tests/diff/c.zig", target, optimize, &.{ "gobject-2.0", "glib-2.0" });
    const diff_step = b.step("diff", "build the differential tests");
    for ([_][]const u8{ "object", "buffer", "caps", "misc", "pool", "taglist", "toc", "streams", "event", "message", "query", "clock", "bus", "task", "pad", "element", "bin", "pipeline", "ghostpad", "registry", "parse", "uri", "extras", "helpers", "logging", "control", "dot", "real", "quarks" }) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    for ([_][]const u8{ "bytereader", "bytewriter", "bits", "baseutil", "adapter", "dataqueue", "typefind", "basesrc", "basesink", "basetransform", "aggregator", "collectpads", "baseparse" }) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstbase-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    for ([_][]const u8{ "tag", "id3v2", "xmp", "exif", "tagelems", "realtag" }) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-tag-1.0", "gstreamer-base-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0", "zlib" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    for ([_][]const u8{ "audio1", "audio2", "audio3", "audio4", "audio5" }) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-audio-1.0", "gstreamer-tag-1.0", "gstreamer-base-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    for ([_][]const u8{ "audio6", "audio7" }) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-audio-1.0", "gstreamer-app-1.0", "gstreamer-tag-1.0", "gstreamer-base-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    for ([_][]const u8{"app"}) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-app-1.0", "gstreamer-base-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    {
        const m = gstModule(b, "tools/tagdata.zig", target, optimize, &.{ "gstreamer-tag-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = "tagdata", .root_module = m, .use_llvm = true });
        b.step("tagdata", "build the tag table extractor").dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
    {
        const m = gstModule(b, "tools/gen.zig", target, optimize, &.{ "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = "gen", .root_module = m, .use_llvm = true });
        b.step("gen", "build the table generator").dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    for ([_][]const u8{ "sintytest", "sintyfail", "sintycrash", "notaplugin", "sintyparse" }) |name| {
        const m = gstModule(b, b.fmt("tests/plugins/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const lib = b.addLibrary(.{ .name = b.fmt("gst{s}", .{name}), .linkage = .dynamic, .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = "testplugins" } } }).step);
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
