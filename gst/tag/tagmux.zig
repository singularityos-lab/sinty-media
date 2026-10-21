const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Mux = c.GstTagMux;
const Class = c.GstTagMuxClass;
const Buffer = c.GstBuffer;
const PATH = "../gst-libs/gst/tag/gsttagmux.c";

const Private = struct {
    srcpad: ?*c.GstPad,
    sinkpad: ?*c.GstPad,
    event_tags: [*c]c.GstTagList,
    final_tags: [*c]c.GstTagList,
    start_tag_size: usize,
    end_tag_size: usize,
    render_start_tag: bool,
    render_end_tag: bool,
    current_offset: i64,
    max_offset: i64,
    newsegment_ev: [*c]c.GstEvent,
};

var once: gtype.Once = .{};
var offset_: c.gint = 0;
var parent: ?*c.GstElementClass = null;

fn of(p: anytype) *Mux {
    return @ptrCast(@alignCast(p));
}

fn priv(p: anytype) *Private {
    return @ptrCast(@alignCast(of(p).priv));
}

fn klass(p: anytype) *Class {
    return gtype.classPeek(Class, p);
}

fn unref(p: anytype) void {
    c.gst_mini_object_unref(@ptrCast(@alignCast(p)));
}

pub export fn gst_tag_mux_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = c.g_type_register_static_simple(c.gst_element_get_type(), "GstTagMux", @sizeOf(Class), classInit, @sizeOf(Mux), @ptrCast(&init), c.G_TYPE_FLAG_ABSTRACT);
            offset_ = c.g_type_add_instance_private(t, @sizeOf(Private));
            const info = c.GInterfaceInfo{ .interface_init = null, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_tag_setter_get_type(), &info);
            return t;
        }
    }.f);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const r = priv(o);
    if (r.newsegment_ev != null) {
        unref(r.newsegment_ev);
        r.newsegment_ev = null;
    }
    if (r.event_tags != null) {
        unref(r.event_tags);
        r.event_tags = null;
    }
    if (r.final_tags != null) {
        unref(r.final_tags);
        r.final_tags = null;
    }
    @as(*c.GObjectClass, @ptrCast(parent)).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ok: *c.GObjectClass = @ptrCast(@alignCast(k));
    const ek: *c.GstElementClass = @ptrCast(@alignCast(k));
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    ok.finalize = finalize;
    ek.change_state = changeState;
    if (offset_ != 0) c.g_type_class_adjust_private_offset(k, &offset_);
    _ = c._gst_debug_category_new("tagmux", 0, "tag muxer base class");
}

fn missing(ek: *c.GstElementClass, what: [*c]const u8) void {
    c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "GstTagMux subclass '%s' did not install a %s pad template!\n", c.g_type_name(@as(*c.GTypeClass, @ptrCast(ek)).g_type), what);
}

fn init(m: *Mux, k: *Class) callconv(.c) void {
    const ek: *c.GstElementClass = @ptrCast(k);
    m.priv = @ptrCast(@as([*]u8, @ptrCast(m)) + @as(usize, @bitCast(@as(isize, offset_))));
    const r = priv(m);
    r.* = std.mem.zeroes(Private);
    var tmpl = c.gst_element_class_get_pad_template(ek, "sink");
    if (tmpl != null) {
        r.sinkpad = c.gst_pad_new_from_template(tmpl, "sink");
    } else {
        missing(ek, "sink");
        r.sinkpad = c.gst_pad_new("sink", c.GST_PAD_SINK);
    }
    c.gst_pad_set_chain_function_full(r.sinkpad, chain, null, null);
    c.gst_pad_set_event_function_full(r.sinkpad, sinkEvent, null, null);
    _ = c.gst_element_add_pad(@ptrCast(m), r.sinkpad);
    tmpl = c.gst_element_class_get_pad_template(ek, "src");
    if (tmpl != null) {
        const caps = c.gst_pad_template_get_caps(tmpl);
        r.srcpad = c.gst_pad_new_from_template(tmpl, "src");
        c.gst_pad_use_fixed_caps(r.srcpad);
        if (caps != null and c.gst_caps_is_fixed(caps) != 0) _ = c.gst_pad_push_event(r.srcpad, c.gst_event_new_caps(caps));
    } else {
        missing(ek, "source");
        r.srcpad = c.gst_pad_new("src", c.GST_PAD_SRC);
    }
    _ = c.gst_element_add_pad(@ptrCast(m), r.srcpad);
    r.render_start_tag = true;
    r.render_end_tag = true;
}

fn getTags(m: *Mux) [*c]c.GstTagList {
    const r = priv(m);
    if (r.final_tags != null) return r.final_tags;
    const setter: ?*c.GstTagSetter = @ptrCast(m);
    r.final_tags = c.gst_tag_list_merge(c.gst_tag_setter_get_tag_list(setter), r.event_tags, c.gst_tag_setter_get_tag_merge_mode(setter));
    if (r.final_tags == null) r.final_tags = c.gst_tag_list_new_empty();
    return r.final_tags;
}

fn renderStart(m: *Mux) c.GstFlowReturn {
    const r = priv(m);
    const list = getTags(m);
    const f = klass(m).render_start_tag orelse return c.GST_FLOW_ERROR;
    const b = f(m, list);
    if (b == null) {
        r.start_tag_size = 0;
        return c.GST_FLOW_OK;
    }
    r.start_tag_size = c.gst_buffer_get_size(b);
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_BYTES);
    _ = c.gst_pad_push_event(r.srcpad, c.gst_event_new_segment(&seg));
    _ = c.gst_pad_push_event(r.srcpad, c.gst_event_new_tag(@ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(list))))));
    b.*.offset = 0;
    const ret = c.gst_pad_push(r.srcpad, b);
    r.current_offset = @intCast(r.start_tag_size);
    r.max_offset = @max(r.max_offset, r.current_offset);
    return ret;
}

fn renderEnd(m: *Mux) c.GstFlowReturn {
    const r = priv(m);
    const list = getTags(m);
    const f = klass(m).render_end_tag orelse return c.GST_FLOW_ERROR;
    const b = f(m, list);
    if (b == null) {
        r.end_tag_size = 0;
        return c.GST_FLOW_OK;
    }
    r.end_tag_size = c.gst_buffer_get_size(b);
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_BYTES);
    seg.start = @bitCast(r.max_offset);
    _ = c.gst_pad_push_event(r.srcpad, c.gst_event_new_segment(&seg));
    b.*.offset = @bitCast(r.max_offset);
    return c.gst_pad_push(r.srcpad, b);
}

fn adjust(m: *Mux, ev: [*c]c.GstEvent) [*c]c.GstEvent {
    const r = priv(m);
    var seg: c.GstSegment = undefined;
    c.gst_event_copy_segment(ev, &seg);
    if (seg.format != c.GST_FORMAT_BYTES) c.g_assertion_message_expr(check.DOMAIN, PATH, 348, "gst_tag_mux_adjust_event_offsets", "segment.format == GST_FORMAT_BYTES");
    const add: u64 = r.start_tag_size;
    if (seg.start != std.math.maxInt(u64)) seg.start +%= add;
    if (seg.stop != std.math.maxInt(u64)) seg.stop +%= add;
    if (seg.time != std.math.maxInt(u64)) seg.time +%= add;
    return c.gst_event_new_segment(&seg);
}

fn chain(_: ?*c.GstPad, p: [*c]c.GstObject, buffer: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    const m = of(p);
    const r = priv(m);
    if (r.render_start_tag) {
        const ret = renderStart(m);
        if (ret != c.GST_FLOW_OK) {
            unref(buffer);
            return ret;
        }
        if (r.newsegment_ev != null) {
            const ns = adjust(m, r.newsegment_ev);
            unref(r.newsegment_ev);
            r.newsegment_ev = null;
            var seg: c.GstSegment = undefined;
            c.gst_event_copy_segment(ns, &seg);
            _ = c.gst_pad_push_event(r.srcpad, ns);
            r.current_offset = @bitCast(seg.start);
            r.max_offset = @max(r.max_offset, r.current_offset);
        }
        r.render_start_tag = false;
    }
    const b: [*c]Buffer = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(buffer))));
    if (b.*.offset != std.math.maxInt(u64)) b.*.offset +%= r.start_tag_size;
    const length: c_int = @truncate(@as(i64, @intCast(c.gst_buffer_get_size(b))));
    const ret = c.gst_pad_push(r.srcpad, b);
    r.current_offset += length;
    r.max_offset = @max(r.max_offset, r.current_offset);
    return ret;
}

fn sinkEvent(pd: ?*c.GstPad, p: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const m = of(p);
    const r = priv(m);
    switch (ev.*.type) {
        c.GST_EVENT_TAG => {
            var tags: [*c]c.GstTagList = null;
            c.gst_event_parse_tag(ev, &tags);
            if (r.event_tags != null) {
                c.gst_tag_list_insert(r.event_tags, tags, c.GST_TAG_MERGE_REPLACE);
            } else r.event_tags = c.gst_tag_list_copy(tags);
            unref(ev);
            return 1;
        },
        c.GST_EVENT_SEGMENT => {
            var seg: c.GstSegment = undefined;
            c.gst_event_copy_segment(ev, &seg);
            if (seg.format != c.GST_FORMAT_BYTES) {
                unref(ev);
                return 1;
            }
            if (r.render_start_tag) {
                if (r.newsegment_ev != null) unref(r.newsegment_ev);
                r.newsegment_ev = ev;
            } else {
                _ = c.gst_pad_push_event(r.srcpad, adjust(m, ev));
                unref(ev);
                r.current_offset = @bitCast(seg.start);
                r.max_offset = @max(r.max_offset, r.current_offset);
            }
            return 1;
        },
        c.GST_EVENT_EOS => {
            if (r.render_end_tag) {
                const ret = renderEnd(m);
                if (ret != c.GST_FLOW_OK) return ret;
                r.render_end_tag = false;
            }
            return c.gst_pad_event_default(pd, p, ev);
        },
        else => return c.gst_pad_event_default(pd, p, ev),
    }
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const result = parent.?.change_state.?(e, t);
    if (result != c.GST_STATE_CHANGE_SUCCESS) return result;
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) {
        const r = priv(e);
        if (r.newsegment_ev != null) {
            unref(r.newsegment_ev);
            r.newsegment_ev = null;
        }
        if (r.event_tags != null) {
            unref(r.event_tags);
            r.event_tags = null;
        }
        if (r.final_tags != null) {
            unref(r.final_tags);
            r.final_tags = null;
        }
        r.start_tag_size = 0;
        r.end_tag_size = 0;
        r.render_start_tag = true;
        r.render_end_tag = true;
        r.current_offset = 0;
        r.max_offset = 0;
    }
    return result;
}
