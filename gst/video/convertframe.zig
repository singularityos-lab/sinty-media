const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const info = @import("info.zig");
const meta = @import("meta.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Element = c.GstElement;
const Caps = c.GstCaps;
const NONE = @as(?*anyopaque, null);

fn capsAreRaw(caps: [*c]const Caps) bool {
    for (0..c.gst_caps_get_size(caps)) |i| {
        if (c.gst_structure_has_name(c.gst_caps_get_structure(caps, @intCast(i)), "video/x-raw") != 0) return true;
    }
    return false;
}

fn createElement(name: [*:0]const u8, element: *[*c]Element, err: *[*c]c.GError) bool {
    element.* = c.gst_element_factory_make(name, null);
    if (element.* != null) return true;
    if (err.* == null) err.* = c.g_error_new(c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, "cannot create element '%s' - please check your GStreamer installation", name);
    return false;
}

fn getEncoder(caps: [*c]const Caps, err: *[*c]c.GError) [*c]Element {
    const encoders = c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_ENCODER | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_IMAGE, c.GST_RANK_NONE);
    if (encoders == null) {
        err.* = c.g_error_new(c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, "Cannot find any image encoder");
        return null;
    }
    defer c.gst_plugin_feature_list_free(encoders);
    const filtered = c.gst_element_factory_list_filter(encoders, caps, c.GST_PAD_SRC, 0);
    if (filtered == null) {
        const tmp = c.gst_caps_to_string(caps);
        err.* = c.g_error_new(c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, "Cannot find any image encoder for caps %s", tmp);
        c.g_free(tmp);
        return null;
    }
    defer c.gst_plugin_feature_list_free(filtered);
    return c.gst_element_factory_create(@ptrCast(@alignCast(filtered[0].data)), null);
}

fn clear(p: *[*c]Element) void {
    if (p.* != null) c.gst_object_unref(p.*);
    p.* = null;
}

fn buildD3d(src_out: *[*c]Element, sink_out: *[*c]Element, from: [*c]Caps, to: [*c]Caps, d3d12: bool, err: *[*c]c.GError) [*c]Element {
    var appsrc: [*c]Element = null;
    var conv: [*c]Element = null;
    var dl: [*c]Element = null;
    var convert: [*c]Element = null;
    var enc: [*c]Element = null;
    var appsink: [*c]Element = null;
    var e: [*c]c.GError = null;
    const conv_name: [*:0]const u8 = if (d3d12) "d3d12convert" else "d3d11convert";
    const dl_name: [*:0]const u8 = if (d3d12) "d3d12download" else "d3d11download";
    var ok = createElement("appsrc", &appsrc, &e) and createElement(conv_name, &conv, &e) and createElement(dl_name, &dl, &e) and createElement("videoconvert", &convert, &e) and createElement("appsink", &appsink, &e);
    if (ok) {
        if (capsAreRaw(to)) {
            ok = createElement("identity", &enc, &e);
        } else {
            enc = getEncoder(to, &e);
            ok = enc != null;
        }
    }
    if (!ok) {
        err.* = e;
        for ([_]*[*c]Element{ &appsrc, &conv, &dl, &convert, &enc, &appsink }) |p| clear(p);
        return null;
    }
    c.g_object_set(appsrc, "caps", from, "emit-signals", @as(c.gboolean, 1), "format", c.GST_FORMAT_TIME, NONE);
    c.g_object_set(appsink, "caps", to, "emit-signals", @as(c.gboolean, 1), NONE);
    const pipeline = c.gst_pipeline_new("d3d11-convert-frame-pipeline");
    c.gst_bin_add_many(@ptrCast(pipeline), appsrc, conv, dl, convert, enc, appsink, NONE);
    if (c.gst_element_link_many(appsrc, conv, dl, convert, enc, appsink, NONE) == 0) {
        appsrc = null;
        appsink = null;
        e = c.g_error_new(c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, "Could not configure pipeline for conversion");
    }
    src_out.* = appsrc;
    sink_out.* = appsink;
    return pipeline;
}

fn stripCrop(_: ?*c.GstPad, pi: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    var buf = c.gst_pad_probe_info_get_buffer(pi);
    const cm = c.gst_buffer_get_meta(buf, meta.gst_video_crop_meta_api_get_type());
    if (cm != null) {
        buf = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(buf)));
        _ = c.gst_buffer_remove_meta(buf, cm);
        pi[0].data = buf;
    }
    return c.GST_PAD_PROBE_OK;
}

fn linkPads(a: [*c]Element, b: [*c]Element) bool {
    return c.gst_element_link_pads(a, "src", b, "sink") != 0;
}

fn linkFailed(pipeline: [*c]Element, err: *[*c]c.GError) [*c]Element {
    c.gst_object_unref(pipeline);
    err.* = c.g_error_new(c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, "Could not convert video frame: failed to link elements");
    return null;
}

fn build(src_out: *[*c]Element, sink_out: *[*c]Element, from: [*c]Caps, cmeta: [*c]c.GstVideoCropMeta, to: [*c]Caps, err: *[*c]c.GError) [*c]Element {
    var vcrop: [*c]Element = null;
    var csp: [*c]Element = null;
    var csp2: [*c]Element = null;
    var vscale: [*c]Element = null;
    var src: [*c]Element = null;
    var sink: [*c]Element = null;
    var dl: [*c]Element = null;
    var e: [*c]c.GError = null;
    const features = c.gst_caps_get_features(from, 0);
    if (features != null and c.gst_caps_features_is_any(features) == 0) {
        const d11 = c.gst_caps_features_contains(features, "memory:D3D11Memory") != 0;
        const d12 = c.gst_caps_features_contains(features, "memory:D3D12Memory") != 0;
        if (d11 or d12) return buildD3d(src_out, sink_out, from, to, d12, err);
    }
    var ok = true;
    if (features != null and c.gst_caps_features_contains(features, "memory:GLMemory") != 0) ok = createElement("gldownload", &dl, &e);
    if (ok and cmeta != null) {
        if (!createElement("videocrop", &vcrop, &e)) {
            c.g_error_free(e);
            e = null;
            c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "build_convert_frame_pipeline: Buffer has crop metadata but videocrop element is not found. Cropping will be disabled");
        } else ok = createElement("videoconvert", &csp2, &e);
    }
    if (ok) ok = createElement("appsrc", &src, &e) and createElement("videoconvert", &csp, &e) and createElement("videoscale", &vscale, &e) and createElement("appsink", &sink, &e);
    if (!ok) {
        for ([_]*[*c]Element{ &src, &vcrop, &csp, &csp2, &vscale, &sink }) |p| clear(p);
        err.* = e;
        return null;
    }
    const pipeline = c.gst_pipeline_new("videoconvert-pipeline");
    c.g_object_set(vscale, "add-borders", @as(c.gboolean, 1), NONE);
    c.gst_bin_add_many(@ptrCast(pipeline), src, csp, vscale, sink, NONE);
    if (vcrop != null) c.gst_bin_add_many(@ptrCast(pipeline), vcrop, csp2, NONE);
    if (dl != null) _ = c.gst_bin_add(@ptrCast(pipeline), dl);
    c.g_object_set(src, "caps", from, "emit-signals", @as(c.gboolean, 1), "format", c.GST_FORMAT_TIME, NONE);
    c.g_object_set(sink, "caps", to, "emit-signals", @as(c.gboolean, 1), NONE);
    if (vcrop != null) {
        var vi: c.GstVideoInfo = undefined;
        _ = info.gst_video_info_from_caps(&vi, from);
        const m = cmeta[0];
        c.g_object_set(vcrop, "left", m.x, NONE);
        c.g_object_set(vcrop, "top", m.y, NONE);
        c.g_object_set(vcrop, "right", vi.width - @as(c.gint, @bitCast(m.x +% m.width)), NONE);
        c.g_object_set(vcrop, "bottom", vi.height - @as(c.gint, @bitCast(m.y +% m.height)), NONE);
        const pad = c.gst_element_get_static_pad(vcrop, "sink");
        _ = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_BUFFER, stripCrop, null, null);
        c.gst_object_unref(pad);
        if (dl == null) {
            if (!linkPads(src, csp2)) return linkFailed(pipeline, err);
        } else {
            if (!linkPads(src, dl)) return linkFailed(pipeline, err);
            if (!linkPads(dl, csp2)) return linkFailed(pipeline, err);
        }
        if (!linkPads(csp2, vcrop)) return linkFailed(pipeline, err);
        if (!linkPads(vcrop, csp)) return linkFailed(pipeline, err);
    } else if (dl == null) {
        if (!linkPads(src, csp)) return linkFailed(pipeline, err);
    } else {
        if (!linkPads(src, dl)) return linkFailed(pipeline, err);
        if (!linkPads(dl, csp)) return linkFailed(pipeline, err);
    }
    if (c.gst_element_link_pads_full(csp, "src", vscale, "sink", c.GST_PAD_LINK_CHECK_NOTHING) == 0) return linkFailed(pipeline, err);
    if (capsAreRaw(to)) {
        if (c.gst_element_link_pads_full(vscale, "src", sink, "sink", c.GST_PAD_LINK_CHECK_NOTHING) == 0) return linkFailed(pipeline, err);
    } else {
        const encoder = getEncoder(to, &e);
        if (encoder == null) {
            c.gst_object_unref(pipeline);
            err.* = e;
            return null;
        }
        _ = c.gst_bin_add(@ptrCast(pipeline), encoder);
        if (c.gst_element_link(vscale, encoder) == 0) return linkFailed(pipeline, err);
        if (!linkPads(encoder, sink)) return linkFailed(pipeline, err);
    }
    src_out.* = src;
    sink_out.* = sink;
    return pipeline;
}

fn stripFramerate(to: [*c]const Caps) [*c]Caps {
    const copy = c.gst_caps_new_empty();
    for (0..c.gst_caps_get_size(to)) |i| {
        const s = c.gst_structure_copy(c.gst_caps_get_structure(to, @intCast(i)));
        c.gst_structure_remove_field(s, "framerate");
        c.gst_caps_append_structure(copy, s);
    }
    return copy;
}

fn cropMeta(buf: [*c]c.GstBuffer) [*c]c.GstVideoCropMeta {
    return @ptrCast(@alignCast(c.gst_buffer_get_meta(buf, meta.gst_video_crop_meta_api_get_type())));
}

fn setError(error_out: [*c][*c]c.GError, e: [*c]c.GError) void {
    if (error_out != null) error_out[0] = e else c.g_error_free(e);
}

pub export fn gst_video_convert_sample(sample: ?*c.GstSample, to_caps: [*c]const Caps, timeout: c.GstClockTime, @"error": [*c][*c]c.GError) ?*c.GstSample {
    const fname = "gst_video_convert_sample";
    if (!check.that(sample != null, fname, "sample != NULL")) return null;
    if (!check.that(to_caps != null, fname, "to_caps != NULL")) return null;
    const buf = c.gst_sample_get_buffer(sample);
    if (!check.that(buf != null, fname, "buf != NULL")) return null;
    const from = c.gst_sample_get_caps(sample);
    if (!check.that(from != null, fname, "from_caps != NULL")) return null;
    const to = stripFramerate(to_caps);
    defer c.gst_caps_unref(to);
    var err: [*c]c.GError = null;
    var src: [*c]Element = null;
    var sink: [*c]Element = null;
    const pipeline = build(&src, &sink, from, cropMeta(buf), to, &err);
    if (pipeline == null) {
        setError(@"error", err);
        return null;
    }
    if (c.gst_element_set_state(pipeline, c.GST_STATE_PAUSED) == c.GST_STATE_CHANGE_FAILURE) {
        setError(@"error", err);
        return null;
    }
    var ret: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(src, "push-buffer", buf, &ret);
    const bus = c.gst_element_get_bus(pipeline);
    const msg = c.gst_bus_timed_pop_filtered(bus, timeout, c.GST_MESSAGE_ERROR | c.GST_MESSAGE_ASYNC_DONE);
    var result: ?*c.GstSample = null;
    if (msg != null) {
        switch (msg[0].type) {
            c.GST_MESSAGE_ASYNC_DONE => c.g_signal_emit_by_name(sink, "pull-preroll", &result),
            c.GST_MESSAGE_ERROR => {
                var dbg: [*c]u8 = null;
                c.gst_message_parse_error(msg, &err, &dbg);
                if (err != null) {
                    if (@"error" != null) @"error"[0] = err else c.g_error_free(err);
                }
                c.g_free(dbg);
            },
            else => {
                check.reached("convertframe.c", 566, fname);
                return null;
            },
        }
        c.gst_message_unref(msg);
    } else if (@"error" != null) {
        @"error"[0] = c.g_error_new(c.gst_core_error_quark(), c.GST_CORE_ERROR_FAILED, "Could not convert video frame: timeout during conversion");
    }
    _ = c.gst_element_set_state(pipeline, c.GST_STATE_NULL);
    c.gst_object_unref(bus);
    c.gst_object_unref(pipeline);
    return result;
}

const Ctx = struct {
    ref_count: c.gint,
    mutex: c.GMutex,
    pipeline: [*c]Element,
    callback: c.GstVideoConvertSampleCallback,
    user_data: c.gpointer,
    destroy_notify: c.GDestroyNotify,
    context: ?*c.GMainContext,
    sample: ?*c.GstSample,
    timeout_source: ?*c.GSource,
    finished: bool,
    converted: ?*c.GstSample,
    @"error": [*c]c.GError,
};

fn ctxRef(x: *Ctx) *Ctx {
    _ = c.g_atomic_int_add(&x.ref_count, 1);
    return x;
}

fn ctxUnref(p: c.gpointer) callconv(.c) void {
    const x: *Ctx = @ptrCast(@alignCast(p));
    if (c.g_atomic_int_dec_and_test(&x.ref_count) == 0) return;
    c.g_mutex_clear(&x.mutex);
    if (x.timeout_source) |s| c.g_source_destroy(s);
    if (x.sample) |s| c.gst_sample_unref(s);
    if (x.converted) |s| c.gst_sample_unref(s);
    c.g_clear_error(&x.@"error");
    c.g_main_context_unref(x.context);
    if (x.pipeline != null) c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "%s", "(../gst-libs/gst/video/convertframe.c:643):gst_video_convert_frame_context_unref: runtime check failed: (ctx->pipeline == NULL)");
    c.g_free(x);
}

fn dispatch(p: c.gpointer) callconv(.c) c.gboolean {
    const x: *Ctx = @ptrCast(@alignCast(p));
    if (!check.that(x.converted != null or x.@"error" != null, "convert_frame_dispatch_callback", "ctx->converted_sample != NULL || ctx->error != NULL")) return 0;
    const s = x.converted;
    const e = x.@"error";
    x.converted = null;
    x.@"error" = null;
    x.callback.?(s, e, x.user_data);
    if (x.destroy_notify) |d| d(x.user_data);
    return 0;
}

fn stopPipeline(o: ?*anyopaque, _: c.gpointer) callconv(.c) void {
    _ = c.gst_element_set_state(@ptrCast(@alignCast(o)), c.GST_STATE_NULL);
}

fn finish(x: *Ctx, sample: ?*c.GstSample, e: [*c]c.GError) void {
    if (!check.that(!x.finished, "convert_frame_finish", "!context->finished")) return;
    if (!check.that(sample != null or e != null, "convert_frame_finish", "sample != NULL || error != NULL")) return;
    x.finished = true;
    x.converted = sample;
    x.@"error" = e;
    if (x.timeout_source) |s| c.g_source_destroy(s);
    x.timeout_source = null;
    const source = c.g_timeout_source_new(0);
    c.g_source_set_callback(source, dispatch, ctxRef(x), ctxUnref);
    _ = c.g_source_attach(source, x.context);
    c.g_source_unref(source);
    if (x.pipeline != null) {
        c.gst_object_call_async(@ptrCast(x.pipeline), @ptrCast(&stopPipeline), null);
        c.gst_object_unref(x.pipeline);
        x.pipeline = null;
    }
}

fn onTimeout(p: c.gpointer) callconv(.c) c.gboolean {
    const x: *Ctx = @ptrCast(@alignCast(p));
    c.g_mutex_lock(&x.mutex);
    if (!x.finished) finish(x, null, c.g_error_new(c.gst_core_error_quark(), c.GST_CORE_ERROR_FAILED, "Could not convert video frame: timeout"));
    c.g_mutex_unlock(&x.mutex);
    return 0;
}

fn onBus(_: ?*c.GstBus, message: [*c]c.GstMessage, p: c.gpointer) callconv(.c) c.gboolean {
    const x: *Ctx = @ptrCast(@alignCast(p));
    c.g_mutex_lock(&x.mutex);
    if (!x.finished and message[0].type == c.GST_MESSAGE_ERROR) {
        var e: [*c]c.GError = null;
        var dbg: [*c]u8 = null;
        c.gst_message_parse_error(message, &e, &dbg);
        finish(x, null, e);
        c.g_free(dbg);
    }
    c.g_mutex_unlock(&x.mutex);
    return 0;
}

fn onNeedData(src: [*c]Element, _: c.guint, p: c.gpointer) callconv(.c) void {
    const x: *Ctx = @ptrCast(@alignCast(p));
    c.g_mutex_lock(&x.mutex);
    if (!x.finished) {
        var ret: c.GstFlowReturn = c.GST_FLOW_ERROR;
        c.g_signal_emit_by_name(src, "push-buffer", c.gst_sample_get_buffer(x.sample), &ret);
        c.gst_sample_unref(x.sample);
        x.sample = null;
        if (ret != c.GST_FLOW_OK) finish(x, null, c.g_error_new(c.gst_core_error_quark(), c.GST_CORE_ERROR_FAILED, "Could not push video frame: %s", c.gst_flow_get_name(ret)));
    }
    c.g_mutex_unlock(&x.mutex);
    _ = c.g_signal_handlers_disconnect_matched(src, c.G_SIGNAL_MATCH_FUNC | c.G_SIGNAL_MATCH_DATA, 0, 0, null, @ptrCast(@constCast(&onNeedData)), p);
}

fn onPreroll(sink: [*c]Element, p: c.gpointer) callconv(.c) c.GstFlowReturn {
    const x: *Ctx = @ptrCast(@alignCast(p));
    c.g_mutex_lock(&x.mutex);
    if (!x.finished) {
        var sample: ?*c.GstSample = null;
        c.g_signal_emit_by_name(sink, "pull-preroll", &sample);
        var e: [*c]c.GError = null;
        if (sample == null) e = c.g_error_new(c.gst_core_error_quark(), c.GST_CORE_ERROR_FAILED, "Could not get converted video sample");
        finish(x, sample, e);
    }
    c.g_mutex_unlock(&x.mutex);
    _ = c.g_signal_handlers_disconnect_matched(sink, c.G_SIGNAL_MATCH_FUNC | c.G_SIGNAL_MATCH_DATA, 0, 0, null, @ptrCast(@constCast(&onNeedData)), p);
    return c.GST_FLOW_OK;
}

fn closureUnref(p: c.gpointer, _: ?*c.GClosure) callconv(.c) void {
    ctxUnref(p);
}

pub export fn gst_video_convert_sample_async(sample: ?*c.GstSample, to_caps: [*c]const Caps, timeout: c.GstClockTime, callback: c.GstVideoConvertSampleCallback, user_data: c.gpointer, destroy_notify: c.GDestroyNotify) void {
    const fname = "gst_video_convert_sample_async";
    if (!check.that(sample != null, fname, "sample != NULL")) return;
    const buf = c.gst_sample_get_buffer(sample);
    if (!check.that(buf != null, fname, "buf != NULL")) return;
    if (!check.that(to_caps != null, fname, "to_caps != NULL")) return;
    const from = c.gst_sample_get_caps(sample);
    if (!check.that(from != null, fname, "from_caps != NULL")) return;
    if (!check.that(callback != null, fname, "callback != NULL")) return;
    var context = c.g_main_context_get_thread_default();
    if (context == null) context = c.g_main_context_default();
    const to = stripFramerate(to_caps);
    defer c.gst_caps_unref(to);
    const x: *Ctx = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Ctx))));
    x.ref_count = 1;
    c.g_mutex_init(&x.mutex);
    x.sample = c.gst_sample_ref(sample);
    x.callback = callback;
    x.user_data = user_data;
    x.destroy_notify = destroy_notify;
    x.context = c.g_main_context_ref(context);
    x.finished = false;
    var e: [*c]c.GError = null;
    var src: [*c]Element = null;
    var sink: [*c]Element = null;
    const pipeline = build(&src, &sink, from, cropMeta(buf), to, &e);
    if (pipeline == null) {
        c.g_mutex_lock(&x.mutex);
        finish(x, null, e);
        c.g_mutex_unlock(&x.mutex);
        ctxUnref(x);
        return;
    }
    x.pipeline = pipeline;
    const bus = c.gst_element_get_bus(pipeline);
    if (timeout != c.GST_CLOCK_TIME_NONE) {
        x.timeout_source = c.g_timeout_source_new(@intCast(timeout / @as(c.GstClockTime, c.GST_MSECOND)));
        c.g_source_set_callback(x.timeout_source, onTimeout, ctxRef(x), ctxUnref);
        _ = c.g_source_attach(x.timeout_source, context);
    }
    _ = c.g_signal_connect_data(src, "need-data", @ptrCast(&onNeedData), ctxRef(x), closureUnref, 0);
    _ = c.g_signal_connect_data(sink, "new-preroll", @ptrCast(&onPreroll), ctxRef(x), closureUnref, 0);
    const source = c.gst_bus_create_watch(bus);
    c.g_source_set_callback(source, @ptrCast(&onBus), ctxRef(x), ctxUnref);
    _ = c.g_source_attach(source, context);
    c.g_source_unref(source);
    c.gst_object_unref(bus);
    if (c.gst_element_set_state(pipeline, c.GST_STATE_PAUSED) == c.GST_STATE_CHANGE_FAILURE) {
        c.g_mutex_lock(&x.mutex);
        finish(x, null, c.g_error_new(c.gst_core_error_quark(), c.GST_CORE_ERROR_STATE_CHANGE, "failed to change state to PLAYING"));
        c.g_mutex_unlock(&x.mutex);
    }
    ctxUnref(x);
}
