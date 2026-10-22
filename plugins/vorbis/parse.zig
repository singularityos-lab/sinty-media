const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const v = @import("vc.zig").v;
const vc = @import("common.zig");

const FILE = "../ext/vorbis/gstvorbisparse.c";
const SEC: u64 = 1_000_000_000;

pub const Parse = extern struct {
    element: c.GstElement,
    sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    packetno: c.guint,
    streamheader_sent: c.gboolean,
    streamheader: [*c]c.GList,
    event_queue: [*c]c.GQueue,
    buffer_queue: [*c]c.GQueue,
    vi: v.vorbis_info,
    vc: v.vorbis_comment,
    prev_granulepos: i64,
    prev_blocksize: i32,
    sample_rate: u32,
    channels: u32,
};

pub const Class = extern struct {
    parent: c.GstElementClass,
    parse_packet: ?*const fn (*Parse, [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn,
};

const Tag = extern struct {
    parse: Parse,
};

const TagClass = extern struct {
    parent: Class,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "audio/x-vorbis");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "audio/x-vorbis");
var once: cm.Once = .{};
var tag_once: cm.Once = .{};
var parent_class: ?*c.GstElementClass = null;
var tag_parent: ?*Class = null;

fn me(p: anytype) *Parse {
    return @ptrCast(@alignCast(p));
}

fn classOf(p: *Parse) *Class {
    return @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(p)).g_class));
}

fn setFlag(b: [*c]c.GstBuffer, f: c.guint) void {
    @as(*c.GstMiniObject, @ptrCast(@alignCast(b))).flags |= f;
}

fn appendBuffer(arr: *c.GValue, b: [*c]c.GstBuffer) void {
    var val = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&val, c.gst_buffer_get_type());
    c.gst_value_set_buffer(&val, b);
    c.gst_value_array_append_value(arr, &val);
    c.g_value_unset(&val);
}

fn headerOnCaps(p: *Parse, caps: [*c]c.GstCaps) void {
    const l = p.streamheader;
    const b1: [*c]c.GstBuffer = @ptrCast(@alignCast(l[0].data));
    const b2: [*c]c.GstBuffer = @ptrCast(@alignCast(l[0].next[0].data));
    const b3: [*c]c.GstBuffer = @ptrCast(@alignCast(l[0].next[0].next[0].data));
    const st = c.gst_caps_get_structure(caps, 0);
    setFlag(b1, c.GST_BUFFER_FLAG_HEADER);
    setFlag(b2, c.GST_BUFFER_FLAG_HEADER);
    setFlag(b3, c.GST_BUFFER_FLAG_HEADER);
    var arr = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&arr, c.gst_value_array_get_type());
    appendBuffer(&arr, b1);
    appendBuffer(&arr, b2);
    appendBuffer(&arr, b3);
    c.gst_structure_take_value(st, "streamheader", &arr);
}

fn drainEvents(p: *Parse) void {
    while (p.event_queue[0].length != 0) {
        const e: [*c]c.GstEvent = @ptrCast(@alignCast(c.g_queue_pop_head(p.event_queue)));
        _ = c.gst_pad_event_default(p.sinkpad, @ptrCast(p), e);
    }
}

fn haveHeader(p: *Parse, id: u8) bool {
    var l = p.streamheader;
    while (l != null) : (l = l[0].next) {
        var h: u8 = 0;
        if (c.gst_buffer_extract(@ptrCast(@alignCast(l[0].data)), 0, &h, 1) == 1 and h == id) return true;
    }
    return false;
}

fn headerIn(p: *Parse, b: [*c]c.GstBuffer, no: i64, bos: c_long) void {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    var pk = std.mem.zeroes(v.ogg_packet);
    pk.packet = map.data;
    pk.bytes = @intCast(map.size);
    pk.granulepos = @bitCast(b[0].offset_end);
    pk.packetno = no;
    pk.e_o_s = 0;
    pk.b_o_s = bos;
    _ = v.vorbis_synthesis_headerin(&p.vi, &p.vc, &pk);
    c.gst_buffer_unmap(b, &map);
}

fn pushHeaders(p: *Parse) bool {
    const names = [_][*:0]const u8{ "identification", "comment", "setup" };
    for ([_]u8{ 1, 3, 5 }, names) |id, n| {
        if (!haveHeader(p, id)) {
            cm.elementError(p, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, null, c.g_strdup_printf("Vorbis stream is missing %s header", n), FILE, "vorbis_parse_push_headers", 286);
            return false;
        }
    }
    const l = p.streamheader;
    const b1: [*c]c.GstBuffer = @ptrCast(@alignCast(l[0].data));
    const b2: [*c]c.GstBuffer = @ptrCast(@alignCast(l[0].next[0].data));
    const b3: [*c]c.GstBuffer = @ptrCast(@alignCast(l[0].next[0].next[0].data));
    headerIn(p, b1, 1, 1);
    p.sample_rate = @intCast(p.vi.rate);
    p.channels = @intCast(p.vi.channels);
    headerIn(p, b2, 2, 0);
    headerIn(p, b3, 3, 0);
    const caps = c.gst_caps_new_simple("audio/x-vorbis", "rate", c.G_TYPE_INT, @as(c.gint, @intCast(p.sample_rate)), "channels", c.G_TYPE_INT, @as(c.gint, @intCast(p.channels)), @as(?*anyopaque, null));
    headerOnCaps(p, caps);
    _ = cm.setCaps(p.srcpad, caps);
    c.gst_caps_unref(caps);
    drainEvents(p);
    _ = c.gst_pad_push(p.srcpad, b1);
    _ = c.gst_pad_push(p.srcpad, b2);
    _ = c.gst_pad_push(p.srcpad, b3);
    c.g_list_free(p.streamheader);
    p.streamheader = null;
    return true;
}

fn clearQueue(p: *Parse) void {
    while (p.buffer_queue[0].length != 0) c.gst_buffer_unref(@ptrCast(@alignCast(c.g_queue_pop_head(p.buffer_queue))));
    while (p.event_queue[0].length != 0) c.gst_event_unref(@ptrCast(@alignCast(c.g_queue_pop_head(p.event_queue))));
}

fn pushBuffer(p: *Parse, b: [*c]c.GstBuffer, gp: i64) c.GstFlowReturn {
    const samples = b[0].offset;
    b[0].offset_end = @bitCast(gp);
    b[0].duration = samples *% SEC / p.sample_rate;
    b[0].offset = @as(u64, @bitCast(gp)) *% SEC / p.sample_rate;
    b[0].pts = b[0].offset -% b[0].duration;
    return c.gst_pad_push(p.srcpad, b);
}

fn drainPrematurely(p: *Parse) c.GstFlowReturn {
    var gp: i64 = @max(p.prev_granulepos, 0);
    drainEvents(p);
    while (c.g_queue_is_empty(p.buffer_queue) == 0) {
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(c.g_queue_pop_head(p.buffer_queue)));
        gp +%= @bitCast(b[0].offset);
        const r = pushBuffer(p, b, gp);
        if (r != c.GST_FLOW_OK) return r;
    }
    p.prev_granulepos = gp;
    return c.GST_FLOW_OK;
}

fn drainQueue(p: *Parse, gp: i64) c.GstFlowReturn {
    var cur = gp;
    var w = p.buffer_queue[0].head;
    while (w != null) : (w = w[0].next) cur -%= @bitCast(@as([*c]c.GstBuffer, @ptrCast(@alignCast(w[0].data)))[0].offset);
    if (p.prev_granulepos != -1) cur = @max(cur, p.prev_granulepos);
    while (c.g_queue_is_empty(p.buffer_queue) == 0) {
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(c.g_queue_pop_head(p.buffer_queue)));
        cur +%= @bitCast(b[0].offset);
        const g = if (cur > gp) gp else if (cur < 0) 0 else cur;
        const r = pushBuffer(p, b, g);
        if (r != c.GST_FLOW_OK) return r;
    }
    p.prev_granulepos = gp;
    return c.GST_FLOW_OK;
}

fn queueBuffer(p: *Parse, b_in: [*c]c.GstBuffer) c.GstFlowReturn {
    const b = c.gst_buffer_make_writable(b_in);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    var pk = std.mem.zeroes(v.ogg_packet);
    pk.packet = map.data;
    pk.bytes = @intCast(map.size);
    pk.granulepos = @bitCast(b[0].offset_end);
    pk.packetno = @intCast(p.packetno + p.buffer_queue[0].length);
    pk.e_o_s = 0;
    const bs = v.vorbis_packet_blocksize(&p.vi, &pk);
    c.gst_buffer_unmap(b, &map);
    if (p.prev_blocksize < 0) {
        b[0].offset = 0;
    } else b[0].offset = @bitCast(@divTrunc(@as(i64, bs) + p.prev_blocksize, 4));
    p.prev_blocksize = @truncate(bs);
    c.g_queue_push_tail(p.buffer_queue, b);
    if (b[0].offset_end != c.GST_BUFFER_OFFSET_NONE) return drainQueue(p, @bitCast(b[0].offset_end));
    return c.GST_FLOW_OK;
}

fn parsePacket(p: *Parse, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    p.packetno += 1;
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    const header = map.size >= 1 and map.data[0] & 1 != 0;
    c.gst_buffer_unmap(b, &map);
    if (header) {
        if (p.streamheader_sent == 0) p.streamheader = c.g_list_append(p.streamheader, b);
        return c.GST_FLOW_OK;
    }
    if (p.streamheader_sent == 0) {
        if (!pushHeaders(p)) return c.GST_FLOW_ERROR;
        p.streamheader_sent = 1;
    }
    return queueBuffer(p, b);
}

fn chain(_: ?*c.GstPad, parent: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const p = me(parent);
    return classOf(p).parse_packet.?(p, b);
}

fn sinkEvent(pad: ?*c.GstPad, parent: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const p = me(parent);
    switch (cm.eventType(e)) {
        c.GST_EVENT_FLUSH_STOP => {
            clearQueue(p);
            p.prev_granulepos = -1;
            p.prev_blocksize = -1;
            return c.gst_pad_event_default(pad, parent, e);
        },
        c.GST_EVENT_EOS => {
            _ = drainPrematurely(p);
            return c.gst_pad_event_default(pad, parent, e);
        },
        else => {
            if (p.streamheader_sent == 0 and cm.eventSerialized(e) and cm.eventType(e) > c.GST_EVENT_CAPS) {
                c.g_queue_push_tail(p.event_queue, e);
                return 1;
            }
            return c.gst_pad_event_default(pad, parent, e);
        },
    }
}

fn convert(p: *Parse, pad: ?*c.GstPad, sf: c.GstFormat, sv: i64, df: *c.GstFormat, dv: *i64) bool {
    if (p.packetno < 4) return false;
    if (sf == df.*) {
        dv.* = sv;
        return true;
    }
    if (p.sinkpad == pad and (sf == c.GST_FORMAT_BYTES or df.* == c.GST_FORMAT_BYTES)) return false;
    const rate = p.vi.rate;
    const fch: u64 = @sizeOf(f32) * @as(u64, @intCast(p.vi.channels));
    const u: u64 = @bitCast(sv);
    switch (sf) {
        c.GST_FORMAT_TIME => switch (df.*) {
            c.GST_FORMAT_BYTES => dv.* = @bitCast(fch *% c.gst_util_uint64_scale_int(u, @intCast(rate), c.GST_SECOND)),
            c.GST_FORMAT_DEFAULT => dv.* = @bitCast(c.gst_util_uint64_scale_int(u, @intCast(rate), c.GST_SECOND)),
            else => return false,
        },
        c.GST_FORMAT_DEFAULT => switch (df.*) {
            c.GST_FORMAT_BYTES => dv.* = @bitCast(u *% fch),
            c.GST_FORMAT_TIME => dv.* = @bitCast(c.gst_util_uint64_scale_int(u, c.GST_SECOND, @intCast(rate))),
            else => return false,
        },
        c.GST_FORMAT_BYTES => switch (df.*) {
            c.GST_FORMAT_DEFAULT => dv.* = @bitCast(u / fch),
            c.GST_FORMAT_TIME => dv.* = @bitCast(c.gst_util_uint64_scale_int(u, c.GST_SECOND, @as(c.gint, @bitCast(@as(u32, @truncate(@as(u64, @intCast(rate)) *% fch)))))),
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
            var val: i64 = 0;
            if (!convert(p, pad, c.GST_FORMAT_DEFAULT, p.prev_granulepos, &f, &val)) return 0;
            c.gst_query_set_position(q, f, val);
            return 1;
        },
        c.GST_QUERY_DURATION => {
            if (c.gst_pad_is_linked(p.sinkpad) == 0) return 0;
            return c.gst_pad_peer_query(p.sinkpad, q);
        },
        c.GST_QUERY_CONVERT => {
            var sf: c.GstFormat = undefined;
            var df: c.GstFormat = undefined;
            var sv: i64 = 0;
            var dv: i64 = 0;
            c.gst_query_parse_convert(q, &sf, &sv, &df, &dv);
            if (!convert(p, pad, sf, sv, &df, &dv)) return 0;
            c.gst_query_set_convert(q, sf, sv, df, dv);
            return 1;
        },
        else => return c.gst_pad_query_default(pad, parent, q),
    }
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const p = me(el);
    if (t == c.GST_STATE_CHANGE_READY_TO_PAUSED) {
        v.vorbis_info_init(&p.vi);
        v.vorbis_comment_init(&p.vc);
        p.prev_granulepos = -1;
        p.prev_blocksize = -1;
        p.packetno = 0;
        p.streamheader_sent = 0;
        p.buffer_queue = c.g_queue_new();
        p.event_queue = c.g_queue_new();
    }
    const r = parent_class.?.change_state.?(el, t);
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) {
        v.vorbis_info_clear(&p.vi);
        v.vorbis_comment_clear(&p.vc);
        clearQueue(p);
        c.g_queue_free(p.buffer_queue);
        p.buffer_queue = null;
        c.g_queue_free(p.event_queue);
        p.event_queue = null;
    }
    return r;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.change_state = changeState;
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "VorbisParse", "Codec/Parser/Audio", "parse raw vorbis streams", "Thomas Vander Stichele <thomas at apestaart dot org>");
    const pc: *Class = @ptrCast(@alignCast(k));
    pc.parse_packet = parsePacket;
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
            return cm.register(c.gst_element_get_type(), "GstVorbisParse", Class, Parse, classInit, init);
        }
    }.f);
}

fn tagPacket(p: *Parse, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    const pass = map.size >= 1 and map.data[0] != 3;
    c.gst_buffer_unmap(b, &map);
    if (pass) return tag_parent.?.parse_packet.?(p, b);
    var encoder: [*c]u8 = null;
    const old = c.gst_tag_list_from_vorbiscomment_buffer(b, "\x03vorbis", 7, &encoder);
    const user = c.gst_tag_setter_get_tag_list(@ptrCast(p));
    const merged = c.gst_tag_list_merge(user, old, c.gst_tag_setter_get_tag_merge_mode(@ptrCast(p)));
    c.gst_tag_list_unref(old);
    const nb = c.gst_tag_list_to_vorbiscomment_buffer(merged, "\x03vorbis", 7, encoder);
    _ = c.gst_buffer_copy_into(nb, b, c.GST_BUFFER_COPY_TIMESTAMPS, 0, std.math.maxInt(usize));
    c.gst_tag_list_unref(merged);
    c.g_free(encoder);
    c.gst_buffer_unref(b);
    return tag_parent.?.parse_packet.?(p, nb);
}

fn tagClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    tag_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "VorbisTag", "Formatter/Metadata", "Retags vorbis streams", "James Livingston <doclivingston@gmail.com>");
    const pc: *Class = @ptrCast(@alignCast(k));
    pc.parse_packet = tagPacket;
}

fn tagInit(_: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {}

pub fn tagType() c.GType {
    return tag_once.get(struct {
        fn f() c.GType {
            const t = cm.register(getType(), "GstVorbisTag", TagClass, Tag, tagClassInit, tagInit);
            const info = c.GInterfaceInfo{ .interface_init = null, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_tag_setter_get_type(), &info);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    _ = c._gst_debug_category_new("vorbisparse", 0, "vorbis parsing element");
    vc.elementInit();
    return c.gst_element_register(p, "vorbisparse", c.GST_RANK_NONE, getType()) != 0;
}

pub fn registerTag(p: ?*c.GstPlugin) bool {
    _ = c._gst_debug_category_new("vorbistag", 0, "vorbis tagging element");
    vc.elementInit();
    return c.gst_element_register(p, "vorbistag", c.GST_RANK_NONE, tagType()) != 0;
}
