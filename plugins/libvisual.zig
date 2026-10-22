const std = @import("std");
const cm = @import("common.zig");
const c = cm.c;
const build = @import("build_options");
const lv = @import("libvisual/lv.zig").p;
const visual = @import("libvisual/visual.zig");

var cat: ?*c.GstDebugCategory = null;

fn logHandler(message: [*c]const u8, funcname: [*c]const u8, priv: ?*anyopaque) callconv(.c) void {
    const level: c.GstDebugLevel = @intCast(@intFromPtr(priv));
    if (level <= c._gst_debug_min) c.gst_debug_log(cat, level, "../ext/libvisual/plugin.c", "libvisual_log_handler", 33, null, "%s - %s", funcname, message);
}

fn validName(name: [*c]u8) void {
    var p = name;
    while (p[0] != 0) : (p += 1) {
        const ch = p[0];
        const ok = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '+';
        if (!ok) p[0] = '_';
    }
}

fn isGl(plugin: ?*lv.VisObject) bool {
    const actor: *lv.VisActorPlugin = @ptrCast(@alignCast(plugin));
    return actor.vidoptions.depth & lv.VISUAL_VIDEO_DEPTH_GL == lv.VISUAL_VIDEO_DEPTH_GL;
}

fn pluginInit(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    cat = c._gst_debug_category_new("libvisual", 0, "libvisual audio visualisations");
    _ = lv.visual_log_set_verboseness(lv.VISUAL_LOG_VERBOSENESS_LOW);
    _ = lv.visual_log_set_info_handler(logHandler, @ptrFromInt(c.GST_LEVEL_INFO));
    _ = lv.visual_log_set_warning_handler(logHandler, @ptrFromInt(c.GST_LEVEL_WARNING));
    _ = lv.visual_log_set_critical_handler(logHandler, @ptrFromInt(c.GST_LEVEL_ERROR));
    _ = lv.visual_log_set_error_handler(logHandler, @ptrFromInt(c.GST_LEVEL_ERROR));
    if (lv.visual_is_initialized() == 0) {
        if (lv.visual_init(null, null) != 0) return 0;
    }
    const list = lv.visual_actor_get_list();
    const count: c_int = lv.visual_collection_size(@ptrCast(list));
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        const ref: ?*lv.VisPluginRef = @ptrCast(@alignCast(lv.visual_list_get(list, i)));
        const vp = lv.visual_plugin_load(ref);
        if (ref.?.info[0].plugname == null) continue;
        var skip = false;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(ref.?.info[0].plugname)));
        if (std.mem.eql(u8, name, "gstreamer") or std.mem.eql(u8, name, "gdkpixbuf")) {
            skip = true;
        } else skip = isGl(vp[0].info[0].plugin);
        _ = lv.visual_plugin_unload(vp);
        if (skip) continue;
        const info = c.GTypeInfo{
            .class_size = @sizeOf(visual.Class),
            .base_init = null,
            .base_finalize = null,
            .class_init = visual.classInit,
            .class_finalize = null,
            .class_data = ref,
            .instance_size = @sizeOf(visual.Self),
            .n_preallocs = 0,
            .instance_init = null,
            .value_table = null,
        };
        var tn = c.g_strdup_printf("GstVisual%s", ref.?.info[0].plugname);
        validName(tn);
        const t = c.g_type_register_static(visual.getType(), tn, &info, 0);
        c.g_free(tn);
        tn = c.g_strdup_printf("libvisual_%s", ref.?.info[0].plugname);
        validName(tn);
        const ok = c.gst_element_register(p, tn, c.GST_RANK_NONE, t) != 0;
        c.g_free(tn);
        if (!ok) return 0;
    }
    return 1;
}

var desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "libvisual",
    .description = "libvisual visualization plugins",
    .plugin_init = pluginInit,
    .version = "1.28.2",
    .license = "LGPL",
    .source = "gst-plugins-base",
    .package = build.package ++ "",
    .origin = build.origin ++ "",
    .release_datetime = null,
    ._gst_reserved = std.mem.zeroes([4]c.gpointer),
};

pub export fn gst_plugin_libvisual_get_desc() *const c.GstPluginDesc {
    return &desc;
}

pub export fn gst_plugin_libvisual_register() void {
    _ = c.gst_plugin_register_static(desc.major_version, desc.minor_version, desc.name, desc.description, desc.plugin_init, desc.version, desc.license, desc.source, desc.package, desc.origin);
}
