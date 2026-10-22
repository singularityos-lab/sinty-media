const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const spec = @import("spec.zig");

const P = "p\x07A";
const U64 = "lu";
const TIME = "%u:%02u:%02u.%09u";
const N: ?*anyopaque = null;

const Self = extern struct {
    parent: c.GstTracer,
};

const Class = extern struct {
    parent: c.GstTracerClass,
};

var once: cm.Once = .{};
var parent_class: ?*c.GObjectClass = null;

var cat_bin: [*c]c.GstDebugCategory = null;
var cat_buffer: [*c]c.GstDebugCategory = null;
var cat_buffer_list: [*c]c.GstDebugCategory = null;
var cat_event: [*c]c.GstDebugCategory = null;
var cat_message: [*c]c.GstDebugCategory = null;
var cat_query: [*c]c.GstDebugCategory = null;
var cat_states: [*c]c.GstDebugCategory = null;
var cat_pads: [*c]c.GstDebugCategory = null;
var cat_element_pads: [*c]c.GstDebugCategory = null;
var cat_element_factory: [*c]c.GstDebugCategory = null;
var cat_log: [*c]c.GstDebugCategory = null;

fn boolStr(v: c.gboolean) [*:0]const u8 {
    return if (v != 0) "true" else "false";
}

const T = struct { h: c.guint, m: c.guint, s: c.guint, ns: c.guint };

fn tm(t: u64) T {
    if (t == c.GST_CLOCK_TIME_NONE) return .{ .h = 99, .m = 99, .s = 99, .ns = 999999999 };
    return .{ .h = @intCast(t / (3600 * 1_000_000_000)), .m = @intCast((t / (60 * 1_000_000_000)) % 60), .s = @intCast((t / 1_000_000_000) % 60), .ns = @intCast(t % 1_000_000_000) };
}

fn pushBufferPre(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, buffer: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_buffer, c.GST_LEVEL_TRACE, "", "do_push_buffer_pre", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", buffer=%" ++ P ++ "", t.h, t.m, t.s, t.ns, pad, buffer);
}

fn pushBufferPost(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, res: c.GstFlowReturn) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_buffer, c.GST_LEVEL_TRACE, "", "do_push_buffer_post", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", res=%s", t.h, t.m, t.s, t.ns, pad, c.gst_flow_get_name(res));
}

fn pushBufferListPre(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, list: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_buffer_list, c.GST_LEVEL_TRACE, "", "do_push_buffer_list_pre", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", list=%" ++ P ++ "", t.h, t.m, t.s, t.ns, pad, list);
}

fn pushBufferListPost(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, res: c.GstFlowReturn) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_buffer_list, c.GST_LEVEL_TRACE, "", "do_push_buffer_list_post", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", res=%s", t.h, t.m, t.s, t.ns, pad, c.gst_flow_get_name(res));
}

fn chainBufferPre(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, buffer: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_buffer, c.GST_LEVEL_TRACE, "", "do_chain_buffer_pre", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", buffer=%" ++ P ++ "", t.h, t.m, t.s, t.ns, pad, buffer);
}

fn chainBufferPost(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, res: c.GstFlowReturn) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_buffer, c.GST_LEVEL_TRACE, "", "do_chain_buffer_post", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", res=%s", t.h, t.m, t.s, t.ns, pad, c.gst_flow_get_name(res));
}

fn chainBufferListPre(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, list: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_buffer_list, c.GST_LEVEL_TRACE, "", "do_chain_buffer_list_pre", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", list=%" ++ P ++ "", t.h, t.m, t.s, t.ns, pad, list);
}

fn chainBufferListPost(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, res: c.GstFlowReturn) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_buffer_list, c.GST_LEVEL_TRACE, "", "do_chain_buffer_list_post", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", res=%s", t.h, t.m, t.s, t.ns, pad, c.gst_flow_get_name(res));
}

fn pullRangePre(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, offset: u64, size: c.guint) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_buffer, c.GST_LEVEL_TRACE, "", "do_pull_range_pre", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", offset=%" ++ U64 ++ ", size=%u", t.h, t.m, t.s, t.ns, pad, offset, size);
}

fn pullRangePost(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, buffer: ?*anyopaque, res: c.GstFlowReturn) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_buffer, c.GST_LEVEL_TRACE, "", "do_pull_range_post", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", buffer=%" ++ P ++ ", res=%s", t.h, t.m, t.s, t.ns, pad, buffer, c.gst_flow_get_name(res));
}

fn pushEventPre(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, event: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_event, c.GST_LEVEL_TRACE, "", "do_push_event_pre", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", event=%" ++ P ++ "", t.h, t.m, t.s, t.ns, pad, event);
}

fn pushEventPost(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, res: c.gboolean) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_event, c.GST_LEVEL_TRACE, "", "do_push_event_post", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", res=%s", t.h, t.m, t.s, t.ns, pad, boolStr(res));
}

fn sendEventPre(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, event: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_event, c.GST_LEVEL_TRACE, "", "do_send_event_pre", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", event=%" ++ P ++ "", t.h, t.m, t.s, t.ns, pad, event);
}

fn sendEventPost(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, res: c.GstFlowReturn) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_event, c.GST_LEVEL_TRACE, "", "do_send_event_post", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", res=%s", t.h, t.m, t.s, t.ns, pad, c.gst_flow_get_name(res));
}

fn padQueryPre(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, query: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_query, c.GST_LEVEL_TRACE, "", "do_pad_query_pre", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", query=%" ++ P ++ "", t.h, t.m, t.s, t.ns, pad, query);
}

fn padQueryPost(_: ?*anyopaque, ts: u64, pad: ?*anyopaque, query: ?*anyopaque, res: c.gboolean) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_query, c.GST_LEVEL_TRACE, "", "do_pad_query_post", 0, @ptrCast(@alignCast(pad)), TIME ++ ", pad=%" ++ P ++ ", query=%" ++ P ++ ", res=%s", t.h, t.m, t.s, t.ns, pad, query, boolStr(res));
}

fn postMessagePre(_: ?*anyopaque, ts: u64, element: ?*anyopaque, message: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_message, c.GST_LEVEL_TRACE, "", "do_post_message_pre", 0, @ptrCast(@alignCast(element)), TIME ++ ", element=%" ++ P ++ ", message=%" ++ P ++ "", t.h, t.m, t.s, t.ns, element, message);
}

fn postMessagePost(_: ?*anyopaque, ts: u64, element: ?*anyopaque, res: c.gboolean) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_message, c.GST_LEVEL_TRACE, "", "do_post_message_post", 0, @ptrCast(@alignCast(element)), TIME ++ ", element=%" ++ P ++ ", res=%s", t.h, t.m, t.s, t.ns, element, boolStr(res));
}

fn elementQueryPre(_: ?*anyopaque, ts: u64, element: ?*anyopaque, query: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_query, c.GST_LEVEL_TRACE, "", "do_element_query_pre", 0, @ptrCast(@alignCast(element)), TIME ++ ", element=%" ++ P ++ ", query=%" ++ P ++ "", t.h, t.m, t.s, t.ns, element, query);
}

fn elementQueryPost(_: ?*anyopaque, ts: u64, element: ?*anyopaque, query: ?*anyopaque, res: c.gboolean) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_query, c.GST_LEVEL_TRACE, "", "do_element_query_post", 0, @ptrCast(@alignCast(element)), TIME ++ ", element=%" ++ P ++ ", query=%" ++ P ++ ", res=%s", t.h, t.m, t.s, t.ns, element, query, boolStr(res));
}

fn elementNew(_: ?*anyopaque, ts: u64, element: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_element_factory, c.GST_LEVEL_TRACE, "", "do_element_new", 0, @ptrCast(@alignCast(element)), TIME ++ ", element=%" ++ P ++ "", t.h, t.m, t.s, t.ns, element);
}

fn elementAddPad(_: ?*anyopaque, ts: u64, element: ?*anyopaque, pad: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_element_pads, c.GST_LEVEL_TRACE, "", "do_element_add_pad", 0, @ptrCast(@alignCast(element)), TIME ++ ", element=%" ++ P ++ ", pad=%" ++ P ++ "", t.h, t.m, t.s, t.ns, element, pad);
}

fn elementRemovePad(_: ?*anyopaque, ts: u64, element: ?*anyopaque, pad: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_element_pads, c.GST_LEVEL_TRACE, "", "do_element_remove_pad", 0, @ptrCast(@alignCast(element)), TIME ++ ", element=%" ++ P ++ ", pad=%" ++ P ++ "", t.h, t.m, t.s, t.ns, element, pad);
}

fn elementChangeStatePre(_: ?*anyopaque, ts: u64, element: ?*anyopaque, change: c.GstStateChange) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_states, c.GST_LEVEL_TRACE, "", "do_element_change_state_pre", 0, @ptrCast(@alignCast(element)), TIME ++ ", element=%" ++ P ++ ", change=%s", t.h, t.m, t.s, t.ns, element, c.gst_state_change_get_name(change));
}

fn elementChangeStatePost(_: ?*anyopaque, ts: u64, element: ?*anyopaque, change: c.GstStateChange, res: c.GstStateChangeReturn) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_states, c.GST_LEVEL_TRACE, "", "do_element_change_state_post", 0, @ptrCast(@alignCast(element)), TIME ++ ", element=%" ++ P ++ ", change=%s, res=%s", t.h, t.m, t.s, t.ns, element, c.gst_state_change_get_name(change), c.gst_state_change_return_get_name(res));
}

fn binAddPre(_: ?*anyopaque, ts: u64, bin: ?*anyopaque, element: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_bin, c.GST_LEVEL_TRACE, "", "do_bin_add_pre", 0, @ptrCast(@alignCast(bin)), TIME ++ ", bin=%" ++ P ++ ", element=%" ++ P ++ "", t.h, t.m, t.s, t.ns, bin, element);
}

fn binAddPost(_: ?*anyopaque, ts: u64, bin: ?*anyopaque, element: ?*anyopaque, res: c.gboolean) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_bin, c.GST_LEVEL_TRACE, "", "do_bin_add_post", 0, @ptrCast(@alignCast(bin)), TIME ++ ", bin=%" ++ P ++ ", element=%" ++ P ++ ", res=%s", t.h, t.m, t.s, t.ns, bin, element, boolStr(res));
}

fn binRemovePre(_: ?*anyopaque, ts: u64, bin: ?*anyopaque, element: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_bin, c.GST_LEVEL_TRACE, "", "do_bin_remove_pre", 0, @ptrCast(@alignCast(bin)), TIME ++ ", bin=%" ++ P ++ ", element=%" ++ P ++ "", t.h, t.m, t.s, t.ns, bin, element);
}

fn binRemovePost(_: ?*anyopaque, ts: u64, bin: ?*anyopaque, res: c.gboolean) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_bin, c.GST_LEVEL_TRACE, "", "do_bin_remove_post", 0, @ptrCast(@alignCast(bin)), TIME ++ ", bin=%" ++ P ++ ", res=%s", t.h, t.m, t.s, t.ns, bin, boolStr(res));
}

fn padLinkPre(_: ?*anyopaque, ts: u64, src: ?*anyopaque, sink: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_pads, c.GST_LEVEL_TRACE, "", "do_pad_link_pre", 0, @ptrCast(@alignCast(src)), TIME ++ ", src=%" ++ P ++ ", sink=%" ++ P ++ "", t.h, t.m, t.s, t.ns, src, sink);
}

fn padLinkPost(_: ?*anyopaque, ts: u64, src: ?*anyopaque, sink: ?*anyopaque, res: c.GstPadLinkReturn) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_pads, c.GST_LEVEL_TRACE, "", "do_pad_link_post", 0, @ptrCast(@alignCast(src)), TIME ++ ", src=%" ++ P ++ ", sink=%" ++ P ++ ", res=%s", t.h, t.m, t.s, t.ns, src, sink, c.gst_pad_link_get_name(res));
}

fn padUnlinkPre(_: ?*anyopaque, ts: u64, src: ?*anyopaque, sink: ?*anyopaque) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_pads, c.GST_LEVEL_TRACE, "", "do_pad_unlink_pre", 0, @ptrCast(@alignCast(src)), TIME ++ ", src=%" ++ P ++ ", sink=%" ++ P ++ "", t.h, t.m, t.s, t.ns, src, sink);
}

fn padUnlinkPost(_: ?*anyopaque, ts: u64, src: ?*anyopaque, sink: ?*anyopaque, res: c.gboolean) callconv(.c) void {
    const t = tm(ts);
    c.gst_debug_log(cat_pads, c.GST_LEVEL_TRACE, "", "do_pad_unlink_post", 0, @ptrCast(@alignCast(src)), TIME ++ ", src=%" ++ P ++ ", sink=%" ++ P ++ ", res=%s", t.h, t.m, t.s, t.ns, src, sink, boolStr(res));
}

fn constructed(ob: [*c]c.GObject) callconv(.c) void {
    parent_class.?.constructed.?(ob);
    var params: [*c]u8 = null;
    c.g_object_get(ob, "params", &params, N);
    if (params == null) return;
    const tmp = c.g_strdup_printf("log,%s", params);
    c.g_free(params);
    const st = c.gst_structure_from_string(tmp, null);
    c.g_free(tmp);
    if (st == null) return;
    const name = c.gst_structure_get_string(st, "name");
    if (name != null) _ = c.gst_object_set_name(@ptrCast(ob), name);
    c.gst_structure_free(st);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.constructed = constructed;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    spec.hook(inst, "pad-push-pre", &pushBufferPre);
    spec.hook(inst, "pad-push-post", &pushBufferPost);
    spec.hook(inst, "pad-push-list-pre", &pushBufferListPre);
    spec.hook(inst, "pad-push-list-post", &pushBufferListPost);
    spec.hook(inst, "pad-chain-pre", &chainBufferPre);
    spec.hook(inst, "pad-chain-post", &chainBufferPost);
    spec.hook(inst, "pad-chain-list-pre", &chainBufferListPre);
    spec.hook(inst, "pad-chain-list-post", &chainBufferListPost);
    spec.hook(inst, "pad-pull-range-pre", &pullRangePre);
    spec.hook(inst, "pad-pull-range-post", &pullRangePost);
    spec.hook(inst, "pad-push-event-pre", &pushEventPre);
    spec.hook(inst, "pad-push-event-post", &pushEventPost);
    spec.hook(inst, "pad-send-event-pre", &sendEventPre);
    spec.hook(inst, "pad-send-event-post", &sendEventPost);
    spec.hook(inst, "pad-query-pre", &padQueryPre);
    spec.hook(inst, "pad-query-post", &padQueryPost);
    spec.hook(inst, "element-post-message-pre", &postMessagePre);
    spec.hook(inst, "element-post-message-post", &postMessagePost);
    spec.hook(inst, "element-query-pre", &elementQueryPre);
    spec.hook(inst, "element-query-post", &elementQueryPost);
    spec.hook(inst, "element-new", &elementNew);
    spec.hook(inst, "element-add-pad", &elementAddPad);
    spec.hook(inst, "element-remove-pad", &elementRemovePad);
    spec.hook(inst, "element-change-state-pre", &elementChangeStatePre);
    spec.hook(inst, "element-change-state-post", &elementChangeStatePost);
    spec.hook(inst, "bin-add-pre", &binAddPre);
    spec.hook(inst, "bin-add-post", &binAddPost);
    spec.hook(inst, "bin-remove-pre", &binRemovePre);
    spec.hook(inst, "bin-remove-post", &binRemovePost);
    spec.hook(inst, "pad-link-pre", &padLinkPre);
    spec.hook(inst, "pad-link-post", &padLinkPost);
    spec.hook(inst, "pad-unlink-pre", &padUnlinkPre);
    spec.hook(inst, "pad-unlink-post", &padUnlinkPost);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            cat_log = c._gst_debug_category_new("log", 0, "log tracer");
            cat_bin = c._gst_debug_get_category("bin");
            cat_buffer = c._gst_debug_get_category("GST_BUFFER");
            cat_buffer_list = c._gst_debug_get_category("GST_BUFFER_LIST");
            cat_event = c._gst_debug_get_category("GST_EVENT");
            cat_message = c._gst_debug_get_category("GST_MESSAGE");
            cat_query = c._gst_debug_get_category("query");
            cat_states = c._gst_debug_get_category("GST_STATES");
            cat_pads = c._gst_debug_get_category("GST_PADS");
            cat_element_pads = c._gst_debug_get_category("GST_ELEMENT_PADS");
            cat_element_factory = c._gst_debug_get_category("GST_ELEMENT_FACTORY");
            return cm.register(c.gst_tracer_get_type(), "GstLogTracer", Class, Self, classInit, init);
        }
    }.f);
}
