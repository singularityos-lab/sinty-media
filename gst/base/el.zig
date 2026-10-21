const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
pub const Pad = @import("../padlayout.zig").Pad;

pub const NONE: u64 = std.math.maxInt(u64);

pub fn pad(p: anytype) *Pad {
    return @ptrCast(@alignCast(p));
}

pub fn raw(p: anytype) ?*c.GstPad {
    return @ptrCast(@alignCast(p));
}

pub fn obj(p: anytype) *c.GstObject {
    return @ptrCast(@alignCast(p));
}

pub fn lock(p: anytype) void {
    c.g_mutex_lock(&obj(p).lock);
}

pub fn unlock(p: anytype) void {
    c.g_mutex_unlock(&obj(p).lock);
}

pub fn streamLock(p: anytype) void {
    c.g_rec_mutex_lock(&pad(p).stream_rec_lock);
}

pub fn streamUnlock(p: anytype) void {
    c.g_rec_mutex_unlock(&pad(p).stream_rec_lock);
}

pub fn flags(p: anytype) c.guint32 {
    return obj(p).flags;
}

pub fn setFlag(p: anytype, f: c.guint32) void {
    obj(p).flags |= f;
}

pub fn unsetFlag(p: anytype, f: c.guint32) void {
    obj(p).flags &= ~f;
}

pub fn mode(p: anytype) c.GstPadMode {
    return pad(p).mode;
}

pub fn modeLocked(p: anytype) c.GstPadMode {
    lock(p);
    defer unlock(p);
    return pad(p).mode;
}

pub fn classOf(comptime Class: type, p: anytype) *Class {
    return gtype.classPeek(Class, p);
}

pub const Domain = enum { core, library, resource, stream };

fn quark(d: Domain) c.GQuark {
    return switch (d) {
        .core => c.gst_core_error_quark(),
        .library => c.gst_library_error_quark(),
        .resource => c.gst_resource_error_quark(),
        .stream => c.gst_stream_error_quark(),
    };
}

pub fn messageAt(e: anytype, kind: c.GstMessageType, d: Domain, code: c.gint, text: [*c]u8, debug: [*c]u8, comptime path: []const u8, comptime func: []const u8, line: c.gint, details: [*c]c.GstStructure) void {
    c.gst_element_message_full_with_details(@ptrCast(@alignCast(e)), kind, quark(d), code, text, debug, path ++ "", func ++ "", line, details);
}

pub fn message(e: anytype, kind: c.GstMessageType, d: Domain, code: c.gint, text: [*c]u8, debug: [*c]u8, comptime file: []const u8, comptime func: []const u8, line: c.gint, details: [*c]c.GstStructure) void {
    messageAt(e, kind, d, code, text, debug, "../libs/gst/base/" ++ file, func, line, details);
}

pub fn errAt(e: anytype, d: Domain, code: c.gint, text: [*c]const u8, debug: [*c]u8, comptime textdomain: []const u8, comptime path: []const u8, comptime func: []const u8, line: c.gint) void {
    messageAt(e, c.GST_MESSAGE_ERROR, d, code, if (text != null) c.g_strdup(c.g_dgettext(textdomain ++ "", text)) else null, debug, path, func, line, null);
}

pub fn err(e: anytype, d: Domain, code: c.gint, text: [*c]const u8, debug: [*c]u8, comptime file: []const u8, comptime func: []const u8, line: c.gint) void {
    errAt(e, d, code, text, debug, "gstreamer-1.0", "../libs/gst/base/" ++ file, func, line);
}

pub fn flowError(e: anytype, flow: c.GstFlowReturn, comptime file: []const u8, comptime func: []const u8, line: c.gint) void {
    const text = c.g_strdup("Internal data stream error.");
    const debug = c.g_strdup_printf("streaming stopped, reason %s (%d)", c.gst_flow_get_name(flow), flow);
    message(e, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_FAILED, text, debug, file, func, line, c.gst_make_element_message_details("flow-return", c.G_TYPE_INT, flow, @as(?*anyopaque, null)));
}

pub fn badPropertyAt(o: [*c]c.GObject, id: c.guint, pspec: [*c]c.GParamSpec, comptime domain: []const u8, comptime path: []const u8, line: c.gint) void {
    c.g_log(domain ++ "", c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", path ++ "", line, "property", id, pspec[0].name, c.g_type_name(pspec[0].g_type_instance.g_class.*.g_type), c.g_type_name(gtype.typeOf(o)));
}

pub fn badProperty(o: [*c]c.GObject, id: c.guint, pspec: [*c]c.GParamSpec, comptime file: []const u8, line: c.gint) void {
    badPropertyAt(o, id, pspec, "GStreamer-Base", "../libs/gst/base/" ++ file, line);
}

pub fn padSetCaps(p: ?*c.GstPad, caps: [*c]c.GstCaps) bool {
    if (!@import("check.zig").that(gtype.instanceOf(p, c.gst_pad_get_type()), "gst_pad_set_caps", "GST_IS_PAD (pad)")) return false;
    if (!@import("check.zig").that(caps != null and c.gst_caps_is_fixed(caps) != 0, "gst_pad_set_caps", "caps != NULL && gst_caps_is_fixed (caps)")) return false;
    const ev = c.gst_event_new_caps(caps);
    if (pad(p).direction == c.GST_PAD_SRC) return c.gst_pad_push_event(p, ev) != 0;
    return c.gst_pad_send_event(p, ev) != 0;
}
