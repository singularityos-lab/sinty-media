const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../gst/rawparse/gstrawbaseparse.c";
const PROP_USE_SINK_CAPS = 1;

pub const CURRENT = 1;
pub const SINKCAPS = 2;
pub const PROPERTIES = 3;

pub const Config = c_uint;

pub const Self = extern struct {
    parent: c.GstBaseParse,
    src_caps_set: c.gboolean,
    config_mutex: c.GMutex,
};

pub const Class = extern struct {
    parent: c.GstBaseParseClass,
    set_current_config: ?*const fn (*Self, Config) callconv(.c) c.gboolean,
    get_current_config: ?*const fn (*Self) callconv(.c) Config,
    set_config_from_caps: ?*const fn (*Self, Config, [*c]c.GstCaps) callconv(.c) c.gboolean,
    get_caps_from_config: ?*const fn (*Self, Config, *[*c]c.GstCaps) callconv(.c) c.gboolean,
    get_config_frame_size: ?*const fn (*Self, Config) callconv(.c) usize,
    get_max_frames_per_buffer: ?*const fn (*Self, Config) callconv(.c) c.guint,
    is_config_ready: ?*const fn (*Self, Config) callconv(.c) c.gboolean,
    process: ?*const fn (*Self, Config, [*c]c.GstBuffer, usize, usize, *[*c]c.GstBuffer) callconv(.c) c.gboolean,
    is_unit_format_supported: ?*const fn (*Self, c.GstFormat) callconv(.c) c.gboolean,
    get_units_per_second: ?*const fn (*Self, c.GstFormat, Config, *usize, *usize) callconv(.c) void,
    get_overhead_size: ?*const fn (*Self, Config) callconv(.c) c.gint,
    get_alignment: ?*const fn (*Self, Config) callconv(.c) c.gint,
};

var once: cm.Once = .{};
var parent: ?*c.GstBaseParseClass = null;

pub fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn klass(s: *Self) *Class {
    return @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(s)).g_class));
}

pub fn lock(s: *Self) void {
    c.g_mutex_lock(&s.config_mutex);
}

pub fn unlock(s: *Self) void {
    c.g_mutex_unlock(&s.config_mutex);
}

pub fn usingSinkCaps(s: *Self) bool {
    return klass(s).get_current_config.?(s) == SINKCAPS;
}

pub fn invalidateSrcCaps(s: *Self) void {
    s.src_caps_set = 0;
}

fn streamError(s: *Self, code: c.gint, text: [*c]const u8, debug: [*c]u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_stream_error_quark(), code, c.g_strdup(text), debug, FILE, func, line);
}

fn updateMinSize(s: *Self) void {
    const k = klass(s);
    if (k.is_config_ready.?(s, CURRENT) != 0) c.gst_base_parse_set_min_frame_size(@ptrCast(s), @intCast(k.get_config_frame_size.?(s, CURRENT)));
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_mutex_clear(&me(o).config_mutex);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    if (id != PROP_USE_SINK_CAPS) return cm.warnInvalid(FILE, o, id, spec, 276);
    lock(s);
    const want = c.g_value_get_boolean(v) != 0;
    if (want == usingSinkCaps(s)) return unlock(s);
    if (klass(s).set_current_config.?(s, if (want) SINKCAPS else PROPERTIES) == 0) {
        unlock(s);
        streamError(s, c.GST_STREAM_ERROR_FAILED, "could not set new current config", c.g_strdup_printf("use-sink-caps property: %d", @as(c_int, @intFromBool(want))), "gst_raw_base_parse_set_property", 241);
        return;
    }
    updateMinSize(s);
    s.src_caps_set = 0;
    unlock(s);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    if (id != PROP_USE_SINK_CAPS) return cm.warnInvalid(FILE, o, id, spec, 296);
    lock(s);
    c.g_value_set_boolean(v, @intFromBool(usingSinkCaps(s)));
    unlock(s);
}

fn start(p: [*c]c.GstBaseParse) callconv(.c) c.gboolean {
    const s = me(p);
    lock(s);
    updateMinSize(s);
    unlock(s);
    return 1;
}

fn stop(p: [*c]c.GstBaseParse) callconv(.c) c.gboolean {
    const s = me(p);
    lock(s);
    s.src_caps_set = 0;
    unlock(s);
    return 1;
}

fn setSinkCaps(p: [*c]c.GstBaseParse, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(p);
    const k = klass(s);
    lock(s);
    if (k.set_config_from_caps.?(s, SINKCAPS, caps) == 0) return 0;
    if (!usingSinkCaps(s)) {
        unlock(s);
        return 1;
    }
    var src_caps: [*c]c.GstCaps = null;
    if (k.get_caps_from_config.?(s, CURRENT, &src_caps) == 0) return 0;
    c.gst_base_parse_set_min_frame_size(p, @intCast(k.get_config_frame_size.?(s, CURRENT)));
    s.src_caps_set = 1;
    unlock(s);
    _ = c.gst_pad_push_event(p.*.srcpad, c.gst_event_new_caps(src_caps));
    c.gst_caps_unref(src_caps);
    return 1;
}

fn alignBuffer(alignment: usize, buffer: [*c]c.GstBuffer, out_size: usize) [*c]c.GstBuffer {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(buffer, &map, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(buffer, &map);
    if (map.size < @sizeOf(usize)) return null;
    if (@intFromPtr(map.data) & (alignment - 1) == 0) return null;
    var params = c.GstAllocationParams{ .flags = 0, .@"align" = alignment - 1, .prefix = 0, .padding = 0, ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
    const fresh = c.gst_buffer_new_allocate(null, out_size, &params);
    _ = c.gst_buffer_fill(fresh, 0, map.data, out_size);
    _ = c.gst_buffer_copy_into(fresh, buffer, c.GST_BUFFER_COPY_METADATA, 0, out_size);
    return fresh;
}

fn dropWith(frame: [*c]c.GstBaseParseFrame, ev: [*c]c.GstEvent, ret: c.GstFlowReturn) c.GstFlowReturn {
    frame.*.flags |= c.GST_BASE_PARSE_FRAME_FLAG_DROP;
    if (ev != null) c.gst_event_unref(ev);
    return ret;
}

fn notReady(s: *Self, comptime func: []const u8, comptime text: []const u8, line: c.gint) void {
    streamError(s, c.GST_STREAM_ERROR_FORMAT, "sink caps config is the current config, and it is not ready -" ++ text ++ "upstream may not have pushed a caps event yet", null, func, line);
}

fn handleFrame(p: [*c]c.GstBaseParse, frame: [*c]c.GstBaseParseFrame, skip: [*c]c.gint) callconv(.c) c.GstFlowReturn {
    const s = me(p);
    const k = klass(s);
    skip.* = 0;
    var ev: [*c]c.GstEvent = null;
    lock(s);
    if (s.src_caps_set == 0) {
        if (k.is_config_ready.?(s, CURRENT) == 0) {
            if (usingSinkCaps(s)) {
                unlock(s);
                notReady(s, "gst_raw_base_parse_handle_frame", "", 650);
                return dropWith(frame, null, c.GST_FLOW_ERROR);
            }
            unreachable;
        }
        var src_caps: [*c]c.GstCaps = null;
        if (k.get_caps_from_config.?(s, CURRENT, &src_caps) == 0) {
            unlock(s);
            return dropWith(frame, null, c.GST_FLOW_NOT_NEGOTIATED);
        }
        ev = c.gst_event_new_caps(src_caps);
        c.gst_caps_unref(src_caps);
        s.src_caps_set = 1;
    }
    const frame_size: c.guint = @truncate(k.get_config_frame_size.?(s, CURRENT));
    if (frame_size <= 0) {
        streamError(s, c.GST_STREAM_ERROR_FORMAT, "Non strictly positive frame size", null, "gst_raw_base_parse_handle_frame", 526);
        unlock(s);
        return dropWith(frame, ev, c.GST_FLOW_ERROR);
    }
    const in_size = c.gst_buffer_get_size(frame.*.buffer);
    if (p.*.flags & c.GST_BASE_PARSE_FLAG_DRAINING != 0 and in_size < frame_size) {
        frame.*.flags |= c.GST_BASE_PARSE_FRAME_FLAG_DROP;
        unlock(s);
        return c.gst_base_parse_finish_frame(p, frame, @intCast(in_size));
    }
    var frames: c.guint = @intCast(in_size / frame_size);
    if (k.get_max_frames_per_buffer) |f| frames = @min(frames, f(s, CURRENT));
    var out_size: usize = @as(usize, frames) * frame_size;
    frame.*.overhead = if (k.get_overhead_size) |f| f(s, CURRENT) else 0;
    out_size -= @intCast(frame.*.overhead);
    var un: usize = 0;
    var ud: usize = 0;
    k.get_units_per_second.?(s, c.GST_FORMAT_BYTES, CURRENT, &un, &ud);
    const duration: u64 = if (un == 0 or ud == 0) cm.CLOCK_NONE else c.gst_util_uint64_scale(out_size, @as(u64, c.GST_SECOND) * ud, un);
    if (k.process) |f| {
        var processed: [*c]c.GstBuffer = null;
        if (f(s, CURRENT, frame.*.buffer, in_size, out_size, &processed) == 0) {
            unlock(s);
            streamError(s, c.GST_STREAM_ERROR_DECODE, "could not process data", null, "gst_raw_base_parse_handle_frame", 658);
            return dropWith(frame, ev, c.GST_FLOW_ERROR);
        }
        frame.*.out_buffer = processed;
    } else frame.*.out_buffer = null;
    if (k.get_alignment) |f| {
        const alignment = f(s, CURRENT);
        if (alignment != 1) {
            const aligned = alignBuffer(@intCast(alignment), if (frame.*.out_buffer != null) frame.*.out_buffer else frame.*.buffer, out_size);
            if (aligned != null) {
                if (frame.*.out_buffer != null) c.gst_buffer_unref(frame.*.out_buffer);
                frame.*.out_buffer = aligned;
            }
        }
    }
    if (frame.*.out_buffer != null) cm.buf(frame.*.out_buffer).duration = duration else cm.buf(frame.*.buffer).duration = duration;
    unlock(s);
    if (ev != null) _ = c.gst_pad_push_event(p.*.srcpad, ev);
    return c.gst_base_parse_finish_frame(p, frame, @intCast(out_size + @as(usize, @intCast(frame.*.overhead))));
}

fn supported(s: *Self, f: c.GstFormat) bool {
    return klass(s).is_unit_format_supported.?(s, f) != 0;
}

fn convert(p: [*c]c.GstBaseParse, sf: c.GstFormat, sv: i64, df: c.GstFormat, dv: [*c]i64) callconv(.c) c.gboolean {
    const s = me(p);
    const k = klass(s);
    lock(s);
    if (k.is_config_ready.?(s, CURRENT) == 0) {
        if (usingSinkCaps(s)) {
            unlock(s);
            notReady(s, "gst_raw_base_parse_convert", " ", 743);
            return 0;
        }
        unreachable;
    }
    var ret: c.gboolean = 1;
    var un: usize = 0;
    var ud: usize = 0;
    if (sf == df) {
        dv.* = sv;
    } else if ((sf == c.GST_FORMAT_TIME or df == c.GST_FORMAT_TIME) and supported(s, sf) and supported(s, df)) {
        if (sf == c.GST_FORMAT_TIME) {
            k.get_units_per_second.?(s, df, CURRENT, &un, &ud);
            dv.* = if (un == 0 or ud == 0) sv else @bitCast(c.gst_util_uint64_scale(@bitCast(sv), un, @as(u64, c.GST_SECOND) * ud));
        } else {
            k.get_units_per_second.?(s, sf, CURRENT, &un, &ud);
            dv.* = if (un == 0 or ud == 0) sv else @bitCast(c.gst_util_uint64_scale(@bitCast(sv), @as(u64, c.GST_SECOND) * ud, un));
        }
    } else ret = c.gst_base_parse_convert_default(p, sf, sv, df, dv);
    unlock(s);
    return ret;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("rawbaseparse", 0, "raw base parse class");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const bc: *c.GstBaseParseClass = @ptrCast(@alignCast(k));
    bc.start = start;
    bc.stop = stop;
    bc.set_sink_caps = setSinkCaps;
    bc.handle_frame = handleFrame;
    bc.convert = convert;
    c.g_object_class_install_property(oc, PROP_USE_SINK_CAPS, c.g_param_spec_boolean("use-sink-caps", "Use sink caps", "Use the sink caps for defining the output format", 0, cm.RW));
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.src_caps_set = 0;
    c.g_mutex_init(&s.config_mutex);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = c.g_type_register_static_simple(c.gst_base_parse_get_type(), c.g_intern_static_string("GstRawBaseParse"), @sizeOf(Class), classInit, @sizeOf(Self), init, c.G_TYPE_FLAG_ABSTRACT);
            c.gst_type_mark_as_plugin_api(t, 0);
            return t;
        }
    }.f);
}
