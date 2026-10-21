const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const info = @import("info.zig");
const pad = @import("pad.zig");
const padflow = @import("padflow.zig");
const padtemplate = @import("padtemplate.zig");
const printf = @import("printf.zig");
const va = @import("varargs.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Element = c.GstElement;
const Class = c.GstElementClass;
const Pad = pad.Pad;
const Obj = c.GstObject;
const NONE: u64 = std.math.maxInt(u64);
const NONE_TYPE: c.GType = 1 << c.G_TYPE_FUNDAMENTAL_SHIFT;

pub export var __gst_elementclass_factory: c.GQuark = 0;
pub export var __gst_elementclass_skip_doc: c.GQuark = 0;

var parent_class: ?*c.GObjectClass = null;
var type_once: gtype.Once = .{};
var pad_added: c.guint = 0;
var pad_removed: c.guint = 0;
var no_more_pads: c.guint = 0;

pub fn isElement(p: anytype) bool {
    return gtype.instanceOf(p, gst_element_get_type());
}

pub fn classOf(e: anytype) *Class {
    return gtype.classPeek(Class, e);
}

fn isClass(k: anytype) bool {
    return k != null and c.g_type_check_class_is_a(@ptrCast(@alignCast(k)), gst_element_get_type()) != 0;
}

fn lock(e: anytype) void {
    object.lock(e);
}

fn unlock(e: anytype) void {
    object.unlock(e);
}

fn objLock(e: [*c]Element) *c.GMutex {
    return @ptrCast(&e[0].object.lock);
}

fn stateLock(e: [*c]Element) void {
    c.g_rec_mutex_lock(@ptrCast(&e[0].state_lock));
}

fn stateUnlock(e: [*c]Element) void {
    c.g_rec_mutex_unlock(@ptrCast(&e[0].state_lock));
}

fn broadcast(e: [*c]Element) void {
    c.g_cond_broadcast(@ptrCast(&e[0].state_cond));
}

fn name(e: anytype) [*c]const u8 {
    return pad.nameOf(@ptrCast(@alignCast(e)));
}

fn padOf(p: anytype) [*c]Pad {
    return @ptrCast(@alignCast(p));
}

fn nextState(cur: c.GstState, pending: c.GstState) c.GstState {
    const d: c_int = @as(c_int, @intCast(pending)) - @as(c_int, @intCast(cur));
    const step: c_int = if (d > 0) 1 else if (d < 0) -1 else 0;
    return @intCast(@as(c_int, @intCast(cur)) + step);
}

fn transition(cur: c.GstState, next: c.GstState) c.GstStateChange {
    return @intCast((cur << 3) | next);
}

pub export fn gst_element_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            var t_info = std.mem.zeroes(c.GTypeInfo);
            t_info.class_size = @sizeOf(Class);
            t_info.base_init = baseInit;
            t_info.class_init = classInit;
            t_info.instance_size = @sizeOf(Element);
            t_info.instance_init = instanceInit;
            const t = c.g_type_register_static(object.gst_object_get_type(), "GstElement", &t_info, c.G_TYPE_FLAG_ABSTRACT);
            __gst_elementclass_factory = c.g_quark_from_static_string("GST_ELEMENTCLASS_FACTORY");
            __gst_elementclass_skip_doc = c.g_quark_from_static_string("GST_ELEMENTCLASS_SKIP_DOCUMENTATION");
            return t;
        }
    }.f);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(klass))).g_type;
    const padt = pad.gst_pad_get_type();
    pad_added = c.g_signal_new("pad-added", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "pad_added"), null, null, null, NONE_TYPE, @as(c.guint, 1), padt);
    pad_removed = c.g_signal_new("pad-removed", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "pad_removed"), null, null, null, NONE_TYPE, @as(c.guint, 1), padt);
    no_more_pads = c.g_signal_new("no-more-pads", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "no_more_pads"), null, null, null, NONE_TYPE, @as(c.guint, 0));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.dispose = dispose;
    gc.finalize = finalize;
    gc.constructed = constructed;
    const k: *Class = @ptrCast(@alignCast(klass));
    k.change_state = changeStateDefault;
    k.set_state = setStateDefault;
    k.get_state = getStateDefault;
    k.set_clock = setClockDefault;
    k.set_bus = setBusDefault;
    k.query = queryDefault;
    k.send_event = sendEventDefault;
    k.numpadtemplates = 0;
    k.post_message = postDefault;
    k.set_context = setContextDefault;
    k.elementfactory = null;
    info._gst_debug_register_funcptr(@ptrCast(&changeStateDefault), "gst_element_change_state_func");
    info._gst_debug_register_funcptr(@ptrCast(&setStateDefault), "gst_element_set_state_func");
    info._gst_debug_register_funcptr(@ptrCast(&getStateDefault), "gst_element_get_state_func");
    info._gst_debug_register_funcptr(@ptrCast(&setClockDefault), "gst_element_set_clock_func");
    info._gst_debug_register_funcptr(@ptrCast(&setBusDefault), "gst_element_set_bus_func");
    info._gst_debug_register_funcptr(@ptrCast(&queryDefault), "gst_element_default_query");
    info._gst_debug_register_funcptr(@ptrCast(&sendEventDefault), "gst_element_default_send_event");
    info._gst_debug_register_funcptr(@ptrCast(&postDefault), "gst_element_post_message_default");
    info._gst_debug_register_funcptr(@ptrCast(&setContextDefault), "gst_element_set_context_default");
}

fn baseInit(klass: c.gpointer) callconv(.c) void {
    const k: *Class = @ptrCast(@alignCast(klass));
    k.metadata = if (k.metadata != null) c.gst_structure_copy(@ptrCast(@alignCast(k.metadata))) else c.gst_structure_new_empty("metadata");
    const copy = c.g_list_copy(k.padtemplates);
    var node = copy;
    while (node != null) : (node = node[0].next) _ = c.gst_object_ref(node[0].data);
    k.padtemplates = copy;
    k.elementfactory = @ptrCast(@alignCast(c.g_type_get_qdata(@as(*c.GTypeClass, @ptrCast(@alignCast(klass))).g_type, __gst_elementclass_factory)));
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const e: [*c]Element = @ptrCast(@alignCast(instance));
    e[0].current_state = c.GST_STATE_NULL;
    e[0].target_state = c.GST_STATE_NULL;
    e[0].next_state = c.GST_STATE_VOID_PENDING;
    e[0].pending_state = c.GST_STATE_VOID_PENDING;
    e[0].last_return = c.GST_STATE_CHANGE_SUCCESS;
    c.g_rec_mutex_init(@ptrCast(&e[0].state_lock));
    c.g_cond_init(@ptrCast(&e[0].state_cond));
}

fn constructed(o: [*c]c.GObject) callconv(.c) void {
    parent_class.?.constructed.?(o);
}

pub export fn gst_element_release_request_pad(e: [*c]Element, p: [*c]Pad) void {
    const f = "gst_element_release_request_pad";
    if (!check.that(isElement(e), f, "GST_IS_ELEMENT (element)")) return;
    if (!check.that(pad.isPad(p), f, "GST_IS_PAD (pad)")) return;
    if (!check.that(p[0].padtemplate == null or p[0].padtemplate[0].presence == c.GST_PAD_REQUEST, f, "GST_PAD_PAD_TEMPLATE (pad) == NULL || GST_PAD_TEMPLATE_PRESENCE (GST_PAD_PAD_TEMPLATE (pad)) == GST_PAD_REQUEST")) return;
    if (!check.that(pad.parentOf(p) == @as([*c]Obj, @ptrCast(e)), f, "GST_PAD_PARENT (pad) == element")) return;
    if (classOf(e).release_pad) |rel| rel(e, pad.h(p)) else _ = gst_element_remove_pad(e, p);
}

pub export fn gst_element_provide_clock(e: [*c]Element) [*c]c.GstClock {
    if (!check.that(isElement(e), "gst_element_provide_clock", "GST_IS_ELEMENT (element)")) return null;
    if (classOf(e).provide_clock) |f| return f(e);
    return null;
}

fn setClockDefault(e: [*c]Element, clock: [*c]c.GstClock) callconv(.c) c.gboolean {
    lock(e);
    _ = object.gst_object_replace(@ptrCast(&e[0].clock), @ptrCast(clock));
    unlock(e);
    return 1;
}

pub export fn gst_element_set_clock(e: [*c]Element, clock: [*c]c.GstClock) c.gboolean {
    if (!check.that(isElement(e), "gst_element_set_clock", "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(clock == null or gtype.instanceOf(clock, c.gst_clock_get_type()), "gst_element_set_clock", "clock == NULL || GST_IS_CLOCK (clock)")) return 0;
    if (classOf(e).set_clock) |f| return f(e, clock);
    return 0;
}

pub export fn gst_element_get_clock(e: [*c]Element) [*c]c.GstClock {
    if (!check.that(isElement(e), "gst_element_get_clock", "GST_IS_ELEMENT (element)")) return null;
    lock(e);
    defer unlock(e);
    if (e[0].clock != null) _ = c.gst_object_ref(e[0].clock);
    return e[0].clock;
}

pub export fn gst_element_set_base_time(e: [*c]Element, t: c.GstClockTime) void {
    if (!check.that(isElement(e), "gst_element_set_base_time", "GST_IS_ELEMENT (element)")) return;
    if (!check.that(t != NONE, "gst_element_set_base_time", "GST_CLOCK_TIME_IS_VALID (time)")) return;
    lock(e);
    e[0].base_time = @bitCast(t);
    unlock(e);
}

pub export fn gst_element_get_base_time(e: [*c]Element) c.GstClockTime {
    if (!check.that(isElement(e), "gst_element_get_base_time", "GST_IS_ELEMENT (element)")) return NONE;
    lock(e);
    defer unlock(e);
    return @bitCast(e[0].base_time);
}

pub export fn gst_element_set_start_time(e: [*c]Element, t: c.GstClockTime) void {
    if (!check.that(isElement(e), "gst_element_set_start_time", "GST_IS_ELEMENT (element)")) return;
    lock(e);
    e[0].start_time = t;
    unlock(e);
}

pub export fn gst_element_get_start_time(e: [*c]Element) c.GstClockTime {
    if (!check.that(isElement(e), "gst_element_get_start_time", "GST_IS_ELEMENT (element)")) return NONE;
    lock(e);
    defer unlock(e);
    return e[0].start_time;
}

pub export fn gst_element_get_current_running_time(e: [*c]Element) c.GstClockTime {
    if (!check.that(isElement(e), "gst_element_get_current_running_time", "GST_IS_ELEMENT (element)")) return NONE;
    const base = gst_element_get_base_time(e);
    if (base == NONE) return NONE;
    const now = gst_element_get_current_clock_time(e);
    if (now == NONE or now < base) return NONE;
    return now - base;
}

pub export fn gst_element_get_current_clock_time(e: [*c]Element) c.GstClockTime {
    if (!check.that(isElement(e), "gst_element_get_current_clock_time", "GST_IS_ELEMENT (element)")) return NONE;
    const clock = gst_element_get_clock(e);
    if (clock == null) return NONE;
    defer c.gst_object_unref(clock);
    return c.gst_clock_get_time(clock);
}

var ghost_type: c.GType = 0;
var ghost_target: ?*const fn ([*c]Pad, [*c]Pad) callconv(.c) c.gboolean = null;

fn isGhost(p: [*c]Pad) bool {
    if (ghost_type == 0) ghost_type = gtype.weakType("gst_ghost_pad_get_type");
    return ghost_type != 0 and gtype.instanceOf(p, ghost_type);
}

pub export fn gst_element_add_pad(e: [*c]Element, p: [*c]Pad) c.gboolean {
    if (!check.that(isElement(e), "gst_element_add_pad", "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(pad.isPad(p), "gst_element_add_pad", "GST_IS_PAD (pad)")) return 0;
    pad.lock(p);
    const pad_name = c.g_strdup(p[0].object.name);
    defer c.g_free(pad_name);
    const active = p[0].mode != c.GST_PAD_MODE_NONE;
    pad.set(p, c.GST_PAD_FLAG_NEED_PARENT);
    pad.unlock(p);
    lock(e);
    if (c.gst_object_check_uniqueness(e[0].pads, pad_name) == 0) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Padname %s is not unique in element %s, not adding", pad_name, name(e));
        unlock(e);
        _ = object.gst_object_ref_sink(p);
        c.gst_object_unref(p);
        return 0;
    }
    if (c.gst_object_set_parent(@ptrCast(p), @ptrCast(e)) == 0) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Pad %s already has parent when trying to add to element %s", pad_name, name(e));
        unlock(e);
        return 0;
    }
    const activate = !active and (e[0].current_state > c.GST_STATE_READY or e[0].next_state == c.GST_STATE_PAUSED);
    switch (p[0].direction) {
        c.GST_PAD_SRC => {
            e[0].srcpads = c.g_list_append(e[0].srcpads, p);
            e[0].numsrcpads += 1;
        },
        c.GST_PAD_SINK => {
            e[0].sinkpads = c.g_list_append(e[0].sinkpads, p);
            e[0].numsinkpads += 1;
        },
        else => {
            pad.lock(p);
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Trying to add pad %s to element %s, but it has no direction", p[0].object.name, name(e));
            pad.unlock(p);
            unlock(e);
            return 0;
        },
    }
    e[0].pads = c.g_list_append(e[0].pads, p);
    e[0].numpads += 1;
    e[0].pads_cookie +%= 1;
    unlock(e);
    if (activate) _ = pad.gst_pad_set_active(p, 1);
    c.g_signal_emit(e, pad_added, 0, p);
    return 1;
}

pub export fn gst_element_remove_pad(e: [*c]Element, p: [*c]Pad) c.gboolean {
    if (!check.that(isElement(e), "gst_element_remove_pad", "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(pad.isPad(p), "gst_element_remove_pad", "GST_IS_PAD (pad)")) return 0;
    pad.lock(p);
    if (pad.parentOf(p) != @as([*c]Obj, @ptrCast(e))) {
        pad.unlock(p);
        lock(e);
        pad.lock(p);
        c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Padname %s:%s does not belong to element %s when removing", pad.parentName(p), pad.padName(p), name(e));
        pad.unlock(p);
        unlock(e);
        return 0;
    }
    pad.unlock(p);
    const peer = pad.gst_pad_get_peer(p);
    if (peer != null) {
        if (pad.isSrc(p)) _ = pad.gst_pad_unlink(p, peer) else _ = pad.gst_pad_unlink(peer, p);
        c.gst_object_unref(peer);
    }
    if (isGhost(p)) {
        if (ghost_target == null) ghost_target = gtype.lookup(?*const fn ([*c]Pad, [*c]Pad) callconv(.c) c.gboolean, "gst_ghost_pad_set_target");
        if (ghost_target) |f| _ = f(p, null);
    }
    lock(e);
    switch (p[0].direction) {
        c.GST_PAD_SRC => {
            e[0].srcpads = c.g_list_remove(e[0].srcpads, p);
            e[0].numsrcpads -= 1;
        },
        c.GST_PAD_SINK => {
            e[0].sinkpads = c.g_list_remove(e[0].sinkpads, p);
            e[0].numsinkpads -= 1;
        },
        else => c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Removing pad without direction???"),
    }
    e[0].pads = c.g_list_remove(e[0].pads, p);
    e[0].numpads -= 1;
    e[0].pads_cookie +%= 1;
    unlock(e);
    c.g_signal_emit(e, pad_removed, 0, p);
    c.gst_object_unparent(@ptrCast(p));
    return 1;
}

pub export fn gst_element_no_more_pads(e: [*c]Element) void {
    if (!check.that(isElement(e), "gst_element_no_more_pads", "GST_IS_ELEMENT (element)")) return;
    c.g_signal_emit(e, no_more_pads, 0);
}

fn padNamed(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const p = padOf(@constCast(a));
    pad.lock(p);
    defer pad.unlock(p);
    return c.strcmp(p[0].object.name, @ptrCast(b));
}

pub export fn gst_element_get_static_pad(e: [*c]Element, pad_name: [*c]const u8) [*c]Pad {
    if (!check.that(isElement(e), "gst_element_get_static_pad", "GST_IS_ELEMENT (element)")) return null;
    if (!check.that(pad_name != null, "gst_element_get_static_pad", "name != NULL")) return null;
    lock(e);
    defer unlock(e);
    const found = c.g_list_find_custom(e[0].pads, pad_name, padNamed);
    if (found == null) return null;
    _ = c.gst_object_ref(found[0].data);
    return padOf(found[0].data);
}

fn validRequestName(templ_in: [*c]const u8, name_in: [*c]const u8) bool {
    if (!check.that(templ_in != null, "gst_element_is_valid_request_template_name", "templ_name != NULL")) return false;
    if (!check.that(name_in != null, "gst_element_is_valid_request_template_name", "name != NULL")) return false;
    var tn = templ_in;
    var nm = name_in;
    if (c.strcmp(tn, nm) == 0) return true;
    while (true) {
        const tp: [*c]const u8 = c.strchr(tn, '%');
        if (tp == null) return false;
        const prefix: usize = @intCast(tp - tn);
        if (c.strlen(nm) <= prefix or c.strncmp(tn, nm, prefix) != 0) return false;
        if (tp[1] == 's') return true;
        const np: [*c]const u8 = nm + prefix;
        tn = c.strchr(tp, '_');
        nm = c.strchr(np, '_');
        if ((tn != null) != (nm != null)) return false;
        const more = tn != null and nm != null;
        var tpost: usize = 0;
        var npost: usize = 0;
        if (tp[2] != 0 and tp[2] != '_') {
            if (more) {
                tpost = @intCast(tn - (tp + 2));
                npost = @intCast(nm - np);
            } else {
                tpost = c.strlen(tp + 2);
                npost = c.strlen(np);
            }
            if (c.strncmp(tp + 2, np + npost - tpost, tpost) != 0) return false;
        }
        if (np[0] == '%') {
            const len: usize = if (more) @intCast(nm - np) else c.strlen(np);
            if (c.strncmp(np, tp, len) != 0) return false;
        } else {
            var target: [*c]u8 = null;
            if (npost > tpost) target = c.g_strndup(np, npost - tpost);
            defer c.g_free(target);
            const spec: [*c]const u8 = if (target != null) target else np;
            var end: [*c]u8 = null;
            if (tp[1] == 'd') {
                const v = c.g_ascii_strtoll(spec, &end, 10);
                if (v < std.math.minInt(c_int) or v > std.math.maxInt(c_int) or (end[0] != 0 and end[0] != '_')) return false;
            } else if (tp[1] == 'u') {
                const v = c.g_ascii_strtoull(spec, &end, 10);
                if (v > std.math.maxInt(c_uint) or (end[0] != 0 and end[0] != '_')) return false;
            }
        }
        if (!more) return true;
        tn += 1;
        nm += 1;
    }
}

fn requestPad(e: [*c]Element, templ: [*c]c.GstPadTemplate, pad_name: [*c]const u8, caps: [*c]const c.GstCaps) [*c]Pad {
    const k = classOf(e);
    if (pad_name != null) {
        if (!check.that(validRequestName(templ[0].name_template, pad_name), "_gst_element_request_pad", "gst_element_is_valid_request_template_name (templ->name_template, name)")) return null;
        const existing = gst_element_get_static_pad(e, pad_name);
        if (existing != null) {
            c.gst_object_unref(existing);
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Element %s already has a pad named %s, the behaviour of  gst_element_get_request_pad() for existing pads is undefined!", name(e), pad_name);
        }
    }
    if (c.g_list_find(k.padtemplates, templ) == null)
        c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Element type %s does not have a pad template %s (%p)", c.g_type_name(gtype.typeOf(e)), templ[0].name_template, templ);
    var newpad: [*c]Pad = null;
    if (k.request_new_pad) |f| newpad = padOf(f(e, templ, pad_name, caps));
    if (newpad != null) _ = c.gst_object_ref(newpad);
    return newpad;
}

pub export fn gst_element_get_request_pad(e: [*c]Element, pad_name: [*c]const u8) [*c]Pad {
    return gst_element_request_pad_simple(e, pad_name);
}

pub export fn gst_element_request_pad_simple(e: [*c]Element, pad_name: [*c]const u8) [*c]Pad {
    if (!check.that(isElement(e), "gst_element_request_pad_simple", "GST_IS_ELEMENT (element)")) return null;
    if (!check.that(pad_name != null, "gst_element_request_pad_simple", "name != NULL")) return null;
    const k = classOf(e);
    var templ = simpleTemplate(k, pad_name);
    var req: [*c]const u8 = null;
    if (templ != null) {
        req = if (c.strstr(pad_name, "%") != null) null else pad_name;
    } else {
        var l = k.padtemplates;
        while (l != null) : (l = l[0].next) {
            const t: [*c]c.GstPadTemplate = @ptrCast(@alignCast(l[0].data));
            if (t[0].presence == c.GST_PAD_REQUEST and validRequestName(t[0].name_template, pad_name)) {
                templ = t;
                req = pad_name;
                break;
            }
        }
        if (templ == null) return null;
    }
    return requestPad(e, templ, req, null);
}

pub export fn gst_element_request_pad(e: [*c]Element, templ: [*c]c.GstPadTemplate, pad_name: [*c]const u8, caps: [*c]const c.GstCaps) [*c]Pad {
    const f = "gst_element_request_pad";
    if (!check.that(isElement(e), f, "GST_IS_ELEMENT (element)")) return null;
    if (!check.that(templ != null, f, "templ != NULL")) return null;
    if (!check.that(templ[0].presence == c.GST_PAD_REQUEST, f, "templ->presence == GST_PAD_REQUEST")) return null;
    return requestPad(e, templ, pad_name, caps);
}

fn iterList(e: [*c]Element, list: *[*c]c.GList) [*c]c.GstIterator {
    lock(e);
    defer unlock(e);
    return c.gst_iterator_new_list(pad.gst_pad_get_type(), objLock(e), &e[0].pads_cookie, @ptrCast(list), @ptrCast(e), null);
}

pub export fn gst_element_iterate_pads(e: [*c]Element) [*c]c.GstIterator {
    if (!check.that(isElement(e), "gst_element_iterate_pads", "GST_IS_ELEMENT (element)")) return null;
    return iterList(e, @ptrCast(&e[0].pads));
}

pub export fn gst_element_iterate_src_pads(e: [*c]Element) [*c]c.GstIterator {
    if (!check.that(isElement(e), "gst_element_iterate_src_pads", "GST_IS_ELEMENT (element)")) return null;
    return iterList(e, @ptrCast(&e[0].srcpads));
}

pub export fn gst_element_iterate_sink_pads(e: [*c]Element) [*c]c.GstIterator {
    if (!check.that(isElement(e), "gst_element_iterate_sink_pads", "GST_IS_ELEMENT (element)")) return null;
    return iterList(e, @ptrCast(&e[0].sinkpads));
}

fn eachPad(e: [*c]Element, func: c.GstElementForeachPadFunc, data: c.gpointer, list: [*c]c.GList, count: c.guint16) c.gboolean {
    if (!check.that(isElement(e), "gst_element_do_foreach_pad", "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(func != null, "gst_element_do_foreach_pad", "func != NULL")) return 0;
    lock(e);
    const n: usize = count;
    const pads = std.heap.c_allocator.alloc(c.gpointer, n + 1) catch @panic("out of memory");
    defer std.heap.c_allocator.free(pads);
    var i: usize = 0;
    var l = list;
    while (l != null) : (l = l[0].next) {
        pads[i] = c.gst_object_ref(l[0].data);
        i += 1;
    }
    unlock(e);
    if (n == 0) return 0;
    var ret: c.gboolean = 1;
    for (pads[0..n]) |p| {
        ret = func.?(e, @ptrCast(@alignCast(p)), data);
        if (ret == 0) break;
    }
    for (pads[0..n]) |p| c.gst_object_unref(p);
    return ret;
}

pub export fn gst_element_foreach_sink_pad(e: [*c]Element, func: c.GstElementForeachPadFunc, data: c.gpointer) c.gboolean {
    return eachPad(e, func, data, e[0].sinkpads, e[0].numsinkpads);
}

pub export fn gst_element_foreach_src_pad(e: [*c]Element, func: c.GstElementForeachPadFunc, data: c.gpointer) c.gboolean {
    return eachPad(e, func, data, e[0].srcpads, e[0].numsrcpads);
}

pub export fn gst_element_foreach_pad(e: [*c]Element, func: c.GstElementForeachPadFunc, data: c.gpointer) c.gboolean {
    return eachPad(e, func, data, e[0].pads, e[0].numpads);
}

pub export fn gst_element_class_add_pad_template(k: [*c]Class, templ: [*c]c.GstPadTemplate) void {
    if (!check.that(isClass(k), "gst_element_class_add_pad_template", "GST_IS_ELEMENT_CLASS (klass)")) return;
    if (!check.that(padtemplate.isTemplate(templ), "gst_element_class_add_pad_template", "GST_IS_PAD_TEMPLATE (templ)")) return;
    var l = k[0].padtemplates;
    while (l != null) : (l = l[0].next) {
        const t: [*c]c.GstPadTemplate = @ptrCast(@alignCast(l[0].data));
        if (c.strcmp(templ[0].name_template, t[0].name_template) == 0) {
            c.gst_object_unref(t);
            _ = object.gst_object_ref_sink(templ);
            l[0].data = templ;
            return;
        }
    }
    _ = object.gst_object_ref_sink(templ);
    k[0].padtemplates = c.g_list_append(k[0].padtemplates, templ);
    k[0].numpadtemplates += 1;
}

pub export fn gst_element_class_add_static_pad_template(k: [*c]Class, s: [*c]c.GstStaticPadTemplate) void {
    gst_element_class_add_pad_template(k, padtemplate.gst_static_pad_template_get(s));
}

pub export fn gst_element_class_add_static_pad_template_with_gtype(k: [*c]Class, s: [*c]c.GstStaticPadTemplate, t: c.GType) void {
    gst_element_class_add_pad_template(k, padtemplate.gst_pad_template_new_from_static_pad_template_with_gtype(s, t));
}

fn metadataOf(k: [*c]Class) [*c]c.GstStructure {
    return @ptrCast(@alignCast(k[0].metadata));
}

pub export fn gst_element_class_add_metadata(k: [*c]Class, key: [*c]const u8, v: [*c]const u8) void {
    const f = "gst_element_class_add_metadata";
    if (!check.that(isClass(k), f, "GST_IS_ELEMENT_CLASS (klass)")) return;
    if (!check.that(key != null, f, "key != NULL")) return;
    if (!check.that(v != null, f, "value != NULL")) return;
    var gv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&gv, c.G_TYPE_STRING);
    c.g_value_set_string(&gv, v);
    c.gst_structure_take_value(metadataOf(k), key, &gv);
}

pub export fn gst_element_class_add_static_metadata(k: [*c]Class, key: [*c]const u8, v: [*c]const u8) void {
    const f = "gst_element_class_add_static_metadata";
    if (!check.that(isClass(k), f, "GST_IS_ELEMENT_CLASS (klass)")) return;
    if (!check.that(key != null, f, "key != NULL")) return;
    if (!check.that(v != null, f, "value != NULL")) return;
    var gv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&gv, c.G_TYPE_STRING);
    c.g_value_set_static_string(&gv, v);
    c.gst_structure_take_value(metadataOf(k), key, &gv);
}

fn nonEmpty(s: [*c]const u8) bool {
    return s != null and s[0] != 0;
}

fn metaChecks(comptime f: []const u8, k: [*c]Class, long: [*c]const u8, klass: [*c]const u8, desc: [*c]const u8, author: [*c]const u8) bool {
    if (!check.that(isClass(k), f, "GST_IS_ELEMENT_CLASS (klass)")) return false;
    if (!check.that(nonEmpty(long), f, "longname != NULL && *longname != '\\0'")) return false;
    if (!check.that(nonEmpty(klass), f, "classification != NULL && *classification != '\\0'")) return false;
    if (!check.that(nonEmpty(desc), f, "description != NULL && *description != '\\0'")) return false;
    return check.that(nonEmpty(author), f, "author != NULL && *author != '\\0'");
}

fn setMeta(k: [*c]Class, long: [*c]const u8, klass: [*c]const u8, desc: [*c]const u8, author: [*c]const u8, static: bool) void {
    const keys = [_][*c]const u8{ "long-name", "klass", "description", "author" };
    const vals = [_][*c]const u8{ long, klass, desc, author };
    for (keys, vals) |key, v| {
        var gv = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&gv, c.G_TYPE_STRING);
        if (static) c.g_value_set_static_string(&gv, v) else c.g_value_set_string(&gv, v);
        c.gst_structure_take_value_static_str(metadataOf(k), key, &gv);
    }
}

pub export fn gst_element_class_set_metadata(k: [*c]Class, long: [*c]const u8, klass: [*c]const u8, desc: [*c]const u8, author: [*c]const u8) void {
    if (!metaChecks("gst_element_class_set_metadata", k, long, klass, desc, author)) return;
    setMeta(k, long, klass, desc, author, false);
}

pub export fn gst_element_class_set_static_metadata(k: [*c]Class, long: [*c]const u8, klass: [*c]const u8, desc: [*c]const u8, author: [*c]const u8) void {
    if (!metaChecks("gst_element_class_set_static_metadata", k, long, klass, desc, author)) return;
    setMeta(k, long, klass, desc, author, true);
}

pub export fn gst_element_class_get_metadata(k: [*c]Class, key: [*c]const u8) [*c]const u8 {
    if (!check.that(isClass(k), "gst_element_class_get_metadata", "GST_IS_ELEMENT_CLASS (klass)")) return null;
    if (!check.that(key != null, "gst_element_class_get_metadata", "key != NULL")) return null;
    return c.gst_structure_get_string(metadataOf(k), key);
}

pub export fn gst_element_get_metadata(e: [*c]Element, key: [*c]const u8) [*c]const u8 {
    if (!check.that(isElement(e), "gst_element_get_metadata", "GST_IS_ELEMENT (element)")) return null;
    if (!check.that(key != null, "gst_element_get_metadata", "key != NULL")) return null;
    return gst_element_class_get_metadata(classOf(e), key);
}

pub export fn gst_element_class_get_pad_template_list(k: [*c]Class) [*c]c.GList {
    if (!check.that(isClass(k), "gst_element_class_get_pad_template_list", "GST_IS_ELEMENT_CLASS (element_class)")) return null;
    return k[0].padtemplates;
}

pub export fn gst_element_get_pad_template_list(e: [*c]Element) [*c]c.GList {
    if (!check.that(isElement(e), "gst_element_get_pad_template_list", "GST_IS_ELEMENT (element)")) return null;
    return gst_element_class_get_pad_template_list(classOf(e));
}

pub export fn gst_element_class_get_pad_template(k: [*c]Class, templ_name: [*c]const u8) [*c]c.GstPadTemplate {
    if (!check.that(isClass(k), "gst_element_class_get_pad_template", "GST_IS_ELEMENT_CLASS (element_class)")) return null;
    if (!check.that(templ_name != null, "gst_element_class_get_pad_template", "name != NULL")) return null;
    var l = k[0].padtemplates;
    while (l != null) : (l = l[0].next) {
        const t: [*c]c.GstPadTemplate = @ptrCast(@alignCast(l[0].data));
        if (c.strcmp(t[0].name_template, templ_name) == 0) return t;
    }
    return null;
}

pub export fn gst_element_get_pad_template(e: [*c]Element, templ_name: [*c]const u8) [*c]c.GstPadTemplate {
    if (!check.that(isElement(e), "gst_element_get_pad_template", "GST_IS_ELEMENT (element)")) return null;
    if (!check.that(templ_name != null, "gst_element_get_pad_template", "name != NULL")) return null;
    return gst_element_class_get_pad_template(classOf(e), templ_name);
}

fn simpleTemplate(k: [*c]Class, n: [*c]const u8) [*c]c.GstPadTemplate {
    const t = gst_element_class_get_pad_template(k, n);
    return if (t != null and t[0].presence == c.GST_PAD_REQUEST) t else null;
}

fn randomPad(e: [*c]Element, linked: bool, dir: c.GstPadDirection) [*c]Pad {
    var l: [*c]c.GList = undefined;
    switch (dir) {
        c.GST_PAD_SRC => {
            lock(e);
            l = e[0].srcpads;
        },
        c.GST_PAD_SINK => {
            lock(e);
            l = e[0].sinkpads;
        },
        else => {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "unknown pad direction %d", dir);
            return null;
        },
    }
    var result: [*c]Pad = null;
    while (l != null) : (l = l[0].next) {
        const p = padOf(l[0].data);
        pad.lock(p);
        const skip = linked and p[0].peer == null;
        pad.unlock(p);
        if (skip) continue;
        result = p;
        break;
    }
    if (result != null) _ = c.gst_object_ref(result);
    unlock(e);
    return result;
}

fn sendEventDefault(e: [*c]Element, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const p = if (ev[0].type & c.GST_EVENT_TYPE_DOWNSTREAM != 0) randomPad(e, true, c.GST_PAD_SINK) else randomPad(e, true, c.GST_PAD_SRC);
    if (p == null) {
        c.gst_mini_object_unref(@ptrCast(ev));
        return 0;
    }
    defer c.gst_object_unref(p);
    return padflow.gst_pad_send_event(p, ev);
}

pub export fn gst_element_send_event(e: [*c]Element, ev: [*c]c.GstEvent) c.gboolean {
    if (!check.that(isElement(e), "gst_element_send_event", "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(ev != null, "gst_element_send_event", "event != NULL")) return 0;
    stateLock(e);
    defer stateUnlock(e);
    if (classOf(e).send_event) |f| return f(e, ev);
    c.gst_mini_object_unref(@ptrCast(ev));
    return 0;
}

pub export fn gst_element_seek(e: [*c]Element, rate: c.gdouble, format: c.GstFormat, flags: c.GstSeekFlags, start_type: c.GstSeekType, start: c.gint64, stop_type: c.GstSeekType, stop: c.gint64) c.gboolean {
    if (!check.that(isElement(e), "gst_element_seek", "GST_IS_ELEMENT (element)")) return 0;
    return gst_element_send_event(e, c.gst_event_new_seek(rate, format, flags, start_type, start, stop_type, stop));
}

fn queryDefault(e: [*c]Element, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    var result: c.gboolean = 0;
    const p = randomPad(e, false, c.GST_PAD_SRC);
    if (p != null) {
        result = padflow.gst_pad_query(p, q);
        c.gst_object_unref(p);
        return result;
    }
    const s = randomPad(e, true, c.GST_PAD_SINK);
    if (s != null) {
        const peer = pad.gst_pad_get_peer(s);
        if (peer != null) {
            result = padflow.gst_pad_query(peer, q);
            c.gst_object_unref(peer);
        }
        c.gst_object_unref(s);
    }
    return result;
}

pub export fn gst_element_query(e: [*c]Element, q: [*c]c.GstQuery) c.gboolean {
    if (!check.that(isElement(e), "gst_element_query", "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(q != null, "gst_element_query", "query != NULL")) return 0;
    if (classOf(e).query) |f| return f(e, q);
    return 0;
}

fn postDefault(e: [*c]Element, m: [*c]c.GstMessage) callconv(.c) c.gboolean {
    if (!check.that(isElement(e), "gst_element_post_message_default", "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(m != null, "gst_element_post_message_default", "message != NULL")) return 0;
    lock(e);
    const bus = e[0].bus;
    if (bus == null) {
        unlock(e);
        c.gst_mini_object_unref(@ptrCast(m));
        return 0;
    }
    _ = c.gst_object_ref(bus);
    unlock(e);
    defer c.gst_object_unref(bus);
    return c.gst_bus_post(bus, m);
}

pub export fn gst_element_post_message(e: [*c]Element, m: [*c]c.GstMessage) c.gboolean {
    if (!check.that(isElement(e), "gst_element_post_message", "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(m != null, "gst_element_post_message", "message != NULL")) return 0;
    if (classOf(e).post_message) |f| return f(e, m);
    c.gst_mini_object_unref(@ptrCast(m));
    return 0;
}

pub export fn _gst_element_error_printf(fmt: [*c]const u8, ...) callconv(.c) [*c]u8 {
    if (fmt == null or fmt[0] == 0) return null;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var buf: [*c]u8 = null;
    if (printf.vasprintf(&buf, fmt, &ap) < 0) return null;
    return buf;
}

pub export fn gst_element_message_full_with_details(e: [*c]Element, kind: c.GstMessageType, domain: c.GQuark, code: c.gint, text: [*c]u8, debug: [*c]u8, file: [*c]const u8, function: [*c]const u8, line: c.gint, s: [*c]c.GstStructure) void {
    const f = "gst_element_message_full_with_details";
    if (!check.that(isElement(e), f, "GST_IS_ELEMENT (element)")) return;
    if (!check.that(kind == c.GST_MESSAGE_ERROR or kind == c.GST_MESSAGE_WARNING or kind == c.GST_MESSAGE_INFO, f, "(type == GST_MESSAGE_ERROR) || (type == GST_MESSAGE_WARNING) || (type == GST_MESSAGE_INFO)")) return;
    var sent_text = text;
    if (text == null or text[0] == 0) {
        c.g_free(text);
        sent_text = c.gst_error_get_message(domain, code);
    }
    const path = c.gst_object_get_path_string(@ptrCast(e));
    const sent_debug = if (debug != null and debug[0] != 0)
        c.g_strdup_printf("%s(%d): %s (): %s:\n%s", file, line, function, path, debug)
    else
        c.g_strdup_printf("%s(%d): %s (): %s", file, line, function, path);
    c.g_free(path);
    c.g_free(debug);
    const err = c.g_error_new_literal(domain, code, sent_text);
    const m = switch (kind) {
        c.GST_MESSAGE_ERROR => c.gst_message_new_error_with_details(@ptrCast(e), err, sent_debug, s),
        c.GST_MESSAGE_WARNING => c.gst_message_new_warning_with_details(@ptrCast(e), err, sent_debug, s),
        else => c.gst_message_new_info_with_details(@ptrCast(e), err, sent_debug, s),
    };
    _ = gst_element_post_message(e, m);
    c.g_error_free(err);
    c.g_free(sent_debug);
    c.g_free(sent_text);
}

pub export fn gst_element_message_full(e: [*c]Element, kind: c.GstMessageType, domain: c.GQuark, code: c.gint, text: [*c]u8, debug: [*c]u8, file: [*c]const u8, function: [*c]const u8, line: c.gint) void {
    gst_element_message_full_with_details(e, kind, domain, code, text, debug, file, function, line, null);
}

pub export fn gst_element_is_locked_state(e: [*c]Element) c.gboolean {
    if (!check.that(isElement(e), "gst_element_is_locked_state", "GST_IS_ELEMENT (element)")) return 0;
    lock(e);
    defer unlock(e);
    return @intFromBool(e[0].object.flags & c.GST_ELEMENT_FLAG_LOCKED_STATE != 0);
}

pub export fn gst_element_set_locked_state(e: [*c]Element, on: c.gboolean) c.gboolean {
    if (!check.that(isElement(e), "gst_element_set_locked_state", "GST_IS_ELEMENT (element)")) return 0;
    lock(e);
    defer unlock(e);
    const old = e[0].object.flags & c.GST_ELEMENT_FLAG_LOCKED_STATE != 0;
    if (old == (on != 0)) return 0;
    if (on != 0) e[0].object.flags |= c.GST_ELEMENT_FLAG_LOCKED_STATE else e[0].object.flags &= ~@as(c.guint32, c.GST_ELEMENT_FLAG_LOCKED_STATE);
    return 1;
}

pub export fn gst_element_sync_state_with_parent(e: [*c]Element) c.gboolean {
    if (!check.that(isElement(e), "gst_element_sync_state_with_parent", "GST_IS_ELEMENT (element)")) return 0;
    const parent: [*c]Element = @ptrCast(@alignCast(c.gst_object_get_parent(@ptrCast(e))));
    if (parent == null) return 0;
    defer c.gst_object_unref(parent);
    lock(parent);
    const cur = parent[0].current_state;
    const pending = parent[0].pending_state;
    unlock(parent);
    const target = if (pending != c.GST_STATE_VOID_PENDING) pending else cur;
    return @intFromBool(gst_element_set_state(e, target) != c.GST_STATE_CHANGE_FAILURE);
}

fn getStateDefault(e: [*c]Element, state: [*c]c.GstState, pending: [*c]c.GstState, timeout: c.GstClockTime) callconv(.c) c.GstStateChangeReturn {
    lock(e);
    const end = if (timeout != NONE) c.g_get_monotonic_time() + @as(i64, @intCast(timeout / 1000)) else 0;
    var ret: c.GstStateChangeReturn = undefined;
    outer: while (true) {
        ret = e[0].last_return;
        if (ret != c.GST_STATE_CHANGE_ASYNC) break;
        const old = e[0].pending_state;
        if (old != c.GST_STATE_VOID_PENDING) {
            const cookie = e[0].state_cookie;
            const signaled = if (timeout != NONE) c.g_cond_wait_until(@ptrCast(&e[0].state_cond), objLock(e), end) != 0 else blk: {
                c.g_cond_wait(@ptrCast(&e[0].state_cond), objLock(e));
                break :blk true;
            };
            if (!signaled) {
                ret = c.GST_STATE_CHANGE_ASYNC;
                break :outer;
            }
            if (cookie != e[0].state_cookie) {
                if (state != null) state.* = c.GST_STATE_VOID_PENDING;
                if (pending != null) pending.* = c.GST_STATE_VOID_PENDING;
                unlock(e);
                return c.GST_STATE_CHANGE_FAILURE;
            }
            ret = if (old == e[0].current_state) c.GST_STATE_CHANGE_SUCCESS else c.GST_STATE_CHANGE_FAILURE;
            if (e[0].pending_state == c.GST_STATE_VOID_PENDING) ret = c.GST_STATE_CHANGE_SUCCESS;
        }
        if (old == e[0].current_state) break;
    }
    if (state != null) state.* = e[0].current_state;
    if (pending != null) pending.* = e[0].pending_state;
    unlock(e);
    return ret;
}

pub export fn gst_element_get_state(e: [*c]Element, state: [*c]c.GstState, pending: [*c]c.GstState, timeout: c.GstClockTime) c.GstStateChangeReturn {
    if (!check.that(isElement(e), "gst_element_get_state", "GST_IS_ELEMENT (element)")) return c.GST_STATE_CHANGE_FAILURE;
    if (classOf(e).get_state) |f| return f(e, state, pending, timeout);
    return c.GST_STATE_CHANGE_FAILURE;
}

pub export fn gst_element_abort_state(e: [*c]Element) void {
    if (!check.that(isElement(e), "gst_element_abort_state", "GST_IS_ELEMENT (element)")) return;
    lock(e);
    defer unlock(e);
    if (e[0].pending_state == c.GST_STATE_VOID_PENDING or e[0].last_return == c.GST_STATE_CHANGE_FAILURE) return;
    e[0].last_return = c.GST_STATE_CHANGE_FAILURE;
    broadcast(e);
}

pub export fn _priv_gst_element_state_changed(e: [*c]Element, old: c.GstState, new: c.GstState, pending: c.GstState) void {
    if (classOf(e).state_changed) |f| f(e, old, new, pending);
    _ = gst_element_post_message(e, c.gst_message_new_state_changed(@ptrCast(e), old, new, pending));
}

pub export fn gst_element_continue_state(e: [*c]Element, ret: c.GstStateChangeReturn) c.GstStateChangeReturn {
    lock(e);
    const old_ret = e[0].last_return;
    e[0].last_return = ret;
    const pending = e[0].pending_state;
    if (pending == c.GST_STATE_VOID_PENDING) {
        unlock(e);
        return ret;
    }
    const old_state = e[0].current_state;
    const old_next = e[0].next_state;
    e[0].current_state = old_next;
    const cur = old_next;
    if (pending == cur) {
        e[0].pending_state = c.GST_STATE_VOID_PENDING;
        e[0].next_state = c.GST_STATE_VOID_PENDING;
        unlock(e);
        if (old_state != old_next or old_ret == c.GST_STATE_CHANGE_ASYNC) _priv_gst_element_state_changed(e, old_state, old_next, c.GST_STATE_VOID_PENDING);
        broadcast(e);
        return ret;
    }
    const next = nextState(cur, pending);
    e[0].next_state = next;
    e[0].last_return = c.GST_STATE_CHANGE_ASYNC;
    unlock(e);
    _priv_gst_element_state_changed(e, old_state, old_next, pending);
    return gst_element_change_state(e, transition(cur, next));
}

pub export fn gst_element_lost_state(e: [*c]Element) void {
    if (!check.that(isElement(e), "gst_element_lost_state", "GST_IS_ELEMENT (element)")) return;
    lock(e);
    if (e[0].last_return == c.GST_STATE_CHANGE_FAILURE) {
        unlock(e);
        return;
    }
    if (e[0].pending_state != c.GST_STATE_VOID_PENDING) {
        unlock(e);
        _ = gst_element_post_message(e, c.gst_message_new_async_start(@ptrCast(e)));
        return;
    }
    const old = e[0].current_state;
    const new: c.GstState = if (old > c.GST_STATE_PAUSED) c.GST_STATE_PAUSED else old;
    e[0].current_state = new;
    e[0].next_state = new;
    e[0].pending_state = new;
    e[0].last_return = c.GST_STATE_CHANGE_ASYNC;
    unlock(e);
    _priv_gst_element_state_changed(e, new, new, new);
    _ = gst_element_post_message(e, c.gst_message_new_async_start(@ptrCast(e)));
}

pub export fn gst_element_set_state(e: [*c]Element, state: c.GstState) c.GstStateChangeReturn {
    if (!check.that(isElement(e), "gst_element_set_state", "GST_IS_ELEMENT (element)")) return c.GST_STATE_CHANGE_FAILURE;
    if (classOf(e).set_state) |f| return f(e, state);
    return c.GST_STATE_CHANGE_FAILURE;
}

fn setStateDefault(e: [*c]Element, state: c.GstState) callconv(.c) c.GstStateChangeReturn {
    if (!check.that(isElement(e), "gst_element_set_state_func", "GST_IS_ELEMENT (element)")) return c.GST_STATE_CHANGE_FAILURE;
    stateLock(e);
    defer stateUnlock(e);
    lock(e);
    if (e[0].last_return == c.GST_STATE_CHANGE_FAILURE) {
        e[0].next_state = c.GST_STATE_VOID_PENDING;
        e[0].pending_state = c.GST_STATE_VOID_PENDING;
        e[0].last_return = c.GST_STATE_CHANGE_SUCCESS;
    }
    var cur = e[0].current_state;
    var next = e[0].next_state;
    const old_pending = e[0].pending_state;
    if (state != e[0].target_state) {
        e[0].target_state = state;
        e[0].state_cookie +%= 1;
    }
    e[0].pending_state = state;
    if (old_pending != c.GST_STATE_VOID_PENDING) {
        if (old_pending <= state or next == state) {
            e[0].last_return = c.GST_STATE_CHANGE_ASYNC;
            unlock(e);
            return c.GST_STATE_CHANGE_ASYNC;
        }
        if (next > state and e[0].last_return == c.GST_STATE_CHANGE_ASYNC) cur = next;
    }
    next = nextState(cur, state);
    e[0].next_state = next;
    if (cur != next) e[0].last_return = c.GST_STATE_CHANGE_ASYNC;
    const t = transition(cur, next);
    broadcast(e);
    unlock(e);
    return gst_element_change_state(e, t);
}

pub export fn gst_element_change_state(e: [*c]Element, t: c.GstStateChange) c.GstStateChangeReturn {
    var ret: c.GstStateChangeReturn = if (classOf(e).change_state) |f| f(e, t) else c.GST_STATE_CHANGE_FAILURE;
    switch (ret) {
        c.GST_STATE_CHANGE_FAILURE => gst_element_abort_state(e),
        c.GST_STATE_CHANGE_ASYNC => {
            if (e[0].target_state > c.GST_STATE_READY) return ret;
            ret = gst_element_continue_state(e, c.GST_STATE_CHANGE_SUCCESS);
        },
        c.GST_STATE_CHANGE_SUCCESS, c.GST_STATE_CHANGE_NO_PREROLL => ret = gst_element_continue_state(e, ret),
        else => {
            lock(e);
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "%s: unknown return value %d from a state change function", name(e), ret);
            e[0].last_return = c.GST_STATE_CHANGE_FAILURE;
            unlock(e);
            return c.GST_STATE_CHANGE_FAILURE;
        },
    }
    return ret;
}

fn activateFold(item: [*c]const c.GValue, ret: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const p = padOf(c.g_value_get_object(item));
    const active: *c.gboolean = @ptrCast(@alignCast(data));
    if (pad.gst_pad_set_active(p, active.*) == 0 and pad.parentOf(p) != null) {
        c.g_value_set_boolean(ret, 0);
        return 0;
    }
    return 1;
}

fn foldActivate(it: [*c]c.GstIterator, active: *c.gboolean) bool {
    var ret = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&ret, c.G_TYPE_BOOLEAN);
    c.g_value_set_boolean(&ret, 1);
    while (true) {
        switch (c.gst_iterator_fold(it, activateFold, &ret, active)) {
            c.GST_ITERATOR_RESYNC => {
                c.g_value_set_boolean(&ret, 1);
                c.gst_iterator_resync(it);
            },
            c.GST_ITERATOR_DONE => break,
            else => {
                c.g_value_set_boolean(&ret, 0);
                break;
            },
        }
    }
    return c.g_value_get_boolean(&ret) != 0;
}

fn padsActivate(e: [*c]Element, on: bool) bool {
    var active: c.gboolean = @intFromBool(on);
    var it = gst_element_iterate_src_pads(e);
    var ok = foldActivate(it, &active);
    c.gst_iterator_free(it);
    if (!ok) return false;
    it = gst_element_iterate_sink_pads(e);
    ok = foldActivate(it, &active);
    c.gst_iterator_free(it);
    return ok;
}

fn changeStateDefault(e: [*c]Element, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    if (!check.that(isElement(e), "gst_element_change_state_func", "GST_IS_ELEMENT (element)")) return c.GST_STATE_CHANGE_FAILURE;
    const state: c.GstState = @intCast(t >> 3);
    const next: c.GstState = @intCast(t & 0x7);
    if (next == c.GST_STATE_VOID_PENDING or state == next) {
        lock(e);
        defer unlock(e);
        return e[0].last_return;
    }
    var result: c.GstStateChangeReturn = c.GST_STATE_CHANGE_SUCCESS;
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY, c.GST_STATE_CHANGE_PAUSED_TO_PLAYING, c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => {},
        c.GST_STATE_CHANGE_READY_TO_PAUSED => if (!padsActivate(e, true)) {
            result = c.GST_STATE_CHANGE_FAILURE;
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY, c.GST_STATE_CHANGE_READY_TO_NULL => {
            if (!padsActivate(e, false)) result = c.GST_STATE_CHANGE_FAILURE;
            lock(e);
            var l = e[0].contexts;
            while (l != null) {
                const ctx: ?*c.GstContext = @ptrCast(l[0].data);
                const nxt = l[0].next;
                if (c.gst_context_is_persistent(ctx) == 0) {
                    c.gst_context_unref(ctx);
                    e[0].contexts = c.g_list_delete_link(e[0].contexts, l);
                }
                l = nxt;
            }
            unlock(e);
        },
        else => c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Unhandled state change from %s to %s", gst_state_get_name(state), gst_state_get_name(next)),
    }
    return result;
}

pub export fn gst_element_get_factory(e: [*c]Element) ?*c.GstElementFactory {
    if (!check.that(isElement(e), "gst_element_get_factory", "GST_IS_ELEMENT (element)")) return null;
    return classOf(e).elementfactory;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const e: [*c]Element = @ptrCast(@alignCast(o));
    const k = classOf(e);
    if (e[0].current_state != c.GST_STATE_NULL) {
        const locked = e[0].object.flags & c.GST_ELEMENT_FLAG_LOCKED_STATE != 0;
        c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "\nTrying to dispose element %s, but it is in %s%s instead of the NULL state.\nYou need to explicitly set elements to the NULL state before\ndropping the final reference, to allow them to clean up.\nThis problem may also be caused by a refcounting bug in the\napplication or some element.\n", e[0].object.name, gst_state_get_name(e[0].current_state), @as([*c]const u8, if (locked) " (locked)" else ""));
        return;
    }
    var walk = e[0].pads;
    while (walk != null) {
        const p = padOf(walk[0].data);
        walk = walk[0].next;
        if (k.release_pad != null and p[0].padtemplate != null and p[0].padtemplate[0].presence == c.GST_PAD_REQUEST) {
            k.release_pad.?(e, pad.h(p));
            if (walk != null and c.g_list_position(e[0].pads, walk) == -1) walk = e[0].pads;
        }
    }
    while (e[0].pads != null) {
        const p = padOf(e[0].pads[0].data);
        if (gst_element_remove_pad(e, p) == 0) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "failed to remove pad %s:%s", pad.parentName(p), pad.padName(p));
            break;
        }
    }
    lock(e);
    _ = object.gst_object_replace(@ptrCast(&e[0].clock), null);
    _ = object.gst_object_replace(@ptrCast(&e[0].bus), null);
    c.g_list_free_full(e[0].contexts, unrefContext);
    e[0].contexts = null;
    unlock(e);
    parent_class.?.dispose.?(o);
}

fn unrefContext(p: c.gpointer) callconv(.c) void {
    c.gst_context_unref(@ptrCast(p));
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const e: [*c]Element = @ptrCast(@alignCast(o));
    c.g_cond_clear(@ptrCast(&e[0].state_cond));
    c.g_rec_mutex_clear(@ptrCast(&e[0].state_lock));
    parent_class.?.finalize.?(o);
}

fn setBusDefault(e: [*c]Element, bus: [*c]c.GstBus) callconv(.c) void {
    if (!check.that(isElement(e), "gst_element_set_bus_func", "GST_IS_ELEMENT (element)")) return;
    lock(e);
    _ = object.gst_object_replace(@ptrCast(&e[0].bus), @ptrCast(bus));
    unlock(e);
}

pub export fn gst_element_set_bus(e: [*c]Element, bus: [*c]c.GstBus) void {
    if (!check.that(isElement(e), "gst_element_set_bus", "GST_IS_ELEMENT (element)")) return;
    if (classOf(e).set_bus) |f| f(e, bus);
}

pub export fn gst_element_get_bus(e: [*c]Element) [*c]c.GstBus {
    if (!check.that(isElement(e), "gst_element_get_bus", "GST_IS_ELEMENT (element)")) return null;
    lock(e);
    defer unlock(e);
    if (e[0].bus != null) _ = c.gst_object_ref(e[0].bus);
    return e[0].bus;
}

fn isContext(ctx: ?*c.GstContext) bool {
    return ctx != null and @as([*c]c.GstMiniObject, @ptrCast(@alignCast(ctx)))[0].type == c.gst_context_get_type();
}

fn setContextDefault(e: [*c]Element, ctx: ?*c.GstContext) callconv(.c) void {
    if (!check.that(isContext(ctx), "gst_element_set_context_default", "GST_IS_CONTEXT (context)")) return;
    const kind = c.gst_context_get_context_type(ctx);
    if (!check.that(kind != null, "gst_element_set_context_default", "context_type != NULL")) return;
    lock(e);
    defer unlock(e);
    var l = e[0].contexts;
    while (l != null) : (l = l[0].next) {
        const tmp: ?*c.GstContext = @ptrCast(l[0].data);
        if (c.g_strcmp0(kind, c.gst_context_get_context_type(tmp)) == 0 and (c.gst_context_is_persistent(ctx) != 0 or c.gst_context_is_persistent(tmp) == 0)) {
            _ = c.gst_context_replace(@ptrCast(&l[0].data), ctx);
            return;
        }
    }
    e[0].contexts = c.g_list_prepend(e[0].contexts, c.gst_context_ref(ctx));
}

pub export fn gst_element_set_context(e: [*c]Element, ctx: ?*c.GstContext) void {
    if (!check.that(isElement(e), "gst_element_set_context", "GST_IS_ELEMENT (element)")) return;
    if (!check.that(isContext(ctx), "gst_element_set_context", "GST_IS_CONTEXT (context)")) return;
    if (classOf(e).set_context) |f| f(e, ctx);
}

fn copyContext(src: c.gconstpointer, _: c.gpointer) callconv(.c) c.gpointer {
    return c.gst_context_ref(@ptrCast(@constCast(src)));
}

pub export fn gst_element_get_contexts(e: [*c]Element) [*c]c.GList {
    if (!check.that(isElement(e), "gst_element_get_contexts", "GST_IS_ELEMENT (element)")) return null;
    lock(e);
    defer unlock(e);
    return c.g_list_copy_deep(e[0].contexts, copyContext, null);
}

fn matchType(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    return c.g_strcmp0(c.gst_context_get_context_type(@ptrCast(@constCast(a))), @ptrCast(b));
}

pub export fn gst_element_get_context_unlocked(e: [*c]Element, kind: [*c]const u8) ?*c.GstContext {
    if (!check.that(isElement(e), "gst_element_get_context_unlocked", "GST_IS_ELEMENT (element)")) return null;
    const node = c.g_list_find_custom(e[0].contexts, kind, matchType);
    if (node == null or node[0].data == null) return null;
    return c.gst_context_ref(@ptrCast(node[0].data));
}

pub export fn gst_element_get_context(e: [*c]Element, kind: [*c]const u8) ?*c.GstContext {
    if (!check.that(isElement(e), "gst_element_get_context", "GST_IS_ELEMENT (element)")) return null;
    lock(e);
    defer unlock(e);
    return gst_element_get_context_unlocked(e, kind);
}

fn postNotify(e: [*c]Element, obj: [*c]c.GObject, pspec: [*c]c.GParamSpec, include: bool) void {
    var val = std.mem.zeroes(c.GValue);
    var v: [*c]c.GValue = null;
    if (include and pspec[0].flags & c.G_PARAM_READABLE != 0) {
        _ = c.g_value_init(&val, pspec[0].value_type);
        c.g_object_get_property(obj, pspec[0].name, &val);
        v = &val;
    }
    _ = gst_element_post_message(e, c.gst_message_new_property_notify(@ptrCast(obj), pspec[0].name, v));
}

fn deepNotify(e: [*c]Element, obj: [*c]c.GObject, pspec: [*c]c.GParamSpec, data: c.gpointer) callconv(.c) void {
    postNotify(e, obj, pspec, @intFromPtr(data) != 0);
}

fn notify(obj: [*c]c.GObject, pspec: [*c]c.GParamSpec, data: c.gpointer) callconv(.c) void {
    postNotify(@ptrCast(@alignCast(obj)), obj, pspec, @intFromPtr(data) != 0);
}

fn watch(comptime f: []const u8, e: [*c]Element, comptime signal: [:0]const u8, prop: [*c]const u8, include: c.gboolean, cb: c.GCallback) c.gulong {
    if (!check.that(isElement(e), f, "GST_IS_ELEMENT (element)")) return 0;
    const sep: [*c]const u8 = if (prop != null) "::" else null;
    const sig = c.g_strconcat(signal, sep, prop, @as([*c]const u8, null));
    defer c.g_free(sig);
    return c.g_signal_connect_data(e, sig, cb, @ptrFromInt(@as(usize, @intCast(include))), null, 0);
}

pub export fn gst_element_add_property_notify_watch(e: [*c]Element, prop: [*c]const u8, include: c.gboolean) c.gulong {
    return watch("gst_element_add_property_notify_watch", e, "notify", prop, include, @ptrCast(&notify));
}

pub export fn gst_element_add_property_deep_notify_watch(e: [*c]Element, prop: [*c]const u8, include: c.gboolean) c.gulong {
    return watch("gst_element_add_property_deep_notify_watch", e, "deep-notify", prop, include, @ptrCast(&deepNotify));
}

pub export fn gst_element_remove_property_notify_watch(e: [*c]Element, id: c.gulong) void {
    c.g_signal_handler_disconnect(e, id);
}

const AsyncCall = struct {
    object: [*c]Obj,
    func: c.GstCallAsyncFunc,
    data: c.gpointer,
    notify: c.GDestroyNotify,
};

var async_pool: ?*c.GThreadPool = null;
var async_lock: c.GMutex = std.mem.zeroes(c.GMutex);

fn runAsync(raw: c.gpointer, _: c.gpointer) callconv(.c) void {
    const d: *AsyncCall = @ptrCast(@alignCast(raw));
    if (d.object != null) {
        const f: c.GstObjectCallAsyncFunc = @ptrCast(d.func);
        f.?(d.object, d.data);
    } else d.func.?(d.data);
    if (d.notify) |n| n(d.data);
    if (d.object != null) c.gst_object_unref(d.object);
    std.heap.c_allocator.destroy(d);
}

pub fn callAsync(o: [*c]Obj, func: c.GstCallAsyncFunc, data: c.gpointer, notify_fn: c.GDestroyNotify) void {
    const d = std.heap.c_allocator.create(AsyncCall) catch return;
    d.* = .{ .object = if (o != null) @ptrCast(@alignCast(c.gst_object_ref(o))) else null, .func = func, .data = data, .notify = notify_fn };
    c.g_mutex_lock(&async_lock);
    defer c.g_mutex_unlock(&async_lock);
    if (async_pool == null) {
        var err: [*c]c.GError = null;
        async_pool = c.g_thread_pool_new(runAsync, null, -1, 0, &err);
        if (err != null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "could not alloc threadpool %s", err[0].message);
            c.g_error_free(err);
        }
    }
    _ = c.g_thread_pool_push(async_pool, d, null);
}

pub export fn gst_call_async(func: c.GstCallAsyncFunc, data: c.gpointer) void {
    callAsync(null, func, data, null);
}

pub export fn gst_object_call_async(o: [*c]Obj, func: c.GstObjectCallAsyncFunc, data: c.gpointer) void {
    if (!check.that(object.isObject(o), "gst_object_call_async", "GST_IS_OBJECT (object)")) return;
    if (!check.that(func != null, "gst_object_call_async", "func != NULL")) return;
    callAsync(o, @ptrCast(func), data, null);
}

pub export fn gst_element_call_async(e: [*c]Element, func: c.GstElementCallAsyncFunc, data: c.gpointer, destroy: c.GDestroyNotify) void {
    if (!check.that(isElement(e), "gst_element_call_async", "GST_IS_ELEMENT (element)")) return;
    callAsync(@ptrCast(e), @ptrCast(func), data, destroy);
}

pub export fn gst_make_element_message_details(first: [*c]const u8, ...) callconv(.c) [*c]c.GstStructure {
    if (first == null) return null;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return c.gst_structure_new_valist("details", first, va.toC(&ap));
}

pub export fn gst_state_get_name(s: c.GstState) [*c]const u8 {
    return switch (s) {
        c.GST_STATE_VOID_PENDING => "VOID_PENDING",
        c.GST_STATE_NULL => "NULL",
        c.GST_STATE_READY => "READY",
        c.GST_STATE_PLAYING => "PLAYING",
        c.GST_STATE_PAUSED => "PAUSED",
        else => c.g_strdup_printf("UNKNOWN!(%d)", s),
    };
}

pub export fn gst_state_change_return_get_name(r: c.GstStateChangeReturn) [*c]const u8 {
    return switch (r) {
        c.GST_STATE_CHANGE_FAILURE => "FAILURE",
        c.GST_STATE_CHANGE_SUCCESS => "SUCCESS",
        c.GST_STATE_CHANGE_ASYNC => "ASYNC",
        c.GST_STATE_CHANGE_NO_PREROLL => "NO PREROLL",
        else => c.g_strdup_printf("UNKNOWN!(%d)", r),
    };
}

pub export fn gst_state_change_get_name(t: c.GstStateChange) [*c]const u8 {
    return switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => "NULL->READY",
        c.GST_STATE_CHANGE_READY_TO_PAUSED => "READY->PAUSED",
        c.GST_STATE_CHANGE_PAUSED_TO_PLAYING => "PAUSED->PLAYING",
        c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => "PLAYING->PAUSED",
        c.GST_STATE_CHANGE_PAUSED_TO_READY => "PAUSED->READY",
        c.GST_STATE_CHANGE_READY_TO_NULL => "READY->NULL",
        c.GST_STATE_CHANGE_NULL_TO_NULL => "NULL->NULL",
        c.GST_STATE_CHANGE_READY_TO_READY => "READY->READY",
        c.GST_STATE_CHANGE_PAUSED_TO_PAUSED => "PAUSED->PAUSED",
        c.GST_STATE_CHANGE_PLAYING_TO_PLAYING => "PLAYING->PLAYING",
        else => "Unknown state return",
    };
}

pub export fn gst_element_state_get_name(s: c.GstState) [*c]const u8 {
    return gst_state_get_name(s);
}

pub export fn gst_element_state_change_return_get_name(r: c.GstStateChangeReturn) [*c]const u8 {
    return gst_state_change_return_get_name(r);
}

pub export fn gst_object_default_error(src: [*c]Obj, err: [*c]const c.GError, debug: [*c]const u8) void {
    const path = c.gst_object_get_path_string(src);
    c.g_printerr("ERROR: from element %s: %s\n", path, err[0].message);
    if (debug != null) c.g_printerr("Additional debug info:\n%s\n", debug);
    c.g_free(path);
}
