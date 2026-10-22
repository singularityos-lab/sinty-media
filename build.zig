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
    .{ .name = "gstaudio-1.0", .root = "gst/audio.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-tag-1.0", "m" }, .deps = &.{} },
    .{ .name = "gstapp-1.0", .root = "gst/app.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0" }, .deps = &.{} },
    .{ .name = "gstallocators-1.0", .root = "gst/allocators.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "libdrm" }, .deps = &.{} },
    .{ .name = "gstcontroller-1.0", .root = "gst/controller.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "m" }, .deps = &.{} },
    .{ .name = "gstnet-1.0", .root = "gst/net.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gio-2.0", "gstreamer-1.0" }, .deps = &.{} },
    .{ .name = "gstfft-1.0", .root = "gst/fft.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "m" }, .deps = &.{} },
    .{ .name = "gstgl-1.0", .root = "gst/gl.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gmodule-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-video-1.0", "gstreamer-allocators-1.0", "egl", "gl", "wayland-client", "wayland-cursor", "wayland-egl", "x11", "x11-xcb", "xcb", "gudev-1.0", "libdrm", "gbm" }, .deps = &.{} },
    .{ .name = "gstvideo-1.0", .root = "gst/video.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-allocators-1.0", "m" }, .deps = &.{} },
    .{ .name = "gstpbutils-1.0", .root = "gst/pbutils.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-tag-1.0", "gstreamer-audio-1.0", "gstreamer-video-1.0" }, .deps = &.{} },
};

fn gstIncludeDir(b: *std.Build) []const u8 {
    const dir = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=includedir", "gstreamer-1.0" }), " \n");
    return b.pathJoin(&.{ dir, "gstreamer-1.0" });
}

fn pkgVar(b: *std.Build, name: []const u8, fallback: []const u8) []const u8 {
    return pkgVarOf(b, "gstreamer-1.0", name, fallback);
}

fn pkgVarOf(b: *std.Build, pkg: []const u8, name: []const u8, fallback: []const u8) []const u8 {
    var code: u8 = 0;
    const r = b.runAllowFail(&.{ "pkg-config", b.fmt("--variable={s}", .{name}), pkg }, &code, .ignore) catch return fallback;
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
    mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ pkgVar(b, "libdir", "/usr/lib"), "gstreamer-1.0", "include" }) });
    mod.addIncludePath(b.path("gst"));
    for ([_][]const u8{ "libdrm", "gudev-1.0", "opus", "ogg" }) |pc| {
        var code: u8 = 0;
        const out = b.runAllowFail(&.{ "pkg-config", "--cflags-only-I", pc }, &code, .ignore) catch continue;
        var it = std.mem.tokenizeAny(u8, out, " \n");
        while (it.next()) |flag| {
            if (std.mem.startsWith(u8, flag, "-I")) mod.addIncludePath(.{ .cwd_relative = flag[2..] });
        }
    }
    for (system) |s| mod.linkSystemLibrary(s, .{});
    return mod;
}

fn relativeTo(base: []const u8, path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, base) and path.len > base.len and path[base.len] == '/') return path[base.len + 1 ..];
    return std.mem.trimStart(u8, path, "/");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "run tests");

    const config = b.addOptions();
    config.addOption([]const u8, "plugin_dir", b.option([]const u8, "plugin-dir", "system plugin directory") orelse pkgVar(b, "pluginsdir", "/usr/lib/gstreamer-1.0"));
    config.addOption([]const u8, "locale_dir", b.option([]const u8, "locale-dir", "gettext locale directory") orelse "/usr/share/locale");
    config.addOption([]const u8, "data_dir", b.option([]const u8, "data-dir", "system data directory") orelse "/usr/share");
    config.addOption([]const u8, "install_helper", b.option([]const u8, "install-helper", "plugin installation helper") orelse "/usr/libexec/gst-install-plugins-helper");
    config.addOption([]const u8, "scanner_dir", b.option([]const u8, "scanner-dir", "directory of gst-plugin-scanner") orelse pkgVar(b, "pluginscannerdir", "/usr/libexec/gstreamer-1.0"));

    const prefix = pkgVar(b, "prefix", "/usr");
    const libexec = pkgVar(b, "libexecdir", "/usr/libexec");
    config.addOption([]const u8, "ptp_helper", b.option([]const u8, "ptp-helper", "installed gst-ptp-helper") orelse b.pathJoin(&.{ libexec, "gstreamer-1.0", "gst-ptp-helper" }));
    config.addOption([]const u8, "plugin_subdir", relativeTo(prefix, pkgVar(b, "libdir", "/usr/lib")));
    config.addOption([]const u8, "helper_subdir", relativeTo(prefix, libexec));

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

    const plugin_opts = b.addOptions();
    plugin_opts.addOption([]const u8, "package", b.option([]const u8, "plugin-package", "package name shown by plugins") orelse "sinty-media");
    plugin_opts.addOption([]const u8, "gio_module_dir", pkgVarOf(b, "gio-2.0", "giomoduledir", "/usr/lib/gio/modules"));
    plugin_opts.addOption([]const u8, "gio_prefix", pkgVarOf(b, "gio-2.0", "prefix", "/usr"));
    plugin_opts.addOption([]const u8, "origin", b.option([]const u8, "plugin-origin", "origin shown by plugins") orelse "https://sinty.dev");
    const plugins = [_]struct { name: []const u8, root: []const u8, system: []const []const u8 }{
        .{ .name = "coreelements", .root = "plugins/coreelements.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0" } },
        .{ .name = "audioconvert", .root = "plugins/audioconvert.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-audio-1.0" } },
        .{ .name = "audioresample", .root = "plugins/audioresample.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-audio-1.0" } },
        .{ .name = "videotestsrc", .root = "plugins/videotestsrc.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-video-1.0" } },
        .{ .name = "audiotestsrc", .root = "plugins/audiotestsrc.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-audio-1.0" } },
        .{ .name = "volume", .root = "plugins/volume.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-audio-1.0" } },
        .{ .name = "basedebug", .root = "plugins/basedebug.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-video-1.0" } },
        .{ .name = "overlaycomposition", .root = "plugins/overlaycomposition.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-video-1.0" } },
        .{ .name = "dsd", .root = "plugins/dsd.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-audio-1.0" } },
        .{ .name = "audiorate", .root = "plugins/audiorate.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-audio-1.0" } },
        .{ .name = "videoconvertscale", .root = "plugins/videoconvertscale.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-video-1.0" } },
        .{ .name = "pbtypes", .root = "plugins/pbtypes.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-video-1.0", "gstreamer-audio-1.0" } },
        .{ .name = "typefindfunctions", .root = "plugins/typefindfunctions.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-pbutils-1.0", "gstreamer-video-1.0", "gstreamer-audio-1.0" } },
        .{ .name = "playback", .root = "plugins/playback.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-pbutils-1.0", "gstreamer-video-1.0", "gstreamer-audio-1.0" } },
        .{ .name = "adder", .root = "plugins/adder.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-audio-1.0", "gstreamer-controller-1.0" } },
        .{ .name = "encoding", .root = "plugins/encoding.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-pbutils-1.0", "gstreamer-video-1.0" } },
        .{ .name = "subparse", .root = "plugins/subparse.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0" } },
        .{ .name = "audiomixer", .root = "plugins/audiomixer.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-audio-1.0" } },
        .{ .name = "rawparse", .root = "plugins/rawparse.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-audio-1.0", "gstreamer-video-1.0" } },
        .{ .name = "gio", .root = "plugins/gio.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gio-2.0", "gstreamer-1.0", "gstreamer-base-1.0" } },
        .{ .name = "compositor", .root = "plugins/compositor.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-video-1.0" } },
        .{ .name = "videorate", .root = "plugins/videorate.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-video-1.0" } },
        .{ .name = "tcp", .root = "plugins/tcp.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gio-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-net-1.0" } },
        .{ .name = "ogg", .root = "plugins/ogg.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-audio-1.0", "gstreamer-tag-1.0", "gstreamer-pbutils-1.0", "gstreamer-riff-1.0", "ogg" } },
        .{ .name = "opus", .root = "plugins/opus.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-audio-1.0", "gstreamer-tag-1.0", "gstreamer-pbutils-1.0", "opus" } },
        .{ .name = "app", .root = "plugins/app.zig", .system = &.{ "glib-2.0", "gobject-2.0", "gstreamer-1.0", "gstreamer-base-1.0", "gstreamer-app-1.0" } },
    };
    const plugin_step = b.step("plugins", "build the element plugins");
    for (plugins) |pl| {
        const m = gstModule(b, pl.root, target, optimize, pl.system);
        m.addOptions("build_options", plugin_opts);
        const lib = b.addLibrary(.{ .name = b.fmt("gst{s}", .{pl.name}), .linkage = .dynamic, .root_module = m, .use_llvm = true });
        const inst = b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = "plugins" } } });
        plugin_step.dependOn(&inst.step);
        b.getInstallStep().dependOn(&inst.step);
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

    for ([_][]const u8{ "audio6", "audio7", "audio8", "audio9", "audio10", "audio11", "audio12" }) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-audio-1.0", "gstreamer-app-1.0", "gstreamer-tag-1.0", "gstreamer-base-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    for ([_][]const u8{ "video1", "video2", "video3", "video4", "video5", "video6", "video7", "video8", "video9", "video10", "video11", "video12", "video13", "video14", "video15", "video16" }) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-video-1.0", "gstreamer-allocators-1.0", "gstreamer-base-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    for ([_][]const u8{"net1"}) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-net-1.0", "gstreamer-1.0", "gio-2.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
    {
        const m = b.createModule(.{ .root_source_file = b.path("tests/diff/ptphelper.zig"), .target = target, .optimize = optimize, .link_libc = true });
        const exe = b.addExecutable(.{ .name = "diff-ptphelper", .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    for ([_][]const u8{"ct1"}) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-controller-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    for ([_][]const u8{"fft1"}) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-fft-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    for ([_][]const u8{ "gl1", "gl2", "gl3" }) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-gl-1.0", "gstreamer-video-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    for ([_][]const u8{"alloc1"}) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-allocators-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    for ([_][]const u8{ "pbutils1", "pbutils2", "pbutils3", "pbutils4", "pbutils5", "pbutils6" }) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-pbutils-1.0", "gstreamer-video-1.0", "gstreamer-audio-1.0", "gstreamer-tag-1.0", "gstreamer-base-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    for ([_][]const u8{"video17"}) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-video-1.0", "gstreamer-app-1.0", "gstreamer-base-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
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
        const m = gstModule(b, "tools/pbdesc.zig", target, optimize, &.{ "gstreamer-pbutils-1.0", "gstreamer-tag-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = "pbdesc", .root_module = m, .use_llvm = true });
        b.step("pbdesc", "build the codec description table extractor").dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    {
        const m = gstModule(b, "tools/vformats.zig", target, optimize, &.{ "gstreamer-video-1.0", "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = "vformats", .root_module = m, .use_llvm = true });
        b.step("vformats", "build the video format table extractor").dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    {
        const m = gstModule(b, "tools/mkaudio.zig", target, optimize, &.{ "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const exe = b.addExecutable(.{ .name = "mkaudio", .root_module = m, .use_llvm = true });
        b.step("mkaudio", "build the audio sample generator").dependOn(&b.addInstallArtifact(exe, .{}).step);
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

    const inspect_mod = gstModule(b, "tests/diff/inspect.zig", target, optimize, &.{ "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
    inspect_mod.addImport("c", c_mod);
    for ([_][]const u8{ "core1", "core2", "base1", "base2", "base3", "base4", "base5", "base6", "vb1", "tf1", "pb1", "pb2", "pb3", "pb4", "pb5", "pb6", "pb7", "pb8", "pb9", "pb10", "pb11", "gio1", "raw1", "mix1", "sub1", "enc1", "add1", "tcp1", "vr1", "co1", "op1", "og1", "pk1" }) |name| {
        const m = gstModule(b, b.fmt("tests/diff/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-pbutils-1.0", "gstreamer-video-1.0", "gstreamer-audio-1.0", "gstreamer-controller-1.0", "gstreamer-base-1.0", "gstreamer-1.0", "gio-2.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        m.addImport("inspect", inspect_mod);
        const exe = b.addExecutable(.{ .name = b.fmt("diff-{s}", .{name}), .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    for ([_][]const u8{ "sintytest", "sintyfail", "sintycrash", "notaplugin", "sintyparse" }) |name| {
        const m = gstModule(b, b.fmt("tests/plugins/{s}.zig", .{name}), target, optimize, &.{ "gstreamer-1.0", "gobject-2.0", "glib-2.0" });
        m.addImport("c", c_mod);
        const lib = b.addLibrary(.{ .name = b.fmt("gst{s}", .{name}), .linkage = .dynamic, .root_module = m, .use_llvm = true });
        diff_step.dependOn(&b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = "testplugins" } } }).step);
    }

    {
        const m = b.createModule(.{ .root_source_file = b.path("tests/diff/web1.zig"), .target = target, .optimize = optimize, .link_libc = true });
        m.addIncludePath(b.path("tests/diff"));
        m.linkSystemLibrary("webkitgtk-6.0", .{});
        m.linkSystemLibrary("gtk4", .{});
        const exe = b.addExecutable(.{ .name = "diff-web1", .root_module = m, .use_llvm = true });
        b.step("web", "build the WebKit media test").dependOn(&b.addInstallArtifact(exe, .{}).step);
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
