const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const context = @import("context.zig");
const debug = @import("debug.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Q = c.GstGLQuery;
const TIME_ELAPSED = 0x88BF;
const TIMESTAMP = 0x8E28;
const RESULT = 0x8866;

var done: usize = 0;

fn initDebug() void {
    if (c.g_once_init_enter(&done) != 0) {
        _ = c._gst_debug_category_new("glquery", 0, "glquery element");
        c.g_once_init_leave(&done, 1);
    }
}

fn toGl(t: c.GstGLQueryType) c.guint {
    return switch (t) {
        c.GST_GL_QUERY_TIME_ELAPSED => TIME_ELAPSED,
        c.GST_GL_QUERY_TIMESTAMP => TIMESTAMP,
        else => 0,
    };
}

fn logTime(data: c.gpointer) callconv(.c) [*c]u8 {
    const r = gst_gl_query_result(@ptrCast(@alignCast(data)));
    if (r == c.GST_CLOCK_TIME_NONE) return c.g_strdup("99:99:99.999999999");
    const s: u64 = c.GST_SECOND;
    return c.g_strdup_printf("%u:%02u:%02u.%09u", @as(c_uint, @intCast(r / (s * 3600))), @as(c_uint, @intCast((r / (s * 60)) % 60)), @as(c_uint, @intCast((r / s) % 60)), @as(c_uint, @intCast(r % s)));
}

pub export fn gst_gl_query_init(q: [*c]Q, ctx: [*c]c.GstGLContext, t: c.GstGLQueryType) void {
    const fname = "gst_gl_query_init";
    if (!check.that(q != null, fname, "query != NULL")) return;
    if (!check.that(context.isContext(ctx), fname, "GST_IS_GL_CONTEXT (context)")) return;
    const gl_type = toGl(t);
    if (!check.that(gl_type != c.GL_NONE, fname, "gl_query_type != GL_NONE")) return;
    q[0] = std.mem.zeroes(Q);
    initDebug();
    const gl = &ctx[0].gl_vtable[0];
    q[0].query_type = gl_type;
    q[0].context = @ptrCast(@alignCast(c.gst_object_ref(ctx)));
    q[0].supported = @intFromBool(gl.GenQueries != null);
    if (q[0].supported != 0) gl.GenQueries.?(1, &q[0].query_id);
    debug.gst_gl_async_debug_init(&q[0].debug);
    q[0].debug.callback = logTime;
    q[0].debug.user_data = q;
}

pub export fn gst_gl_query_unset(q: [*c]Q) void {
    if (!check.that(q != null, "gst_gl_query_unset", "query != NULL")) return;
    if (q[0].start_called != 0) c.g_log(null, c.G_LOG_LEVEL_CRITICAL, "Unsetting a running query. This may not be what you wanted.Be sure to pair calls to gst_gl_query_start() and gst_gl_query_end()");
    const gl = &q[0].context[0].gl_vtable[0];
    debug.gst_gl_async_debug_unset(&q[0].debug);
    if (q[0].query_id != 0) gl.DeleteQueries.?(1, &q[0].query_id);
    c.gst_object_unref(q[0].context);
}

pub export fn gst_gl_query_new(ctx: [*c]c.GstGLContext, t: c.GstGLQueryType) [*c]Q {
    const q: [*c]Q = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Q))));
    gst_gl_query_init(q, ctx, t);
    return q;
}

pub export fn gst_gl_query_free(q: [*c]Q) void {
    if (!check.that(q != null, "gst_gl_query_free", "query != NULL")) return;
    gst_gl_query_unset(q);
    c.g_free(q);
}

pub export fn gst_gl_query_start(q: [*c]Q) void {
    const fname = "gst_gl_query_start";
    if (!check.that(q != null, fname, "query != NULL")) return;
    if (!check.that(q[0].query_type == TIME_ELAPSED, fname, "_query_type_supports_begin_end (query->query_type)")) return;
    if (!check.that(q[0].start_called == 0, fname, "query->start_called == FALSE")) return;
    q[0].start_called = 1;
    if (q[0].supported == 0) return;
    debug.gst_gl_async_debug_output_log_msg(&q[0].debug);
    q[0].context[0].gl_vtable[0].BeginQuery.?(q[0].query_type, q[0].query_id);
}

pub export fn gst_gl_query_end(q: [*c]Q) void {
    const fname = "gst_gl_query_end";
    if (!check.that(q != null, fname, "query != NULL")) return;
    if (!check.that(q[0].query_type == TIME_ELAPSED, fname, "_query_type_supports_begin_end (query->query_type)")) return;
    if (!check.that(q[0].start_called != 0, fname, "query->start_called")) return;
    q[0].start_called = 0;
    if (q[0].supported == 0) return;
    q[0].context[0].gl_vtable[0].EndQuery.?(q[0].query_type);
}

pub export fn gst_gl_query_counter(q: [*c]Q) void {
    const fname = "gst_gl_query_counter";
    if (!check.that(q != null, fname, "query != NULL")) return;
    if (!check.that(q[0].query_type == TIMESTAMP, fname, "_query_type_supports_counter (query->query_type)")) return;
    if (q[0].supported == 0) return;
    debug.gst_gl_async_debug_output_log_msg(&q[0].debug);
    q[0].context[0].gl_vtable[0].QueryCounter.?(q[0].query_id, q[0].query_type);
}

pub export fn gst_gl_query_result(q: [*c]Q) c.guint64 {
    const fname = "gst_gl_query_result";
    if (!check.that(q != null, fname, "query != NULL")) return 0;
    if (!check.that(q[0].start_called == 0, fname, "!query->start_called")) return 0;
    if (q[0].supported == 0) return 0;
    const gl = &q[0].context[0].gl_vtable[0];
    if (gl.GetQueryObjectui64v) |f| {
        var v: c.GLuint64 = 0;
        f(q[0].query_id, RESULT, &v);
        return v;
    }
    var v: c.GLuint = 0;
    gl.GetQueryObjectuiv.?(q[0].query_id, RESULT, &v);
    return v;
}

pub fn startLog(q: [*c]Q, cat: ?*c.GstDebugCategory, comptime file: []const u8, comptime func: [*:0]const u8, line: c.gint, what: [*:0]const u8) void {
    debug.gst_gl_async_debug_store_log_msg(&q[0].debug, cat, c.GST_LEVEL_LOG, "../gst-libs/gst/gl/" ++ file ++ "\x00", func, line, null, "%s took", what);
    debug.gst_gl_async_debug_freeze(&q[0].debug);
    gst_gl_query_start(q);
    debug.gst_gl_async_debug_thaw(&q[0].debug);
}
