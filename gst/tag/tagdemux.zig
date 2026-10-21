const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Demux = c.GstTagDemux;
const Class = c.GstTagDemuxClass;
const Buffer = c.GstBuffer;
const NONE = el.NONE;
const PATH = "../gst-libs/gst/tag/gsttagdemux.c";
const MIN_SIZE = 8192;
const MAX_SIZE = 65536;
const BLOCKSIZE = 4096;

const State = enum { read_start_tag, typefinding, streaming };

const Private = struct {
    srcpad: ?*c.GstPad,
    sinkpad: ?*c.GstPad,
    strip_start: c.guint,
    strip_end: c.guint,
    upstream_size: i64,
    state: State,
    adapter: ?*c.GstAdapter,
    collect: [*c]Buffer,
    collect_size: usize,
    tagsize: c.guint,
    src_caps: [*c]c.GstCaps,
    event_tags: [*c]c.GstTagList,
    parsed_tags: [*c]c.GstTagList,
    send_tag_event: bool,
    segment: c.GstSegment,
    need_newseg: bool,
    segment_seqnum: u32,
    offset: u64,
    pending_events: ?*c.GList,
};

var once: gtype.Once = .{};
var offset_: c.gint = 0;
var parent: ?*c.GstElementClass = null;
var templ = c.GstStaticPadTemplate{ .name_template = "src", .direction = c.GST_PAD_SRC, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = "ANY", ._gst_reserved = .{null} ** 4 } };

fn of(p: anytype) *Demux {
    return @ptrCast(@alignCast(p));
}

fn priv(p: anytype) *Private {
    return @ptrCast(@alignCast(of(p).priv));
}

fn klass(p: anytype) *Class {
    return el.classOf(Class, p);
}

fn assert(ok: bool, line: c.gint, comptime func: []const u8, comptime expr: []const u8) void {
    if (!ok) c.g_assertion_message_expr(check.DOMAIN, PATH, line, func ++ "", expr ++ "");
}

fn typeNotFound(d: *Demux, text: [*c]const u8, debug: [*c]u8, comptime func: []const u8, line: c.gint) void {
    el.messageAt(d, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_TYPE_NOT_FOUND, if (text != null) c.g_strdup(text) else null, debug, PATH, func, line, null);
}

fn flowError(d: *Demux, flow: c.GstFlowReturn, comptime func: []const u8, line: c.gint) void {
    const text = c.g_strdup("Internal data stream error.");
    const debug = c.g_strdup_printf("streaming stopped, reason %s (%d)", c.gst_flow_get_name(flow), flow);
    el.messageAt(d, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_FAILED, text, debug, PATH, func, line, c.gst_make_element_message_details("flow-return", c.G_TYPE_INT, flow, @as(?*anyopaque, null)));
}

fn offsetValid(b: [*c]Buffer) bool {
    return b.*.offset != NONE;
}

fn baseInit(k: c.gpointer) callconv(.c) void {
    c.gst_element_class_add_static_pad_template(@ptrCast(@alignCast(k)), &templ);
    _ = c._gst_debug_category_new("tagdemux", 0, "tag demux base class");
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const tk: *Class = @ptrCast(@alignCast(k));
    const ek: *c.GstElementClass = @ptrCast(@alignCast(k));
    const ok: *c.GObjectClass = @ptrCast(@alignCast(k));
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    ok.dispose = dispose;
    ek.change_state = changeState;
    if (offset_ != 0) c.g_type_class_adjust_private_offset(k, &offset_);
    tk.min_start_size = 0;
    tk.min_end_size = 0;
}

pub export fn gst_tag_demux_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const info = c.GTypeInfo{
                .class_size = @sizeOf(Class),
                .base_init = baseInit,
                .base_finalize = null,
                .class_init = classInit,
                .class_finalize = null,
                .class_data = null,
                .instance_size = @sizeOf(Demux),
                .n_preallocs = 0,
                .instance_init = @ptrCast(&init),
                .value_table = null,
            };
            const t = c.g_type_register_static(c.gst_element_get_type(), "GstTagDemux", &info, c.G_TYPE_FLAG_ABSTRACT);
            offset_ = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

fn reset(d: *Demux) void {
    const r = priv(d);
    r.strip_start = 0;
    r.strip_end = 0;
    r.upstream_size = -1;
    r.state = .read_start_tag;
    r.send_tag_event = false;
    _ = c.gst_mini_object_replace(@ptrCast(&r.collect), null);
    r.collect_size = 0;
    r.tagsize = 0;
    c.gst_adapter_clear(r.adapter);
    _ = c.gst_mini_object_replace(@ptrCast(&r.src_caps), null);
    if (r.event_tags != null) {
        c.gst_mini_object_unref(@ptrCast(r.event_tags));
        r.event_tags = null;
    }
    if (r.parsed_tags != null) {
        c.gst_mini_object_unref(@ptrCast(r.parsed_tags));
        r.parsed_tags = null;
    }
    c.gst_segment_init(&r.segment, c.GST_FORMAT_UNDEFINED);
    r.need_newseg = true;
    r.segment_seqnum = c.gst_util_seqnum_next();
    var it = r.pending_events;
    while (it) |n| : (it = n.next) c.gst_mini_object_unref(@ptrCast(@alignCast(n.data)));
    c.g_list_free(r.pending_events);
    r.pending_events = null;
}

fn init(d: *Demux, k: *Class) callconv(.c) void {
    const ek: *c.GstElementClass = @ptrCast(k);
    d.priv = @ptrCast(@as([*]u8, @ptrCast(d)) + @as(usize, @bitCast(@as(isize, offset_))));
    const r = priv(d);
    r.* = std.mem.zeroes(Private);
    var tmpl = c.gst_element_class_get_pad_template(ek, "sink");
    if (tmpl != null) {
        r.sinkpad = c.gst_pad_new_from_template(tmpl, "sink");
        c.gst_pad_set_activatemode_function_full(r.sinkpad, sinkActivateMode, null, null);
        c.gst_pad_set_activate_function_full(r.sinkpad, sinkActivate, null, null);
        c.gst_pad_set_event_function_full(r.sinkpad, sinkEvent, null, null);
        c.gst_pad_set_chain_function_full(r.sinkpad, chain, null, null);
        _ = c.gst_element_add_pad(@ptrCast(d), r.sinkpad);
    } else {
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "GstTagDemux subclass %s must provide a sink pad template", c.g_type_name(gtype.typeOf(d)));
    }
    tmpl = c.gst_element_class_get_pad_template(ek, "src");
    r.srcpad = c.gst_pad_new_from_template(tmpl, "src");
    c.gst_pad_set_query_function_full(r.srcpad, padQuery, null, null);
    c.gst_pad_set_event_function_full(r.srcpad, srcEvent, null, null);
    c.gst_pad_set_activatemode_function_full(r.srcpad, srcActivateMode, null, null);
    c.gst_pad_set_getrange_function_full(r.srcpad, srcGetrange, null, null);
    c.gst_pad_use_fixed_caps(r.srcpad);
    _ = c.gst_element_add_pad(@ptrCast(d), r.srcpad);
    r.adapter = c.gst_adapter_new();
    reset(d);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const d = of(o);
    reset(d);
    const r = priv(d);
    if (r.adapter != null) {
        c.g_object_unref(r.adapter);
        r.adapter = null;
    }
    @as(*c.GObjectClass, @ptrCast(parent)).dispose.?(o);
}

fn setSrcCaps(d: *Demux, caps: [*c]c.GstCaps) void {
    const r = priv(d);
    if (r.src_caps != null and c.gst_caps_is_equal(caps, r.src_caps) != 0) return;
    _ = c.gst_mini_object_replace(@ptrCast(&r.src_caps), @ptrCast(caps));
    var ev = c.gst_pad_get_sticky_event(r.sinkpad, c.GST_EVENT_STREAM_START, 0);
    if (ev == null) {
        const id = c.gst_pad_create_stream_id(r.srcpad, @ptrCast(d), null);
        ev = c.gst_event_new_stream_start(id);
        c.g_free(id);
        c.gst_event_set_group_id(ev, c.gst_util_group_id_next());
    }
    _ = c.gst_pad_push_event(r.srcpad, ev);
    if (!check.that(r.src_caps != null and c.gst_caps_is_fixed(r.src_caps) != 0, "gst_pad_set_caps", "caps != NULL && gst_caps_is_fixed (caps)")) return;
    _ = c.gst_pad_push_event(r.srcpad, c.gst_event_new_caps(r.src_caps));
}

fn trim(d: *Demux, ref: *[*c]Buffer, size: *usize) bool {
    const r = priv(d);
    var b = ref.*;
    var trim_start: c.guint = 0;
    const bsize: c.guint = @intCast(c.gst_buffer_get_size(b));
    var out_size = bsize;
    var out_offset: u64 = b.*.offset;
    var fixup = false;
    if (!offsetValid(b)) {
        size.* = bsize;
        return true;
    }
    if (r.strip_end > 0 and upstreamSize(d)) {
        const v1: u64 = @bitCast(r.upstream_size - r.strip_end);
        if (out_offset >= v1) {
            c.gst_mini_object_unref(@ptrCast(b));
            ref.* = null;
            return false;
        }
        if (out_offset + out_size > v1) {
            out_size = @truncate(v1 - out_offset);
            fixup = true;
        }
    }
    if (r.strip_start > 0) {
        if (out_offset <= r.strip_start) {
            if (out_offset + out_size <= r.strip_start) {
                c.gst_mini_object_unref(@ptrCast(b));
                ref.* = null;
                return true;
            }
            trim_start = @truncate(r.strip_start - out_offset);
            out_size -= trim_start;
            out_offset = 0;
        } else out_offset -= r.strip_start;
        fixup = true;
    }
    if (!fixup) return true;
    const writable = c.gst_mini_object_is_writable(@ptrCast(b)) != 0;
    if (out_size != bsize or !writable) {
        if (!writable) {
            const sub = c.gst_buffer_copy_region(b, c.GST_BUFFER_COPY_ALL, trim_start, out_size);
            if (!check.that(sub != null, "gst_tag_demux_trim_buffer", "sub != NULL")) return false;
            if (b.*.pts != NONE) sub.*.pts = b.*.pts;
            if (b.*.duration != NONE) sub.*.duration = b.*.duration;
            c.gst_mini_object_unref(@ptrCast(b));
            b = sub;
            ref.* = sub;
            size.* = out_size;
        } else c.gst_buffer_resize(b, trim_start, out_size);
    }
    b.*.offset = out_offset;
    b.*.offset_end = out_offset + out_size;
    return true;
}

fn updateCollected(d: *Demux) void {
    const r = priv(d);
    const avail = c.gst_adapter_available(r.adapter);
    if (avail == 0) return;
    const b = c.gst_adapter_take_buffer(r.adapter, avail);
    r.collect = if (r.collect == null) b else c.gst_buffer_append(r.collect, b);
    r.collect_size += avail;
}

fn chainParseTag(d: *Demux) void {
    const r = priv(d);
    const available: c.guint = @intCast(r.collect_size + c.gst_adapter_available(r.adapter));
    const k = klass(d);
    if (available < k.min_start_size) return;
    if (available < r.tagsize) return;
    updateCollected(d);
    r.collect = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(r.collect))));
    const collect = r.collect;
    if (offsetValid(collect) and collect.*.offset != 0) {
        r.state = .typefinding;
        return;
    }
    assert(k.identify_tag != null, 550, "gst_tag_demux_chain_parse_tag", "klass->identify_tag != NULL");
    assert(k.parse_tag != null, 551, "gst_tag_demux_chain_parse_tag", "klass->parse_tag != NULL");
    var tagsize: c.guint = 0;
    if (k.identify_tag.?(d, collect, 1, &tagsize) == 0) {
        r.state = .typefinding;
        return;
    }
    r.tagsize = tagsize;
    if (!offsetValid(collect)) collect.*.offset = 0;
    while (true) {
        var list: [*c]c.GstTagList = null;
        r.strip_start = tagsize;
        if (available < tagsize) return;
        const saved = c.gst_buffer_get_size(collect);
        c.gst_buffer_set_size(collect, tagsize);
        var newsize = tagsize;
        const res = k.parse_tag.?(d, collect, 1, &newsize, &list);
        c.gst_buffer_set_size(collect, @intCast(saved));
        switch (res) {
            c.GST_TAG_DEMUX_RESULT_OK, c.GST_TAG_DEMUX_RESULT_BROKEN_TAG => {
                r.strip_start = newsize;
                r.parsed_tags = list;
            },
            c.GST_TAG_DEMUX_RESULT_AGAIN => {
                assert(newsize != tagsize, 603, "gst_tag_demux_chain_parse_tag", "newsize != tagsize");
                tagsize = newsize;
                continue;
            },
            else => {},
        }
        break;
    }
    r.state = .typefinding;
    r.send_tag_event = true;
}

fn chainBuffer(d: *Demux, b: [*c]Buffer, at_eos: bool) c.GstFlowReturn {
    const r = priv(d);
    const size = c.gst_buffer_get_size(b);
    if (r.segment.format == c.GST_FORMAT_BYTES) {
        if (offsetValid(b)) r.segment.position = b.*.offset;
        r.segment.position +%= size;
    } else if (r.segment.format == c.GST_FORMAT_TIME) {
        if (b.*.pts != NONE) r.segment.position = b.*.pts;
        if (b.*.duration != NONE) r.segment.position +%= b.*.duration;
    }
    c.gst_adapter_push(r.adapter, b);
    var st = r.state;
    if (st == .read_start_tag) {
        chainParseTag(d);
        if (r.state != .typefinding) return c.GST_FLOW_OK;
        st = .typefinding;
    }
    if (st == .typefinding) {
        var prob: c.GstTypeFindProbability = 0;
        var tf_size: usize = 0;
        updateCollected(d);
        if (!at_eos and r.collect_size < MIN_SIZE + r.strip_start) return c.GST_FLOW_OK;
        var tf = r.collect;
        if (tf != null) {
            _ = c.gst_mini_object_ref(@ptrCast(tf));
            if (!trim(d, &tf, &tf_size)) return c.GST_FLOW_EOS;
        }
        if (tf == null) return c.GST_FLOW_OK;
        const caps = c.gst_type_find_helper_for_buffer(@ptrCast(d), tf, &prob);
        if (caps == null) {
            if (tf_size < MAX_SIZE) {
                c.gst_mini_object_unref(@ptrCast(tf));
                return c.GST_FLOW_OK;
            }
            typeNotFound(d, null, c.g_strdup("Could not detect type for contents within tag"), "gst_tag_demux_chain_buffer", 680);
            c.gst_mini_object_unref(@ptrCast(tf));
            c.gst_mini_object_unref(@ptrCast(r.collect));
            r.collect = null;
            r.collect_size = 0;
            return c.GST_FLOW_ERROR;
        }
        c.gst_mini_object_unref(@ptrCast(tf));
        setSrcCaps(d, caps);
        c.gst_mini_object_unref(@ptrCast(caps));
        r.state = .streaming;
    }
    var out: [*c]Buffer = null;
    var out_size: usize = 0;
    updateCollected(d);
    if (r.collect != null) {
        out = r.collect;
        r.collect = null;
        r.collect_size = 0;
        if (!trim(d, &out, &out_size)) return c.GST_FLOW_EOS;
    }
    if (out != null) {
        if (r.need_newseg) {
            _ = sendNewSegment(d);
            r.need_newseg = false;
        }
        sendPendingEvents(d);
        if (r.send_tag_event) {
            sendTagEvent(d);
            r.send_tag_event = false;
        }
        return c.gst_pad_push(r.srcpad, out);
    }
    return c.GST_FLOW_OK;
}

fn chain(_: ?*c.GstPad, p: [*c]c.GstObject, b: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    return chainBuffer(of(p), b, false);
}

fn sinkEvent(pd: ?*c.GstPad, p: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const d = of(p);
    const r = priv(d);
    switch (ev.*.type) {
        c.GST_EVENT_EOS => {
            if (c.gst_pad_has_current_caps(r.srcpad) == 0) {
                _ = chainBuffer(d, c.gst_buffer_new(), true);
                if (c.gst_pad_has_current_caps(r.srcpad) == 0) typeNotFound(d, null, null, "gst_tag_demux_sink_event", 766);
            }
            return c.gst_pad_event_default(pd, p, ev);
        },
        c.GST_EVENT_SEGMENT => {
            c.gst_event_copy_segment(ev, &r.segment);
            r.segment_seqnum = c.gst_event_get_seqnum(ev);
            r.need_newseg = true;
            c.gst_mini_object_unref(@ptrCast(ev));
            return 1;
        },
        c.GST_EVENT_FLUSH_STOP, c.GST_EVENT_FLUSH_START, c.GST_EVENT_CAPS => return c.gst_pad_event_default(pd, p, ev),
        else => {
            if (r.need_newseg and ev.*.type & c.GST_EVENT_TYPE_SERIALIZED != 0) {
                el.lock(d);
                r.pending_events = c.g_list_append(r.pending_events, ev);
                el.unlock(d);
                return 1;
            }
            return c.gst_pad_event_default(pd, p, ev);
        },
    }
}

fn upstreamSize(d: *Demux) bool {
    const r = priv(d);
    if (r.upstream_size > 0) return true;
    var len: i64 = 0;
    if (c.gst_pad_peer_query_duration(r.sinkpad, c.GST_FORMAT_BYTES, &len) == 0 or len <= 0) return false;
    r.upstream_size = len;
    return true;
}

fn adjustSeek(d: *Demux, start_type: c.GstSeekType, start: *i64, stop_type: c.GstSeekType, stop: *i64) void {
    const r = priv(d);
    switch (start_type) {
        c.GST_SEEK_TYPE_SET => {
            if (start.* == -1) start.* = 0;
            start.* += r.strip_start;
        },
        c.GST_SEEK_TYPE_END => {
            if (start.* > 0) start.* = 0;
            start.* -= r.strip_end;
        },
        else => {},
    }
    switch (stop_type) {
        c.GST_SEEK_TYPE_SET => {
            if (stop.* != -1) stop.* += r.strip_start;
        },
        c.GST_SEEK_TYPE_END => {
            if (stop.* > 0) stop.* = 0;
            stop.* -= r.strip_end;
        },
        else => {},
    }
}

fn seekPull(d: *Demux, ev: [*c]c.GstEvent) bool {
    const r = priv(d);
    var rate: f64 = 0;
    var format: c.GstFormat = 0;
    var flags: c.GstSeekFlags = 0;
    var start_type: c.GstSeekType = 0;
    var stop_type: c.GstSeekType = 0;
    var start: i64 = 0;
    var stop: i64 = 0;
    c.gst_event_parse_seek(ev, &rate, &format, &flags, &start_type, &start, &stop_type, &stop);
    if (format != c.GST_FORMAT_BYTES) return false;
    if (r.state != .streaming) return false;
    adjustSeek(d, start_type, &start, stop_type, &stop);
    var seg = r.segment;
    _ = c.gst_segment_do_seek(&seg, rate, format, flags, start_type, @bitCast(start), stop_type, @bitCast(stop), null);
    const flush = flags & c.GST_SEEK_FLAG_FLUSH != 0;
    if (flush) {
        _ = c.gst_pad_push_event(r.sinkpad, c.gst_event_new_flush_start());
        _ = c.gst_pad_push_event(r.srcpad, c.gst_event_new_flush_start());
    } else _ = c.gst_pad_pause_task(r.sinkpad);
    el.streamLock(r.sinkpad);
    if (flush) {
        _ = c.gst_pad_push_event(r.sinkpad, c.gst_event_new_flush_stop(1));
        _ = c.gst_pad_push_event(r.srcpad, c.gst_event_new_flush_stop(1));
    }
    r.segment = seg;
    r.offset = r.segment.start;
    if (r.segment.flags & c.GST_SEGMENT_FLAG_SEGMENT != 0) {
        const msg = c.gst_message_new_segment_start(@ptrCast(d), c.GST_FORMAT_BYTES, @bitCast(r.segment.start));
        _ = c.gst_element_post_message(@ptrCast(d), msg);
    }
    r.need_newseg = true;
    _ = c.gst_pad_start_task(r.sinkpad, elementLoop, d, null);
    el.streamUnlock(r.sinkpad);
    return true;
}

fn seekPush(d: *Demux, ev: [*c]c.GstEvent) bool {
    const r = priv(d);
    var rate: f64 = 0;
    var format: c.GstFormat = 0;
    var flags: c.GstSeekFlags = 0;
    var start_type: c.GstSeekType = 0;
    var stop_type: c.GstSeekType = 0;
    var start: i64 = 0;
    var stop: i64 = 0;
    c.gst_event_parse_seek(ev, &rate, &format, &flags, &start_type, &start, &stop_type, &stop);
    if (format == c.GST_FORMAT_BYTES and r.state == .streaming and c.gst_pad_is_linked(r.sinkpad) != 0) {
        adjustSeek(d, start_type, &start, stop_type, &stop);
        const up = c.gst_event_new_seek(rate, format, flags, start_type, start, stop_type, stop);
        c.gst_event_set_seqnum(up, c.gst_event_get_seqnum(ev));
        return c.gst_pad_push_event(r.sinkpad, up) != 0;
    } else if (format == c.GST_FORMAT_TIME and r.state == .streaming and c.gst_pad_is_linked(r.sinkpad) != 0) {
        return c.gst_pad_push_event(r.sinkpad, @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(ev))))) != 0;
    }
    return false;
}

fn srcEvent(_: ?*c.GstPad, p: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const d = of(p);
    const r = priv(d);
    if (ev.*.type == c.GST_EVENT_SEEK) {
        const res = if (el.mode(r.sinkpad) == c.GST_PAD_MODE_PUSH) seekPush(d, ev) else seekPull(d, ev);
        c.gst_mini_object_unref(@ptrCast(ev));
        return @intFromBool(res);
    }
    return c.gst_pad_push_event(r.sinkpad, ev);
}

fn pullTag(d: *Demux, list: *[*c]c.GstTagList, comptime start: bool) c.GstFlowReturn {
    const r = priv(d);
    const k = klass(d);
    const fname = if (start) "gst_tag_demux_pull_start_tag" else "gst_tag_demux_pull_end_tag";
    assert(k.identify_tag != null, if (start) 1200 else 1063, fname, "klass->identify_tag != NULL");
    assert(k.parse_tag != null, if (start) 1201 else 1064, fname, "klass->parse_tag != NULL");
    const min = if (start) k.min_start_size else k.min_end_size;
    if (min == 0) return c.GST_FLOW_OK;
    var offset: u64 = 0;
    var req: c.guint = 0;
    if (start) {
        req = @max(min, 4096);
    } else {
        if (r.upstream_size < min) return c.GST_FLOW_OK;
        offset = @bitCast(r.upstream_size - min);
        req = min;
    }
    var new_tags: [*c]c.GstTagList = null;
    var b: [*c]Buffer = null;
    defer {
        if (new_tags != null) c.gst_mini_object_unref(@ptrCast(new_tags));
        if (b != null) c.gst_mini_object_unref(@ptrCast(b));
    }
    var flow = c.gst_pad_pull_range(r.sinkpad, offset, req, &b);
    if (flow != c.GST_FLOW_OK) return flow;
    var bsize = c.gst_buffer_get_size(b);
    if (bsize < min) return c.GST_FLOW_EOS;
    var tagsize: c.guint = 0;
    if (k.identify_tag.?(d, b, @intFromBool(start), &tagsize) == 0) return c.GST_FLOW_OK;
    while (true) {
        if (start) r.strip_start = tagsize else r.strip_end = tagsize;
        assert(tagsize >= min, if (start) 1244 else 1113, fname, if (start) "tagsize >= klass->min_start_size" else "tagsize >= klass->min_end_size");
        if ((start and bsize < tagsize) or (!start and bsize != tagsize)) {
            c.gst_mini_object_unref(@ptrCast(b));
            b = null;
            if (!start) offset = @bitCast(r.upstream_size - tagsize);
            flow = c.gst_pad_pull_range(r.sinkpad, offset, tagsize, &b);
            if (flow != c.GST_FLOW_OK) return flow;
            bsize = c.gst_buffer_get_size(b);
            if (bsize < tagsize) {
                if (start) el.messageAt(d, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_DECODE, c.g_strdup(c.g_dgettext("gst-plugins-base-1.0", "Failed to read tag: not enough data")), null, PATH, "gst_tag_demux_pull_start_tag", 1262, null);
                return c.GST_FLOW_EOS;
            }
        }
        if (!start) b.*.offset = offset;
        const saved = bsize;
        c.gst_buffer_set_size(b, tagsize);
        var newsize = tagsize;
        const res = k.parse_tag.?(d, b, @intFromBool(start), &newsize, &new_tags);
        c.gst_buffer_set_size(b, @intCast(saved));
        switch (res) {
            c.GST_TAG_DEMUX_RESULT_OK, c.GST_TAG_DEMUX_RESULT_BROKEN_TAG => {
                flow = c.GST_FLOW_OK;
                if (start) r.strip_start = newsize else r.strip_end = newsize;
            },
            c.GST_TAG_DEMUX_RESULT_AGAIN => {
                assert(newsize != tagsize, if (start) 1290 else 1167, fname, "newsize != tagsize");
                tagsize = newsize;
                continue;
            },
            else => {},
        }
        break;
    }
    list.* = new_tags;
    new_tags = null;
    return flow;
}

fn readRangeFn(o: [*c]c.GstObject, p: [*c]c.GstObject, offset: u64, length: c.guint, b: [*c][*c]Buffer) callconv(.c) c.GstFlowReturn {
    return readRange(of(o), p, offset, length, b);
}

fn elementFind(d: *Demux) c.GstFlowReturn {
    const r = priv(d);
    const fname = "gst_tag_demux_element_find";
    if (!upstreamSize(d)) {
        typeNotFound(d, "Could not get stream size", null, fname, 1411);
        return c.GST_FLOW_ERROR;
    }
    r.strip_start = 0;
    r.strip_end = 0;
    var start_tags: [*c]c.GstTagList = null;
    var end_tags: [*c]c.GstTagList = null;
    var ret = pullTag(d, &start_tags, true);
    if (ret != c.GST_FLOW_OK and ret != c.GST_FLOW_EOS) return readError(d, ret);
    const s_ok = ret == c.GST_FLOW_OK;
    ret = pullTag(d, &end_tags, false);
    if (ret != c.GST_FLOW_OK and ret != c.GST_FLOW_EOS) return readError(d, ret);
    const e_ok = ret == c.GST_FLOW_OK;
    ret = c.GST_FLOW_OK;
    const k = klass(d);
    r.parsed_tags = if (k.merge_tags) |m| m(d, start_tags, end_tags) else c.gst_tag_list_merge(end_tags, start_tags, c.GST_TAG_MERGE_REPLACE);
    if (start_tags != null) c.gst_mini_object_unref(@ptrCast(start_tags));
    if (end_tags != null) c.gst_mini_object_unref(@ptrCast(end_tags));
    if (!e_ok and !s_ok) {
        typeNotFound(d, "Could not get start and/or end tag", null, fname, 1423);
        return c.GST_FLOW_ERROR;
    }
    if (r.parsed_tags != null) r.send_tag_event = true;
    if (r.upstream_size <= @as(i64, r.strip_start + r.strip_end)) {
        typeNotFound(d, "No data in file", null, fname, 1431);
        return c.GST_FLOW_ERROR;
    }
    if (el.mode(r.srcpad) != c.GST_PAD_MODE_PULL) {
        var caps: [*c]c.GstCaps = null;
        var prob: c.GstTypeFindProbability = 0;
        ret = c.gst_type_find_helper_get_range_full(@ptrCast(d), null, readRangeFn, @bitCast(r.upstream_size - (r.strip_start + r.strip_end)), null, &caps, &prob);
        if (ret != c.GST_FLOW_OK) return readError(d, ret);
        if (caps == null) {
            typeNotFound(d, "Could not detect type of contents", null, fname, 1437);
            return c.GST_FLOW_ERROR;
        }
        r.state = .streaming;
        setSrcCaps(d, caps);
        c.gst_mini_object_unref(@ptrCast(caps));
    }
    r.state = .streaming;
    r.offset += r.strip_start;
    return ret;
}

fn readError(d: *Demux, ret: c.GstFlowReturn) c.GstFlowReturn {
    if (ret == c.GST_FLOW_NOT_LINKED or ret < c.GST_FLOW_EOS) flowError(d, ret, "gst_tag_demux_element_find", 1418);
    return ret;
}

fn elementLoop(data: c.gpointer) callconv(.c) void {
    const d = of(data);
    const r = priv(d);
    var ret: c.GstFlowReturn = undefined;
    switch (r.state) {
        .read_start_tag, .typefinding => ret = elementFind(d),
        .streaming => {
            if (r.need_newseg) {
                r.need_newseg = false;
                _ = sendNewSegment(d);
            }
            if (r.send_tag_event) {
                sendTagEvent(d);
                r.send_tag_event = false;
            }
            var out: [*c]Buffer = null;
            ret = c.gst_pad_pull_range(r.sinkpad, r.offset, BLOCKSIZE, &out);
            if (ret == c.GST_FLOW_OK) {
                out.*.offset = r.offset - r.strip_start;
                r.offset += c.gst_buffer_get_size(out);
                out.*.offset_end = r.offset - r.strip_start;
                ret = c.gst_pad_push(r.srcpad, out);
            }
        },
    }
    if (ret == c.GST_FLOW_OK) return;
    var push_eos = false;
    _ = c.gst_pad_pause_task(r.sinkpad);
    if (ret == c.GST_FLOW_EOS) {
        if (r.segment.flags & c.GST_SEEK_FLAG_SEGMENT != 0) {
            var stop: i64 = @bitCast(r.segment.stop);
            if (stop == -1) stop = @bitCast(r.offset);
            _ = c.gst_element_post_message(@ptrCast(d), c.gst_message_new_segment_done(@ptrCast(d), c.GST_FORMAT_BYTES, stop));
            _ = c.gst_pad_push_event(r.srcpad, c.gst_event_new_segment_done(c.GST_FORMAT_BYTES, stop));
        } else push_eos = true;
    } else if (ret == c.GST_FLOW_NOT_LINKED or ret < c.GST_FLOW_EOS) {
        flowError(d, ret, "gst_tag_demux_element_loop", 1532);
        push_eos = true;
    }
    if (push_eos) _ = c.gst_pad_push_event(r.srcpad, c.gst_event_new_eos());
}

fn sinkActivateMode(pd: ?*c.GstPad, p: [*c]c.GstObject, m: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    const r = priv(p);
    var res: c.gboolean = 1;
    if (m == c.GST_PAD_MODE_PULL) {
        if (active != 0) {
            r.need_newseg = true;
            r.offset = 0;
        } else res = c.gst_pad_stop_task(pd);
    }
    if (active != 0) r.state = .read_start_tag;
    return res;
}

fn sinkActivate(pd: ?*c.GstPad, p: [*c]c.GstObject) callconv(.c) c.gboolean {
    const q = c.gst_query_new_scheduling();
    if (c.gst_pad_peer_query(pd, q) == 0) {
        c.gst_mini_object_unref(@ptrCast(q));
        return c.gst_pad_activate_mode(pd, c.GST_PAD_MODE_PUSH, 1);
    }
    const pull = c.gst_query_has_scheduling_mode_with_flags(q, c.GST_PAD_MODE_PULL, c.GST_SCHEDULING_FLAG_SEEKABLE) != 0;
    c.gst_mini_object_unref(@ptrCast(q));
    if (!pull or c.gst_pad_activate_mode(pd, c.GST_PAD_MODE_PULL, 1) == 0) return c.gst_pad_activate_mode(pd, c.GST_PAD_MODE_PUSH, 1);
    return c.gst_pad_start_task(pd, elementLoop, p, null);
}

fn srcActivateMode(_: ?*c.GstPad, p: [*c]c.GstObject, m: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    if (m != c.GST_PAD_MODE_PULL) return 1;
    const r = priv(p);
    _ = c.gst_pad_pause_task(r.sinkpad);
    return c.gst_pad_activate_mode(r.sinkpad, m, active);
}

fn ensureTags(d: *Demux) c.GstFlowReturn {
    const r = priv(d);
    if (r.state == .read_start_tag and el.mode(r.srcpad) == c.GST_PAD_MODE_PULL) return elementFind(d);
    return c.GST_FLOW_OK;
}

fn readRange(d: *Demux, _: [*c]c.GstObject, offset: u64, length: c.guint, b: [*c][*c]Buffer) c.GstFlowReturn {
    if (!check.that(b != null, "gst_tag_demux_read_range", "buffer != NULL")) return c.GST_FLOW_ERROR;
    var ret = ensureTags(d);
    if (ret != c.GST_FLOW_OK) return ret;
    const r = priv(d);
    const in_offset = offset +% r.strip_start;
    if (!upstreamSize(d)) return c.GST_FLOW_ERROR;
    const limit: u64 = @bitCast(r.upstream_size - r.strip_end);
    var in_length: c.guint = length;
    if (in_offset +% length >= limit) {
        if (in_offset +% r.strip_end >= @as(u64, @bitCast(r.upstream_size))) return c.GST_FLOW_EOS;
        in_length = @truncate(limit -% in_offset);
    }
    ret = c.gst_pad_pull_range(r.sinkpad, in_offset, in_length, b);
    if (ret == c.GST_FLOW_OK and b[0] != null) {
        var size: usize = 0;
        const bp: *[*c]Buffer = @ptrCast(b);
        if (!trim(d, bp, &size)) {
            if (b[0] != null) {
                c.gst_mini_object_unref(@ptrCast(b[0]));
                b[0] = null;
            }
            return c.GST_FLOW_EOS;
        }
        assert(b[0] != null, 1691, "gst_tag_demux_read_range", "*buffer != NULL");
    }
    return ret;
}

fn srcGetrange(_: ?*c.GstPad, p: [*c]c.GstObject, offset: u64, length: c.guint, b: [*c][*c]Buffer) callconv(.c) c.GstFlowReturn {
    const d = of(p);
    const r = priv(d);
    if (r.need_newseg) {
        sendPendingEvents(d);
        r.need_newseg = false;
    }
    if (r.send_tag_event) {
        sendTagEvent(d);
        r.send_tag_event = false;
    }
    return readRange(d, null, offset, length, b);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const ret = parent.?.change_state.?(e, t);
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) {
        const r = priv(e);
        el.streamLock(r.srcpad);
        reset(of(e));
        el.streamUnlock(r.srcpad);
    }
    return ret;
}

fn padQuery(pd: ?*c.GstPad, p: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const d = of(p);
    const r = priv(d);
    var format: c.GstFormat = 0;
    var result: i64 = 0;
    switch (q.*.type) {
        c.GST_QUERY_SCHEDULING => return c.gst_pad_peer_query(r.sinkpad, q),
        c.GST_QUERY_POSITION => {
            if (c.gst_pad_peer_query(r.sinkpad, q) == 0) return 0;
            c.gst_query_parse_position(q, &format, &result);
            if (format == c.GST_FORMAT_BYTES) {
                result -= r.strip_start;
                c.gst_query_set_position(q, format, result);
            }
            return 1;
        },
        c.GST_QUERY_DURATION => {
            if (c.gst_pad_peer_query(r.sinkpad, q) == 0) return 0;
            c.gst_query_parse_duration(q, &format, &result);
            if (format == c.GST_FORMAT_BYTES) {
                _ = ensureTags(d);
                result -= r.strip_start +% r.strip_end;
                if (result < 0) result = 0;
                c.gst_query_set_duration(q, format, result);
            }
            return 1;
        },
        else => return c.gst_pad_query_default(pd, p, q),
    }
}

fn sendPendingEvents(d: *Demux) void {
    const r = priv(d);
    el.lock(d);
    var events = r.pending_events;
    r.pending_events = null;
    el.unlock(d);
    while (events) |n| {
        _ = c.gst_pad_push_event(r.srcpad, @ptrCast(@alignCast(n.data)));
        events = c.g_list_delete_link(events, n);
    }
}

fn sendTagEvent(d: *Demux) void {
    const r = priv(d);
    const merged = c.gst_tag_list_merge(r.event_tags, r.parsed_tags, c.GST_TAG_MERGE_KEEP);
    if (merged != null) _ = c.gst_pad_push_event(r.srcpad, c.gst_event_new_tag(merged));
}

fn sendNewSegment(d: *Demux) bool {
    const r = priv(d);
    const seg = &r.segment;
    if (seg.format == c.GST_FORMAT_UNDEFINED) {
        c.gst_segment_init(seg, c.GST_FORMAT_BYTES);
        seg.start = r.strip_start;
        seg.time = r.strip_start;
    }
    if (seg.format != c.GST_FORMAT_BYTES) {
        const ev = c.gst_event_new_segment(seg);
        c.gst_event_set_seqnum(ev, r.segment_seqnum);
        return c.gst_pad_push_event(r.srcpad, ev) != 0;
    }
    var start: i64 = @bitCast(seg.start);
    var stop: i64 = @bitCast(seg.stop);
    var time: i64 = @bitCast(seg.time);
    if (!check.that(start != -1, "gst_tag_demux_send_new_segment", "start != -1")) return false;
    if (!check.that(time != -1, "gst_tag_demux_send_new_segment", "time != -1")) return false;
    if (r.strip_end > 0 and upstreamSize(d)) {
        const v1: u64 = @bitCast(r.upstream_size - r.strip_end);
        if (@as(u64, @bitCast(start)) >= v1) {
            start = @bitCast(v1);
            stop = -1;
        }
        if (stop != -1 and @as(u64, @bitCast(stop)) >= v1) stop = @bitCast(v1);
    }
    if (r.strip_start > 0) {
        start = if (start > r.strip_start) start - r.strip_start else 0;
        time = if (time > r.strip_start) time - r.strip_start else 0;
        if (stop != -1) stop = if (stop > r.strip_start) stop - r.strip_start else 0;
    }
    var newseg: c.GstSegment = undefined;
    c.gst_segment_copy_into(seg, &newseg);
    newseg.start = @bitCast(start);
    newseg.stop = @bitCast(stop);
    newseg.time = @bitCast(time);
    const ev = c.gst_event_new_segment(&newseg);
    c.gst_event_set_seqnum(ev, r.segment_seqnum);
    return c.gst_pad_push_event(r.srcpad, ev) != 0;
}
