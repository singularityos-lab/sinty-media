const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const info = @import("info.zig");
const util = @import("util.zig");
const va = @import("varargs.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Cat = info.CatPtr;
const Level = c.GstDebugLevel;
const NONE: c.GstClockTime = std.math.maxInt(u64);
const alloc = std.heap.c_allocator;

pub const Context = extern struct {
    hash_flags: c.GstLogContextHashFlags,
    flags: c.GstLogContextFlags,
    interval: c.GstClockTime,
    category: Cat,
    lock: c.GMutex,
    logged: ?*c.GHashTable,
    last_reset: c.GstClockTime,

    pub const Header = c.struct__GstLogContext;
};

pub const Builder = extern struct {
    hash_flags: c.GstLogContextHashFlags,
    flags: c.GstLogContextFlags,
    category: Cat,
    interval: c.GstClockTime,

    pub const Header = c.struct__GstLogContextBuilder;
};

var registry: ?*c.GHashTable = null;
var registry_lock = std.mem.zeroes(c.GMutex);
var once_registry: ?*c.GHashTable = null;
var once_lock = std.mem.zeroes(c.GMutex);

fn destroy(p: c.gpointer) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(p));
    c.g_mutex_lock(&ctx.lock);
    if (ctx.logged) |t| {
        c.g_hash_table_remove_all(t);
        c.g_hash_table_unref(t);
    }
    c.g_mutex_unlock(&ctx.lock);
    c.g_free(ctx);
}

fn track(ctx: *Context) void {
    c.g_mutex_lock(&registry_lock);
    defer c.g_mutex_unlock(&registry_lock);
    if (registry == null) registry = c.g_hash_table_new_full(c.g_direct_hash, c.g_direct_equal, null, destroy);
    _ = c.g_hash_table_add(registry, ctx);
}

pub export fn gst_log_context_builder_new(cat: Cat, flags: c.GstLogContextFlags) ?*Builder {
    if (!check.that(cat != null, "gst_log_context_builder_new", "category")) return null;
    const b: *Builder = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Builder))));
    b.* = .{ .hash_flags = c.GST_LOG_CONTEXT_DEFAULT, .flags = flags, .interval = 0, .category = cat };
    return b;
}

pub export fn gst_log_context_builder_set_category(b: ?*Builder, cat: Cat) ?*Builder {
    const r = b orelse {
        check.fail("gst_log_context_builder_set_category", "builder != NULL");
        return null;
    };
    r.category = cat;
    return r;
}

pub export fn gst_log_context_builder_set_hash_flags(b: ?*Builder, flags: c.GstLogContextHashFlags) ?*Builder {
    const r = b orelse {
        check.fail("gst_log_context_builder_set_hash_flags", "builder != NULL");
        return null;
    };
    r.hash_flags = flags;
    return r;
}

pub export fn gst_log_context_builder_set_interval(b: ?*Builder, interval: c.GstClockTime) ?*Builder {
    const r = b orelse {
        check.fail("gst_log_context_builder_set_interval", "builder != NULL");
        return null;
    };
    r.interval = interval;
    return r;
}

pub export fn gst_log_context_builder_build(b: ?*Builder) ?*Context {
    const r = b orelse return null;
    const ctx: *Context = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Context))));
    ctx.hash_flags = r.hash_flags;
    ctx.flags = r.flags;
    ctx.interval = r.interval;
    ctx.logged = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, null);
    ctx.last_reset = NONE;
    ctx.category = r.category;
    track(ctx);
    c.g_free(r);
    return ctx;
}

pub export fn gst_log_context_get_category(ctx: ?*Context) Cat {
    const r = ctx orelse {
        check.fail("gst_log_context_get_category", "context != NULL");
        return null;
    };
    return r.category;
}

fn resetLocked(ctx: *Context) void {
    if (ctx.logged) |t| c.g_hash_table_remove_all(t);
    ctx.last_reset = util.gst_util_get_timestamp();
}

pub export fn gst_log_context_reset(ctx: ?*Context) void {
    const r = ctx orelse return check.fail("gst_log_context_reset", "ctx != NULL");
    c.g_mutex_lock(&r.lock);
    resetLocked(r);
    c.g_mutex_unlock(&r.lock);
}

pub export fn gst_log_context_free(ctx: ?*Context) void {
    const r = ctx orelse return check.fail("gst_log_context_free", "ctx != NULL");
    c.g_mutex_lock(&registry_lock);
    defer c.g_mutex_unlock(&registry_lock);
    if (registry == null or c.g_hash_table_remove(registry, r) == 0)
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Trying to free log context %p while was not registered", r);
}

fn periodic(ctx: *Context) bool {
    c.g_mutex_lock(&ctx.lock);
    defer c.g_mutex_unlock(&ctx.lock);
    if (ctx.interval == 0) return true;
    if (ctx.last_reset == NONE) {
        ctx.last_reset = util.gst_util_get_timestamp();
        return true;
    }
    const now = util.gst_util_get_timestamp();
    const elapsed = @as(i64, @bitCast(now)) -% @as(i64, @bitCast(ctx.last_reset));
    if (elapsed >= @as(i64, @bitCast(ctx.interval))) {
        resetLocked(ctx);
        return true;
    }
    return false;
}

fn messageKey(ctx: *Context, file: [*c]const u8, line: c.gint, object: [*c]c.GObject, id: [*c]const u8, text: [*c]const u8) [*c]u8 {
    const f = ctx.hash_flags;
    return c.g_strdup_printf("%s:%d/%p/%s/%s", if (f & c.GST_LOG_CONTEXT_IGNORE_FILE != 0) @as([*c]const u8, "") else file, if (f & c.GST_LOG_CONTEXT_USE_LINE_NUMBER != 0) line else @as(c.gint, -1), if (f & c.GST_LOG_CONTEXT_IGNORE_OBJECT != 0) null else object, if (f & c.GST_LOG_CONTEXT_IGNORE_OBJECT != 0) @as([*c]const u8, "") else id, if (f & c.GST_LOG_CONTEXT_IGNORE_FORMAT != 0) @as([*c]const u8, "") else text);
}

fn seen(ctx: *Context, key: [*c]u8) bool {
    if (ctx.flags & c.GST_LOG_CONTEXT_FLAG_THROTTLE == 0) {
        c.g_free(key);
        return false;
    }
    c.g_mutex_lock(&ctx.lock);
    defer c.g_mutex_unlock(&ctx.lock);
    return c.g_hash_table_add(ctx.logged, key) == 0;
}

fn allowText(ctx: *Context, file: [*c]const u8, line: c.gint, object: [*c]c.GObject, id: [*c]const u8, text: [*c]const u8) bool {
    if (!periodic(ctx)) return false;
    return !seen(ctx, messageKey(ctx, file, line, object, id, text));
}

fn allowFormat(ctx: *Context, file: [*c]const u8, line: c.gint, object: [*c]c.GObject, id: [*c]const u8, format: [*c]const u8, ap: *va.VaList) callconv(.c) bool {
    if (!periodic(ctx)) return false;
    var full: [*c]u8 = null;
    defer c.g_free(full);
    if (ctx.hash_flags & c.GST_LOG_CONTEXT_USE_STRING_ARGS != 0) {
        var copy = @cVaCopy(ap);
        defer @cVaEnd(&copy);
        full = c.g_strdup_vprintf(format, va.toC(&copy));
    }
    return !seen(ctx, messageKey(ctx, file, line, object, id, if (full != null) full else format));
}

fn gate(ctx: *Context, level: Level) bool {
    if (level > info.gst_debug_category_get_threshold(ctx.category)) return false;
    return check.that(level < c.GST_LEVEL_MEMDUMP, "gst_debug_log_full_valist", "level < GST_LEVEL_MEMDUMP");
}

fn admit(ctx: *Context, level: Level, file: [*c]const u8, line: c.gint, object: [*c]c.GObject, id: [*c]const u8, format: [*c]const u8, ap: *va.VaList) callconv(.c) bool {
    if (!gate(ctx, level)) return false;
    return allowFormat(ctx, file, line, object, id, format, ap);
}

fn logLiteral(ctx: *Context, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, object: [*c]c.GObject, id: [*c]const u8, text: [*c]const u8) void {
    if (level > info.gst_debug_category_get_threshold(ctx.category)) return;
    if (!check.that(level < c.GST_LEVEL_MEMDUMP, "gst_debug_log_literal_full", "level < GST_LEVEL_MEMDUMP")) return;
    if (!allowText(ctx, file, line, object, id, text)) return;
    info.logText(ctx.category, level, file, func, line, object, id, text);
}

pub export fn gst_debug_log_with_context(ctx: *Context, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, object: [*c]c.GObject, format: [*c]const u8, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    if (admit(ctx, level, file, line, object, null, format, &ap)) info.logVa(ctx.category, level, file, func, line, object, null, format, &ap);
}

pub export fn gst_debug_log_with_context_valist(ctx: *Context, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, object: [*c]c.GObject, format: [*c]const u8, ap: va.CVaList) void {
    if (admit(ctx, level, file, line, object, null, format, va.fromC(ap))) info.logVa(ctx.category, level, file, func, line, object, null, format, va.fromC(ap));
}

pub export fn gst_debug_log_literal_with_context(ctx: *Context, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, object: [*c]c.GObject, text: [*c]const u8) void {
    logLiteral(ctx, level, file, func, line, object, null, text);
}

pub export fn gst_debug_log_id_with_context(ctx: *Context, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, id: [*c]const u8, format: [*c]const u8, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    if (admit(ctx, level, file, line, null, id, format, &ap)) info.logVa(ctx.category, level, file, func, line, null, id, format, &ap);
}

pub export fn gst_debug_log_id_with_context_valist(ctx: *Context, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, id: [*c]const u8, format: [*c]const u8, ap: va.CVaList) void {
    if (admit(ctx, level, file, line, null, id, format, va.fromC(ap))) info.logVa(ctx.category, level, file, func, line, null, id, format, va.fromC(ap));
}

pub export fn gst_debug_log_id_literal_with_context(ctx: *Context, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, id: [*c]const u8, text: [*c]const u8) void {
    logLiteral(ctx, level, file, func, line, null, id, text);
}

fn onceContext(cat: Cat) *Context {
    c.g_mutex_lock(&once_lock);
    defer c.g_mutex_unlock(&once_lock);
    if (once_registry == null) once_registry = c.g_hash_table_new_full(c.g_direct_hash, c.g_direct_equal, null, null);
    if (c.g_hash_table_lookup(once_registry, cat)) |found| return @ptrCast(@alignCast(found));
    const b = gst_log_context_builder_new(cat, c.GST_LOG_CONTEXT_FLAG_THROTTLE);
    _ = gst_log_context_builder_set_hash_flags(b, c.GST_LOG_CONTEXT_USE_LINE_NUMBER);
    const ctx = gst_log_context_builder_build(b).?;
    _ = c.g_hash_table_insert(once_registry, ctx.category, ctx);
    return ctx;
}

pub export fn _gst_debug_log_once(cat: Cat, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, object: [*c]c.GObject, format: [*c]const u8, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    const ctx = onceContext(cat);
    if (admit(ctx, level, file, line, object, null, format, &ap)) info.logVa(ctx.category, level, file, func, line, object, null, format, &ap);
}

pub export fn _gst_debug_log_once_id(cat: Cat, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, id: [*c]const u8, format: [*c]const u8, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    const ctx = onceContext(cat);
    if (admit(ctx, level, file, line, null, id, format, &ap)) info.logVa(ctx.category, level, file, func, line, null, id, format, &ap);
}

const ThreadLog = struct {
    lines: std.ArrayListUnmanaged([*c]u8) = .empty,
    first: usize = 0,
    size: usize = 0,
    last_use: i64 = 0,
    thread: c_int,

    fn drop(t: *ThreadLog) void {
        for (t.lines.items[t.first..]) |l| c.g_free(l);
        t.lines.deinit(alloc);
    }

    fn popFront(t: *ThreadLog) void {
        const l = t.lines.items[t.first];
        t.size -= c.strlen(l);
        c.g_free(l);
        t.first += 1;
        if (t.first > 256 and t.first * 2 > t.lines.items.len) {
            std.mem.copyForwards([*c]u8, t.lines.items[0 .. t.lines.items.len - t.first], t.lines.items[t.first..]);
            t.lines.shrinkRetainingCapacity(t.lines.items.len - t.first);
            t.first = 0;
        }
    }
};

const Ring = struct {
    max_size: c.guint,
    timeout: c.guint,
    threads: std.ArrayListUnmanaged(*ThreadLog) = .empty,
};

var ring: ?*Ring = null;
var ring_lock = std.mem.zeroes(c.GMutex);

fn ringLog(cat: Cat, level: Level, file: [*c]const u8, func: [*c]const u8, line: c.gint, object: [*c]c.GObject, m: ?*c.GstDebugMessage, data: c.gpointer) callconv(.c) void {
    const r: *Ring = @ptrCast(@alignCast(data));
    const now = c.g_get_monotonic_time();
    const text = info.gst_debug_log_get_line(cat, level, file, func, line, object, m);
    const len = c.strlen(text);
    const tid: c_int = @intCast(std.os.linux.gettid());
    c.g_mutex_lock(&ring_lock);
    defer c.g_mutex_unlock(&ring_lock);
    if (r.timeout > 0) {
        while (r.threads.items.len > 0) {
            const oldest = r.threads.items[r.threads.items.len - 1];
            if (oldest.last_use + @as(i64, r.timeout) * 1000000 >= now) break;
            oldest.drop();
            alloc.destroy(oldest);
            _ = r.threads.pop();
        }
    }
    var log: *ThreadLog = undefined;
    var found: ?usize = null;
    for (r.threads.items, 0..) |t, i| if (t.thread == tid) {
        found = i;
        break;
    };
    if (found) |i| {
        log = r.threads.orderedRemove(i);
    } else {
        log = alloc.create(ThreadLog) catch {
            c.g_free(text);
            return;
        };
        log.* = .{ .thread = tid };
    }
    r.threads.insert(alloc, 0, log) catch {};
    log.last_use = now;
    if (len < r.max_size) {
        while (log.size + len > r.max_size) log.popFront();
        log.lines.append(alloc, text) catch {};
        log.size += len;
    } else {
        while (log.first < log.lines.items.len) log.popFront();
        c.g_free(text);
        log.size = 0;
    }
}

fn ringFree(data: c.gpointer) callconv(.c) void {
    const r: *Ring = @ptrCast(@alignCast(data));
    c.g_mutex_lock(&ring_lock);
    defer c.g_mutex_unlock(&ring_lock);
    if (ring != r) return;
    for (r.threads.items) |t| {
        t.drop();
        alloc.destroy(t);
    }
    r.threads.deinit(alloc);
    alloc.destroy(r);
    ring = null;
}

pub export fn gst_debug_ring_buffer_logger_get_logs() [*c][*c]u8 {
    const r = ring orelse {
        check.fail("gst_debug_ring_buffer_logger_get_logs", "ring_buffer_logger != NULL");
        return null;
    };
    c.g_mutex_lock(&ring_lock);
    defer c.g_mutex_unlock(&ring_lock);
    const logs: [*c][*c]u8 = @ptrCast(@alignCast(c.g_malloc0((r.threads.items.len + 1) * @sizeOf([*c]u8))));
    for (r.threads.items, 0..) |t, i| {
        const buf: [*c]u8 = @ptrCast(c.g_malloc(t.size + 1));
        var p: usize = 0;
        for (t.lines.items[t.first..]) |l| {
            const n = c.strlen(l);
            @memcpy(buf[p .. p + n], l[0..n]);
            p += n;
        }
        buf[p] = 0;
        logs[i] = buf;
    }
    return logs;
}

pub export fn gst_debug_add_ring_buffer_logger(max_size: c.guint, timeout: c.guint) void {
    c.g_mutex_lock(&ring_lock);
    if (ring != null) {
        c.g_mutex_unlock(&ring_lock);
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "(%s:%d):%s: code should not be reached", "../gst/gstinfo.c", @as(c_int, 4538), "gst_debug_add_ring_buffer_logger");
        return;
    }
    const r = alloc.create(Ring) catch {
        c.g_mutex_unlock(&ring_lock);
        return;
    };
    r.* = .{ .max_size = max_size, .timeout = timeout };
    ring = r;
    c.g_mutex_unlock(&ring_lock);
    info.gst_debug_add_log_function(ringLog, r, ringFree);
}

pub export fn gst_debug_remove_ring_buffer_logger() void {
    _ = info.gst_debug_remove_log_function(ringLog);
}

pub export fn gst_debug_get_stack_trace(_: c.GstStackTraceFlags) [*c]u8 {
    var frames: [128]?*anyopaque = undefined;
    const n = c.backtrace(@ptrCast(&frames), frames.len);
    const names = c.backtrace_symbols(@ptrCast(&frames), n);
    if (names == null) return null;
    defer c.free(@ptrCast(names));
    const s = c.g_string_new(null);
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) c.g_string_append_printf(s, "%s\n", names[i]);
    return c.g_string_free(s, 0);
}

pub export fn gst_debug_print_stack_trace() void {
    const t = gst_debug_get_stack_trace(c.GST_STACK_TRACE_SHOW_FULL);
    if (t != null) c.g_print("%s\n", t);
    c.g_free(t);
}
