const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const info = @import("info.zig");
const fields = @import("fields.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Pool = c.GstBufferPool;
const Class = c.GstBufferPoolClass;
const Buffer = c.GstBuffer;
const Structure = c.GstStructure;
const Params = c.GstBufferPoolAcquireParams;
const NONE: u64 = std.math.maxInt(u64);

const Private = extern struct {
    queue_lock: c.GMutex,
    queue_cond: c.GCond,
    queue: ?*c.GstVecDeque,
    rec_lock: c.GRecMutex,
    started: c.gboolean,
    active: c.gboolean,
    outstanding: c.gint,
    configured: c.gboolean,
    config: [*c]Structure,
    size: c.guint,
    min: c.guint,
    max: c.guint,
    cur: c.gint,
    allocator: [*c]c.GstAllocator,
    params: c.GstAllocationParams,
};

var private_offset: c.gint = 0;
var parent_class: ?*c.GObjectClass = null;
var type_once: gtype.Once = .{};
var debug_cat: [*c]c.GstDebugCategory = null;
var no_options = [_][*c]const u8{null};

fn priv(p: anytype) *Private {
    const base: [*]u8 = @ptrCast(@constCast(p));
    return @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, private_offset)))));
}

fn classOf(p: [*c]Pool) *Class {
    return gtype.classPeek(Class, p);
}

fn isPool(p: anytype) bool {
    return gtype.instanceOf(p, gst_buffer_pool_get_type());
}

fn flushing(p: [*c]Pool) bool {
    return @atomicLoad(c.gint, &p[0].flushing, .seq_cst) != 0;
}

fn lock(p: [*c]Pool) void {
    c.g_rec_mutex_lock(&priv(p).rec_lock);
}

fn unlock(p: [*c]Pool) void {
    c.g_rec_mutex_unlock(&priv(p).rec_lock);
}

pub export fn gst_buffer_pool_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(object.gst_object_get_type(), "GstBufferPool", Class, Pool, classInit, instanceInit, 0);
            private_offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &private_offset);
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.dispose = dispose;
    gc.finalize = finalize;
    const k: *Class = @ptrCast(@alignCast(klass));
    k.start = defaultStart;
    k.stop = defaultStop;
    k.set_config = defaultSetConfig;
    k.acquire_buffer = defaultAcquire;
    k.reset_buffer = defaultReset;
    k.alloc_buffer = defaultAlloc;
    k.release_buffer = defaultRelease;
    k.free_buffer = defaultFree;
    debug_cat = info._gst_debug_category_new("bufferpool", 0, "bufferpool debug");
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: [*c]Pool = @ptrCast(@alignCast(instance));
    const d = priv(p);
    p[0].priv = @ptrCast(d);
    c.g_rec_mutex_init(&d.rec_lock);
    d.queue = c.gst_vec_deque_new(16);
    c.g_mutex_init(&d.queue_lock);
    c.g_cond_init(&d.queue_cond);
    p[0].flushing = 1;
    d.config = c.gst_structure_new_static_str_empty("GstBufferPoolConfig");
    gst_buffer_pool_config_set_params(d.config, null, 0, 0, 0);
    c.gst_allocation_params_init(&d.params);
    gst_buffer_pool_config_set_allocator(d.config, null, &d.params);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const p: [*c]Pool = @ptrCast(@alignCast(o));
    _ = gst_buffer_pool_set_active(p, 0);
    const d = priv(p);
    if (d.allocator != null) {
        c.gst_object_unref(d.allocator);
        d.allocator = null;
    }
    parent_class.?.dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const d = priv(o);
    c.gst_vec_deque_free(d.queue);
    c.g_mutex_clear(&d.queue_lock);
    c.g_cond_clear(&d.queue_cond);
    c.gst_structure_free(d.config);
    c.g_rec_mutex_clear(&d.rec_lock);
    parent_class.?.finalize.?(o);
}

pub export fn gst_buffer_pool_new() [*c]Pool {
    const p = c.g_object_new(gst_buffer_pool_get_type(), @as([*c]const u8, null));
    _ = object.gst_object_ref_sink(p);
    return @ptrCast(@alignCast(p));
}

fn defaultAlloc(p: [*c]Pool, out: [*c][*c]Buffer, _: [*c]Params) callconv(.c) c.GstFlowReturn {
    const d = priv(p);
    out.* = c.gst_buffer_new_allocate(d.allocator, d.size, &d.params);
    return if (out.* == null) c.GST_FLOW_ERROR else c.GST_FLOW_OK;
}

fn markPooled(_: [*c]Buffer, meta: [*c][*c]c.GstMeta, _: c.gpointer) callconv(.c) c.gboolean {
    meta.*[0].flags |= c.GST_META_FLAG_POOLED | c.GST_META_FLAG_LOCKED;
    return 1;
}

fn allocOne(p: [*c]Pool, out: [*c][*c]Buffer, params: [*c]Params) c.GstFlowReturn {
    const d = priv(p);
    const alloc = classOf(p).alloc_buffer orelse return c.GST_FLOW_NOT_SUPPORTED;
    const cur = @atomicRmw(c.gint, &d.cur, .Add, 1, .seq_cst);
    if (d.max != 0 and cur >= d.max) {
        _ = @atomicRmw(c.gint, &d.cur, .Sub, 1, .seq_cst);
        return c.GST_FLOW_EOS;
    }
    const r = alloc(p, out, params);
    if (r != c.GST_FLOW_OK) {
        _ = @atomicRmw(c.gint, &d.cur, .Sub, 1, .seq_cst);
        return r;
    }
    _ = c.gst_buffer_foreach_meta(out.*, markPooled, p);
    out.*[0].mini_object.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_TAG_MEMORY);
    return r;
}

fn defaultStart(p: [*c]Pool) callconv(.c) c.gboolean {
    const d = priv(p);
    var i: c.guint = 0;
    while (i < d.min) : (i += 1) {
        var b: [*c]Buffer = null;
        if (allocOne(p, &b, null) != c.GST_FLOW_OK) return 0;
        if (classOf(p).release_buffer) |rel| rel(p, b);
    }
    return 1;
}

fn start(p: [*c]Pool) bool {
    const d = priv(p);
    if (d.started != 0) return true;
    if (classOf(p).start) |f| if (f(p) == 0) return false;
    d.started = 1;
    return true;
}

fn defaultFree(_: [*c]Pool, b: [*c]Buffer) callconv(.c) void {
    c.gst_mini_object_unref(@ptrCast(b));
}

fn freeOne(p: [*c]Pool, b: [*c]Buffer) void {
    const d = priv(p);
    _ = @atomicRmw(c.gint, &d.cur, .Sub, 1, .seq_cst);
    if (classOf(p).free_buffer) |f| f(p, b);
    wake(d, false);
}

fn wake(d: *Private, all: bool) void {
    c.g_mutex_lock(&d.queue_lock);
    if (all) c.g_cond_broadcast(&d.queue_cond) else c.g_cond_signal(&d.queue_cond);
    c.g_mutex_unlock(&d.queue_lock);
}

fn defaultStop(p: [*c]Pool) callconv(.c) c.gboolean {
    const d = priv(p);
    c.g_mutex_lock(&d.queue_lock);
    while (c.gst_vec_deque_pop_head(d.queue)) |b| {
        c.g_mutex_unlock(&d.queue_lock);
        freeOne(p, @ptrCast(@alignCast(b)));
        c.g_mutex_lock(&d.queue_lock);
    }
    const cleared = d.cur == 0;
    c.g_mutex_unlock(&d.queue_lock);
    return @intFromBool(cleared);
}

fn stop(p: [*c]Pool) bool {
    const d = priv(p);
    if (d.started == 0) return true;
    if (classOf(p).stop) |f| if (f(p) == 0) return false;
    d.started = 0;
    return true;
}

fn setFlushing(p: [*c]Pool, on: bool) void {
    const d = priv(p);
    if (flushing(p) == on) return;
    const k = classOf(p);
    if (on) {
        c.g_mutex_lock(&d.queue_lock);
        @atomicStore(c.gint, &p[0].flushing, 1, .seq_cst);
        c.g_cond_broadcast(&d.queue_cond);
        c.g_mutex_unlock(&d.queue_lock);
        if (k.flush_start) |f| f(p);
    } else {
        if (k.flush_stop) |f| f(p);
        @atomicStore(c.gint, &p[0].flushing, 0, .seq_cst);
    }
}

pub export fn gst_buffer_pool_set_active(p: [*c]Pool, active: c.gboolean) c.gboolean {
    if (!check.that(isPool(p), "gst_buffer_pool_set_active", "GST_IS_BUFFER_POOL (pool)")) return 0;
    const d = priv(p);
    lock(p);
    defer unlock(p);
    if ((d.active != 0) == (active != 0)) return 1;
    if (d.configured == 0) {
        info.gst_debug_log(debug_cat, c.GST_LEVEL_ERROR, "../gst/gstbufferpool.c", "gst_buffer_pool_set_active", 0, @ptrCast(p), "pool was not configured");
        return 0;
    }
    if (active != 0) {
        if (!start(p)) {
            info.gst_debug_log(debug_cat, c.GST_LEVEL_ERROR, "../gst/gstbufferpool.c", "gst_buffer_pool_set_active", 0, @ptrCast(p), "start failed");
            return 0;
        }
        d.active = 1;
        setFlushing(p, false);
    } else {
        setFlushing(p, true);
        if (@atomicLoad(c.gint, &d.outstanding, .seq_cst) == 0 and !stop(p)) return 0;
        d.active = 0;
    }
    return 1;
}

pub export fn gst_buffer_pool_is_active(p: [*c]Pool) c.gboolean {
    lock(p);
    defer unlock(p);
    return priv(p).active;
}

fn defaultSetConfig(p: [*c]Pool, config: [*c]Structure) callconv(.c) c.gboolean {
    const d = priv(p);
    var caps: [*c]c.GstCaps = null;
    var size: c.guint = 0;
    var min: c.guint = 0;
    var max: c.guint = 0;
    if (gst_buffer_pool_config_get_params(config, &caps, &size, &min, &max) == 0) return 0;
    var allocator: [*c]c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    if (gst_buffer_pool_config_get_allocator(config, &allocator, &params) == 0) return 0;
    d.size = size;
    d.min = min;
    d.max = max;
    d.cur = 0;
    if (d.allocator != null) c.gst_object_unref(d.allocator);
    d.allocator = allocator;
    if (allocator != null) _ = c.gst_object_ref(allocator);
    d.params = params;
    return 1;
}

pub export fn gst_buffer_pool_set_config(p: [*c]Pool, config: [*c]Structure) c.gboolean {
    const f = "gst_buffer_pool_set_config";
    if (!check.that(isPool(p), f, "GST_IS_BUFFER_POOL (pool)")) return 0;
    if (!check.that(config != null, f, "config != NULL")) return 0;
    const d = priv(p);
    lock(p);
    defer unlock(p);
    if (d.configured != 0 and c.gst_structure_is_equal(config, d.config) != 0) {
        c.gst_structure_free(config);
        return 1;
    }
    if (d.active != 0 or @atomicLoad(c.gint, &d.outstanding, .seq_cst) != 0) {
        c.gst_structure_free(config);
        return 0;
    }
    const ok = if (classOf(p).set_config) |set| set(p, config) else 0;
    if (d.config != null) c.gst_structure_free(d.config);
    d.config = config;
    if (ok != 0) d.configured = 1;
    return ok;
}

pub export fn gst_buffer_pool_get_config(p: [*c]Pool) [*c]Structure {
    if (!check.that(isPool(p), "gst_buffer_pool_get_config", "GST_IS_BUFFER_POOL (pool)")) return null;
    lock(p);
    defer unlock(p);
    return c.gst_structure_copy(priv(p).config);
}

pub export fn gst_buffer_pool_get_options(p: [*c]Pool) [*c][*c]const u8 {
    if (!check.that(isPool(p), "gst_buffer_pool_get_options", "GST_IS_BUFFER_POOL (pool)")) return null;
    const get = classOf(p).get_options orelse return &no_options;
    const r = get(p);
    if (r != null) return r;
    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "bufferpool subclass returned NULL options");
    return &no_options;
}

pub export fn gst_buffer_pool_has_option(p: [*c]Pool, option: [*c]const u8) c.gboolean {
    const f = "gst_buffer_pool_has_option";
    if (!check.that(isPool(p), f, "GST_IS_BUFFER_POOL (pool)")) return 0;
    if (!check.that(option != null, f, "option != NULL")) return 0;
    const opts = gst_buffer_pool_get_options(p);
    var i: usize = 0;
    while (opts[i] != null) : (i += 1) if (c.g_str_equal(opts[i], option) != 0) return 1;
    return 0;
}

pub export fn gst_buffer_pool_config_set_params(config: [*c]Structure, caps: [*c]c.GstCaps, size: c.guint, min: c.guint, max: c.guint) void {
    const f = "gst_buffer_pool_config_set_params";
    if (!check.that(config != null, f, "config != NULL")) return;
    if (!check.that(max == 0 or min <= max, f, "max_buffers == 0 || min_buffers <= max_buffers")) return;
    if (!check.that(caps == null or c.gst_caps_is_fixed(caps) != 0, f, "caps == NULL || gst_caps_is_fixed (caps)")) return;
    fields.set(config, "caps", c.gst_caps_get_type(), caps);
    fields.set(config, "size", c.G_TYPE_UINT, size);
    fields.set(config, "min-buffers", c.G_TYPE_UINT, min);
    fields.set(config, "max-buffers", c.G_TYPE_UINT, max);
}

pub export fn gst_buffer_pool_config_set_allocator(config: [*c]Structure, allocator: [*c]c.GstAllocator, params: [*c]const c.GstAllocationParams) void {
    const f = "gst_buffer_pool_config_set_allocator";
    if (!check.that(config != null, f, "config != NULL")) return;
    if (!check.that(allocator != null or params != null, f, "allocator != NULL || params != NULL")) return;
    fields.set(config, "allocator", c.gst_allocator_get_type(), allocator);
    fields.set(config, "params", c.gst_allocation_params_get_type(), params);
}

fn options(config: [*c]Structure) [*c]const c.GValue {
    return c.gst_structure_get_value(config, "options");
}

fn findOption(v: [*c]const c.GValue, option: [*c]const u8) bool {
    var i: c.guint = 0;
    const n = c.gst_value_array_get_size(v);
    while (i < n) : (i += 1) if (c.g_str_equal(option, c.g_value_get_string(c.gst_value_array_get_value(v, i))) != 0) return true;
    return false;
}

pub export fn gst_buffer_pool_config_add_option(config: [*c]Structure, option: [*c]const u8) void {
    if (!check.that(config != null, "gst_buffer_pool_config_add_option", "config != NULL")) return;
    var v = options(config);
    if (v != null) {
        if (findOption(v, option)) return;
    } else {
        var arr = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&arr, c.gst_value_array_get_type());
        c.gst_structure_take_value_static_str(config, "options", &arr);
        v = options(config);
    }
    var item = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&item, c.G_TYPE_STRING);
    c.g_value_set_string(&item, option);
    c.gst_value_array_append_and_take_value(@constCast(v), &item);
}

pub export fn gst_buffer_pool_config_n_options(config: [*c]Structure) c.guint {
    if (!check.that(config != null, "gst_buffer_pool_config_n_options", "config != NULL")) return 0;
    const v = options(config);
    return if (v != null) c.gst_value_array_get_size(v) else 0;
}

pub export fn gst_buffer_pool_config_get_option(config: [*c]Structure, idx: c.guint) [*c]const u8 {
    if (!check.that(config != null, "gst_buffer_pool_config_get_option", "config != NULL")) return null;
    const v = options(config);
    if (v == null) return null;
    const item = c.gst_value_array_get_value(v, idx);
    return if (item != null) c.g_value_get_string(item) else null;
}

pub export fn gst_buffer_pool_config_has_option(config: [*c]Structure, option: [*c]const u8) c.gboolean {
    if (!check.that(config != null, "gst_buffer_pool_config_has_option", "config != NULL")) return 0;
    const v = options(config);
    return @intFromBool(v != null and findOption(v, option));
}

pub export fn gst_buffer_pool_config_get_params(config: [*c]Structure, caps: [*c][*c]c.GstCaps, size: [*c]c.guint, min: [*c]c.guint, max: [*c]c.guint) c.gboolean {
    if (!check.that(config != null, "gst_buffer_pool_config_get_params", "config != NULL")) return 0;
    if (caps != null) caps.* = @ptrCast(@alignCast(c.g_value_get_boxed(c.gst_structure_get_value(config, "caps"))));
    return c.gst_structure_get(config, "size", c.G_TYPE_UINT, size, "min-buffers", c.G_TYPE_UINT, min, "max-buffers", c.G_TYPE_UINT, max, @as(?*anyopaque, null));
}

pub export fn gst_buffer_pool_config_get_allocator(config: [*c]Structure, allocator: [*c][*c]c.GstAllocator, params: [*c]c.GstAllocationParams) c.gboolean {
    if (!check.that(config != null, "gst_buffer_pool_config_get_allocator", "config != NULL")) return 0;
    if (allocator != null) allocator.* = @ptrCast(@alignCast(c.g_value_get_object(c.gst_structure_get_value(config, "allocator"))));
    if (params != null) {
        const p: [*c]c.GstAllocationParams = @ptrCast(@alignCast(c.g_value_get_boxed(c.gst_structure_get_value(config, "params"))));
        if (p != null) params[0] = p[0] else c.gst_allocation_params_init(params);
    }
    return 1;
}

pub export fn gst_buffer_pool_config_validate_params(config: [*c]Structure, caps: [*c]c.GstCaps, size: c.guint, min: c.guint, _: c.guint) c.gboolean {
    if (!check.that(config != null, "gst_buffer_pool_config_validate_params", "config != NULL")) return 0;
    var have: [*c]c.GstCaps = null;
    var have_size: c.guint = 0;
    var have_min: c.guint = 0;
    _ = gst_buffer_pool_config_get_params(config, &have, &have_size, &have_min, null);
    return @intFromBool(c.gst_caps_is_equal(caps, have) != 0 and have_size >= size and have_min >= min);
}

fn defaultAcquire(p: [*c]Pool, out: [*c][*c]Buffer, params: [*c]Params) callconv(.c) c.GstFlowReturn {
    const d = priv(p);
    c.g_mutex_lock(&d.queue_lock);
    while (true) {
        if (flushing(p)) {
            c.g_mutex_unlock(&d.queue_lock);
            return c.GST_FLOW_FLUSHING;
        }
        out.* = @ptrCast(@alignCast(c.gst_vec_deque_pop_head(d.queue)));
        c.g_mutex_unlock(&d.queue_lock);
        if (out.* != null) return c.GST_FLOW_OK;
        const r = allocOne(p, out, params);
        if (r != c.GST_FLOW_EOS) return r;
        if (params != null and params[0].flags & c.GST_BUFFER_POOL_ACQUIRE_FLAG_DONTWAIT != 0) return r;
        c.g_mutex_lock(&d.queue_lock);
        while (c.gst_vec_deque_get_length(d.queue) == 0 and !flushing(p) and @atomicLoad(c.gint, &d.cur, .seq_cst) >= d.max) c.g_cond_wait(&d.queue_cond, &d.queue_lock);
    }
}

fn outstandingDone(p: [*c]Pool) void {
    const d = priv(p);
    if (@atomicRmw(c.gint, &d.outstanding, .Sub, 1, .seq_cst) != 1) return;
    if (!flushing(p)) return;
    lock(p);
    defer unlock(p);
    if (d.active == 0) _ = stop(p);
}

fn dropUnpooled(b: [*c]Buffer, meta: [*c][*c]c.GstMeta, _: c.gpointer) callconv(.c) c.gboolean {
    const m = meta.*;
    if (m[0].flags & c.GST_META_FLAG_POOLED == 0) {
        m[0].flags &= ~@as(c.GstMetaFlags, c.GST_META_FLAG_LOCKED);
        meta.* = null;
    } else if (m[0].info[0].clear_func) |clear| {
        clear(b, m);
    }
    return 1;
}

fn defaultReset(p: [*c]Pool, b: [*c]Buffer) callconv(.c) void {
    b[0].mini_object.flags &= c.GST_BUFFER_FLAG_TAG_MEMORY;
    b[0].pts = NONE;
    b[0].dts = NONE;
    b[0].duration = NONE;
    b[0].offset = NONE;
    b[0].offset_end = NONE;
    if (b[0].mini_object.flags & c.GST_BUFFER_FLAG_TAG_MEMORY == 0) {
        var offset: c.gsize = 0;
        var maxsize: c.gsize = 0;
        _ = c.gst_buffer_get_sizes(b, &offset, &maxsize);
        if (maxsize >= priv(p).size) c.gst_buffer_resize(b, -@as(c.gssize, @intCast(offset)), priv(p).size);
    }
    _ = c.gst_buffer_foreach_meta(b, dropUnpooled, p);
}

pub export fn gst_buffer_pool_acquire_buffer(p: [*c]Pool, out: [*c][*c]Buffer, params: [*c]Params) c.GstFlowReturn {
    const f = "gst_buffer_pool_acquire_buffer";
    if (!check.that(isPool(p), f, "GST_IS_BUFFER_POOL (pool)")) return c.GST_FLOW_ERROR;
    if (!check.that(out != null, f, "buffer != NULL")) return c.GST_FLOW_ERROR;
    out.* = null;
    _ = @atomicRmw(c.gint, &priv(p).outstanding, .Add, 1, .seq_cst);
    const r = if (classOf(p).acquire_buffer) |acq| acq(p, out, params) else c.GST_FLOW_NOT_SUPPORTED;
    if (r == c.GST_FLOW_OK) {
        out.*[0].pool = @ptrCast(@alignCast(c.gst_object_ref(p)));
    } else {
        outstandingDone(p);
    }
    return r;
}

fn defaultRelease(p: [*c]Pool, b: [*c]Buffer) callconv(.c) void {
    const d = priv(p);
    const keep = b[0].mini_object.flags & c.GST_BUFFER_FLAG_TAG_MEMORY == 0 and c.gst_buffer_get_size(b) == d.size and c.gst_buffer_is_all_memory_writable(b) != 0;
    if (!keep) {
        freeOne(p, b);
        wake(d, false);
        return;
    }
    c.g_mutex_lock(&d.queue_lock);
    c.gst_vec_deque_push_tail(d.queue, b);
    c.g_cond_signal(&d.queue_cond);
    c.g_mutex_unlock(&d.queue_lock);
}

pub export fn gst_buffer_pool_release_buffer(p: [*c]Pool, b: [*c]Buffer) void {
    const f = "gst_buffer_pool_release_buffer";
    if (!check.that(isPool(p), f, "GST_IS_BUFFER_POOL (pool)")) return;
    if (!check.that(b != null, f, "buffer != NULL")) return;
    if (@cmpxchgStrong([*c]Pool, &b[0].pool, p, null, .seq_cst, .seq_cst) != null) return;
    const k = classOf(p);
    if (k.reset_buffer) |reset| reset(p, b);
    if (k.release_buffer) |rel| rel(p, b);
    outstandingDone(p);
    c.gst_object_unref(p);
}

pub export fn gst_buffer_pool_set_flushing(p: [*c]Pool, on: c.gboolean) void {
    if (!check.that(isPool(p), "gst_buffer_pool_set_flushing", "GST_IS_BUFFER_POOL (pool)")) return;
    lock(p);
    defer unlock(p);
    if (priv(p).active != 0) setFlushing(p, on != 0);
}
