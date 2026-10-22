const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../gst/playback/gstsubtitleoverlay.c";
const N: ?*anyopaque = null;
const MARK = "gst-subtitle-overlay-event-marker";

const PROP_SILENT = 1;
const PROP_FONT_DESC = 2;
const PROP_SUBTITLE_ENCODING = 3;
const PROP_SUBTITLE_TS_OFFSET = 4;

pub const Self = extern struct {
    parent: c.GstBin,
    silent: c.gboolean,
    font_desc: [*c]u8,
    encoding: [*c]u8,
    ts_offset: i64,
    do_async: c.gboolean,
    srcpad: ?*c.GstPad,
    downstream_error: c.gboolean,
    video_sinkpad: ?*c.GstPad,
    video_block_pad: ?*c.GstPad,
    video_block: c.gulong,
    video_blocked: c.gboolean,
    fps_n: c.gint,
    fps_d: c.gint,
    sub_sinkpad: ?*c.GstPad,
    sub_block_pad: ?*c.GstPad,
    sub_block: c.gulong,
    sub_blocked: c.gboolean,
    sub_flush: c.gboolean,
    sub_error: c.gboolean,
    factories_lock: c.GMutex,
    factories: [*c]c.GList,
    cookie: u32,
    factory_caps: [*c]c.GstCaps,
    lock: c.GMutex,
    subcaps: [*c]c.GstCaps,
    passthrough: ?*c.GstElement,
    pre_conv: ?*c.GstElement,
    post_conv: ?*c.GstElement,
    parser: ?*c.GstElement,
    overlay: ?*c.GstElement,
    renderer: ?*c.GstElement,
    silent_prop: [*c]const u8,
    silent_invert: c.gboolean,
};

const Class = extern struct {
    parent: c.GstBinClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var video_t = cm.staticTemplate("video_sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var sub_t = cm.staticTemplate("subtitle_sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var sw_once: usize = 0;
var sw_caps_val: [*c]c.GstCaps = null;

fn swCaps() [*c]c.GstCaps {
    if (c.g_once_init_enter(&sw_once) != 0) {
        var n: c.guint = 0;
        const list = c.gst_video_formats_raw(&n);
        const str = c.g_string_new("video/x-raw, format=(string){ ");
        var i: c.guint = 0;
        while (i < n) : (i += 1) {
            if (i > 0) _ = c.g_string_append(str, ", ");
            _ = c.g_string_append(str, c.gst_video_format_to_string(list[i]));
        }
        _ = c.g_string_append(str, " }, width=(int)[ 1, max ], height=(int)[ 1, max ], framerate=(fraction)[ 0, max ]");
        sw_caps_val = c.gst_caps_from_string(str.*.str);
        sw_caps_val.*.mini_object.flags |= c.GST_MINI_OBJECT_FLAG_MAY_BE_LEAKED;
        _ = c.g_string_free(str, 1);
        c.g_once_init_leave(&sw_once, 1);
    }
    return c.gst_caps_ref(sw_caps_val);
}

var once: cm.Once = .{};
var parent_class: ?*c.GstBinClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn elem(p: anytype) *c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn ghost(p: ?*c.GstPad) ?*c.GstGhostPad {
    return @ptrCast(@alignCast(p));
}

fn gobj(p: anytype) *c.GObject {
    return @ptrCast(@alignCast(p));
}

fn lock(s: *Self) void {
    c.g_mutex_lock(&s.lock);
}

fn unlock(s: *Self) void {
    c.g_mutex_unlock(&s.lock);
}

fn asyncStart(s: *Self) void {
    if (s.do_async != 0) return;
    parent_class.?.handle_message.?(@ptrCast(s), c.gst_message_new_async_start(cm.obj(s)));
    s.do_async = 1;
}

fn asyncDone(s: *Self) void {
    if (s.do_async == 0) return;
    parent_class.?.handle_message.?(@ptrCast(s), c.gst_message_new_async_done(cm.obj(s), cm.CLOCK_NONE));
    s.do_async = 0;
}

fn block(s: *Self, pad: ?*c.GstPad, id: *c.gulong) void {
    if (id.* != 0 or pad == null) return;
    id.* = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_BLOCK_DOWNSTREAM, padBlocked, s, null);
}

fn blockBoth(s: *Self) void {
    block(s, s.sub_block_pad, &s.sub_block);
    block(s, s.video_block_pad, &s.video_block);
}

fn unblockBoth(s: *Self) void {
    if (s.video_block != 0) {
        c.gst_pad_remove_probe(s.video_block_pad, s.video_block);
        s.video_blocked = 0;
        s.video_block = 0;
    }
    if (s.sub_block != 0) {
        c.gst_pad_remove_probe(s.sub_block_pad, s.sub_block);
        s.sub_blocked = 0;
        s.sub_block = 0;
    }
}

fn padSupports(pad: ?*c.GstPad, caps: [*c]c.GstCaps) bool {
    const pc = c.gst_pad_query_caps(pad, null);
    defer c.gst_caps_unref(pc);
    return c.gst_caps_is_subset(caps, pc) != 0;
}

fn klassHas(f: *c.GstElementFactory, comptime parts: []const [*:0]const u8) bool {
    const klass = c.gst_element_factory_get_metadata(f, c.GST_ELEMENT_METADATA_KLASS);
    if (klass == null) return false;
    inline for (parts) |p| if (c.strstr(klass, p) != null) return true;
    return false;
}

fn featureName(f: anytype) []const u8 {
    return std.mem.span(@as(*c.GstObject, @ptrCast(@alignCast(f))).name);
}

fn isRenderer(f: *c.GstElementFactory) bool {
    if (c.gst_element_factory_get_metadata(f, c.GST_ELEMENT_METADATA_KLASS) == null) return false;
    return klassHas(f, &.{ "Overlay/Subtitle", "Overlay/SubPicture" }) or std.mem.eql(u8, featureName(f), "textoverlay");
}

fn isParserDecoder(f: *c.GstElementFactory) bool {
    return klassHas(f, &.{ "Parser/Subtitle", "Decoder/Subtitle" });
}

const sub_pad_names = [_][*:0]const u8{ "subpicture", "subpicture_sink", "text", "text_sink", "subtitle_sink", "subtitle", "cc_sink" };

fn isVideoPad(pad: ?*c.GstPad) bool {
    var caps: [*c]c.GstCaps = null;
    if (c.gst_pad_get_peer(pad)) |peer| {
        caps = c.gst_pad_get_current_caps(peer);
        if (caps == null) caps = c.gst_pad_query_caps(peer, null);
        c.gst_object_unref(peer);
    } else caps = c.gst_pad_query_caps(pad, null);
    defer c.gst_caps_unref(caps);
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(caps)) : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(c.gst_structure_get_name(c.gst_caps_get_structure(caps, i))), "video/x-raw")) return true;
    }
    return false;
}

fn subCaps(f: *c.GstElementFactory) [*c]c.GstCaps {
    const pd = isParserDecoder(f);
    var l: ?*const c.GList = c.gst_element_factory_get_static_pad_templates(f);
    while (l) |n| : (l = n.next) {
        const t: *c.GstStaticPadTemplate = @ptrCast(@alignCast(n.data));
        if (t.direction != c.GST_PAD_SINK or t.presence != c.GST_PAD_ALWAYS) continue;
        var found = pd;
        if (!found) {
            for (sub_pad_names) |name| {
                if (std.mem.eql(u8, std.mem.span(t.name_template), std.mem.span(name))) {
                    found = true;
                    break;
                }
            }
        }
        if (found) return c.gst_static_caps_get(&t.static_caps);
    }
    return null;
}

fn factoryFilter(feature: ?*c.GstPluginFeature, data: c.gpointer) callconv(.c) c.gboolean {
    if (!cm.isA(feature, c.gst_element_factory_get_type())) return 0;
    const f: *c.GstElementFactory = @ptrCast(@alignCast(feature));
    if (!std.mem.eql(u8, featureName(f), "textoverlay") and c.gst_plugin_feature_get_rank(feature) < c.GST_RANK_MARGINAL) return 0;
    const renderer = if (isRenderer(f)) true else if (isParserDecoder(f)) false else return 0;
    var have_video = false;
    if (renderer) {
        var l: ?*const c.GList = c.gst_element_factory_get_static_pad_templates(f);
        while (l) |n| : (l = n.next) {
            const t: *c.GstStaticPadTemplate = @ptrCast(@alignCast(n.data));
            if (t.direction != c.GST_PAD_SINK or t.presence != c.GST_PAD_ALWAYS) continue;
            const name = std.mem.span(t.name_template);
            if (std.mem.eql(u8, name, "video") or std.mem.eql(u8, name, "video_sink")) have_video = true;
        }
    }
    const caps = subCaps(f);
    const out: *[*c]c.GstCaps = @ptrCast(@alignCast(data));
    if (caps != null and renderer == have_video) {
        out.* = c.gst_caps_merge(out.*, caps);
        return 1;
    }
    if (caps != null) c.gst_caps_unref(caps);
    return 0;
}

fn updateFactories(s: *Self) bool {
    const reg = c.gst_registry_get();
    const cookie = c.gst_registry_get_feature_list_cookie(reg);
    if (s.factories == null or s.cookie != cookie) {
        var caps = c.gst_caps_new_empty();
        const list = c.gst_registry_feature_filter(reg, factoryFilter, 0, @ptrCast(&caps));
        _ = c.gst_caps_replace(&s.factory_caps, caps);
        c.gst_caps_unref(caps);
        if (s.factories != null) c.gst_plugin_feature_list_free(s.factories);
        s.factories = list;
        s.cookie = cookie;
    }
    return s.factories != null;
}

var cache_lock: c.GMutex = std.mem.zeroes(c.GMutex);
var cache_caps: [*c]c.GstCaps = null;
var cache_cookie: u32 = 0;

pub fn factoryCaps() [*c]c.GstCaps {
    const reg = c.gst_registry_get();
    const cookie = c.gst_registry_get_feature_list_cookie(reg);
    c.g_mutex_lock(&cache_lock);
    defer c.g_mutex_unlock(&cache_lock);
    if (cache_caps == null or cache_cookie != cookie) {
        if (cache_caps != null) c.gst_caps_unref(cache_caps);
        cache_caps = c.gst_caps_new_empty();
        cache_caps.*.mini_object.flags |= c.GST_MINI_OBJECT_FLAG_MAY_BE_LEAKED;
        c.gst_plugin_feature_list_free(c.gst_registry_feature_filter(reg, factoryFilter, 0, @ptrCast(&cache_caps)));
        cache_cookie = cookie;
    }
    return c.gst_caps_ref(cache_caps);
}

fn factoriesFor(list: [*c]c.GList, caps: [*c]c.GstCaps) [*c]c.GList {
    var out: [*c]c.GList = null;
    var l = list;
    while (l != null) : (l = l.*.next) {
        const f: *c.GstElementFactory = @ptrCast(@alignCast(l.*.data));
        const fc = subCaps(f);
        const ok = fc != null and c.gst_caps_is_subset(caps, fc) != 0;
        if (fc != null) c.gst_caps_unref(fc);
        if (ok) out = c.g_list_prepend(out, c.gst_object_ref(f));
    }
    return out;
}

fn byRank(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const fa: ?*c.GstPluginFeature = @ptrCast(@alignCast(@constCast(a)));
    const fb: ?*c.GstPluginFeature = @ptrCast(@alignCast(@constCast(b)));
    const d = @as(c.gint, @intCast(c.gst_plugin_feature_get_rank(fb))) - @as(c.gint, @intCast(c.gst_plugin_feature_get_rank(fa)));
    if (d != 0) return d;
    return c.strcmp(cm.obj(fa).name, cm.obj(fb).name);
}

fn firstPad(e: ?*c.GstElement, names: []const [*:0]const u8) ?*c.GstPad {
    for (names) |n| if (c.gst_element_get_static_pad(e, n)) |p| return p;
    return null;
}

fn subPad(e: ?*c.GstElement) ?*c.GstPad {
    return firstPad(e, &sub_pad_names);
}

fn videoPad(e: ?*c.GstElement) ?*c.GstPad {
    return firstPad(e, &.{ "video", "video_sink" });
}

fn coreMsg(s: *Self, err: bool, code: c.gint, dbg: [*c]u8, comptime func: []const u8, line: c.gint) void {
    if (err) cm.elementError(s, c.gst_core_error_quark(), code, null, dbg, FILE, func, line) else cm.elementWarning(s, c.gst_core_error_quark(), code, null, dbg, FILE, func, line);
}

fn create(s: *Self, slot: *?*c.GstElement, name: ?[*:0]const u8, factory: ?*c.GstElementFactory, el_name: [*c]const u8, mandatory: bool) bool {
    const fname: [*c]const u8 = name orelse cm.obj(factory).name;
    const e = if (name) |n| c.gst_element_factory_make(n, el_name) else c.gst_element_factory_create(factory, el_name);
    if (e == null) {
        if (factory == null) {
            _ = c.gst_element_post_message(elem(s), c.gst_missing_element_message_new(elem(s), fname));
            coreMsg(s, mandatory, c.GST_CORE_ERROR_MISSING_PLUGIN, c.g_strdup_printf("no '%s' plugin found", fname), "_create_element", if (mandatory) 566 else 569);
        } else {
            coreMsg(s, mandatory, c.GST_CORE_ERROR_FAILED, c.g_strdup_printf("can't instantiate '%s'", fname), "_create_element", if (mandatory) 573 else 576);
        }
        return false;
    }
    if (c.gst_element_set_state(e, c.GST_STATE_READY) != c.GST_STATE_CHANGE_SUCCESS) {
        c.gst_object_unref(e);
        if (mandatory) coreMsg(s, true, c.GST_CORE_ERROR_STATE_CHANGE, c.g_strdup_printf("failed to set '%s' to READY", fname), "_create_element", 588);
        return false;
    }
    if (c.gst_bin_add(@ptrCast(s), @ptrCast(@alignCast(c.gst_object_ref(e)))) == 0) {
        _ = c.gst_element_set_state(e, c.GST_STATE_NULL);
        c.gst_object_unref(e);
        if (mandatory) coreMsg(s, true, c.GST_CORE_ERROR_FAILED, c.g_strdup_printf("failed to add '%s' to subtitleoverlay", fname), "_create_element", 600);
        return false;
    }
    _ = c.gst_element_sync_state_with_parent(e);
    slot.* = e;
    return true;
}

fn remove(s: *Self, slot: *?*c.GstElement) void {
    const e = slot.* orelse return;
    _ = c.gst_bin_remove(@ptrCast(s), e);
    _ = c.gst_element_set_state(e, c.GST_STATE_NULL);
    c.gst_object_unref(e);
    slot.* = null;
}

fn untarget(s: *Self) void {
    _ = c.gst_ghost_pad_set_target(ghost(s.srcpad), null);
    _ = c.gst_ghost_pad_set_target(ghost(s.video_sinkpad), null);
    _ = c.gst_ghost_pad_set_target(ghost(s.sub_sinkpad), null);
    s.silent_prop = null;
}

fn clearAll(s: *Self) void {
    untarget(s);
    remove(s, &s.post_conv);
    remove(s, &s.overlay);
    remove(s, &s.parser);
    remove(s, &s.renderer);
    remove(s, &s.pre_conv);
    remove(s, &s.passthrough);
}

fn passthrough(s: *Self) bool {
    if (s.passthrough == null) {
        clearAll(s);
        if (!create(s, &s.passthrough, "identity", null, "passthrough-identity", true)) return false;
        c.g_object_set(gobj(s.passthrough), "silent", @as(c.gboolean, 1), "signal-handoffs", @as(c.gboolean, 0), N);
        const src = c.gst_element_get_static_pad(s.passthrough, "src") orelse {
            coreMsg(s, true, c.GST_CORE_ERROR_PAD, c.g_strdup("Failed to get srcpad from identity"), "_setup_passthrough", 662);
            return false;
        };
        const ok = c.gst_ghost_pad_set_target(ghost(s.srcpad), src) != 0;
        c.gst_object_unref(src);
        if (!ok) {
            coreMsg(s, true, c.GST_CORE_ERROR_PAD, c.g_strdup("Failed to set srcpad target"), "_setup_passthrough", 669);
            return false;
        }
        const sink = c.gst_element_get_static_pad(s.passthrough, "sink") orelse {
            coreMsg(s, true, c.GST_CORE_ERROR_PAD, c.g_strdup("Failed to get sinkpad from identity"), "_setup_passthrough", 678);
            return false;
        };
        const ok2 = c.gst_ghost_pad_set_target(ghost(s.video_sinkpad), sink) != 0;
        c.gst_object_unref(sink);
        if (!ok2) {
            coreMsg(s, true, c.GST_CORE_ERROR_PAD, c.g_strdup("Failed to set video sinkpad target"), "_setup_passthrough", 686);
            return false;
        }
    }
    unblockBoth(s);
    return true;
}

fn hasProp(o: ?*c.GstElement, name: [*c]const u8, t: c.GType) bool {
    const spec = c.g_object_class_find_property(@ptrCast(@alignCast(gobj(o).g_type_instance.g_class)), name) orelse return false;
    return spec.*.value_type == t;
}

fn setFps(s: *Self) void {
    if (s.parser == null or s.fps_d == 0) return;
    if (!hasProp(s.parser, "video-fps", c.gst_fraction_get_type())) return;
    c.g_object_set(gobj(s.parser), "video-fps", s.fps_n, s.fps_d, N);
}

fn updateOffset(s: *Self) void {
    const p = s.parser orelse return;
    const src = c.gst_element_get_static_pad(p, "src");
    c.gst_pad_set_offset(src, -%s.ts_offset);
    c.gst_object_unref(src);
}

fn peerCaps(pad: ?*c.GstPad, fixed_only: bool) [*c]c.GstCaps {
    const peer = c.gst_pad_get_peer(pad) orelse return null;
    defer c.gst_object_unref(peer);
    var caps = c.gst_pad_get_current_caps(peer);
    if (caps == null) {
        caps = c.gst_pad_query_caps(peer, null);
        if (fixed_only and c.gst_caps_is_fixed(caps) == 0) {
            c.gst_caps_unref(caps);
            caps = null;
        }
    }
    return caps;
}

fn setupParser(s: *Self) void {
    const vc = peerCaps(s.video_sinkpad, true);
    if (vc != null) {
        var n: c.gint = 0;
        var d: c.gint = 0;
        if (c.gst_structure_get_fraction(c.gst_caps_get_structure(vc, 0), "framerate", &n, &d) != 0) {
            s.fps_n = n;
            s.fps_d = d;
        }
        c.gst_caps_unref(vc);
    }
    if (hasProp(s.parser, "subtitle-encoding", c.G_TYPE_STRING)) c.g_object_set(gobj(s.parser), "subtitle-encoding", s.encoding, N);
    setFps(s);
}

fn setupRenderer(s: *Self, r: ?*c.GstElement) void {
    if (std.mem.eql(u8, featureName(c.gst_element_get_factory(r)), "textoverlay")) {
        c.gst_util_set_object_arg(gobj(r), "halignment", "center");
        c.gst_util_set_object_arg(gobj(r), "valignment", "bottom");
        c.g_object_set(gobj(r), "wait-text", @as(c.gboolean, 0), N);
        if (s.font_desc != null) c.g_object_set(gobj(r), "font-desc", s.font_desc, N);
        s.silent_prop = "silent";
        s.silent_invert = 0;
        return;
    }
    s.silent_prop = null;
    if (hasProp(r, "silent", c.G_TYPE_BOOLEAN)) {
        s.silent_prop = "silent";
        s.silent_invert = 0;
    } else if (hasProp(r, "enable", c.G_TYPE_BOOLEAN)) {
        s.silent_prop = "enable";
        s.silent_invert = 1;
    }
    if (hasProp(r, "subtitle-encoding", c.G_TYPE_STRING)) c.g_object_set(gobj(r), "subtitle-encoding", s.encoding, N);
    if (hasProp(r, "font-desc", c.G_TYPE_STRING)) c.g_object_set(gobj(r), "font-desc", s.font_desc, N);
}

fn linkPads(a: ?*c.GstPad, b: ?*c.GstPad) bool {
    const r = c.gst_pad_link(a, b) == c.GST_PAD_LINK_OK;
    c.gst_object_unref(a);
    c.gst_object_unref(b);
    return r;
}

fn linkRenderer(s: *Self, r: ?*c.GstElement, sub_src: ?*c.GstPad) bool {
    const video = isVideoPad(s.video_sinkpad);
    var src: ?*c.GstPad = null;
    if (video) {
        const vs = videoPad(r) orelse return false;
        const same = isVideoPad(vs);
        c.gst_object_unref(vs);
        if (!same) return false;
        if (!create(s, &s.post_conv, "videoconvert", null, "post-colorspace", false)) return false;
        const rsrc = c.gst_element_get_static_pad(r, "src") orelse return false;
        const psink = c.gst_element_get_static_pad(s.post_conv, "sink") orelse {
            c.gst_object_unref(rsrc);
            return false;
        };
        if (!linkPads(rsrc, psink)) return false;
        if (!create(s, &s.pre_conv, "videoconvert", null, "pre-colorspace", false)) return false;
        const rsink = videoPad(r) orelse return false;
        const psrc = c.gst_element_get_static_pad(s.pre_conv, "src") orelse {
            c.gst_object_unref(rsink);
            return false;
        };
        if (!linkPads(psrc, rsink)) return false;
        src = c.gst_element_get_static_pad(s.post_conv, "src") orelse return false;
    } else {
        const vc = peerCaps(s.video_sinkpad, false);
        const vs = videoPad(r) orelse {
            if (vc != null) c.gst_caps_unref(vc);
            return false;
        };
        const allowed = c.gst_pad_query_caps(vs, null);
        c.gst_object_unref(vs);
        const subset = allowed != null and vc != null and c.gst_caps_is_subset(vc, allowed) != 0;
        if (allowed != null) c.gst_caps_unref(allowed);
        if (vc != null) c.gst_caps_unref(vc);
        if (!subset) return false;
        src = c.gst_element_get_static_pad(r, "src") orelse return false;
    }
    const ok = c.gst_ghost_pad_set_target(ghost(s.srcpad), src) != 0;
    c.gst_object_unref(src);
    if (!ok) return false;
    const vsink = (if (s.pre_conv) |p| c.gst_element_get_static_pad(p, "sink") else videoPad(r)) orelse return false;
    const ok2 = c.gst_ghost_pad_set_target(ghost(s.video_sinkpad), vsink) != 0;
    c.gst_object_unref(vsink);
    if (!ok2) return false;
    const ssink = subPad(r) orelse return false;
    defer c.gst_object_unref(ssink);
    if (sub_src) |x| return c.gst_pad_link(x, ssink) == c.GST_PAD_LINK_OK;
    return c.gst_ghost_pad_set_target(ghost(s.sub_sinkpad), ssink) != 0;
}

fn tryParser(s: *Self) bool {
    setupParser(s);
    const src = c.gst_element_get_static_pad(s.parser, "src");
    const pcaps = c.gst_pad_query_caps(src, null);
    c.gst_object_unref(src);
    c.g_mutex_lock(&s.factories_lock);
    _ = updateFactories(s);
    var overlays = factoriesFor(s.factories, pcaps);
    c.g_mutex_unlock(&s.factories_lock);
    c.gst_caps_unref(pcaps);
    if (overlays == null) return false;
    overlays = c.g_list_sort(overlays, byRank);
    defer c.gst_plugin_feature_list_free(overlays);
    var found = false;
    var k = overlays;
    while (k != null) : (k = k.*.next) {
        untarget(s);
        remove(s, &s.post_conv);
        remove(s, &s.overlay);
        remove(s, &s.pre_conv);
        if (!create(s, &s.overlay, null, @ptrCast(@alignCast(k.*.data)), "overlay", false)) continue;
        setupRenderer(s, s.overlay);
        const psrc = c.gst_element_get_static_pad(s.parser, "src");
        const ok = linkRenderer(s, s.overlay, psrc);
        c.gst_object_unref(psrc);
        if (ok) {
            found = true;
            break;
        }
    }
    if (!found) return false;
    const sink = c.gst_element_get_static_pad(s.parser, "sink");
    defer c.gst_object_unref(sink);
    return c.gst_ghost_pad_set_target(ghost(s.sub_sinkpad), sink) != 0;
}

fn padBlocked(pad: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const s = me(data);
    if (cm.isEvent(info.*.data)) {
        if (!cm.eventSerialized(info.*.data)) return c.GST_PAD_PROBE_PASS;
        if (cm.eventType(info.*.data) == c.GST_EVENT_STREAM_START) return c.GST_PAD_PROBE_PASS;
    }
    lock(s);
    defer unlock(s);
    if (pad == s.video_block_pad) s.video_blocked = 1 else if (pad == s.sub_block_pad) s.sub_blocked = 1;
    var subcaps = s.subcaps;
    if (subcaps == null) {
        subcaps = peerCaps(s.sub_sinkpad, true);
        _ = c.gst_caps_replace(&s.subcaps, subcaps);
        if (subcaps != null) c.gst_caps_unref(subcaps);
    }
    if (subcaps == null and s.sub_blocked != 0) {
        coreMsg(s, false, c.GST_CORE_ERROR_NEGOTIATION, c.g_strdup("Subtitle sink is blocked but we have no subtitle caps"), "_pad_blocked_cb", 1086);
        subcaps = null;
    }
    if (s.sub_error != 0 or (s.silent != 0 and s.silent_prop == null)) {
        _ = passthrough(s);
        asyncDone(s);
        return c.GST_PAD_PROBE_OK;
    }
    if (subcaps != null and s.sub_flush == 0) {
        if (c.gst_ghost_pad_get_target(ghost(s.sub_sinkpad))) |target| {
            const ok = padSupports(target, subcaps);
            c.gst_object_unref(target);
            if (ok) {
                unblockBoth(s);
                return c.GST_PAD_PROBE_OK;
            }
        }
    }
    if (s.sub_blocked != 0 and s.video_blocked == 0) {
        block(s, s.video_block_pad, &s.video_block);
        return c.GST_PAD_PROBE_OK;
    }
    s.sub_flush = 0;
    var factories: [*c]c.GList = null;
    c.g_mutex_lock(&s.factories_lock);
    _ = updateFactories(s);
    if (subcaps != null) {
        factories = factoriesFor(s.factories, subcaps);
        if (factories == null) {
            _ = c.gst_element_post_message(elem(s), c.gst_missing_decoder_message_new(elem(s), subcaps));
            coreMsg(s, false, c.GST_CORE_ERROR_MISSING_PLUGIN, c.g_strdup("no suitable subtitle plugin found"), "_pad_blocked_cb", 1135);
            subcaps = null;
            s.sub_error = 1;
        }
    }
    c.g_mutex_unlock(&s.factories_lock);
    defer if (factories != null) c.gst_plugin_feature_list_free(factories);
    if (subcaps == null) {
        _ = passthrough(s);
        asyncDone(s);
        return c.GST_PAD_PROBE_OK;
    }
    factories = c.g_list_sort(factories, byRank);
    var found = false;
    var l = factories;
    while (l != null) : (l = l.*.next) {
        const f: *c.GstElementFactory = @ptrCast(@alignCast(l.*.data));
        const renderer = isRenderer(f);
        clearAll(s);
        if (renderer) {
            if (!create(s, &s.renderer, null, f, "renderer", false)) continue;
            setupRenderer(s, s.renderer);
            if (!linkRenderer(s, s.renderer, null)) continue;
        } else {
            if (!create(s, &s.parser, null, f, "parser", false)) continue;
            if (!tryParser(s)) continue;
        }
        found = true;
        break;
    }
    if (!found) {
        coreMsg(s, false, c.GST_CORE_ERROR_FAILED, c.g_strdup("Failed to find any usable factories"), "_pad_blocked_cb", 1303);
        s.sub_error = 1;
        _ = passthrough(s);
        asyncDone(s);
        return c.GST_PAD_PROBE_OK;
    }
    unblockBoth(s);
    updateOffset(s);
    asyncDone(s);
    return c.GST_PAD_PROBE_OK;
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    var ret: c.GstStateChangeReturn = c.GST_STATE_CHANGE_SUCCESS;
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => {
            c.g_mutex_lock(&s.factories_lock);
            const ok = updateFactories(s);
            c.g_mutex_unlock(&s.factories_lock);
            if (!ok) return c.GST_STATE_CHANGE_FAILURE;
            lock(s);
            block(s, s.video_block_pad, &s.video_block);
            block(s, s.sub_block_pad, &s.sub_block);
            unlock(s);
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            s.fps_n = 0;
            s.fps_d = 0;
            s.sub_flush = 0;
            s.sub_error = 0;
            s.downstream_error = 0;
            asyncStart(s);
            ret = c.GST_STATE_CHANGE_ASYNC;
        },
        else => {},
    }
    const bret = @as(*c.GstElementClass, @ptrCast(@alignCast(parent_class.?))).change_state.?(e, t);
    if (bret == c.GST_STATE_CHANGE_FAILURE) {
        asyncDone(s);
        return ret;
    } else if (bret == c.GST_STATE_CHANGE_ASYNC) {
        ret = bret;
    } else if (bret == c.GST_STATE_CHANGE_NO_PREROLL) {
        asyncDone(s);
        ret = bret;
    }
    switch (t) {
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            lock(s);
            block(s, s.video_block_pad, &s.video_block);
            block(s, s.sub_block_pad, &s.sub_block);
            unlock(s);
            asyncDone(s);
        },
        c.GST_STATE_CHANGE_READY_TO_NULL => {
            lock(s);
            _ = c.gst_caps_replace(&s.subcaps, null);
            _ = c.gst_ghost_pad_set_target(ghost(s.srcpad), null);
            _ = c.gst_ghost_pad_set_target(ghost(s.video_sinkpad), null);
            _ = c.gst_ghost_pad_set_target(ghost(s.sub_sinkpad), null);
            unblockBoth(s);
            clearAll(s);
            unlock(s);
        },
        else => {},
    }
    return ret;
}

fn within(src: ?*c.GstObject, e: ?*c.GstElement) bool {
    const x = e orelse return false;
    return c.gst_object_has_as_ancestor(src, cm.obj(x)) != 0;
}

fn handleMessage(b: [*c]c.GstBin, msg_in: [*c]c.GstMessage) callconv(.c) void {
    const s = me(b);
    var msg = msg_in;
    if (msg.*.type == c.GST_MESSAGE_ERROR) {
        const src = msg.*.src;
        if (src != null and (within(src, s.overlay) or within(src, s.parser) or within(src, s.renderer))) {
            var err: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            c.gst_message_parse_error(msg, &err, &dbg);
            const w = c.gst_message_new_warning(src, err, dbg);
            c.gst_message_unref(msg);
            c.g_error_free(err);
            c.g_free(dbg);
            msg = w;
            lock(s);
            s.sub_error = 1;
            blockBoth(s);
            unlock(s);
        }
    }
    parent_class.?.handle_message.?(b, msg);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_SILENT => c.g_value_set_boolean(v, s.silent),
        PROP_FONT_DESC => {
            lock(s);
            c.g_value_set_string(v, s.font_desc);
            unlock(s);
        },
        PROP_SUBTITLE_ENCODING => {
            lock(s);
            c.g_value_set_string(v, s.encoding);
            unlock(s);
        },
        PROP_SUBTITLE_TS_OFFSET => {
            lock(s);
            c.g_value_set_int64(v, s.ts_offset);
            unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 1509),
    }
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_SILENT => {
            lock(s);
            s.silent = c.g_value_get_boolean(v);
            if (s.silent_prop != null) {
                const val: c.gboolean = if (s.silent_invert != 0) @intFromBool(s.silent == 0) else s.silent;
                if (s.overlay) |x| c.g_object_set(gobj(x), s.silent_prop, val, N) else if (s.renderer) |x| c.g_object_set(gobj(x), s.silent_prop, val, N);
            } else blockBoth(s);
            unlock(s);
        },
        PROP_FONT_DESC => {
            lock(s);
            c.g_free(s.font_desc);
            s.font_desc = c.g_value_dup_string(v);
            if (s.overlay != null and hasProp(s.overlay, "font-desc", c.G_TYPE_STRING)) {
                c.g_object_set(gobj(s.overlay), "font-desc", s.font_desc, N);
            } else if (s.renderer != null and hasProp(s.renderer, "font-desc", c.G_TYPE_STRING)) {
                c.g_object_set(gobj(s.renderer), "font-desc", s.font_desc, N);
            }
            unlock(s);
        },
        PROP_SUBTITLE_ENCODING => {
            lock(s);
            c.g_free(s.encoding);
            s.encoding = c.g_value_dup_string(v);
            if (s.renderer != null and hasProp(s.renderer, "subtitle-encoding", c.G_TYPE_STRING)) c.g_object_set(gobj(s.renderer), "subtitle-encoding", s.encoding, N);
            if (s.parser != null and hasProp(s.parser, "subtitle-encoding", c.G_TYPE_STRING)) c.g_object_set(gobj(s.parser), "subtitle-encoding", s.encoding, N);
            unlock(s);
        },
        PROP_SUBTITLE_TS_OFFSET => {
            lock(s);
            s.ts_offset = c.g_value_get_int64(v);
            updateOffset(s);
            unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 1577),
    }
}

fn srcProxyChain(proxy: ?*c.GstPad, parent: ?*c.GstObject, buffer: ?*c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const gp: ?*c.GstPad = @ptrCast(@alignCast(parent));
    if (gp == null) {
        c.gst_buffer_unref(buffer);
        return c.GST_FLOW_ERROR;
    }
    const sp = c.gst_object_get_parent(cm.obj(gp));
    if (sp == null or me(sp).srcpad != gp) {
        c.gst_buffer_unref(buffer);
        if (sp) |x| c.gst_object_unref(x);
        return c.GST_FLOW_ERROR;
    }
    const s = me(sp);
    const r = c.gst_proxy_pad_chain_default(proxy, parent, buffer);
    if (r == c.GST_FLOW_ERROR) s.downstream_error = 1;
    c.gst_object_unref(sp);
    return r;
}

fn srcProxyEvent(proxy: ?*c.GstPad, parent: ?*c.GstObject, ev: ?*c.GstEvent) callconv(.c) c.gboolean {
    const gp: ?*c.GstPad = @ptrCast(@alignCast(parent));
    if (gp == null) {
        c.gst_event_unref(ev);
        return 0;
    }
    const sp = c.gst_object_get_parent(cm.obj(gp));
    defer if (sp != null) c.gst_object_unref(sp);
    if (sp == null or me(sp).srcpad != gp) {
        c.gst_event_unref(ev);
        return 0;
    }
    const st = c.gst_event_get_structure(ev);
    if (st != null and c.gst_structure_has_field(st, MARK) != 0) {
        c.gst_event_unref(ev);
        return 1;
    }
    return c.gst_pad_event_default(proxy, parent, ev);
}

fn videoSetCaps(s: *Self, caps: [*c]c.GstCaps) bool {
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) == 0) return false;
    const target = c.gst_ghost_pad_get_target(ghost(s.video_sinkpad));
    lock(s);
    if (target == null or !padSupports(target, caps)) blockBoth(s);
    if (s.fps_n != info.fps_n or s.fps_d != info.fps_d) {
        s.fps_n = info.fps_n;
        s.fps_d = info.fps_d;
        setFps(s);
    }
    unlock(s);
    if (target) |x| c.gst_object_unref(x);
    return true;
}

fn videoEvent(pad: ?*c.GstPad, parent: ?*c.GstObject, ev: ?*c.GstEvent) callconv(.c) c.gboolean {
    defer c.gst_event_unref(ev);
    if (cm.eventType(ev) == c.GST_EVENT_CAPS) {
        var caps: [*c]c.GstCaps = null;
        c.gst_event_parse_caps(ev, &caps);
        if (!videoSetCaps(me(parent), caps)) return 0;
    }
    return c.gst_pad_event_default(pad, parent, c.gst_event_ref(ev));
}

fn addFeature(caps: [*c]c.GstCaps, feature: [*c]const u8, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const n = c.gst_caps_copy(caps);
    var i: c.guint = 0;
    const size = c.gst_caps_get_size(n);
    while (i < size) : (i += 1) {
        const f = c.gst_caps_get_features(n, i);
        if (c.gst_caps_features_is_any(f) == 0) c.gst_caps_features_add(f, feature);
    }
    c.gst_caps_append(n, c.gst_caps_intersect_full(caps, filter, c.GST_CAPS_INTERSECT_FIRST));
    return n;
}

fn byFeature(caps: [*c]c.GstCaps, feature: [*c]const u8, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const n = c.gst_caps_new_empty();
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(caps)) : (i += 1) {
        const f = c.gst_caps_features_copy(c.gst_caps_get_features(caps, i));
        const simple = c.gst_caps_new_full(c.gst_structure_copy(c.gst_caps_get_structure(caps, i)), @as(?*c.GstStructure, null));
        c.gst_caps_set_features(simple, 0, f);
        var filtered: [*c]c.GstCaps = null;
        if (c.gst_caps_features_contains(f, feature) != 0) {
            c.gst_caps_append(n, c.gst_caps_copy(simple));
            c.gst_caps_features_remove(f, feature);
            filtered = c.gst_caps_ref(simple);
        } else filtered = c.gst_caps_intersect_full(simple, filter, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(simple);
        c.gst_caps_append(n, filtered);
    }
    return n;
}

fn videoSinkCaps(s: *Self, pad: ?*c.GstPad, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    var ofilter: [*c]c.GstCaps = null;
    if (filter != null) {
        const sw = swCaps();
        ofilter = addFeature(filter, c.GST_CAPS_FEATURE_META_GST_VIDEO_OVERLAY_COMPOSITION, sw);
        c.gst_caps_unref(sw);
    }
    const peer = c.gst_pad_peer_query_caps(s.srcpad, ofilter);
    if (ofilter != null) c.gst_caps_unref(ofilter);
    var caps: [*c]c.GstCaps = null;
    if (peer != null) {
        if (c.gst_caps_is_any(peer) != 0) {
            const t = c.gst_pad_get_pad_template_caps(s.srcpad);
            caps = c.gst_caps_copy(t);
            c.gst_caps_unref(t);
        } else {
            const sw = swCaps();
            caps = byFeature(peer, c.GST_CAPS_FEATURE_META_GST_VIDEO_OVERLAY_COMPOSITION, sw);
            c.gst_caps_unref(sw);
        }
        c.gst_caps_unref(peer);
    } else caps = c.gst_pad_get_pad_template_caps(pad);
    if (filter != null) {
        const x = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(caps);
        caps = x;
    }
    return caps;
}

fn videoQuery(pad: ?*c.GstPad, parent: ?*c.GstObject, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    if (cm.queryType(q) == c.GST_QUERY_CAPS) {
        if (c.gst_ghost_pad_get_target(ghost(pad))) |t| {
            const r = c.gst_pad_query_default(pad, parent, q);
            c.gst_object_unref(t);
            return r;
        }
        var filter: [*c]c.GstCaps = null;
        c.gst_query_parse_caps(q, &filter);
        const caps = videoSinkCaps(me(parent), pad, filter);
        c.gst_query_set_caps_result(q, caps);
        c.gst_caps_unref(caps);
        return 1;
    }
    return c.gst_pad_query_default(pad, parent, q);
}

fn videoChain(pad: ?*c.GstPad, parent: ?*c.GstObject, buffer: ?*c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(parent);
    const r = c.gst_proxy_pad_chain_default(pad, parent, buffer);
    if (s.downstream_error != 0 or s.passthrough != null) return r;
    if (r == c.GST_FLOW_ERROR) {
        lock(s);
        s.sub_error = 1;
        blockBoth(s);
        unlock(s);
        return c.GST_FLOW_OK;
    }
    return r;
}

fn subChain(pad: ?*c.GstPad, parent: ?*c.GstObject, buffer: ?*c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(parent);
    if (s.sub_error != 0) {
        c.gst_buffer_unref(buffer);
        return c.GST_FLOW_OK;
    }
    const r = c.gst_proxy_pad_chain_default(pad, parent, buffer);
    if (r == c.GST_FLOW_ERROR or r == c.GST_FLOW_NOT_NEGOTIATED) {
        lock(s);
        s.sub_error = 1;
        blockBoth(s);
        unlock(s);
        return c.GST_FLOW_OK;
    }
    return r;
}

fn subSetCaps(s: *Self, caps: [*c]c.GstCaps) void {
    const target = c.gst_ghost_pad_get_target(ghost(s.sub_sinkpad));
    defer if (target) |t| c.gst_object_unref(t);
    lock(s);
    defer unlock(s);
    _ = c.gst_caps_replace(&s.subcaps, caps);
    if (target != null and padSupports(target, caps)) return;
    s.sub_error = 0;
    blockBoth(s);
}

fn subLink(_: ?*c.GstPad, parent: ?*c.GstObject, peer: ?*c.GstPad) callconv(.c) c.GstPadLinkReturn {
    const s = me(parent);
    var caps = c.gst_pad_get_current_caps(peer);
    if (caps == null) {
        caps = c.gst_pad_query_caps(peer, null);
        if (c.gst_caps_is_fixed(caps) == 0) {
            c.gst_caps_unref(caps);
            caps = null;
        }
    }
    if (caps != null) {
        lock(s);
        _ = c.gst_caps_replace(&s.subcaps, caps);
        s.sub_error = 0;
        blockBoth(s);
        unlock(s);
        c.gst_caps_unref(caps);
    }
    return c.GST_PAD_LINK_OK;
}

fn subUnlink(_: ?*c.GstPad, parent: ?*c.GstObject) callconv(.c) void {
    const s = me(parent);
    _ = c.gst_caps_replace(&s.subcaps, null);
    lock(s);
    s.sub_error = 0;
    blockBoth(s);
    unlock(s);
}

fn subEvent(pad: ?*c.GstPad, parent: ?*c.GstObject, ev_in: ?*c.GstEvent) callconv(.c) c.gboolean {
    const s = me(parent);
    var ev = ev_in;
    if (cm.eventType(ev) == c.GST_EVENT_CUSTOM_DOWNSTREAM_OOB and c.gst_event_has_name(ev, "playsink-custom-subtitle-flush") != 0) {
        lock(s);
        s.sub_flush = 1;
        s.sub_error = 0;
        blockBoth(s);
        unlock(s);
        c.gst_event_unref(ev);
        return 1;
    }
    switch (cm.eventType(ev)) {
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(ev, &caps);
            subSetCaps(s, caps);
        },
        c.GST_EVENT_FLUSH_STOP, c.GST_EVENT_FLUSH_START, c.GST_EVENT_SEGMENT, c.GST_EVENT_EOS => {
            ev = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(ev)));
            c.gst_structure_set(c.gst_event_writable_structure(ev), MARK, c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), N);
        },
        else => {},
    }
    const r = c.gst_pad_event_default(pad, parent, c.gst_event_ref(ev));
    c.gst_event_unref(ev);
    return r;
}

fn subQuery(pad: ?*c.GstPad, parent: ?*c.GstObject, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    switch (cm.queryType(q)) {
        c.GST_QUERY_ACCEPT_CAPS => {
            c.gst_query_set_accept_caps_result(q, 1);
            return 1;
        },
        c.GST_QUERY_CAPS => {
            var filter: [*c]c.GstCaps = null;
            c.gst_query_parse_caps(q, &filter);
            var caps = factoryCaps();
            if (filter != null) {
                const x = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
                c.gst_caps_unref(caps);
                caps = x;
            }
            c.gst_query_set_caps_result(q, caps);
            c.gst_caps_unref(caps);
            return 1;
        },
        else => return c.gst_pad_query_default(pad, parent, q),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_mutex_clear(&s.lock);
    c.g_mutex_clear(&s.factories_lock);
    if (s.factories != null) c.gst_plugin_feature_list_free(s.factories);
    s.factories = null;
    _ = c.gst_caps_replace(&s.factory_caps, null);
    c.g_free(s.font_desc);
    s.font_desc = null;
    c.g_free(s.encoding);
    s.encoding = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent_class.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_SILENT, c.g_param_spec_boolean("silent", "Silent", "Whether to show subtitles", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_FONT_DESC, c.g_param_spec_string("font-desc", "Subtitle font description", "Pango font description of font to be used for subtitle rendering", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_SUBTITLE_ENCODING, c.g_param_spec_string("subtitle-encoding", "subtitle encoding", "Encoding to assume if input subtitles are not in UTF-8 encoding. If not set, the GST_SUBTITLE_ENCODING environment variable will be checked for an encoding to use. If that is not set either, ISO-8859-15 will be assumed.", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_SUBTITLE_TS_OFFSET, c.g_param_spec_int64("subtitle-ts-offset", "Subtitle Timestamp Offset", "The synchronisation offset between text and video in nanoseconds", std.math.minInt(i64), std.math.maxInt(i64), 0, cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &video_t);
    c.gst_element_class_add_static_pad_template(ec, &sub_t);
    c.gst_element_class_set_static_metadata(ec, "Subtitle Overlay", "Video/Overlay/Subtitle", "Overlays a video stream with subtitles", "Sebastian Dröge <sebastian.droege@collabora.co.uk>");
    ec.change_state = changeState;
    const bc: *c.GstBinClass = @ptrCast(@alignCast(k));
    bc.handle_message = handleMessage;
    _ = c._gst_debug_category_new("subtitleoverlay", 0, "Subtitle Overlay");
}

fn ghostFrom(t: *c.GstStaticPadTemplate, name: [*c]const u8) ?*c.GstPad {
    const templ = c.gst_static_pad_template_get(t);
    defer c.gst_object_unref(templ);
    return c.gst_ghost_pad_new_no_target_from_template(name, templ);
}

fn internal(p: ?*c.GstPad) ?*c.GstPad {
    const x: ?*c.GstPad = @ptrCast(@alignCast(c.gst_proxy_pad_get_internal(@ptrCast(@alignCast(p)))));
    c.gst_object_unref(x);
    return x;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    c.g_mutex_init(&s.lock);
    c.g_mutex_init(&s.factories_lock);
    s.srcpad = ghostFrom(&src_t, "src");
    const sp = internal(s.srcpad);
    c.gst_pad_set_event_function_full(sp, srcProxyEvent, null, null);
    c.gst_pad_set_chain_function_full(sp, srcProxyChain, null, null);
    _ = c.gst_element_add_pad(elem(s), s.srcpad);
    s.video_sinkpad = ghostFrom(&video_t, "video_sink");
    c.gst_pad_set_event_function_full(s.video_sinkpad, videoEvent, null, null);
    c.gst_pad_set_query_function_full(s.video_sinkpad, videoQuery, null, null);
    c.gst_pad_set_chain_function_full(s.video_sinkpad, videoChain, null, null);
    s.video_block_pad = internal(s.video_sinkpad);
    _ = c.gst_element_add_pad(elem(s), s.video_sinkpad);
    s.sub_sinkpad = ghostFrom(&sub_t, "subtitle_sink");
    c.gst_pad_set_link_function_full(s.sub_sinkpad, subLink, null, null);
    c.gst_pad_set_unlink_function_full(s.sub_sinkpad, subUnlink, null, null);
    c.gst_pad_set_event_function_full(s.sub_sinkpad, subEvent, null, null);
    c.gst_pad_set_query_function_full(s.sub_sinkpad, subQuery, null, null);
    c.gst_pad_set_chain_function_full(s.sub_sinkpad, subChain, null, null);
    s.sub_block_pad = internal(s.sub_sinkpad);
    _ = c.gst_element_add_pad(elem(s), s.sub_sinkpad);
    s.fps_n = 0;
    s.fps_d = 0;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_bin_get_type(), "GstSubtitleOverlay", Class, Self, classInit, init);
        }
    }.f);
}
