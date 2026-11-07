const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const pw = @import("pw.zig");
const pod = @import("pod.zig");

const SRC_CAPS = "ANY";
const QUEUE_MAX = 8;
const NEGOTIATE_WAIT_US: i64 = 10 * std.time.us_per_s;

const PROP_PATH = 1;
const PROP_TARGET_OBJECT = 2;
const PROP_CLIENT_NAME = 3;
const PROP_STREAM_PROPERTIES = 4;
const PROP_FD = 5;
const PROP_KEEPALIVE_TIME = 6;
const PROP_ON_DISCONNECT = 7;
const PROP_ALWAYS_COPY = 8;
const PROP_MIN_BUFFERS = 9;
const PROP_MAX_BUFFERS = 10;
const PROP_RESEND_LAST = 11;
const PROP_AUTOCONNECT = 12;
const PROP_PROVIDE_CLOCK = 13;

const DISCONNECT_NONE = 0;
const DISCONNECT_EOS = 1;
const DISCONNECT_ERROR = 2;

const Self = extern struct {
    parent: c.GstPushSrc,
    path: [*c]u8,
    target: [*c]u8,
    client_name: [*c]u8,
    stream_props: ?*c.GstStructure,
    fd: c.gint,
    keepalive: c.gint,
    on_disconnect: c.gint,
    always_copy: c.gboolean,
    min_buffers: c.gint,
    max_buffers: c.gint,
    resend_last: c.gboolean,
    autoconnect: c.gboolean,
    provide_clock: c.gboolean,
    rt: ?*Runtime,
};

const Class = extern struct {
    parent: c.GstPushSrcClass,
};

const Runtime = struct {
    owner: *Self,
    loop: ?*pw.pw_thread_loop = null,
    context: ?*pw.pw_context = null,
    core: ?*pw.pw_core = null,
    stream: ?*pw.pw_stream = null,
    hook: pw.spa_hook = .{},
    events: pw.pw_stream_events = .{},
    mutex: c.GMutex = std.mem.zeroes(c.GMutex),
    cond: c.GCond = std.mem.zeroes(c.GCond),
    queue: [QUEUE_MAX]?*c.GstBuffer = .{null} ** QUEUE_MAX,
    head: usize = 0,
    count: usize = 0,
    last: ?*c.GstBuffer = null,
    caps: ?*c.GstCaps = null,
    video: bool = true,
    info: c.GstVideoInfo = undefined,
    frame: usize = 0,
    flushing: bool = false,
    disconnected: bool = false,
    failed: bool = false,
    streaming: bool = false,
    error_text: [256]u8 = .{0} ** 256,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, SRC_CAPS);
var once: cm.Once = .{};
var disconnect_once: cm.Once = .{};
var pw_ready: usize = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn basesrc(p: anytype) [*c]c.GstBaseSrc {
    return @ptrCast(@alignCast(p));
}

fn disconnectType() c.GType {
    return disconnect_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = DISCONNECT_NONE, .value_name = "GST_PIPEWIRE_SRC_ON_DISCONNECT_NONE", .value_nick = "none" },
            .{ .value = DISCONNECT_EOS, .value_name = "GST_PIPEWIRE_SRC_ON_DISCONNECT_EOS", .value_nick = "eos" },
            .{ .value = DISCONNECT_ERROR, .value_name = "GST_PIPEWIRE_SRC_ON_DISCONNECT_ERROR", .value_nick = "error" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static("GstPipeWireSrcOnDisconnect", &values);
        }
    }.f);
}

fn setString(dst: *[*c]u8, v: [*c]const c.GValue) void {
    c.g_free(dst.*);
    dst.* = c.g_value_dup_string(v);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    cm.lock(s);
    defer cm.unlock(s);
    switch (id) {
        PROP_PATH => setString(&s.path, v),
        PROP_TARGET_OBJECT => setString(&s.target, v),
        PROP_CLIENT_NAME => setString(&s.client_name, v),
        PROP_STREAM_PROPERTIES => {
            if (s.stream_props) |p| c.gst_structure_free(p);
            const p: ?*const c.GstStructure = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
            s.stream_props = if (p) |x| c.gst_structure_copy(x) else null;
        },
        PROP_FD => s.fd = c.g_value_get_int(v),
        PROP_KEEPALIVE_TIME => s.keepalive = c.g_value_get_int(v),
        PROP_ON_DISCONNECT => s.on_disconnect = c.g_value_get_enum(v),
        PROP_ALWAYS_COPY => s.always_copy = c.g_value_get_boolean(v),
        PROP_MIN_BUFFERS => s.min_buffers = c.g_value_get_int(v),
        PROP_MAX_BUFFERS => s.max_buffers = c.g_value_get_int(v),
        PROP_RESEND_LAST => s.resend_last = c.g_value_get_boolean(v),
        PROP_AUTOCONNECT => s.autoconnect = c.g_value_get_boolean(v),
        PROP_PROVIDE_CLOCK => s.provide_clock = c.g_value_get_boolean(v),
        else => cm.warnInvalid("gstpipewiresrc.c", o, id, spec, 0),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    cm.lock(s);
    defer cm.unlock(s);
    switch (id) {
        PROP_PATH => c.g_value_set_string(v, s.path),
        PROP_TARGET_OBJECT => c.g_value_set_string(v, s.target),
        PROP_CLIENT_NAME => c.g_value_set_string(v, s.client_name),
        PROP_STREAM_PROPERTIES => c.g_value_set_boxed(v, s.stream_props),
        PROP_FD => c.g_value_set_int(v, s.fd),
        PROP_KEEPALIVE_TIME => c.g_value_set_int(v, s.keepalive),
        PROP_ON_DISCONNECT => c.g_value_set_enum(v, s.on_disconnect),
        PROP_ALWAYS_COPY => c.g_value_set_boolean(v, s.always_copy),
        PROP_MIN_BUFFERS => c.g_value_set_int(v, s.min_buffers),
        PROP_MAX_BUFFERS => c.g_value_set_int(v, s.max_buffers),
        PROP_RESEND_LAST => c.g_value_set_boolean(v, s.resend_last),
        PROP_AUTOCONNECT => c.g_value_set_boolean(v, s.autoconnect),
        PROP_PROVIDE_CLOCK => c.g_value_set_boolean(v, s.provide_clock),
        else => cm.warnInvalid("gstpipewiresrc.c", o, id, spec, 0),
    }
}

fn fail(rt: *Runtime, comptime fmt: []const u8, args: anytype) void {
    _ = std.fmt.bufPrintZ(&rt.error_text, fmt, args) catch {};
    rt.failed = true;
    c.g_cond_broadcast(&rt.cond);
}

fn onState(data: ?*anyopaque, _: pw.State, state: pw.State, err: ?[*:0]const u8) callconv(.c) void {
    const rt: *Runtime = @ptrCast(@alignCast(data));
    c.g_mutex_lock(&rt.mutex);
    defer c.g_mutex_unlock(&rt.mutex);
    switch (state) {
        pw.STATE_ERROR => fail(rt, "stream error: {s}", .{if (err) |e| std.mem.span(e) else "unknown"}),
        pw.STATE_UNCONNECTED => {
            rt.disconnected = true;
            c.g_cond_broadcast(&rt.cond);
        },
        pw.STATE_STREAMING => rt.streaming = true,
        else => {},
    }
}

fn videoCaps(rt: *Runtime, p: []const u8) ?*c.GstCaps {
    const f = pod.objectProp(p, pod.VIDEO_FORMAT) orelse return null;
    const size = pod.objectProp(p, pod.VIDEO_SIZE) orelse return null;
    var fn_: u32 = 0;
    var fd: u32 = 1;
    if (pod.objectProp(p, pod.VIDEO_FRAMERATE)) |r| {
        fn_ = r.word(0);
        fd = @max(r.word(1), 1);
    }
    const format: c.GstVideoFormat = @intCast(f.word(0));
    const w = size.word(0);
    const h = size.word(1);
    if (w == 0 or h == 0 or c.gst_video_format_to_string(format) == null) return null;
    c.gst_video_info_init(&rt.info);
    if (c.gst_video_info_set_format(&rt.info, format, w, h) == 0) return null;
    rt.info.fps_n = @intCast(fn_);
    rt.info.fps_d = @intCast(fd);
    return c.gst_video_info_to_caps(&rt.info);
}

fn audioCaps(rt: *Runtime, p: []const u8) ?*c.GstCaps {
    _ = rt;
    const f = pod.objectProp(p, pod.AUDIO_FORMAT) orelse return null;
    const rate = pod.objectProp(p, pod.AUDIO_RATE) orelse return null;
    const channels = pod.objectProp(p, pod.AUDIO_CHANNELS) orelse return null;
    const name: [*c]const u8 = switch (f.word(0)) {
        pod.S16_LE => "S16LE",
        pod.S32_LE => "S32LE",
        pod.F32_LE => "F32LE",
        else => return null,
    };
    const ch = channels.word(0);
    if (ch == 0 or rate.word(0) == 0) return null;
    const caps = c.gst_caps_new_simple("audio/x-raw", "format", c.G_TYPE_STRING, name, "layout", c.G_TYPE_STRING, "interleaved", "rate", c.G_TYPE_INT, @as(c.gint, @intCast(rate.word(0))), "channels", c.G_TYPE_INT, @as(c.gint, @intCast(ch)), @as(?*anyopaque, null));
    if (ch <= 2) {
        const mask: u64 = if (ch == 1) 0 else 0x3;
        c.gst_caps_set_simple(caps, "channel-mask", c.gst_bitmask_get_type(), mask, @as(?*anyopaque, null));
    }
    return caps;
}

fn onParam(data: ?*anyopaque, id: u32, param: ?*const pw.spa_pod) callconv(.c) void {
    const rt: *Runtime = @ptrCast(@alignCast(data));
    if (id != pod.PARAM_FORMAT) return;
    const pm = param orelse return;
    const len = 8 + @as(usize, pm.size);
    const bytes: [*]const u8 = @ptrCast(pm);
    const p = bytes[0..len];
    const caps = if (rt.video) videoCaps(rt, p) else audioCaps(rt, p);
    c.g_mutex_lock(&rt.mutex);
    if (caps) |x| {
        if (rt.caps) |old| c.gst_caps_unref(old);
        rt.caps = x;
    } else fail(rt, "unsupported format from the PipeWire node", .{});
    c.g_cond_broadcast(&rt.cond);
    c.g_mutex_unlock(&rt.mutex);
    if (caps == null) return;
    var mem: [128]u8 align(8) = undefined;
    var b = pod.Builder{ .buf = &mem };
    b.object(pod.OBJECT_BUFFERS, pod.PARAM_BUFFERS);
    b.prop(pod.BUFFERS_DATATYPE);
    b.choice(pod.CHOICE_FLAGS, pod.INT, &.{(1 << pod.DATA_MEMPTR) | (1 << pod.DATA_MEMFD)});
    b.end();
    if (b.bytes()) |out| {
        const params = [_]*const pw.spa_pod{@ptrCast(out.ptr)};
        _ = pw.pw_stream_update_params(rt.stream, &params, 1);
    }
}

fn copyVideo(rt: *Runtime, d: *const pw.spa_data, src: [*]const u8, size: usize) ?*c.GstBuffer {
    const info = &rt.info;
    if (info.finfo.*.n_planes != 1) {
        if (size < info.size) return null;
        const out = c.gst_buffer_new_allocate(null, info.size, null);
        _ = c.gst_buffer_fill(out, 0, src, info.size);
        return out;
    }
    const dst_stride: usize = @intCast(info.stride[0]);
    const chunk_stride: i32 = d.chunk.?.stride;
    const src_stride: usize = if (chunk_stride > 0) @intCast(chunk_stride) else dst_stride;
    const rows: usize = @intCast(info.height);
    const row = @min(src_stride, dst_stride);
    if (src_stride * (rows - 1) + row > size) return null;
    const out = c.gst_buffer_new_allocate(null, info.size, null);
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(out, &map, c.GST_MAP_WRITE) == 0) {
        c.gst_buffer_unref(out);
        return null;
    }
    var j: usize = 0;
    while (j < rows) : (j += 1) @memcpy(map.data[j * dst_stride ..][0..row], src[j * src_stride ..][0..row]);
    c.gst_buffer_unmap(out, &map);
    return out;
}

fn onProcess(data: ?*anyopaque) callconv(.c) void {
    const rt: *Runtime = @ptrCast(@alignCast(data));
    while (true) {
        const b = pw.pw_stream_dequeue_buffer(rt.stream) orelse return;
        defer _ = pw.pw_stream_queue_buffer(rt.stream, b);
        const sb = b.buffer orelse continue;
        if (sb.n_datas < 1) continue;
        const d = &sb.datas[0];
        const chunk = d.chunk orelse continue;
        if (d.data == null) continue;
        const off: usize = chunk.offset % @max(d.maxsize, 1);
        const size: usize = @min(chunk.size, d.maxsize - off);
        if (size == 0) continue;
        const src: [*]const u8 = @as([*]const u8, @ptrCast(d.data)) + off;
        var out: ?*c.GstBuffer = null;
        if (rt.video) {
            if (rt.caps == null) continue;
            out = copyVideo(rt, d, src, size);
        } else {
            out = c.gst_buffer_new_allocate(null, size, null);
            if (out) |x| _ = c.gst_buffer_fill(x, 0, src, size);
        }
        const buf = out orelse continue;
        c.g_mutex_lock(&rt.mutex);
        if (rt.count == QUEUE_MAX) {
            if (rt.queue[rt.head]) |old| c.gst_buffer_unref(old);
            rt.queue[rt.head] = null;
            rt.head = (rt.head + 1) % QUEUE_MAX;
            rt.count -= 1;
        }
        rt.queue[(rt.head + rt.count) % QUEUE_MAX] = buf;
        rt.count += 1;
        rt.frame += 1;
        c.g_cond_signal(&rt.cond);
        c.g_mutex_unlock(&rt.mutex);
    }
}

fn putProps(props: ?*pw.pw_properties, st: ?*c.GstStructure) void {
    const s = st orelse return;
    const n = c.gst_structure_n_fields(s);
    var i: c.gint = 0;
    while (i < n) : (i += 1) {
        const name = c.gst_structure_nth_field_name(s, @intCast(i));
        const v = c.gst_structure_get_value(s, name);
        if (v == null) continue;
        if (v.*.g_type == c.G_TYPE_STRING) {
            _ = pw.pw_properties_set(props, name, c.g_value_get_string(v));
        } else {
            const text = c.gst_value_serialize(v);
            if (text != null) {
                _ = pw.pw_properties_set(props, name, text);
                c.g_free(text);
            }
        }
    }
}

fn start(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(bs);
    if (c.g_once_init_enter(&pw_ready) != 0) {
        pw.pw_init(null, null);
        c.g_once_init_leave(&pw_ready, 1);
    }
    const rt = std.heap.c_allocator.create(Runtime) catch return 0;
    rt.* = .{ .owner = s };
    c.g_mutex_init(&rt.mutex);
    c.g_cond_init(&rt.cond);
    rt.events.state_changed = onState;
    rt.events.param_changed = onParam;
    rt.events.process = onProcess;
    s.rt = rt;
    rt.loop = pw.pw_thread_loop_new("pipewire-src", null);
    if (rt.loop == null) return startFailed(s, "could not create the PipeWire loop");
    rt.context = pw.pw_context_new(pw.pw_thread_loop_get_loop(rt.loop), null, 0);
    if (rt.context == null) return startFailed(s, "could not create the PipeWire context");
    if (pw.pw_thread_loop_start(rt.loop) < 0) return startFailed(s, "could not start the PipeWire loop");
    pw.pw_thread_loop_lock(rt.loop);
    cm.lock(s);
    const fd = s.fd;
    cm.unlock(s);
    rt.core = if (fd >= 0) pw.pw_context_connect_fd(rt.context, c.fcntl(fd, c.F_DUPFD_CLOEXEC, @as(c_int, 3)), null, 0) else pw.pw_context_connect(rt.context, null, 0);
    pw.pw_thread_loop_unlock(rt.loop);
    if (rt.core == null) return startFailed(s, "could not connect to PipeWire");
    return 1;
}

fn startFailed(s: *Self, text: [*c]const u8) c.gboolean {
    cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_FAILED, c.g_strdup(text), null, "gstpipewiresrc.c", "gst_pipewire_src_start", 0);
    teardown(s);
    return 0;
}

fn teardown(s: *Self) void {
    const rt = s.rt orelse return;
    if (rt.loop) |l| {
        pw.pw_thread_loop_lock(l);
        if (rt.stream) |st| {
            _ = pw.pw_stream_disconnect(st);
            pw.pw_stream_destroy(st);
        }
        rt.stream = null;
        if (rt.core) |co| _ = pw.pw_core_disconnect(co);
        rt.core = null;
        pw.pw_thread_loop_unlock(l);
        pw.pw_thread_loop_stop(l);
    }
    if (rt.context) |ctx| pw.pw_context_destroy(ctx);
    if (rt.loop) |l| pw.pw_thread_loop_destroy(l);
    while (rt.count > 0) {
        if (rt.queue[rt.head]) |b| c.gst_buffer_unref(b);
        rt.queue[rt.head] = null;
        rt.head = (rt.head + 1) % QUEUE_MAX;
        rt.count -= 1;
    }
    if (rt.last) |b| c.gst_buffer_unref(b);
    if (rt.caps) |x| c.gst_caps_unref(x);
    c.g_cond_clear(&rt.cond);
    c.g_mutex_clear(&rt.mutex);
    std.heap.c_allocator.destroy(rt);
    s.rt = null;
}

fn stop(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    teardown(me(bs));
    return 1;
}

const VIDEO_FORMATS = [_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_BGRx, c.GST_VIDEO_FORMAT_RGBx, c.GST_VIDEO_FORMAT_BGRA, c.GST_VIDEO_FORMAT_RGBA, c.GST_VIDEO_FORMAT_xRGB, c.GST_VIDEO_FORMAT_xBGR, c.GST_VIDEO_FORMAT_ARGB, c.GST_VIDEO_FORMAT_ABGR, c.GST_VIDEO_FORMAT_RGB, c.GST_VIDEO_FORMAT_BGR, c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_YUY2 };
const AUDIO_FORMATS = [_]struct { gst: [*c]const u8, spa: u32 }{ .{ .gst = "F32LE", .spa = pod.F32_LE }, .{ .gst = "S16LE", .spa = pod.S16_LE }, .{ .gst = "S32LE", .spa = pod.S32_LE } };

fn accepts(peer: *c.GstCaps, text: [*c]const u8) bool {
    const probe = c.gst_caps_from_string(text);
    defer c.gst_caps_unref(probe);
    return c.gst_caps_can_intersect(peer, probe) != 0;
}

fn fixedInt(peer: *c.GstCaps, field: [*c]const u8, fallback: u32) u32 {
    if (c.gst_caps_get_size(peer) == 0) return fallback;
    var v: c.gint = 0;
    if (c.gst_structure_get_int(c.gst_caps_get_structure(peer, 0), field, &v) != 0 and v > 0) return @intCast(v);
    return fallback;
}

fn formatParam(rt: *Runtime, peer: *c.GstCaps, b: *pod.Builder) bool {
    var list: [24]u32 = undefined;
    var n: usize = 1;
    b.object(pod.OBJECT_FORMAT, pod.PARAM_ENUM_FORMAT);
    b.prop(pod.MEDIA_TYPE);
    b.id(if (rt.video) pod.TYPE_VIDEO else pod.TYPE_AUDIO);
    b.prop(pod.MEDIA_SUBTYPE);
    b.id(pod.SUBTYPE_RAW);
    if (rt.video) {
        for (VIDEO_FORMATS) |f| {
            var text: [96]u8 = undefined;
            const z = std.fmt.bufPrintZ(&text, "video/x-raw,format={s}", .{std.mem.span(c.gst_video_format_to_string(f))}) catch continue;
            if (c.gst_caps_is_any(peer) != 0 or accepts(peer, z.ptr)) {
                list[n] = @intCast(f);
                n += 1;
            }
        }
        if (n == 1) return false;
        list[0] = list[1];
        b.prop(pod.VIDEO_FORMAT);
        b.choice(pod.CHOICE_ENUM, pod.ID, list[0..n]);
        b.prop(pod.VIDEO_SIZE);
        b.choice(pod.CHOICE_RANGE, pod.RECTANGLE, &.{ 1920, 1080, 1, 1, 16384, 16384 });
        b.prop(pod.VIDEO_FRAMERATE);
        b.choice(pod.CHOICE_RANGE, pod.FRACTION, &.{ 0, 1, 0, 1, 1000, 1 });
    } else {
        for (AUDIO_FORMATS) |f| {
            var text: [96]u8 = undefined;
            const z = std.fmt.bufPrintZ(&text, "audio/x-raw,format={s},layout=interleaved", .{std.mem.span(f.gst)}) catch continue;
            if (c.gst_caps_is_any(peer) != 0 or accepts(peer, z.ptr)) {
                list[n] = f.spa;
                n += 1;
            }
        }
        if (n == 1) return false;
        list[0] = list[1];
        b.prop(pod.AUDIO_FORMAT);
        b.choice(pod.CHOICE_ENUM, pod.ID, list[0..n]);
        b.prop(pod.AUDIO_RATE);
        const rate = fixedInt(peer, "rate", 48000);
        b.choice(pod.CHOICE_RANGE, pod.INT, &.{ rate, 1, 384000 });
        b.prop(pod.AUDIO_CHANNELS);
        const ch = fixedInt(peer, "channels", 2);
        b.choice(pod.CHOICE_RANGE, pod.INT, &.{ ch, 1, 64 });
    }
    b.end();
    return true;
}

fn negotiate(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(bs);
    const rt = s.rt orelse return 0;
    const pad = bs.*.srcpad;
    const peer = c.gst_pad_peer_query_caps(pad, null) orelse return 0;
    defer c.gst_caps_unref(peer);
    if (c.gst_caps_is_empty(peer) != 0) return 0;
    if (rt.stream == null) {
        rt.video = c.gst_caps_is_any(peer) != 0 or accepts(peer, "video/x-raw");
        if (!rt.video and !accepts(peer, "audio/x-raw")) return 0;
        var mem: [512]u8 align(8) = undefined;
        var b = pod.Builder{ .buf = &mem };
        if (!formatParam(rt, peer, &b)) return 0;
        const param = b.bytes() orelse return 0;
        cm.lock(s);
        const props = pw.pw_properties_new(null, @as(?*anyopaque, null));
        _ = pw.pw_properties_set(props, "media.type", if (rt.video) "Video" else "Audio");
        _ = pw.pw_properties_set(props, "media.category", "Capture");
        if (!rt.video) _ = pw.pw_properties_set(props, "media.role", "Music");
        if (s.client_name != null) _ = pw.pw_properties_set(props, "node.name", s.client_name);
        if (s.target != null) _ = pw.pw_properties_set(props, "target.object", s.target);
        putProps(props, s.stream_props);
        var flags: u32 = pw.FLAG_MAP_BUFFERS;
        if (s.autoconnect != 0) flags |= pw.FLAG_AUTOCONNECT;
        const path_id: u32 = if (s.path != null) std.fmt.parseInt(u32, std.mem.span(s.path), 10) catch pw.ID_ANY else pw.ID_ANY;
        const name = if (s.client_name != null) s.client_name else c.g_get_prgname();
        cm.unlock(s);
        pw.pw_thread_loop_lock(rt.loop);
        rt.stream = pw.pw_stream_new(rt.core, if (name != null) name else "gst-pipewire-src", props);
        if (rt.stream) |st| {
            pw.pw_stream_add_listener(st, &rt.hook, &rt.events, rt);
            const params = [_]*const pw.spa_pod{@ptrCast(param.ptr)};
            if (pw.pw_stream_connect(st, pw.DIRECTION_INPUT, path_id, flags, &params, 1) < 0) fail(rt, "could not connect the PipeWire stream", .{});
        }
        pw.pw_thread_loop_unlock(rt.loop);
        if (rt.stream == null) return 0;
    }
    c.g_mutex_lock(&rt.mutex);
    const until = c.g_get_monotonic_time() + NEGOTIATE_WAIT_US;
    while (rt.caps == null and !rt.failed and !rt.disconnected and !rt.flushing) {
        if (c.g_cond_wait_until(&rt.cond, &rt.mutex, until) == 0) break;
    }
    const caps = if (rt.caps) |x| c.gst_caps_ref(x) else null;
    const failed = rt.failed;
    c.g_mutex_unlock(&rt.mutex);
    if (caps == null) {
        if (failed) {
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_FAILED, c.g_strdup(&rt.error_text), null, "gstpipewiresrc.c", "gst_pipewire_src_negotiate", 0);
        } else cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_FORMAT, c.g_strdup("the PipeWire node did not agree on a format"), null, "gstpipewiresrc.c", "gst_pipewire_src_negotiate", 0);
        return 0;
    }
    defer c.gst_caps_unref(caps);
    return c.gst_base_src_set_caps(bs, caps);
}

fn create(ps: [*c]c.GstPushSrc, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(ps);
    const rt = s.rt orelse return c.GST_FLOW_FLUSHING;
    cm.lock(s);
    const keepalive: i64 = s.keepalive;
    const mode = s.on_disconnect;
    cm.unlock(s);
    c.g_mutex_lock(&rt.mutex);
    defer c.g_mutex_unlock(&rt.mutex);
    var resend = false;
    while (rt.count == 0) {
        if (rt.flushing) return c.GST_FLOW_FLUSHING;
        if (rt.failed) {
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_FAILED, c.g_strdup(&rt.error_text), null, "gstpipewiresrc.c", "gst_pipewire_src_create", 0);
            return c.GST_FLOW_ERROR;
        }
        if (rt.disconnected and mode != DISCONNECT_NONE) {
            if (mode == DISCONNECT_EOS) return c.GST_FLOW_EOS;
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("the PipeWire stream disconnected"), null, "gstpipewiresrc.c", "gst_pipewire_src_create", 0);
            return c.GST_FLOW_ERROR;
        }
        if (keepalive > 0 and rt.last != null) {
            if (c.g_cond_wait_until(&rt.cond, &rt.mutex, c.g_get_monotonic_time() + keepalive * std.time.us_per_ms) == 0 and rt.count == 0 and !rt.flushing) {
                resend = true;
                break;
            }
        } else c.g_cond_wait(&rt.cond, &rt.mutex);
    }
    var buf: *c.GstBuffer = undefined;
    if (resend) {
        buf = c.gst_buffer_copy(rt.last.?);
    } else {
        buf = rt.queue[rt.head].?;
        rt.queue[rt.head] = null;
        rt.head = (rt.head + 1) % QUEUE_MAX;
        rt.count -= 1;
        if (rt.last) |old| c.gst_buffer_unref(old);
        rt.last = c.gst_buffer_ref(buf);
    }
    buf.pts = cm.CLOCK_NONE;
    buf.dts = cm.CLOCK_NONE;
    buf.duration = cm.CLOCK_NONE;
    out.* = buf;
    return c.GST_FLOW_OK;
}

fn unlock(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const rt = me(bs).rt orelse return 1;
    c.g_mutex_lock(&rt.mutex);
    rt.flushing = true;
    c.g_cond_broadcast(&rt.cond);
    c.g_mutex_unlock(&rt.mutex);
    return 1;
}

fn unlockStop(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const rt = me(bs).rt orelse return 1;
    c.g_mutex_lock(&rt.mutex);
    rt.flushing = false;
    c.g_mutex_unlock(&rt.mutex);
    return 1;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    teardown(s);
    c.g_free(s.path);
    c.g_free(s.target);
    c.g_free(s.client_name);
    if (s.stream_props) |p| c.gst_structure_free(p);
    const pc: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_peek_parent(@as(*c.GTypeInstance, @ptrCast(@alignCast(o))).g_class)));
    pc.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    c.g_object_class_install_property(oc, PROP_PATH, c.g_param_spec_string("path", "Path", "The source path to connect to (NULL = default)", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_TARGET_OBJECT, c.g_param_spec_string("target-object", "Target object", "The source name/serial to connect to (NULL = default)", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_CLIENT_NAME, c.g_param_spec_string("client-name", "Client Name", "The client name to use (NULL = default)", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_STREAM_PROPERTIES, c.g_param_spec_boxed("stream-properties", "Stream properties", "List of PipeWire stream properties", c.gst_structure_get_type(), cm.RW));
    c.g_object_class_install_property(oc, PROP_FD, c.g_param_spec_int("fd", "Fd", "The fd to connect with", -1, std.math.maxInt(c.gint), -1, cm.RW));
    c.g_object_class_install_property(oc, PROP_KEEPALIVE_TIME, c.g_param_spec_int("keepalive-time", "Keepalive Time", "Periodically send last buffer (in milliseconds, 0 = disabled)", 0, std.math.maxInt(c.gint), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_ON_DISCONNECT, c.g_param_spec_enum("on-disconnect", "On disconnect", "Action to take when the stream disconnects", disconnectType(), DISCONNECT_NONE, cm.RW));
    c.g_object_class_install_property(oc, PROP_ALWAYS_COPY, c.g_param_spec_boolean("always-copy", "Always copy", "Always copy the buffer and data", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_MIN_BUFFERS, c.g_param_spec_int("min-buffers", "Min Buffers", "Minimum number of buffers to negotiate with PipeWire", 1, std.math.maxInt(c.gint), 8, cm.RW));
    c.g_object_class_install_property(oc, PROP_MAX_BUFFERS, c.g_param_spec_int("max-buffers", "Max Buffers", "Maximum number of buffers to negotiate with PipeWire", 1, std.math.maxInt(c.gint), std.math.maxInt(c.gint), cm.RW));
    c.g_object_class_install_property(oc, PROP_RESEND_LAST, c.g_param_spec_boolean("resend-last", "Resend last", "Resend last buffer on EOS", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_AUTOCONNECT, c.g_param_spec_boolean("autoconnect", "Connect automatically", "Attempt to find a peer to connect to", 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_PROVIDE_CLOCK, c.g_param_spec_boolean("provide-clock", "Provide Clock", "Provide a clock to be used as the global pipeline clock", 1, cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_pad_template(ec, c.gst_static_pad_template_get(&src_t));
    c.gst_element_class_set_static_metadata(ec, "PipeWire source", "Source/Audio/Video", "Uses PipeWire to create audio/video", "Wim Taymans <wim.taymans@gmail.com>");
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.start = start;
    bc.stop = stop;
    bc.negotiate = negotiate;
    bc.unlock = unlock;
    bc.unlock_stop = unlockStop;
    const pc: *c.GstPushSrcClass = @ptrCast(@alignCast(k));
    pc.create = create;
    _ = c._gst_debug_category_new("pipewiresrc", 0, "PipeWire Source");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.path = null;
    s.target = null;
    s.client_name = null;
    s.stream_props = null;
    s.fd = -1;
    s.keepalive = 0;
    s.on_disconnect = DISCONNECT_NONE;
    s.always_copy = 0;
    s.min_buffers = 8;
    s.max_buffers = std.math.maxInt(c.gint);
    s.resend_last = 0;
    s.autoconnect = 1;
    s.provide_clock = 1;
    s.rt = null;
    c.gst_base_src_set_live(basesrc(s), 1);
    c.gst_base_src_set_format(basesrc(s), c.GST_FORMAT_TIME);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_push_src_get_type(), "GstPipeWireSrc", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "pipewiresrc", c.GST_RANK_PRIMARY + 1, getType()) != 0;
}
