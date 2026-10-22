const std = @import("std");
const c = @import("../c.zig").c;
const features = @import("features.zig");

comptime {
    @import("../abi.zig").check(@This());
}

pub export fn gst_gl_check_extension(name: [*c]const u8, ext: [*c]const u8) c.gboolean {
    if (name == null or ext == null) return 0;
    const want = std.mem.span(name);
    var it = std.mem.splitScalar(u8, std.mem.span(ext), ' ');
    while (it.next()) |e| {
        if (std.mem.eql(u8, e, want)) return 1;
    }
    return 0;
}

fn findSuffix(g: features.Group, prefix: [*c]const u8, exts: [*c]const u8) ?[]const u8 {
    var ns = std.mem.splitScalar(u8, g.ns[0 .. g.ns.len - 1], 0);
    while (ns.next()) |space| {
        if (space.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, space, ':');
        const head = if (colon) |i| space[0..i] else space;
        const suffix = if (colon) |i| space[i + 1 ..] else space;
        var en = std.mem.splitScalar(u8, g.ext[0 .. g.ext.len - 1], 0);
        while (en.next()) |e| {
            if (e.len == 0) break;
            var buf: [256]u8 = undefined;
            const full = std.fmt.bufPrintZ(&buf, "{s}_{s}_{s}", .{ std.mem.span(prefix), head, e }) catch continue;
            if (gst_gl_check_extension(full.ptr, exts) != 0) return suffix;
        }
    }
    return null;
}

fn slot(vt: *c.GstGLFuncs, comptime name: []const u8) *?*anyopaque {
    return @ptrCast(@alignCast(&@field(vt, name)));
}

fn proc(ctx: [*c]c.GstGLContext, name: []const u8, suffix: []const u8) ?*anyopaque {
    var buf: [256]u8 = undefined;
    const full = std.fmt.bufPrintZ(&buf, "gl{s}{s}", .{ name, suffix }) catch return null;
    return c.gst_gl_context_get_proc_address(ctx, full.ptr);
}

fn checkGroup(ctx: [*c]c.GstGLContext, comptime g: features.Group, prefix: [*c]const u8, exts: [*c]const u8) bool {
    const vt: *c.GstGLFuncs = @ptrCast(@alignCast(ctx[0].gl_vtable));
    const api = c.gst_gl_context_get_gl_api(ctx);
    var ver: [2]u8 = .{ 0, 0 };
    if (api & (c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3) != 0) {
        ver = g.gl;
    } else if (api & (c.GST_GL_API_GLES1 | c.GST_GL_API_GLES2) != 0) {
        ver = g.gles;
    }
    var core = c.gst_gl_context_check_gl_version(ctx, g.api, ver[0], ver[1]) != 0;
    var suffix: []const u8 = "";
    if (!core) suffix = findSuffix(g, prefix, exts) orelse return fail(vt, g);
    inline for (g.funcs) |f| {
        var p = proc(ctx, f, suffix);
        if (p == null and core) {
            suffix = findSuffix(g, prefix, exts) orelse return fail(vt, g);
            core = false;
            p = proc(ctx, f, suffix);
        }
        if (p == null) return fail(vt, g);
        slot(vt, f).* = p;
    }
    return true;
}

fn fail(vt: *c.GstGLFuncs, comptime g: features.Group) bool {
    inline for (g.funcs) |f| slot(vt, f).* = null;
    return false;
}

pub fn checkAll(ctx: [*c]c.GstGLContext, exts: [*c]const u8) void {
    inline for (features.groups) |g| _ = checkGroup(ctx, g, "GL", exts);
}

pub fn checkCore(ctx: [*c]c.GstGLContext) bool {
    return checkGroup(ctx, features.groups[0], "GL", "");
}
