const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const gio = @import("element.zig");

const FILE = "../gst/gio/gstgiobasesink.c";
const PROP_CLOSE_ON_STOP = 1;

pub const Self = extern struct {
    parent: c.GstBaseSink,
    cancel: ?*c.GCancellable,
    position: c.guint64,
    stream: ?*c.GOutputStream,
    close_on_stop: c.gboolean,
};

pub const Class = extern struct {
    parent: c.GstBaseSinkClass,
    get_stream: ?*const fn (*Self) callconv(.c) ?*c.GOutputStream,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var parent: ?*c.GstBaseSinkClass = null;

pub fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn klass(s: *Self) *Class {
    return @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(s)).g_class));
}

fn isOutput(p: anytype) bool {
    return cm.isA(p, c.g_output_stream_get_type());
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.cancel) |x| c.g_object_unref(x);
    s.cancel = null;
    if (s.stream) |x| c.g_object_unref(x);
    s.stream = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id != PROP_CLOSE_ON_STOP) return cm.warnInvalid(FILE, o, id, spec, 146);
    c.g_value_set_boolean(v, me(o).close_on_stop);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id != PROP_CLOSE_ON_STOP) return cm.warnInvalid(FILE, o, id, spec, 162);
    me(o).close_on_stop = c.g_value_get_boolean(v);
}

fn start(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    const s = me(b);
    s.position = 0;
    s.stream = klass(s).get_stream.?(s);
    if (!isOutput(s.stream)) {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_WRITE, null, c.g_strdup("No output stream provided by subclass"), FILE, "gst_gio_base_sink_start", 178);
        return 0;
    } else if (c.g_output_stream_is_closed(s.stream) != 0) {
        cm.elementError(s, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_FAILED, null, c.g_strdup("Output stream is already closed"), FILE, "gst_gio_base_sink_start", 182);
        return 0;
    }
    return 1;
}

fn closeWarning(s: *Self, debug: [*c]u8, line: c.gint) void {
    cm.elementWarning(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_CLOSE, null, debug, FILE, "gst_gio_base_sink_stop", line);
}

fn stop(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    const s = me(b);
    var err: [*c]c.GError = null;
    if (s.close_on_stop != 0 and isOutput(s.stream)) {
        const ok = c.g_output_stream_close(s.stream, s.cancel, &err) != 0;
        if (!ok and !gio.gioError(s, "g_output_stream_close", &err, null)) {
            closeWarning(s, c.g_strdup_printf("gio_output_stream_close failed: %s", err.*.message), 207);
            c.g_clear_error(&err);
        } else if (!ok) closeWarning(s, c.g_strdup("g_output_stream_close failed"), 211);
    } else {
        const ok = c.g_output_stream_flush(s.stream, s.cancel, &err) != 0;
        if (!ok and !gio.gioError(s, "g_output_stream_flush", &err, null)) {
            closeWarning(s, c.g_strdup_printf("gio_output_stream_flush failed: %s", err.*.message), 223);
            c.g_clear_error(&err);
        } else if (!ok) closeWarning(s, c.g_strdup("g_output_stream_flush failed"), 227);
    }
    c.g_object_unref(@ptrCast(s.stream));
    s.stream = null;
    return 1;
}

fn unlock(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    c.g_cancellable_cancel(me(b).cancel);
    return 1;
}

fn unlockStop(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    const s = me(b);
    c.g_object_unref(s.cancel);
    s.cancel = c.g_cancellable_new();
    return 1;
}

fn event(b: [*c]c.GstBaseSink, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(b);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (s.stream == null) return 1;
    switch (cm.eventType(e)) {
        c.GST_EVENT_SEGMENT => if (isOutput(s.stream)) {
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(e, &seg);
            if (seg.*.format == c.GST_FORMAT_BYTES) {
                if (gio.isSeekable(s.stream)) {
                    ret = gio.seek(s, s.stream, seg.*.start, s.cancel);
                    if (ret == c.GST_FLOW_OK) s.position = seg.*.start;
                } else ret = c.GST_FLOW_NOT_SUPPORTED;
            }
        },
        c.GST_EVENT_EOS, c.GST_EVENT_FLUSH_START => if (isOutput(s.stream)) {
            var err: [*c]c.GError = null;
            if (c.g_output_stream_flush(s.stream, s.cancel, &err) == 0 and !gio.gioError(s, "g_output_stream_flush", &err, &ret)) {
                cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, null, c.g_strdup_printf("flush failed: %s", err.*.message), FILE, "gst_gio_base_sink_event", 308);
                c.g_clear_error(&err);
            }
        },
        else => {},
    }
    if (ret == c.GST_FLOW_OK) return parent.?.event.?(b, e);
    c.gst_event_unref(e);
    return 0;
}

fn render(b: [*c]c.GstBaseSink, buffer: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(b);
    if (!cm.that(isOutput(s.stream), "gst_gio_base_sink_render", "G_IS_OUTPUT_STREAM (sink->stream)")) return c.GST_FLOW_ERROR;
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(buffer, &map, c.GST_MAP_READ);
    var written: usize = 0;
    var err: [*c]c.GError = null;
    const ok = c.g_output_stream_write_all(s.stream, map.data, map.size, &written, s.cancel, &err) != 0;
    c.gst_buffer_unmap(buffer, &map);
    if (ok) {
        s.position += written;
        return c.GST_FLOW_OK;
    }
    var ret: c.GstFlowReturn = c.GST_FLOW_ERROR;
    if (!gio.gioError(s, "g_output_stream_write_all", &err, &ret)) {
        if (gio.ioError(err, c.G_IO_ERROR_NO_SPACE)) {
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NO_SPACE_LEFT, null, c.g_strdup_printf("Could not write to stream: %s", err.*.message), FILE, "gst_gio_base_sink_render", 357);
        } else {
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, null, c.g_strdup_printf("Could not write to stream: %s", err.*.message), FILE, "gst_gio_base_sink_render", 360);
        }
        c.g_clear_error(&err);
    }
    return ret;
}

fn query(b: [*c]c.GstBaseSink, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(b);
    var format: c.GstFormat = 0;
    switch (cm.queryType(q)) {
        c.GST_QUERY_POSITION => {
            c.gst_query_parse_position(q, &format, null);
            if (format != c.GST_FORMAT_BYTES and format != c.GST_FORMAT_DEFAULT) return 0;
            c.gst_query_set_position(q, format, @bitCast(s.position));
            return 1;
        },
        c.GST_QUERY_FORMATS => {
            c.gst_query_set_formats(q, 2, c.GST_FORMAT_DEFAULT, c.GST_FORMAT_BYTES);
            return 1;
        },
        c.GST_QUERY_URI => {
            if (!cm.isA(b, c.gst_uri_handler_get_type())) return 0;
            const uri = c.gst_uri_handler_get_uri(@ptrCast(s));
            c.gst_query_set_uri(q, uri);
            c.g_free(uri);
            return 1;
        },
        c.GST_QUERY_SEEKING => {
            c.gst_query_parse_seeking(q, &format, null, null, null);
            const ok = format == c.GST_FORMAT_BYTES or format == c.GST_FORMAT_DEFAULT;
            c.gst_query_set_seeking(q, format, @intFromBool(ok and gio.isSeekable(s.stream)), 0, -1);
            return 1;
        },
        else => return parent.?.query.?(b, q),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("gio_base_sink", 0, "GIO base sink");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.get_property = getProperty;
    oc.set_property = setProperty;
    c.gst_element_class_add_static_pad_template(@ptrCast(@alignCast(k)), &sink_t);
    c.g_object_class_install_property(oc, PROP_CLOSE_ON_STOP, c.g_param_spec_boolean("close-on-stop", "Close stream on stop", "Close the stream when the element stops (i.e. goes from READY to NULL) rather than when the element is disposed)", 0, cm.RW));
    const bc: *c.GstBaseSinkClass = @ptrCast(@alignCast(k));
    bc.start = start;
    bc.stop = stop;
    bc.unlock = unlock;
    bc.unlock_stop = unlockStop;
    bc.query = query;
    bc.event = event;
    bc.render = render;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    c.gst_base_sink_set_sync(@ptrCast(s), 0);
    s.cancel = c.g_cancellable_new();
    s.close_on_stop = 0;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_base_sink_get_type(), "GstGioBaseSink", Class, Self, classInit, init);
            c.gst_type_mark_as_plugin_api(t, 0);
            return t;
        }
    }.f);
}
