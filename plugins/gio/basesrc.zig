const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const gio = @import("element.zig");

const FILE = "../gst/gio/gstgiobasesrc.c";

pub const Self = extern struct {
    parent: c.GstBaseSrc,
    cancel: ?*c.GCancellable,
    position: c.guint64,
    stream: ?*c.GInputStream,
    cache: [*c]c.GstBuffer,
};

pub const Class = extern struct {
    parent: c.GstBaseSrcClass,
    get_stream: ?*const fn (*Self) callconv(.c) ?*c.GInputStream,
    close_on_stop: c.gboolean,
    wait_for_data: ?*const fn (*Self) callconv(.c) c.gboolean,
    waited_for_data: ?*const fn (*Self) callconv(.c) void,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var parent: ?*c.GstBaseSrcClass = null;

pub fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn klass(s: *Self) *Class {
    return @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(s)).g_class));
}

fn isInput(p: anytype) bool {
    return cm.isA(p, c.g_input_stream_get_type());
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.cancel) |x| c.g_object_unref(x);
    s.cancel = null;
    if (s.stream) |x| c.g_object_unref(x);
    s.stream = null;
    if (s.cache != null) c.gst_buffer_unref(s.cache);
    s.cache = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn start(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(b);
    s.position = 0;
    s.stream = klass(s).get_stream.?(s);
    if (!isInput(s.stream)) {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ, null, c.g_strdup("No input stream provided by subclass"), FILE, "gst_gio_base_src_start", 122);
        return 0;
    } else if (c.g_input_stream_is_closed(s.stream) != 0) {
        cm.elementError(s, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_FAILED, null, c.g_strdup("Input stream is already closed"), FILE, "gst_gio_base_src_start", 126);
        return 0;
    }
    if (cm.isA(s.stream, c.g_seekable_get_type())) s.position = @bitCast(c.g_seekable_tell(@ptrCast(s.stream)));
    return 1;
}

fn stop(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(b);
    if (klass(s).close_on_stop != 0 and isInput(s.stream)) {
        var err: [*c]c.GError = null;
        const ok = c.g_input_stream_close(s.stream, s.cancel, &err) != 0;
        if (!ok and !gio.gioError(s, "g_input_stream_close", &err, null)) {
            cm.elementWarning(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_CLOSE, null, c.g_strdup_printf("g_input_stream_close failed: %s", err.*.message), FILE, "gst_gio_base_src_stop", 155);
            c.g_clear_error(&err);
        } else if (!ok) {
            cm.elementWarning(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_CLOSE, null, c.g_strdup("g_input_stream_close failed"), FILE, "gst_gio_base_src_stop", 159);
        }
    }
    c.g_object_unref(@ptrCast(s.stream));
    s.stream = null;
    return 1;
}

fn getSize(b: [*c]c.GstBaseSrc, size: [*c]c.guint64) callconv(.c) c.gboolean {
    const s = me(b);
    if (cm.isA(s.stream, c.g_file_input_stream_get_type())) {
        var err: [*c]c.GError = null;
        const info = c.g_file_input_stream_query_info(@ptrCast(s.stream), c.G_FILE_ATTRIBUTE_STANDARD_SIZE, s.cancel, &err);
        if (info != null) {
            size[0] = @bitCast(c.g_file_info_get_size(info));
            c.g_object_unref(info);
            return 1;
        }
        if (!gio.gioError(s, "g_file_input_stream_query_info", &err, null)) c.g_clear_error(&err);
    }
    if (gio.isSeekable(s.stream)) {
        const sk: ?*c.GSeekable = @ptrCast(s.stream);
        var err: [*c]c.GError = null;
        const old = c.g_seekable_tell(sk);
        if (c.g_seekable_seek(sk, 0, c.G_SEEK_END, s.cancel, &err) == 0) {
            if (!gio.gioError(s, "g_seekable_seek", &err, null)) c.g_clear_error(&err);
            return 0;
        }
        const n = c.g_seekable_tell(sk);
        if (c.g_seekable_seek(sk, old, c.G_SEEK_SET, s.cancel, &err) == 0) {
            if (!gio.gioError(s, "g_seekable_seek", &err, null)) c.g_clear_error(&err);
            return 0;
        }
        if (n >= 0) {
            size[0] = @bitCast(n);
            return 1;
        }
    }
    return 0;
}

fn isSeekable(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return @intFromBool(gio.isSeekable(me(b).stream));
}

fn unlock(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    c.g_cancellable_cancel(me(b).cancel);
    return 1;
}

fn unlockStop(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(b);
    c.g_object_unref(s.cancel);
    s.cancel = c.g_cancellable_new();
    return 1;
}

fn create(b: [*c]c.GstBaseSrc, offset: c.guint64, size: c.guint, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(b);
    if (!cm.that(isInput(s.stream), "gst_gio_base_src_create", "G_IS_INPUT_STREAM (src->stream)")) return c.GST_FLOW_ERROR;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    var result: [*c]c.GstBuffer = null;
    if (s.cache != null and offset >= cm.buf(s.cache).offset and offset + size <= cm.buf(s.cache).offset_end) {
        result = c.gst_buffer_copy_region(s.cache, c.GST_BUFFER_COPY_ALL, offset - cm.buf(s.cache).offset, size);
        cm.buf(result).offset = offset;
        cm.buf(result).offset_end = offset + size;
    } else {
        const cachesize: c.guint = @max(4096, size);
        const k = klass(s);
        const fresh = c.gst_buffer_new();
        var read: i64 = 0;
        if (s.cache != null and offset >= cm.buf(s.cache).offset and offset <= cm.buf(s.cache).offset_end) {
            read = @intCast(cm.buf(s.cache).offset_end - offset);
            _ = c.gst_buffer_copy_into(fresh, s.cache, c.GST_BUFFER_COPY_MEMORY, offset - cm.buf(s.cache).offset, @intCast(read));
        }
        if (s.cache != null) c.gst_buffer_unref(s.cache);
        s.cache = fresh;
        const from = offset + @as(u64, @intCast(read));
        if (from != s.position) {
            if (!gio.isSeekable(s.stream)) return c.GST_FLOW_NOT_SUPPORTED;
            ret = gio.seek(s, s.stream, from, s.cancel);
            if (ret != c.GST_FLOW_OK) return ret;
            s.position = from;
        }
        const mem = c.gst_allocator_alloc(null, cachesize, null);
        if (mem == null) return c.GST_FLOW_ERROR;
        var map: c.GstMapInfo = undefined;
        _ = c.gst_memory_map(mem, &map, c.GST_MAP_WRITE);
        var got: usize = 0;
        var err: [*c]c.GError = null;
        var waited = false;
        while (@as(i64, size) - read > 0) {
            const res = c.g_input_stream_read(s.stream, map.data + got, cachesize - got, s.cancel, &err);
            if (res < 0) break;
            read += res;
            got += @intCast(res);
            s.position += @intCast(res);
            if (res != 0) continue;
            if (k.wait_for_data == null or k.wait_for_data.?(s) == 0) break;
            waited = true;
        }
        if (err != null) c.g_clear_error(&err);
        if (waited) if (k.waited_for_data) |f| f(s);
        c.gst_memory_unmap(mem, &map);
        c.gst_buffer_append_memory(s.cache, mem);
        const eos = read == 0;
        if (!eos) {
            const n: u64 = @min(size, @as(u64, @intCast(read)));
            cm.buf(s.cache).offset = offset;
            cm.buf(s.cache).offset_end = offset + @as(u64, @intCast(read));
            result = c.gst_buffer_copy_region(s.cache, c.GST_BUFFER_COPY_ALL, 0, n);
            cm.buf(result).offset = offset;
            cm.buf(result).offset_end = offset + n;
        } else {
            c.gst_buffer_unref(s.cache);
            s.cache = null;
            result = null;
            ret = c.GST_FLOW_EOS;
        }
    }
    out[0] = result;
    return ret;
}

fn query(b: [*c]c.GstBaseSrc, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    var ret = false;
    if (cm.queryType(q) == c.GST_QUERY_URI and cm.isA(b, c.gst_uri_handler_get_type())) {
        const uri = c.gst_uri_handler_get_uri(@ptrCast(b));
        c.gst_query_set_uri(q, uri);
        c.g_free(uri);
        ret = true;
    }
    if (!ret) return parent.?.query.?(b, q);
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("gio_base_src", 0, "GIO base source");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    c.gst_element_class_add_static_pad_template(@ptrCast(@alignCast(k)), &src_t);
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.start = start;
    bc.stop = stop;
    bc.get_size = getSize;
    bc.is_seekable = isSeekable;
    bc.unlock = unlock;
    bc.unlock_stop = unlockStop;
    bc.create = create;
    bc.query = query;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    me(inst).cancel = c.g_cancellable_new();
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = c.g_type_register_static_simple(c.gst_base_src_get_type(), c.g_intern_static_string("GstGioBaseSrc"), @sizeOf(Class), classInit, @sizeOf(Self), init, 0);
            c.gst_type_mark_as_plugin_api(t, 0);
            return t;
        }
    }.f);
}

pub fn unlockParent(b: [*c]c.GstBaseSrc) c.gboolean {
    return unlock(b);
}

pub fn queryParent(b: [*c]c.GstBaseSrc, q: [*c]c.GstQuery) c.gboolean {
    return query(b, q);
}
