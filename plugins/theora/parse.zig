const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const t = @import("tc.zig").t;

const SEC: u64 = 1_000_000_000;

const Self = extern struct {
    element: c.GstElement,
    sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    send_streamheader: c.gboolean,
    streamheader_received: c.gboolean,
    is_old_bitstream: c.gboolean,
    streamheader: [3][*c]c.GstBuffer,
    event_queue: [*c]c.GQueue,
    buffer_queue: [*c]c.GQueue,
    info: t.th_info,
    comment: t.th_comment,
    prev_frame: i64,
    prev_keyframe: i64,
    fps_n: u32,
    fps_d: u32,
    shift: c.gint,
    granule_offset: i64,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "video/x-theora");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "video/x-theora");
var once: cm.Once = .{};
var parent_class: ?*c.GstElementClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn headerOnCaps(p: *Self, caps: [*c]c.GstCaps) void {
    const st = c.gst_caps_get_structure(caps, 0);
    var arr = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&arr, c.gst_value_array_get_type());
    for (&p.streamheader) |*b| {
        if (b.* == null) continue;
        b.* = c.gst_buffer_make_writable(b.*);
        @as(*c.GstMiniObject, @ptrCast(@alignCast(b.*))).flags |= c.GST_BUFFER_FLAG_HEADER;
        var val = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&val, c.gst_buffer_get_type());
        c.gst_value_set_buffer(&val, b.*);
        c.gst_value_array_append_value(&arr, &val);
        c.g_value_unset(&val);
    }
    c.gst_structure_take_value(st, "streamheader", &arr);
}

fn setStreamheader(p: *Self) void {
    const caps = c.gst_caps_make_writable(c.gst_pad_query_caps(p.srcpad, null));
    headerOnCaps(p, caps);
    _ = cm.setCaps(p.srcpad, caps);
    c.gst_caps_unref(caps);
    var setup: ?*t.th_setup_info = null;
    for (p.streamheader, 0..) |b, i| {
        if (b == null) continue;
        var map: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
        var pk = std.mem.zeroes(t.ogg_packet);
        pk.packet = map.data;
        pk.bytes = @intCast(map.size);
        pk.granulepos = @bitCast(b[0].offset_end);
        pk.packetno = @intCast(i + 1);
        pk.e_o_s = 0;
        pk.b_o_s = @intFromBool(i == 0);
        _ = t.th_decode_headerin(&p.info, &p.comment, &setup, &pk);
        c.gst_buffer_unmap(b, &map);
    }
    if (setup) |x| t.th_setup_free(x);
    p.fps_n = p.info.fps_numerator;
    p.fps_d = p.info.fps_denominator;
    p.shift = p.info.keyframe_granule_shift;
    const ver = (@as(u32, p.info.version_major) << 16) | (@as(u32, p.info.version_minor) << 8) | p.info.version_subminor;
    p.is_old_bitstream = @intFromBool(ver <= 0x00030200);
    p.streamheader_received = 1;
}

fn drainEvents(p: *Self) void {
    while (p.event_queue[0].length != 0) {
        const e: [*c]c.GstEvent = @ptrCast(@alignCast(c.g_queue_pop_head(p.event_queue)));
        _ = c.gst_pad_event_default(p.sinkpad, @ptrCast(p), e);
    }
}

fn pushHeaders(p: *Self) void {
    if (p.streamheader_received == 0) setStreamheader(p);
    drainEvents(p);
    for (&p.streamheader) |*b| {
        if (b.* != null) {
            _ = c.gst_pad_push(p.srcpad, b.*);
            b.* = null;
        }
    }
}

fn clearQueue(p: *Self) void {
    while (p.buffer_queue[0].length != 0) c.gst_buffer_unref(@ptrCast(@alignCast(c.g_queue_pop_head(p.buffer_queue))));
    while (p.event_queue[0].length != 0) c.gst_event_unref(@ptrCast(@alignCast(c.g_queue_pop_head(p.event_queue))));
}

fn makeGranulepos(p: *Self, kf0: i64, frame: i64) i64 {
    const kf = if (kf0 == -1) 0 else kf0;
    const iframe = if (p.is_old_bitstream == 0) kf + 1 else kf;
    if (!(frame >= kf)) {
        c.g_return_if_fail_warning(null, "make_granulepos", "frame >= keyframe");
        return -1;
    }
    const sh: u6 = @intCast(p.shift);
    if (!(frame - kf < (@as(i64, 1) << sh))) {
        c.g_return_if_fail_warning(null, "make_granulepos", "frame - keyframe < 1 << parse->shift");
        return -1;
    }
    return (iframe << sh) + (frame - kf);
}

fn parseGranulepos(p: *Self, gp: i64, keyframe: ?*i64, frame: ?*i64) void {
    const sh: u6 = @intCast(p.shift);
    var kf = gp >> sh;
    if (p.is_old_bitstream == 0) kf -= 1;
    if (keyframe) |k| k.* = kf;
    if (frame) |f| f.* = kf + (gp & ((@as(i64, 1) << sh) - 1));
}

fn isKeyframe(b: [*c]c.GstBuffer) bool {
    if (c.gst_buffer_get_size(b) == 0) return false;
    var d: u8 = 0;
    _ = c.gst_buffer_extract(b, 0, &d, 1);
    return d & 0x40 == 0;
}

fn pushBuffer(p: *Self, b: [*c]c.GstBuffer, kf: i64, frame: i64) c.GstFlowReturn {
    const this = c.gst_util_uint64_scale_int(SEC *% @as(u64, @bitCast(frame)), @bitCast(p.fps_d), @bitCast(p.fps_n));
    const next = c.gst_util_uint64_scale_int(SEC *% @as(u64, @bitCast(frame + 1)), @bitCast(p.fps_d), @bitCast(p.fps_n));
    b[0].offset_end = @bitCast(makeGranulepos(p, kf, frame));
    b[0].offset = this;
    b[0].pts = this;
    b[0].duration = next -% this;
    return c.gst_pad_push(p.srcpad, b);
}

fn markDelta(b: [*c]c.GstBuffer) void {
    @as(*c.GstMiniObject, @ptrCast(@alignCast(b))).flags |= c.GST_BUFFER_FLAG_DELTA_UNIT;
}

fn drainPrematurely(p: *Self) c.GstFlowReturn {
    drainEvents(p);
    while (c.g_queue_is_empty(p.buffer_queue) == 0) {
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(c.g_queue_pop_head(p.buffer_queue)));
        p.prev_frame += 1;
        if (isKeyframe(b)) {
            p.prev_keyframe = p.prev_frame;
        } else markDelta(b);
        if (p.prev_keyframe < 0) {
            if (b[0].offset_end != c.GST_BUFFER_OFFSET_NONE) {
                parseGranulepos(p, @bitCast(b[0].offset_end), &p.prev_keyframe, null);
            } else {
                c.gst_buffer_unref(b);
                continue;
            }
        }
        const r = pushBuffer(p, b, p.prev_keyframe, p.prev_frame);
        if (r != c.GST_FLOW_OK) return r;
    }
    return c.GST_FLOW_OK;
}

fn drainQueue(p: *Self, gp: i64) c.GstFlowReturn {
    var kf: i64 = 0;
    var frame: i64 = 0;
    parseGranulepos(p, gp, &kf, &frame);
    const prev = frame - @as(i64, c.g_queue_get_length(p.buffer_queue));
    if (prev < p.prev_frame) {
        p.prev_frame = prev;
    } else if (prev > p.prev_frame) {
        if (kf <= prev and kf > p.prev_keyframe) p.prev_keyframe = kf;
        p.prev_frame = prev;
    }
    while (c.g_queue_is_empty(p.buffer_queue) == 0) {
        p.prev_frame += 1;
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(c.g_queue_pop_head(p.buffer_queue)));
        if (isKeyframe(b)) {
            p.prev_keyframe = p.prev_frame;
        } else markDelta(b);
        const r = pushBuffer(p, b, p.prev_keyframe, p.prev_frame);
        if (r != c.GST_FLOW_OK) return r;
    }
    return c.GST_FLOW_OK;
}

fn queueBuffer(p: *Self, b_in: [*c]c.GstBuffer) c.GstFlowReturn {
    const b = c.gst_buffer_make_writable(b_in);
    c.g_queue_push_tail(p.buffer_queue, b);
    if (b[0].offset_end != c.GST_BUFFER_OFFSET_NONE) {
        if (p.prev_keyframe < 0) parseGranulepos(p, @bitCast(b[0].offset_end), &p.prev_keyframe, null);
        return drainQueue(p, @bitCast(b[0].offset_end));
    }
    return c.GST_FLOW_OK;
}

fn chain(_: ?*c.GstPad, parent: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const p = me(parent);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    const header = map.data[0];
    c.gst_buffer_unmap(b, &map);
    if (map.size >= 1 and header & 0x80 != 0) {
        if (p.send_streamheader != 0) {
            if (header >= 0x80 and header <= 0x82) p.streamheader[header - 0x80] = b;
        }
        return c.GST_FLOW_OK;
    }
    if (p.send_streamheader != 0) {
        pushHeaders(p);
        p.send_streamheader = 0;
    }
    return queueBuffer(p, b);
}

fn sinkEvent(pad: ?*c.GstPad, parent: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const p = me(parent);
    switch (cm.eventType(e)) {
        c.GST_EVENT_FLUSH_STOP => {
            clearQueue(p);
            p.prev_keyframe = -1;
            p.prev_frame = -1;
            return c.gst_pad_event_default(pad, parent, e);
        },
        c.GST_EVENT_EOS => {
            _ = drainPrematurely(p);
            return c.gst_pad_event_default(pad, parent, e);
        },
        else => {
            if (p.send_streamheader != 0 and cm.eventSerialized(e) and cm.eventType(e) > c.GST_EVENT_CAPS) {
                c.g_queue_push_tail(p.event_queue, e);
                return 1;
            }
            return c.gst_pad_event_default(pad, parent, e);
        },
    }
}

fn convert(pad: ?*c.GstPad, sf: c.GstFormat, sv: i64, df: *c.GstFormat, dv: *i64) bool {
    if (sf == df.*) {
        dv.* = sv;
        return true;
    }
    const p = me(c.gst_object_get_parent(@as([*c]c.GstObject, @ptrCast(@alignCast(pad)))));
    defer c.gst_object_unref(p);
    if (p.streamheader_received == 0) return false;
    const u: u64 = @bitCast(sv);
    const w = p.info.pic_width;
    const h = p.info.pic_height;
    switch (sf) {
        c.GST_FORMAT_BYTES => switch (df.*) {
            c.GST_FORMAT_DEFAULT => dv.* = @bitCast(c.gst_util_uint64_scale_int(u, 2, @bitCast(h *% w *% 3))),
            else => return false,
        },
        c.GST_FORMAT_TIME => {
            var scale: u64 = 1;
            switch (df.*) {
                c.GST_FORMAT_BYTES => scale = 3 * @as(u64, w *% h) / 2,
                c.GST_FORMAT_DEFAULT => {},
                else => return false,
            }
            dv.* = @bitCast(scale *% c.gst_util_uint64_scale(u, p.info.fps_numerator, @as(u64, p.info.fps_denominator) *% SEC));
        },
        c.GST_FORMAT_DEFAULT => switch (df.*) {
            c.GST_FORMAT_TIME => dv.* = @bitCast(c.gst_util_uint64_scale(u, SEC *% p.info.fps_denominator, p.info.fps_numerator)),
            c.GST_FORMAT_BYTES => dv.* = @bitCast(c.gst_util_uint64_scale_int(u, @bitCast(3 *% w *% h), 2)),
            else => return false,
        },
        else => return false,
    }
    return true;
}

fn srcQuery(pad: ?*c.GstPad, parent: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const p = me(parent);
    switch (cm.queryType(q)) {
        c.GST_QUERY_POSITION => {
            var f: c.GstFormat = undefined;
            c.gst_query_parse_position(q, &f, null);
            var mf: c.GstFormat = c.GST_FORMAT_TIME;
            var time: i64 = 0;
            if (!convert(p.sinkpad, c.GST_FORMAT_DEFAULT, p.prev_frame, &mf, &time)) return 0;
            var val: i64 = 0;
            if (!convert(pad, mf, time, &f, &val)) return 0;
            c.gst_query_set_position(q, f, val);
            return 1;
        },
        c.GST_QUERY_DURATION => return c.gst_pad_query(@ptrCast(cm.pad(p.sinkpad).peer), q),
        c.GST_QUERY_CONVERT => {
            var sf: c.GstFormat = undefined;
            var df: c.GstFormat = undefined;
            var sv: i64 = 0;
            var dv: i64 = 0;
            c.gst_query_parse_convert(q, &sf, &sv, &df, &dv);
            if (!convert(pad, sf, sv, &df, &dv)) return 0;
            c.gst_query_set_convert(q, sf, sv, df, dv);
            return 1;
        },
        else => return c.gst_pad_query_default(pad, parent, q),
    }
}

fn changeState(el: [*c]c.GstElement, tr: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const p = me(el);
    if (tr == c.GST_STATE_CHANGE_READY_TO_PAUSED) {
        t.th_info_init(&p.info);
        t.th_comment_init(&p.comment);
        p.send_streamheader = 1;
        p.buffer_queue = c.g_queue_new();
        p.event_queue = c.g_queue_new();
        p.prev_keyframe = -1;
        p.prev_frame = -1;
        p.granule_offset = 0;
    }
    const r = parent_class.?.change_state.?(el, tr);
    if (tr == c.GST_STATE_CHANGE_PAUSED_TO_READY) {
        t.th_info_clear(&p.info);
        t.th_comment_clear(&p.comment);
        clearQueue(p);
        c.g_queue_free(p.buffer_queue);
        c.g_queue_free(p.event_queue);
        p.buffer_queue = null;
        for (&p.streamheader) |*b| {
            if (b.* != null) {
                c.gst_buffer_unref(b.*);
                b.* = null;
            }
        }
        p.streamheader_received = 0;
    }
    return r;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Theora video parser", "Codec/Parser/Video", "parse raw theora streams", "Andy Wingo <wingo@pobox.com>");
    ec.change_state = changeState;
    _ = c._gst_debug_category_new("theoraparse", 0, "Theora parser");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p = me(inst);
    p.sinkpad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_chain_function_full(p.sinkpad, chain, null, null);
    c.gst_pad_set_event_function_full(p.sinkpad, sinkEvent, null, null);
    _ = c.gst_element_add_pad(&p.element, p.sinkpad);
    p.srcpad = c.gst_pad_new_from_static_template(&src_t, "src");
    c.gst_pad_set_query_function_full(p.srcpad, srcQuery, null, null);
    _ = c.gst_element_add_pad(&p.element, p.srcpad);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_element_get_type(), "GstTheoraParse", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "theoraparse", c.GST_RANK_NONE, getType()) != 0;
}
