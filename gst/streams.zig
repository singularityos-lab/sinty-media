const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const mini = @import("mini.zig");
const info = @import("info.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Stream = c.GstStream;

const Private = extern struct {
    flags: c.GstStreamFlags,
    kind: c.GstStreamType,
    tags: [*c]c.GstTagList,
    caps: [*c]c.GstCaps,
};

const PROP_ID = 1;
const PROP_FLAGS = 2;
const PROP_TYPE = 3;
const PROP_TAGS = 4;
const PROP_CAPS = 5;

var pspecs: [6]?*c.GParamSpec = .{null} ** 6;
var private_offset: c.gint = 0;
var parent_class: ?*c.GObjectClass = null;
var type_once: gtype.Once = .{};
pub var debug_cat: [*c]c.GstDebugCategory = null;

fn priv(s: anytype) *Private {
    const base: [*]u8 = @ptrCast(@constCast(s));
    return @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, private_offset)))));
}

fn isStream(s: anytype) bool {
    return gtype.instanceOf(s, gst_stream_get_type());
}

pub export fn gst_stream_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(object.gst_object_get_type(), "GstStream", c.GstStreamClass, Stream, classInit, instanceInit, 0);
            private_offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            debug_cat = info._gst_debug_category_new("streams", c.GST_DEBUG_BOLD, "debugging info for the stream and stream collection objects");
            return t;
        }
    }.f);
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s: *Stream = @ptrCast(@alignCast(instance));
    s.priv = @ptrCast(priv(s));
    priv(s).kind = c.GST_STREAM_TYPE_UNKNOWN;
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &private_offset);
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    const static = c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, PROP_ID, c.g_param_spec_string("stream-id", "Stream ID", "The stream ID of the stream", null, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | static));
    pspecs[PROP_FLAGS] = c.g_param_spec_flags("stream-flags", "Stream Flags", "The stream flags", c.gst_stream_flags_get_type(), c.GST_STREAM_FLAG_NONE, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | static);
    c.g_object_class_install_property(gc, PROP_FLAGS, pspecs[PROP_FLAGS]);
    pspecs[PROP_TYPE] = c.g_param_spec_flags("stream-type", "Stream Type", "The type of stream", c.gst_stream_type_get_type(), c.GST_STREAM_TYPE_UNKNOWN, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | static);
    c.g_object_class_install_property(gc, PROP_TYPE, pspecs[PROP_TYPE]);
    pspecs[PROP_CAPS] = c.g_param_spec_boxed("caps", "Caps", "The caps of the stream", c.gst_caps_get_type(), c.G_PARAM_READWRITE | static);
    c.g_object_class_install_property(gc, PROP_CAPS, pspecs[PROP_CAPS]);
    pspecs[PROP_TAGS] = c.g_param_spec_boxed("tags", "Tags", "The tags of the stream", c.gst_tag_list_get_type(), c.G_PARAM_READWRITE | static);
    c.g_object_class_install_property(gc, PROP_TAGS, pspecs[PROP_TAGS]);
    gc.finalize = finalize;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s: *Stream = @ptrCast(@alignCast(o));
    _ = mini.gst_mini_object_replace(@ptrCast(&priv(s).tags), null);
    _ = c.gst_caps_replace(&priv(s).caps, null);
    c.g_free(@constCast(s.stream_id));
    s.stream_id = null;
    parent_class.?.finalize.?(o);
}

pub export fn gst_stream_new(id: [*c]const u8, caps: [*c]c.GstCaps, kind: c.GstStreamType, flags: c.GstStreamFlags) [*c]Stream {
    const s = c.g_object_new(gst_stream_get_type(), "stream-id", id, "caps", caps, "stream-type", kind, "stream-flags", flags, @as(?*anyopaque, null));
    _ = object.gst_object_ref_sink(s);
    return @ptrCast(@alignCast(s));
}

fn setId(s: *Stream, id: [*c]const u8) void {
    if (!check.that(isStream(@as(?*Stream, s)), "gst_stream_set_stream_id", "GST_IS_STREAM (stream)")) return;
    object.lock(s);
    if (id != null) {
        s.stream_id = c.g_strdup(id);
    } else {
        s.stream_id = c.g_strdup_printf("%08x%08x%08x%08x", c.g_random_int(), c.g_random_int(), c.g_random_int(), c.g_random_int());
    }
    c.g_free(s.object.name);
    s.object.name = c.g_strdup(s.stream_id);
    object.unlock(s);
    if (id == null) info.gst_debug_log(debug_cat, c.GST_LEVEL_FIXME, "gst/streams.zig", "gst_stream_set_stream_id", 0, @ptrCast(s), "Created random stream-id, consider implementing a deterministic way of creating a stream-id");
}

pub export fn gst_stream_get_stream_id(s: [*c]Stream) [*c]const u8 {
    if (!check.that(isStream(s), "gst_stream_get_stream_id", "GST_IS_STREAM (stream)")) return null;
    return s[0].stream_id;
}

pub export fn gst_stream_set_stream_flags(s: [*c]Stream, flags: c.GstStreamFlags) void {
    if (!check.that(isStream(s), "gst_stream_set_stream_flags", "GST_IS_STREAM (stream)")) return;
    object.lock(s);
    priv(s).flags = flags;
    object.unlock(s);
    c.g_object_notify_by_pspec(@ptrCast(@alignCast(s)), pspecs[PROP_FLAGS]);
}

pub export fn gst_stream_get_stream_flags(s: [*c]Stream) c.GstStreamFlags {
    if (!check.that(isStream(s), "gst_stream_get_stream_flags", "GST_IS_STREAM (stream)")) return c.GST_STREAM_FLAG_NONE;
    object.lock(s);
    defer object.unlock(s);
    return priv(s).flags;
}

pub export fn gst_stream_set_stream_type(s: [*c]Stream, kind: c.GstStreamType) void {
    if (!check.that(isStream(s), "gst_stream_set_stream_type", "GST_IS_STREAM (stream)")) return;
    object.lock(s);
    priv(s).kind = kind;
    object.unlock(s);
    c.g_object_notify_by_pspec(@ptrCast(@alignCast(s)), pspecs[PROP_TYPE]);
}

pub export fn gst_stream_get_stream_type(s: [*c]Stream) c.GstStreamType {
    if (!check.that(isStream(s), "gst_stream_get_stream_type", "GST_IS_STREAM (stream)")) return c.GST_STREAM_TYPE_UNKNOWN;
    object.lock(s);
    defer object.unlock(s);
    return priv(s).kind;
}

pub export fn gst_stream_set_tags(s: [*c]Stream, tags: [*c]c.GstTagList) void {
    if (!check.that(isStream(s), "gst_stream_set_tags", "GST_IS_STREAM (stream)")) return;
    object.lock(s);
    var notify = false;
    const p = priv(s);
    if (p.tags == null or tags == null or c.gst_tag_list_is_equal(p.tags, tags) == 0) {
        _ = mini.gst_mini_object_replace(@ptrCast(&p.tags), @ptrCast(@alignCast(tags)));
        notify = true;
    }
    object.unlock(s);
    if (notify) c.g_object_notify_by_pspec(@ptrCast(@alignCast(s)), pspecs[PROP_TAGS]);
}

pub export fn gst_stream_get_tags(s: [*c]Stream) [*c]c.GstTagList {
    if (!check.that(isStream(s), "gst_stream_get_tags", "GST_IS_STREAM (stream)")) return null;
    object.lock(s);
    defer object.unlock(s);
    return if (priv(s).tags != null) c.gst_tag_list_ref(priv(s).tags) else null;
}

pub export fn gst_stream_set_caps(s: [*c]Stream, caps: [*c]c.GstCaps) void {
    if (!check.that(isStream(s), "gst_stream_set_caps", "GST_IS_STREAM (stream)")) return;
    object.lock(s);
    var notify = false;
    const p = priv(s);
    if (p.caps == null or (caps != null and c.gst_caps_is_equal(p.caps, caps) == 0)) {
        _ = c.gst_caps_replace(&p.caps, caps);
        notify = true;
    }
    object.unlock(s);
    if (notify) c.g_object_notify_by_pspec(@ptrCast(@alignCast(s)), pspecs[PROP_CAPS]);
}

pub export fn gst_stream_get_caps(s: [*c]Stream) [*c]c.GstCaps {
    if (!check.that(isStream(s), "gst_stream_get_caps", "GST_IS_STREAM (stream)")) return null;
    object.lock(s);
    defer object.unlock(s);
    return if (priv(s).caps != null) c.gst_caps_ref(priv(s).caps) else null;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: ?*c.GParamSpec) callconv(.c) void {
    const s: *Stream = @ptrCast(@alignCast(o));
    switch (id) {
        PROP_ID => setId(s, c.g_value_get_string(v)),
        PROP_FLAGS, PROP_TYPE => {
            object.lock(s);
            if (id == PROP_FLAGS) priv(s).flags = c.g_value_get_flags(v) else priv(s).kind = c.g_value_get_flags(v);
            object.unlock(s);
        },
        PROP_TAGS, PROP_CAPS => {
            object.lock(s);
            const slot: [*c][*c]c.GstMiniObject = if (id == PROP_TAGS) @ptrCast(&priv(s).tags) else @ptrCast(&priv(s).caps);
            _ = mini.gst_mini_object_replace(slot, @ptrCast(@alignCast(c.g_value_get_boxed(v))));
            object.unlock(s);
        },
        else => object.warnBadProperty(o, id, pspec),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: ?*c.GParamSpec) callconv(.c) void {
    const s: *Stream = @ptrCast(@alignCast(o));
    switch (id) {
        PROP_ID => c.g_value_set_string(v, gst_stream_get_stream_id(s)),
        PROP_FLAGS => c.g_value_set_flags(v, gst_stream_get_stream_flags(s)),
        PROP_TYPE => c.g_value_set_flags(v, gst_stream_get_stream_type(s)),
        PROP_TAGS => c.g_value_take_boxed(v, gst_stream_get_tags(s)),
        PROP_CAPS => c.g_value_take_boxed(v, gst_stream_get_caps(s)),
        else => object.warnBadProperty(o, id, pspec),
    }
}

pub export fn gst_stream_type_get_name(kind: c.GstStreamType) [*c]const u8 {
    switch (kind) {
        c.GST_STREAM_TYPE_UNKNOWN => return "unknown",
        c.GST_STREAM_TYPE_AUDIO => return "audio",
        c.GST_STREAM_TYPE_VIDEO => return "video",
        c.GST_STREAM_TYPE_CONTAINER => return "container",
        c.GST_STREAM_TYPE_TEXT => return "text",
        c.GST_STREAM_TYPE_METADATA => return "metadata",
        else => {},
    }
    const all = c.GST_STREAM_TYPE_AUDIO | c.GST_STREAM_TYPE_VIDEO | c.GST_STREAM_TYPE_CONTAINER | c.GST_STREAM_TYPE_TEXT;
    if (kind & ~@as(c.GstStreamType, all) != 0) {
        check.unreachableAt("../gst/gststreams.c", 600, "gst_stream_type_get_name");
        return "invalid";
    }
    var buf: [48]u8 = std.mem.zeroes([48]u8);
    const parts = [_]struct { c.GstStreamType, [:0]const u8 }{ .{ c.GST_STREAM_TYPE_CONTAINER, "+container" }, .{ c.GST_STREAM_TYPE_VIDEO, "+video" }, .{ c.GST_STREAM_TYPE_AUDIO, "+audio" }, .{ c.GST_STREAM_TYPE_TEXT, "+text" }, .{ c.GST_STREAM_TYPE_METADATA, "+metadata" } };
    for (parts) |p| if (kind & p[0] != 0) {
        _ = c.g_strlcat(&buf, p[1].ptr, buf.len);
    };
    return c.g_intern_string(@as([*c]const u8, &buf) + 1);
}
