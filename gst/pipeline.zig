const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const info = @import("info.zig");
const element = @import("element.zig");
const bin = @import("bin.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Pipeline = c.GstPipeline;
const Element = c.GstElement;
const NONE: u64 = std.math.maxInt(u64);

const Private = extern struct {
    auto_flush_bus: c.gboolean,
    is_live: c.gboolean,
    min_latency: c.GstClockTime,
    last_start_time: c.GstClockTime,
    update_clock: c.gboolean,
    latency: c.GstClockTime,
    instant_seqnum: c.guint32,
    instant_rate: c.gdouble,
    upstream_anchor: c.GstClockTime,
    clock_anchor: c.GstClockTime,
};

const PROP_DELAY = 1;
const PROP_AUTO_FLUSH_BUS = 2;
const PROP_LATENCY = 3;

var private_offset: c.gint = 0;
var parent_class: ?*c.GstBinClass = null;
var type_once: gtype.Once = .{};
var debug_cat: [*c]c.GstDebugCategory = null;

fn priv(p: anytype) *Private {
    const base: [*]u8 = @ptrCast(@constCast(p));
    return @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, private_offset)))));
}

fn isPipeline(p: anytype) bool {
    return gtype.instanceOf(p, gst_pipeline_get_type());
}

fn el(p: anytype) [*c]Element {
    return @ptrCast(@alignCast(p));
}

fn lock(p: anytype) void {
    object.lock(p);
}

fn unlock(p: anytype) void {
    object.unlock(p);
}

fn parentElement() *c.GstElementClass {
    return @ptrCast(parent_class.?);
}

pub export fn gst_pipeline_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(bin.gst_bin_get_type(), "GstPipeline", c.GstPipelineClass, Pipeline, classInit, instanceInit, 0);
            private_offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            debug_cat = info._gst_debug_category_new("pipeline", c.GST_DEBUG_BOLD, "debugging info for the 'pipeline' container element");
            return t;
        }
    }.f);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &private_offset);
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    const fl = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, PROP_DELAY, c.g_param_spec_uint64("delay", "Delay", "Expected delay needed for elements to spin up to PLAYING in nanoseconds", 0, NONE, 0, fl));
    c.g_object_class_install_property(gc, PROP_AUTO_FLUSH_BUS, c.g_param_spec_boolean("auto-flush-bus", "Auto Flush Bus", "Whether to automatically flush the pipeline's bus when going from READY into NULL state", 1, fl));
    c.g_object_class_install_property(gc, PROP_LATENCY, c.g_param_spec_uint64("latency", "Latency", "Latency to configure on the pipeline", 0, NONE, NONE, fl));
    gc.dispose = dispose;
    const ek: [*c]c.GstElementClass = @ptrCast(@alignCast(klass));
    element.gst_element_class_set_static_metadata(ek, "Pipeline object", "Generic/Bin", "Complete pipeline object", "Erik Walthinsen <omega@cse.ogi.edu>, Wim Taymans <wim@fluendo.com>");
    ek[0].change_state = changeState;
    ek[0].provide_clock = provideClock;
    const bk: *c.GstBinClass = @ptrCast(@alignCast(klass));
    bk.handle_message = handleMessage;
    bk.do_latency = doLatency;
    info._gst_debug_register_funcptr(@ptrCast(&changeState), "gst_pipeline_change_state");
    info._gst_debug_register_funcptr(@ptrCast(&provideClock), "gst_pipeline_provide_clock_func");
    info._gst_debug_register_funcptr(@ptrCast(&handleMessage), "gst_pipeline_handle_message");
    info._gst_debug_register_funcptr(@ptrCast(&doLatency), "gst_pipeline_do_latency");
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: [*c]Pipeline = @ptrCast(@alignCast(instance));
    const d = priv(p);
    p[0].priv = @ptrCast(d);
    d.auto_flush_bus = 1;
    p[0].delay = 0;
    d.latency = NONE;
    d.is_live = 0;
    d.min_latency = NONE;
    const bus = c.gst_bus_new();
    element.gst_element_set_bus(el(p), bus);
    c.gst_object_unref(bus);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const p: [*c]Pipeline = @ptrCast(@alignCast(o));
    _ = object.gst_object_replace(@ptrCast(&p[0].fixed_clock), null);
    @as(*c.GObjectClass, @ptrCast(parent_class.?)).dispose.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const p: [*c]Pipeline = @ptrCast(@alignCast(o));
    switch (id) {
        PROP_DELAY => gst_pipeline_set_delay(p, c.g_value_get_uint64(v)),
        PROP_AUTO_FLUSH_BUS => gst_pipeline_set_auto_flush_bus(p, c.g_value_get_boolean(v)),
        PROP_LATENCY => gst_pipeline_set_latency(p, c.g_value_get_uint64(v)),
        else => object.warnBadProperty(o, id, pspec),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const p: [*c]Pipeline = @ptrCast(@alignCast(o));
    switch (id) {
        PROP_DELAY => c.g_value_set_uint64(v, gst_pipeline_get_delay(p)),
        PROP_AUTO_FLUSH_BUS => c.g_value_set_boolean(v, gst_pipeline_get_auto_flush_bus(p)),
        PROP_LATENCY => c.g_value_set_uint64(v, gst_pipeline_get_latency(p)),
        else => object.warnBadProperty(o, id, pspec),
    }
}

fn resetStart(p: [*c]Pipeline, t: c.GstClockTime) void {
    lock(p);
    defer unlock(p);
    if (el(p)[0].start_time == NONE) return;
    el(p)[0].start_time = t;
    const d = priv(p);
    d.last_start_time = NONE;
    d.instant_seqnum = c.GST_SEQNUM_INVALID;
    d.upstream_anchor = NONE;
    d.clock_anchor = NONE;
    d.instant_rate = 1.0;
}

pub export fn gst_pipeline_new(name: [*c]const u8) [*c]Element {
    const make = gtype.lookup(?*const fn ([*c]const u8, [*c]const u8) callconv(.c) [*c]Element, "gst_element_factory_make");
    if (make) |f| {
        const r = f("pipeline", name);
        if (r != null) return r;
    }
    return @ptrCast(@alignCast(c.g_object_new(gst_pipeline_get_type(), "name", name, @as([*c]const u8, null))));
}

fn updateStart(e: [*c]Element) void {
    const p: [*c]Pipeline = @ptrCast(@alignCast(e));
    lock(e);
    defer unlock(e);
    const clock = e[0].clock;
    if (clock == null) return;
    _ = c.gst_object_ref(clock);
    unlock(e);
    const now = c.gst_clock_get_time(clock);
    c.gst_object_unref(clock);
    lock(e);
    if (e[0].start_time == NONE) return;
    if (now != NONE) e[0].start_time = now -% @as(u64, @bitCast(e[0].base_time));
    priv(p).update_clock = 1;
}

fn changeState(e: [*c]Element, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const p: [*c]Pipeline = @ptrCast(@alignCast(e));
    const d = priv(p);
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => {
            lock(e);
            if (e[0].bus != null) c.gst_bus_set_flushing(e[0].bus, 0);
            unlock(e);
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            lock(e);
            d.update_clock = 1;
            unlock(e);
            resetStart(p, 0);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_PLAYING => {
            lock(e);
            var cur = e[0].clock;
            if (cur != null) _ = c.gst_object_ref(cur);
            const start = e[0].start_time;
            const last = d.last_start_time;
            d.last_start_time = start;
            const update = d.update_clock != 0;
            d.update_clock = 0;
            const delay = p[0].delay;
            unlock(e);
            if (object.of(e).parent == null and (update or last != start)) {
                var clock: [*c]c.GstClock = null;
                if (update) {
                    clock = element.gst_element_provide_clock(e);
                } else if (cur != null) clock = @ptrCast(@alignCast(c.gst_object_ref(cur)));
                const now = if (clock != null) c.gst_clock_get_time(clock) else NONE;
                if (clock != cur) {
                    if (element.gst_element_set_clock(e, clock) == 0) {
                        element.gst_element_message_full(e, c.GST_MESSAGE_ERROR, c.gst_core_error_quark(), c.GST_CORE_ERROR_CLOCK, c.g_strdup("Selected clock cannot be used in pipeline."), c.g_strdup("Pipeline cannot operate with selected clock"), "../gst/gstpipeline.c", "gst_pipeline_change_state", 483);
                        if (clock != null) c.gst_object_unref(clock);
                        if (cur != null) c.gst_object_unref(cur);
                        return c.GST_STATE_CHANGE_FAILURE;
                    }
                    _ = element.gst_element_post_message(e, c.gst_message_new_new_clock(@ptrCast(e), clock));
                }
                if (clock != null) c.gst_object_unref(clock);
                if (start != NONE and now != NONE) element.gst_element_set_base_time(e, now -% start +% delay);
            }
            if (cur != null) c.gst_object_unref(cur);
            cur = null;
        },
        c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => updateStart(e),
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            lock(e);
            d.is_live = 0;
            d.min_latency = NONE;
            unlock(e);
            resetStart(p, 0);
        },
        else => {},
    }
    const result = parentElement().change_state.?(e, t);
    if (t & 0x7 == c.GST_STATE_PAUSED) {
        lock(e);
        d.is_live = @intFromBool(result == c.GST_STATE_CHANGE_NO_PREROLL);
        unlock(e);
    }
    switch (t) {
        c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => updateStart(e),
        c.GST_STATE_CHANGE_READY_TO_NULL => {
            lock(e);
            const bus = e[0].bus;
            if (bus != null) _ = c.gst_object_ref(bus);
            const flush = d.auto_flush_bus != 0;
            unlock(e);
            if (bus != null) {
                if (flush) c.gst_bus_set_flushing(bus, 1);
                c.gst_object_unref(bus);
            }
        },
        else => {},
    }
    return result;
}

fn handleMessage(b: [*c]c.GstBin, m: [*c]c.GstMessage) callconv(.c) void {
    const p: [*c]Pipeline = @ptrCast(@alignCast(b));
    switch (m[0].type) {
        c.GST_MESSAGE_RESET_TIME => {
            var running: c.GstClockTime = 0;
            c.gst_message_parse_reset_time(m, &running);
            resetStart(p, running);
            lock(p);
            const live = priv(p).is_live != 0;
            unlock(p);
            if (live and el(p)[0].target_state == c.GST_STATE_PLAYING) _ = changeState(el(p), c.GST_STATE_CHANGE_PAUSED_TO_PLAYING);
        },
        c.GST_MESSAGE_CLOCK_LOST => {
            var clock: [*c]c.GstClock = null;
            c.gst_message_parse_clock_lost(m, &clock);
            lock(b);
            if (clock == el(b)[0].clock) priv(p).update_clock = 1;
            unlock(b);
        },
        c.GST_MESSAGE_INSTANT_RATE_REQUEST => {
            const seqnum = c.gst_message_get_seqnum(m);
            var rate: f64 = 0;
            c.gst_message_parse_instant_rate_request(m, &rate);
            _ = instantRate(p, rate, seqnum);
        },
        else => {},
    }
    parent_class.?.handle_message.?(b, m);
}

fn timeParts(t: u64) struct { c.guint, c.guint, c.guint, c.guint } {
    if (t == NONE) return .{ 99, 99, 99, 999999999 };
    const s: u64 = 1000000000;
    return .{ @intCast(t / (s * 3600)), @intCast((t / (s * 60)) % 60), @intCast((t / s) % 60), @intCast(t % s) };
}

fn warn(e: [*c]Element, line: c.gint, comptime fmt: [:0]const u8, a: u64, b: u64) void {
    const x = timeParts(a);
    const y = timeParts(b);
    const dbg = c.g_strdup_printf(fmt, x[0], x[1], x[2], x[3], y[0], y[1], y[2], y[3]);
    element.gst_element_message_full(e, c.GST_MESSAGE_WARNING, c.gst_core_error_quark(), c.GST_CORE_ERROR_CLOCK, null, dbg, "../gst/gstpipeline.c", "gst_pipeline_do_latency", line);
}

fn doLatency(b: [*c]c.GstBin) callconv(.c) c.gboolean {
    const p: [*c]Pipeline = @ptrCast(@alignCast(b));
    const e = el(p);
    lock(p);
    var latency = priv(p).latency;
    unlock(p);
    const q = c.gst_query_new_latency();
    var res = element.gst_element_query(e, q);
    if (res != 0) {
        var live: c.gboolean = 0;
        var min: u64 = 0;
        var max: u64 = 0;
        c.gst_query_parse_latency(q, &live, &min, &max);
        if (max < min) warn(e, 703, "Impossible to configure latency: max %u:%02u:%02u.%09u < min %u:%02u:%02u.%09u. Add queues or other buffering elements.", max, min);
        if (latency == NONE) {
            latency = min;
        } else {
            if (latency < min) warn(e, 716, "Configured latency is lower than detected minimum latency: configured %u:%02u:%02u.%09u < min %u:%02u:%02u.%09u", latency, min);
            if (max < latency) warn(e, 724, "Impossible to configure latency: max %u:%02u:%02u.%09u < configured %u:%02u:%02u.%09u. Add queues or other buffering elements.", max, latency);
        }
    }
    c.gst_query_unref(q);
    if (latency != NONE) {
        lock(p);
        priv(p).min_latency = latency;
        unlock(p);
        res = element.gst_element_send_event(e, c.gst_event_new_latency(latency));
    }
    return res;
}

pub export fn gst_pipeline_get_bus(p: [*c]Pipeline) [*c]c.GstBus {
    return element.gst_element_get_bus(el(p));
}

fn provideClock(e: [*c]Element) callconv(.c) [*c]c.GstClock {
    const p: [*c]Pipeline = @ptrCast(@alignCast(e));
    lock(p);
    if (object.of(p).flags & c.GST_PIPELINE_FLAG_FIXED_CLOCK != 0) {
        const clock = p[0].fixed_clock;
        if (clock != null) _ = c.gst_object_ref(clock);
        unlock(p);
        return clock;
    }
    unlock(p);
    const clock = parentElement().provide_clock.?(e);
    return if (clock != null) clock else c.gst_system_clock_obtain();
}

pub export fn gst_pipeline_get_clock(p: [*c]Pipeline) [*c]c.GstClock {
    return gst_pipeline_get_pipeline_clock(p);
}

pub export fn gst_pipeline_get_pipeline_clock(p: [*c]Pipeline) [*c]c.GstClock {
    if (!check.that(isPipeline(p), "gst_pipeline_get_pipeline_clock", "GST_IS_PIPELINE (pipeline)")) return null;
    return provideClock(el(p));
}

pub export fn gst_pipeline_use_clock(p: [*c]Pipeline, clock: [*c]c.GstClock) void {
    if (!check.that(isPipeline(p), "gst_pipeline_use_clock", "GST_IS_PIPELINE (pipeline)")) return;
    lock(p);
    defer unlock(p);
    object.of(p).flags |= c.GST_PIPELINE_FLAG_FIXED_CLOCK;
    _ = object.gst_object_replace(@ptrCast(&p[0].fixed_clock), @ptrCast(clock));
}

pub export fn gst_pipeline_set_clock(p: [*c]Pipeline, clock: [*c]c.GstClock) c.gboolean {
    if (!check.that(p != null, "gst_pipeline_set_clock", "pipeline != NULL")) return 0;
    if (!check.that(isPipeline(p), "gst_pipeline_set_clock", "GST_IS_PIPELINE (pipeline)")) return 0;
    return parentElement().set_clock.?(el(p), clock);
}

pub export fn gst_pipeline_auto_clock(p: [*c]Pipeline) void {
    if (!check.that(p != null, "gst_pipeline_auto_clock", "pipeline != NULL")) return;
    if (!check.that(isPipeline(p), "gst_pipeline_auto_clock", "GST_IS_PIPELINE (pipeline)")) return;
    lock(p);
    defer unlock(p);
    object.of(p).flags &= ~@as(c.guint32, c.GST_PIPELINE_FLAG_FIXED_CLOCK);
    _ = object.gst_object_replace(@ptrCast(&p[0].fixed_clock), null);
}

pub export fn gst_pipeline_set_delay(p: [*c]Pipeline, delay: c.GstClockTime) void {
    if (!check.that(isPipeline(p), "gst_pipeline_set_delay", "GST_IS_PIPELINE (pipeline)")) return;
    if (!check.that(delay != NONE, "gst_pipeline_set_delay", "delay != GST_CLOCK_TIME_NONE")) return;
    lock(p);
    p[0].delay = delay;
    unlock(p);
}

pub export fn gst_pipeline_get_delay(p: [*c]Pipeline) c.GstClockTime {
    if (!check.that(isPipeline(p), "gst_pipeline_get_delay", "GST_IS_PIPELINE (pipeline)")) return NONE;
    lock(p);
    defer unlock(p);
    return p[0].delay;
}

pub export fn gst_pipeline_set_auto_flush_bus(p: [*c]Pipeline, on: c.gboolean) void {
    if (!check.that(isPipeline(p), "gst_pipeline_set_auto_flush_bus", "GST_IS_PIPELINE (pipeline)")) return;
    lock(p);
    priv(p).auto_flush_bus = on;
    unlock(p);
}

pub export fn gst_pipeline_get_auto_flush_bus(p: [*c]Pipeline) c.gboolean {
    if (!check.that(isPipeline(p), "gst_pipeline_get_auto_flush_bus", "GST_IS_PIPELINE (pipeline)")) return 0;
    lock(p);
    defer unlock(p);
    return priv(p).auto_flush_bus;
}

pub export fn gst_pipeline_set_latency(p: [*c]Pipeline, latency: c.GstClockTime) void {
    if (!check.that(isPipeline(p), "gst_pipeline_set_latency", "GST_IS_PIPELINE (pipeline)")) return;
    lock(p);
    const changed = priv(p).latency != latency;
    priv(p).latency = latency;
    unlock(p);
    if (changed) _ = bin.gst_bin_recalculate_latency(@ptrCast(p));
}

pub export fn gst_pipeline_get_latency(p: [*c]Pipeline) c.GstClockTime {
    if (!check.that(isPipeline(p), "gst_pipeline_get_latency", "GST_IS_PIPELINE (pipeline)")) return NONE;
    lock(p);
    defer unlock(p);
    return priv(p).latency;
}

fn instantRate(p: [*c]Pipeline, rate_in: f64, seqnum: c.guint32) bool {
    var rate = rate_in;
    var running: u64 = NONE;
    var upstream: u64 = NONE;
    const d = priv(p);
    const e = el(p);
    lock(p);
    if (d.instant_seqnum != c.GST_SEQNUM_INVALID and d.instant_seqnum == seqnum) {
        upstream = d.upstream_anchor;
        running = d.clock_anchor;
        if (rate != d.instant_rate) rate = d.instant_rate;
    } else {
        const playing = e[0].current_state == c.GST_STATE_PLAYING and (e[0].pending_state == c.GST_STATE_VOID_PENDING or e[0].pending_state == c.GST_STATE_PLAYING);
        if (playing) {
            if (e[0].clock != null) running = c.gst_clock_get_time(e[0].clock) -% @as(u64, @bitCast(e[0].base_time));
        } else running = e[0].start_time;
        if (running == NONE) {
            unlock(p);
            return false;
        }
        if (d.upstream_anchor != NONE) {
            const elapsed = running -% d.clock_anchor;
            d.upstream_anchor +%= @intFromFloat(@as(f64, @floatFromInt(elapsed)) * d.instant_rate);
            d.clock_anchor = running;
        } else {
            d.upstream_anchor = running;
            d.clock_anchor = running;
        }
        upstream = d.upstream_anchor;
        d.instant_seqnum = seqnum;
        d.instant_rate = rate;
    }
    unlock(p);
    const ev = c.gst_event_new_instant_rate_sync_time(rate, running, upstream);
    c.gst_event_set_seqnum(ev, seqnum);
    return element.gst_element_send_event(e, ev) != 0;
}

pub export fn gst_pipeline_is_live(p: [*c]Pipeline) c.gboolean {
    lock(p);
    defer unlock(p);
    return priv(p).is_live;
}

pub export fn gst_pipeline_get_configured_latency(p: [*c]Pipeline) c.GstClockTime {
    lock(p);
    defer unlock(p);
    return priv(p).min_latency;
}
