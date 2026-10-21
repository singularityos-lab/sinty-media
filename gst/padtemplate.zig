const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const pad = @import("pad.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Template = c.GstPadTemplate;
const Static = c.GstStaticPadTemplate;
const NONE_TYPE: c.GType = 1 << c.G_TYPE_FUNDAMENTAL_SHIFT;

const PROP_NAME_TEMPLATE = 1;
const PROP_DIRECTION = 2;
const PROP_PRESENCE = 3;
const PROP_CAPS = 4;
const PROP_GTYPE = 5;

var parent_class: ?*c.GObjectClass = null;
var type_once: gtype.Once = .{};
var static_once: gtype.Once = .{};
var created_signal: c.guint = 0;

pub fn isTemplate(p: anytype) bool {
    return gtype.instanceOf(p, gst_pad_template_get_type());
}

pub export fn gst_pad_template_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return gtype.object(object.gst_object_get_type, "GstPadTemplate", c.GstPadTemplateClass, Template, classInit, instanceInit, 0);
        }
    }.f);
}

pub export fn gst_static_pad_template_get_type() c.GType {
    return static_once.get(struct {
        fn f() c.GType {
            return c.g_pointer_type_register_static("GstStaticPadTemplate");
        }
    }.f);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(klass))).g_type;
    created_signal = c.g_signal_new("pad-created", t, c.G_SIGNAL_RUN_LAST, @offsetOf(c.GstPadTemplateClass, "pad_created"), null, null, null, NONE_TYPE, @as(c.guint, 1), pad.gst_pad_get_type());
    gc.dispose = dispose;
    gc.get_property = getProperty;
    gc.set_property = setProperty;
    const fl = c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, PROP_NAME_TEMPLATE, c.g_param_spec_string("name-template", "Name template", "The name template of the pad template", null, fl));
    c.g_object_class_install_property(gc, PROP_DIRECTION, c.g_param_spec_enum("direction", "Direction", "The direction of the pad described by the pad template", c.gst_pad_direction_get_type(), c.GST_PAD_UNKNOWN, fl));
    c.g_object_class_install_property(gc, PROP_PRESENCE, c.g_param_spec_enum("presence", "Presence", "When the pad described by the pad template will become available", c.gst_pad_presence_get_type(), c.GST_PAD_ALWAYS, fl));
    c.g_object_class_install_property(gc, PROP_CAPS, c.g_param_spec_boxed("caps", "Caps", "The capabilities of the pad described by the pad template", c.gst_caps_get_type(), fl));
    c.g_object_class_install_property(gc, PROP_GTYPE, c.g_param_spec_gtype("gtype", "GType", "The GType of the pad described by the pad template", NONE_TYPE, fl));
    @as(*c.GstObjectClass, @ptrCast(@alignCast(klass))).path_string_separator = "*";
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const t: [*c]Template = @ptrCast(@alignCast(instance));
    t[0].object.flags |= c.GST_OBJECT_FLAG_MAY_BE_LEAKED;
    t[0].ABI.abi.gtype = NONE_TYPE;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const t: [*c]Template = @ptrCast(@alignCast(o));
    c.g_free(t[0].name_template);
    if (t[0].caps != null) c.gst_caps_unref(t[0].caps);
    _ = c.gst_caps_replace(&t[0].ABI.abi.documentation_caps, null);
    parent_class.?.dispose.?(o);
}

fn validName(name: [*c]const u8, presence: c.GstPadPresence) bool {
    const s = std.mem.span(name);
    if (presence == c.GST_PAD_ALWAYS) {
        if (std.mem.indexOfScalar(u8, s, '%') != null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "invalid name template %s: conversion specifications are not allowed for GST_PAD_ALWAYS padtemplates", name);
            return false;
        }
        return true;
    }
    if (presence != c.GST_PAD_REQUEST) return true;
    var has_s = false;
    var at = std.mem.indexOfScalar(u8, s, '%');
    while (at) |i| {
        const next: u8 = if (i + 1 < s.len) s[i + 1] else 0;
        if (next != 's' and next != 'd' and next != 'u') {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "invalid name template %s: conversion specification must be of type '%%d', '%%u' or '%%s' for GST_PAD_REQUEST padtemplate", name);
            return false;
        }
        if (next == 's' and (i + 2 < s.len or has_s)) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "invalid name template %s: conversion specification of type '%%s'only can be used once in the GST_PAD_REQUEST padtemplate at the very end and not allowed any other characters with '%%s'", name);
            return false;
        }
        if (next == 's') has_s = true;
        const underscore = std.mem.indexOfScalarPos(u8, s, i, '_');
        at = std.mem.indexOfScalarPos(u8, s, i + 1, '%');
        if (at) |n| if (underscore == null or n < underscore.?) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "invalid name template %s: each of conversion specifications must be separated by an underscore", name);
            return false;
        };
    }
    return true;
}

fn build(name: [*c]const u8, dir: c.GstPadDirection, presence: c.GstPadPresence, caps: [*c]c.GstCaps, kind: ?c.GType) [*c]Template {
    const t = gst_pad_template_get_type();
    const o = if (kind) |k|
        c.g_object_new(t, "name", name, "name-template", name, "direction", dir, "presence", presence, "caps", caps, "gtype", k, @as([*c]const u8, null))
    else
        c.g_object_new(t, "name", name, "name-template", name, "direction", dir, "presence", presence, "caps", caps, @as([*c]const u8, null));
    return @ptrCast(@alignCast(o));
}

fn fromStatic(s: [*c]Static, kind: ?c.GType) [*c]Template {
    if (!validName(s[0].name_template, s[0].presence)) return null;
    const caps = c.gst_static_caps_get(&s[0].static_caps);
    const r = build(s[0].name_template, s[0].direction, s[0].presence, caps, kind);
    c.gst_caps_unref(caps);
    return r;
}

pub export fn gst_static_pad_template_get(s: [*c]Static) [*c]Template {
    return fromStatic(s, null);
}

pub export fn gst_pad_template_new_from_static_pad_template_with_gtype(s: [*c]Static, kind: c.GType) [*c]Template {
    if (!check.that(c.g_type_is_a(kind, pad.gst_pad_get_type()) != 0, "gst_pad_template_new_from_static_pad_template_with_gtype", "g_type_is_a (pad_type, GST_TYPE_PAD)")) return null;
    return fromStatic(s, kind);
}

fn newChecked(comptime f: []const u8, name: [*c]const u8, dir: c.GstPadDirection, presence: c.GstPadPresence, caps: [*c]c.GstCaps, kind: ?c.GType) [*c]Template {
    if (!check.that(name != null, f, "name_template != NULL")) return null;
    if (!check.that(caps != null, f, "caps != NULL")) return null;
    if (!check.that(dir == c.GST_PAD_SRC or dir == c.GST_PAD_SINK, f, "direction == GST_PAD_SRC || direction == GST_PAD_SINK")) return null;
    if (!check.that(presence == c.GST_PAD_ALWAYS or presence == c.GST_PAD_SOMETIMES or presence == c.GST_PAD_REQUEST, f, "presence == GST_PAD_ALWAYS || presence == GST_PAD_SOMETIMES || presence == GST_PAD_REQUEST")) return null;
    if (kind) |k| if (!check.that(c.g_type_is_a(k, pad.gst_pad_get_type()) != 0, f, "g_type_is_a (pad_type, GST_TYPE_PAD)")) return null;
    if (!validName(name, presence)) return null;
    return build(name, dir, presence, caps, kind);
}

pub export fn gst_pad_template_new(name: [*c]const u8, dir: c.GstPadDirection, presence: c.GstPadPresence, caps: [*c]c.GstCaps) [*c]Template {
    return newChecked("gst_pad_template_new", name, dir, presence, caps, null);
}

pub export fn gst_pad_template_new_with_gtype(name: [*c]const u8, dir: c.GstPadDirection, presence: c.GstPadPresence, caps: [*c]c.GstCaps, kind: c.GType) [*c]Template {
    return newChecked("gst_pad_template_new_with_gtype", name, dir, presence, caps, kind);
}

pub export fn gst_static_pad_template_get_caps(s: [*c]Static) [*c]c.GstCaps {
    if (!check.that(s != null, "gst_static_pad_template_get_caps", "templ")) return null;
    return c.gst_static_caps_get(&s[0].static_caps);
}

pub export fn gst_pad_template_get_caps(t: [*c]Template) [*c]c.GstCaps {
    if (!check.that(isTemplate(t), "gst_pad_template_get_caps", "GST_IS_PAD_TEMPLATE (templ)")) return null;
    return if (t[0].caps != null) c.gst_caps_ref(t[0].caps) else null;
}

pub export fn gst_pad_template_set_documentation_caps(t: [*c]Template, caps: [*c]c.GstCaps) void {
    if (!check.that(isTemplate(t), "gst_pad_template_set_documentation_caps", "GST_IS_PAD_TEMPLATE (templ)")) return;
    if (!check.that(caps != null and caps[0].mini_object.type == c._gst_caps_type, "gst_pad_template_set_documentation_caps", "GST_IS_CAPS (caps)")) return;
    caps[0].mini_object.flags |= c.GST_MINI_OBJECT_FLAG_MAY_BE_LEAKED;
    _ = c.gst_caps_replace(&t[0].ABI.abi.documentation_caps, caps);
}

pub export fn gst_pad_template_get_documentation_caps(t: [*c]Template) [*c]c.GstCaps {
    if (!check.that(isTemplate(t), "gst_pad_template_get_documentation_caps", "GST_IS_PAD_TEMPLATE (templ)")) return null;
    if (t[0].ABI.abi.documentation_caps != null) return c.gst_caps_ref(t[0].ABI.abi.documentation_caps);
    return gst_pad_template_get_caps(t);
}

pub export fn gst_pad_template_pad_created(t: [*c]Template, p: ?*c.GstPad) void {
    c.g_signal_emit(t, created_signal, 0, p);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const t: [*c]Template = @ptrCast(@alignCast(o));
    switch (id) {
        PROP_NAME_TEMPLATE => t[0].name_template = c.g_value_dup_string(v),
        PROP_DIRECTION => t[0].direction = @intCast(c.g_value_get_enum(v)),
        PROP_PRESENCE => t[0].presence = @intCast(c.g_value_get_enum(v)),
        PROP_CAPS => {
            t[0].caps = @ptrCast(@alignCast(c.g_value_dup_boxed(v)));
            if (t[0].caps != null) t[0].caps[0].mini_object.flags |= c.GST_MINI_OBJECT_FLAG_MAY_BE_LEAKED;
        },
        PROP_GTYPE => t[0].ABI.abi.gtype = c.g_value_get_gtype(v),
        else => object.warnBadProperty(o, id, pspec),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const t: [*c]Template = @ptrCast(@alignCast(o));
    switch (id) {
        PROP_NAME_TEMPLATE => c.g_value_set_string(v, t[0].name_template),
        PROP_DIRECTION => c.g_value_set_enum(v, @intCast(t[0].direction)),
        PROP_PRESENCE => c.g_value_set_enum(v, @intCast(t[0].presence)),
        PROP_CAPS => c.g_value_set_boxed(v, t[0].caps),
        PROP_GTYPE => c.g_value_set_gtype(v, t[0].ABI.abi.gtype),
        else => object.warnBadProperty(o, id, pspec),
    }
}
