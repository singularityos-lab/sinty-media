const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const t = @import("tc.zig").t;

const FILE = "../ext/theora/gsttheoraenc.c";
const SINK_CAPS = "video/x-raw, format = (string) { I420, Y42B, Y444 }, framerate = (fraction) [1/MAX, MAX], width = (int) [ 1, MAX ], height = (int) [ 1, MAX ]";
const SRC_CAPS = "video/x-theora, framerate = (fraction) [1/MAX, MAX], width = (int) [ 1, MAX ], height = (int) [ 1, MAX ]";
const SEC: u64 = 1_000_000_000;

const SINGLE_PASS = 0;
const FIRST_PASS = 1;
const SECOND_PASS = 2;

const PROP_BITRATE = 1;
const PROP_QUALITY = 2;
const PROP_KEYFRAME_AUTO = 3;
const PROP_KEYFRAME_FREQ = 4;
const PROP_KEYFRAME_FREQ_FORCE = 5;
const PROP_SPEEDLEVEL = 6;
const PROP_VP3_COMPATIBLE = 7;
const PROP_DROP_FRAMES = 8;
const PROP_CAP_OVERFLOW = 9;
const PROP_CAP_UNDERFLOW = 10;
const PROP_RATE_BUFFER = 11;
const PROP_MULTIPASS_CACHE_FILE = 12;
const PROP_MULTIPASS_MODE = 13;

const Self = extern struct {
    parent: c.GstVideoEncoder,
    initialised: c.gboolean,
    info: t.th_info,
    comment: t.th_comment,
    encoder: ?*t.th_enc_ctx,
    input_state: ?*c.GstVideoCodecState,
    video_bitrate: c.gint,
    bitrate_changed: c.gboolean,
    video_quality: c.gint,
    quality_changed: c.gboolean,
    keyframe_auto: c.gboolean,
    keyframe_freq: c.gint,
    keyframe_force: c.gint,
    width: c.gint,
    height: c.gint,
    fps_n: c.gint,
    fps_d: c.gint,
    granulepos_offset: u64,
    timestamp_offset: u64,
    pfn_offset: u64,
    packetno: u64,
    speed_level: c.gint,
    vp3_compatible: c.gboolean,
    drop_frames: c.gboolean,
    cap_overflow: c.gboolean,
    cap_underflow: c.gboolean,
    rate_buffer: c.gint,
    multipass_mode: c.gint,
    multipass_cache_fd: ?*c.GIOChannel,
    multipass_cache_adapter: ?*c.GstAdapter,
    multipass_cache_file: [*c]u8,
};

const Class = extern struct {
    parent: c.GstVideoEncoderClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, SRC_CAPS);
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, SINK_CAPS);
var once: cm.Once = .{};
var mode_type: c.GType = 0;
var parent_class: ?*c.GstVideoEncoderClass = null;

const modes = [_]c.GEnumValue{
    .{ .value = SINGLE_PASS, .value_name = "Single pass", .value_nick = "single-pass" },
    .{ .value = FIRST_PASS, .value_name = "First pass", .value_nick = "first-pass" },
    .{ .value = SECOND_PASS, .value_name = "Second pass", .value_nick = "second-pass" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn modeType() c.GType {
    if (mode_type == 0) mode_type = c.g_enum_register_static("GstTheoraEncMultipassMode", &modes);
    return mode_type;
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn venc(s: *Self) *c.GstVideoEncoder {
    return &s.parent;
}

fn ilog(v0: c_uint) c_int {
    var v = v0;
    var r: c_int = 0;
    while (v != 0) : (v >>= 1) r += 1;
    return r;
}

fn toTimestamp(s: *Self, gp: i64) u64 {
    if (gp < 0) return c.GST_CLOCK_TIME_NONE;
    const shift: u6 = @intCast(s.info.keyframe_granule_shift);
    const u: u64 = @bitCast(gp);
    const i = u >> shift;
    const p = u -% (i << shift);
    return c.gst_util_uint64_scale(i +% p, SEC *% s.info.fps_denominator, s.info.fps_numerator);
}

fn resError(s: *Self, code: c.gint, debug: [*c]u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_resource_error_quark(), code, null, debug, FILE, func, line);
}

fn clearCache(s: *Self) void {
    if (s.multipass_cache_fd) |fd| {
        _ = c.g_io_channel_shutdown(fd, 1, null);
        c.g_io_channel_unref(fd);
        s.multipass_cache_fd = null;
    }
    if (s.multipass_cache_adapter) |a| {
        c.gst_object_unref(a);
        s.multipass_cache_adapter = null;
    }
}

fn finalize(ob: [*c]c.GObject) callconv(.c) void {
    const s = me(ob);
    if (s.encoder) |e| t.th_encode_free(e);
    t.th_comment_clear(&s.comment);
    t.th_info_clear(&s.info);
    c.g_free(s.multipass_cache_file);
    clearCache(s);
    if (s.input_state) |x| c.gst_video_codec_state_unref(x);
    @as(*c.GObjectClass, @ptrCast(parent_class.?)).finalize.?(ob);
}

fn ctl(s: *Self, req: c_int, v: anytype) void {
    _ = t.th_encode_ctl(s.encoder, req, @ptrCast(v), @sizeOf(@TypeOf(v.*)));
}

fn flush(e: [*c]c.GstVideoEncoder) callconv(.c) c.gboolean {
    const s = me(e);
    if (s.input_state == null) return 0;
    cm.lock(s);
    s.info.target_bitrate = s.video_bitrate;
    s.info.quality = s.video_quality;
    s.bitrate_changed = 0;
    s.quality_changed = 0;
    cm.unlock(s);
    if (s.encoder) |x| t.th_encode_free(x);
    s.encoder = t.th_encode_alloc(&s.info);
    ctl(s, t.TH_ENCCTL_SET_SPLEVEL, &s.speed_level);
    ctl(s, t.TH_ENCCTL_SET_VP3_COMPATIBLE, &s.vp3_compatible);
    var flags: c_int = 0;
    if (s.drop_frames != 0) flags |= t.TH_RATECTL_DROP_FRAMES;
    if (s.drop_frames != 0) flags |= t.TH_RATECTL_CAP_OVERFLOW;
    if (s.drop_frames != 0) flags |= t.TH_RATECTL_CAP_UNDERFLOW;
    ctl(s, t.TH_ENCCTL_SET_RATE_FLAGS, &flags);
    if (s.rate_buffer != 0) ctl(s, t.TH_ENCCTL_SET_RATE_BUFFER, &s.rate_buffer);
    var force: t.ogg_uint32_t = @intCast(if (s.keyframe_auto != 0) s.keyframe_force else s.keyframe_freq);
    ctl(s, t.TH_ENCCTL_SET_KEYFRAME_FREQUENCY_FORCE, &force);
    if (s.multipass_cache_fd != null and s.multipass_mode == FIRST_PASS) _ = writeCache(s, true, false);
    return 1;
}

fn start(e: [*c]c.GstVideoEncoder) callconv(.c) c.gboolean {
    const s = me(e);
    if (s.multipass_mode >= FIRST_PASS) {
        if (s.multipass_cache_file == null) {
            cm.elementError(s, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_SETTINGS, null, null, FILE, "theora_enc_start", 441);
            return 0;
        }
        var gerr: [*c]c.GError = null;
        s.multipass_cache_fd = c.g_io_channel_new_file(s.multipass_cache_file, if (s.multipass_mode == FIRST_PASS) "w" else "r", &gerr);
        if (s.multipass_mode == SECOND_PASS) s.multipass_cache_adapter = c.gst_adapter_new();
        if (s.multipass_cache_fd == null) {
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ, null, c.g_strdup_printf("Failed to open multipass cache file: %s", gerr[0].message), FILE, "theora_enc_start", 452);
            c.g_error_free(gerr);
            return 0;
        }
        _ = c.g_io_channel_set_encoding(s.multipass_cache_fd, null, null);
    }
    s.packetno = 0;
    s.initialised = 0;
    return 1;
}

fn stop(e: [*c]c.GstVideoEncoder) callconv(.c) c.gboolean {
    const s = me(e);
    if (s.encoder) |x| t.th_encode_free(x);
    s.encoder = null;
    t.th_comment_clear(&s.comment);
    t.th_info_clear(&s.info);
    if (s.input_state) |x| c.gst_video_codec_state_unref(x);
    s.input_state = null;
    clearCache(s);
    return 1;
}

fn supportedFormats() [*c]u8 {
    var info: t.th_info = undefined;
    t.th_info_init(&info);
    info.frame_width = 16;
    info.frame_height = 16;
    info.fps_numerator = 25;
    info.fps_denominator = 1;
    var str: ?*c.GString = null;
    const fmts = [_]struct { pf: t.th_pixel_fmt, name: [*:0]const u8 }{
        .{ .pf = t.TH_PF_420, .name = "I420" },
        .{ .pf = t.TH_PF_422, .name = "Y42B" },
        .{ .pf = t.TH_PF_444, .name = "Y444" },
    };
    for (fmts) |f| {
        info.pixel_fmt = f.pf;
        const enc = t.th_encode_alloc(&info) orelse continue;
        t.th_encode_free(enc);
        if (str) |g| {
            _ = c.g_string_append(g, ", ");
            _ = c.g_string_append(g, f.name);
        } else str = c.g_string_new(f.name);
    }
    t.th_info_clear(&info);
    return if (str) |g| c.g_string_free(g, 0) else null;
}

fn getCaps(e: [*c]c.GstVideoEncoder, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const fmts = supportedFormats();
    if (fmts == null) return c.gst_caps_new_empty();
    const str = c.g_strdup_printf("video/x-raw, format = (string) { %s }, framerate = (fraction) [1/MAX, MAX], width = (int) [ 1, MAX ], height = (int) [ 1, MAX ]", fmts);
    const caps = c.gst_caps_from_string(str);
    c.g_free(str);
    c.g_free(fmts);
    const r = c.gst_video_encoder_proxy_getcaps(e, caps, filter);
    c.gst_caps_unref(caps);
    return r;
}

fn roundUp16(v: c.gint) c.guint {
    return @intCast((v + 15) & ~@as(c.gint, 15));
}

fn setFormat(e: [*c]c.GstVideoEncoder, state: [*c]c.GstVideoCodecState) callconv(.c) c.gboolean {
    const s = me(e);
    const info = &state[0].info;
    s.width = info.width;
    s.height = info.height;
    t.th_info_clear(&s.info);
    t.th_info_init(&s.info);
    s.info.frame_width = roundUp16(s.width);
    s.info.frame_height = roundUp16(s.height);
    s.info.pic_width = @intCast(s.width);
    s.info.pic_height = @intCast(s.height);
    s.info.pixel_fmt = switch (info.finfo[0].format) {
        c.GST_VIDEO_FORMAT_I420 => t.TH_PF_420,
        c.GST_VIDEO_FORMAT_Y42B => t.TH_PF_422,
        c.GST_VIDEO_FORMAT_Y444 => t.TH_PF_444,
        else => unreachable,
    };
    s.fps_n = info.fps_n;
    s.fps_d = info.fps_d;
    s.info.fps_numerator = @intCast(info.fps_n);
    s.info.fps_denominator = @intCast(info.fps_d);
    s.info.aspect_numerator = @intCast(info.par_n);
    s.info.aspect_denominator = @intCast(info.par_d);
    s.info.colorspace = t.TH_CS_UNSPECIFIED;
    if (s.input_state) |x| c.gst_video_codec_state_unref(x);
    s.input_state = c.gst_video_codec_state_ref(state);
    s.info.keyframe_granule_shift = ilog(@bitCast(s.keyframe_force - 1));
    _ = flush(e);
    s.initialised = 1;
    return 1;
}

fn prePush(e: [*c]c.GstVideoEncoder, frame: [*c]c.GstVideoCodecFrame) callconv(.c) c.GstFlowReturn {
    const s = me(e);
    var pfn: u64 = frame[0].presentation_frame_number -% @as(c.guint, @bitCast(frame[0].distance_from_sync));
    pfn -%= s.pfn_offset;
    pfn +%= s.granulepos_offset +% 1;
    const shift: u6 = @intCast(s.info.keyframe_granule_shift);
    const b = frame[0].output_buffer;
    b[0].offset_end = (pfn << shift) +% @as(u64, @bitCast(@as(i64, frame[0].distance_from_sync)));
    b[0].offset = toTimestamp(s, @bitCast(b[0].offset_end));
    return c.GST_FLOW_OK;
}

fn pushPacket(s: *Self, p: *t.ogg_packet) c.GstFlowReturn {
    const frame = c.gst_video_encoder_get_oldest_frame(venc(s));
    if (c.gst_video_encoder_allocate_output_frame(venc(s), frame, @intCast(p.bytes)) != c.GST_FLOW_OK) {
        c.gst_video_codec_frame_unref(frame);
        return c.GST_FLOW_ERROR;
    }
    if (p.bytes > 0) _ = c.gst_buffer_fill(frame[0].output_buffer, 0, p.packet, @intCast(p.bytes));
    if (p.bytes > 0 and p.packet[0] & 0x40 == 0) {
        frame[0].flags |= c.GST_VIDEO_CODEC_FRAME_FLAG_SYNC_POINT;
    } else frame[0].flags &= ~@as(c.guint32, c.GST_VIDEO_CODEC_FRAME_FLAG_SYNC_POINT);
    s.packetno += 1;
    return c.gst_video_encoder_finish_frame(venc(s), frame);
}

fn headerOnCaps(caps_in: [*c]c.GstCaps, bufs: [*c]c.GList) [*c]c.GstCaps {
    const caps = c.gst_caps_make_writable(caps_in);
    const st = c.gst_caps_get_structure(caps, 0);
    var arr = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&arr, c.gst_value_array_get_type());
    var w = bufs;
    while (w != null) : (w = w[0].next) {
        var val = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&val, c.gst_buffer_get_type());
        c.gst_value_set_buffer(&val, @as([*c]c.GstBuffer, @ptrCast(@alignCast(w[0].data))));
        c.gst_value_array_append_value(&arr, &val);
        c.g_value_unset(&val);
    }
    c.gst_structure_take_value(st, "streamheader", &arr);
    return caps;
}

fn initBuffer(buf: *t.th_ycbcr_buffer, f: *c.GstVideoFrame) void {
    var vi: c.GstVideoInfo = undefined;
    c.gst_video_info_init(&vi);
    _ = c.gst_video_info_set_format(&vi, f.info.finfo[0].format, roundUp16(f.info.width), roundUp16(f.info.height));
    const fi = f.info.finfo;
    for (0..3) |i| {
        buf[i].width = -((-vi.width) >> @intCast(vi.finfo[0].w_sub[i]));
        buf[i].height = -((-vi.height) >> @intCast(vi.finfo[0].h_sub[i]));
        const plane = fi[0].plane[i];
        buf[i].data = @as([*]u8, @ptrCast(f.data[plane].?)) + fi[0].poffset[i];
        buf[i].stride = f.info.stride[plane];
    }
}

fn readCache(s: *Self) bool {
    var stat: c.GIOStatus = c.G_IO_STATUS_NORMAL;
    var read: usize = 0;
    var used: c_int = 0;
    var done = false;
    const a = s.multipass_cache_adapter;
    while (!done) {
        if (c.gst_adapter_available(a) == 0) {
            const cb = c.gst_buffer_new_allocate(null, 512, null);
            var map: c.GstMapInfo = undefined;
            _ = c.gst_buffer_map(cb, &map, c.GST_MAP_WRITE);
            stat = c.g_io_channel_read_chars(s.multipass_cache_fd, @ptrCast(map.data), map.size, &read, null);
            c.gst_buffer_unmap(cb, &map);
            if (read <= 0) {
                c.gst_buffer_unref(cb);
                break;
            }
            c.gst_buffer_resize(cb, 0, @intCast(read));
            c.gst_adapter_push(a, cb);
        }
        if (c.gst_adapter_available(a) == 0) break;
        read = @min(c.gst_adapter_available(a), 512);
        const d = c.gst_adapter_map(a, read);
        used = t.th_encode_ctl(s.encoder, t.TH_ENCCTL_2PASS_IN, @constCast(d), read);
        c.gst_adapter_unmap(a);
        done = used <= 0;
        if (used > 0) c.gst_adapter_flush(a, @intCast(used));
    }
    if (stat == c.G_IO_STATUS_ERROR or (stat == c.G_IO_STATUS_EOF and read == 0) or used < 0) {
        resError(s, c.GST_RESOURCE_ERROR_READ, c.g_strdup("Failed to read multipass cache file"), "theora_enc_read_multipass_cache", 784);
        return false;
    }
    return true;
}

fn writeCache(s: *Self, begin: bool, eos: bool) bool {
    var gerr: [*c]c.GError = null;
    if (begin) {
        const stat = c.g_io_channel_seek_position(s.multipass_cache_fd, 0, c.G_SEEK_SET, &gerr);
        if (stat == c.G_IO_STATUS_ERROR) {
            const dbg = c.g_strdup_printf("Failed to seek to beginning of multipass cache file: %s", gerr[0].message);
            if (eos) {
                cm.elementWarning(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, null, dbg, FILE, "theora_enc_write_multipass_cache", 807);
            } else resError(s, c.GST_RESOURCE_ERROR_WRITE, dbg, "theora_enc_write_multipass_cache", 811);
            c.g_error_free(gerr);
            return false;
        }
    }
    var n: c_int = 0;
    var written: usize = 0;
    while (true) {
        var buf: [*c]u8 = null;
        n = t.th_encode_ctl(s.encoder, t.TH_ENCCTL_2PASS_OUT, @ptrCast(&buf), @sizeOf([*c]u8));
        if (n > 0) _ = c.g_io_channel_write_chars(s.multipass_cache_fd, buf, n, &written, &gerr);
        if (!(n > 0 and written > 0 and gerr == null)) break;
    }
    if (n < 0 or gerr != null) {
        if (n < 0) {
            resError(s, c.GST_RESOURCE_ERROR_WRITE, c.g_strdup_printf("Failed to read multipass cache data: %d", n), "theora_enc_write_multipass_cache", 830);
        } else resError(s, c.GST_RESOURCE_ERROR_WRITE, c.g_strdup_printf("Failed to write multipass cache file: %s", gerr[0].message), "theora_enc_write_multipass_cache", 833);
        if (gerr != null) c.g_error_free(gerr);
        return false;
    }
    return true;
}

fn resetTs(s: *Self, rt: u64, pfn: u32) void {
    s.granulepos_offset = c.gst_util_uint64_scale(rt, @intCast(s.fps_n), SEC *% @as(u64, @intCast(s.fps_d)));
    s.timestamp_offset = rt;
    s.pfn_offset = pfn;
}

fn headerBuffer(s: *Self, p: *t.ogg_packet) [*c]c.GstBuffer {
    const b = c.gst_video_encoder_allocate_output_buffer(venc(s), @intCast(p.bytes));
    _ = c.gst_buffer_fill(b, 0, p.packet, @intCast(p.bytes));
    b[0].offset = 0;
    b[0].offset_end = 0;
    b[0].pts = c.GST_CLOCK_TIME_NONE;
    b[0].duration = c.GST_CLOCK_TIME_NONE;
    @as(*c.GstMiniObject, @ptrCast(@alignCast(b))).flags |= c.GST_BUFFER_FLAG_HEADER;
    return b;
}

fn handleFrame(e: [*c]c.GstVideoEncoder, frame: [*c]c.GstVideoCodecFrame) callconv(.c) c.GstFlowReturn {
    const s = me(e);
    var op: t.ogg_packet = undefined;
    const ts = frame[0].pts;
    const rt = c.gst_segment_to_running_time(&e[0].input_segment, c.GST_FORMAT_TIME, ts);
    cm.lock(s);
    if (s.bitrate_changed != 0) {
        var br: c_long = s.video_bitrate;
        ctl(s, t.TH_ENCCTL_SET_BITRATE, &br);
        s.bitrate_changed = 0;
    }
    if (s.quality_changed != 0) {
        var q: c_long = s.video_quality;
        ctl(s, t.TH_ENCCTL_SET_QUALITY, &q);
        s.quality_changed = 0;
    }
    var force = frame[0].flags & c.GST_VIDEO_CODEC_FRAME_FLAG_FORCE_KEYFRAME != 0;
    cm.unlock(s);
    if (s.packetno == 0) {
        s.granulepos_offset = 0;
        s.timestamp_offset = 0;
        t.th_comment_clear(&s.comment);
        t.th_comment_init(&s.comment);
        var bufs: [*c]c.GList = null;
        var r: c_int = 0;
        while (true) {
            r = t.th_encode_flushheader(s.encoder, &s.comment, &op);
            if (r <= 0) break;
            bufs = c.g_list_prepend(bufs, headerBuffer(s, &op));
        }
        if (r < 0) {
            c.g_list_free_full(bufs, cm.unrefBuffer);
            c.gst_video_codec_frame_unref(frame);
            cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_ENCODE, null, c.g_strdup("libtheora has been compiled with the encoder disabled"), FILE, "theora_enc_handle_frame", 1048);
            return c.GST_FLOW_ERROR;
        }
        bufs = c.g_list_reverse(bufs);
        const caps = headerOnCaps(c.gst_caps_new_empty_simple("video/x-theora"), bufs);
        const st = c.gst_video_encoder_set_output_state(e, caps, s.input_state);
        c.gst_video_codec_state_unref(st);
        _ = c.gst_video_encoder_negotiate(e);
        c.gst_video_encoder_set_headers(e, bufs);
        resetTs(s, rt, frame[0].presentation_frame_number);
    }
    var ki: c.gint = 0;
    if (force) {
        ki = 1;
        ctl(s, t.TH_ENCCTL_SET_KEYFRAME_FREQUENCY_FORCE, &ki);
    }
    if (s.multipass_cache_fd != null and s.multipass_mode == SECOND_PASS) {
        if (!readCache(s)) {
            c.gst_video_codec_frame_unref(frame);
            return c.GST_FLOW_ERROR;
        }
    }
    var vf: c.GstVideoFrame = undefined;
    _ = c.gst_video_frame_map(&vf, &s.input_state.?.info, frame[0].input_buffer, c.GST_MAP_READ);
    var ycbcr: t.th_ycbcr_buffer = undefined;
    initBuffer(&ycbcr, &vf);
    _ = t.th_encode_ycbcr_in(s.encoder, &ycbcr);
    c.gst_video_frame_unmap(&vf);
    if (s.multipass_cache_fd != null and s.multipass_mode == FIRST_PASS) {
        if (!writeCache(s, false, false)) {
            c.gst_video_codec_frame_unref(frame);
            return c.GST_FLOW_ERROR;
        }
    }
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    while (t.th_encode_packetout(s.encoder, 0, &op) != 0) {
        if (force) {
            ki = if (s.keyframe_auto != 0) s.keyframe_force else s.keyframe_freq;
            ctl(s, t.TH_ENCCTL_SET_KEYFRAME_FREQUENCY_FORCE, &ki);
            force = false;
        }
        ret = pushPacket(s, &op);
        if (ret != c.GST_FLOW_OK) break;
    }
    c.gst_video_codec_frame_unref(frame);
    return ret;
}

fn finish(e: [*c]c.GstVideoEncoder) callconv(.c) c.GstFlowReturn {
    const s = me(e);
    if (s.initialised != 0) {
        var op: t.ogg_packet = undefined;
        while (t.th_encode_packetout(s.encoder, 1, &op) != 0) _ = pushPacket(s, &op);
    }
    if (s.initialised != 0 and s.multipass_cache_fd != null and s.multipass_mode == FIRST_PASS) _ = writeCache(s, true, true);
    clearCache(s);
    return c.GST_FLOW_OK;
}

fn proposeAllocation(e: [*c]c.GstVideoEncoder, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    c.gst_query_add_allocation_meta(q, c.gst_video_meta_api_get_type(), null);
    return parent_class.?.propose_allocation.?(e, q);
}

fn setProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(ob);
    switch (id) {
        PROP_BITRATE => {
            cm.lock(s);
            s.video_bitrate = c.g_value_get_int(v) *% 1000;
            s.video_quality = 0;
            s.bitrate_changed = 1;
            cm.unlock(s);
        },
        PROP_QUALITY => {
            cm.lock(s);
            if (!(s.parent.element.current_state >= c.GST_STATE_PAUSED and s.video_quality == 0)) {
                s.video_quality = c.g_value_get_int(v);
                s.video_bitrate = 0;
                s.quality_changed = 1;
            }
            cm.unlock(s);
        },
        PROP_KEYFRAME_AUTO => s.keyframe_auto = c.g_value_get_boolean(v),
        PROP_KEYFRAME_FREQ => s.keyframe_freq = c.g_value_get_int(v),
        PROP_KEYFRAME_FREQ_FORCE => s.keyframe_force = c.g_value_get_int(v),
        PROP_SPEEDLEVEL => s.speed_level = c.g_value_get_int(v),
        PROP_VP3_COMPATIBLE => s.vp3_compatible = c.g_value_get_boolean(v),
        PROP_DROP_FRAMES => s.drop_frames = c.g_value_get_boolean(v),
        PROP_CAP_OVERFLOW => s.cap_overflow = c.g_value_get_boolean(v),
        PROP_CAP_UNDERFLOW => s.cap_underflow = c.g_value_get_boolean(v),
        PROP_RATE_BUFFER => s.rate_buffer = c.g_value_get_int(v),
        PROP_MULTIPASS_CACHE_FILE => {
            c.g_free(s.multipass_cache_file);
            s.multipass_cache_file = c.g_value_dup_string(v);
        },
        PROP_MULTIPASS_MODE => s.multipass_mode = c.g_value_get_enum(v),
        else => cm.warnInvalid(FILE, ob, id, spec, 1147),
    }
}

fn getProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(ob);
    switch (id) {
        PROP_BITRATE => {
            cm.lock(s);
            c.g_value_set_int(v, @divTrunc(s.video_bitrate, 1000));
            cm.unlock(s);
        },
        PROP_QUALITY => {
            cm.lock(s);
            c.g_value_set_int(v, s.video_quality);
            cm.unlock(s);
        },
        PROP_KEYFRAME_AUTO => c.g_value_set_boolean(v, s.keyframe_auto),
        PROP_KEYFRAME_FREQ => c.g_value_set_int(v, s.keyframe_freq),
        PROP_KEYFRAME_FREQ_FORCE => c.g_value_set_int(v, s.keyframe_force),
        PROP_SPEEDLEVEL => c.g_value_set_int(v, s.speed_level),
        PROP_VP3_COMPATIBLE => c.g_value_set_boolean(v, s.vp3_compatible),
        PROP_DROP_FRAMES => c.g_value_set_boolean(v, s.drop_frames),
        PROP_CAP_OVERFLOW => c.g_value_set_boolean(v, s.cap_overflow),
        PROP_CAP_UNDERFLOW => c.g_value_set_boolean(v, s.cap_underflow),
        PROP_RATE_BUFFER => c.g_value_set_int(v, s.rate_buffer),
        PROP_MULTIPASS_CACHE_FILE => c.g_value_set_string(v, s.multipass_cache_file),
        PROP_MULTIPASS_MODE => c.g_value_set_enum(v, s.multipass_mode),
        else => cm.warnInvalid(FILE, ob, id, spec, 1203),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    gc.finalize = finalize;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Theora video encoder", "Codec/Encoder/Video", "encode raw YUV video to a theora stream", "Wim Taymans <wim@fluendo.com>");
    const vc: *c.GstVideoEncoderClass = @ptrCast(@alignCast(k));
    vc.start = start;
    vc.stop = stop;
    vc.flush = flush;
    vc.set_format = setFormat;
    vc.handle_frame = handleFrame;
    vc.pre_push = prePush;
    vc.finish = finish;
    vc.getcaps = getCaps;
    vc.propose_allocation = proposeAllocation;
    const RW = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    const PLAY = RW | c.GST_PARAM_MUTABLE_PLAYING;
    c.g_object_class_install_property(gc, PROP_BITRATE, c.g_param_spec_int("bitrate", "Bitrate", "Compressed video bitrate (kbps)", 0, (1 << 24) - 1, 0, PLAY));
    c.g_object_class_install_property(gc, PROP_QUALITY, c.g_param_spec_int("quality", "Quality", "Video quality", 0, 63, 48, PLAY));
    c.g_object_class_install_property(gc, PROP_KEYFRAME_AUTO, c.g_param_spec_boolean("keyframe-auto", "Keyframe Auto", "Automatic keyframe detection", 1, RW));
    c.g_object_class_install_property(gc, PROP_KEYFRAME_FREQ, c.g_param_spec_int("keyframe-freq", "Keyframe frequency", "Keyframe frequency", 1, 32768, 64, RW));
    c.g_object_class_install_property(gc, PROP_KEYFRAME_FREQ_FORCE, c.g_param_spec_int("keyframe-force", "Keyframe force", "Force keyframe every N frames", 1, 32768, 64, RW));
    c.g_object_class_install_property(gc, PROP_SPEEDLEVEL, c.g_param_spec_int("speed-level", "Speed level", "Controls the amount of motion vector searching done while encoding", 0, 3, 1, RW));
    c.g_object_class_install_property(gc, PROP_VP3_COMPATIBLE, c.g_param_spec_boolean("vp3-compatible", "VP3 compatible", "Disables non-VP3 compatible features", 0, RW));
    c.g_object_class_install_property(gc, PROP_DROP_FRAMES, c.g_param_spec_boolean("drop-frames", "Drop frames", "Allow or disallow frame dropping", 1, RW));
    c.g_object_class_install_property(gc, PROP_CAP_OVERFLOW, c.g_param_spec_boolean("cap-overflow", "Cap overflow", "Enable capping of bit reservoir overflows", 1, RW));
    c.g_object_class_install_property(gc, PROP_CAP_UNDERFLOW, c.g_param_spec_boolean("cap-underflow", "Cap underflow", "Enable capping of bit reservoir underflows", 0, RW));
    c.g_object_class_install_property(gc, PROP_RATE_BUFFER, c.g_param_spec_int("rate-buffer", "Rate Control Buffer", "Sets the size of the rate control buffer, in units of frames.  The default value of 0 instructs the encoder to automatically select an appropriate value", 0, 1000, 0, RW));
    c.g_object_class_install_property(gc, PROP_MULTIPASS_CACHE_FILE, c.g_param_spec_string("multipass-cache-file", "Multipass Cache File", "Multipass cache file", null, RW));
    c.g_object_class_install_property(gc, PROP_MULTIPASS_MODE, c.g_param_spec_enum("multipass-mode", "Multipass mode", "Single pass or first/second pass", modeType(), SINGLE_PASS, RW));
    _ = c._gst_debug_category_new("theoraenc", 0, "Theora encoder");
    c.gst_type_mark_as_plugin_api(modeType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    cm.obj(venc(s).sinkpad).flags |= c.GST_PAD_FLAG_ACCEPT_TEMPLATE;
    s.video_bitrate = 0;
    s.video_quality = 48;
    s.keyframe_auto = 1;
    s.keyframe_freq = 64;
    s.keyframe_force = 64;
    s.speed_level = 1;
    s.vp3_compatible = 0;
    s.drop_frames = 1;
    s.cap_overflow = 1;
    s.cap_underflow = 0;
    s.rate_buffer = 0;
    s.multipass_mode = SINGLE_PASS;
    s.multipass_cache_file = null;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_video_encoder_get_type(), "GstTheoraEnc", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "theoraenc", c.GST_RANK_PRIMARY, getType()) != 0;
}
