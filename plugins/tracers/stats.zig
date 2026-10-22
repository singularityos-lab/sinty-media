const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const spec = @import("spec.zig");

const N: ?*anyopaque = null;
const MAXU: c.guint = std.math.maxInt(c.guint);

const Self = extern struct {
    parent: c.GstTracer,
    num_elements: c.guint,
    num_pads: c.guint,
};

const Class = extern struct {
    parent: c.GstTracerClass,
};

const PadStats = extern struct {
    index: c.guint,
    last_ts: u64,
    parent_ix: c.guint,
};

const ElementStats = extern struct {
    index: c.guint,
    last_ts: u64,
    treal: u64,
    parent_ix: c.guint,
};

var once: cm.Once = .{};
var parent_class: ?*c.GObjectClass = null;
var data_quark: c.GQuark = 0;
var elem_lock: c.GMutex = std.mem.zeroes(c.GMutex);
var pad_lock: c.GMutex = std.mem.zeroes(c.GMutex);
var no_elem: ElementStats = std.mem.zeroes(ElementStats);
var no_pad: PadStats = std.mem.zeroes(PadStats);

var tr_new_element: ?*c.GstTracerRecord = null;
var tr_new_pad: ?*c.GstTracerRecord = null;
var tr_buffer: ?*c.GstTracerRecord = null;
var tr_element_query: ?*c.GstTracerRecord = null;
var tr_event: ?*c.GstTracerRecord = null;
var tr_message: ?*c.GstTracerRecord = null;
var tr_query: ?*c.GstTracerRecord = null;

fn obj(p: anytype) *c.GstObject {
    return @ptrCast(@alignCast(p));
}

fn objName(p: anytype) [*c]u8 {
    return obj(p).name;
}

fn typeName(p: anytype) [*c]const u8 {
    return c.g_type_name(cm.typeOf(p));
}

fn isGhost(p: anytype) bool {
    return cm.isA(p, c.gst_ghost_pad_get_type());
}

fn peer(p: ?*c.GstPad) ?*c.GstPad {
    return @ptrCast(cm.pad(p).peer);
}

fn logNewElement(s: *ElementStats, el: ?*c.GstElement, elapsed: u64) void {
    c.gst_tracer_record_log(tr_new_element, spec.thread(), elapsed, s.index, s.parent_ix, objName(el), typeName(el), @as(c.gboolean, @intFromBool(cm.isA(el, c.gst_bin_get_type()))));
}

fn createElementStats(self: *Self, el: ?*c.GstElement) *ElementStats {
    const s: *ElementStats = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(ElementStats))));
    s.index = self.num_elements;
    self.num_elements += 1;
    s.parent_ix = MAXU;
    c.g_object_set_qdata_full(@ptrCast(@alignCast(el)), data_quark, s, c.g_free);
    return s;
}

fn elementStats(self: *Self, el: ?*c.GstElement) *ElementStats {
    if (el == null) {
        no_elem.index = MAXU;
        return &no_elem;
    }
    var fresh = false;
    c.g_mutex_lock(&elem_lock);
    var s: ?*ElementStats = @ptrCast(@alignCast(c.g_object_get_qdata(@ptrCast(@alignCast(el)), data_quark)));
    if (s == null) {
        s = createElementStats(self, el);
        fresh = true;
    }
    c.g_mutex_unlock(&elem_lock);
    const st = s.?;
    if (st.parent_ix == MAXU) {
        const parent: ?*c.GstElement = @ptrCast(@alignCast(obj(el).parent));
        if (parent != null) st.parent_ix = elementStats(self, parent).index;
    }
    if (fresh) logNewElement(st, el, c.GST_CLOCK_TIME_NONE);
    return st;
}

fn realParent(p: ?*c.GstPad) ?*c.GstElement {
    if (p == null) return null;
    var parent = obj(p).parent;
    if (parent != null and isGhost(parent)) parent = obj(parent).parent;
    return @ptrCast(@alignCast(parent));
}

fn padStats(self: *Self, p: ?*c.GstPad) *PadStats {
    if (p == null) {
        no_pad.index = MAXU;
        return &no_pad;
    }
    var fresh = false;
    c.g_mutex_lock(&pad_lock);
    var s: ?*PadStats = @ptrCast(@alignCast(c.g_object_get_qdata(@ptrCast(@alignCast(p)), data_quark)));
    if (s == null) {
        const n: *PadStats = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(PadStats))));
        n.index = self.num_pads;
        self.num_pads += 1;
        n.parent_ix = MAXU;
        c.g_object_set_qdata_full(@ptrCast(@alignCast(p)), data_quark, n, c.g_free);
        s = n;
        fresh = true;
    }
    c.g_mutex_unlock(&pad_lock);
    const st = s.?;
    if (st.parent_ix == MAXU) {
        if (realParent(p)) |el| st.parent_ix = elementStats(self, el).index;
    }
    if (fresh) c.gst_tracer_record_log(tr_new_pad, spec.thread(), st.index, st.parent_ix, objName(p), typeName(p), @as(c.gboolean, @intFromBool(isGhost(p))), cm.pad(p).direction);
    return st;
}

fn valid(t: u64) c.gboolean {
    return @intFromBool(t != c.GST_CLOCK_TIME_NONE);
}

fn bufferStats(self: *Self, this: ?*c.GstPad, ts_: *PadStats, that: ?*c.GstPad, tt: *PadStats, b: [*c]c.GstBuffer, elapsed: u64) void {
    const te = elementStats(self, realParent(this));
    const pe = elementStats(self, realParent(that));
    const pts = b[0].pts;
    const dts = b[0].dts;
    const dur = b[0].duration;
    const flags = @as(*c.GstMiniObject, @ptrCast(@alignCast(b))).flags;
    c.gst_tracer_record_log(tr_buffer, spec.thread(), elapsed, ts_.index, te.index, tt.index, pe.index, @as(c.guint, @truncate(c.gst_buffer_get_size(b))), valid(pts), pts, valid(dts), dts, valid(dur), dur, flags);
}

fn queryStats(self: *Self, this: ?*c.GstPad, ts_: *PadStats, that: ?*c.GstPad, tt: *PadStats, q: [*c]c.GstQuery, elapsed: u64, have: bool, res: c.gboolean) void {
    const te = elementStats(self, realParent(this));
    const pe = elementStats(self, realParent(that));
    c.gst_tracer_record_log(tr_query, spec.thread(), elapsed, ts_.index, te.index, tt.index, pe.index, c.gst_query_type_get_name(cm.queryType(q)), c.gst_query_get_structure(q), @as(c.gboolean, @intFromBool(have)), res);
}

fn elementStatsFor(self: *Self, p: ?*c.GstPad, e1: u64, e2: u64) void {
    const elapsed: i64 = @as(i64, @bitCast(e2)) -% @as(i64, @bitCast(e1));
    var parent = obj(p).parent;
    const this: ?*c.GstElement = @ptrCast(@alignCast(if (parent != null and cm.isA(parent, c.gst_pad_get_type())) obj(parent).parent else parent));
    const this_stats = elementStats(self, this);
    var pp = peer(p) orelse return;
    var peer_pad: ?*c.GstPad = pp;
    parent = obj(pp).parent;
    if (parent != null and isGhost(parent)) {
        pp = @ptrCast(@alignCast(parent));
        _ = padStats(self, pp);
        parent = obj(pp).parent;
        if (parent != null) _ = elementStats(self, @ptrCast(@alignCast(parent)));
        peer_pad = peer(pp);
        parent = if (peer_pad != null) obj(peer_pad).parent else null;
    }
    while (peer_pad != null and isGhost(peer_pad)) {
        _ = padStats(self, peer_pad);
        _ = elementStats(self, @ptrCast(@alignCast(parent)));
        peer_pad = c.gst_ghost_pad_get_target(@ptrCast(@alignCast(peer_pad)));
        parent = if (peer_pad != null) obj(peer_pad).parent else null;
    }
    if (parent == null) {
        const t = timeArgs(@bitCast(elapsed));
        _ = std.c.printf("%u:%02u:%02u.%09u transmission on unparented target pad %s_%s -> %s_%s\n", t[0], t[1], t[2], t[3], cm.padParentName(p), cm.padName(p), cm.padParentName(peer_pad), cm.padName(peer_pad));
        return;
    }
    const peer_stats = elementStats(self, @ptrCast(@alignCast(parent)));
    this_stats.treal -%= @bitCast(elapsed);
    peer_stats.treal +%= @bitCast(elapsed);
}

fn timeArgs(t: u64) [4]c.guint {
    if (t == c.GST_CLOCK_TIME_NONE) return .{ 99, 99, 99, 999999999 };
    return .{ @truncate(t / (3600 * 1_000_000_000)), @truncate((t / (60 * 1_000_000_000)) % 60), @truncate((t / 1_000_000_000) % 60), @truncate(t % 1_000_000_000) };
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn pushPre(t: ?*anyopaque, ts: u64, p: ?*c.GstPad, b: [*c]c.GstBuffer) callconv(.c) void {
    const self = me(t);
    const a = padStats(self, p);
    const that = peer(p);
    bufferStats(self, p, a, that, padStats(self, that), b, ts);
}

fn pushPost(t: ?*anyopaque, ts: u64, p: ?*c.GstPad, _: c.GstFlowReturn) callconv(.c) void {
    const self = me(t);
    elementStatsFor(self, p, padStats(self, p).last_ts, ts);
}

const ListArgs = struct {
    self: *Self,
    this: ?*c.GstPad,
    this_stats: *PadStats,
    that: ?*c.GstPad,
    that_stats: *PadStats,
    ts: u64,
};

fn listItem(b: [*c][*c]c.GstBuffer, _: c.guint, data: c.gpointer) callconv(.c) c.gboolean {
    const a: *ListArgs = @ptrCast(@alignCast(data));
    bufferStats(a.self, a.this, a.this_stats, a.that, a.that_stats, b[0], a.ts);
    return 1;
}

fn pushListPre(t: ?*anyopaque, ts: u64, p: ?*c.GstPad, list: ?*c.GstBufferList) callconv(.c) void {
    const self = me(t);
    const a = padStats(self, p);
    const that = peer(p);
    var args = ListArgs{ .self = self, .this = p, .this_stats = a, .that = that, .that_stats = padStats(self, that), .ts = ts };
    _ = c.gst_buffer_list_foreach(list, listItem, &args);
}

fn pullPre(t: ?*anyopaque, ts: u64, p: ?*c.GstPad) callconv(.c) void {
    padStats(me(t), p).last_ts = ts;
}

fn pullPost(t: ?*anyopaque, ts: u64, p: ?*c.GstPad, b: [*c]c.GstBuffer) callconv(.c) void {
    const self = me(t);
    const a = padStats(self, p);
    const last = a.last_ts;
    const that = peer(p);
    const tt = padStats(self, that);
    if (b != null) bufferStats(self, p, a, that, tt, b, ts);
    elementStatsFor(self, p, last, ts);
}

fn eventPre(t: ?*anyopaque, ts: u64, p: ?*c.GstPad, ev: [*c]c.GstEvent) callconv(.c) void {
    const self = me(t);
    const es = elementStats(self, realParent(p));
    const ps = padStats(self, p);
    es.last_ts = ts;
    c.gst_tracer_record_log(tr_event, spec.thread(), ts, ps.index, es.index, c.gst_event_type_get_name(cm.eventType(ev)));
}

fn messagePre(t: ?*anyopaque, ts: u64, el: ?*c.GstElement, msg: [*c]c.GstMessage) callconv(.c) void {
    const st = elementStats(me(t), el);
    const ms = c.gst_message_get_structure(msg);
    const s = if (ms != null) ms else c.gst_structure_new_empty("dummy");
    st.last_ts = ts;
    c.gst_tracer_record_log(tr_message, spec.thread(), ts, st.index, c.gst_message_type_get_name(msg[0].type), s);
    if (s != ms) c.gst_structure_free(@constCast(s));
}

fn elementNew(t: ?*anyopaque, ts: u64, el: ?*c.GstElement) callconv(.c) void {
    const st = createElementStats(me(t), el);
    logNewElement(st, el, ts);
}

fn elementQueryPre(t: ?*anyopaque, ts: u64, el: ?*c.GstElement, q: [*c]c.GstQuery) callconv(.c) void {
    const st = elementStats(me(t), el);
    st.last_ts = ts;
    c.gst_tracer_record_log(tr_element_query, spec.thread(), ts, st.index, c.gst_query_type_get_name(cm.queryType(q)));
}

fn queryPre(t: ?*anyopaque, ts: u64, p: ?*c.GstPad, q: [*c]c.GstQuery) callconv(.c) void {
    const self = me(t);
    const a = padStats(self, p);
    const that = peer(p);
    queryStats(self, p, a, that, padStats(self, that), q, ts, false, 0);
}

fn queryPost(t: ?*anyopaque, ts: u64, p: ?*c.GstPad, q: [*c]c.GstQuery, res: c.gboolean) callconv(.c) void {
    const self = me(t);
    const a = padStats(self, p);
    const that = peer(p);
    queryStats(self, p, a, that, padStats(self, that), q, ts, true, res);
}

fn constructed(ob: [*c]c.GObject) callconv(.c) void {
    parent_class.?.constructed.?(ob);
    var params: [*c]u8 = null;
    c.g_object_get(ob, "params", &params, N);
    if (params == null) return;
    const tmp = c.g_strdup_printf("stats,%s", params);
    c.g_free(params);
    const st = c.gst_structure_from_string(tmp, null);
    c.g_free(tmp);
    if (st == null) return;
    const name = c.gst_structure_get_string(st, "name");
    if (name != null) _ = c.gst_object_set_name(@ptrCast(ob), name);
    c.gst_structure_free(st);
}

fn optU64(d: [*:0]const u8) [*c]c.GstStructure {
    return spec.make("value", &.{ .{ .gtype = c.G_TYPE_UINT64 }, .{ .desc = d }, .{ .flags = c.GST_TRACER_VALUE_FLAGS_OPTIONAL }, .{ .min_u64 = 0 }, .{ .max_u64 = ~@as(u64, 0) } });
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.constructed = constructed;
    const S = c.gst_structure_get_type();
    tr_buffer = c.gst_tracer_record_new("buffer.class", "thread-id", S, spec.threadId(), "ts", S, spec.ts(), "pad-ix", S, spec.padIx(), "element-ix", S, spec.elementIx(), "peer-pad-ix", S, spec.padIx(), "peer-element-ix", S, spec.elementIx(), "buffer-size", S, spec.make("value", &.{ .{ .gtype = c.G_TYPE_UINT }, .{ .desc = "size of buffer in bytes" }, .{ .min_u = 0 }, .{ .max_u = MAXU } }), "buffer-pts", S, optU64("presentation timestamp of the buffer in ns"), "buffer-dts", S, optU64("decoding timestamp of the buffer in ns"), "buffer-duration", S, optU64("duration of the buffer in ns"), "buffer-flags", S, spec.value(c.gst_buffer_flags_get_type(), "flags of the buffer"), N);
    tr_event = c.gst_tracer_record_new("event.class", "thread-id", S, spec.threadId(), "ts", S, spec.ts(), "pad-ix", S, spec.padIx(), "element-ix", S, spec.elementIx(), "name", S, spec.value(c.G_TYPE_STRING, "name of the event"), N);
    tr_message = c.gst_tracer_record_new("message.class", "thread-id", S, spec.threadId(), "ts", S, spec.ts(), "element-ix", S, spec.elementIx(), "name", S, spec.value(c.G_TYPE_STRING, "name of the message"), "structure", S, spec.make("structure", &.{ .{ .gtype = S }, .{ .desc = "message structure" } }), N);
    tr_element_query = c.gst_tracer_record_new("element-query.class", "thread-id", S, spec.threadId(), "ts", S, spec.ts(), "element-ix", S, spec.elementIx(), "name", S, spec.value(c.G_TYPE_STRING, "name of the query"), N);
    tr_query = c.gst_tracer_record_new("query.class", "thread-id", S, spec.threadId(), "ts", S, spec.ts(), "pad-ix", S, spec.padIx(), "element-ix", S, spec.elementIx(), "peer-pad-ix", S, spec.padIx(), "peer-element-ix", S, spec.elementIx(), "name", S, spec.value(c.G_TYPE_STRING, "name of the query"), "structure", S, spec.value(S, "query structure"), "res", S, spec.make("value", &.{ .{ .gtype = c.G_TYPE_BOOLEAN }, .{ .desc = "query result" }, .{ .flags = c.GST_TRACER_VALUE_FLAGS_OPTIONAL } }), N);
    tr_new_element = c.gst_tracer_record_new("new-element.class", "thread-id", S, spec.threadId(), "ts", S, spec.ts(), "ix", S, spec.elementIx(), "parent-ix", S, spec.elementIx(), "name", S, spec.value(c.G_TYPE_STRING, "name of the element"), "type", S, spec.value(c.G_TYPE_STRING, "type name of the element"), "is-bin", S, spec.value(c.G_TYPE_BOOLEAN, "is element a bin"), N);
    tr_new_pad = c.gst_tracer_record_new("new-pad.class", "thread-id", S, spec.threadId(), "ix", S, spec.padIx(), "parent-ix", S, spec.elementIx(), "name", S, spec.value(c.G_TYPE_STRING, "name of the pad"), "type", S, spec.value(c.G_TYPE_STRING, "type name of the pad"), "is-ghostpad", S, spec.value(c.G_TYPE_BOOLEAN, "is pad a ghostpad"), "pad-direction", S, spec.value(c.gst_pad_direction_get_type(), "ipad direction"), N);
    for ([_]?*c.GstTracerRecord{ tr_buffer, tr_event, tr_message, tr_element_query, tr_query, tr_new_element, tr_new_pad }) |r| spec.maybeLeaked(r);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    spec.hook(inst, "pad-push-pre", &pushPre);
    spec.hook(inst, "pad-push-post", &pushPost);
    spec.hook(inst, "pad-push-list-pre", &pushListPre);
    spec.hook(inst, "pad-push-list-post", &pushPost);
    spec.hook(inst, "pad-pull-range-pre", &pullPre);
    spec.hook(inst, "pad-pull-range-post", &pullPost);
    spec.hook(inst, "pad-push-event-pre", &eventPre);
    spec.hook(inst, "element-new", &elementNew);
    spec.hook(inst, "element-post-message-pre", &messagePre);
    spec.hook(inst, "element-query-pre", &elementQueryPre);
    spec.hook(inst, "pad-query-pre", &queryPre);
    spec.hook(inst, "pad-query-post", &queryPost);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            _ = c._gst_debug_category_new("stats", 0, "stats tracer");
            data_quark = c.g_quark_from_static_string("gststats:data");
            return cm.register(c.gst_tracer_get_type(), "GstStatsTracer", Class, Self, classInit, init);
        }
    }.f);
}
