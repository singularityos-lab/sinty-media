const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

fn probe(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const ev: [*c]c.GstEvent = @ptrCast(@alignCast(info[0].data));
    out("  probe {s}", .{z(c.gst_event_type_get_name(ev.*.type))});
    return c.GST_PAD_PROBE_OK;
}

fn chain(_: ?*c.GstPad, _: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    c.gst_buffer_unref(b);
    return c.GST_FLOW_OK;
}

pub fn main() void {
    c.gst_init(null, null);
    for (0..4) |variant| {
        out("variant {d}", .{variant});
        const src = c.gst_pad_new("src", c.GST_PAD_SRC);
        const sink = c.gst_pad_new("sink", c.GST_PAD_SINK);
        c.gst_pad_set_chain_function_full(sink, chain, null, null);
        _ = c.gst_pad_set_active(src, 1);
        _ = c.gst_pad_set_active(sink, 1);
        _ = c.gst_pad_link(src, sink);
        _ = c.gst_pad_add_probe(src, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, probe, null, null);
        var seg: c.GstSegment = undefined;
        c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
        out(" ss {d}", .{c.gst_pad_push_event(src, c.gst_event_new_stream_start("x"))});
        out(" caps {d}", .{c.gst_pad_push_event(src, c.gst_event_new_caps(c.gst_caps_new_empty_simple("a/b")))});
        out(" seg {d}", .{c.gst_pad_push_event(src, c.gst_event_new_segment(&seg))});
        if (variant & 1 != 0) out(" buf {d}", .{c.gst_pad_push(src, c.gst_buffer_new())});
        out(" fs {d}", .{c.gst_pad_push_event(src, c.gst_event_new_flush_start())});
        out(" fstop {d}", .{c.gst_pad_push_event(src, c.gst_event_new_flush_stop(@intFromBool(variant & 2 != 0)))});
        out(" eos {d}", .{c.gst_pad_push_event(src, c.gst_event_new_eos())});
        out(" flags {x}", .{@as(*c.GstObject, @ptrCast(@alignCast(src))).flags & 0xfff0});
        c.gst_object_unref(src);
        c.gst_object_unref(sink);
    }
}
