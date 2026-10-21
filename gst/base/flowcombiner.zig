const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const Pad = @import("../padlayout.zig").Pad;

comptime {
    @import("../abi.zig").check(@This());
}

const Combiner = extern struct {
    pads: c.GQueue,
    last_ret: c.GstFlowReturn,
    ref_count: c.gint,

    pub const Header = c.struct__GstFlowCombiner;
};

var type_once: gtype.Once = .{};

fn last(p: c.gpointer) *c.GstFlowReturn {
    return &@as(*Pad, @ptrCast(@alignCast(p))).ABI.abi.last_flowret;
}

pub export fn gst_flow_combiner_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.boxed("GstFlowCombiner", @ptrCast(&gst_flow_combiner_ref), @ptrCast(&gst_flow_combiner_unref));
            _ = c._gst_debug_category_new("flowcombiner", 0, "Flow Combiner");
            return t;
        }
    }.f);
}

pub export fn gst_flow_combiner_new() [*c]Combiner {
    const k: [*c]Combiner = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Combiner))));
    c.g_queue_init(&k[0].pads);
    k[0].last_ret = c.GST_FLOW_OK;
    k[0].ref_count = 1;
    _ = gst_flow_combiner_get_type();
    return k;
}

pub export fn gst_flow_combiner_free(k: [*c]Combiner) void {
    gst_flow_combiner_unref(k);
}

pub export fn gst_flow_combiner_ref(k: [*c]Combiner) [*c]Combiner {
    if (!check.that(k != null, "gst_flow_combiner_ref", "combiner != NULL")) return null;
    _ = @atomicRmw(c.gint, &k[0].ref_count, .Add, 1, .seq_cst);
    return k;
}

fn drain(k: [*c]Combiner) void {
    while (c.g_queue_pop_head(&k[0].pads)) |p| c.gst_object_unref(p);
}

pub export fn gst_flow_combiner_unref(k: [*c]Combiner) void {
    if (!check.that(k != null, "gst_flow_combiner_unref", "combiner != NULL")) return;
    if (!check.that(k[0].ref_count > 0, "gst_flow_combiner_unref", "combiner->ref_count > 0")) return;
    if (@atomicRmw(c.gint, &k[0].ref_count, .Sub, 1, .seq_cst) != 1) return;
    drain(k);
    c.g_free(k);
}

pub export fn gst_flow_combiner_clear(k: [*c]Combiner) void {
    if (!check.that(k != null, "gst_flow_combiner_clear", "combiner != NULL")) return;
    drain(k);
    k[0].last_ret = c.GST_FLOW_OK;
}

pub export fn gst_flow_combiner_reset(k: [*c]Combiner) void {
    if (!check.that(k != null, "gst_flow_combiner_reset", "combiner != NULL")) return;
    var l = k[0].pads.head;
    while (l != null) : (l = l.*.next) last(l.*.data).* = c.GST_FLOW_OK;
    k[0].last_ret = c.GST_FLOW_OK;
}

fn fatal(r: c.GstFlowReturn) bool {
    return r <= c.GST_FLOW_NOT_NEGOTIATED or r == c.GST_FLOW_FLUSHING;
}

fn combine(k: [*c]Combiner) c.GstFlowReturn {
    var eos = true;
    var unlinked = true;
    var l = k[0].pads.head;
    while (l != null) : (l = l.*.next) {
        const r = last(l.*.data).*;
        if (fatal(r)) return r;
        if (r != c.GST_FLOW_NOT_LINKED) {
            unlinked = false;
            if (r != c.GST_FLOW_EOS) eos = false;
        }
    }
    if (unlinked) return c.GST_FLOW_NOT_LINKED;
    if (eos) return c.GST_FLOW_EOS;
    return c.GST_FLOW_OK;
}

pub export fn gst_flow_combiner_update_flow(k: [*c]Combiner, r: c.GstFlowReturn) c.GstFlowReturn {
    if (!check.that(k != null, "gst_flow_combiner_update_flow", "combiner != NULL")) return c.GST_FLOW_ERROR;
    if (k[0].last_ret == r) return r;
    const out = if (fatal(r) or k[0].pads.head == null) r else combine(k);
    k[0].last_ret = out;
    return out;
}

pub export fn gst_flow_combiner_update_pad_flow(k: [*c]Combiner, p: ?*c.GstPad, r: c.GstFlowReturn) c.GstFlowReturn {
    if (!check.that(p != null, "gst_flow_combiner_update_pad_flow", "pad != NULL")) return c.GST_FLOW_ERROR;
    last(p).* = r;
    return gst_flow_combiner_update_flow(k, r);
}

pub export fn gst_flow_combiner_add_pad(k: [*c]Combiner, p: ?*c.GstPad) void {
    if (!check.that(k != null, "gst_flow_combiner_add_pad", "combiner != NULL")) return;
    if (!check.that(p != null, "gst_flow_combiner_add_pad", "pad != NULL")) return;
    c.g_queue_push_head(&k[0].pads, c.gst_object_ref(p));
}

pub export fn gst_flow_combiner_remove_pad(k: [*c]Combiner, p: ?*c.GstPad) void {
    if (!check.that(k != null, "gst_flow_combiner_remove_pad", "combiner != NULL")) return;
    if (!check.that(p != null, "gst_flow_combiner_remove_pad", "pad != NULL")) return;
    if (c.g_queue_remove(&k[0].pads, p) != 0) c.gst_object_unref(p);
}
