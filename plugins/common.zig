const std = @import("std");
pub const c = @import("c.zig").c;

pub const MUTABLE_PLAYING: c.GParamFlags = c.GST_PARAM_MUTABLE_PLAYING;
pub const MUTABLE_READY: c.GParamFlags = c.GST_PARAM_MUTABLE_READY;
pub const RW: c.GParamFlags = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;

pub fn tr(comptime domain: [:0]const u8, s: [*c]const u8) [*c]const u8 {
    return c.dgettext(domain, s);
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

pub fn typeOf(p: anytype) c.GType {
    return @as(*c.GTypeInstance, @ptrCast(@alignCast(p))).g_class[0].g_type;
}

pub fn warnInvalid(comptime file: []const u8, o: [*c]c.GObject, id: c.guint, spec: [*c]c.GParamSpec, line: c_int) void {
    c.g_log("GLib-GObject", c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", (file ++ "").ptr, line, "property", id, spec[0].name, c.g_type_name(spec[0].g_type_instance.g_class[0].g_type), c.g_type_name(typeOf(o)));
}

pub fn elementError(el: anytype, domain: c.GQuark, code: c.gint, text: [*c]u8, debug: [*c]u8, comptime file: []const u8, comptime func: []const u8, line: c.gint) void {
    c.gst_element_message_full(@ptrCast(@alignCast(el)), c.GST_MESSAGE_ERROR, domain, code, text, debug, (file ++ "").ptr, (func ++ "").ptr, line);
}

pub fn elementWarning(el: anytype, domain: c.GQuark, code: c.gint, text: [*c]u8, debug: [*c]u8, comptime file: []const u8, comptime func: []const u8, line: c.gint) void {
    c.gst_element_message_full(@ptrCast(@alignCast(el)), c.GST_MESSAGE_WARNING, domain, code, text, debug, (file ++ "").ptr, (func ++ "").ptr, line);
}

pub const Once = struct {
    t: c.GType = 0,

    pub fn get(self: *Once, comptime make: fn () c.GType) c.GType {
        if (c.g_once_init_enter_pointer(@ptrCast(&self.t)) != 0) {
            c.g_once_init_leave_pointer(@ptrCast(&self.t), @ptrFromInt(make()));
        }
        return self.t;
    }
};

pub fn register(parent: c.GType, name: [*:0]const u8, comptime Class: type, comptime Instance: type, class_init: c.GClassInitFunc, instance_init: c.GInstanceInitFunc) c.GType {
    return c.g_type_register_static_simple(parent, c.g_intern_static_string(name), @sizeOf(Class), class_init, @sizeOf(Instance), instance_init, 0);
}

pub fn staticTemplate(comptime name: [:0]const u8, dir: c.GstPadDirection, presence: c.GstPadPresence, comptime caps: [:0]const u8) c.GstStaticPadTemplate {
    return .{ .name_template = name.ptr, .direction = dir, .presence = presence, .static_caps = .{ .caps = null, .string = caps.ptr, ._gst_reserved = std.mem.zeroes([4]c.gpointer) } };
}

pub fn eventType(e: anytype) c.GstEventType {
    return @as(*c.GstEvent, @ptrCast(@alignCast(e))).type;
}

pub fn queryType(q: anytype) c.GstQueryType {
    return @as(*c.GstQuery, @ptrCast(@alignCast(q))).type;
}

pub fn unrefEvent(p: c.gpointer) callconv(.c) void {
    c.gst_mini_object_unref(@ptrCast(@alignCast(p)));
}

pub fn unrefCaps(p: c.gpointer) callconv(.c) void {
    c.gst_mini_object_unref(@ptrCast(@alignCast(p)));
}

pub fn that(ok: bool, comptime func: []const u8, comptime expr: []const u8) bool {
    if (!ok) c.g_return_if_fail_warning("GStreamer", (func ++ "").ptr, (expr ++ "").ptr);
    return ok;
}

pub const Pad = @import("padlayout.zig").Pad;

pub fn pad(p: anytype) *Pad {
    return @ptrCast(@alignCast(p));
}

pub fn setCaps(p: ?*c.GstPad, caps: [*c]c.GstCaps) bool {
    const ev = c.gst_event_new_caps(caps);
    if (pad(p).direction == c.GST_PAD_SRC) return c.gst_pad_push_event(p, ev) != 0;
    return c.gst_pad_send_event(p, ev) != 0;
}

pub const CLOCK_NONE: u64 = std.math.maxInt(u64);

pub fn strNull(p: [*c]const u8) [*c]const u8 {
    return if (p == null) "(NULL)" else p;
}

pub fn padParentName(p: anytype) [*c]const u8 {
    if (p == null) return "''";
    const o = obj(p);
    if (o.parent == null) return "''";
    return strNull(o.parent[0].name);
}

pub fn padName(p: anytype) [*c]const u8 {
    if (p == null) return "''";
    return strNull(obj(p).name);
}

pub fn timeStr(out: []u8, t: u64) [*c]const u8 {
    if (t == CLOCK_NONE) {
        _ = std.fmt.bufPrintZ(out, "none", .{}) catch {};
        return out.ptr;
    }
    const s: u64 = t / 1_000_000_000;
    _ = c.g_snprintf(out.ptr, @intCast(out.len), "%u:%02u:%02u.%09u", @as(c.guint, @truncate(s / 3600)), @as(c.guint, @truncate((s / 60) % 60)), @as(c.guint, @truncate(s % 60)), @as(c.guint, @truncate(t % 1_000_000_000)));
    return out.ptr;
}

pub fn timeFmt(out: []u8, t: u64) [*c]const u8 {
    if (t == CLOCK_NONE) {
        _ = c.g_snprintf(out.ptr, @intCast(out.len), "%u:%02u:%02u.%09u", @as(c.guint, 99), @as(c.guint, 99), @as(c.guint, 99), @as(c.guint, 999999999));
        return out.ptr;
    }
    return timeStr(out, t);
}

pub fn buf(p: anytype) *c.GstBuffer {
    return @ptrCast(@alignCast(p));
}

pub fn typeOfClass(k: c.gpointer) c.GType {
    return @as(*c.GTypeClass, @ptrCast(@alignCast(k))).g_type;
}

const FLAG_NAMES = [_][]const u8{ "live", "decode-only", "discont", "resync", "corrupted", "marker", "header", "gap", "droppable", "delta-unit", "tag-memory", "sync-after", "non-droppable", "FIXME" };

pub fn flagsString(b: [*c]c.GstBuffer) [*c]u8 {
    const s = c.g_string_new(null);
    const flags = buf(b).mini_object.flags;
    for (FLAG_NAMES, 4..) |name, bit| {
        if (flags & (@as(c.guint, 1) << @intCast(bit)) != 0) {
            _ = c.g_string_append_len(s, name.ptr, @intCast(name.len));
            _ = c.g_string_append_c(s, ' ');
        }
    }
    return c.g_string_free(s, 0);
}

pub fn metaString(b: [*c]c.GstBuffer) [*c]u8 {
    var state: c.gpointer = null;
    var s: [*c]c.GString = null;
    while (true) {
        const m = c.gst_buffer_iterate_meta(b, &state);
        if (m == null) break;
        if (s == null) s = c.g_string_new(null) else _ = c.g_string_append(s, ", ");
        _ = c.g_string_append(s, c.g_type_name(m[0].info[0].type));
    }
    return if (s != null) c.g_string_free(s, 0) else null;
}
