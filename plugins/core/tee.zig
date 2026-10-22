const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gsttee.c";

const PROP_NUM_SRC_PADS = 1;
const PROP_HAS_CHAIN = 2;
const PROP_SILENT = 3;
const PROP_LAST_MESSAGE = 4;
const PROP_PULL_MODE = 5;
const PROP_ALLOC_PAD = 6;
const PROP_ALLOW_NOT_LINKED = 7;

const PULL_NEVER = 0;
const PULL_SINGLE = 1;

const TeePad = extern struct {
    parent: cm.Pad,
    index: c.guint,
    pushed: c.gboolean,
    result: c.GstFlowReturn,
    removed: c.gboolean,
};

const Self = extern struct {
    element: c.GstElement,
    sinkpad: ?*c.GstPad,
    allocpad: ?*c.GstPad,
    pad_indexes: ?*c.GHashTable,
    next_pad_index: c.guint,
    has_chain: c.gboolean,
    silent: c.gboolean,
    last_message: [*c]u8,
    sink_mode: c.GstPadMode,
    pull_mode: c.gint,
    pull_pad: ?*c.GstPad,
    allow_not_linked: c.gboolean,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var src_t = cm.staticTemplate("src_%u", c.GST_PAD_SRC, c.GST_PAD_REQUEST, "ANY");

var once: cm.Once = .{};
var pad_once: cm.Once = .{};
var mode_once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;
var pspec_last: [*c]c.GParamSpec = null;
var pspec_alloc: [*c]c.GParamSpec = null;

var modes = [_]c.GEnumValue{
    .{ .value = PULL_NEVER, .value_name = "Never activate in pull mode", .value_nick = "never" },
    .{ .value = PULL_SINGLE, .value_name = "Only one src pad can be active in pull mode", .value_nick = "single" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn modeType() c.GType {
    return mode_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstTeePullMode", &modes);
        }
    }.f);
}

fn padInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: *TeePad = @ptrCast(@alignCast(inst));
    p.pushed = 0;
    p.result = c.GST_FLOW_NOT_LINKED;
    p.removed = 0;
}

fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(c.gst_pad_get_type(), c.g_intern_static_string("GstTeePad"), @sizeOf(c.GstPadClass), null, @sizeOf(TeePad), padInit, 0);
        }
    }.f);
}

fn tp(p: anytype) *TeePad {
    return @ptrCast(@alignCast(p));
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn el(p: anytype) *c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    restart: while (true) {
        var item: ?*c.GList = el(o).pads;
        while (item) |n| : (item = n.next) {
            const pad: ?*c.GstPad = @ptrCast(@alignCast(n.data));
            if (cm.pad(pad).direction == c.GST_PAD_SRC) {
                c.gst_element_release_request_pad(el(o), pad);
                continue :restart;
            }
        }
        break;
    }
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const t = me(o);
    c.g_hash_table_unref(t.pad_indexes);
    c.g_free(t.last_message);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn notifyAlloc(t: *Self) void {
    c.g_object_notify_by_pspec(@ptrCast(@alignCast(t)), pspec_alloc);
}

fn forwardSticky(_: ?*c.GstPad, ev: [*c][*c]c.GstEvent, data: c.gpointer) callconv(.c) c.gboolean {
    _ = c.gst_pad_store_sticky_event(@ptrCast(@alignCast(data)), ev[0]);
    return 1;
}

fn key(i: c.guint) c.gpointer {
    return @ptrFromInt(i);
}

fn requestNewPad(e: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, name_templ: [*c]const u8, _: ?*const c.GstCaps) callconv(.c) ?*c.GstPad {
    const t = me(e);
    var index: c.guint = 0;
    cm.lock(t);
    if (name_templ != null and c.sscanf(name_templ, "src_%u", &index) == 1) {
        if (c.g_hash_table_contains(t.pad_indexes, key(index)) != 0) {
            cm.unlock(t);
            return null;
        }
        if (index >= t.next_pad_index) t.next_pad_index = index + 1;
    } else {
        index = t.next_pad_index;
        while (c.g_hash_table_contains(t.pad_indexes, key(index)) != 0) index += 1;
        t.next_pad_index = index + 1;
    }
    _ = c.g_hash_table_insert(t.pad_indexes, key(index), null);
    const name = c.g_strdup_printf("src_%u", index);
    const srcpad: ?*c.GstPad = @ptrCast(@alignCast(c.g_object_new(padType(), "name", name, "direction", templ[0].direction, "template", templ, @as(?*anyopaque, null))));
    tp(srcpad).index = index;
    c.g_free(name);
    const mode = t.sink_mode;
    cm.unlock(t);
    const ok = if (mode == c.GST_PAD_MODE_PULL or mode == c.GST_PAD_MODE_PUSH) c.gst_pad_activate_mode(srcpad, c.GST_PAD_MODE_PUSH, 1) != 0 else true;
    if (!ok) {
        var changed = false;
        cm.lock(t);
        if (t.allocpad == srcpad) {
            t.allocpad = null;
            changed = true;
        }
        cm.unlock(t);
        c.gst_object_unref(srcpad);
        if (changed) notifyAlloc(t);
        return null;
    }
    c.gst_pad_set_activatemode_function_full(srcpad, srcActivate, null, null);
    c.gst_pad_set_query_function_full(srcpad, srcQuery, null, null);
    c.gst_pad_set_getrange_function_full(srcpad, getRange, null, null);
    cm.setPadFlag(srcpad, c.GST_PAD_FLAG_PROXY_CAPS);
    c.gst_pad_sticky_events_foreach(t.sinkpad, forwardSticky, srcpad);
    _ = c.gst_element_add_pad(e, srcpad);
    return srcpad;
}

fn releasePad(e: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const t = me(e);
    var changed = false;
    cm.lock(t);
    const index = tp(pad).index;
    tp(pad).removed = 1;
    if (t.allocpad == pad) {
        t.allocpad = null;
        changed = true;
    }
    cm.unlock(t);
    _ = c.gst_pad_set_active(pad, 0);
    _ = c.gst_element_remove_pad(e, pad);
    if (changed) notifyAlloc(t);
    cm.lock(t);
    _ = c.g_hash_table_remove(t.pad_indexes, key(index));
    cm.unlock(t);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const t = me(o);
    cm.lock(t);
    defer cm.unlock(t);
    switch (id) {
        PROP_HAS_CHAIN => t.has_chain = c.g_value_get_boolean(v),
        PROP_SILENT => t.silent = c.g_value_get_boolean(v),
        PROP_PULL_MODE => t.pull_mode = c.g_value_get_enum(v),
        PROP_ALLOC_PAD => {
            const pad: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(v)));
            cm.lock(pad);
            if (@as(?*anyopaque, @ptrCast(cm.obj(pad).parent)) == @as(?*anyopaque, @ptrCast(o))) t.allocpad = pad;
            cm.unlock(pad);
        },
        PROP_ALLOW_NOT_LINKED => t.allow_not_linked = c.g_value_get_boolean(v),
        else => cm.warnInvalid(FILE, o, id, spec, 512),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const t = me(o);
    cm.lock(t);
    defer cm.unlock(t);
    switch (id) {
        PROP_NUM_SRC_PADS => c.g_value_set_int(v, @intCast(el(t).numsrcpads)),
        PROP_HAS_CHAIN => c.g_value_set_boolean(v, t.has_chain),
        PROP_SILENT => c.g_value_set_boolean(v, t.silent),
        PROP_LAST_MESSAGE => c.g_value_set_string(v, t.last_message),
        PROP_PULL_MODE => c.g_value_set_enum(v, t.pull_mode),
        PROP_ALLOC_PAD => c.g_value_set_object(v, t.allocpad),
        PROP_ALLOW_NOT_LINKED => c.g_value_set_boolean(v, t.allow_not_linked),
        else => cm.warnInvalid(FILE, o, id, spec, 548),
    }
}

fn sinkEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    return c.gst_pad_event_default(pad, par, ev);
}

const AllocCtx = extern struct {
    tee: *Self,
    query: [*c]c.GstQuery,
    params: c.GstAllocationParams,
    size: c.guint,
    min_buffers: c.guint,
    first_query: c.gboolean,
    num_pads: c.guint,
};

fn queryAllocation(item: [*c]const c.GValue, ret: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *AllocCtx = @ptrCast(@alignCast(data));
    const src: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(item)));
    const peer = c.gst_pad_get_peer(src);
    if (peer == null) {
        if (ctx.tee.allow_not_linked != 0) return 1;
        c.g_value_set_boolean(ret, 0);
        return 0;
    }
    var caps: [*c]c.GstCaps = null;
    c.gst_query_parse_allocation(ctx.query, &caps, null);
    const q = c.gst_query_new_allocation(caps, 0);
    if (c.gst_pad_query(peer, q) == 0) {
        c.g_value_set_boolean(ret, 0);
        c.gst_mini_object_unref(@ptrCast(q));
        c.gst_object_unref(peer);
        return 0;
    }
    c.gst_object_unref(peer);
    var i: c.guint = 0;
    var n = c.gst_query_get_n_allocation_params(q);
    while (i < n) : (i += 1) {
        var p = std.mem.zeroes(c.GstAllocationParams);
        c.gst_query_parse_nth_allocation_param(q, i, null, &p);
        if (ctx.params.@"align" < p.@"align") ctx.params.@"align" = p.@"align";
        if (ctx.params.prefix < p.prefix) ctx.params.prefix = p.prefix;
        if (ctx.params.padding < p.padding) ctx.params.padding = p.padding;
    }
    if (c.gst_query_get_n_allocation_pools(q) > 0) {
        var size: c.guint = 0;
        var min: c.guint = 0;
        c.gst_query_parse_nth_allocation_pool(q, 0, null, &size, &min, null);
        if (ctx.size < size) ctx.size = size;
        if (ctx.min_buffers < min) ctx.min_buffers = min;
    }
    n = c.gst_query_get_n_allocation_metas(q);
    i = 0;
    while (i < n) : (i += 1) {
        var param: [*c]const c.GstStructure = null;
        const api = c.gst_query_parse_nth_allocation_meta(q, i, &param);
        if (ctx.first_query != 0) {
            c.gst_query_add_allocation_meta(ctx.query, api, param);
            continue;
        }
        var idx: c.guint = 0;
        if (c.gst_query_find_allocation_meta(ctx.query, api, &idx) != 0) {
            var cparam: [*c]const c.GstStructure = null;
            _ = c.gst_query_parse_nth_allocation_meta(ctx.query, idx, &cparam);
            if (cparam == null and param == null) continue;
            var agg: [*c]c.GstStructure = null;
            if (c.gst_meta_api_type_aggregate_params(api, &agg, cparam, param) != 0) {
                c.gst_query_add_allocation_meta(ctx.query, api, agg);
                if (agg != null) c.gst_structure_free(agg);
            }
            c.gst_query_remove_nth_allocation_meta(ctx.query, idx);
        }
    }
    var count = c.gst_query_get_n_allocation_metas(ctx.query);
    i = 0;
    while (i < count) {
        const api = c.gst_query_parse_nth_allocation_meta(ctx.query, i, null);
        if (c.gst_query_find_allocation_meta(q, api, null) == 0) {
            c.gst_query_remove_nth_allocation_meta(ctx.query, i);
            count -= 1;
            continue;
        }
        i += 1;
    }
    ctx.first_query = 0;
    ctx.num_pads += 1;
    c.gst_mini_object_unref(@ptrCast(q));
    return 1;
}

fn clearMetas(q: [*c]c.GstQuery) void {
    const count = c.gst_query_get_n_allocation_metas(q);
    var i: c.guint = 1;
    while (i <= count) : (i += 1) c.gst_query_remove_nth_allocation_meta(q, count - i);
}

fn resetCtx(ctx: *AllocCtx) void {
    ctx.first_query = 1;
    c.gst_allocation_params_init(&ctx.params);
}

fn sinkQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const t = me(par);
    if (cm.queryType(q) != c.GST_QUERY_ALLOCATION) return c.gst_pad_query_default(pad, par, q);
    var ret = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&ret, c.G_TYPE_BOOLEAN);
    c.g_value_set_boolean(&ret, 1);
    var ctx = std.mem.zeroes(AllocCtx);
    ctx.tee = t;
    ctx.query = q;
    resetCtx(&ctx);
    const it = c.gst_element_iterate_src_pads(el(t));
    while (c.gst_iterator_fold(it, queryAllocation, &ret, &ctx) == c.GST_ITERATOR_RESYNC) {
        c.gst_iterator_resync(it);
        resetCtx(&ctx);
        ctx.size = 0;
        ctx.min_buffers = 0;
        ctx.num_pads = 0;
        clearMetas(q);
    }
    c.gst_iterator_free(it);
    const res = c.g_value_get_boolean(&ret);
    c.g_value_unset(&ret);
    if (res != 0) {
        if (ctx.num_pads > 1) ctx.min_buffers += 1;
        if (ctx.params.@"align" != 0 or ctx.params.prefix != 0 or ctx.params.padding != 0) c.gst_query_add_allocation_param(q, null, &ctx.params);
        if (ctx.size != 0) c.gst_query_add_allocation_pool(q, null, ctx.size, ctx.min_buffers, 0);
    } else clearMetas(q);
    return res;
}

fn doMessage(t: *Self, pad: ?*c.GstPad, data: c.gpointer, list: bool) void {
    cm.lock(t);
    c.g_free(t.last_message);
    if (list) {
        t.last_message = c.g_strdup_printf("chain-list   ******* (%s:%s)t %p", cm.padParentName(pad), cm.padName(pad), data);
    } else {
        t.last_message = c.g_strdup_printf("chain        ******* (%s:%s)t (%lu bytes, %lu) %p", cm.padParentName(pad), cm.padName(pad), c.gst_buffer_get_size(@ptrCast(@alignCast(data))), cm.buf(data).pts, data);
    }
    cm.unlock(t);
    c.g_object_notify_by_pspec(@ptrCast(@alignCast(t)), pspec_last);
}

fn pushTo(pad: ?*c.GstPad, data: c.gpointer, list: bool, take: bool) c.GstFlowReturn {
    if (list) {
        const l: ?*c.GstBufferList = @ptrCast(data);
        return c.gst_pad_push_list(pad, if (take) l else @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(@alignCast(l))))));
    }
    const b: [*c]c.GstBuffer = @ptrCast(@alignCast(data));
    return c.gst_pad_push(pad, if (take) b else c.gst_buffer_ref(b));
}

fn handleData(t: *Self, data: c.gpointer, list: bool) c.GstFlowReturn {
    if (t.silent == 0) doMessage(t, t.sinkpad, data, list);
    cm.lock(t);
    var pads: ?*c.GList = el(t).srcpads;
    if (pads == null) {
        const r: c.GstFlowReturn = if (t.allow_not_linked != 0) c.GST_FLOW_OK else c.GST_FLOW_NOT_LINKED;
        cm.unlock(t);
        c.gst_mini_object_unref(@ptrCast(@alignCast(data)));
        return r;
    }
    if (pads.?.next == null) {
        const pad: ?*c.GstPad = @ptrCast(@alignCast(pads.?.data));
        _ = c.gst_object_ref(pad);
        cm.unlock(t);
        var r: c.GstFlowReturn = if (pad == t.pull_pad) c.GST_FLOW_OK else pushTo(pad, data, list, true);
        cm.lock(t);
        if (tp(pad).removed != 0) r = c.GST_FLOW_NOT_LINKED;
        if (r == c.GST_FLOW_NOT_LINKED and t.allow_not_linked != 0) r = c.GST_FLOW_OK;
        cm.unlock(t);
        c.gst_object_unref(pad);
        return r;
    }
    var l = pads;
    while (l) |n| : (l = n.next) {
        tp(n.data).pushed = 0;
        tp(n.data).result = c.GST_FLOW_NOT_LINKED;
    }
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    restart: while (true) {
        var cret: c.GstFlowReturn = if (t.allow_not_linked != 0) c.GST_FLOW_OK else c.GST_FLOW_NOT_LINKED;
        pads = el(t).srcpads;
        const cookie = el(t).pads_cookie;
        while (pads) |n| : (pads = n.next) {
            const pad: ?*c.GstPad = @ptrCast(@alignCast(n.data));
            if (tp(pad).pushed == 0) {
                _ = c.gst_object_ref(pad);
                cm.unlock(t);
                ret = if (pad == t.pull_pad) c.GST_FLOW_OK else pushTo(pad, data, list, false);
                cm.lock(t);
                if (tp(pad).removed != 0) ret = c.GST_FLOW_NOT_LINKED;
                tp(pad).pushed = 1;
                tp(pad).result = ret;
                c.gst_object_unref(pad);
            } else ret = tp(pad).result;
            if (el(t).pads_cookie != cookie) continue :restart;
            if (ret != c.GST_FLOW_OK and ret != c.GST_FLOW_NOT_LINKED) {
                cm.unlock(t);
                c.gst_mini_object_unref(@ptrCast(@alignCast(data)));
                return ret;
            }
            if (ret != c.GST_FLOW_NOT_LINKED) cret = ret;
        }
        cm.unlock(t);
        c.gst_mini_object_unref(@ptrCast(@alignCast(data)));
        return cret;
    }
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return handleData(me(par), b, false);
}

fn chainList(_: ?*c.GstPad, par: [*c]c.GstObject, l: ?*c.GstBufferList) callconv(.c) c.GstFlowReturn {
    return handleData(me(par), l, true);
}

fn sinkActivate(_: ?*c.GstPad, par: [*c]c.GstObject, mode: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    const t = me(par);
    if (mode != c.GST_PAD_MODE_PUSH) return 0;
    cm.lock(t);
    t.sink_mode = if (active != 0) mode else c.GST_PAD_MODE_NONE;
    const ok = !(active != 0 and t.has_chain == 0);
    cm.unlock(t);
    return @intFromBool(ok);
}

fn srcActivate(pad: ?*c.GstPad, par: [*c]c.GstObject, mode: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    const t = me(par);
    if (mode != c.GST_PAD_MODE_PULL) return 1;
    cm.lock(t);
    if (t.pull_mode == PULL_NEVER or (t.pull_mode == PULL_SINGLE and active != 0 and t.pull_pad != null)) {
        cm.unlock(t);
        return 0;
    }
    const sinkpad: ?*c.GstPad = @ptrCast(@alignCast(c.gst_object_ref(t.sinkpad)));
    cm.unlock(t);
    const res = c.gst_pad_activate_mode(sinkpad, c.GST_PAD_MODE_PULL, active);
    c.gst_object_unref(sinkpad);
    if (res == 0) return 0;
    cm.lock(t);
    if (active != 0) {
        if (t.pull_mode == PULL_SINGLE) t.pull_pad = pad;
    } else if (pad == t.pull_pad) t.pull_pad = null;
    t.sink_mode = if (active != 0) c.GST_PAD_MODE_PULL else c.GST_PAD_MODE_NONE;
    cm.unlock(t);
    return res;
}

fn srcQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const t = me(par);
    if (cm.queryType(q) != c.GST_QUERY_SCHEDULING) return c.gst_pad_query_default(pad, par, q);
    cm.lock(t);
    var pull = true;
    if (t.pull_mode == PULL_NEVER) {
        pull = false;
    } else if (t.pull_mode == PULL_SINGLE and t.pull_pad != null) pull = false;
    const sinkpad: ?*c.GstPad = @ptrCast(@alignCast(c.gst_object_ref(t.sinkpad)));
    cm.unlock(t);
    const res: c.gboolean = if (pull) c.gst_pad_peer_query(sinkpad, q) else 1;
    c.gst_object_unref(sinkpad);
    return res;
}

fn pushEos(v: [*c]const c.GValue, data: c.gpointer) callconv(.c) void {
    const t = me(data);
    const pad: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(v)));
    if (pad != t.pull_pad) _ = c.gst_pad_push_event(pad, c.gst_event_new_eos());
}

fn getRange(_: ?*c.GstPad, par: [*c]c.GstObject, offset: c.guint64, length: c.guint, b: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const t = me(par);
    var ret = c.gst_pad_pull_range(t.sinkpad, offset, length, b);
    if (ret == c.GST_FLOW_OK) {
        ret = handleData(t, c.gst_buffer_ref(b[0]), false);
    } else if (ret == c.GST_FLOW_EOS) {
        const it = c.gst_element_iterate_src_pads(el(t));
        while (c.gst_iterator_foreach(it, pushEos, t) == c.GST_ITERATOR_RESYNC) c.gst_iterator_resync(it);
        c.gst_iterator_free(it);
    }
    return ret;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.dispose = dispose;
    const CRW = c.G_PARAM_CONSTRUCT | c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, PROP_NUM_SRC_PADS, c.g_param_spec_int("num-src-pads", "Num Src Pads", "The number of source pads", 0, std.math.maxInt(c.gint), 0, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, PROP_HAS_CHAIN, c.g_param_spec_boolean("has-chain", "Has Chain", "If the element can operate in push mode", 1, CRW));
    c.g_object_class_install_property(oc, PROP_SILENT, c.g_param_spec_boolean("silent", "Silent", "Don't produce last_message events", 1, CRW));
    pspec_last = c.g_param_spec_string("last-message", "Last Message", "The message describing current status", null, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS);
    c.g_object_class_install_property(oc, PROP_LAST_MESSAGE, pspec_last);
    c.g_object_class_install_property(oc, PROP_PULL_MODE, c.g_param_spec_enum("pull-mode", "Pull mode", "Behavior of tee in pull mode", modeType(), PULL_NEVER, CRW));
    pspec_alloc = c.g_param_spec_object("alloc-pad", "Allocation Src Pad", "The pad ALLOCATION queries will be proxied to (DEPRECATED, has no effect)", c.gst_pad_get_type(), c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS | c.G_PARAM_DEPRECATED);
    c.g_object_class_install_property(oc, PROP_ALLOC_PAD, pspec_alloc);
    c.g_object_class_install_property(oc, PROP_ALLOW_NOT_LINKED, c.g_param_spec_boolean("allow-not-linked", "Allow not linked", "Return GST_FLOW_OK even if there are no source pads or they are all unlinked", 0, CRW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Tee pipe fitting", "Generic", "1-to-N pipe fitting", "Erik Walthinsen <omega@cse.ogi.edu>, Wim Taymans <wim@fluendo.com>");
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    ec.request_new_pad = requestNewPad;
    ec.release_pad = releasePad;
    c.gst_type_mark_as_plugin_api(modeType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const t = me(inst);
    t.sinkpad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    t.sink_mode = c.GST_PAD_MODE_NONE;
    c.gst_pad_set_event_function_full(t.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(t.sinkpad, sinkQuery, null, null);
    c.gst_pad_set_activatemode_function_full(t.sinkpad, sinkActivate, null, null);
    c.gst_pad_set_chain_function_full(t.sinkpad, chain, null, null);
    c.gst_pad_set_chain_list_function_full(t.sinkpad, chainList, null, null);
    cm.setPadFlag(t.sinkpad, c.GST_PAD_FLAG_PROXY_CAPS);
    _ = c.gst_element_add_pad(el(t), t.sinkpad);
    t.pad_indexes = c.g_hash_table_new(null, null);
    t.last_message = null;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstTee", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("tee", 0, "tee element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "tee", c.GST_RANK_NONE, getType()) != 0;
}
