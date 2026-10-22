const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const base = @import("base.zig");

const FILE = "../ext/pango/gsttimeoverlay.c";
const NONE = std.math.maxInt(u64);
const SEC: u64 = c.GST_SECOND;

const Line = enum(c.gint) { buffer_time, stream_time, running_time, time_code, elapsed_running_time, reference_timestamp, buffer_count, buffer_offset };
const Prop = enum(c.guint) { time_line = 1, show_times_as_dates, datetime_epoch, datetime_format, reference_timestamp_caps };

const Self = extern struct {
    parent: base.Self,
    time_line: c.gint,
    show_times_as_dates: c.gboolean,
    buffer_count: c.guint,
    show_buffer_count: c.gboolean,
    datetime_format: [*c]u8,
    datetime_epoch: ?*c.GDateTime,
    reference_timestamp_caps: [*c]c.GstCaps,
    first_running_time: c.GstClockTime,
    orig_video_event: c.GstPadEventFunction,
};

var ntp_caps = c.GstStaticCaps{ .caps = null, .string = "timestamp/x-ntp", ._gst_reserved = .{null} ** 4 };
var once: cm.Once = .{};
var line_once: cm.Once = .{};
var parent_el: *c.GstElementClass = undefined;
var parent_obj: *c.GObjectClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn lineType() c.GType {
    return line_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "buffer-time", .value_nick = "buffer-time" },
            .{ .value = 1, .value_name = "stream-time", .value_nick = "stream-time" },
            .{ .value = 2, .value_name = "running-time", .value_nick = "running-time" },
            .{ .value = 3, .value_name = "time-code", .value_nick = "time-code" },
            .{ .value = 4, .value_name = "elapsed-running-time", .value_nick = "elapsed-running-time" },
            .{ .value = 5, .value_name = "reference-timestamp", .value_nick = "reference-timestamp" },
            .{ .value = 6, .value_name = "buffer-count", .value_nick = "buffer-count" },
            .{ .value = 7, .value_name = "buffer-offset", .value_nick = "buffer-offset" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static("GstTimeOverlayTimeLine", &values);
        }
    }.f);
}

fn renderTime(t: c.GstClockTime) [*c]u8 {
    if (t == NONE) return c.g_strdup("");
    const h: c.guint = @truncate(t / (SEC * 60 * 60));
    const m: c.guint = @truncate((t / (SEC * 60)) % 60);
    const sec: c.guint = @truncate((t / SEC) % 60);
    const ms: c.guint = @truncate((t % SEC) / (1000 * 1000));
    return c.g_strdup_printf("%u:%02u:%02u.%03u", h, m, sec, ms);
}

fn getText(o: *base.Self, frame: [*c]c.GstBuffer) callconv(.c) [*c]u8 {
    const s = me(o);
    o.need_render = 1;
    s.show_buffer_count = 0;
    const line = @atomicLoad(c.gint, &s.time_line, .seq_cst);
    var time_str: [*c]u8 = undefined;
    if (line == @intFromEnum(Line.time_code)) {
        const meta: [*c]c.GstVideoTimeCodeMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(frame, c.gst_video_time_code_meta_api_get_type())));
        if (meta == null) return c.g_strdup("00:00:00:00");
        time_str = c.gst_video_time_code_to_string(&meta[0].tc);
    } else {
        const seg = &o.segment;
        const tb = frame[0].pts;
        var ts = tb;
        if (tb == NONE) return c.g_strdup("");
        switch (line) {
            @intFromEnum(Line.stream_time) => ts = c.gst_segment_to_stream_time(seg, c.GST_FORMAT_TIME, tb),
            @intFromEnum(Line.running_time) => ts = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, tb),
            @intFromEnum(Line.elapsed_running_time) => {
                ts = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, tb);
                if (s.first_running_time == NONE) s.first_running_time = ts;
                ts -%= s.first_running_time;
            },
            @intFromEnum(Line.reference_timestamp) => {
                ts = 0;
                if (s.reference_timestamp_caps != null) {
                    const meta = c.gst_buffer_get_reference_timestamp_meta(frame, s.reference_timestamp_caps);
                    if (meta != null) ts = meta[0].timestamp;
                }
            },
            @intFromEnum(Line.buffer_count) => {
                s.show_buffer_count = 1;
                s.buffer_count +%= 1;
            },
            @intFromEnum(Line.buffer_offset) => {
                s.show_buffer_count = 1;
                ts = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, tb);
                s.buffer_count = @truncate(c.gst_util_uint64_scale(ts, @bitCast(@as(i64, o.info.fps_n)), @as(u64, @bitCast(@as(i64, o.info.fps_d))) *% SEC));
            },
            else => ts = tb,
        }
        if (s.show_buffer_count != 0) {
            time_str = c.g_strdup_printf("%u", s.buffer_count);
        } else if (s.show_times_as_dates != 0) {
            const dt = c.g_date_time_add_seconds(s.datetime_epoch, @as(f64, @floatFromInt(ts)) / @as(f64, @floatFromInt(SEC)));
            time_str = c.g_date_time_format(dt, s.datetime_format);
            c.g_date_time_unref(dt);
        } else time_str = renderTime(ts);
    }
    const txt = c.g_strdup(o.default_text);
    var ret: [*c]u8 = undefined;
    if (txt != null and txt[0] != 0) {
        ret = c.g_strdup_printf("%s %s", txt, time_str);
    } else {
        ret = time_str;
        time_str = null;
    }
    c.g_free(txt);
    c.g_free(time_str);
    return ret;
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    if (t == c.GST_STATE_CHANGE_READY_TO_PAUSED) {
        s.first_running_time = NONE;
        s.buffer_count = 0;
    }
    return parent_el.change_state.?(e, t);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.reference_timestamp_caps != null) c.gst_caps_unref(s.reference_timestamp_caps);
    s.reference_timestamp_caps = null;
    c.g_date_time_unref(s.datetime_epoch);
    c.g_free(s.datetime_format);
    parent_obj.finalize.?(o);
}

fn videoEvent(pad: ?*c.GstPad, parent: ?*c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(parent);
    if (e[0].type == c.GST_EVENT_FLUSH_STOP) s.first_running_time = NONE;
    return s.orig_video_event.?(pad, parent, e);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.time_line) => @atomicStore(c.gint, &s.time_line, c.g_value_get_enum(v), .seq_cst),
        @intFromEnum(Prop.show_times_as_dates) => s.show_times_as_dates = c.g_value_get_boolean(v),
        @intFromEnum(Prop.datetime_epoch) => {
            c.g_date_time_unref(s.datetime_epoch);
            s.datetime_epoch = @ptrCast(c.g_value_dup_boxed(v));
        },
        @intFromEnum(Prop.datetime_format) => {
            c.g_free(s.datetime_format);
            s.datetime_format = c.g_value_dup_string(v);
        },
        @intFromEnum(Prop.reference_timestamp_caps) => {
            if (s.reference_timestamp_caps != null) c.gst_caps_unref(s.reference_timestamp_caps);
            s.reference_timestamp_caps = @ptrCast(@alignCast(c.g_value_dup_boxed(v)));
        },
        else => cm.warnInvalid(FILE, o, id, spec, 451),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.time_line) => c.g_value_set_enum(v, @atomicLoad(c.gint, &s.time_line, .seq_cst)),
        @intFromEnum(Prop.show_times_as_dates) => c.g_value_set_boolean(v, s.show_times_as_dates),
        @intFromEnum(Prop.datetime_epoch) => c.g_value_set_boxed(v, s.datetime_epoch),
        @intFromEnum(Prop.datetime_format) => c.g_value_set_string(v, s.datetime_format),
        @intFromEnum(Prop.reference_timestamp_caps) => c.g_value_set_boxed(v, s.reference_timestamp_caps),
        else => cm.warnInvalid(FILE, o, id, spec, 479),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_el = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    parent_obj = @ptrCast(@alignCast(parent_el));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Time overlay", "Filter/Editor/Video", "Overlays buffer time stamps on a video stream", "Tim-Philipp Müller <tim@centricular.net>");
    @as(*base.Class, @ptrCast(@alignCast(k))).get_text = getText;
    ec.change_state = changeState;
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, @intFromEnum(Prop.time_line), c.g_param_spec_enum("time-mode", "Time Mode", "What time to show", lineType(), 0, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.datetime_epoch), c.g_param_spec_boxed("datetime-epoch", "Datetime Epoch", "When showing times as dates, the initial date from which time is counted, if not specified prime epoch is used (1900-01-01)", c.g_date_time_get_type(), cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.datetime_format), c.g_param_spec_string("datetime-format", "Datetime Format", "When showing times as dates, the format to render date and time in", "%F %T", cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.show_times_as_dates), c.g_param_spec_boolean("show-times-as-dates", "Show times as dates", "Whether to display times, counted from datetime-epoch, as dates", 0, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.reference_timestamp_caps), c.g_param_spec_boxed("reference-timestamp-caps", "Reference Timestamp Caps", "Caps to use for the reference timestamp time mode", c.gst_caps_get_type(), cm.RW));
    c.gst_type_mark_as_plugin_api(lineType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.parent.valign = @intFromEnum(base.VAlign.top);
    s.parent.halign = @intFromEnum(base.HAlign.left);
    s.time_line = 0;
    s.show_times_as_dates = 0;
    s.datetime_epoch = c.g_date_time_new_utc(1900, 1, 1, 0, 0, 0);
    s.datetime_format = c.g_strdup("%F %T");
    s.reference_timestamp_caps = c.gst_static_caps_get(&ntp_caps);
    base.setMonospace(&s.parent);
    const pad = c.gst_element_get_static_pad(@ptrCast(s), "video_sink");
    s.orig_video_event = @as(*@import("../padlayout.zig").Pad, @ptrCast(@alignCast(pad))).eventfunc;
    c.gst_pad_set_event_function_full(pad, videoEvent, null, null);
    c.gst_object_unref(pad);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(base.getType(), "GstTimeOverlay", base.Class, Self, classInit, init);
        }
    }.f);
}
