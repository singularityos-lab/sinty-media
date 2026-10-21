const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const info = @import("info.zig");
const frame = @import("frame.zig");
const format = @import("format.zig");
const pool = @import("pool.zig");
const meta = @import("meta.zig");
const color = @import("color.zig");
const chroma = @import("chroma.zig");
const converter = @import("converter.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Agg = c.GstVideoAggregator;
const AggClass = c.GstVideoAggregatorClass;
const PadClass = c.GstVideoAggregatorPadClass;
const CPadClass = c.GstVideoAggregatorConvertPadClass;
const PPadClass = c.GstVideoAggregatorParallelConvertPadClass;
const BAgg = c.GstAggregator;
const BAggClass = c.GstAggregatorClass;
const BPadClass = c.GstAggregatorPadClass;
const OPad = ?*c.GstVideoAggregatorPad;
const OCPad = ?*c.GstVideoAggregatorConvertPad;
const OBPad = ?*c.GstAggregatorPad;

const BPad = extern struct {
    parent: el.Pad,
    segment: c.GstSegment,
    priv: c.gpointer,
    reserved: [4]c.gpointer,
};

const Pad = extern struct {
    parent: BPad,
    info: c.GstVideoInfo,
    priv: c.gpointer,
    reserved: [4]c.gpointer,
};

const CPad = extern struct {
    parent: Pad,
    priv: c.gpointer,
    reserved: [4]c.gpointer,
};

const PPad = extern struct {
    parent: CPad,
};
const Buffer = c.GstBuffer;
const VFrame = c.GstVideoFrame;
const NONE = el.NONE;
const VNONE = @as(?*anyopaque, null);
const SEC: u64 = c.GST_SECOND;
const PATH = "../gst-libs/gst/video/gstvideoaggregator.c";
const NEED_DATA = c.GST_AGGREGATOR_FLOW_NEED_DATA;

const AggPrivate = struct {
    lock: c.GMutex,
    ts_offset: u64,
    nframes: u64,
    proportion: f64,
    earliest_time: u64,
    qos_processed: u64,
    qos_dropped: u64,
    current_caps: [*c]c.GstCaps,
    live: c.gboolean,
    supported_formats: ?*c.GPtrArray,
    task_pool: [*c]c.GstTaskPool,
    task_pool_from_context: bool,
    task_pool_from_persistent_context: bool,
};

const PadPrivate = struct {
    buffer: [*c]Buffer,
    caps: [*c]c.GstCaps,
    prepared_frame: VFrame,
    zorder: c.guint,
    repeat_after_eos: bool,
    max_last_buffer_repeat: u64,
    needs_alpha: bool,
    start_time: u64,
    end_time: u64,
    pending_vinfo: c.GstVideoInfo,
    pending_caps: [*c]c.GstCaps,
};

const CPadPrivate = struct {
    convert: ?*c.GstVideoConverter,
    conversion_info: c.GstVideoInfo,
    converted_buffer: [*c]Buffer,
    converter_config: ?*c.GstStructure,
    converter_config_changed: bool,
};

const PPadPrivate = struct {
    src_frame: VFrame,
    is_converting: bool,
};

var pad_once: gtype.Once = .{};
var pad_offset: c.gint = 0;
var pad_parent: ?*BPadClass = null;
var cpad_once: gtype.Once = .{};
var cpad_offset: c.gint = 0;
var cpad_parent: ?*PadClass = null;
var ppad_once: gtype.Once = .{};
var ppad_offset: c.gint = 0;
var ppad_parent: ?*CPadClass = null;
var agg_once: gtype.Once = .{};
var agg_offset: c.gint = 0;
var agg_parent: ?*BAggClass = null;

fn agg(p: anytype) [*c]Agg {
    return @ptrCast(@alignCast(p));
}

fn apriv(p: anytype) *AggPrivate {
    return @ptrCast(@alignCast(agg(p).*.priv));
}

fn vpad(p: anytype) [*c]Pad {
    return @ptrCast(@alignCast(p));
}

fn ppriv(p: anytype) *PadPrivate {
    return @ptrCast(@alignCast(vpad(p).*.priv));
}

fn cpriv(p: anytype) *CPadPrivate {
    return @ptrCast(@alignCast(@as([*c]CPad, @ptrCast(@alignCast(p))).*.priv));
}

fn pcpriv(p: anytype) *PPadPrivate {
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(@alignCast(p))) + @as(usize, @bitCast(@as(isize, ppad_offset)))));
}

fn padClass(p: anytype) *PadClass {
    return gtype.classPeek(PadClass, p);
}

fn aggClass(p: anytype) *AggClass {
    return gtype.classPeek(AggClass, p);
}

fn srcSegment(a: anytype) *c.GstSegment {
    return &@as(*BPad, @ptrCast(@alignCast(@as([*c]BAgg, @ptrCast(@alignCast(a)))[0].srcpad))).segment;
}

fn srcPad(a: anytype) ?*c.GstPad {
    return @as([*c]BAgg, @ptrCast(@alignCast(a)))[0].srcpad;
}

fn sinkpads(a: anytype) [*c]c.GList {
    return @as([*c]c.GstElement, @ptrCast(@alignCast(a)))[0].sinkpads;
}

fn vlock(a: anytype) void {
    c.g_mutex_lock(&apriv(a).lock);
}

fn vunlock(a: anytype) void {
    c.g_mutex_unlock(&apriv(a).lock);
}

fn isPad(p: anytype) bool {
    return gtype.instanceOf(p, gst_video_aggregator_pad_get_type());
}

fn isCPad(p: anytype) bool {
    return gtype.instanceOf(p, gst_video_aggregator_convert_pad_get_type());
}

fn replaceBuf(dst: *[*c]Buffer, src: [*c]Buffer) void {
    _ = c.gst_mini_object_replace(@ptrCast(dst), @ptrCast(src));
}

fn replaceCaps(dst: *[*c]c.GstCaps, src: [*c]c.GstCaps) void {
    _ = c.gst_mini_object_replace(@ptrCast(dst), @ptrCast(src));
}

fn padGetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const p = ppriv(o);
    switch (id) {
        1 => c.g_value_set_uint(v, p.zorder),
        2 => c.g_value_set_boolean(v, @intFromBool(p.repeat_after_eos)),
        3 => c.g_value_set_uint64(v, p.max_last_buffer_repeat),
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 139),
    }
}

fn zorderCompare(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    return @bitCast(ppriv(@constCast(a)).zorder -% ppriv(@constCast(b)).zorder);
}

fn padSetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const p = ppriv(o);
    switch (id) {
        1 => {
            const parent_obj = c.gst_object_get_parent(@ptrCast(o));
            if (parent_obj != null) {
                el.lock(parent_obj);
                p.zorder = c.g_value_get_uint(v);
                const e: [*c]c.GstElement = @ptrCast(@alignCast(parent_obj));
                e[0].sinkpads = c.g_list_sort(e[0].sinkpads, zorderCompare);
                el.unlock(parent_obj);
                c.gst_object_unref(parent_obj);
            } else p.zorder = c.g_value_get_uint(v);
        },
        2 => p.repeat_after_eos = c.g_value_get_boolean(v) != 0,
        3 => p.max_last_buffer_repeat = c.g_value_get_uint64(v),
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 181),
    }
}

fn flushPad(bp: OBPad, a: [*c]BAgg) callconv(.c) c.GstFlowReturn {
    resetQos(agg(a));
    const p = ppriv(bp);
    replaceBuf(&p.buffer, null);
    replaceCaps(&p.caps, null);
    p.start_time = NONE;
    p.end_time = NONE;
    return c.GST_FLOW_OK;
}

fn skipBuffer(bp: OBPad, a: [*c]BAgg, buffer: [*c]Buffer) callconv(.c) c.gboolean {
    const seg = srcSegment(a);
    if (seg.position != NONE and buffer[0].duration != NONE) {
        const st = c.gst_segment_to_running_time(&@as([*c]BPad, @ptrCast(@alignCast(bp)))[0].segment, c.GST_FORMAT_TIME, buffer[0].pts);
        const et = st +% buffer[0].duration;
        const ost = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, seg.position);
        return @intFromBool(et < ost);
    }
    return 0;
}

fn padPrepareFrame(pad: OPad, _: [*c]Agg, buffer: [*c]Buffer, prepared: [*c]VFrame) callconv(.c) c.gboolean {
    const p = vpad(pad);
    return frame.gst_video_frame_map(prepared, &p[0].info, buffer, c.GST_MAP_READ);
}

fn padCleanFrame(_: OPad, _: [*c]Agg, prepared: [*c]VFrame) callconv(.c) void {
    if (prepared[0].buffer != null) {
        frame.gst_video_frame_unmap(prepared);
        prepared[0] = std.mem.zeroes(VFrame);
    }
}

fn peekNextSample(_: [*c]BAgg, bp: OBPad) callconv(.c) ?*c.GstSample {
    const p = ppriv(bp);
    if (p.buffer != null) return c.gst_sample_new(p.buffer, p.caps, &@as([*c]BPad, @ptrCast(@alignCast(bp)))[0].segment, null);
    return null;
}

fn padClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    pad_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (pad_offset != 0) c.g_type_class_adjust_private_offset(k, &pad_offset);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    const bc: *BPadClass = @ptrCast(@alignCast(k));
    const vc: *PadClass = @ptrCast(@alignCast(k));
    oc.set_property = padSetProperty;
    oc.get_property = padGetProperty;
    const RWC = c.G_PARAM_READWRITE | c.GST_PARAM_CONTROLLABLE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, 1, c.g_param_spec_uint("zorder", "Z-Order", "Z Order of the picture", 0, std.math.maxInt(c.guint), 0, RWC));
    c.g_object_class_install_property(oc, 2, c.g_param_spec_boolean("repeat-after-eos", "Repeat After EOS", "Repeat the last frame after EOS until all pads are EOS", 0, RWC));
    c.g_object_class_install_property(oc, 3, c.g_param_spec_uint64("max-last-buffer-repeat", "Max Last Buffer Repeat", "Repeat last buffer for time (in ns, -1=until EOS), behaviour on EOS is not affected", 0, std.math.maxInt(u64), NONE, c.G_PARAM_READWRITE | c.GST_PARAM_MUTABLE_PLAYING | c.G_PARAM_STATIC_STRINGS));
    bc.flush = flushPad;
    bc.skip_buffer = skipBuffer;
    vc.prepare_frame = padPrepareFrame;
    vc.clean_frame = padCleanFrame;
}

fn padInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p = vpad(inst);
    p[0].priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, pad_offset))));
    const r = ppriv(p);
    r.zorder = 0;
    r.repeat_after_eos = false;
    r.max_last_buffer_repeat = NONE;
    r.prepared_frame = std.mem.zeroes(VFrame);
}

pub export fn gst_video_aggregator_pad_get_type() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_aggregator_pad_get_type, "GstVideoAggregatorPad", PadClass, Pad, padClassInit, padInit, 0);
            pad_offset = c.g_type_add_instance_private(t, @sizeOf(PadPrivate));
            return t;
        }
    }.f);
}

pub export fn gst_video_aggregator_pad_has_current_buffer(pad: OPad) c.gboolean {
    if (!check.that(isPad(pad), "gst_video_aggregator_pad_has_current_buffer", "GST_IS_VIDEO_AGGREGATOR_PAD (pad)")) return 0;
    return @intFromBool(ppriv(pad).buffer != null);
}

pub export fn gst_video_aggregator_pad_get_current_buffer(pad: OPad) [*c]Buffer {
    if (!check.that(isPad(pad), "gst_video_aggregator_pad_get_current_buffer", "GST_IS_VIDEO_AGGREGATOR_PAD (pad)")) return null;
    return ppriv(pad).buffer;
}

pub export fn gst_video_aggregator_pad_get_prepared_frame(pad: OPad) [*c]VFrame {
    if (!check.that(isPad(pad), "gst_video_aggregator_pad_get_prepared_frame", "GST_IS_VIDEO_AGGREGATOR_PAD (pad)")) return null;
    const p = ppriv(pad);
    return if (p.prepared_frame.buffer != null) &p.prepared_frame else null;
}

pub export fn gst_video_aggregator_pad_set_needs_alpha(pad: OPad, needs_alpha: c.gboolean) void {
    if (!check.that(isPad(pad), "gst_video_aggregator_pad_set_needs_alpha", "GST_IS_VIDEO_AGGREGATOR_PAD (pad)")) return;
    const p = ppriv(pad);
    if ((needs_alpha != 0) != p.needs_alpha) {
        const a = c.gst_object_get_parent(@ptrCast(@alignCast(pad)));
        p.needs_alpha = needs_alpha != 0;
        if (a != null) {
            c.gst_pad_mark_reconfigure(srcPad(a));
            c.gst_object_unref(a);
        }
    }
}

fn cpadFinalize(o: [*c]c.GObject) callconv(.c) void {
    const p = cpriv(o);
    if (p.convert) |cv| converter.gst_video_converter_free(cv);
    p.convert = null;
    if (p.converter_config) |s| c.gst_structure_free(s);
    p.converter_config = null;
    @as(*c.GObjectClass, @ptrCast(pad_parent)).finalize.?(o);
}

fn cpadUpdateInternal(pad: OPad) callconv(.c) void {
    const p = vpad(pad);
    el.lock(p);
    cpriv(p).converter_config_changed = true;
    el.unlock(p);
}

fn setupConversion(p: [*c]Pad, a: [*c]Agg, parallel: bool) bool {
    const cp = cpriv(p);
    el.lock(p);
    defer el.unlock(p);
    if (!cp.converter_config_changed) return true;
    const k = gtype.classPeek(CPadClass, p);
    var ci: c.GstVideoInfo = undefined;
    info.gst_video_info_init(&ci);
    k.create_conversion_info.?(@ptrCast(p), a, &ci);
    if (ci.finfo == null) return false;
    cp.converter_config_changed = false;
    cp.conversion_info = ci;
    if (cp.convert) |cv| converter.gst_video_converter_free(cv);
    cp.convert = null;
    if (info.gst_video_info_is_equal(&p[0].info, &cp.conversion_info) == 0 or cp.converter_config != null) {
        var cfg: ?*c.GstStructure = if (cp.converter_config) |s| c.gst_structure_copy(s) else null;
        if (parallel) {
            if (cfg == null) {
                cfg = c.gst_structure_new_static_str_empty("GstVideoConverterConfig");
                const n = c.gst_shared_task_pool_get_max_threads(@ptrCast(apriv(a).task_pool));
                c.gst_structure_set(cfg, c.GST_VIDEO_CONVERTER_OPT_THREADS, c.G_TYPE_UINT, n, VNONE);
            }
            c.gst_structure_set_static_str(cfg, c.GST_VIDEO_CONVERTER_OPT_ASYNC_TASKS, c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), VNONE);
        }
        cp.convert = @ptrCast(converter.gst_video_converter_new_with_pool(&p[0].info, &cp.conversion_info, cfg, apriv(a).task_pool));
        if (cp.convert == null) return false;
    }
    return true;
}

var conv_params = c.GstAllocationParams{ .flags = 0, .@"align" = 15, .prefix = 0, .padding = 0 };

fn newConverted(cp: *CPadPrivate, a: [*c]Agg) [*c]Buffer {
    var size: c.gint = @truncate(@as(i64, @bitCast(cp.conversion_info.size)));
    const outsize: c.guint = @truncate(a[0].info.size);
    if (size <= 0 or @as(c.guint, @bitCast(size)) < outsize) size = @bitCast(outsize);
    return c.gst_buffer_new_allocate(null, @intCast(@as(c.guint, @bitCast(size))), &conv_params);
}

fn cpadPrepareFrame(pad: OPad, a: [*c]Agg, buffer: [*c]Buffer, prepared: [*c]VFrame) callconv(.c) c.gboolean {
    const p = vpad(pad);
    if (!setupConversion(p, a, false)) return 0;
    const cp = cpriv(p);
    var fr: VFrame = undefined;
    if (frame.gst_video_frame_map(&fr, &p[0].info, buffer, c.GST_MAP_READ) == 0) return 0;
    if (cp.convert) |cv| {
        const cb = newConverted(cp, a);
        _ = converter.gst_video_converter_transform_metas(@ptrCast(cv), buffer, cb);
        var conv: VFrame = undefined;
        if (frame.gst_video_frame_map(&conv, &cp.conversion_info, cb, c.GST_MAP_READWRITE) == 0) {
            frame.gst_video_frame_unmap(&fr);
            return 0;
        }
        converter.gst_video_converter_frame(@ptrCast(cv), &fr, &conv);
        cp.converted_buffer = cb;
        frame.gst_video_frame_unmap(&fr);
        prepared[0] = conv;
    } else prepared[0] = fr;
    return 1;
}

fn cpadCleanFrame(pad: OPad, _: [*c]Agg, prepared: [*c]VFrame) callconv(.c) void {
    const p = vpad(pad);
    const cp = cpriv(p);
    if (prepared[0].buffer != null) {
        frame.gst_video_frame_unmap(prepared);
        prepared[0] = std.mem.zeroes(VFrame);
    }
    if (cp.converted_buffer != null) {
        c.gst_mini_object_unref(@ptrCast(cp.converted_buffer));
        cp.converted_buffer = null;
    }
}

fn createConversionInfo(pad: OCPad, a: [*c]Agg, ci: [*c]c.GstVideoInfo) callconv(.c) void {
    const fname = "gst_video_aggregator_convert_pad_create_conversion_info";
    if (!check.that(isCPad(pad), fname, "GST_IS_VIDEO_AGGREGATOR_CONVERT_PAD (pad)")) return;
    if (!check.that(ci != null, fname, "convert_info != NULL")) return;
    const p = vpad(pad);
    if (p[0].info.finfo == null or p[0].info.finfo[0].format == c.GST_VIDEO_FORMAT_UNKNOWN) return;
    if (a[0].info.finfo == null or a[0].info.finfo[0].format == c.GST_VIDEO_FORMAT_UNKNOWN) return;
    const colorimetry = color.gst_video_colorimetry_to_string(@ptrCast(&p[0].info.colorimetry));
    const ch = chroma.gst_video_chroma_site_to_string(p[0].info.chroma_site);
    const best_colorimetry = color.gst_video_colorimetry_to_string(@ptrCast(&a[0].info.colorimetry));
    const best_ch = chroma.gst_video_chroma_site_to_string(a[0].info.chroma_site);
    if (a[0].info.finfo[0].format != p[0].info.finfo[0].format or c.g_strcmp0(colorimetry, best_colorimetry) != 0 or c.g_strcmp0(ch, best_ch) != 0) {
        var t: c.GstVideoInfo = undefined;
        _ = info.gst_video_info_set_format(&t, a[0].info.finfo[0].format, @bitCast(p[0].info.width), @bitCast(p[0].info.height));
        t.chroma_site = a[0].info.chroma_site;
        t.colorimetry = a[0].info.colorimetry;
        t.par_n = p[0].info.par_n;
        t.par_d = p[0].info.par_d;
        t.fps_n = p[0].info.fps_n;
        t.fps_d = p[0].info.fps_d;
        t.flags = p[0].info.flags;
        t.interlace_mode = p[0].info.interlace_mode;
        ci[0] = t;
    } else ci[0] = p[0].info;
    c.g_free(colorimetry);
    c.g_free(best_colorimetry);
    c.g_free(ch);
    c.g_free(best_ch);
}

fn cpadGetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    if (id != 1) return el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 661);
    el.lock(o);
    if (cpriv(o).converter_config) |s| c.g_value_set_boxed(v, s);
    el.unlock(o);
}

fn cpadSetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    if (id != 1) return el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 682);
    const p = cpriv(o);
    el.lock(o);
    if (p.converter_config) |s| c.gst_structure_free(s);
    p.converter_config = @ptrCast(@alignCast(c.g_value_dup_boxed(v)));
    p.converter_config_changed = true;
    el.unlock(o);
}

fn cpadClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    cpad_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (cpad_offset != 0) c.g_type_class_adjust_private_offset(k, &cpad_offset);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    const vc: *PadClass = @ptrCast(@alignCast(k));
    const cc: *CPadClass = @ptrCast(@alignCast(k));
    oc.finalize = cpadFinalize;
    oc.get_property = cpadGetProperty;
    oc.set_property = cpadSetProperty;
    c.g_object_class_install_property(oc, 1, c.g_param_spec_boxed("converter-config", "Converter configuration", "A GstStructure describing the configuration that should be used when scaling and converting this pad's video frames", c.gst_structure_get_type(), c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS));
    vc.update_conversion_info = cpadUpdateInternal;
    vc.prepare_frame = cpadPrepareFrame;
    vc.clean_frame = cpadCleanFrame;
    cc.create_conversion_info = createConversionInfo;
}

fn cpadInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: [*c]CPad = @ptrCast(@alignCast(inst));
    p[0].priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, cpad_offset))));
    const r = cpriv(p);
    r.converted_buffer = null;
    r.convert = null;
    r.converter_config = null;
    r.converter_config_changed = false;
}

pub export fn gst_video_aggregator_convert_pad_get_type() c.GType {
    return cpad_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(gst_video_aggregator_pad_get_type, "GstVideoAggregatorConvertPad", CPadClass, CPad, cpadClassInit, cpadInit, 0);
            cpad_offset = c.g_type_add_instance_private(t, @sizeOf(CPadPrivate));
            return t;
        }
    }.f);
}

pub export fn gst_video_aggregator_convert_pad_update_conversion_info(pad: OCPad) void {
    if (!check.that(isCPad(pad), "gst_video_aggregator_convert_pad_update_conversion_info", "GST_IS_VIDEO_AGGREGATOR_CONVERT_PAD (pad)")) return;
    el.lock(pad);
    cpriv(pad).converter_config_changed = true;
    el.unlock(pad);
}

fn ppadStart(pad: OPad, a: [*c]Agg, buffer: [*c]Buffer, prepared: [*c]VFrame) callconv(.c) void {
    const p = vpad(pad);
    const pp = pcpriv(p);
    pp.src_frame = std.mem.zeroes(VFrame);
    pp.is_converting = false;
    if (!setupConversion(p, a, true)) return;
    const cp = cpriv(p);
    if (frame.gst_video_frame_map(&pp.src_frame, &p[0].info, buffer, c.GST_MAP_READ) == 0) return;
    if (cp.convert) |cv| {
        var cb = newConverted(cp, a);
        _ = converter.gst_video_converter_transform_metas(@ptrCast(cv), buffer, cb);
        if (frame.gst_video_frame_map(prepared, &cp.conversion_info, cb, c.GST_MAP_READWRITE) == 0) {
            c.gst_mini_object_unref(@ptrCast(cb));
            cb = null;
            frame.gst_video_frame_unmap(&pp.src_frame);
            pp.src_frame = std.mem.zeroes(VFrame);
            return;
        }
        converter.gst_video_converter_frame(@ptrCast(cv), &pp.src_frame, prepared);
        cp.converted_buffer = cb;
        pp.is_converting = true;
    } else {
        prepared[0] = pp.src_frame;
        pp.src_frame = std.mem.zeroes(VFrame);
    }
}

fn finishParallel(p: anytype) void {
    const pp = pcpriv(p);
    const cp = cpriv(p);
    if (cp.convert != null and pp.is_converting) {
        pp.is_converting = false;
        converter.gst_video_converter_frame_finish(@ptrCast(cp.convert));
        if (pp.src_frame.buffer != null) {
            frame.gst_video_frame_unmap(&pp.src_frame);
            pp.src_frame = std.mem.zeroes(VFrame);
        }
    }
}

fn ppadFinish(pad: OPad, _: [*c]Agg, _: [*c]VFrame) callconv(.c) void {
    const p = vpad(pad);
    finishParallel(p);
}

fn ppadFinalize(o: [*c]c.GObject) callconv(.c) void {
    finishParallel(o);
    @as(*c.GObjectClass, @ptrCast(ppad_parent)).finalize.?(o);
}

fn ppadClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    ppad_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (ppad_offset != 0) c.g_type_class_adjust_private_offset(k, &ppad_offset);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    const vc: *PadClass = @ptrCast(@alignCast(k));
    oc.finalize = ppadFinalize;
    vc.prepare_frame = null;
    vc.prepare_frame_start = ppadStart;
    vc.prepare_frame_finish = ppadFinish;
}

pub export fn gst_video_aggregator_parallel_convert_pad_get_type() c.GType {
    return ppad_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(gst_video_aggregator_convert_pad_get_type, "GstVideoAggregatorParallelConvertPad", PPadClass, PPad, ppadClassInit, null, 0);
            ppad_offset = c.g_type_add_instance_private(t, @sizeOf(PPadPrivate));
            return t;
        }
    }.f);
}

fn supportsFormat(a: [*c]Agg, f: c.GstVideoFormat) bool {
    const arr = apriv(a).supported_formats.?;
    for (0..arr.len) |i| {
        const fi: [*c]const c.GstVideoFormatInfo = @ptrCast(@alignCast(arr.pdata[i]));
        if (fi != null and fi[0].format == f) return true;
    }
    return false;
}

fn possibleCaps(vi: [*c]c.GstVideoInfo) [*c]c.GstCaps {
    const caps = info.gst_video_info_to_caps(vi);
    c.gst_structure_remove_fields(c.gst_caps_get_structure(caps, 0), "width", "height", "framerate", "pixel-aspect-ratio", "interlace-mode", VNONE);
    return caps;
}

fn canUse(downstream: [*c]c.GstCaps, vi: [*c]c.GstVideoInfo) bool {
    const pc = possibleCaps(vi);
    defer c.gst_caps_unref(pc);
    return c.gst_caps_can_intersect(downstream, pc) != 0;
}

fn hasAlpha(fi: [*c]const c.GstVideoFormatInfo) bool {
    return fi[0].flags & c.GST_VIDEO_FORMAT_FLAG_ALPHA != 0;
}

fn findBestFormat(a: [*c]Agg, downstream: [*c]c.GstCaps, best: [*c]c.GstVideoInfo, at_least_one_alpha: [*c]c.gboolean) callconv(.c) void {
    var need_alpha = false;
    var best_number: c.gint = 0;
    const table = c.g_hash_table_new(c.g_direct_hash, c.g_direct_equal);
    el.lock(a);
    var l = sinkpads(a);
    while (l != null) : (l = l[0].next) {
        const p: [*c]Pad = @ptrCast(@alignCast(l[0].data));
        var number: c.gint = 0;
        if (p[0].info.finfo == null) continue;
        if (hasAlpha(p[0].info.finfo)) at_least_one_alpha[0] = 1;
        if (need_alpha and !hasAlpha(p[0].info.finfo)) continue;
        const f = p[0].info.finfo[0].format;
        if (f == c.GST_VIDEO_FORMAT_UNKNOWN) continue;
        if (!isCPad(p) and !canUse(downstream, &p[0].info)) continue;
        if (supportsFormat(a, f)) {
            number = @intCast(@intFromPtr(c.g_hash_table_lookup(table, @ptrFromInt(@as(usize, f)))));
            number +%= p[0].info.width * p[0].info.height;
            _ = c.g_hash_table_replace(table, @ptrFromInt(@as(usize, f)), @ptrFromInt(@as(usize, @as(u32, @bitCast(number)))));
        }
        if (!need_alpha and ppriv(p).needs_alpha and !hasAlpha(p[0].info.finfo)) {
            need_alpha = true;
            _ = info.gst_video_info_set_format(best, c.GST_VIDEO_FORMAT_ARGB, @bitCast(p[0].info.width), @bitCast(p[0].info.height));
        } else if (!need_alpha and hasAlpha(p[0].info.finfo)) {
            need_alpha = true;
            best[0] = p[0].info;
            best_number = number;
        } else if (number > best_number) {
            best[0] = p[0].info;
            best_number = number;
        }
    }
    el.unlock(a);
    c.g_hash_table_unref(table);
    if (supportsFormat(a, best[0].finfo[0].format) and canUse(downstream, @ptrCast(best))) return;
    const arr = apriv(a).supported_formats.?;
    for (0..arr.len) |i| {
        const fi: [*c]const c.GstVideoFormatInfo = @ptrCast(@alignCast(arr.pdata[i]));
        if (!need_alpha or hasAlpha(fi)) {
            _ = info.gst_video_info_set_format(best, fi[0].format, @bitCast(best[0].width), @bitCast(best[0].height));
            if (canUse(downstream, @ptrCast(best))) return;
        }
    }
    info.gst_video_info_init(best);
}

fn fixateSrcCaps(a: [*c]BAgg, caps_in: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    var bw: c.gint = -1;
    var bh: c.gint = -1;
    var bn: c.gint = -1;
    var bd: c.gint = -1;
    var bfps: f64 = -1.0;
    el.lock(a);
    var l = sinkpads(a);
    while (l != null) : (l = l[0].next) {
        const p: [*c]Pad = @ptrCast(@alignCast(l[0].data));
        const n = p[0].info.fps_n;
        const d = p[0].info.fps_d;
        const w = p[0].info.width;
        const h = p[0].info.height;
        if (w == 0 or h == 0) continue;
        if (bw < w) bw = w;
        if (bh < h) bh = h;
        var cur: f64 = 0.0;
        if (d != 0) c.gst_util_fraction_to_double(n, d, &cur);
        if (bfps < cur) {
            bfps = cur;
            bn = n;
            bd = d;
        }
    }
    el.unlock(a);
    if (bn <= 0 or bd <= 0 or bfps == 0.0) {
        bn = 25;
        bd = 1;
    }
    var caps: [*c]c.GstCaps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(caps_in)));
    const s = c.gst_caps_get_structure(caps, 0);
    _ = c.gst_structure_fixate_field_nearest_int(s, "width", bw);
    _ = c.gst_structure_fixate_field_nearest_int(s, "height", bh);
    _ = c.gst_structure_fixate_field_nearest_fraction(s, "framerate", bn, bd);
    if (c.gst_structure_has_field(s, "pixel-aspect-ratio") != 0) _ = c.gst_structure_fixate_field_nearest_fraction(s, "pixel-aspect-ratio", 1, 1);
    caps = c.gst_caps_fixate(caps);
    return caps;
}

fn updateCapsDefault(a: [*c]Agg, caps: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const k = aggClass(a);
    var one_alpha: c.gboolean = 0;
    var best_format: c.GstVideoFormat = c.GST_VIDEO_FORMAT_UNKNOWN;
    var best: c.GstVideoInfo = undefined;
    info.gst_video_info_init(&best);
    if (k.find_best_format) |f| {
        f(a, caps, &best, &one_alpha);
        best_format = best.finfo[0].format;
    }
    if (best_format == c.GST_VIDEO_FORMAT_UNKNOWN) {
        const tmp = c.gst_caps_fixate(c.gst_caps_ref(caps));
        _ = info.gst_video_info_from_caps(&best, tmp);
        best_format = best.finfo[0].format;
        c.gst_caps_unref(tmp);
    }
    const color_name = color.gst_video_colorimetry_to_string(&best.colorimetry);
    const site = chroma.gst_video_chroma_site_to_string(best.chroma_site);
    var bfc = c.gst_caps_copy(caps);
    c.gst_caps_set_simple_static_str(bfc, "format", c.G_TYPE_STRING, format.gst_video_format_to_string(best_format), VNONE);
    var ret = c.gst_caps_intersect(bfc, caps);
    replaceCaps(&bfc, ret);
    if (ret != null) c.gst_caps_unref(ret);
    ret = null;
    if (site != null) c.gst_caps_set_simple_static_str(bfc, "chroma-site", c.G_TYPE_STRING, site, VNONE);
    if (color_name != null) c.gst_caps_set_simple_static_str(bfc, "colorimetry", c.G_TYPE_STRING, color_name, VNONE);
    c.g_free(color_name);
    c.g_free(site);
    return c.gst_caps_merge(bfc, c.gst_caps_ref(caps));
}

fn updateSrcCapsDefault(a: [*c]BAgg, caps: [*c]c.GstCaps, ret: [*c][*c]c.GstCaps) callconv(.c) c.GstFlowReturn {
    ret[0] = aggClass(a).update_caps.?(agg(a), caps);
    return c.GST_FLOW_OK;
}

fn updateConversion(_: [*c]c.GstElement, pad: ?*c.GstPad, _: c.gpointer) callconv(.c) c.gboolean {
    if (padClass(pad).update_conversion_info) |f| f(@ptrCast(pad));
    return 1;
}

fn negotiatedSrcCaps(a: [*c]BAgg, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const v = agg(a);
    const p = apriv(a);
    vlock(a);
    defer vunlock(a);
    var vi: c.GstVideoInfo = undefined;
    if (info.gst_video_info_from_caps(&vi, caps) == 0) return 0;
    if (v[0].info.fps_n != vi.fps_n or v[0].info.fps_d != vi.fps_d) {
        if (srcSegment(a).position != NONE) p.nframes = 0;
        resetQos(v);
    }
    el.lock(a);
    v[0].info = vi;
    el.unlock(a);
    _ = c.gst_element_foreach_sink_pad(@ptrCast(a), updateConversion, null);
    if (p.current_caps == null or c.gst_caps_is_equal(caps, p.current_caps) == 0) {
        replaceCaps(&p.current_caps, caps);
        c.gst_aggregator_set_src_caps(a, caps);
        const latency = c.gst_util_uint64_scale(SEC, @intCast(vi.fps_d), @intCast(vi.fps_n));
        c.gst_aggregator_set_latency(a, latency, latency);
    }
    return 1;
}

fn sinkpadsInterlaceMode(a: [*c]Agg, skip: [*c]Pad, mode: *c.GstVideoInterlaceMode) bool {
    el.lock(a);
    defer el.unlock(a);
    var l = sinkpads(a);
    while (l != null) : (l = l[0].next) {
        const p: [*c]Pad = @ptrCast(@alignCast(l[0].data));
        if (skip != null and p == skip) continue;
        if (p[0].info.finfo != null and p[0].info.finfo[0].format != c.GST_VIDEO_FORMAT_UNKNOWN) {
            mode.* = p[0].info.interlace_mode;
            return true;
        }
    }
    return false;
}

fn padSinkSetcaps(pad: [*c]Pad, a: [*c]Agg, caps: [*c]c.GstCaps) bool {
    var vi: c.GstVideoInfo = undefined;
    if (info.gst_video_info_from_caps(&vi, caps) == 0) return false;
    vlock(a);
    defer vunlock(a);
    var mode: c.GstVideoInterlaceMode = c.GST_VIDEO_INTERLACE_MODE_PROGRESSIVE;
    var has = false;
    if (a[0].info.finfo[0].format != c.GST_VIDEO_FORMAT_UNKNOWN) {
        mode = a[0].info.interlace_mode;
        has = true;
    } else has = sinkpadsInterlaceMode(a, pad, &mode);
    if (has and mode != vi.interlace_mode) return false;
    const p = ppriv(pad);
    if (pad[0].info.finfo == null or pad[0].info.finfo[0].format == c.GST_VIDEO_FORMAT_UNKNOWN) {
        pad[0].info = vi;
        replaceCaps(&p.caps, caps);
        c.gst_pad_mark_reconfigure(srcPad(a));
    } else {
        p.pending_vinfo = vi;
        replaceCaps(&p.pending_caps, caps);
    }
    return true;
}

fn formatInfoFromValue(v: [*c]const c.GValue) [*c]const c.GstVideoFormatInfo {
    return format.gst_video_format_get_info(format.gst_video_format_from_string(c.g_value_get_string(v)));
}

fn capsHasAlpha(caps: [*c]c.GstCaps) bool {
    for (0..c.gst_caps_get_size(caps)) |i| {
        const s = c.gst_caps_get_structure(caps, @intCast(i));
        const formats = c.gst_structure_get_value(s, "format");
        if (formats == null) return true;
        if (formats[0].g_type == c.gst_value_list_get_type()) {
            for (0..c.gst_value_list_get_size(formats)) |j| {
                if (hasAlpha(formatInfoFromValue(c.gst_value_list_get_value(formats, @intCast(j))))) return true;
            }
        } else if (c.g_type_check_value_holds(formats, c.G_TYPE_STRING) != 0) {
            if (hasAlpha(formatInfoFromValue(formats))) return true;
        } else unreachable;
    }
    return false;
}

fn nonAlphaCaps(caps: [*c]c.GstCaps) [*c]c.GstCaps {
    const result = c.gst_caps_new_empty();
    for (0..c.gst_caps_get_size(caps)) |i| {
        var s = c.gst_caps_get_structure(caps, @intCast(i));
        const formats = c.gst_structure_get_value(s, "format");
        if (formats == null) continue;
        var nf = std.mem.zeroes(c.GValue);
        var has = false;
        if (formats[0].g_type == c.gst_value_list_get_type()) {
            _ = c.g_value_init(&nf, c.gst_value_list_get_type());
            for (0..c.gst_value_list_get_size(formats)) |j| {
                const item = c.gst_value_list_get_value(formats, @intCast(j));
                if (!hasAlpha(formatInfoFromValue(item))) {
                    has = true;
                    c.gst_value_list_append_value(&nf, item);
                }
            }
        } else if (c.g_type_check_value_holds(formats, c.G_TYPE_STRING) != 0) {
            if (!hasAlpha(formatInfoFromValue(formats))) {
                has = true;
                c.gst_value_init_and_copy(&nf, formats);
            }
        } else unreachable;
        if (has) {
            s = c.gst_structure_copy(s);
            c.gst_structure_take_value_static_str(s, "format", &nf);
            c.gst_caps_append_structure_full(result, s, c.gst_caps_features_copy(c.gst_caps_get_features(caps, @intCast(i))));
        } else if (nf.g_type != 0) c.g_value_unset(&nf);
    }
    return result;
}

fn adjustAcceptable(s: ?*c.GstStructure, pad: anytype) void {
    c.gst_structure_set_static_str(s, "framerate", c.gst_fraction_range_get_type(), @as(c.gint, 0), @as(c.gint, 1), @as(c.gint, std.math.maxInt(c.gint)), @as(c.gint, 1), VNONE);
    if (isCPad(pad)) {
        c.gst_structure_set_static_str(s, "width", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, std.math.maxInt(c.gint)), "height", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, std.math.maxInt(c.gint)), VNONE);
        c.gst_structure_remove_fields(s, "colorimetry", "chroma-site", "format", "pixel-aspect-ratio", VNONE);
    }
}

fn padSinkGetcaps(pad: ?*c.GstPad, a: [*c]Agg, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const sp = srcPad(a);
    const templ = c.gst_pad_get_pad_template_caps(sp);
    var srccaps = c.gst_pad_peer_query_caps(sp, templ);
    srccaps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(srccaps)));
    const has_alpha = capsHasAlpha(srccaps);
    var mode: c.GstVideoInterlaceMode = 0;
    const has_mode = sinkpadsInterlaceMode(a, null, &mode);
    for (0..c.gst_caps_get_size(srccaps)) |i| {
        const s = c.gst_caps_get_structure(srccaps, @intCast(i));
        adjustAcceptable(s, pad);
        if (has_mode) c.gst_structure_set_static_str(s, "interlace-mode", c.G_TYPE_STRING, info.gst_video_interlace_mode_to_string(mode), VNONE);
    }
    var returned: [*c]c.GstCaps = undefined;
    if (filter != null) {
        returned = c.gst_caps_intersect(srccaps, filter);
        c.gst_caps_unref(srccaps);
    } else returned = srccaps;
    var stc = c.gst_pad_get_pad_template_caps(pad);
    if (!has_alpha) {
        const tmp = nonAlphaCaps(stc);
        c.gst_caps_unref(stc);
        stc = tmp;
    }
    const inter = c.gst_caps_intersect(returned, stc);
    c.gst_caps_unref(returned);
    c.gst_caps_unref(templ);
    c.gst_caps_unref(stc);
    return inter;
}

fn updateQos(a: [*c]Agg, proportion: f64, diff: i64, timestamp: u64) void {
    const live = c.gst_aggregator_get_latency(@ptrCast(a)) != NONE;
    const p = apriv(a);
    el.lock(a);
    p.proportion = proportion;
    if (timestamp != NONE) {
        if (!live and diff > 0) {
            p.earliest_time = timestamp +% @as(u64, @bitCast(@min(2 * diff, @as(i64, @intCast(SEC))))) +% c.gst_util_uint64_scale_int_round(SEC, a[0].info.fps_d, a[0].info.fps_n);
        } else p.earliest_time = timestamp +% @as(u64, @bitCast(diff));
    } else p.earliest_time = NONE;
    el.unlock(a);
}

fn resetQos(a: [*c]Agg) void {
    updateQos(a, 0.5, 0, NONE);
    apriv(a).qos_processed = 0;
    apriv(a).qos_dropped = 0;
}

fn reset(a: [*c]Agg) void {
    const p = apriv(a);
    el.lock(a);
    info.gst_video_info_init(&a[0].info);
    el.unlock(a);
    p.ts_offset = 0;
    p.nframes = 0;
    p.live = 0;
    srcSegment(a).position = NONE;
    resetQos(a);
    el.lock(a);
    var l = sinkpads(a);
    while (l != null) : (l = l[0].next) {
        const pd: [*c]Pad = @ptrCast(@alignCast(l[0].data));
        const pp = ppriv(pd);
        replaceBuf(&pp.buffer, null);
        replaceCaps(&pp.caps, null);
        pp.start_time = NONE;
        pp.end_time = NONE;
        info.gst_video_info_init(&pd[0].info);
    }
    el.unlock(a);
}

fn applyPending(pad: [*c]Pad, reconf: *bool) void {
    const p = ppriv(pad);
    if (p.pending_vinfo.finfo != null) {
        replaceCaps(&p.caps, p.pending_caps);
        replaceCaps(&p.pending_caps, null);
        pad[0].info = p.pending_vinfo;
        reconf.* = true;
        p.pending_vinfo.finfo = null;
    }
}

fn isGapMissing(buf: [*c]Buffer) bool {
    return c.gst_buffer_get_size(buf) == 0 and buf[0].mini_object.flags & c.GST_BUFFER_FLAG_GAP != 0 and c.gst_buffer_get_custom_meta(buf, "GstAggregatorMissingDataMeta") != null;
}

fn fillQueues(a: [*c]Agg, out_start: u64, out_end: u64, timeout: bool) c.GstFlowReturn {
    var eos = c.gst_aggregator_get_force_live(@ptrCast(a)) == 0;
    var repeat_eos = false;
    var no_repeat = false;
    var need_more = false;
    var reconf = false;
    el.lock(a);
    var l = sinkpads(a);
    while (l != null) : (l = l[0].next) {
        const pad: [*c]Pad = @ptrCast(@alignCast(l[0].data));
        const bp: OBPad = @ptrCast(pad);
        const p = ppriv(pad);
        if (c.gst_aggregator_pad_is_inactive(bp) != 0) continue;
        el.lock(bp);
        var seg = pad[0].parent.segment;
        el.unlock(bp);
        const is_eos = c.gst_aggregator_pad_is_eos(bp) != 0;
        if (!is_eos) eos = false;
        if (!p.repeat_after_eos) no_repeat = true;
        var buf = c.gst_aggregator_pad_peek_buffer(bp);
        if (buf != null) {
            while (true) {
                var st = buf[0].pts;
                if (st == NONE) {
                    c.gst_mini_object_unref(@ptrCast(buf));
                    el.unlock(a);
                    return c.GST_FLOW_ERROR;
                }
                var et = buf[0].duration;
                if (et == NONE) {
                    st = @max(st, seg.start);
                    st = c.gst_segment_to_running_time(&seg, c.GST_FORMAT_TIME, st);
                    if (st >= out_end) {
                        c.gst_mini_object_unref(@ptrCast(buf));
                        break;
                    } else if (st < out_start) {
                        replaceBuf(&p.buffer, buf);
                        applyPending(pad, &reconf);
                        c.gst_mini_object_unref(@ptrCast(buf));
                        _ = c.gst_aggregator_pad_drop_buffer(bp);
                        p.start_time = st;
                        if (timeout) {
                            buf = c.gst_aggregator_pad_peek_buffer(bp);
                            if (buf != null) continue;
                        }
                        need_more = true;
                        break;
                    }
                    c.gst_mini_object_unref(@ptrCast(buf));
                    buf = c.gst_aggregator_pad_pop_buffer(bp);
                    replaceBuf(&p.buffer, buf);
                    applyPending(pad, &reconf);
                    p.start_time = st;
                    c.gst_mini_object_unref(@ptrCast(buf));
                    break;
                }
                et +%= st;
                if (st >= seg.stop or et < seg.start) {
                    c.gst_mini_object_unref(@ptrCast(buf));
                    _ = c.gst_aggregator_pad_drop_buffer(bp);
                    need_more = true;
                    break;
                }
                st = @max(st, seg.start);
                if (seg.stop != NONE) et = @min(et, seg.stop);
                var srt: u64 = undefined;
                var ert: u64 = undefined;
                if (seg.rate >= 0) {
                    srt = c.gst_segment_to_running_time(&seg, c.GST_FORMAT_TIME, st);
                    ert = c.gst_segment_to_running_time(&seg, c.GST_FORMAT_TIME, et);
                } else {
                    srt = c.gst_segment_to_running_time(&seg, c.GST_FORMAT_TIME, et);
                    ert = c.gst_segment_to_running_time(&seg, c.GST_FORMAT_TIME, st);
                }
                if (p.end_time != NONE and p.end_time > ert) {
                    c.gst_mini_object_unref(@ptrCast(buf));
                    _ = c.gst_aggregator_pad_drop_buffer(bp);
                    break;
                }
                if (ert > out_start and srt < out_end) {
                    if (!isGapMissing(buf)) replaceBuf(&p.buffer, buf);
                    applyPending(pad, &reconf);
                    p.start_time = srt;
                    p.end_time = ert;
                    c.gst_mini_object_unref(@ptrCast(buf));
                    _ = c.gst_aggregator_pad_drop_buffer(bp);
                    eos = false;
                } else if (srt >= out_end) {
                    c.gst_mini_object_unref(@ptrCast(buf));
                    eos = false;
                } else {
                    if (!isGapMissing(buf)) replaceBuf(&p.buffer, buf);
                    applyPending(pad, &reconf);
                    p.start_time = srt;
                    p.end_time = ert;
                    c.gst_mini_object_unref(@ptrCast(buf));
                    _ = c.gst_aggregator_pad_drop_buffer(bp);
                    need_more = true;
                }
                break;
            }
            continue;
        }
        if (is_eos and p.repeat_after_eos) {
            repeat_eos = true;
            continue;
        }
        if (p.end_time != NONE) {
            if (p.end_time <= out_start) {
                if (!is_eos) {
                    if (p.max_last_buffer_repeat != NONE) {
                        if (out_start -% p.end_time > p.max_last_buffer_repeat) {
                            p.start_time = NONE;
                            p.end_time = NONE;
                            replaceBuf(&p.buffer, null);
                            replaceCaps(&p.caps, null);
                        }
                    } else {
                        p.start_time = NONE;
                        p.end_time = NONE;
                    }
                    need_more = true;
                } else {
                    replaceBuf(&p.buffer, null);
                    replaceCaps(&p.caps, null);
                    p.start_time = NONE;
                    p.end_time = NONE;
                }
            } else if (is_eos) eos = false;
        } else if (is_eos) {
            replaceBuf(&p.buffer, null);
            replaceCaps(&p.caps, null);
        } else if (p.start_time != NONE) {
            if (p.start_time <= out_start and p.max_last_buffer_repeat != NONE) {
                if (out_start -% p.start_time > p.max_last_buffer_repeat) {
                    p.start_time = NONE;
                    p.end_time = NONE;
                    replaceBuf(&p.buffer, null);
                    replaceCaps(&p.caps, null);
                }
            }
        }
    }
    el.unlock(a);
    if (reconf) c.gst_pad_mark_reconfigure(srcPad(a));
    if (need_more) return NEED_DATA;
    if (eos and !no_repeat and repeat_eos) eos = false;
    if (eos) return c.GST_FLOW_EOS;
    return c.GST_FLOW_OK;
}

fn syncPad(_: [*c]c.GstElement, pad: ?*c.GstPad, user: c.gpointer) callconv(.c) c.gboolean {
    const t: *u64 = @ptrCast(@alignCast(user));
    if (t.* != NONE) _ = c.gst_object_sync_values(@ptrCast(@alignCast(pad)), t.*);
    return 1;
}

fn isGapBuffer(b: [*c]Buffer) bool {
    return c.gst_buffer_get_size(b) == 0 and b[0].mini_object.flags & c.GST_BUFFER_FLAG_GAP != 0;
}

fn prepStart(a: [*c]c.GstElement, pad: ?*c.GstPad, _: c.gpointer) callconv(.c) c.gboolean {
    const p = ppriv(pad);
    const k = padClass(pad);
    p.prepared_frame = std.mem.zeroes(VFrame);
    if (p.buffer == null or k.prepare_frame_start == null) return 1;
    if (isGapBuffer(p.buffer)) return 1;
    if (!check.that(k.prepare_frame_start != null and k.prepare_frame_finish != null, "prepare_frames_start", "vaggpad_class->prepare_frame_start && vaggpad_class->prepare_frame_finish")) return 1;
    k.prepare_frame_start.?(@ptrCast(pad), agg(a), p.buffer, &p.prepared_frame);
    return 1;
}

fn prepFinish(a: [*c]c.GstElement, pad: ?*c.GstPad, _: c.gpointer) callconv(.c) c.gboolean {
    const p = ppriv(pad);
    const k = padClass(pad);
    if (p.buffer == null or (k.prepare_frame == null and k.prepare_frame_start == null)) return 1;
    if (isGapBuffer(p.buffer)) return 1;
    if (k.prepare_frame_start != null and k.prepare_frame_finish != null) {
        k.prepare_frame_finish.?(@ptrCast(pad), agg(a), &p.prepared_frame);
        return 1;
    }
    return k.prepare_frame.?(@ptrCast(pad), agg(a), p.buffer, &p.prepared_frame);
}

fn cleanPad(a: [*c]c.GstElement, pad: ?*c.GstPad, _: c.gpointer) callconv(.c) c.gboolean {
    const p = ppriv(pad);
    if (padClass(pad).clean_frame) |f| f(@ptrCast(pad), agg(a), &p.prepared_frame);
    p.prepared_frame = std.mem.zeroes(VFrame);
    return 1;
}

fn doAggregate(a: [*c]Agg, out_start: u64, out_end: u64, outbuf: *[*c]Buffer) c.GstFlowReturn {
    const k = aggClass(a);
    const seg = srcSegment(a);
    const ret = k.create_output_buffer.?(a, outbuf);
    if (ret != c.GST_FLOW_OK) return ret;
    if (outbuf.* == null) return c.GST_FLOW_OK;
    el.lock(srcPad(a));
    var ost: u64 = undefined;
    if (seg.rate >= 0) {
        outbuf.*[0].pts = out_start;
        outbuf.*[0].duration = out_end -% out_start;
        ost = c.gst_segment_to_stream_time(seg, c.GST_FORMAT_TIME, out_start);
    } else {
        outbuf.*[0].pts = out_end;
        outbuf.*[0].duration = out_start -% out_end;
        ost = c.gst_segment_to_stream_time(seg, c.GST_FORMAT_TIME, out_end);
    }
    el.unlock(srcPad(a));
    _ = c.gst_element_foreach_sink_pad(@ptrCast(a), syncPad, &ost);
    c.gst_aggregator_selected_samples(@ptrCast(a), outbuf.*[0].pts, outbuf.*[0].dts, outbuf.*[0].duration, null);
    _ = c.gst_element_foreach_sink_pad(@ptrCast(a), prepStart, null);
    _ = c.gst_element_foreach_sink_pad(@ptrCast(a), prepFinish, null);
    const r = k.aggregate_frames.?(a, outbuf.*);
    _ = c.gst_element_foreach_sink_pad(@ptrCast(a), cleanPad, null);
    return r;
}

fn doQos(a: [*c]Agg, timestamp: u64) i64 {
    if (timestamp == NONE) return -1;
    el.lock(a);
    const earliest = apriv(a).earliest_time;
    el.unlock(a);
    if (earliest == NONE) return -1;
    const qostime = c.gst_segment_to_running_time(srcSegment(a), c.GST_FORMAT_TIME, timestamp);
    return @as(i64, @bitCast(earliest)) -% @as(i64, @bitCast(qostime));
}

fn advanceOnTimeout(a: [*c]Agg) void {
    const seg = srcSegment(a);
    el.lock(a);
    if (seg.position == NONE) seg.position = if (seg.rate > 0.0) seg.start else seg.stop;
    const d: c.gint = if (a[0].info.fps_d != 0) a[0].info.fps_d else 1;
    const n: c.gint = if (a[0].info.fps_n != 0) a[0].info.fps_n else 25;
    const fd = c.gst_util_uint64_scale(SEC, @intCast(d), @intCast(n));
    if (seg.rate > 0.0) {
        seg.position +%= fd;
    } else if (seg.position > fd) {
        seg.position -= fd;
    } else seg.position = 0;
    apriv(a).nframes += 1;
    el.unlock(a);
}

fn aggregate(ba: [*c]BAgg, timeout_in: c.gboolean) callconv(.c) c.GstFlowReturn {
    const a = agg(ba);
    const p = apriv(a);
    const timeout = timeout_in != 0;
    const seg = srcSegment(a);
    var outbuf: [*c]Buffer = null;
    vlock(a);
    if (a[0].info.finfo[0].format == c.GST_VIDEO_FORMAT_UNKNOWN) {
        if (timeout) advanceOnTimeout(a);
        vunlock(a);
        return NEED_DATA;
    }
    if (seg.rate < 0 and seg.stop == NONE) {
        vunlock(a);
        return c.GST_FLOW_ERROR;
    }
    var out_start = seg.position;
    if (seg.rate >= 0) {
        if (seg.position == NONE or seg.position < seg.start) out_start = seg.start;
    } else if (seg.position == NONE or seg.position > seg.stop) out_start = seg.stop;
    if (p.nframes == 0) p.ts_offset = out_start;
    var out_end: u64 = undefined;
    if (a[0].info.fps_n == 0) {
        out_end = NONE;
    } else {
        const dur = c.gst_util_uint64_scale(p.nframes + 1, SEC *% @as(u64, @intCast(a[0].info.fps_d)), @intCast(a[0].info.fps_n));
        if (seg.rate >= 0) {
            out_end = p.ts_offset +% dur;
        } else if (p.ts_offset >= dur) {
            out_end = p.ts_offset - dur;
        } else out_end = NONE;
    }
    if (seg.rate >= 0) {
        if (seg.stop != NONE) out_end = @min(out_end, seg.stop);
    } else if (seg.start != NONE) out_end = @max(out_end, seg.start);
    const out_start_rt = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, out_start);
    const out_end_rt = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, out_end);
    var flow: c.GstFlowReturn = if (out_end == out_start) c.GST_FLOW_EOS else fillQueues(a, out_start_rt, out_end_rt, timeout);
    if ((flow == NEED_DATA and !timeout) or flow == c.GST_FLOW_EOS or flow == c.GST_FLOW_ERROR) {
        vunlock(a);
        return flow;
    }
    if (c.gst_pad_needs_reconfigure(srcPad(a)) != 0) {
        vunlock(a);
        return NEED_DATA;
    }
    const jitter = doQos(a, out_start);
    if (jitter <= 0) {
        flow = doAggregate(a, out_start, out_end, &outbuf);
        if (flow != c.GST_FLOW_OK) {
            if (outbuf != null) c.gst_mini_object_unref(@ptrCast(outbuf));
            vunlock(a);
            return flow;
        }
        p.qos_processed += 1;
    } else {
        p.qos_dropped += 1;
        const msg = c.gst_message_new_qos(@ptrCast(a), p.live, out_start_rt, c.gst_segment_to_stream_time(seg, c.GST_FORMAT_TIME, out_start), out_start, out_end -% out_start);
        c.gst_message_set_qos_values(msg, jitter, p.proportion, 1000000);
        c.gst_message_set_qos_stats(msg, c.GST_FORMAT_BUFFERS, p.qos_processed, p.qos_dropped);
        _ = c.gst_element_post_message(@ptrCast(a), msg);
        flow = c.GST_FLOW_OK;
    }
    vunlock(a);
    if (outbuf != null) flow = c.gst_aggregator_finish_buffer(ba, outbuf);
    vlock(a);
    p.nframes += 1;
    seg.position = out_end;
    vunlock(a);
    return flow;
}

fn queryDuration(a: [*c]Agg, query: [*c]c.GstQuery) bool {
    var fmt: c.GstFormat = 0;
    c.gst_query_parse_duration(query, &fmt, null);
    var max: i64 = -1;
    var res = true;
    var done = false;
    var item = std.mem.zeroes(c.GValue);
    const it = c.gst_element_iterate_sink_pads(@ptrCast(a));
    while (!done) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_DONE => done = true,
            c.GST_ITERATOR_OK => {
                const pad: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(&item)));
                var duration: i64 = 0;
                res = res and c.gst_pad_peer_query_duration(pad, fmt, &duration) != 0;
                if (res) {
                    if (duration == -1) {
                        max = duration;
                        done = true;
                    } else if (duration > max) max = duration;
                }
                _ = c.g_value_reset(&item);
            },
            c.GST_ITERATOR_RESYNC => {
                max = -1;
                res = true;
                c.gst_iterator_resync(it);
            },
            else => {
                res = false;
                done = true;
            },
        }
    }
    c.g_value_unset(&item);
    c.gst_iterator_free(it);
    if (res) c.gst_query_set_duration(query, fmt, max);
    return res;
}

fn srcQuery(ba: [*c]BAgg, query: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const a = agg(ba);
    const seg = srcSegment(a);
    switch (query[0].type) {
        c.GST_QUERY_POSITION => {
            var fmt: c.GstFormat = 0;
            c.gst_query_parse_position(query, &fmt, null);
            if (fmt == c.GST_FORMAT_TIME) {
                c.gst_query_set_position(query, fmt, @bitCast(c.gst_segment_to_stream_time(seg, c.GST_FORMAT_TIME, seg.position)));
                return 1;
            }
            return 0;
        },
        c.GST_QUERY_DURATION => return @intFromBool(queryDuration(a, query)),
        c.GST_QUERY_LATENCY => {
            const res = agg_parent.?.src_query.?(ba, query);
            if (res != 0) c.gst_query_parse_latency(query, &apriv(a).live, null, null);
            return res;
        },
        else => return agg_parent.?.src_query.?(ba, query),
    }
}

fn srcEvent(ba: [*c]BAgg, event: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (event[0].type == c.GST_EVENT_QOS) {
        var t: c.GstQOSType = 0;
        var diff: i64 = 0;
        var ts: u64 = 0;
        var prop: f64 = 0;
        c.gst_event_parse_qos(event, &t, &prop, &diff, &ts);
        updateQos(agg(ba), prop, diff, ts);
    }
    return agg_parent.?.src_event.?(ba, event);
}

fn flushAgg(ba: [*c]BAgg) callconv(.c) c.GstFlowReturn {
    const a = agg(ba);
    const seg = srcSegment(a);
    el.lock(a);
    const abs_rate = @abs(seg.rate);
    var l = sinkpads(a);
    while (l != null) : (l = l[0].next) {
        const p = ppriv(l[0].data);
        if (@abs(seg.rate) != abs_rate) {
            if (@abs(seg.rate) != 1.0 and p.buffer != null) {
                p.start_time = @intFromFloat(@as(f64, @floatFromInt(p.start_time)) / @abs(seg.rate));
                p.end_time = @intFromFloat(@as(f64, @floatFromInt(p.end_time)) / @abs(seg.rate));
            }
            if (abs_rate != 1.0 and p.buffer != null) {
                p.start_time = @intFromFloat(@as(f64, @floatFromInt(p.start_time)) * abs_rate);
                p.end_time = @intFromFloat(@as(f64, @floatFromInt(p.end_time)) * abs_rate);
            }
        }
    }
    el.unlock(a);
    seg.position = NONE;
    apriv(a).ts_offset = 0;
    apriv(a).nframes = 0;
    resetQos(a);
    return c.GST_FLOW_OK;
}

fn sinkEventPreQueue(ba: [*c]BAgg, bp: OBPad, event: [*c]c.GstEvent) callconv(.c) c.GstFlowReturn {
    if (event[0].type == c.GST_EVENT_SEGMENT) {
        var seg: c.GstSegment = undefined;
        c.gst_event_copy_segment(event, &seg);
        if (seg.format != c.GST_FORMAT_TIME) {
            c.gst_mini_object_unref(@ptrCast(event));
            return c.GST_FLOW_ERROR;
        }
    }
    return agg_parent.?.sink_event_pre_queue.?(ba, bp, event);
}

fn sinkEvent(ba: [*c]BAgg, bp: OBPad, event: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const a = agg(ba);
    switch (event[0].type) {
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(event, &caps);
            const ret = padSinkSetcaps(vpad(bp), a, caps);
            c.gst_mini_object_unref(@ptrCast(event));
            return @intFromBool(ret);
        },
        c.GST_EVENT_SEGMENT => resetQos(a),
        else => {},
    }
    return agg_parent.?.sink_event.?(ba, bp, event);
}

fn startAgg(ba: [*c]BAgg) callconv(.c) c.gboolean {
    const a = agg(ba);
    replaceCaps(&apriv(a).current_caps, null);
    const tp = setupTaskPool(a);
    if (tp != null) c.gst_object_unref(tp);
    return 1;
}

fn stopAgg(ba: [*c]BAgg) callconv(.c) c.gboolean {
    reset(agg(ba));
    return 1;
}

fn requestNewPad(e: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, name: [*c]const u8, caps: [*c]const c.GstCaps) callconv(.c) ?*c.GstPad {
    const pad = @as(*c.GstElementClass, @ptrCast(agg_parent)).request_new_pad.?(e, templ, name, caps);
    if (pad == null) return null;
    el.lock(e);
    const p = ppriv(pad);
    p.zorder = e[0].numsinkpads;
    p.start_time = NONE;
    p.end_time = NONE;
    e[0].sinkpads = c.g_list_sort(e[0].sinkpads, zorderCompare);
    el.unlock(e);
    return pad;
}

fn releasePad(e: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const a = agg(e);
    vlock(a);
    el.lock(a);
    const last = e[0].numsinkpads -% 1 == 0;
    el.unlock(a);
    if (last) reset(a);
    const p = ppriv(pad);
    replaceBuf(&p.buffer, null);
    replaceCaps(&p.caps, null);
    replaceCaps(&p.pending_caps, null);
    @as(*c.GstElementClass, @ptrCast(agg_parent)).release_pad.?(e, pad);
    c.gst_pad_mark_reconfigure(srcPad(a));
    vunlock(a);
}

fn proposeAllocation(_: [*c]BAgg, _: OBPad, _: [*c]c.GstQuery, query: [*c]c.GstQuery) callconv(.c) c.gboolean {
    c.gst_query_add_allocation_meta(query, meta.gst_video_meta_api_get_type(), null);
    return 1;
}

fn decideAllocation(ba: [*c]BAgg, query: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const a = agg(ba);
    var params = c.GstAllocationParams{ .flags = 0, .@"align" = 15, .prefix = 0, .padding = 0 };
    if (c.gst_query_get_n_allocation_params(query) == 0) {
        c.gst_query_add_allocation_param(query, null, &params);
    } else {
        var i: c.guint = 0;
        while (i < c.gst_query_get_n_allocation_params(query)) : (i += 1) {
            var al: [*c]c.GstAllocator = null;
            c.gst_query_parse_nth_allocation_param(query, i, &al, &params);
            params.@"align" = @max(params.@"align", 15);
            c.gst_query_set_nth_allocation_param(query, i, al, &params);
        }
    }
    var allocator: [*c]c.GstAllocator = null;
    c.gst_query_parse_nth_allocation_param(query, 0, &allocator, &params);
    var bp: [*c]c.GstBufferPool = null;
    var size: c.guint = 0;
    var min: c.guint = 0;
    var max: c.guint = 0;
    var update = false;
    if (c.gst_query_get_n_allocation_pools(query) > 0) {
        c.gst_query_parse_nth_allocation_pool(query, 0, &bp, &size, &min, &max);
        size = @max(size, @as(c.guint, @truncate(a[0].info.size)));
        update = true;
    } else size = @truncate(a[0].info.size);
    var caps: [*c]c.GstCaps = null;
    c.gst_query_parse_allocation(query, &caps, null);
    const obj_name = @as(*c.GstObject, @ptrCast(@alignCast(a))).name;
    if (bp == null) {
        bp = pool.gst_video_buffer_pool_new();
        const name = c.g_strdup_printf("%s-pool", obj_name);
        c.g_object_set(bp, "name", name, VNONE);
        c.g_free(name);
    }
    const has_meta = c.gst_query_find_allocation_meta(query, meta.gst_video_meta_api_get_type(), null) != 0;
    var config = c.gst_buffer_pool_get_config(bp);
    c.gst_buffer_pool_config_set_params(config, caps, size, min, max);
    c.gst_buffer_pool_config_set_allocator(config, allocator, &params);
    if (has_meta) c.gst_buffer_pool_config_add_option(config, c.GST_BUFFER_POOL_OPTION_VIDEO_META);
    if (c.gst_buffer_pool_set_config(bp, config) == 0) {
        config = c.gst_buffer_pool_get_config(bp);
        if (c.gst_buffer_pool_config_validate_params(config, caps, size, min, max) == 0) {
            c.gst_structure_free(config);
            c.gst_object_unref(bp);
            bp = null;
        } else if (c.gst_buffer_pool_set_config(bp, config) == 0) {
            c.gst_object_unref(bp);
            bp = null;
        }
        if (bp == null) {
            bp = pool.gst_video_buffer_pool_new();
            const name = c.g_strdup_printf("%s-fallback-pool", obj_name);
            c.g_object_set(bp, "name", name, VNONE);
            c.g_free(name);
            config = c.gst_buffer_pool_get_config(bp);
            c.gst_buffer_pool_config_set_params(config, caps, size, min, max);
            c.gst_buffer_pool_config_set_allocator(config, allocator, &params);
            if (c.gst_query_find_allocation_meta(query, meta.gst_video_meta_api_get_type(), null) != 0) c.gst_buffer_pool_config_add_option(config, c.GST_BUFFER_POOL_OPTION_VIDEO_META);
            if (c.gst_buffer_pool_set_config(bp, config) == 0) {
                c.gst_object_unref(bp);
                if (allocator != null) c.gst_object_unref(allocator);
                el.messageAt(a, c.GST_MESSAGE_ERROR, .resource, c.GST_RESOURCE_ERROR_SETTINGS, c.g_strdup("Failed to configure the buffer pool"), c.g_strdup("Configuration is most likely invalid, please report this issue."), PATH, "gst_video_aggregator_decide_allocation", 2898, null);
                return 0;
            }
        }
    }
    if (update) c.gst_query_set_nth_allocation_pool(query, 0, bp, size, min, max) else c.gst_query_add_allocation_pool(query, bp, size, min, max);
    if (bp != null) c.gst_object_unref(bp);
    if (allocator != null) c.gst_object_unref(allocator);
    return 1;
}

fn createOutputBuffer(a: [*c]Agg, outbuf: [*c][*c]Buffer) callconv(.c) c.GstFlowReturn {
    const bp = c.gst_aggregator_get_buffer_pool(@ptrCast(a));
    if (bp != null) {
        if (c.gst_buffer_pool_is_active(bp) == 0 and c.gst_buffer_pool_set_active(bp, 1) == 0) {
            el.messageAt(a, c.GST_MESSAGE_ERROR, .resource, c.GST_RESOURCE_ERROR_SETTINGS, c.g_strdup("failed to activate bufferpool"), c.g_strdup("failed to activate bufferpool"), PATH, "gst_video_aggregator_create_output_buffer", 2917, null);
            c.gst_object_unref(bp);
            return c.GST_FLOW_ERROR;
        }
        const r = c.gst_buffer_pool_acquire_buffer(bp, outbuf, null);
        c.gst_object_unref(bp);
        return r;
    }
    var allocator: [*c]c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    c.gst_aggregator_get_allocator(@ptrCast(a), &allocator, &params);
    const outsize: c.guint = @truncate(a[0].info.size);
    outbuf[0] = c.gst_buffer_new_allocate(allocator, outsize, &params);
    if (allocator != null) c.gst_object_unref(allocator);
    if (outbuf[0] == null) {
        el.messageAt(a, c.GST_MESSAGE_ERROR, .resource, c.GST_RESOURCE_ERROR_NO_SPACE_LEFT, null, c.g_strdup_printf("Could not acquire buffer of size: %d", outsize), PATH, "gst_video_aggregator_create_output_buffer", 2941, null);
        return c.GST_FLOW_ERROR;
    }
    return c.GST_FLOW_OK;
}

fn padSinkAcceptcaps(pad: ?*c.GstPad, a: [*c]Agg, caps: [*c]c.GstCaps) bool {
    var acc = c.gst_pad_get_current_caps(srcPad(a));
    if (acc == null) acc = c.gst_pad_get_pad_template_caps(srcPad(a));
    acc = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(acc)));
    for (0..c.gst_caps_get_size(acc)) |i| adjustAcceptable(c.gst_caps_get_structure(acc, @intCast(i)), pad);
    const ret = c.gst_caps_can_intersect(caps, acc) != 0;
    c.gst_caps_unref(acc);
    return ret;
}

fn sinkQuery(ba: [*c]BAgg, bp: OBPad, query: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const a = agg(ba);
    switch (query[0].type) {
        c.GST_QUERY_CAPS => {
            var filter: [*c]c.GstCaps = null;
            c.gst_query_parse_caps(query, &filter);
            const caps = padSinkGetcaps(@ptrCast(bp), a, filter);
            c.gst_query_set_caps_result(query, caps);
            c.gst_caps_unref(caps);
            return 1;
        },
        c.GST_QUERY_ACCEPT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_query_parse_accept_caps(query, &caps);
            c.gst_query_set_accept_caps_result(query, @intFromBool(padSinkAcceptcaps(@ptrCast(bp), a, caps)));
            return 1;
        },
        else => return agg_parent.?.sink_query.?(ba, bp, query),
    }
}

pub export fn gst_video_aggregator_get_execution_task_pool(vagg: [*c]Agg) [*c]c.GstTaskPool {
    if (!check.that(gtype.instanceOf(vagg, gst_video_aggregator_get_type()), "gst_video_aggregator_get_execution_task_pool", "GST_IS_VIDEO_AGGREGATOR (vagg)")) return null;
    return setupTaskPool(vagg);
}

fn finalizeAgg(o: [*c]c.GObject) callconv(.c) void {
    const p = apriv(o);
    c.g_mutex_clear(&p.lock);
    c.g_ptr_array_unref(p.supported_formats);
    if (p.task_pool != null) {
        if (!p.task_pool_from_context) c.gst_task_pool_cleanup(p.task_pool);
        c.gst_object_unref(p.task_pool);
        p.task_pool = null;
    }
    @as(*c.GObjectClass, @ptrCast(agg_parent)).finalize.?(o);
}

fn disposeAgg(o: [*c]c.GObject) callconv(.c) void {
    replaceCaps(&apriv(o).current_caps, null);
    @as(*c.GObjectClass, @ptrCast(agg_parent)).dispose.?(o);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    if (id != 1) return el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 3094);
    c.g_value_set_boolean(v, c.gst_aggregator_get_force_live(@ptrCast(o)));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    if (id != 1) return el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 3109);
    c.gst_aggregator_set_force_live(@ptrCast(o), c.g_value_get_boolean(v));
}

fn postTaskPoolRequest(a: [*c]Agg) void {
    el.lock(a);
    if (apriv(a).task_pool != null) {
        el.unlock(a);
        return;
    }
    el.unlock(a);
    _ = c.gst_element_post_message(@ptrCast(a), c.gst_message_new_need_context(@ptrCast(a), c.GST_TASK_POOL_CONTEXT_TYPE));
}

fn setupTaskPool(a: [*c]Agg) [*c]c.GstTaskPool {
    postTaskPoolRequest(a);
    const p = apriv(a);
    el.lock(a);
    defer el.unlock(a);
    if (p.task_pool == null) {
        p.task_pool = c.gst_shared_task_pool_new();
        c.gst_shared_task_pool_set_max_threads(@ptrCast(p.task_pool), c.g_get_num_processors());
        c.gst_task_pool_prepare(p.task_pool, null);
        p.task_pool_from_context = false;
    }
    return @ptrCast(@alignCast(c.gst_object_ref(p.task_pool)));
}

fn setContext(e: [*c]c.GstElement, context: ?*c.GstContext) callconv(.c) void {
    const a = agg(e);
    const p = apriv(a);
    if (c.gst_context_has_context_type(context, c.GST_TASK_POOL_CONTEXT_TYPE) != 0) {
        var tp: [*c]c.GstTaskPool = null;
        _ = c.gst_context_get_task_pool(context, &tp);
        el.lock(a);
        if (p.task_pool != null and !p.task_pool_from_context) c.gst_task_pool_cleanup(p.task_pool);
        if (p.task_pool != null) c.gst_object_unref(p.task_pool);
        p.task_pool = tp;
        p.task_pool_from_context = true;
        p.task_pool_from_persistent_context = c.gst_context_is_persistent(context) != 0;
        el.unlock(a);
    }
    @as(*c.GstElementClass, @ptrCast(agg_parent)).set_context.?(e, context);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const ret = @as(*c.GstElementClass, @ptrCast(agg_parent)).change_state.?(e, t);
    if (t == c.GST_STATE_CHANGE_READY_TO_NULL) {
        const p = apriv(e);
        el.lock(e);
        if (p.task_pool_from_context and !p.task_pool_from_persistent_context) {
            if (p.task_pool != null) c.gst_object_unref(p.task_pool);
            p.task_pool = null;
            p.task_pool_from_context = false;
        }
        el.unlock(e);
    }
    return ret;
}

fn aggClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    _ = c._gst_debug_category_new("videoaggregator", 0, "base video aggregator");
    agg_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (agg_offset != 0) c.g_type_class_adjust_private_offset(k, &agg_offset);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    const ac: *BAggClass = @ptrCast(@alignCast(k));
    const vc: *AggClass = @ptrCast(@alignCast(k));
    oc.finalize = finalizeAgg;
    oc.dispose = disposeAgg;
    oc.get_property = getProperty;
    oc.set_property = setProperty;
    ec.request_new_pad = requestNewPad;
    ec.release_pad = releasePad;
    ec.set_context = setContext;
    ec.change_state = changeState;
    ac.start = startAgg;
    ac.stop = stopAgg;
    ac.sink_query = sinkQuery;
    ac.sink_event = sinkEvent;
    ac.sink_event_pre_queue = sinkEventPreQueue;
    ac.flush = flushAgg;
    ac.aggregate = aggregate;
    ac.src_event = srcEvent;
    ac.src_query = srcQuery;
    ac.get_next_time = c.gst_aggregator_simple_get_next_time;
    ac.update_src_caps = updateSrcCapsDefault;
    ac.fixate_src_caps = fixateSrcCaps;
    ac.negotiated_src_caps = negotiatedSrcCaps;
    ac.decide_allocation = decideAllocation;
    ac.propose_allocation = proposeAllocation;
    ac.peek_next_sample = peekNextSample;
    vc.find_best_format = findBestFormat;
    vc.create_output_buffer = createOutputBuffer;
    vc.update_caps = updateCapsDefault;
    _ = c.g_type_class_ref(gst_video_aggregator_pad_get_type());
    c.g_object_class_install_property(oc, 1, c.g_param_spec_boolean("force-live", "Force live", "Always operate in live mode and aggregate on timeout regardless of whether any live sources are linked upstream", 0, c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS | c.G_PARAM_CONSTRUCT_ONLY));
}

fn aggInit(inst: [*c]c.GTypeInstance, g_class: c.gpointer) callconv(.c) void {
    const a = agg(inst);
    a[0].priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, agg_offset))));
    const p = apriv(a);
    p.current_caps = null;
    c.g_mutex_init(&p.lock);
    reset(a);
    p.supported_formats = c.g_ptr_array_new();
    const tmpl = c.gst_element_class_get_pad_template(@ptrCast(@alignCast(g_class)), "src");
    const src_templ = c.gst_pad_template_get_caps(tmpl);
    for (0..c.gst_caps_get_size(src_templ)) |i| {
        const v = c.gst_structure_get_value(c.gst_caps_get_structure(src_templ, @intCast(i)), "format");
        if (v != null and c.g_type_check_value_holds(v, c.G_TYPE_STRING) != 0) {
            c.g_ptr_array_add(p.supported_formats, @constCast(@ptrCast(formatInfoFromValue(v))));
            continue;
        }
        if (v != null and v[0].g_type == c.gst_value_list_get_type()) {
            for (0..c.gst_value_list_get_size(v)) |j| c.g_ptr_array_add(p.supported_formats, @constCast(@ptrCast(formatInfoFromValue(c.gst_value_list_get_value(v, @intCast(j))))));
        }
    }
    c.gst_caps_unref(src_templ);
}

pub export fn gst_video_aggregator_get_type() c.GType {
    return agg_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_aggregator_get_type, "GstVideoAggregator", AggClass, Agg, aggClassInit, aggInit, c.G_TYPE_FLAG_ABSTRACT);
            agg_offset = c.g_type_add_instance_private(t, @sizeOf(AggPrivate));
            return t;
        }
    }.f);
}
