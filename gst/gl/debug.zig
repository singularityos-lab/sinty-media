const std = @import("std");
const c = @import("../c.zig").c;
const va = @import("../varargs.zig");
const context = @import("context.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const FILLED = 1 << 0;
const FROZEN = 1 << 1;

const AD = c.GstGLAsyncDebug;

var done: usize = 0;
var perf_cat: ?*c.GstDebugCategory = null;
var default_cat: ?*c.GstDebugCategory = null;
var marker_cat: ?*c.GstDebugCategory = null;

fn initDebug() void {
    if (c.g_once_init_enter(&done) != 0) {
        perf_cat = c._gst_debug_get_category("GST_PERFORMANCE");
        default_cat = c._gst_debug_get_category("default");
        marker_cat = c._gst_debug_category_new("gldebugmarker", 0, "OpenGL Markers");
        c.g_once_init_leave(&done, 1);
    }
}

fn clear(ad: [*c]AD) void {
    if (ad[0].debug_msg != null) {
        c.g_free(ad[0].debug_msg);
        ad[0].debug_msg = null;
        if (ad[0].object != null) c.g_object_unref(ad[0].object);
        ad[0].object = null;
        ad[0].state_flags &= ~@as(c.guint, FILLED);
    }
}

pub export fn gst_gl_async_debug_init(ad: [*c]AD) void {
    initDebug();
    ad[0] = std.mem.zeroes(AD);
}

pub export fn gst_gl_async_debug_unset(ad: [*c]AD) void {
    gst_gl_async_debug_output_log_msg(ad);
    clear(ad);
    if (ad[0].notify) |n| n(ad[0].user_data);
}

pub export fn gst_gl_async_debug_new() [*c]AD {
    return @ptrCast(@alignCast(c.g_malloc0(@sizeOf(AD))));
}

pub export fn gst_gl_async_debug_free(ad: [*c]AD) void {
    gst_gl_async_debug_unset(ad);
    c.g_free(ad);
}

pub export fn gst_gl_async_debug_freeze(ad: [*c]AD) void {
    ad[0].state_flags |= FROZEN;
}

pub export fn gst_gl_async_debug_thaw(ad: [*c]AD) void {
    ad[0].state_flags &= ~@as(c.guint, FROZEN);
}

fn severity(v: c.GLenum) [*c]const u8 {
    return switch (v) {
        0x9146 => "high",
        0x9147 => "medium",
        0x9148 => "low",
        0x826B => "notification",
        else => "invalid",
    };
}

fn source(v: c.GLenum) [*c]const u8 {
    return switch (v) {
        0x8246 => "API",
        0x8247 => "winsys",
        0x8248 => "shader compiler",
        0x8249 => "third party",
        0x824A => "application",
        0x824B => "other",
        else => "invalid",
    };
}

fn kind(v: c.GLenum) [*c]const u8 {
    return switch (v) {
        0x824C => "error",
        0x824D => "deprecated",
        0x824E => "undefined",
        0x824F => "portability",
        0x8250 => "performance",
        0x8268 => "debug marker",
        0x8251 => "other",
        else => "invalid",
    };
}

fn callback(src: c.GLenum, typ: c.GLenum, id: c.GLuint, sev: c.GLenum, _: c.GLsizei, msg: [*c]const c.GLchar, data: ?*const anyopaque) callconv(.c) void {
    initDebug();
    const obj: [*c]c.GObject = @ptrCast(@alignCast(@constCast(data)));
    const level: c.GstDebugLevel, const dc = switch (typ) {
        0x824C, 0x824E => .{ c.GST_LEVEL_ERROR, context.gldebug_cat },
        0x824D, 0x824F => .{ c.GST_LEVEL_FIXME, context.gldebug_cat },
        0x8250 => .{ c.GST_LEVEL_DEBUG, perf_cat },
        else => .{ c.GST_LEVEL_DEBUG, context.gldebug_cat },
    };
    if (level > c._gst_debug_min) return;
    c.gst_debug_log(dc, level, "../gst-libs/gst/gl/gstgldebug.c", "_gst_gl_debug_callback", 237, obj, "%s: GL %s from %s id:%u, %s", severity(sev), kind(typ), source(src), id, msg);
}

pub fn enable(ctx: *c.GstGLContext) void {
    const gl = &ctx.gl_vtable[0];
    initDebug();
    const cb = gl.DebugMessageCallback orelse return;
    if (!context.debugEnabled()) return;
    const level = c.gst_debug_category_get_threshold(context.gldebug_cat);
    cb(callback, ctx);
    if (level >= c.GST_LEVEL_DEBUG) {
        gl.DebugMessageControl.?(c.GL_DONT_CARE, c.GL_DONT_CARE, c.GL_DONT_CARE, 0, null, c.GL_TRUE);
        return;
    }
    var types: [8]c.GLenum = undefined;
    var n: usize = 0;
    if (level >= c.GST_LEVEL_FIXME) {
        types[n] = 0x824D;
        types[n + 1] = 0x824F;
        n += 2;
    }
    if (level >= c.GST_LEVEL_ERROR) {
        types[n] = 0x824C;
        types[n + 1] = 0x824E;
        n += 2;
    }
    for (types[0..n]) |t| gl.DebugMessageControl.?(c.GL_DONT_CARE, t, c.GL_DONT_CARE, 0, null, c.GL_TRUE);
}

pub export fn gst_gl_insert_debug_marker(ctx: [*c]c.GstGLContext, format: [*c]const u8, ...) callconv(.c) void {
    const gl = &ctx[0].gl_vtable[0];
    initDebug();
    if (c.gst_debug_category_get_threshold(marker_cat) < c.GST_LEVEL_FIXME) return;
    var ap = @cVaStart();
    var s: [*c]u8 = null;
    const len = c.gst_info_vasprintf(&s, format, va.toC(&ap));
    @cVaEnd(&ap);
    if (len < 0 or s == null) return;
    if (gl.DebugMessageInsert) |f| {
        f(0x8249, 0x8268, 0, 0x9148, len, s);
    } else if (gl.InsertEventMarker) |f| {
        f(len, s);
    } else if (gl.StringMarker) |f| {
        f(len, s);
    }
    c.g_free(s);
}

pub export fn gst_gl_async_debug_store_log_msg_valist(ad: [*c]AD, dc: ?*c.GstDebugCategory, level: c.GstDebugLevel, file: [*c]const u8, function: [*c]const u8, line: c.gint, object: [*c]c.GObject, format: [*c]const u8, ap: va.CVaList) void {
    gst_gl_async_debug_output_log_msg(ad);
    clear(ad);
    if (level <= c.GST_LEVEL_MAX and level <= c._gst_debug_min) {
        ad[0].cat = dc orelse default_cat;
        ad[0].level = level;
        ad[0].file = file;
        ad[0].function = function;
        ad[0].line = line;
        ad[0].object = if (object != null) @ptrCast(@alignCast(c.g_object_ref(object))) else null;
        ad[0].debug_msg = c.gst_info_strdup_vprintf(format, ap);
        ad[0].state_flags |= FILLED;
    }
}

pub export fn gst_gl_async_debug_output_log_msg(ad: [*c]AD) void {
    if (ad[0].state_flags & FILLED != 0 and ad[0].state_flags & FROZEN == 0) {
        var msg: [*c]u8 = null;
        if (ad[0].callback) |f| msg = f(ad[0].user_data);
        const dm: [*c]const u8 = if (ad[0].debug_msg != null) ad[0].debug_msg else "(NULL)";
        const m: [*c]const u8 = if (msg != null) msg else "";
        c.gst_debug_log(ad[0].cat, ad[0].level, ad[0].file, ad[0].function, ad[0].line, ad[0].object, "%s %s", dm, m);
        c.g_free(msg);
        clear(ad);
    }
}

pub export fn gst_gl_async_debug_store_log_msg(ad: [*c]AD, dc: ?*c.GstDebugCategory, level: c.GstDebugLevel, file: [*c]const u8, function: [*c]const u8, line: c.gint, object: [*c]c.GObject, format: [*c]const u8, ...) callconv(.c) void {
    if (level <= c.GST_LEVEL_MAX and level <= c._gst_debug_min) {
        var ap = @cVaStart();
        defer @cVaEnd(&ap);
        gst_gl_async_debug_store_log_msg_valist(ad, dc, level, file, function, line, object, format, va.toC(&ap));
    }
}
