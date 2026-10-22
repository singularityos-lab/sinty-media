const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const desc = @import("desc.zig");
const target = @import("enctarget.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Caps = c.GstCaps;
const OProfile = ?*c.GstEncodingProfile;
const VNONE = @as(?*anyopaque, null);
const PATH = "../gst-libs/gst/pbutils/encoding-profile.c";

pub const Profile = extern struct {
    parent: c.GObject,
    name: [*c]u8,
    description: [*c]u8,
    format: [*c]Caps,
    preset: [*c]u8,
    preset_name: [*c]u8,
    presence: c.guint,
    allow_dynamic_output: c.gboolean,
    enabled: c.gboolean,
    single_segment: c.gboolean,
    lock: c.GMutex,
    restriction: [*c]Caps,
    element_properties: ?*c.GstStructure,
};

const ProfileClass = extern struct {
    parent: c.GObjectClass,
    copy: ?*const fn (*Profile, *Profile) callconv(.c) void,
};

const Container = extern struct {
    parent: Profile,
    profiles: [*c]c.GList,
};

const Video = extern struct {
    parent: Profile,
    pass: c.guint,
    variableframerate: c.gboolean,
};

var profile_once: gtype.Once = .{};
var container_once: gtype.Once = .{};
var video_once: gtype.Once = .{};
var audio_once: gtype.Once = .{};
var profile_parent: ?*c.GObjectClass = null;
var container_parent: ?*c.GObjectClass = null;
var props: [3]?*c.GParamSpec = .{ null, null, null };

pub fn of(p: anytype) *Profile {
    return @ptrCast(@alignCast(p));
}

pub fn isProfile(p: anytype) bool {
    return gtype.instanceOf(p, gst_encoding_profile_get_type());
}

pub fn isContainer(p: anytype) bool {
    return gtype.instanceOf(p, gst_encoding_container_profile_get_type());
}

pub fn isVideo(p: anytype) bool {
    return gtype.instanceOf(p, gst_encoding_video_profile_get_type());
}

pub fn isAudio(p: anytype) bool {
    return gtype.instanceOf(p, gst_encoding_audio_profile_get_type());
}

fn kids(p: anytype) *[*c]c.GList {
    return &@as(*Container, @ptrCast(@alignCast(p))).profiles;
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const p = of(o);
    switch (id) {
        1 => c.gst_value_set_caps(v, p.restriction),
        2 => {
            c.g_mutex_lock(&p.lock);
            c.gst_value_set_structure(v, p.element_properties);
            c.g_mutex_unlock(&p.lock);
        },
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 432),
    }
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        1 => gst_encoding_profile_set_restriction(@ptrCast(o), c.gst_caps_copy(c.gst_value_get_caps(v))),
        2 => {
            const s = c.gst_value_get_structure(v);
            gst_encoding_profile_set_element_properties(@ptrCast(o), if (s != null) c.gst_structure_copy(s) else null);
        },
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 457),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const p = of(o);
    c.g_free(p.name);
    if (p.format != null) c.gst_mini_object_unref(@ptrCast(p.format));
    c.g_free(p.preset);
    c.g_free(p.description);
    if (p.restriction != null) c.gst_mini_object_unref(@ptrCast(p.restriction));
    c.g_free(p.preset_name);
    profile_parent.?.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    profile_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const flags = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS | c.G_PARAM_EXPLICIT_NOTIFY;
    props[1] = c.g_param_spec_boxed("restriction-caps", "Restriction caps", "The restriction caps to use", c.gst_caps_get_type(), flags);
    props[2] = c.g_param_spec_boxed("element-properties", "Element properties", "The element properties to use. Example: {properties,boolean-prop=true,string-prop=\"hi\"}.", c.gst_structure_get_type(), flags);
    c.g_object_class_install_properties(oc, 3, &props);
}

fn serializeValue(v: [*c]const c.GValue) callconv(.c) [*c]u8 {
    return gst_encoding_profile_to_string(@ptrCast(c.g_value_get_object(v)));
}

fn deserializeValue(v: [*c]c.GValue, s: [*c]const u8) callconv(.c) c.gboolean {
    const p = gst_encoding_profile_from_string(s);
    if (p == null) return 0;
    c.g_value_take_object(v, p);
    return 1;
}

fn stringToProfile(src: [*c]const c.GValue, dst: [*c]c.GValue) callconv(.c) void {
    const p = gst_encoding_profile_from_string(c.g_value_get_string(src));
    if (p != null) c.g_value_take_object(dst, p);
}

var vtable: c.GstValueTable = std.mem.zeroes(c.GstValueTable);

pub export fn gst_encoding_profile_get_type() c.GType {
    return profile_once.get(struct {
        fn f() c.GType {
            const t = c.g_type_register_static_simple(c.G_TYPE_OBJECT, c.g_intern_static_string("GstEncodingProfile"), @sizeOf(ProfileClass), classInit, @sizeOf(Profile), null, 0);
            vtable.type = t;
            vtable.serialize = @ptrCast(&serializeValue);
            vtable.deserialize = @ptrCast(&deserializeValue);
            c.g_value_register_transform_func(c.G_TYPE_STRING, t, stringToProfile);
            c.gst_value_register(&vtable);
            return t;
        }
    }.f);
}

fn containerFinalize(o: [*c]c.GObject) callconv(.c) void {
    const l = kids(o);
    c.g_list_foreach(l.*, @ptrCast(&c.g_object_unref), null);
    c.g_list_free(l.*);
    container_parent.?.finalize.?(o);
}

fn containerCopy(self: *Profile, copy: *Profile) callconv(.c) void {
    var t = kids(self).*;
    while (t != null) : (t = t[0].next) _ = gst_encoding_container_profile_add_profile(@ptrCast(copy), gst_encoding_profile_copy(@ptrCast(t[0].data)));
}

fn containerClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    container_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = containerFinalize;
    @as(*ProfileClass, @ptrCast(@alignCast(k))).copy = containerCopy;
}

fn videoCopy(self: *Profile, copy: *Profile) callconv(.c) void {
    const s: *Video = @ptrCast(self);
    const d: *Video = @ptrCast(copy);
    d.pass = s.pass;
    d.variableframerate = s.variableframerate;
}

fn videoClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    @as(*ProfileClass, @ptrCast(@alignCast(k))).copy = videoCopy;
}

fn audioClassInit(_: c.gpointer, _: c.gpointer) callconv(.c) void {}

pub export fn gst_encoding_container_profile_get_type() c.GType {
    return container_once.get(struct {
        fn f() c.GType {
            return gtype.object(gst_encoding_profile_get_type, "GstEncodingContainerProfile", ProfileClass, Container, containerClassInit, null, 0);
        }
    }.f);
}

pub export fn gst_encoding_video_profile_get_type() c.GType {
    return video_once.get(struct {
        fn f() c.GType {
            return gtype.object(gst_encoding_profile_get_type, "GstEncodingVideoProfile", ProfileClass, Video, videoClassInit, null, 0);
        }
    }.f);
}

pub export fn gst_encoding_audio_profile_get_type() c.GType {
    return audio_once.get(struct {
        fn f() c.GType {
            return gtype.object(gst_encoding_profile_get_type, "GstEncodingAudioProfile", ProfileClass, Profile, audioClassInit, null, 0);
        }
    }.f);
}

fn valid(p: OProfile, comptime fname: []const u8) bool {
    return check.that(isProfile(p), fname, "GST_IS_ENCODING_PROFILE (profile)");
}

pub export fn gst_encoding_profile_get_name(profile: OProfile) [*c]const c.gchar {
    if (!valid(profile, "gst_encoding_profile_get_name")) return null;
    return of(profile).name;
}

pub export fn gst_encoding_profile_get_description(profile: OProfile) [*c]const c.gchar {
    if (!valid(profile, "gst_encoding_profile_get_description")) return null;
    return of(profile).description;
}

pub export fn gst_encoding_profile_get_format(profile: OProfile) [*c]Caps {
    if (!valid(profile, "gst_encoding_profile_get_format")) return null;
    const f = of(profile).format;
    return if (f != null) c.gst_caps_ref(f) else null;
}

pub export fn gst_encoding_profile_get_preset(profile: OProfile) [*c]const c.gchar {
    if (!valid(profile, "gst_encoding_profile_get_preset")) return null;
    return of(profile).preset;
}

pub export fn gst_encoding_profile_get_preset_name(profile: OProfile) [*c]const c.gchar {
    if (!valid(profile, "gst_encoding_profile_get_preset_name")) return null;
    return of(profile).preset_name;
}

pub export fn gst_encoding_profile_get_presence(profile: OProfile) c.guint {
    if (!valid(profile, "gst_encoding_profile_get_presence")) return 0;
    return of(profile).presence;
}

pub export fn gst_encoding_profile_is_enabled(profile: OProfile) c.gboolean {
    if (!valid(profile, "gst_encoding_profile_is_enabled")) return 0;
    return of(profile).enabled;
}

pub export fn gst_encoding_profile_get_restriction(profile: OProfile) [*c]Caps {
    if (!valid(profile, "gst_encoding_profile_get_restriction")) return null;
    const r = of(profile).restriction;
    return if (r != null) c.gst_caps_ref(r) else null;
}

pub export fn gst_encoding_profile_set_name(profile: OProfile, name: [*c]const c.gchar) void {
    if (!valid(profile, "gst_encoding_profile_set_name")) return;
    const p = of(profile);
    c.g_free(p.name);
    p.name = c.g_strdup(name);
}

pub export fn gst_encoding_profile_set_description(profile: OProfile, description: [*c]const c.gchar) void {
    if (!valid(profile, "gst_encoding_profile_set_description")) return;
    const p = of(profile);
    c.g_free(p.description);
    p.description = c.g_strdup(description);
}

pub export fn gst_encoding_profile_set_format(profile: OProfile, format: [*c]Caps) void {
    if (!valid(profile, "gst_encoding_profile_set_format")) return;
    const p = of(profile);
    if (p.format != null) c.gst_mini_object_unref(@ptrCast(p.format));
    p.format = c.gst_caps_ref(format);
}

pub export fn gst_encoding_profile_get_allow_dynamic_output(profile: OProfile) c.gboolean {
    if (!valid(profile, "gst_encoding_profile_get_allow_dynamic_output")) return 0;
    return of(profile).allow_dynamic_output;
}

pub export fn gst_encoding_profile_set_allow_dynamic_output(profile: OProfile, allow: c.gboolean) void {
    if (!valid(profile, "gst_encoding_profile_set_allow_dynamic_output")) return;
    of(profile).allow_dynamic_output = allow;
}

pub export fn gst_encoding_profile_get_single_segment(profile: OProfile) c.gboolean {
    if (!valid(profile, "gst_encoding_profile_get_single_segment")) return 0;
    return of(profile).single_segment;
}

pub export fn gst_encoding_profile_set_single_segment(profile: OProfile, single: c.gboolean) void {
    if (!valid(profile, "gst_encoding_profile_set_single_segment")) return;
    of(profile).single_segment = single;
}

pub export fn gst_encoding_profile_set_preset(profile: OProfile, preset: [*c]const c.gchar) void {
    if (!valid(profile, "gst_encoding_profile_set_preset")) return;
    const p = of(profile);
    c.g_free(p.preset);
    p.preset = c.g_strdup(preset);
}

pub export fn gst_encoding_profile_set_preset_name(profile: OProfile, preset_name: [*c]const c.gchar) void {
    if (!valid(profile, "gst_encoding_profile_set_preset_name")) return;
    const p = of(profile);
    c.g_free(p.preset_name);
    p.preset_name = c.g_strdup(preset_name);
}

pub export fn gst_encoding_profile_set_presence(profile: OProfile, presence: c.guint) void {
    if (!valid(profile, "gst_encoding_profile_set_presence")) return;
    of(profile).presence = presence;
}

pub export fn gst_encoding_profile_set_enabled(profile: OProfile, enabled: c.gboolean) void {
    if (!valid(profile, "gst_encoding_profile_set_enabled")) return;
    of(profile).enabled = enabled;
}

pub export fn gst_encoding_profile_set_restriction(profile: OProfile, restriction: [*c]Caps) void {
    const fname = "gst_encoding_profile_set_restriction";
    if (!check.that(restriction == null or check.isCaps(restriction), fname, "restriction == NULL || GST_IS_CAPS (restriction)")) return;
    if (!valid(profile, fname)) return;
    const p = of(profile);
    if (p.restriction != null) c.gst_mini_object_unref(@ptrCast(p.restriction));
    p.restriction = restriction;
    c.g_object_notify_by_pspec(@ptrCast(p), props[1]);
}

pub export fn gst_encoding_profile_set_element_properties(self: OProfile, element_properties: ?*c.GstStructure) void {
    const fname = "gst_encoding_profile_set_element_properties";
    if (!check.that(isProfile(self), fname, "GST_IS_ENCODING_PROFILE (self)")) return;
    const ep = element_properties;
    if (!check.that(ep == null or ep.?.type == c.gst_structure_get_type(), fname, "!element_properties || GST_IS_STRUCTURE (element_properties)")) return;
    if (ep != null and (c.gst_structure_has_name(ep, "element-properties-map") != 0 or c.gst_structure_has_name(ep, "properties-map") != 0 or c.gst_structure_has_name(ep, "map") != 0)) {
        if (!check.that(c.gst_structure_has_field_typed(ep, "map", c.gst_value_list_get_type()) != 0, fname, "gst_structure_has_field_typed (element_properties, \"map\", GST_TYPE_LIST)")) return;
    }
    const p = of(self);
    c.g_mutex_lock(&p.lock);
    if (p.element_properties) |old| c.gst_structure_free(old);
    p.element_properties = ep;
    c.g_mutex_unlock(&p.lock);
    c.g_object_notify_by_pspec(@ptrCast(p), props[2]);
}

pub export fn gst_encoding_profile_get_element_properties(self: OProfile) ?*c.GstStructure {
    if (!check.that(isProfile(self), "gst_encoding_profile_get_element_properties", "GST_IS_ENCODING_PROFILE (self)")) return null;
    const p = of(self);
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    return if (p.element_properties) |s| c.gst_structure_copy(s) else null;
}

pub export fn gst_encoding_container_profile_get_profiles(profile: ?*c.GstEncodingContainerProfile) [*c]const c.GList {
    if (!check.that(isContainer(profile), "gst_encoding_container_profile_get_profiles", "GST_IS_ENCODING_CONTAINER_PROFILE (profile)")) return null;
    return kids(profile).*;
}

pub export fn gst_encoding_video_profile_get_pass(prof: ?*c.GstEncodingVideoProfile) c.guint {
    if (!check.that(isVideo(prof), "gst_encoding_video_profile_get_pass", "GST_IS_ENCODING_VIDEO_PROFILE (prof)")) return 0;
    return @as(*Video, @ptrCast(@alignCast(prof))).pass;
}

pub export fn gst_encoding_video_profile_get_variableframerate(prof: ?*c.GstEncodingVideoProfile) c.gboolean {
    if (!check.that(isVideo(prof), "gst_encoding_video_profile_get_variableframerate", "GST_IS_ENCODING_VIDEO_PROFILE (prof)")) return 0;
    return @as(*Video, @ptrCast(@alignCast(prof))).variableframerate;
}

pub export fn gst_encoding_video_profile_set_pass(prof: ?*c.GstEncodingVideoProfile, pass: c.guint) void {
    if (!check.that(isVideo(prof), "gst_encoding_video_profile_set_pass", "GST_IS_ENCODING_VIDEO_PROFILE (prof)")) return;
    @as(*Video, @ptrCast(@alignCast(prof))).pass = pass;
}

pub export fn gst_encoding_video_profile_set_variableframerate(prof: ?*c.GstEncodingVideoProfile, v: c.gboolean) void {
    if (!check.that(isVideo(prof), "gst_encoding_video_profile_set_variableframerate", "GST_IS_ENCODING_VIDEO_PROFILE (prof)")) return;
    @as(*Video, @ptrCast(@alignCast(prof))).variableframerate = v;
}

fn capsEqual(a: [*c]Caps, b: [*c]Caps) bool {
    if (a == b) return true;
    if (a == null or b == null) return false;
    return c.gst_caps_is_equal(a, b) != 0;
}

fn compare(a_: c.gconstpointer, b_: c.gconstpointer) callconv(.c) c.gint {
    const a = of(@constCast(a_));
    const b = of(@constCast(b_));
    if (gtype.typeOf(a) != gtype.typeOf(b) or !capsEqual(a.format, b.format) or c.g_strcmp0(a.preset, b.preset) != 0 or c.g_strcmp0(a.preset_name, b.preset_name) != 0 or c.g_strcmp0(a.name, b.name) != 0 or c.g_strcmp0(a.description, b.description) != 0) return -1;
    if (isContainer(a)) {
        if (c.g_list_length(kids(a).*) != c.g_list_length(kids(b).*)) return -1;
        var t = kids(a).*;
        while (t != null) : (t = t[0].next) {
            if (gst_encoding_container_profile_contains_profile(@ptrCast(a), @ptrCast(t[0].data)) == 0) return -1;
        }
        return 0;
    }
    if (isVideo(a)) {
        const va: *Video = @ptrCast(a);
        const vb: *Video = @ptrCast(b);
        if (va.pass != vb.pass or va.variableframerate != vb.variableframerate) return -1;
    }
    return 0;
}

pub export fn gst_encoding_container_profile_contains_profile(container: ?*c.GstEncodingContainerProfile, profile: OProfile) c.gboolean {
    const fname = "gst_encoding_container_profile_contains_profile";
    if (!check.that(isContainer(container), fname, "GST_IS_ENCODING_CONTAINER_PROFILE (container)")) return 0;
    if (!check.that(isProfile(profile), fname, "GST_IS_ENCODING_PROFILE (profile)")) return 0;
    return @intFromBool(c.g_list_find_custom(kids(container).*, profile, compare) != null);
}

pub export fn gst_encoding_container_profile_add_profile(container: ?*c.GstEncodingContainerProfile, profile: OProfile) c.gboolean {
    const fname = "gst_encoding_container_profile_add_profile";
    if (!check.that(isContainer(container), fname, "GST_IS_ENCODING_CONTAINER_PROFILE (container)")) return 0;
    if (!check.that(isProfile(profile), fname, "GST_IS_ENCODING_PROFILE (profile)")) return 0;
    const l = kids(container);
    l.* = c.g_list_append(l.*, profile);
    return 1;
}

fn create(t: c.GType, format: [*c]Caps, preset: [*c]const u8, name: [*c]const u8, description: [*c]const u8, restriction: [*c]Caps, presence: c.guint) *Profile {
    const p = of(c.g_object_new(t, @as([*c]const u8, null)));
    if (name != null) p.name = c.g_strdup(name);
    if (description != null) p.description = c.g_strdup(description);
    if (preset != null) p.preset = c.g_strdup(preset);
    if (format != null) p.format = c.gst_caps_ref(format);
    if (restriction != null) p.restriction = c.gst_caps_ref(restriction);
    p.presence = presence;
    p.preset_name = null;
    p.allow_dynamic_output = 1;
    p.enabled = 1;
    return p;
}

pub export fn gst_encoding_container_profile_new(name: [*c]const c.gchar, description: [*c]const c.gchar, format: [*c]Caps, preset: [*c]const c.gchar) ?*c.GstEncodingContainerProfile {
    if (!check.that(check.isCaps(format), "gst_encoding_container_profile_new", "GST_IS_CAPS (format)")) return null;
    return @ptrCast(create(gst_encoding_container_profile_get_type(), format, preset, name, description, null, 0));
}

pub export fn gst_encoding_video_profile_new(format: [*c]Caps, preset: [*c]const c.gchar, restriction: [*c]Caps, presence: c.guint) ?*c.GstEncodingVideoProfile {
    return @ptrCast(create(gst_encoding_video_profile_get_type(), format, preset, null, null, restriction, presence));
}

pub export fn gst_encoding_audio_profile_new(format: [*c]Caps, preset: [*c]const c.gchar, restriction: [*c]Caps, presence: c.guint) ?*c.GstEncodingAudioProfile {
    return @ptrCast(create(gst_encoding_audio_profile_get_type(), format, preset, null, null, restriction, presence));
}

pub export fn gst_encoding_profile_is_equal(a: OProfile, b: OProfile) c.gboolean {
    if (!check.that(isProfile(a), "gst_encoding_profile_is_equal", "GST_IS_ENCODING_PROFILE (a)")) return 0;
    if (!check.that(isProfile(b), "gst_encoding_profile_is_equal", "GST_IS_ENCODING_PROFILE (b)")) return 0;
    return @intFromBool(compare(a, b) == 0);
}

pub export fn gst_encoding_profile_get_input_caps(profile: OProfile) [*c]Caps {
    if (!valid(profile, "gst_encoding_profile_get_input_caps")) return null;
    if (isContainer(profile)) {
        var res = c.gst_caps_new_empty();
        var t = kids(profile).*;
        while (t != null) : (t = t[0].next) res = c.gst_caps_merge(res, gst_encoding_profile_get_input_caps(@ptrCast(t[0].data)));
        return res;
    }
    const p = of(profile);
    if (p.restriction == null or c.gst_caps_is_any(p.restriction) != 0) return c.gst_caps_ref(p.format);
    const name = c.gst_structure_get_name(c.gst_caps_get_structure(p.format, 0));
    const tmp = c.gst_caps_new_empty();
    for (0..c.gst_caps_get_size(p.restriction)) |i| {
        const st = c.gst_structure_copy(c.gst_caps_get_structure(p.restriction, @intCast(i)));
        c.gst_structure_set_name(st, name);
        c.gst_caps_append_structure(tmp, st);
    }
    const out = c.gst_caps_intersect(tmp, p.format);
    c.gst_mini_object_unref(@ptrCast(tmp));
    return out;
}

pub export fn gst_encoding_profile_get_type_nick(profile: OProfile) [*c]const c.gchar {
    if (isContainer(profile)) return "container";
    if (isVideo(profile)) return "video";
    if (isAudio(profile)) return "audio";
    c.g_assertion_message_expr(check.DOMAIN, PATH, 1473, "gst_encoding_profile_get_type_nick", null);
    return null;
}

fn hasFormat(profile: OProfile, media: [*:0]const u8) bool {
    if (!check.that(isProfile(profile), "gst_encoding_profile_has_format", "GST_IS_ENCODING_PROFILE (profile)")) return false;
    const caps = gst_encoding_profile_get_format(profile);
    const r = c.gst_structure_has_name(c.gst_caps_get_structure(caps, 0), media) != 0;
    c.gst_mini_object_unref(@ptrCast(caps));
    return r;
}

fn hasVideo(profile: anytype) bool {
    var l = kids(profile).*;
    while (l != null) : (l = l[0].next) {
        if (isVideo(l[0].data)) return true;
        if (isContainer(l[0].data) and hasVideo(l[0].data)) return true;
    }
    return false;
}

pub export fn gst_encoding_profile_get_file_extension(profile: OProfile) [*c]const c.gchar {
    if (!valid(profile, "gst_encoding_profile_get_file_extension")) return null;
    const caps = gst_encoding_profile_get_format(profile);
    defer c.gst_mini_object_unref(@ptrCast(caps));
    var ext: [*c]const u8 = desc.extension(caps) orelse null;
    if (!isContainer(profile)) return ext;
    const list = kids(profile).*;
    const n = c.g_list_length(list);
    if (desc.isTag(caps)) {
        if (n == 1) ext = gst_encoding_profile_get_file_extension(@ptrCast(list[0].data));
        return ext;
    }
    if (n == 0) return ext;
    const video = hasVideo(profile);
    if (c.g_strcmp0(ext, "ogg") == 0) {
        if (video) return "ogv";
        if (n == 1) {
            const child: OProfile = @ptrCast(list[0].data);
            if (isAudio(child) and hasFormat(child, "audio/x-speex")) return "spx";
        }
        return ext;
    }
    if (video and c.g_strcmp0(ext, "mka") == 0) return "mkv";
    if (hasFormat(profile, "video/x-ms-asf")) {
        var wmv: c.guint = 0;
        var wma: c.guint = 0;
        var other: c.guint = 0;
        var l = list;
        while (l != null) : (l = l[0].next) {
            if (hasFormat(@ptrCast(l[0].data), "video/x-wmv")) {
                wmv += 1;
            } else if (hasFormat(@ptrCast(l[0].data), "audio/x-wma")) {
                wma += 1;
            } else other += 1;
        }
        if (other > 0) {
            ext = "asf";
        } else if (wmv > 0) {
            ext = "wmv";
        } else if (wma > 0) ext = "wma";
    }
    return ext;
}

pub export fn gst_encoding_profile_find(targetname: [*c]const c.gchar, profilename: [*c]const c.gchar, category: [*c]const c.gchar) OProfile {
    if (!check.that(targetname != null, "gst_encoding_profile_find", "targetname != NULL")) return null;
    const t = target.gst_encoding_target_load(targetname, category, null);
    if (t == null) return null;
    const r = target.gst_encoding_target_get_profile(t, if (profilename != null) profilename else "default");
    c.g_object_unref(t);
    return r;
}

fn comboSearch(name: [*c]const u8) OProfile {
    const split = c.g_strsplit(name, "/", 3);
    defer c.g_strfreev(split);
    const n = c.g_strv_length(split);
    if (n > 3) return null;
    return gst_encoding_profile_find(split[0], if (n == 2) split[1] else null, if (n == 3) split[2] else null);
}

fn warn(comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, c.g_log, .{ check.DOMAIN, c.G_LOG_LEVEL_WARNING, fmt } ++ args);
}

fn formatFromFactory(desc_s: [*c]const u8, new_name: *[*c]u8, restrictions: ?*[*c]Caps, rendering: *bool) [*c]Caps {
    var caps: [*c]Caps = null;
    var tmpcaps = c.gst_caps_from_string(desc_s);
    rendering.* = false;
    new_name.* = null;
    var fact: ?*c.GstElementFactory = null;
    defer {
        if (fact != null) c.gst_object_unref(fact);
        if (tmpcaps != null) c.gst_mini_object_unref(@ptrCast(tmpcaps));
    }
    if (c.gst_caps_get_size(tmpcaps) != 1) return null;
    const st = c.gst_caps_get_structure(tmpcaps, 0);
    fact = c.gst_element_factory_find(c.gst_structure_get_name(st));
    if (fact == null) return null;
    if (c.gst_element_factory_list_is_type(fact, c.GST_ELEMENT_FACTORY_TYPE_ENCODER | c.GST_ELEMENT_FACTORY_TYPE_MUXER) == 0) return null;
    var t: [*c]const c.GList = c.gst_element_factory_get_static_pad_templates(fact);
    while (t != null) : (t = t[0].next) {
        const templ: *c.GstStaticPadTemplate = @ptrCast(@alignCast(t[0].data));
        if (templ.direction != c.GST_PAD_SRC) continue;
        const tc = c.gst_static_caps_get(&templ.static_caps);
        if (c.gst_caps_get_size(tc) > 0) caps = c.gst_caps_new_empty_simple(c.gst_structure_get_name(c.gst_caps_get_structure(tc, 0)));
        c.gst_mini_object_unref(@ptrCast(tc));
        if (caps != null) break;
    }
    if (caps != null) {
        new_name.* = c.g_strdup(c.gst_structure_get_name(st));
        if (c.gst_structure_n_fields(st) != 0 and restrictions != null) {
            const sname = c.gst_structure_get_name(c.gst_caps_get_structure(caps, 0));
            if (c.g_str_has_prefix(sname, "audio/") != 0) {
                c.gst_structure_set_name(st, "audio/x-raw");
            } else if (c.g_str_has_prefix(sname, "video/") != 0 or c.g_str_has_prefix(sname, "image/") != 0) c.gst_structure_set_name(st, "video/x-raw");
            restrictions.?.* = tmpcaps;
            tmpcaps = null;
        }
    } else if (c.gst_element_factory_list_is_type(fact, c.GST_ELEMENT_FACTORY_TYPE_MUXER) != 0) {
        new_name.* = c.g_strdup(c.gst_structure_get_name(st));
        caps = c.gst_caps_ref(c.gst_caps_new_empty());
        rendering.* = true;
    }
    return caps;
}

const Env = struct {
    factories: [*c]c.GList,
    raw_audio: [*c]Caps,
    raw_video: [*c]Caps,
};

fn fromCaps(caps: [*c]Caps, preset_name: [*c]u8, restriction: [*c]Caps, presence: c.guint, single: bool, factory_name: [*c]u8, env: *const Env, rendering: bool) OProfile {
    var profile: OProfile = null;
    blk: {
        if (rendering) {
            profile = @ptrCast(gst_encoding_container_profile_new("User profile", "User profile", caps, null));
            break :blk;
        }
        var raw_audio = false;
        var raw_video = false;
        var factories: [*c]c.GList = null;
        if (c.gst_caps_can_intersect(env.raw_audio, caps) != 0) {
            raw_audio = true;
        } else if (c.gst_caps_can_intersect(env.raw_video, caps) != 0) {
            raw_video = true;
        } else {
            factories = c.gst_element_factory_list_filter(env.factories, caps, c.GST_PAD_SRC, 0);
            if (factories == null) return null;
        }
        if (raw_audio or (factories != null and c.gst_element_factory_list_is_type(@ptrCast(factories[0].data), c.GST_ELEMENT_FACTORY_TYPE_AUDIO_ENCODER) != 0)) {
            profile = @ptrCast(gst_encoding_audio_profile_new(caps, preset_name, restriction, presence));
        } else if (raw_video or (factories != null and c.gst_element_factory_list_is_type(@ptrCast(factories[0].data), c.GST_ELEMENT_FACTORY_TYPE_VIDEO_ENCODER) != 0)) {
            profile = @ptrCast(gst_encoding_video_profile_new(caps, preset_name, restriction, presence));
        } else if (c.gst_element_factory_list_is_type(@ptrCast(factories[0].data), c.GST_ELEMENT_FACTORY_TYPE_MUXER) != 0) {
            profile = @ptrCast(gst_encoding_container_profile_new("User profile", "User profile", caps, null));
        }
        if (factories != null) c.gst_plugin_feature_list_free(factories);
    }
    if (factory_name != null and profile != null) gst_encoding_profile_set_preset_name(profile, factory_name);
    gst_encoding_profile_set_single_segment(profile, @intFromBool(single));
    c.g_free(factory_name);
    return profile;
}

fn validateName(name: [*c]const u8) bool {
    if (!c.g_ascii_isalpha(name[0])) return false;
    var s = name + 1;
    while (s[0] != 0 and (c.g_ascii_isalnum(s[0]) or c.strchr("/-_.:+", s[0]) != null)) s += 1;
    return s[0] == ',' or s[0] == 0;
}

fn streamProfile(serialized: [*c]u8, env: *const Env) OProfile {
    var presence: c.guint = 0;
    var single = false;
    var strcaps: [*c]u8 = null;
    var preset_name: [*c]u8 = null;
    var factory_name: [*c]u8 = null;
    var variable_framerate: [*c]u8 = null;
    var element_properties: ?*c.GstStructure = null;
    var restriction: [*c]Caps = null;
    var profile: OProfile = null;
    var strprops: [*c][*c]u8 = null;

    const rf = c.g_strsplit(serialized, "->", 0);
    if (rf[1] != null) {
        restriction = c.gst_caps_from_string(rf[0]);
        strcaps = c.g_strdup(rf[1]);
    } else strcaps = c.g_strdup(rf[0]);
    c.g_strfreev(rf);

    const preset_v = c.g_strsplit(strcaps, "+", 0);
    var strpresence: [*c]u8 = undefined;
    if (preset_v[1] != null) {
        strpresence = preset_v[1];
        c.g_free(strcaps);
        strcaps = c.g_strdup(preset_v[0]);
    } else strpresence = preset_v[0];

    blk: {
        strprops = c.g_strsplit(strpresence, "|", 0);
        if (strprops[1] != null) {
            if (preset_v[1] != null) {
                preset_name = c.g_strdup(strprops[0]);
            } else {
                c.g_free(strcaps);
                strcaps = c.g_strdup(strprops[0]);
            }
            var i: usize = 1;
            while (strprops[i] != null) : (i += 1) {
                const prop = strprops[i];
                var tmpstruct: ?*c.GstStructure = null;
                if (validateName(prop)) tmpstruct = c.gst_structure_new_from_string(prop);
                if (tmpstruct != null) {
                    if (element_properties) |old| c.gst_structure_free(old);
                    element_properties = tmpstruct;
                    continue;
                }
                const propv = c.g_strsplit(prop, "=", -1);
                defer c.g_strfreev(propv);
                if (propv[1] != null and propv[2] != null) {
                    warn("Wrong format for property: %s, only 1 `=` is expected", .{prop});
                    break :blk;
                }
                var presence_str: [*c]u8 = null;
                if (propv[1] == null) {
                    presence_str = propv[0];
                } else if (c.g_strcmp0(propv[0], "presence") == 0) {
                    presence_str = propv[1];
                } else if (c.g_strcmp0(propv[0], "variable-framerate") == 0) {
                    variable_framerate = c.g_strdup(propv[1]);
                } else if (c.g_strcmp0(propv[0], "single-segment") == 0) {
                    var v = std.mem.zeroes(c.GValue);
                    _ = c.g_value_init(&v, c.G_TYPE_BOOLEAN);
                    if (c.gst_value_deserialize(&v, propv[1]) == 0) {
                        warn("Invalid value for property 'single-segment': %s", .{propv[1]});
                        break :blk;
                    }
                    single = c.g_value_get_boolean(&v) != 0;
                    _ = c.g_value_reset(&v);
                } else if (c.g_strcmp0(propv[0], "factory-name") == 0) {
                    if (factory_name != null) {
                        warn("Multiple factory names specified", .{});
                        break :blk;
                    }
                    factory_name = c.g_strdup(propv[1]);
                } else {
                    warn("Unsupported property: %s", .{propv[0]});
                    break :blk;
                }
                if (presence_str != null) {
                    var end: [*c]u8 = null;
                    presence = @truncate(@as(u64, @bitCast(c.g_ascii_strtoll(presence_str, &end, 10))));
                    if (end == strprops[1]) {
                        warn("Wrong presence %s", .{presence_str});
                        break :blk;
                    }
                }
            }
        } else if (preset_v[1] != null) {
            preset_name = c.g_strdup(preset_v[1]);
            c.g_free(strcaps);
            strcaps = c.g_strdup(preset_v[0]);
        }

        var caps = c.gst_caps_from_string(strcaps);
        if (caps != null) {
            profile = fromCaps(caps, preset_name, restriction, presence, single, null, env, false);
            c.gst_mini_object_unref(@ptrCast(caps));
        }
        if (profile == null) {
            var rendering = false;
            caps = formatFromFactory(strcaps, &factory_name, if (restriction != null) null else &restriction, &rendering);
            if (caps != null) {
                profile = fromCaps(caps, preset_name, restriction, presence, single, factory_name, env, rendering);
                c.gst_mini_object_unref(@ptrCast(caps));
            }
        }
        if (variable_framerate != null and isVideo(profile)) {
            var v = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&v, c.G_TYPE_BOOLEAN);
            if (c.gst_value_deserialize(&v, variable_framerate) != 0) gst_encoding_video_profile_set_variableframerate(@ptrCast(profile), c.g_value_get_boolean(&v));
            _ = c.g_value_reset(&v);
        }
        if (profile != null and element_properties != null) {
            gst_encoding_profile_set_element_properties(profile, element_properties);
            element_properties = null;
        }
    }
    c.g_free(strcaps);
    c.g_free(variable_framerate);
    c.g_strfreev(strprops);
    c.g_strfreev(preset_v);
    c.g_free(preset_name);
    if (element_properties) |s| c.gst_structure_free(s);
    if (restriction != null) c.gst_mini_object_unref(@ptrCast(restriction));
    return profile;
}

fn parse(value: [*c]const u8) OProfile {
    var res: OProfile = null;
    var parts = c.g_regex_split_simple("(?<!\\\\)(?:\\\\\\\\)*:", value, 0, 0);
    const env = Env{
        .factories = c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_ENCODER | c.GST_ELEMENT_FACTORY_TYPE_MUXER, c.GST_RANK_MARGINAL),
        .raw_video = c.gst_caps_new_empty_simple("video/x-raw"),
        .raw_audio = c.gst_caps_new_empty_simple("audio/x-raw"),
    };
    if (parts == null) parts = c.g_strsplit(value, ":", 0);
    var i: usize = 0;
    while (parts[i] != null and parts[i][0] != 0) : (i += 1) {
        const cs = c.g_strcompress(parts[i]);
        const profile = streamProfile(cs, &env);
        c.g_free(cs);
        if (profile == null or (res != null and !isContainer(res))) {
            if (res != null) c.g_object_unref(res);
            res = null;
            break;
        }
        if (res != null) {
            _ = gst_encoding_container_profile_add_profile(@ptrCast(res), profile);
        } else res = profile;
    }
    c.g_strfreev(parts);
    c.gst_mini_object_unref(@ptrCast(env.raw_audio));
    c.gst_mini_object_unref(@ptrCast(env.raw_video));
    c.gst_plugin_feature_list_free(env.factories);
    return res;
}

pub export fn gst_encoding_profile_from_string(string: [*c]const c.gchar) OProfile {
    var profile = comboSearch(string);
    if (profile != null) return profile;
    const end = c.g_strrstr(string, ".gep");
    if (end != null) {
        var pname: [*c]u8 = null;
        if (end[4] == ':') pname = c.g_strdup(end + 5);
        if (end[4] == 0 or pname != null) {
            const fname = c.g_strndup(string, @intCast(@intFromPtr(end) - @intFromPtr(string) + 4));
            const t = target.gst_encoding_target_load_from_file(fname, null);
            if (t != null) {
                profile = target.gst_encoding_target_get_profile(t, if (pname != null) pname else "default");
                c.g_object_unref(t);
            }
            c.g_free(pname);
            c.g_free(fname);
        }
    }
    if (profile == null) profile = parse(string);
    return profile;
}

fn serialize(res: *c.GString, p: *Profile) void {
    if (res.len != 0) _ = c.g_string_append_c(res, ':');
    if (p.restriction != null) {
        const t = c.gst_caps_to_string(p.restriction);
        c.g_string_append_printf(res, "%s->", t);
        c.g_free(t);
    }
    const t = c.gst_caps_to_string(p.format);
    _ = c.g_string_append(res, t);
    c.g_free(t);
    if (p.presence != 0) c.g_string_append_printf(res, "|presence=%d", p.presence);
    if (p.single_segment != 0) c.g_string_append_printf(res, "%ssingle-segment=true", @as([*c]const u8, if (p.presence != 0) "" else "|"));
    if (isContainer(p)) {
        var l = kids(p).*;
        while (l != null) : (l = l[0].next) serialize(res, of(l[0].data));
    }
}

pub export fn gst_encoding_profile_to_string(profile: OProfile) [*c]c.gchar {
    if (!check.that(profile != null, "gst_encoding_profile_to_string", "profile != NULL")) return null;
    const res = c.g_string_new(null);
    serialize(res, of(profile));
    return c.g_string_free(res, 0);
}

pub export fn gst_encoding_profile_copy(self: OProfile) OProfile {
    const s = of(self);
    const k: *ProfileClass = gtype.classPeek(ProfileClass, self);
    const copy = create(gtype.typeOf(s), s.format, s.preset, s.name, s.description, s.restriction, s.presence);
    copy.enabled = s.enabled;
    copy.allow_dynamic_output = s.allow_dynamic_output;
    gst_encoding_profile_set_preset_name(@ptrCast(copy), s.preset_name);
    gst_encoding_profile_set_description(@ptrCast(copy), s.description);
    if (k.copy) |f| f(s, copy);
    return @ptrCast(copy);
}
