const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const smart = @import("smartencoder.zig");
const combiner = @import("combiner.zig");
const splitter = @import("splitter.zig");

const FILE = "../gst/encoding/gstencodebasebin.c";
const DOMAIN = "gst-plugins-base-1.0";
const PROP_PROFILE = 1;
const PROP_QUEUE_BUFFERS_MAX = 2;
const PROP_QUEUE_BYTES_MAX = 3;
const PROP_QUEUE_TIME_MAX = 4;
const PROP_AUDIO_JITTER_TOLERANCE = 5;
const PROP_AVOID_REENCODING = 6;
const PROP_FLAGS = 7;
const NO_AUDIO_CONVERSION: c.guint = 1;
const NO_VIDEO_CONVERSION: c.guint = 2;
const DEFAULT_QUEUE_BUFFERS_MAX = 200;
const DEFAULT_QUEUE_BYTES_MAX = 10 * 1024 * 1024;
const DEFAULT_QUEUE_TIME_MAX: u64 = c.GST_SECOND;
const DEFAULT_AUDIO_JITTER_TOLERANCE: u64 = 20 * c.GST_MSECOND;

const Group = struct {
    ebin: *Self,
    profile: ?*c.GstEncodingProfile = null,
    ghostpad: ?*c.GstPad = null,
    identity: [*c]c.GstElement = null,
    inqueue: [*c]c.GstElement = null,
    splitter: [*c]c.GstElement = null,
    converters: [*c]c.GList = null,
    capsfilter: [*c]c.GstElement = null,
    inputfilter_caps_sid: c.gulong = 0,
    encoder: [*c]c.GstElement = null,
    fakesink: [*c]c.GstElement = null,
    combiner: [*c]c.GstElement = null,
    parser: [*c]c.GstElement = null,
    timestamper: [*c]c.GstElement = null,
    smartencoder: [*c]c.GstElement = null,
    smart_capsfilter: [*c]c.GstElement = null,
    smart_capsfilter_sid: c.gulong = 0,
    outfilter: [*c]c.GstElement = null,
    outputfilter_caps_sid: c.gulong = 0,
    formatter: [*c]c.GstElement = null,
    outqueue: [*c]c.GstElement = null,
    restriction_sid: c.gulong = 0,
};

pub const Self = extern struct {
    parent: c.GstBin,
    profile: ?*c.GstEncodingProfile,
    streams: [*c]c.GList,
    muxer: [*c]c.GstElement,
    srcpad: ?*c.GstPad,
    active: c.gboolean,
    muxers: [*c]c.GList,
    formatters: [*c]c.GList,
    encoders: [*c]c.GList,
    parsers: [*c]c.GList,
    timestampers: [*c]c.GList,
    last_pad_id: c.guint,
    raw_video_caps: [*c]c.GstCaps,
    raw_audio_caps: [*c]c.GstCaps,
    queue_buffers_max: c.guint,
    queue_bytes_max: c.guint,
    queue_time_max: u64,
    tolerance: u64,
    avoid_reencoding: c.gboolean,
    flags: c.guint,
};

pub const Class = extern struct {
    parent: c.GstBinClass,
    request_pad: ?*const fn (*Self, [*c]c.GstCaps) callconv(.c) ?*c.GstPad,
    request_profile_pad: ?*const fn (*Self, [*c]const u8) callconv(.c) ?*c.GstPad,
};

var video_t = cm.staticTemplate("video_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "ANY");
var audio_t = cm.staticTemplate("audio_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "ANY");
var private_t = cm.staticTemplate("private_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "ANY");
var raw_caps = c.GstStaticCaps{ .caps = null, .string = "video/x-raw; audio/x-raw; text/x-raw; subpicture/x-dvd; subpicture/x-pgs", ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
var once: cm.Once = .{};
var flags_once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;
var sig_request_pad: c.guint = 0;
var sig_request_profile_pad: c.guint = 0;

const flag_values = [_]c.GFlagsValue{
    .{ .value = NO_AUDIO_CONVERSION, .value_name = "Do not use audio conversion elements", .value_nick = "no-audio-conversion" },
    .{ .value = NO_VIDEO_CONVERSION, .value_name = "Do not use video conversion elements", .value_nick = "no-video-conversion" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

pub fn flagsType() c.GType {
    return flags_once.get(struct {
        fn f() c.GType {
            return c.g_flags_register_static("GstEncodeBinFlags", &flag_values);
        }
    }.f);
}

pub fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn el(p: anytype) [*c]c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn bin(s: *Self) *c.GstBin {
    return @ptrCast(s);
}

fn isA(p: anytype, t: c.GType) bool {
    return cm.isA(p, t);
}

fn fastPadLink(a: ?*c.GstPad, b: ?*c.GstPad) c.GstPadLinkReturn {
    return c.gst_pad_link_full(a, b, c.GST_PAD_LINK_CHECK_NOTHING);
}

fn fastElementLink(a: [*c]c.GstElement, b: [*c]c.GstElement) bool {
    return c.gst_element_link_pads_full(a, "src", b, "sink", c.GST_PAD_LINK_CHECK_NOTHING) != 0;
}

fn firstPad(list: [*c]c.GList) ?*c.GstPad {
    return @ptrCast(list.*.data);
}

fn clearObject(p: anytype) void {
    if (p.* != null) c.gst_object_unref(p.*);
    p.* = null;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    for ([_]*[*c]c.GList{ &s.muxers, &s.formatters, &s.encoders, &s.parsers, &s.timestampers }) |l| {
        if (l.* != null) c.gst_plugin_feature_list_free(l.*);
        l.* = null;
    }
    tearDownProfile(s);
    if (s.raw_video_caps != null) c.gst_caps_unref(s.raw_video_caps);
    s.raw_video_caps = null;
    if (s.raw_audio_caps != null) c.gst_caps_unref(s.raw_audio_caps);
    s.raw_audio_caps = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_PROFILE => _ = setProfile(s, @ptrCast(@alignCast(c.g_value_dup_object(v)))),
        PROP_QUEUE_BUFFERS_MAX => s.queue_buffers_max = c.g_value_get_uint(v),
        PROP_QUEUE_BYTES_MAX => s.queue_bytes_max = c.g_value_get_uint(v),
        PROP_QUEUE_TIME_MAX => s.queue_time_max = c.g_value_get_uint64(v),
        PROP_AUDIO_JITTER_TOLERANCE => s.tolerance = c.g_value_get_uint64(v),
        PROP_AVOID_REENCODING => {
            const was = s.avoid_reencoding;
            s.avoid_reencoding = c.g_value_get_boolean(v);
            if (s.avoid_reencoding != was and s.profile != null) _ = setProfile(s, @ptrCast(@alignCast(c.gst_object_ref(s.profile))));
        },
        PROP_FLAGS => s.flags = c.g_value_get_flags(v),
        else => cm.warnInvalid(FILE, o, id, spec, 512),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_PROFILE => c.g_value_set_object(v, s.profile),
        PROP_QUEUE_BUFFERS_MAX => c.g_value_set_uint(v, s.queue_buffers_max),
        PROP_QUEUE_BYTES_MAX => c.g_value_set_uint(v, s.queue_bytes_max),
        PROP_QUEUE_TIME_MAX => c.g_value_set_uint64(v, s.queue_time_max),
        PROP_AUDIO_JITTER_TOLERANCE => c.g_value_set_uint64(v, s.tolerance),
        PROP_AVOID_REENCODING => c.g_value_set_boolean(v, s.avoid_reencoding),
        PROP_FLAGS => c.g_value_set_flags(v, s.flags),
        else => cm.warnInvalid(FILE, o, id, spec, 546),
    }
}

fn areRawCaps(caps: [*c]const c.GstCaps) bool {
    const raw = c.gst_static_caps_get(&raw_caps);
    defer c.gst_caps_unref(raw);
    return c.gst_caps_can_intersect(caps, raw) != 0;
}

fn groupOf(l: [*c]c.GList) *Group {
    return @ptrCast(@alignCast(l.*.data));
}

fn usedCount(s: *Self, sprof: ?*c.GstEncodingProfile) c.guint {
    var n: c.guint = 0;
    var l = s.streams;
    while (l != null) : (l = l.*.next) {
        if (groupOf(l).profile == sprof) n += 1;
    }
    return n;
}

fn available(s: *Self, sprof: ?*c.GstEncodingProfile) bool {
    const presence = c.gst_encoding_profile_get_presence(sprof);
    return presence == 0 or presence > usedCount(s, sprof);
}

fn nextUnusedProfile(s: *Self, ptype_in: c.GType, name: [*c]const u8, caps: [*c]c.GstCaps, previous: ?*c.GstEncodingProfile) ?*c.GstEncodingProfile {
    var ptype = ptype_in;
    if (ptype == c.G_TYPE_NONE and caps != null) {
        if (c.gst_caps_can_intersect(s.raw_video_caps, caps) != 0) {
            ptype = c.gst_encoding_video_profile_get_type();
        } else if (c.gst_caps_can_intersect(s.raw_audio_caps, caps) != 0) ptype = c.gst_encoding_audio_profile_get_type();
    }
    if (!isA(s.profile, c.gst_encoding_container_profile_get_type())) return null;
    const profiles = c.gst_encoding_container_profile_get_profiles(@ptrCast(s.profile));
    if (name != null) {
        var l = profiles;
        while (l != null) : (l = l.*.next) {
            const sprof: ?*c.GstEncodingProfile = @ptrCast(l.*.data);
            const pname = c.gst_encoding_profile_get_name(sprof);
            if (pname != null and c.strcmp(name, pname) == 0) {
                if (c.gst_encoding_profile_is_enabled(sprof) == 0) return null;
                if (available(s, sprof)) return sprof;
                return null;
            }
        }
    }
    var l = profiles;
    while (l != null) : (l = l.*.next) {
        const sprof: ?*c.GstEncodingProfile = @ptrCast(l.*.data);
        if (cm.typeOf(sprof) == ptype) {
            if (c.gst_encoding_profile_is_enabled(sprof) != 0 and available(s, sprof) and sprof != previous) return sprof;
        } else if (caps != null and ptype == c.G_TYPE_NONE) {
            const out = c.gst_encoding_profile_get_input_caps(sprof);
            const ok = c.gst_caps_can_intersect(out, caps) != 0;
            c.gst_caps_unref(out);
            if (ok and sprof != previous) return sprof;
        }
    }
    return null;
}

fn requestPadForStream(s: *Self, ptype: c.GType, name: [*c]const u8, caps: [*c]c.GstCaps) ?*c.GstPad {
    var group: ?*Group = null;
    var missing: [*c]c.GList = null;
    var sprof: ?*c.GstEncodingProfile = null;
    while (group == null) {
        var not_found = false;
        sprof = nextUnusedProfile(s, ptype, name, caps, sprof);
        if (sprof == null) {
            c.g_list_free(missing);
            return null;
        }
        group = createStreamGroup(s, sprof, name, caps, &not_found);
        if (group != null) break;
        if (not_found) {
            missing = c.g_list_prepend(missing, sprof);
            if (name != null) break;
        } else break;
    }
    if (group == null) {
        var l = missing;
        while (l != null) : (l = l.*.next) postMissingPlugin(s, @ptrCast(l.*.data));
        c.g_list_free(missing);
        return null;
    }
    c.g_list_free(missing);
    return group.?.ghostpad;
}

fn requestNewPad(element: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, name: [*c]const u8, caps: [*c]const c.GstCaps) callconv(.c) ?*c.GstPad {
    const s = me(element);
    var res: ?*c.GstPad = null;
    if (caps != null or name != null) res = requestPadForStream(s, c.G_TYPE_NONE, name, @constCast(caps));
    if (res == null) {
        var ptype: c.GType = c.G_TYPE_NONE;
        if (c.strcmp(templ.*.name_template, "video_%u") == 0) {
            ptype = c.gst_encoding_video_profile_get_type();
        } else if (c.strcmp(templ.*.name_template, "audio_%u") == 0) ptype = c.gst_encoding_audio_profile_get_type();
        res = requestPadForStream(s, ptype, name, null);
    }
    return res;
}

fn requestPadSignal(s: *Self, caps: [*c]c.GstCaps) callconv(.c) ?*c.GstPad {
    const p = requestPadForStream(s, c.G_TYPE_NONE, null, caps);
    return if (p != null) @ptrCast(c.gst_object_ref(p)) else null;
}

fn requestProfilePadSignal(s: *Self, name: [*c]const u8) callconv(.c) ?*c.GstPad {
    const p = requestPadForStream(s, c.G_TYPE_NONE, name, null);
    return if (p != null) @ptrCast(c.gst_object_ref(p)) else null;
}

fn releasePad(element: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const s = me(element);
    var l = s.streams;
    while (l != null) : (l = l.*.next) {
        if (groupOf(l).ghostpad == pad) return groupRemove(s, groupOf(l));
    }
}

fn padTemplateCaps(t: [*c]c.GstPadTemplate) [*c]c.GstCaps {
    return t.*.caps;
}

fn compatibleProcessor(all: [*c]c.GList, sprof: ?*c.GstEncodingProfile, encoder: [*c]c.GstElement) [*c]c.GstElement {
    var encoding_format = c.gst_encoding_profile_get_format(sprof);
    if (c.gst_caps_is_empty(encoding_format) != 0) return null;
    defer c.gst_caps_unref(encoding_format);
    const media = c.gst_structure_get_name(c.gst_caps_get_structure(encoding_format, 0));
    var format: [*c]c.GstCaps = null;
    if (encoder != null) {
        const t = c.gst_element_get_pad_template(encoder, "src");
        if (t != null) format = c.gst_pad_template_get_caps(t);
    }
    if (format == null or c.gst_caps_is_any(format) != 0) {
        if (format != null) c.gst_caps_unref(format);
        format = c.gst_caps_ref(encoding_format);
    }
    defer c.gst_caps_unref(format);
    const first = c.gst_element_factory_list_filter(all, format, c.GST_PAD_SRC, 0);
    const processors = c.gst_element_factory_list_filter(first, format, c.GST_PAD_SINK, 0);
    c.gst_plugin_feature_list_free(first);
    if (processors == null) return null;
    defer c.gst_plugin_feature_list_free(processors);
    var l = processors;
    while (l != null) : (l = l.*.next) {
        const processor = c.gst_element_factory_create(@ptrCast(@alignCast(l.*.data)), null);
        const t = c.gst_element_get_pad_template(processor, "sink");
        const pcaps = c.gst_pad_template_get_caps(t);
        var ok = false;
        if (c.gst_caps_is_any(pcaps) != 0) {
            ok = true;
        } else if (c.gst_caps_is_empty(pcaps) == 0) {
            ok = c.strcmp(media, c.gst_structure_get_name(c.gst_caps_get_structure(pcaps, 0))) == 0;
        }
        c.gst_caps_unref(pcaps);
        if (ok) return processor;
        c.gst_object_unref(processor);
    }
    encoding_format = encoding_format;
    return null;
}

fn setOneProperty(id: [*c]const c.GstIdStr, v: [*c]const c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    c.g_object_set_property(@ptrCast(@alignCast(data)), c.gst_id_str_as_str(id), v);
    return 1;
}

fn elementPropertiesFromProfile(profile: ?*c.GstEncodingProfile, _: ?*c.GParamSpec, element: [*c]c.GstElement) callconv(.c) void {
    const props = c.gst_encoding_profile_get_element_properties(profile);
    if (props == null) return;
    defer c.gst_structure_free(props);
    if (c.gst_structure_has_name(props, "element-properties-map") == 0) {
        _ = c.gst_structure_foreach_id_str(props, setOneProperty, element);
        return;
    }
    const factory = c.gst_element_get_factory(element);
    if (factory == null) return;
    const v = c.gst_structure_get_value(props, "map");
    var i: c.guint = 0;
    while (i < c.gst_value_list_get_size(v)) : (i += 1) {
        const item = c.gst_value_list_get_value(v, i);
        if (item.*.g_type != c.gst_structure_get_type()) {
            c.g_log(null, c.G_LOG_LEVEL_WARNING, "Invalid value type %s in the property map (expected GstStructure)", c.g_type_name(item.*.g_type));
            continue;
        }
        const tmp = c.gst_value_get_structure(item);
        if (c.gst_structure_has_name(tmp, cm.obj(factory).name) == 0) continue;
        _ = c.gst_structure_foreach_id_str(tmp, setOneProperty, element);
        return;
    }
}

fn createWithPreset(factory: ?*c.GstElementFactory, profile: ?*c.GstEncodingProfile, name: [*c]const u8) [*c]c.GstElement {
    const preset_name = c.gst_encoding_profile_get_preset_name(profile);
    const preset = c.gst_encoding_profile_get_preset(profile);
    const fname = cm.obj(factory).name;
    if (preset_name != null and c.g_strcmp0(fname, preset_name) != 0) return null;
    var res = c.gst_element_factory_create(factory, name);
    if (preset != null and isA(res, c.gst_preset_get_type())) {
        if (preset_name == null or c.g_strcmp0(fname, preset_name) == 0) {
            if (c.gst_preset_load_preset(@ptrCast(res), preset) == 0) {
                c.gst_object_unref(res);
                res = null;
            }
        }
    }
    if (res != null) {
        elementPropertiesFromProfile(profile, null, res);
        _ = c.g_signal_connect_data(profile, "notify::element-properties", @ptrCast(&elementPropertiesFromProfile), res, null, 0);
    }
    return res;
}

fn getEncoder(s: *Self, sprof: ?*c.GstEncodingProfile) [*c]c.GstElement {
    const format = c.gst_encoding_profile_get_format(sprof);
    defer if (format != null) c.gst_caps_unref(format);
    if (areRawCaps(format)) return c.gst_element_factory_make("identity", null);
    var encoders = c.gst_element_factory_list_filter(s.encoders, format, c.GST_PAD_SRC, 0);
    if (encoders == null and sprof == s.profile) encoders = c.gst_element_factory_list_filter(s.muxers, format, c.GST_PAD_SRC, 0);
    if (encoders == null) return null;
    defer c.gst_plugin_feature_list_free(encoders);
    var l = encoders;
    while (l != null) : (l = l.*.next) {
        const e = createWithPreset(@ptrCast(@alignCast(l.*.data)), sprof, null);
        if (e != null) return e;
    }
    return null;
}

fn localRequestPad(element: [*c]c.GstElement, name: [*c]const u8) ?*c.GstPad {
    const k: *c.GstElementClass = @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(element)).g_class));
    const p = if (k.request_new_pad) |f| f(element, null, name, null) else null;
    if (p != null) _ = c.gst_object_ref(p);
    return p;
}

fn padFromTemplate(element: [*c]c.GstElement, t: [*c]c.GstPadTemplate) ?*c.GstPad {
    switch (t.*.presence) {
        c.GST_PAD_ALWAYS, c.GST_PAD_SOMETIMES => {
            const p = c.gst_element_get_static_pad(element, t.*.name_template);
            if (p == null and t.*.presence == c.GST_PAD_ALWAYS) c.g_log(null, c.G_LOG_LEVEL_WARNING, "Element %s has an ALWAYS template %s, but no pad of the same name", cm.obj(element).name, t.*.name_template);
            return p;
        },
        else => return c.gst_element_request_pad(element, t, null, null),
    }
}

fn muxerSinkPad(s: *Self, sprof: ?*c.GstEncodingProfile, sinkcaps: [*c]c.GstCaps) ?*c.GstPad {
    var compatible: [*c]c.GList = null;
    var l = c.gst_element_get_pad_template_list(s.muxer);
    while (l != null) : (l = l.*.next) {
        const t: [*c]c.GstPadTemplate = @ptrCast(@alignCast(l.*.data));
        if (t.*.direction == c.GST_PAD_SRC) continue;
        if (c.gst_caps_can_intersect(padTemplateCaps(t), sinkcaps) == 0) continue;
        if (c.gst_caps_is_any(padTemplateCaps(t)) == 0) {
            compatible = c.g_list_append(compatible, t);
            continue;
        }
        var type_name: [*c]const u8 = undefined;
        var other: [*c]const u8 = undefined;
        if (isA(sprof, c.gst_encoding_video_profile_get_type())) {
            type_name = "video";
            other = "audio";
        } else if (isA(sprof, c.gst_encoding_audio_profile_get_type())) {
            type_name = "audio";
            other = "video";
        } else {
            compatible = c.g_list_prepend(compatible, t);
            continue;
        }
        if (c.strstr(t.*.name_template, type_name) == t.*.name_template) {
            compatible = c.g_list_prepend(compatible, t);
        } else if (c.strstr(t.*.name_template, other) == null) compatible = c.g_list_append(compatible, t);
    }
    if (compatible == null) return null;
    defer c.g_list_free(compatible);
    var it = compatible;
    while (it != null) : (it = it.*.next) {
        const p = padFromTemplate(s.muxer, @ptrCast(@alignCast(it.*.data)));
        if (p != null) return p;
    }
    return null;
}

fn hasClass(element: [*c]c.GstElement, name: [*c]const u8) bool {
    const k: [*c]c.GstElementClass = @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(element)).g_class));
    const v = c.gst_element_class_get_metadata(k, c.GST_ELEMENT_METADATA_KLASS);
    return v != null and c.strstr(v, name) != null;
}

fn restrictionChanged(profile: ?*c.GstEncodingProfile, _: ?*c.GParamSpec, g: *Group) callconv(.c) void {
    const r = c.gst_encoding_profile_get_restriction(profile);
    c.g_object_set(g.capsfilter, "caps", r, @as(?*anyopaque, null));
}

fn forceFormat(pad: ?*c.GstPad, _: ?*c.GParamSpec, g: *Group) callconv(.c) void {
    const par: [*c]c.GstElement = @ptrCast(@alignCast(c.gst_object_get_parent(@ptrCast(@alignCast(pad)))));
    if (par == null) return;
    defer c.gst_object_unref(par);
    var caps: [*c]c.GstCaps = null;
    c.g_object_get(pad, "caps", &caps, @as(?*anyopaque, null));
    caps = c.gst_caps_copy(caps);
    defer c.gst_caps_unref(caps);
    if (par == g.outfilter or par == g.smart_capsfilter) {
        if (g.smart_capsfilter != null) {
            const st = c.gst_caps_get_structure(caps, 0);
            if (c.gst_structure_has_name(st, "video/x-h264") != 0 and c.gst_structure_has_field(st, "stream_format") == 0) {
                c.gst_structure_set(st, "stream-format", c.G_TYPE_STRING, "avc3", @as(?*anyopaque, null));
                c.gst_structure_remove_fields(st, "codec_data", "profile", "level", @as(?*anyopaque, null));
            } else if (c.gst_structure_has_name(st, "video/x-h265") != 0 and c.gst_structure_has_field(st, "stream_format") == 0) {
                c.gst_structure_set(st, "stream-format", c.G_TYPE_STRING, "hev1", @as(?*anyopaque, null));
                c.gst_structure_remove_fields(st, "codec_data", "tier", "profile", "level", @as(?*anyopaque, null));
            }
            if (c.gst_structure_has_name(st, "video/x-vp8") != 0 or c.gst_structure_has_name(st, "video/x-vp9") != 0) c.gst_structure_remove_field(st, "streamheader");
            c.g_object_set(g.smart_capsfilter, "caps", caps, @as(?*anyopaque, null));
            c.g_signal_handler_disconnect(firstPad(g.smart_capsfilter.*.sinkpads), g.smart_capsfilter_sid);
            g.smart_capsfilter_sid = 0;
        }
        if (g.outfilter != null) {
            const tmp = c.gst_caps_copy(caps);
            c.g_object_set(g.outfilter, "caps", tmp, @as(?*anyopaque, null));
            c.gst_caps_unref(tmp);
            c.g_signal_handler_disconnect(firstPad(g.outfilter.*.sinkpads), g.outputfilter_caps_sid);
            g.outputfilter_caps_sid = 0;
        }
    } else if (par == g.capsfilter) {
        c.g_object_set(par, "caps", caps, @as(?*anyopaque, null));
        c.g_signal_handler_disconnect(pad, g.inputfilter_caps_sid);
    } else unreachable;
}

fn watchCaps(pad: ?*c.GstPad, g: *Group) c.gulong {
    return c.g_signal_connect_data(pad, "notify::caps", @ptrCast(&forceFormat), g, null, 0);
}

fn setGroupCapsFormat(g: *Group, prof: ?*c.GstEncodingProfile, format: [*c]c.GstCaps) void {
    c.g_object_set(g.outfilter, "caps", format, @as(?*anyopaque, null));
    if (c.gst_encoding_profile_get_allow_dynamic_output(prof) == 0 and g.outputfilter_caps_sid == 0) g.outputfilter_caps_sid = watchCaps(firstPad(g.outfilter.*.sinkpads), g);
}

fn postMissingPlugin(s: *Self, prof: ?*c.GstEncodingProfile) void {
    const format = c.gst_encoding_profile_get_format(prof);
    _ = c.gst_element_post_message(el(s), c.gst_missing_encoder_message_new(el(s), format));
    const text = c.gst_caps_to_string(format);
    cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, c.g_strdup_printf("Couldn't create encoder for format %s", text), null, FILE, "_post_missing_plugin_message", 1328);
    c.g_free(text);
    c.gst_caps_unref(format);
}

fn missingPluginProbe(_: ?*c.GstPad, _: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const g: *Group = @ptrCast(@alignCast(data));
    postMissingPlugin(g.ebin, g.profile);
    return c.GST_PAD_PROBE_OK;
}

fn setupSmartEncoder(s: *Self, sprof: ?*c.GstEncodingProfile, g: *Group) [*c]c.GstElement {
    var encoder: [*c]c.GstElement = null;
    var parser: [*c]c.GstElement = null;
    var reencoder: [*c]c.GstElement = null;
    var convert: [*c]c.GstElement = null;
    var se: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(smart.getType(), @as([*c]const u8, null))));
    const srcpad = c.gst_element_get_static_pad(se, "src");
    const format = c.gst_caps_make_writable(c.gst_encoding_profile_get_format(sprof));
    const tmpcaps = c.gst_pad_query_caps(srcpad, null);
    const native = s.flags & NO_VIDEO_CONVERSION != 0;
    const st = c.gst_caps_get_structure(format, 0);
    defer {
        c.gst_caps_unref(tmpcaps);
        c.gst_caps_unref(format);
        c.gst_object_unref(srcpad);
        clearObject(&encoder);
        clearObject(&parser);
        clearObject(&convert);
    }
    ok: {
        if (c.gst_caps_can_intersect(tmpcaps, format) == 0) break :ok;
        encoder = getEncoder(s, sprof);
        if (encoder == null) break :ok;
        var sinkelement = encoder;
        parser = compatibleProcessor(s.parsers, sprof, encoder);
        g.smart_capsfilter = c.gst_element_factory_make("capsfilter", null);
        reencoder = c.gst_bin_new(null);
        if (c.gst_structure_has_name(st, "video/x-h264") != 0) {
            c.gst_structure_set(st, "stream-format", c.G_TYPE_STRING, "avc3", @as(?*anyopaque, null));
            c.gst_structure_remove_fields(st, "codec_data", "profile", "level", @as(?*anyopaque, null));
        } else if (c.gst_structure_has_name(st, "video/x-h265") != 0) {
            c.gst_structure_set(st, "stream-format", c.G_TYPE_STRING, "hev1", @as(?*anyopaque, null));
            c.gst_structure_remove_fields(st, "codec_data", "tier", "profile", "level", @as(?*anyopaque, null));
        }
        if (c.gst_structure_has_name(st, "video/x-vp8") != 0 or c.gst_structure_has_name(st, "video/x-vp9") != 0) c.gst_structure_remove_field(st, "streamheader");
        c.g_object_set(g.smart_capsfilter, "caps", format, @as(?*anyopaque, null));
        const rb: *c.GstBin = @ptrCast(@alignCast(reencoder));
        _ = c.gst_bin_add(rb, @ptrCast(@alignCast(c.gst_object_ref(encoder))));
        _ = c.gst_bin_add(rb, @ptrCast(@alignCast(c.gst_object_ref(if (parser != null) parser else g.smart_capsfilter))));
        if (parser != null) _ = c.gst_bin_add(rb, @ptrCast(@alignCast(c.gst_object_ref(g.smart_capsfilter))));
        if (!native) {
            convert = c.gst_element_factory_make("videoconvert", null);
            if (convert == null) break :ok;
            _ = c.gst_bin_add(rb, @ptrCast(@alignCast(c.gst_object_ref(convert))));
            if (c.gst_element_link(convert, sinkelement) == 0) break :ok;
            sinkelement = convert;
        }
        const linked = if (parser != null) c.gst_element_link_many(encoder, parser, g.smart_capsfilter, @as(?*anyopaque, null)) else c.gst_element_link_many(encoder, g.smart_capsfilter, @as(?*anyopaque, null));
        if (linked == 0) break :ok;
        if (c.gst_element_add_pad(reencoder, c.gst_ghost_pad_new("sink", firstPad(sinkelement.*.sinkpads))) == 0) break :ok;
        if (c.gst_element_add_pad(reencoder, c.gst_ghost_pad_new("src", firstPad(g.smart_capsfilter.*.srcpads))) == 0) break :ok;
        if (c.gst_encoding_profile_get_allow_dynamic_output(sprof) == 0 and g.smart_capsfilter_sid == 0) g.smart_capsfilter_sid = watchCaps(firstPad(g.smart_capsfilter.*.sinkpads), g);
        if (!smart.setEncoder(smart.me(se), format, reencoder)) {
            reencoder = null;
            break :ok;
        }
        return se;
    }
    clearObject(&se);
    clearObject(&reencoder);
    return se;
}

fn createSrcPad(s: *Self, target: ?*c.GstPad) bool {
    const t = c.gst_element_get_pad_template(el(s), "src_%u");
    cm.lock(s);
    const name = c.g_strdup_printf("src_%u", el(s).*.numsrcpads);
    cm.unlock(s);
    const p = c.gst_ghost_pad_new_from_template(name, target, t);
    c.g_free(name);
    if (p == null) return false;
    _ = c.gst_element_add_pad(el(s), p);
    return true;
}

fn addSynced(s: *Self, tosync: *[*c]c.GList, e: [*c]c.GstElement) void {
    _ = c.gst_bin_add(bin(s), e);
    tosync.* = c.g_list_append(tosync.*, e);
}

fn missingElement(s: *Self, name: [*c]const u8) void {
    _ = c.gst_element_post_message(el(s), c.gst_missing_element_message_new(el(s), name));
    cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, c.g_strdup_printf(cm.tr(DOMAIN, "Missing element '%s' - check your GStreamer installation."), name), null, FILE, "_create_stream_group", 1997);
}

fn createStreamGroup(s: *Self, sprof: ?*c.GstEncodingProfile, sinkpadname: [*c]const u8, _: [*c]c.GstCaps, encoder_not_found: ?*bool) ?*Group {
    const format = c.gst_encoding_profile_get_format(sprof);
    const restriction = c.gst_encoding_profile_get_restriction(sprof);
    const g = std.heap.c_allocator.create(Group) catch unreachable;
    g.* = .{ .ebin = s, .profile = @ptrCast(@alignCast(c.gst_object_ref(sprof))) };
    var tosync: [*c]c.GList = null;
    var sinkpad: ?*c.GstPad = null;
    var srcpad: ?*c.GstPad = null;
    var last: [*c]c.GstElement = null;
    defer {
        if (format != null) c.gst_caps_unref(format);
        if (restriction != null) c.gst_caps_unref(restriction);
        c.g_list_free(tosync);
    }
    built: {
        g.encoder = getEncoder(s, sprof);
        if (g.encoder == null and (c.gst_encoding_profile_get_preset(g.profile) != null or c.gst_encoding_profile_get_preset_name(g.profile) != null)) {
            if (encoder_not_found) |p| p.* = true else postMissingPlugin(s, sprof);
            break :built;
        }
        var muxerpad: ?*c.GstPad = null;
        if (s.muxer != null) {
            muxerpad = muxerSinkPad(s, sprof, format);
            if (muxerpad == null) break :built;
        }
        g.outqueue = c.gst_element_factory_make("queue", null);
        last = g.outqueue;
        c.g_object_set(g.outqueue, "max-size-buffers", @as(c.guint, 0), "max-size-bytes", @as(c.guint, 0), "max-size-time", @as(u64, 3 * c.GST_SECOND), "silent", @as(c.gboolean, 1), @as(?*anyopaque, null));
        addSynced(s, &tosync, g.outqueue);
        srcpad = c.gst_element_get_static_pad(g.outqueue, "src");
        if (muxerpad != null) {
            if (fastPadLink(srcpad, muxerpad) != c.GST_PAD_LINK_OK) break :built;
            c.gst_object_unref(muxerpad);
        } else if (s.srcpad != null) {
            _ = c.gst_ghost_pad_set_target(@ptrCast(@alignCast(s.srcpad)), srcpad);
        } else if (!createSrcPad(s, srcpad)) {
            c.gst_object_unref(srcpad);
            srcpad = null;
            break :built;
        }
        c.gst_object_unref(srcpad);
        srcpad = null;
        if (s.muxer == null or (!isA(s.muxer, c.gst_tag_setter_get_type()) and !hasClass(s.muxer, "Formatter"))) {
            g.formatter = getFormatter(s, sprof);
            if (g.formatter != null) {
                addSynced(s, &tosync, g.formatter);
                if (!fastElementLink(g.formatter, last)) break :built;
                last = g.formatter;
            }
        }
        g.outfilter = c.gst_element_factory_make("capsfilter", null);
        setGroupCapsFormat(g, sprof, format);
        addSynced(s, &tosync, g.outfilter);
        if (!fastElementLink(g.outfilter, last)) break :built;
        last = g.outfilter;
        g.parser = compatibleProcessor(s.parsers, g.profile, g.encoder);
        if (g.parser != null) {
            addSynced(s, &tosync, g.parser);
            if (c.gst_element_link(g.parser, last) == 0) break :built;
            last = g.parser;
        }
        g.timestamper = compatibleProcessor(s.timestampers, sprof, null);
        if (g.timestamper != null) {
            addSynced(s, &tosync, g.timestamper);
            if (c.gst_element_link(g.timestamper, last) == 0) break :built;
            last = g.timestamper;
            if (g.parser != null) {
                const p1 = c.gst_element_factory_make(cm.obj(c.gst_element_get_factory(g.parser)).name, null);
                addSynced(s, &tosync, p1);
                if (c.gst_element_link(p1, last) == 0) break :built;
                last = p1;
            }
        }
        g.combiner = @ptrCast(@alignCast(c.g_object_new(combiner.getType(), @as([*c]const u8, null))));
        addSynced(s, &tosync, g.combiner);
        if (!fastElementLink(g.combiner, last)) break :built;
        g.splitter = @ptrCast(@alignCast(c.g_object_new(splitter.getType(), @as([*c]const u8, null))));
        addSynced(s, &tosync, g.splitter);
        if (c.gst_encoding_profile_get_single_segment(sprof) != 0 and s.avoid_reencoding == 0) {
            g.identity = c.gst_element_factory_make("identity", null);
            c.g_object_set(g.identity, "single-segment", @as(c.gboolean, 1), @as(?*anyopaque, null));
            addSynced(s, &tosync, g.identity);
        }
        g.inqueue = c.gst_element_factory_make("queue", null);
        c.g_object_set(g.inqueue, "max-size-buffers", s.queue_buffers_max, "max-size-bytes", s.queue_bytes_max, "max-size-time", s.queue_time_max, "silent", @as(c.gboolean, 1), @as(?*anyopaque, null));
        addSynced(s, &tosync, g.inqueue);
        sinkpad = c.gst_element_get_static_pad(if (g.identity != null) g.identity else g.inqueue, "sink");
        if (sinkpadname == null) {
            const pname = c.g_strdup_printf("%s_%u", c.gst_encoding_profile_get_type_nick(sprof), s.last_pad_id);
            s.last_pad_id += 1;
            g.ghostpad = c.gst_ghost_pad_new(pname, sinkpad);
            c.g_free(pname);
        } else g.ghostpad = c.gst_ghost_pad_new(sinkpadname, sinkpad);
        c.gst_object_unref(sinkpad);
        sinkpad = null;
        if (g.identity != null and !fastElementLink(g.identity, g.inqueue)) break :built;
        if (!fastElementLink(g.inqueue, g.splitter)) break :built;
        sinkpad = localRequestPad(g.combiner, "passthroughsink");
        if (sinkpad == null) break :built;
        if (s.avoid_reencoding != 0) {
            g.smartencoder = setupSmartEncoder(s, sprof, g);
            if (g.smartencoder != null) {
                _ = c.gst_bin_add(bin(s), g.smartencoder);
                srcpad = c.gst_element_get_static_pad(g.smartencoder, "src");
                _ = fastPadLink(srcpad, sinkpad);
                clearObject(&srcpad);
                clearObject(&sinkpad);
                tosync = c.g_list_append(tosync, g.smartencoder);
                sinkpad = c.gst_element_get_static_pad(g.smartencoder, "sink");
            }
        }
        srcpad = localRequestPad(g.splitter, "passthroughsrc");
        if (srcpad == null) break :built;
        if (fastPadLink(srcpad, sinkpad) != c.GST_PAD_LINK_OK) break :built;
        clearObject(&sinkpad);
        clearObject(&srcpad);
        if (g.encoder != null) {
            addSynced(s, &tosync, g.encoder);
            sinkpad = localRequestPad(g.combiner, "encodingsink");
            if (sinkpad == null) break :built;
            srcpad = c.gst_element_get_static_pad(g.encoder, "src");
            if (fastPadLink(srcpad, sinkpad) != c.GST_PAD_LINK_OK) break :built;
            clearObject(&sinkpad);
            clearObject(&srcpad);
        }
        g.capsfilter = c.gst_element_factory_make("capsfilter", null);
        last = g.capsfilter;
        if (restriction != null and c.gst_caps_is_any(restriction) == 0) c.g_object_set(g.capsfilter, "caps", restriction, @as(?*anyopaque, null));
        if (c.gst_encoding_profile_get_allow_dynamic_output(sprof) == 0 and g.inputfilter_caps_sid == 0) g.inputfilter_caps_sid = watchCaps(firstPad(g.capsfilter.*.sinkpads), g);
        addSynced(s, &tosync, g.capsfilter);
        var encoder: [*c]c.GstElement = g.encoder;
        if (g.encoder == null) {
            g.fakesink = c.gst_element_factory_make("fakesink", null);
            c.g_object_set(g.fakesink, "async", @as(c.gboolean, 0), @as(?*anyopaque, null));
            addSynced(s, &tosync, g.fakesink);
            encoder = g.fakesink;
            const fp = c.gst_element_get_static_pad(g.fakesink, "sink");
            _ = c.gst_pad_add_probe(fp, c.GST_PAD_PROBE_TYPE_BUFFER, missingPluginProbe, g, null);
            c.gst_object_unref(fp);
        }
        _ = fastElementLink(g.capsfilter, encoder);
        g.restriction_sid = c.g_signal_connect_data(sprof, "notify::restriction-caps", @ptrCast(&restrictionChanged), g, null, 0);
        if (isA(sprof, c.gst_encoding_video_profile_get_type())) {
            const native = s.flags & NO_VIDEO_CONVERSION != 0;
            var cspace: [*c]c.GstElement = null;
            var cspace2: [*c]c.GstElement = null;
            if (!native) {
                cspace = c.gst_element_factory_make("videoconvert", null);
                const scale = c.gst_element_factory_make("videoscale", null);
                if (scale == null) {
                    missingElement(s, "videoscale");
                    break :built;
                }
                c.g_object_set(scale, "method", @as(c.gint, 2), "add-borders", @as(c.gboolean, 1), @as(?*anyopaque, null));
                cspace2 = c.gst_element_factory_make("videoconvert", null);
                if (cspace == null or cspace2 == null) {
                    missingElement(s, "videoconvert");
                    break :built;
                }
                for ([_][*c]c.GstElement{ cspace, scale, cspace2 }) |e| addSynced(s, &tosync, e);
                for ([_][*c]c.GstElement{ cspace, scale, cspace2 }) |e| g.converters = c.g_list_prepend(g.converters, e);
                if (!fastElementLink(cspace, scale) or !fastElementLink(scale, cspace2)) break :built;
            }
            if (c.gst_encoding_video_profile_get_variableframerate(@ptrCast(sprof)) == 0) {
                const vrate = c.gst_element_factory_make("videorate", null);
                if (vrate == null) {
                    missingElement(s, "videorate");
                    break :built;
                }
                c.g_object_set(vrate, "skip-to-first", @as(c.gboolean, 1), @as(?*anyopaque, null));
                _ = c.gst_bin_add(bin(s), vrate);
                tosync = c.g_list_prepend(tosync, vrate);
                g.converters = c.g_list_prepend(g.converters, vrate);
                if ((!native and !fastElementLink(cspace2, vrate)) or !fastElementLink(vrate, last)) break :built;
                last = if (!native) cspace else vrate;
            } else if (!native) {
                if (!fastElementLink(cspace2, last)) break :built;
                last = cspace;
            }
        } else if (isA(sprof, c.gst_encoding_audio_profile_get_type()) and s.flags & NO_AUDIO_CONVERSION == 0) {
            const arate = c.gst_element_factory_make("audiorate", null);
            if (arate == null) {
                missingElement(s, "audiorate");
                break :built;
            }
            c.g_object_set(arate, "tolerance", s.tolerance, @as(?*anyopaque, null));
            c.g_object_set(arate, "skip-to-first", @as(c.gboolean, 1), @as(?*anyopaque, null));
            const aconv = c.gst_element_factory_make("audioconvert", null);
            const aconv2 = c.gst_element_factory_make("audioconvert", null);
            const ares = c.gst_element_factory_make("audioresample", null);
            if (aconv == null or aconv2 == null) {
                missingElement(s, "audioconvert");
                break :built;
            }
            if (ares == null) {
                missingElement(s, "audioresample");
                break :built;
            }
            for ([_][*c]c.GstElement{ arate, aconv, ares, aconv2 }) |e| addSynced(s, &tosync, e);
            if (!fastElementLink(arate, aconv) or !fastElementLink(aconv, ares) or !fastElementLink(ares, aconv2) or !fastElementLink(aconv2, last)) break :built;
            for ([_][*c]c.GstElement{ arate, aconv, ares, aconv2 }) |e| g.converters = c.g_list_prepend(g.converters, e);
            last = arate;
        }
        clearObject(&sinkpad);
        clearObject(&srcpad);
        sinkpad = c.gst_element_get_static_pad(last, "sink");
        srcpad = localRequestPad(g.splitter, "encodingsrc");
        if (srcpad == null) break :built;
        if (fastPadLink(srcpad, sinkpad) != c.GST_PAD_LINK_OK) break :built;
        clearObject(&sinkpad);
        clearObject(&srcpad);
        var l = tosync;
        while (l != null) : (l = l.*.next) _ = c.gst_element_sync_state_with_parent(@ptrCast(@alignCast(l.*.data)));
        _ = c.gst_pad_set_active(g.ghostpad, 1);
        _ = c.gst_element_add_pad(el(s), g.ghostpad);
        s.streams = c.g_list_prepend(s.streams, g);
        return g;
    }
    clearObject(&sinkpad);
    clearObject(&srcpad);
    groupFree(s, g);
    return null;
}

fn capsMatchField(id: [*c]const c.GstIdStr, v: [*c]const c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const other = c.gst_structure_id_str_get_value(@ptrCast(@alignCast(data)), id);
    if (other == null) return 0;
    return @intFromBool(c.gst_value_compare(v, other) == c.GST_VALUE_EQUAL);
}

fn capsMatch(a: [*c]const c.GstCaps, b: [*c]const c.GstCaps) bool {
    for (0..c.gst_caps_get_size(a)) |i| {
        const sa = c.gst_caps_get_structure(a, @intCast(i));
        for (0..c.gst_caps_get_size(b)) |j| {
            if (c.gst_structure_foreach_id_str(sa, capsMatchField, c.gst_caps_get_structure(b, @intCast(j))) != 0) return true;
        }
    }
    return false;
}

fn factoryHandles(factory: ?*c.GstElementFactory, caps: [*c]const c.GstCaps, dir: c.GstPadDirection, exact: bool) bool {
    var l = c.gst_element_factory_get_static_pad_templates(factory);
    while (l != null) : (l = l.*.next) {
        const t: *c.GstStaticPadTemplate = @ptrCast(@alignCast(l.*.data));
        if (t.direction != dir) continue;
        const tmp = c.gst_static_caps_get(&t.static_caps);
        defer c.gst_caps_unref(tmp);
        if ((exact and capsMatch(caps, tmp)) or (!exact and c.gst_caps_can_intersect(tmp, caps) != 0)) return true;
    }
    return false;
}

fn getFormatter(s: *Self, sprof: ?*c.GstEncodingProfile) [*c]c.GstElement {
    const format = c.gst_encoding_profile_get_format(sprof);
    defer if (format != null) c.gst_caps_unref(format);
    const formatters = c.gst_element_factory_list_filter(s.formatters, format, c.GST_PAD_SRC, 0);
    if (formatters == null) return null;
    defer c.gst_plugin_feature_list_free(formatters);
    var l = formatters;
    while (l != null) : (l = l.*.next) {
        const f = createWithPreset(@ptrCast(@alignCast(l.*.data)), sprof, null);
        if (f != null) return f;
    }
    return null;
}

fn compareElements(a: c.gconstpointer, b: c.gconstpointer, data: c.gpointer) callconv(.c) c.gint {
    const caps: [*c]c.GstCaps = @ptrCast(@alignCast(data));
    const fa: ?*c.GstElementFactory = @ptrCast(@constCast(a));
    const fb: ?*c.GstElementFactory = @ptrCast(@constCast(b));
    const ea = factoryHandles(fa, caps, c.GST_PAD_SRC, true);
    const eb = factoryHandles(fb, caps, c.GST_PAD_SRC, true);
    if (ea == eb) return @as(c.gint, @bitCast(c.gst_plugin_feature_get_rank(@ptrCast(fb)))) - @as(c.gint, @bitCast(c.gst_plugin_feature_get_rank(@ptrCast(fa))));
    return if (ea) -1 else 1;
}

fn getMuxer(s: *Self) [*c]c.GstElement {
    const format = c.gst_encoding_profile_get_format(s.profile);
    defer if (format != null) c.gst_caps_unref(format);
    const preset_name = c.gst_encoding_profile_get_preset_name(s.profile);
    var muxers: [*c]c.GList = null;
    if (preset_name != null) {
        const f = c.gst_registry_find_feature(c.gst_registry_get(), preset_name, c.gst_element_factory_get_type());
        if (f != null) muxers = c.g_list_append(muxers, f);
    } else muxers = c.gst_element_factory_list_filter(s.muxers, format, c.GST_PAD_SRC, 1);
    var formatters = c.gst_element_factory_list_filter(s.formatters, format, c.GST_PAD_SRC, 1);
    muxers = c.g_list_sort_with_data(muxers, compareElements, format);
    formatters = c.g_list_sort_with_data(formatters, compareElements, format);
    muxers = c.g_list_concat(muxers, formatters);
    if (muxers == null) return null;
    defer c.gst_plugin_feature_list_free(muxers);
    var l = muxers;
    while (l != null) : (l = l.*.next) {
        const factory: ?*c.GstElementFactory = @ptrCast(@alignCast(l.*.data));
        var sinks = true;
        var p = c.gst_encoding_container_profile_get_profiles(@ptrCast(s.profile));
        while (p != null) : (p = p.*.next) {
            const sformat = c.gst_encoding_profile_get_format(@ptrCast(@alignCast(p.*.data)));
            const ok = factoryHandles(factory, sformat, c.GST_PAD_SINK, false);
            if (sformat != null) c.gst_caps_unref(sformat);
            if (!ok) {
                sinks = false;
                break;
            }
        }
        if (sinks) {
            const m = createWithPreset(factory, s.profile, "muxer");
            if (m != null) return m;
        }
    }
    return null;
}

fn createElementsAndPads(s: *Self) bool {
    if (!isA(s.profile, c.gst_encoding_container_profile_get_type())) return createStreamGroup(s, s.profile, null, null, null) != null;
    const muxer = getMuxer(s);
    if (muxer == null) {
        const format = c.gst_encoding_profile_get_format(s.profile);
        _ = c.gst_element_post_message(el(s), c.gst_missing_encoder_message_new(el(s), format));
        const text = c.gst_caps_to_string(format);
        cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, c.g_strdup_printf("No available muxer for format %s", text), null, FILE, "create_elements_and_pads", 2359);
        c.g_free(text);
        if (format != null) c.gst_caps_unref(format);
        return false;
    }
    s.muxer = muxer;
    _ = c.gst_bin_add(bin(s), muxer);
    const muxerpad = c.gst_element_get_static_pad(muxer, "src");
    if (s.srcpad != null) {
        if (muxerpad == null) {
            _ = c.gst_bin_remove(bin(s), muxer);
            return false;
        }
        if (c.gst_ghost_pad_set_target(@ptrCast(@alignCast(s.srcpad)), muxerpad) == 0) {
            _ = c.gst_bin_remove(bin(s), muxer);
            c.gst_object_unref(muxerpad);
            return false;
        }
        c.gst_object_unref(muxerpad);
    } else if (muxerpad != null) {
        if (!createSrcPad(s, muxerpad)) {
            _ = c.gst_bin_remove(bin(s), muxer);
            c.gst_object_unref(muxerpad);
            return false;
        }
        c.gst_object_unref(muxerpad);
    }
    var l = c.gst_encoding_container_profile_get_profiles(@ptrCast(s.profile));
    while (l != null) : (l = l.*.next) {
        const sprof: ?*c.GstEncodingProfile = @ptrCast(l.*.data);
        if (c.gst_encoding_profile_get_presence(sprof) != 0 and c.gst_encoding_profile_is_enabled(sprof) != 0) {
            if (createStreamGroup(s, sprof, null, null, null) == null) {
                _ = c.gst_bin_remove(bin(s), muxer);
                s.muxer = null;
                return false;
            }
        }
    }
    _ = c.gst_element_sync_state_with_parent(muxer);
    return true;
}

fn releasePads(item: [*c]const c.GValue, data: c.gpointer) callconv(.c) void {
    const pad: ?*c.GstPad = @ptrCast(c.g_value_get_object(item));
    const peer = c.gst_pad_get_peer(pad);
    if (peer != null) {
        if (c.gst_pad_get_direction(peer) == c.GST_PAD_SRC) {
            _ = c.gst_pad_unlink(peer, pad);
        } else _ = c.gst_pad_unlink(pad, peer);
        c.gst_object_unref(peer);
    }
    c.gst_element_release_request_pad(@ptrCast(@alignCast(data)), pad);
}

fn releaseAll(it: ?*c.GstIterator, owner: [*c]c.GstElement) void {
    var ret: c.GstIteratorResult = c.GST_ITERATOR_OK;
    while (ret == c.GST_ITERATOR_OK or ret == c.GST_ITERATOR_RESYNC) {
        ret = c.gst_iterator_foreach(it, releasePads, owner);
        c.gst_iterator_resync(it);
    }
    c.gst_iterator_free(it);
}

fn stopRemove(s: *Self, e: [*c]c.GstElement) void {
    _ = c.gst_element_set_state(e, c.GST_STATE_NULL);
    _ = c.gst_bin_remove(bin(s), e);
}

fn groupFree(s: *Self, g: *Group) void {
    if (g.restriction_sid != 0) c.g_signal_handler_disconnect(g.profile, g.restriction_sid);
    if (g.outqueue != null) {
        if (s.muxer != null) {
            const tmp = c.gst_element_get_static_pad(g.outqueue, "src");
            const pad = c.gst_pad_get_peer(tmp);
            if (pad != null) {
                _ = c.gst_pad_unlink(tmp, pad);
                const t = c.gst_pad_get_pad_template(pad);
                if (t != null and t.*.presence == c.GST_PAD_REQUEST) c.gst_element_release_request_pad(s.muxer, pad);
                if (t != null) c.gst_object_unref(t);
                c.gst_object_unref(pad);
            }
            c.gst_object_unref(tmp);
        }
        _ = c.gst_element_set_state(g.outqueue, c.GST_STATE_NULL);
    }
    if (g.formatter != null) {
        _ = c.gst_element_set_state(g.formatter, c.GST_STATE_NULL);
        _ = c.gst_element_set_state(g.outfilter, c.GST_STATE_NULL);
        c.gst_element_unlink(g.formatter, g.outqueue);
        c.gst_element_unlink(g.outfilter, g.formatter);
    } else if (g.outfilter != null) {
        _ = c.gst_element_set_state(g.outfilter, c.GST_STATE_NULL);
        c.gst_element_unlink(g.outfilter, g.outqueue);
    }
    if (g.outqueue != null) stopRemove(s, g.outqueue);
    if (g.parser != null) {
        _ = c.gst_element_set_state(g.parser, c.GST_STATE_NULL);
        c.gst_element_unlink(g.parser, g.outfilter);
        if (g.combiner != null) c.gst_element_unlink(g.combiner, g.parser);
        _ = c.gst_bin_remove(bin(s), g.parser);
    }
    if (g.ghostpad != null) {
        if (cm.obj(g.ghostpad).parent != null) {
            _ = c.gst_element_remove_pad(el(s), g.ghostpad);
        } else c.gst_object_unref(g.ghostpad);
    }
    if (g.inqueue != null) _ = c.gst_element_set_state(g.inqueue, c.GST_STATE_NULL);
    if (g.encoder != null) {
        _ = c.gst_element_set_state(g.encoder, c.GST_STATE_NULL);
        _ = c.g_signal_handlers_disconnect_matched(g.profile, c.G_SIGNAL_MATCH_FUNC | c.G_SIGNAL_MATCH_DATA, 0, 0, null, @constCast(@ptrCast(&elementPropertiesFromProfile)), g.encoder);
    }
    if (g.fakesink != null) _ = c.gst_element_set_state(g.fakesink, c.GST_STATE_NULL);
    if (g.outfilter != null) {
        _ = c.gst_element_set_state(g.outfilter, c.GST_STATE_NULL);
        if (g.outputfilter_caps_sid != 0) {
            c.g_signal_handler_disconnect(firstPad(g.outfilter.*.sinkpads), g.outputfilter_caps_sid);
            g.outputfilter_caps_sid = 0;
        }
    }
    if (g.smartencoder != null) _ = c.gst_element_set_state(g.smartencoder, c.GST_STATE_NULL);
    clearObject(&g.smart_capsfilter);
    if (g.capsfilter != null) {
        _ = c.gst_element_set_state(g.capsfilter, c.GST_STATE_NULL);
        c.gst_element_unlink(g.capsfilter, if (g.encoder != null) g.encoder else g.fakesink);
        _ = c.gst_bin_remove(bin(s), g.capsfilter);
    }
    var l = g.converters;
    while (l != null) : (l = l.*.next) stopRemove(s, @ptrCast(@alignCast(l.*.data)));
    if (g.converters != null) c.g_list_free(g.converters);
    if (g.combiner != null) {
        releaseAll(c.gst_element_iterate_sink_pads(g.combiner), g.combiner);
        stopRemove(s, g.combiner);
    }
    if (g.splitter != null) {
        releaseAll(c.gst_element_iterate_src_pads(g.splitter), g.splitter);
        stopRemove(s, g.splitter);
    }
    if (g.inqueue != null) _ = c.gst_bin_remove(bin(s), g.inqueue);
    if (g.encoder != null) _ = c.gst_bin_remove(bin(s), g.encoder);
    if (g.fakesink != null) _ = c.gst_bin_remove(bin(s), g.fakesink);
    if (g.smartencoder != null) _ = c.gst_bin_remove(bin(s), g.smartencoder);
    if (g.outfilter != null) _ = c.gst_bin_remove(bin(s), g.outfilter);
    clearObject(&g.profile);
    std.heap.c_allocator.destroy(g);
}

fn groupRemove(s: *Self, g: *Group) void {
    s.streams = c.g_list_remove(s.streams, g);
    groupFree(s, g);
}

fn tearDownProfile(s: *Self) void {
    if (s.profile == null) return;
    while (s.streams != null) groupRemove(s, groupOf(s.streams));
    if (s.srcpad != null) _ = c.gst_ghost_pad_set_target(@ptrCast(@alignCast(s.srcpad)), null);
    if (s.muxer != null) {
        _ = c.g_signal_handlers_disconnect_matched(s.profile, c.G_SIGNAL_MATCH_FUNC | c.G_SIGNAL_MATCH_DATA, 0, 0, null, @constCast(@ptrCast(&elementPropertiesFromProfile)), s.muxer);
        stopRemove(s, s.muxer);
        s.muxer = null;
    }
    if (s.srcpad == null) {
        while (el(s).*.srcpads != null) _ = c.gst_element_remove_pad(el(s), firstPad(el(s).*.srcpads));
    }
    clearObject(&s.profile);
}

fn setupProfile(s: *Self, profile: ?*c.GstEncodingProfile) bool {
    if (!cm.that(s.profile == null, "gst_encode_base_bin_setup_profile", "ebin->profile == NULL")) return false;
    s.profile = profile;
    const ok = createElementsAndPads(s);
    if (!ok) tearDownProfile(s);
    return ok;
}

fn setProfile(s: *Self, profile_in: ?*c.GstEncodingProfile) bool {
    var profile = profile_in;
    if (!cm.that(isA(profile, c.gst_encoding_profile_get_type()), "gst_encode_base_bin_set_profile", "GST_IS_ENCODING_PROFILE (profile)")) return false;
    if (s.active != 0) {
        clearObject(&profile);
        return false;
    }
    if (s.profile != null) tearDownProfile(s);
    return setupProfile(s, profile);
}

fn deactivate(s: *Self) void {
    var l = s.streams;
    while (l != null) : (l = l.*.next) {
        const g = groupOf(l);
        const format = c.gst_encoding_profile_get_format(g.profile);
        setGroupCapsFormat(g, g.profile, format);
        if (format != null) c.gst_caps_unref(format);
    }
    s.active = 0;
}

fn changeState(element: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(element);
    if (t == c.GST_STATE_CHANGE_READY_TO_PAUSED or t == c.GST_STATE_CHANGE_PAUSED_TO_PLAYING) {
        s.active = @intFromBool(s.profile != null);
        if (s.active == 0) return c.GST_STATE_CHANGE_FAILURE;
    }
    const ret = parent.?.change_state.?(element, t);
    if (ret == c.GST_STATE_CHANGE_FAILURE) return ret;
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) deactivate(s);
    return ret;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("encodebasebin", 0, "base encodebin");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.dispose = dispose;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_PROFILE, c.g_param_spec_object("profile", "Profile", "The GstEncodingProfile to use", c.gst_encoding_profile_get_type(), cm.RW));
    c.g_object_class_install_property(oc, PROP_QUEUE_BYTES_MAX, c.g_param_spec_uint("queue-bytes-max", "Max. size (kB)", "Max. amount of data in the queue (bytes, 0=disable)", 0, std.math.maxInt(c.guint), DEFAULT_QUEUE_BYTES_MAX, cm.RW));
    c.g_object_class_install_property(oc, PROP_QUEUE_BUFFERS_MAX, c.g_param_spec_uint("queue-buffers-max", "Max. size (buffers)", "Max. number of buffers in the queue (0=disable)", 0, std.math.maxInt(c.guint), DEFAULT_QUEUE_BUFFERS_MAX, cm.RW));
    c.g_object_class_install_property(oc, PROP_QUEUE_TIME_MAX, c.g_param_spec_uint64("queue-time-max", "Max. size (ns)", "Max. amount of data in the queue (in ns, 0=disable)", 0, std.math.maxInt(u64), DEFAULT_QUEUE_TIME_MAX, cm.RW));
    c.g_object_class_install_property(oc, PROP_AUDIO_JITTER_TOLERANCE, c.g_param_spec_uint64("audio-jitter-tolerance", "Audio jitter tolerance", "Amount of timestamp jitter/imperfection to allow on audio streams before inserting/dropping samples (ns)", 0, std.math.maxInt(u64), DEFAULT_AUDIO_JITTER_TOLERANCE, cm.RW));
    c.g_object_class_install_property(oc, PROP_AVOID_REENCODING, c.g_param_spec_boolean("avoid-reencoding", "Avoid re-encoding", "Whether to re-encode portions of compatible video streams that lay on segment boundaries", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_FLAGS, c.g_param_spec_flags("flags", "Flags", "Flags to control behaviour", flagsType(), 0, cm.RW));
    const t = cm.typeOfClass(k);
    sig_request_pad = c.g_signal_new("request-pad", t, c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION, @offsetOf(Class, "request_pad"), null, null, null, c.gst_pad_get_type(), @as(c.guint, 1), c.gst_caps_get_type());
    sig_request_profile_pad = c.g_signal_new("request-profile-pad", t, c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION, @offsetOf(Class, "request_profile_pad"), null, null, null, c.gst_pad_get_type(), @as(c.guint, 1), c.G_TYPE_STRING);
    const bk: *Class = @ptrCast(@alignCast(k));
    bk.request_pad = requestPadSignal;
    bk.request_profile_pad = requestProfilePadSignal;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &video_t);
    c.gst_element_class_add_static_pad_template(ec, &audio_t);
    c.gst_element_class_add_static_pad_template(ec, &private_t);
    ec.change_state = changeState;
    ec.request_new_pad = requestNewPad;
    ec.release_pad = releasePad;
    c.gst_element_class_set_static_metadata(ec, "Encoder Bin", "Generic/Bin/Encoder", "Convenience encoding/muxing element", "Edward Hervey <edward.hervey@collabora.co.uk>");
    c.gst_type_mark_as_plugin_api(flagsType(), 0);
    c.gst_type_mark_as_plugin_api(t, 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.muxers = c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_MUXER, c.GST_RANK_MARGINAL);
    s.formatters = c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_FORMATTER, c.GST_RANK_SECONDARY);
    s.encoders = c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_ENCODER, c.GST_RANK_MARGINAL);
    s.parsers = c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_PARSER, c.GST_RANK_MARGINAL);
    s.timestampers = c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_TIMESTAMPER, c.GST_RANK_MARGINAL);
    s.raw_video_caps = c.gst_caps_from_string("video/x-raw");
    s.raw_audio_caps = c.gst_caps_from_string("audio/x-raw");
    s.queue_buffers_max = DEFAULT_QUEUE_BUFFERS_MAX;
    s.queue_bytes_max = DEFAULT_QUEUE_BYTES_MAX;
    s.queue_time_max = DEFAULT_QUEUE_TIME_MAX;
    s.tolerance = DEFAULT_AUDIO_JITTER_TOLERANCE;
    s.avoid_reencoding = 0;
    s.flags = 0;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_bin_get_type(), "GstEncodeBaseBin", Class, Self, classInit, init);
        }
    }.f);
}
