const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("el.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Trans = c.GstBaseTransform;
const Class = c.GstBaseTransformClass;
const Buffer = c.GstBuffer;
const Event = c.GstEvent;
const Query = c.GstQuery;
const Caps = c.GstCaps;
const Pad = ?*c.GstPad;
const NONE = el.NONE;
const FILE = "gstbasetransform.c";
const FLOW_DROPPED: c.GstFlowReturn = c.GST_FLOW_CUSTOM_SUCCESS;
const PROP_QOS = 1;

const Private = extern struct {
    passthrough: bool,
    always_in_place: bool,
    cache_caps1: [*c]Caps,
    cache_caps1_size: c.gsize,
    cache_caps2: [*c]Caps,
    cache_caps2_size: c.gsize,
    have_same_caps: bool,
    negotiated: bool,
    qos_enabled: bool,
    proportion: f64,
    earliest_time: c.GstClockTime,
    discont: bool,
    pad_mode: c.GstPadMode,
    gap_aware: bool,
    prefer_passthrough: bool,
    processed: u64,
    dropped: u64,
    position_out: c.GstClockTime,
    pool: ?*c.GstBufferPool,
    pool_active: bool,
    allocator: ?*c.GstAllocator,
    params: c.GstAllocationParams,
    query: [*c]Query,
};

var type_once: gtype.Once = .{};
var offset: c.gint = 0;
var parent: ?*c.GstElementClass = null;

fn priv(s: anytype) *Private {
    return @ptrCast(@alignCast(@as([*c]Trans, @ptrCast(@alignCast(s)))[0].priv));
}

fn of(p: anytype) *Trans {
    return @ptrCast(@alignCast(p));
}

fn klass(s: anytype) *Class {
    return el.classOf(Class, s);
}

fn isTrans(s: anytype) bool {
    return gtype.instanceOf(s, gst_base_transform_get_type());
}

fn checked(s: anytype, comptime func: []const u8) bool {
    return check.that(isTrans(s), func, "GST_IS_BASE_TRANSFORM (trans)");
}

fn direction(p: Pad) c.GstPadDirection {
    return el.pad(p).direction;
}

fn elementName(x: *Trans) [*c]const u8 {
    return x.element.object.name;
}

pub export fn gst_base_transform_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_element_get_type(), "GstBaseTransform", Class, Trans, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    if (offset != 0) c.g_type_class_adjust_private_offset(k, &offset);
    _ = c._gst_debug_category_new("basetransform", 0, "basetransform element");
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = setProp;
    gc.get_property = getProp;
    c.g_object_class_install_property(gc, PROP_QOS, c.g_param_spec_boolean("qos", "QoS", "Handle Quality-of-Service events", 0, c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS));
    gc.finalize = finalize;
    const bc: *Class = @ptrCast(@alignCast(k));
    bc.passthrough_on_same_caps = 0;
    bc.transform_ip_on_passthrough = 1;
    bc.transform_caps = defaultTransformCaps;
    bc.fixate_caps = defaultFixateCaps;
    bc.accept_caps = defaultAcceptCaps;
    bc.query = defaultQuery;
    bc.decide_allocation = defaultDecideAllocation;
    bc.propose_allocation = defaultProposeAllocation;
    bc.transform_size = defaultTransformSize;
    bc.transform_meta = defaultTransformMeta;
    bc.sink_event = defaultSinkEvent;
    bc.src_event = defaultSrcEvent;
    bc.prepare_output_buffer = defaultPrepareOutput;
    bc.copy_metadata = defaultCopyMetadata;
    bc.submit_input_buffer = defaultSubmit;
    bc.generate_output = defaultGenerate;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    @as(*c.GObjectClass, @ptrCast(parent.?)).finalize.?(o);
}

fn init(instance: [*c]c.GTypeInstance, g_class: c.gpointer) callconv(.c) void {
    const x: *Trans = @ptrCast(@alignCast(instance));
    const base: [*]u8 = @ptrCast(instance);
    x.priv = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, offset)))));
    const p = priv(x);
    const k: *Class = @ptrCast(@alignCast(g_class));
    var templ = c.gst_element_class_get_pad_template(@ptrCast(k), "sink");
    if (!check.that(templ != null, "gst_base_transform_init", "pad_template != NULL")) return;
    x.sinkpad = c.gst_pad_new_from_template(templ, "sink");
    el.setFlag(x.sinkpad, c.GST_PAD_FLAG_ACCEPT_INTERSECT);
    c.gst_pad_set_event_function_full(x.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_chain_function_full(x.sinkpad, chain, null, null);
    c.gst_pad_set_activatemode_function_full(x.sinkpad, sinkActivateMode, null, null);
    c.gst_pad_set_query_function_full(x.sinkpad, padQuery, null, null);
    _ = c.gst_element_add_pad(@ptrCast(x), x.sinkpad);
    templ = c.gst_element_class_get_pad_template(@ptrCast(k), "src");
    if (!check.that(templ != null, "gst_base_transform_init", "pad_template != NULL")) return;
    x.srcpad = c.gst_pad_new_from_template(templ, "src");
    c.gst_pad_set_event_function_full(x.srcpad, srcEvent, null, null);
    c.gst_pad_set_getrange_function_full(x.srcpad, getRange, null, null);
    c.gst_pad_set_activatemode_function_full(x.srcpad, srcActivateMode, null, null);
    c.gst_pad_set_query_function_full(x.srcpad, padQuery, null, null);
    _ = c.gst_element_add_pad(@ptrCast(x), x.srcpad);
    p.qos_enabled = false;
    p.cache_caps1 = null;
    p.cache_caps2 = null;
    p.pad_mode = c.GST_PAD_MODE_NONE;
    p.gap_aware = false;
    p.prefer_passthrough = true;
    p.passthrough = false;
    if (k.transform == null) {
        p.always_in_place = true;
        if (k.transform_ip == null) p.passthrough = true;
    }
    p.processed = 0;
    p.dropped = 0;
}

fn defaultTransformCaps(_: [*c]Trans, _: c.GstPadDirection, caps: [*c]Caps, filter: [*c]Caps) callconv(.c) [*c]Caps {
    if (filter != null) return c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
    return c.gst_caps_ref(caps);
}

fn transformCaps(x: *Trans, dir: c.GstPadDirection, caps: [*c]Caps, filter: [*c]Caps) [*c]Caps {
    if (caps == null) return null;
    if (klass(x).transform_caps) |f| return f(x, dir, caps, filter);
    return null;
}

fn defaultTransformMeta(_: [*c]Trans, _: [*c]Buffer, meta: [*c]c.GstMeta, _: [*c]Buffer) callconv(.c) c.gboolean {
    return @intFromBool(c.gst_meta_api_type_get_tags(meta[0].info[0].api) == null);
}

fn warn(comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, c.g_log, .{ "GStreamer-Base", c.G_LOG_LEVEL_WARNING, fmt } ++ args);
}

fn defaultTransformSize(s: [*c]Trans, _: c.GstPadDirection, caps: [*c]Caps, size: c.gsize, othercaps: [*c]Caps, othersize: [*c]c.gsize) callconv(.c) c.gboolean {
    const x = of(s);
    if (klass(x).get_unit_size == null) {
        othersize.* = size;
        return 1;
    }
    var in_unit: c.gsize = 0;
    var out_unit: c.gsize = 0;
    if (!unitSize(x, caps, &in_unit)) {
        warn("%s: could not get in_size", .{elementName(x)});
        return 0;
    }
    if (in_unit == 0 or size % in_unit != 0) {
        warn("%s: size %lu is not a multiple of unit size %lu", .{ elementName(x), size, in_unit });
        return 0;
    }
    const units = size / in_unit;
    if (!unitSize(x, othercaps, &out_unit)) {
        warn("%s: could not get out_size", .{elementName(x)});
        return 0;
    }
    othersize.* = units * out_unit;
    return 1;
}

fn transformSize(x: *Trans, dir: c.GstPadDirection, caps: [*c]Caps, size: c.gsize, othercaps: [*c]Caps, othersize: *c.gsize) bool {
    if (klass(x).transform_size) |f| return f(x, dir, caps, size, othercaps, othersize) != 0;
    return false;
}

fn queryCaps(x: *Trans, pad: Pad, filter: [*c]Caps) [*c]Caps {
    const other = if (pad == x.srcpad) x.sinkpad else x.srcpad;
    const templ = c.gst_pad_get_pad_template_caps(pad);
    const otempl = c.gst_pad_get_pad_template_caps(other);
    var peercaps: [*c]Caps = null;
    var caps: [*c]Caps = null;
    defer {
        if (peercaps != null) c.gst_caps_unref(peercaps);
        c.gst_caps_unref(templ);
        c.gst_caps_unref(otempl);
    }
    var peerfilter: [*c]Caps = null;
    if (filter != null) {
        var temp = c.gst_caps_intersect_full(filter, templ, c.GST_CAPS_INTERSECT_FIRST);
        peerfilter = transformCaps(x, direction(pad), temp, null);
        c.gst_caps_unref(temp);
        if (peerfilter != null) {
            if (c.gst_caps_is_empty(peerfilter) == 0) {
                temp = c.gst_caps_intersect_full(peerfilter, otempl, c.GST_CAPS_INTERSECT_FIRST);
                c.gst_caps_unref(peerfilter);
                peerfilter = temp;
            }
            if (peerfilter != null and c.gst_caps_is_empty(peerfilter) != 0) return peerfilter;
        }
    }
    peercaps = c.gst_pad_peer_query_caps(other, peerfilter);
    if (peerfilter != null) c.gst_caps_unref(peerfilter);
    const temp = if (peercaps != null) c.gst_caps_intersect_full(peercaps, otempl, c.GST_CAPS_INTERSECT_FIRST) else c.gst_caps_ref(otempl);
    caps = transformCaps(x, direction(other), temp, filter);
    c.gst_caps_unref(temp);
    if (caps == null or c.gst_caps_is_empty(caps) != 0) return caps;
    if (peercaps != null) {
        const t2 = c.gst_caps_intersect_full(caps, templ, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(caps);
        caps = t2;
        if (priv(x).prefer_passthrough) {
            const t3 = c.gst_caps_intersect_full(peercaps, caps, c.GST_CAPS_INTERSECT_FIRST);
            if (c.gst_caps_is_empty(t3) == 0) caps = c.gst_caps_merge(t3, caps) else c.gst_caps_unref(t3);
        }
    } else {
        c.gst_caps_unref(caps);
        caps = if (filter != null) c.gst_caps_intersect_full(filter, templ, c.GST_CAPS_INTERSECT_FIRST) else c.gst_caps_ref(templ);
    }
    return caps;
}

fn setAllocation(x: *Trans, pool: ?*c.GstBufferPool, allocator: ?*c.GstAllocator, params: ?*const c.GstAllocationParams, q: [*c]Query) void {
    const p = priv(x);
    el.lock(x);
    const oldpool = p.pool;
    p.pool = pool;
    p.pool_active = false;
    const oldalloc = p.allocator;
    p.allocator = allocator;
    const oldquery = p.query;
    p.query = q;
    if (params) |pp| p.params = pp.* else c.gst_allocation_params_init(&p.params);
    el.unlock(x);
    if (oldpool != null) {
        _ = c.gst_buffer_pool_set_active(oldpool, 0);
        c.gst_object_unref(oldpool);
    }
    if (oldalloc != null) c.gst_object_unref(oldalloc);
    if (oldquery != null) c.gst_query_unref(oldquery);
}

fn defaultDecideAllocation(s: [*c]Trans, q: [*c]Query) callconv(.c) c.gboolean {
    const x = of(s);
    const k = klass(x);
    var n = c.gst_query_get_n_allocation_metas(q);
    var i: c.guint = 0;
    while (i < n) {
        var params: [*c]const c.GstStructure = null;
        const api = c.gst_query_parse_nth_allocation_meta(q, i, &params);
        const remove = if (c.gst_meta_api_type_has_tag(api, c._gst_meta_tag_memory) != 0 or c.gst_meta_api_type_has_tag(api, c._gst_meta_tag_memory_reference) != 0)
            true
        else if (k.filter_meta) |f|
            f(x, q, api, params) == 0
        else
            true;
        if (remove) {
            c.gst_query_remove_nth_allocation_meta(q, i);
            n -= 1;
        } else i += 1;
    }
    var outcaps: [*c]Caps = null;
    c.gst_query_parse_allocation(q, &outcaps, null);
    var allocator: ?*c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    var update = false;
    if (c.gst_query_get_n_allocation_params(q) > 0) {
        c.gst_query_parse_nth_allocation_param(q, 0, &allocator, &params);
        update = true;
    } else c.gst_allocation_params_init(&params);
    var pool: ?*c.GstBufferPool = null;
    var size: c.guint = 0;
    var min: c.guint = 0;
    var max: c.guint = 0;
    if (c.gst_query_get_n_allocation_pools(q) > 0) {
        c.gst_query_parse_nth_allocation_pool(q, 0, &pool, &size, &min, &max);
        if (pool == null) pool = c.gst_buffer_pool_new();
    }
    if (pool != null) {
        var config = c.gst_buffer_pool_get_config(pool);
        c.gst_buffer_pool_config_set_params(config, outcaps, size, min, max);
        c.gst_buffer_pool_config_set_allocator(config, allocator, &params);
        if (c.gst_buffer_pool_set_config(pool, config) == 0) {
            config = c.gst_buffer_pool_get_config(pool);
            if (c.gst_buffer_pool_config_validate_params(config, outcaps, size, min, max) == 0) {
                c.gst_structure_free(config);
                c.gst_clear_object(@ptrCast(&pool));
            } else if (c.gst_buffer_pool_set_config(pool, config) == 0) {
                c.gst_clear_object(@ptrCast(&pool));
            }
            if (pool == null) {
                pool = c.gst_buffer_pool_new();
                config = c.gst_buffer_pool_get_config(pool);
                c.gst_buffer_pool_config_set_params(config, outcaps, size, min, max);
                c.gst_buffer_pool_config_set_allocator(config, allocator, &params);
                if (c.gst_buffer_pool_set_config(pool, config) == 0) {
                    c.gst_object_unref(pool);
                    el.err(x, .resource, c.GST_RESOURCE_ERROR_SETTINGS, "Failed to configure the buffer pool", c.g_strdup("Configuration is most likely invalid, please report this issue."), FILE, "gst_base_transform_default_decide_allocation", 916);
                    return 0;
                }
            }
        }
    }
    if (update) c.gst_query_set_nth_allocation_param(q, 0, allocator, &params) else c.gst_query_add_allocation_param(q, allocator, &params);
    if (allocator != null) c.gst_object_unref(allocator);
    if (pool != null) {
        c.gst_query_set_nth_allocation_pool(q, 0, pool, size, min, max);
        c.gst_object_unref(pool);
    }
    return 1;
}

fn doBufferpool(x: *Trans, outcaps: [*c]Caps) bool {
    const p = priv(x);
    if (p.passthrough or p.always_in_place) {
        setAllocation(x, null, null, null, null);
        return true;
    }
    const q = c.gst_query_new_allocation(outcaps, 1);
    _ = c.gst_pad_peer_query(x.srcpad, q);
    const decide = klass(x).decide_allocation.?;
    if (decide(x, q) == 0) {
        c.gst_query_unref(q);
        return false;
    }
    if (p.passthrough or p.always_in_place) {
        setAllocation(x, null, null, null, null);
        c.gst_query_unref(q);
        return true;
    }
    var allocator: ?*c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    if (c.gst_query_get_n_allocation_params(q) > 0) {
        c.gst_query_parse_nth_allocation_param(q, 0, &allocator, &params);
    } else c.gst_allocation_params_init(&params);
    var pool: ?*c.GstBufferPool = null;
    if (c.gst_query_get_n_allocation_pools(q) > 0) c.gst_query_parse_nth_allocation_pool(q, 0, &pool, null, null, null);
    setAllocation(x, pool, allocator, &params, q);
    return true;
}

fn configureCaps(x: *Trans, in: [*c]Caps, out: [*c]Caps) bool {
    const p = priv(x);
    const k = klass(x);
    _ = c.gst_caps_replace(&p.cache_caps1, null);
    _ = c.gst_caps_replace(&p.cache_caps2, null);
    p.have_same_caps = c.gst_caps_is_equal(in, out) != 0;
    if (k.passthrough_on_same_caps != 0) gst_base_transform_set_passthrough(x, @intFromBool(p.have_same_caps));
    if (k.set_caps) |f| return f(x, in, out) != 0;
    return true;
}

fn defaultFixateCaps(_: [*c]Trans, _: c.GstPadDirection, _: [*c]Caps, othercaps: [*c]Caps) callconv(.c) [*c]Caps {
    return c.gst_caps_fixate(othercaps);
}

fn padName(p: Pad) [2][*c]const u8 {
    const o = el.obj(p);
    const par: [*c]c.GstObject = o.parent;
    return .{ if (par != null and par[0].name != null) par[0].name else "''", if (o.name != null) o.name else "''" };
}

fn findTransform(x: *Trans, pad: Pad, caps: [*c]Caps) [*c]Caps {
    if (!check.that(c.gst_caps_is_fixed(caps) != 0, "gst_base_transform_find_transform", "gst_caps_is_fixed (caps)")) return null;
    const k = klass(x);
    const other = if (pad == x.srcpad) x.sinkpad else x.srcpad;
    const otherpeer = c.gst_pad_get_peer(other);
    defer if (otherpeer != null) c.gst_object_unref(otherpeer);
    var othercaps = transformCaps(x, direction(pad), caps, null);
    if (othercaps != null and c.gst_caps_is_empty(othercaps) == 0) {
        const templ = c.gst_pad_get_pad_template_caps(other);
        const i = c.gst_caps_intersect_full(othercaps, templ, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(othercaps);
        c.gst_caps_unref(templ);
        othercaps = i;
    }
    if (othercaps == null or c.gst_caps_is_empty(othercaps) != 0) {
        if (othercaps != null) c.gst_caps_unref(othercaps);
        return null;
    }
    var fixed = c.gst_caps_is_fixed(othercaps) != 0;
    if (!fixed) {
        if (otherpeer != null) {
            var peercaps = c.gst_pad_query_caps(otherpeer, othercaps);
            if (c.gst_caps_is_empty(peercaps) == 0) {
                const templ = c.gst_pad_get_pad_template_caps(other);
                var i = c.gst_caps_intersect_full(peercaps, templ, c.GST_CAPS_INTERSECT_FIRST);
                c.gst_caps_unref(peercaps);
                c.gst_caps_unref(templ);
                peercaps = i;
                i = c.gst_caps_intersect_full(peercaps, othercaps, c.GST_CAPS_INTERSECT_FIRST);
                c.gst_caps_unref(peercaps);
                c.gst_caps_unref(othercaps);
                othercaps = i;
            } else {
                c.gst_caps_unref(othercaps);
                othercaps = peercaps;
            }
            fixed = c.gst_caps_is_fixed(othercaps) != 0;
        } else {
            c.gst_caps_unref(othercaps);
            othercaps = c.gst_caps_ref(caps);
            fixed = true;
        }
    }
    if (c.gst_caps_is_empty(othercaps) != 0) {
        c.gst_caps_unref(othercaps);
        return null;
    }
    if (k.fixate_caps) |f| {
        othercaps = f(x, direction(pad), caps, othercaps);
        if (othercaps == null) {
            const n = padName(pad);
            c.g_log("GStreamer-Base", c.G_LOG_LEVEL_CRITICAL, "basetransform: second attempt to fixate caps returned invalid (NULL) caps on pad %s:%s", n[0], n[1]);
        }
        fixed = othercaps != null and c.gst_caps_is_fixed(othercaps) != 0;
    }
    if (!fixed or (otherpeer != null and c.gst_pad_query_accept_caps(otherpeer, othercaps) == 0)) {
        if (othercaps != null) c.gst_caps_unref(othercaps);
        return null;
    }
    return othercaps;
}

fn defaultAcceptCaps(s: [*c]Trans, dir: c.GstPadDirection, caps: [*c]Caps) callconv(.c) c.gboolean {
    const x = of(s);
    const pad = if (dir == c.GST_PAD_SINK) x.sinkpad else x.srcpad;
    const other = if (dir == c.GST_PAD_SINK) x.srcpad else x.sinkpad;
    const templ = c.gst_pad_get_pad_template_caps(pad);
    const otempl = c.gst_pad_get_pad_template_caps(other);
    defer {
        c.gst_caps_unref(templ);
        c.gst_caps_unref(otempl);
    }
    if (el.flags(x.sinkpad) & c.GST_PAD_FLAG_ACCEPT_INTERSECT != 0) {
        if (c.gst_caps_can_intersect(caps, templ) == 0) return 0;
    } else if (c.gst_caps_is_subset(caps, templ) == 0) return 0;
    const ocaps = transformCaps(x, dir, caps, otempl);
    defer if (ocaps != null) c.gst_caps_unref(ocaps);
    return @intFromBool(ocaps != null and c.gst_caps_is_empty(ocaps) == 0);
}

fn setCaps(x: *Trans, pad: Pad, incaps: [*c]Caps) bool {
    const p = priv(x);
    var ret = true;
    var outcaps = findTransform(x, pad, incaps);
    var prev_in: [*c]Caps = null;
    var prev_out: [*c]Caps = null;
    body: {
        if (outcaps == null or c.gst_caps_is_empty(outcaps) != 0) {
            ret = false;
            break :body;
        }
        if (c.gst_caps_is_equal(incaps, outcaps) != 0) {
            c.gst_caps_unref(outcaps);
            outcaps = c.gst_caps_ref(incaps);
        }
        prev_in = c.gst_pad_get_current_caps(x.sinkpad);
        prev_out = c.gst_pad_get_current_caps(x.srcpad);
        if (!(prev_in != null and prev_out != null and c.gst_caps_is_equal(prev_in, incaps) != 0 and c.gst_caps_is_equal(prev_out, outcaps) != 0)) {
            ret = configureCaps(x, incaps, outcaps);
            if (!ret) break :body;
            if (prev_out == null or c.gst_caps_is_equal(outcaps, prev_out) == 0) ret = el.padSetCaps(x.srcpad, outcaps);
        }
        if (ret) ret = doBufferpool(x, outcaps);
    }
    if (outcaps != null) c.gst_caps_unref(outcaps);
    if (prev_in != null) c.gst_caps_unref(prev_in);
    if (prev_out != null) c.gst_caps_unref(prev_out);
    el.lock(x);
    p.negotiated = ret;
    el.unlock(x);
    return ret;
}

fn defaultProposeAllocation(s: [*c]Trans, decide: [*c]Query, q: [*c]Query) callconv(.c) c.gboolean {
    const x = of(s);
    if (decide == null) return c.gst_pad_peer_query(x.srcpad, q);
    const n = c.gst_query_get_n_allocation_metas(decide);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        var params: [*c]const c.GstStructure = null;
        const api = c.gst_query_parse_nth_allocation_meta(decide, i, &params);
        c.gst_query_add_allocation_meta(q, api, params);
    }
    return 1;
}

fn reconfigureUnlocked(x: *Trans) bool {
    var ret = true;
    if (c.gst_pad_check_reconfigure(x.srcpad) != 0) {
        const incaps = c.gst_pad_get_current_caps(x.sinkpad);
        if (incaps != null) {
            if (!setCaps(x, x.sinkpad, incaps)) {
                el.message(x, c.GST_MESSAGE_WARNING, .stream, c.GST_STREAM_ERROR_FORMAT, c.g_strdup("not negotiated"), c.g_strdup("not negotiated"), FILE, "gst_base_transform_reconfigure_unlocked", 1447, null);
                ret = false;
            }
            c.gst_caps_unref(incaps);
        }
    }
    if (!ret) c.gst_pad_mark_reconfigure(x.srcpad);
    return ret;
}

pub export fn gst_base_transform_reconfigure(s: [*c]Trans) c.gboolean {
    if (!checked(s, "gst_base_transform_reconfigure")) return 0;
    const x = of(s);
    el.streamLock(x.sinkpad);
    defer el.streamUnlock(x.sinkpad);
    const ret = reconfigureUnlocked(x);
    if (!ret) c.gst_pad_mark_reconfigure(x.srcpad);
    return @intFromBool(ret);
}

fn defaultQuery(s: [*c]Trans, dir: c.GstPadDirection, q: [*c]Query) callconv(.c) c.gboolean {
    const x = of(s);
    const p = priv(x);
    const k = klass(x);
    const pad = if (dir == c.GST_PAD_SRC) x.srcpad else x.sinkpad;
    const other = if (dir == c.GST_PAD_SRC) x.sinkpad else x.srcpad;
    switch (q[0].type) {
        c.GST_QUERY_ALLOCATION => {
            if (dir != c.GST_PAD_SINK) return 0;
            if (!reconfigureUnlocked(x)) return 0;
            el.lock(x);
            if (!p.negotiated and !p.passthrough and k.set_caps != null) {
                el.unlock(x);
                return 0;
            }
            const decide = p.query;
            p.query = null;
            el.unlock(x);
            const ret = if (k.propose_allocation) |f| f(x, decide, q) else 0;
            if (decide != null) {
                el.lock(x);
                if (p.query == null) p.query = decide else c.gst_query_unref(decide);
                el.unlock(x);
            }
            return ret;
        },
        c.GST_QUERY_POSITION => {
            var format: c.GstFormat = 0;
            c.gst_query_parse_position(q, &format, null);
            if (format == c.GST_FORMAT_TIME and x.segment.format == c.GST_FORMAT_TIME) {
                const at = if (dir == c.GST_PAD_SINK or p.position_out == NONE) x.segment.position else p.position_out;
                c.gst_query_set_position(q, format, @bitCast(c.gst_segment_to_stream_time(&x.segment, c.GST_FORMAT_TIME, at)));
                return 1;
            }
            return c.gst_pad_peer_query(other, q);
        },
        c.GST_QUERY_ACCEPT_CAPS => {
            var caps: [*c]Caps = null;
            c.gst_query_parse_accept_caps(q, &caps);
            const f = k.accept_caps orelse return 0;
            c.gst_query_set_accept_caps_result(q, f(x, dir, caps));
            return 1;
        },
        c.GST_QUERY_CAPS => {
            var filter: [*c]Caps = null;
            c.gst_query_parse_caps(q, &filter);
            var caps = queryCaps(x, pad, filter);
            if (caps == null) caps = c.gst_caps_new_empty();
            c.gst_query_set_caps_result(q, caps);
            c.gst_caps_unref(caps);
            return 1;
        },
        else => return c.gst_pad_peer_query(other, q),
    }
}

fn padQuery(pad: Pad, parent_obj: [*c]c.GstObject, q: [*c]Query) callconv(.c) c.gboolean {
    const x = of(parent_obj);
    if (klass(x).query) |f| return f(x, direction(pad), q);
    return 0;
}

fn defaultPrepareOutput(s: [*c]Trans, inbuf: [*c]Buffer, out: [*c][*c]Buffer) callconv(.c) c.GstFlowReturn {
    const x = of(s);
    const p = priv(x);
    const k = klass(x);
    if (p.passthrough) {
        out.* = inbuf;
        return c.GST_FLOW_OK;
    }
    if (p.pool != null) {
        if (!p.pool_active) {
            if (c.gst_buffer_pool_set_active(p.pool, 1) == 0) {
                el.err(x, .resource, c.GST_RESOURCE_ERROR_SETTINGS, "failed to activate bufferpool", c.g_strdup("failed to activate bufferpool"), FILE, "default_prepare_output_buffer", 1745);
                return c.GST_FLOW_ERROR;
            }
            p.pool_active = true;
        }
        const r = c.gst_buffer_pool_acquire_buffer(p.pool, out, null);
        if (r != c.GST_FLOW_OK) return r;
    } else if (k.transform_ip != null and p.always_in_place) {
        out.* = if (c.gst_mini_object_is_writable(@ptrCast(@alignCast(inbuf))) != 0) inbuf else c.gst_buffer_copy(inbuf);
        return c.GST_FLOW_OK;
    } else {
        const incaps = c.gst_pad_get_current_caps(x.sinkpad);
        const outcaps = c.gst_pad_get_current_caps(x.srcpad);
        if (outcaps == null) {
            c.gst_caps_unref(incaps);
            return c.GST_FLOW_FLUSHING;
        }
        var outsize: c.gsize = 0;
        const ok = transformSize(x, c.GST_PAD_SINK, incaps, c.gst_buffer_get_size(inbuf), outcaps, &outsize);
        c.gst_caps_unref(incaps);
        c.gst_caps_unref(outcaps);
        if (!ok) return c.GST_FLOW_ERROR;
        out.* = c.gst_buffer_new_allocate(p.allocator, outsize, &p.params);
        if (out.* == null) return c.GST_FLOW_ERROR;
    }
    if (k.copy_metadata) |f| {
        if (f(x, inbuf, out.*) == 0) el.message(x, c.GST_MESSAGE_WARNING, .stream, c.GST_STREAM_ERROR_NOT_IMPLEMENTED, c.g_strdup("could not copy metadata"), null, FILE, "default_prepare_output_buffer", 1735, null);
    }
    return c.GST_FLOW_OK;
}

const CopyData = struct {
    trans: *Trans,
    out: [*c]Buffer,
};

fn copyMeta(in: [*c]Buffer, meta: [*c][*c]c.GstMeta, data: c.gpointer) callconv(.c) c.gboolean {
    const d: *CopyData = @ptrCast(@alignCast(data));
    const k = klass(d.trans);
    const minfo = meta.*[0].info;
    var do_copy = false;
    if (c.gst_meta_api_type_has_tag(minfo[0].api, c._gst_meta_tag_memory) != 0 or c.gst_meta_api_type_has_tag(minfo[0].api, c._gst_meta_tag_memory_reference) != 0) {
        do_copy = false;
    } else if (k.transform_meta) |f| {
        do_copy = f(d.trans, d.out, meta.*, in) != 0;
    }
    if (do_copy) {
        if (minfo[0].transform_func) |f| {
            var copy = c.GstMetaTransformCopy{ .region = 0, .offset = 0, .size = std.math.maxInt(c.gsize) };
            _ = f(d.out, meta.*, in, c._gst_meta_transform_copy, &copy);
        }
    }
    return 1;
}

fn defaultCopyMetadata(s: [*c]Trans, inbuf: [*c]Buffer, outbuf: [*c]Buffer) callconv(.c) c.gboolean {
    const x = of(s);
    if (c.gst_mini_object_is_writable(@ptrCast(@alignCast(outbuf))) == 0) return 0;
    _ = c.gst_buffer_copy_into(outbuf, inbuf, c.GST_BUFFER_COPY_FLAGS | c.GST_BUFFER_COPY_TIMESTAMPS, 0, std.math.maxInt(c.gsize));
    if (!priv(x).gap_aware) outbuf[0].mini_object.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_GAP);
    var d = CopyData{ .trans = x, .out = outbuf };
    _ = c.gst_buffer_foreach_meta(inbuf, copyMeta, &d);
    return 1;
}

fn unitSize(x: *Trans, caps: [*c]Caps, size: *c.gsize) bool {
    const p = priv(x);
    if (p.cache_caps1 == caps) {
        size.* = p.cache_caps1_size;
        return true;
    }
    if (p.cache_caps2 == caps) {
        size.* = p.cache_caps2_size;
        return true;
    }
    const ok = klass(x).get_unit_size.?(x, caps, size) != 0;
    if (ok) {
        if (p.cache_caps1 == null) {
            _ = c.gst_caps_replace(&p.cache_caps1, caps);
            p.cache_caps1_size = size.*;
        } else if (p.cache_caps2 == null) {
            _ = c.gst_caps_replace(&p.cache_caps2, caps);
            p.cache_caps2_size = size.*;
        }
    }
    return ok;
}

fn sinkEvent(_: Pad, parent_obj: [*c]c.GstObject, ev: [*c]Event) callconv(.c) c.gboolean {
    const x = of(parent_obj);
    if (klass(x).sink_event) |f| return f(x, ev);
    c.gst_event_unref(ev);
    return 1;
}

fn defaultSinkEvent(s: [*c]Trans, ev: [*c]Event) callconv(.c) c.gboolean {
    const x = of(s);
    const p = priv(x);
    var ret = true;
    var forward = true;
    switch (ev[0].type) {
        c.GST_EVENT_FLUSH_STOP => {
            el.lock(x);
            p.proportion = 1.0;
            p.earliest_time = NONE;
            p.discont = false;
            p.processed = 0;
            p.dropped = 0;
            el.unlock(x);
            x.have_segment = 0;
            c.gst_segment_init(&x.segment, c.GST_FORMAT_UNDEFINED);
            p.position_out = NONE;
        },
        c.GST_EVENT_CAPS => {
            var caps: [*c]Caps = null;
            c.gst_event_parse_caps(ev, &caps);
            _ = c.gst_pad_check_reconfigure(x.srcpad);
            ret = setCaps(x, x.sinkpad, caps);
            if (!ret) c.gst_pad_mark_reconfigure(x.srcpad);
            forward = false;
        },
        c.GST_EVENT_SEGMENT => {
            c.gst_event_copy_segment(ev, &x.segment);
            x.have_segment = 1;
        },
        else => {},
    }
    if (ret and forward) return c.gst_pad_push_event(x.srcpad, ev);
    c.gst_event_unref(ev);
    return @intFromBool(ret);
}

fn srcEvent(_: Pad, parent_obj: [*c]c.GstObject, ev: [*c]Event) callconv(.c) c.gboolean {
    const x = of(parent_obj);
    if (klass(x).src_event) |f| return f(x, ev);
    c.gst_event_unref(ev);
    return 1;
}

fn defaultSrcEvent(s: [*c]Trans, ev: [*c]Event) callconv(.c) c.gboolean {
    const x = of(s);
    if (ev[0].type == c.GST_EVENT_QOS) {
        var proportion: f64 = 0;
        var diff: c.GstClockTimeDiff = 0;
        var ts: c.GstClockTime = 0;
        c.gst_event_parse_qos(ev, null, &proportion, &diff, &ts);
        gst_base_transform_update_qos(x, proportion, diff, ts);
    }
    return c.gst_pad_push_event(x.sinkpad, ev);
}

fn defaultSubmit(s: [*c]Trans, _: c.gboolean, inbuf: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    const x = of(s);
    const p = priv(x);
    const k = klass(x);
    if (!reconfigureUnlocked(x) or (!p.negotiated and !p.passthrough and k.set_caps != null)) {
        c.gst_buffer_unref(inbuf);
        if (el.flags(x.srcpad) & c.GST_PAD_FLAG_FLUSHING != 0) return c.GST_FLOW_FLUSHING;
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    el.lock(x);
    const qos = p.qos_enabled;
    el.unlock(x);
    if (qos and x.segment.format == c.GST_FORMAT_TIME) {
        const ts = inbuf[0].pts;
        const running = c.gst_segment_to_running_time(&x.segment, c.GST_FORMAT_TIME, ts);
        if (running != NONE) {
            el.lock(x);
            const earliest = p.earliest_time;
            const proportion = p.proportion;
            const skip = earliest != NONE and running <= earliest;
            el.unlock(x);
            if (skip) {
                p.dropped += 1;
                const stream_time = c.gst_segment_to_stream_time(&x.segment, c.GST_FORMAT_TIME, ts);
                const jitter: i64 = @as(i64, @bitCast(earliest)) -% @as(i64, @bitCast(running));
                const m = c.gst_message_new_qos(@ptrCast(x), 0, running, stream_time, ts, inbuf[0].duration);
                c.gst_message_set_qos_values(m, jitter, proportion, 1000000);
                c.gst_message_set_qos_stats(m, c.GST_FORMAT_BUFFERS, p.processed, p.dropped);
                _ = c.gst_element_post_message(@ptrCast(x), m);
                p.discont = true;
                c.gst_buffer_unref(inbuf);
                return FLOW_DROPPED;
            }
        }
    }
    if (x.queued_buf != null) c.gst_buffer_unref(x.queued_buf);
    x.queued_buf = inbuf;
    return c.GST_FLOW_OK;
}

fn defaultGenerate(s: [*c]Trans, out: [*c][*c]Buffer) callconv(.c) c.GstFlowReturn {
    const x = of(s);
    const p = priv(x);
    const k = klass(x);
    const inbuf = x.queued_buf;
    x.queued_buf = null;
    if (inbuf == null) return c.GST_FLOW_OK;
    const prepare = k.prepare_output_buffer orelse {
        c.gst_buffer_unref(inbuf);
        el.err(x, .stream, c.GST_STREAM_ERROR_NOT_IMPLEMENTED, "Sub-class has no prepare_output_buffer implementation", null, FILE, "default_generate_output", 2235);
        return c.GST_FLOW_NOT_SUPPORTED;
    };
    var ret = prepare(x, inbuf, out);
    if (ret != c.GST_FLOW_OK or out.* == null) {
        c.gst_buffer_unref(inbuf);
        out.* = null;
        return ret;
    }
    if (p.passthrough) {
        if (k.transform_ip_on_passthrough != 0) {
            if (k.transform_ip) |f| ret = f(x, out.*);
        }
    } else if (k.transform_ip != null and p.always_in_place) {
        ret = k.transform_ip.?(x, out.*);
    } else {
        ret = if (k.transform) |f| f(x, inbuf, out.*) else c.GST_FLOW_NOT_SUPPORTED;
    }
    if (out.* != inbuf) c.gst_buffer_unref(inbuf);
    return ret;
}

fn markDiscont(b: [*c]Buffer) [*c]Buffer {
    if (b[0].mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0) return b;
    const w: [*c]Buffer = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(@alignCast(b)))));
    w[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
    return w;
}

fn getRange(_: Pad, parent_obj: [*c]c.GstObject, off_in: u64, length: c.guint, out: [*c][*c]Buffer) callconv(.c) c.GstFlowReturn {
    const x = of(parent_obj);
    const p = priv(x);
    const k = klass(x);
    var off = off_in;
    var outbuf: [*c]Buffer = null;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    while (true) {
        ret = k.generate_output.?(x, &outbuf);
        if (ret == FLOW_DROPPED) ret = c.GST_FLOW_OK;
        if (ret != c.GST_FLOW_OK or outbuf != null) break;
        var inbuf: [*c]Buffer = null;
        ret = c.gst_pad_pull_range(x.sinkpad, off, length, &inbuf);
        if (ret != c.GST_FLOW_OK) return ret;
        if (k.before_transform) |f| f(x, inbuf);
        if (inbuf[0].mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0) p.discont = true;
        off +%= c.gst_buffer_get_size(inbuf);
        ret = k.submit_input_buffer.?(x, @intFromBool(p.discont), inbuf);
        if (ret != c.GST_FLOW_OK) return if (ret == FLOW_DROPPED) c.GST_FLOW_OK else ret;
        if (outbuf != null) break;
    }
    out.* = outbuf;
    if (outbuf != null) {
        if (p.discont) {
            out.* = markDiscont(outbuf);
            p.discont = false;
        }
        p.processed += 1;
    }
    return ret;
}

fn chain(_: Pad, parent_obj: [*c]c.GstObject, buffer: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    const x = of(parent_obj);
    const p = priv(x);
    const k = klass(x);
    var position: u64 = NONE;
    const ts = buffer[0].pts;
    const dur = buffer[0].duration;
    if (ts != NONE) position = if (dur != NONE) ts +% dur else ts;
    if (k.before_transform) |f| f(x, buffer);
    if (buffer[0].mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0) p.discont = true;
    var ret = k.submit_input_buffer.?(x, @intFromBool(p.discont), buffer);
    if (ret == c.GST_FLOW_OK) {
        while (true) {
            var outbuf: [*c]Buffer = null;
            ret = k.generate_output.?(x, &outbuf);
            if (outbuf != null) {
                if (ret == c.GST_FLOW_OK) {
                    if (position != NONE and x.segment.format == c.GST_FORMAT_TIME) x.segment.position = position;
                    var pos_out: u64 = NONE;
                    if (outbuf[0].pts != NONE) {
                        pos_out = outbuf[0].pts;
                        if (outbuf[0].duration != NONE) pos_out +%= outbuf[0].duration;
                    } else if (position != NONE) pos_out = position;
                    if (pos_out != NONE and x.segment.format == c.GST_FORMAT_TIME) p.position_out = pos_out;
                    if (p.discont) {
                        outbuf = markDiscont(outbuf);
                        p.discont = false;
                    }
                    p.processed += 1;
                    ret = c.gst_pad_push(x.srcpad, outbuf);
                } else c.gst_buffer_unref(outbuf);
            }
            if (!(ret == c.GST_FLOW_OK and outbuf != null)) break;
        }
    }
    if (ret == FLOW_DROPPED) {
        p.discont = true;
        ret = c.GST_FLOW_OK;
    }
    return ret;
}

fn setProp(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_QOS => gst_base_transform_set_qos_enabled(of(o), c.g_value_get_boolean(v)),
        else => el.badProperty(o, id, pspec, FILE, 2438),
    }
}

fn getProp(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_QOS => c.g_value_set_boolean(v, gst_base_transform_is_qos_enabled(of(o))),
        else => el.badProperty(o, id, pspec, FILE, 2456),
    }
}

fn activate(x: *Trans, active: bool) bool {
    const p = priv(x);
    const k = klass(x);
    var ok = true;
    if (active) {
        if (p.pad_mode == c.GST_PAD_MODE_NONE) {
            if (k.start) |f| ok = ok and f(x) != 0;
        }
        const incaps = c.gst_pad_get_current_caps(x.sinkpad);
        const outcaps = c.gst_pad_get_current_caps(x.srcpad);
        el.lock(x);
        p.have_same_caps = if (incaps != null and outcaps != null) c.gst_caps_is_equal(incaps, outcaps) != 0 or p.passthrough else p.passthrough;
        p.negotiated = false;
        x.have_segment = 0;
        c.gst_segment_init(&x.segment, c.GST_FORMAT_UNDEFINED);
        p.position_out = NONE;
        p.proportion = 1.0;
        p.earliest_time = NONE;
        p.discont = false;
        p.processed = 0;
        p.dropped = 0;
        el.unlock(x);
        if (incaps != null) c.gst_caps_unref(incaps);
        if (outcaps != null) c.gst_caps_unref(outcaps);
    } else {
        el.streamLock(x.sinkpad);
        el.streamUnlock(x.sinkpad);
        p.have_same_caps = false;
        if (k.passthrough_on_same_caps != 0) gst_base_transform_set_passthrough(x, 0);
        _ = c.gst_caps_replace(&p.cache_caps1, null);
        _ = c.gst_caps_replace(&p.cache_caps2, null);
        _ = c.gst_mini_object_replace(@ptrCast(&x.queued_buf), null);
        if (p.pad_mode != c.GST_PAD_MODE_NONE) {
            if (k.stop) |f| ok = ok and f(x) != 0;
        }
        setAllocation(x, null, null, null, null);
    }
    return ok;
}

fn sinkActivateMode(_: Pad, parent_obj: [*c]c.GstObject, m: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    const x = of(parent_obj);
    if (m != c.GST_PAD_MODE_PUSH) return 1;
    const ok = activate(x, active != 0);
    if (ok) priv(x).pad_mode = if (active != 0) c.GST_PAD_MODE_PUSH else c.GST_PAD_MODE_NONE;
    return @intFromBool(ok);
}

fn srcActivateMode(_: Pad, parent_obj: [*c]c.GstObject, m: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    const x = of(parent_obj);
    if (m != c.GST_PAD_MODE_PULL) return 1;
    var ok = c.gst_pad_activate_mode(x.sinkpad, c.GST_PAD_MODE_PULL, active) != 0;
    if (ok) ok = activate(x, active != 0);
    if (ok) priv(x).pad_mode = if (active != 0) m else c.GST_PAD_MODE_NONE;
    return @intFromBool(ok);
}

pub export fn gst_base_transform_set_passthrough(s: [*c]Trans, passthrough: c.gboolean) void {
    if (!checked(s, "gst_base_transform_set_passthrough")) return;
    const k = klass(s);
    el.lock(s);
    defer el.unlock(s);
    if (passthrough == 0) {
        if (k.transform_ip != null or k.transform != null or (k.generate_output != null and k.generate_output != @as(@TypeOf(k.generate_output), defaultGenerate))) priv(s).passthrough = false;
    } else priv(s).passthrough = true;
}

pub export fn gst_base_transform_is_passthrough(s: [*c]Trans) c.gboolean {
    if (!checked(s, "gst_base_transform_is_passthrough")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return @intFromBool(priv(s).passthrough);
}

pub export fn gst_base_transform_set_in_place(s: [*c]Trans, in_place: c.gboolean) void {
    if (!checked(s, "gst_base_transform_set_in_place")) return;
    const k = klass(s);
    el.lock(s);
    defer el.unlock(s);
    if (in_place != 0) {
        if (k.transform_ip != null) priv(s).always_in_place = true;
    } else if (k.transform != null) priv(s).always_in_place = false;
}

pub export fn gst_base_transform_is_in_place(s: [*c]Trans) c.gboolean {
    if (!checked(s, "gst_base_transform_is_in_place")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return @intFromBool(priv(s).always_in_place);
}

pub export fn gst_base_transform_update_qos(s: [*c]Trans, proportion: f64, diff: c.GstClockTimeDiff, ts: c.GstClockTime) void {
    if (!checked(s, "gst_base_transform_update_qos")) return;
    if (!check.that(ts != NONE, "gst_base_transform_update_qos", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return;
    el.lock(s);
    defer el.unlock(s);
    priv(s).proportion = proportion;
    priv(s).earliest_time = ts +% @as(u64, @bitCast(diff));
}

pub export fn gst_base_transform_set_qos_enabled(s: [*c]Trans, enabled: c.gboolean) void {
    if (!checked(s, "gst_base_transform_set_qos_enabled")) return;
    el.lock(s);
    defer el.unlock(s);
    priv(s).qos_enabled = enabled != 0;
}

pub export fn gst_base_transform_is_qos_enabled(s: [*c]Trans) c.gboolean {
    if (!checked(s, "gst_base_transform_is_qos_enabled")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return @intFromBool(priv(s).qos_enabled);
}

pub export fn gst_base_transform_set_gap_aware(s: [*c]Trans, gap_aware: c.gboolean) void {
    if (!checked(s, "gst_base_transform_set_gap_aware")) return;
    el.lock(s);
    defer el.unlock(s);
    priv(s).gap_aware = gap_aware != 0;
}

pub export fn gst_base_transform_set_prefer_passthrough(s: [*c]Trans, prefer: c.gboolean) void {
    if (!checked(s, "gst_base_transform_set_prefer_passthrough")) return;
    el.lock(s);
    defer el.unlock(s);
    priv(s).prefer_passthrough = prefer != 0;
}

pub export fn gst_base_transform_reconfigure_sink(s: [*c]Trans) void {
    if (!checked(s, "gst_base_transform_reconfigure_sink")) return;
    _ = c.gst_pad_push_event(s[0].sinkpad, c.gst_event_new_reconfigure());
}

pub export fn gst_base_transform_reconfigure_src(s: [*c]Trans) void {
    if (!checked(s, "gst_base_transform_reconfigure_src")) return;
    c.gst_pad_mark_reconfigure(s[0].srcpad);
}

pub export fn gst_base_transform_get_buffer_pool(s: [*c]Trans) ?*c.GstBufferPool {
    if (!checked(s, "gst_base_transform_get_buffer_pool")) return null;
    const pool = priv(s).pool;
    return if (pool != null) @ptrCast(@alignCast(c.gst_object_ref(pool))) else null;
}

pub export fn gst_base_transform_get_allocator(s: [*c]Trans, allocator: [*c]?*c.GstAllocator, params: [*c]c.GstAllocationParams) void {
    if (!checked(s, "gst_base_transform_get_allocator")) return;
    const p = priv(s);
    if (allocator != null) allocator.* = if (p.allocator != null) @ptrCast(@alignCast(c.gst_object_ref(p.allocator))) else null;
    if (params != null) params.* = p.params;
}

pub export fn gst_base_transform_update_src_caps(s: [*c]Trans, caps: [*c]Caps) c.gboolean {
    if (!checked(s, "gst_base_transform_update_src_caps")) return 0;
    if (c.gst_pad_push_event(s[0].srcpad, c.gst_event_new_caps(caps)) == 0) return 0;
    c.gst_pad_mark_reconfigure(s[0].srcpad);
    return 1;
}
