const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const pc = @import("pc.zig").p;
const base = @import("base.zig");

const FILE = "../ext/pango/gstclockoverlay.c";
const DEFAULT_FORMAT = "%H:%M:%S";
const PROP_TIMEFORMAT = 1;

const Self = extern struct {
    parent: base.Self,
    format: [*c]u8,
    wformat: ?*anyopaque,
    text: [*c]u8,
};

var once: cm.Once = .{};
var parent_obj: *c.GObjectClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn renderTime(s: *Self) [*c]u8 {
    var now: pc.time_t = pc.time(null);
    var tm: pc.struct_tm = undefined;
    pc.tzset();
    const t = pc.localtime_r(&now, &tm);
    if (t == null) return c.g_strdup("--:--:--");
    var buf: [256]u8 = undefined;
    if (pc.strftime(&buf, buf.len, s.format, t) == 0) return c.g_strdup("");
    return c.g_strdup(&buf);
}

fn getText(o: *base.Self, _: [*c]c.GstBuffer) callconv(.c) [*c]u8 {
    const s = me(o);
    const txt = c.g_strdup(o.default_text);
    cm.lock(s);
    var time_str = renderTime(s);
    cm.unlock(s);
    var ret: [*c]u8 = undefined;
    if (txt != null and txt[0] != 0) {
        ret = c.g_strdup_printf("%s %s", txt, time_str);
    } else {
        ret = time_str;
        time_str = null;
    }
    if (c.g_strcmp0(ret, s.text) != 0) {
        o.need_render = 1;
        c.g_free(s.text);
        s.text = c.g_strdup(ret);
    }
    c.g_free(txt);
    c.g_free(time_str);
    return ret;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_free(s.format);
    c.g_free(s.text);
    s.format = null;
    c.g_free(s.wformat);
    parent_obj.finalize.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    cm.lock(s);
    defer cm.unlock(s);
    if (id == PROP_TIMEFORMAT) {
        c.g_free(s.format);
        s.format = c.g_value_dup_string(v);
        if (s.format == null) s.format = c.g_strdup(DEFAULT_FORMAT);
    } else cm.warnInvalid(FILE, o, id, spec, 252);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    cm.lock(s);
    defer cm.unlock(s);
    if (id == PROP_TIMEFORMAT) c.g_value_set_string(v, s.format) else cm.warnInvalid(FILE, o, id, spec, 271);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_obj = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Clock overlay", "Filter/Editor/Video", "Overlays the current clock time on a video stream", "Tim-Philipp Müller <tim@centricular.net>");
    @as(*base.Class, @ptrCast(@alignCast(k))).get_text = getText;
    c.g_object_class_install_property(oc, PROP_TIMEFORMAT, c.g_param_spec_string("time-format", "Date/Time Format", "Format to use for time and date value, as in strftime.", DEFAULT_FORMAT, cm.RW));
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.format = c.g_strdup(DEFAULT_FORMAT);
    base.setMonospace(&s.parent);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(base.getType(), "GstClockOverlay", base.Class, Self, classInit, init);
        }
    }.f);
}
