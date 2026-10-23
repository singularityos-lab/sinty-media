const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const x = @import("x.zig");
const X = x.p;
const ctxm = @import("context.zig");
const xa = @import("alloc.zig");
const Ctx = ctxm.Ctx;
const Win = ctxm.Win;

const FILE = "../sys/xvimage/xvimagesink.c";
const CAPS = "video/x-raw, framerate = (fraction) [ 0, MAX ], width = (int) [ 1, MAX ], height = (int) [ 1, MAX ]";

const Prop = enum(c.guint) { contrast = 1, brightness, hue, saturation, display, synchronous, pixel_aspect_ratio, force_aspect_ratio, handle_events, device, device_name, handle_expose, double_buffer, autopaint_colorkey, colorkey, draw_borders, window_width, window_height, last };

const Self = extern struct {
    video_sink: c.GstVideoSink,
    context: ?*Ctx,
    allocator: ?*xa.Allocator,
    config: ctxm.Config,
    xwindow: ?*Win,
    cur_image: [*c]c.GstBuffer,
    event_thread: ?*c.GThread,
    running: c.gboolean,
    info: c.GstVideoInfo,
    fps_n: c.gint,
    fps_d: c.gint,
    video_width: c.gint,
    video_height: c.gint,
    flow_lock: c.GMutex,
    par: [*c]c.GValue,
    pool: [*c]c.GstBufferPool,
    synchronous: c.gboolean,
    double_buffer: c.gboolean,
    keep_aspect: c.gboolean,
    redraw_border: c.gboolean,
    handle_events: c.gboolean,
    handle_expose: c.gboolean,
    draw_borders: c.gboolean,
    media_title: [*c]u8,
    render_rect: c.GstVideoRectangle,
    pending_render_rect: c.gboolean,
};

const Class = extern struct {
    parent: c.GstVideoSinkClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, CAPS);
var once: cm.Once = .{};
var parent_el: *c.GstElementClass = undefined;
var parent_bs: *c.GstBaseSinkClass = undefined;
var parent_obj: *c.GObjectClass = undefined;
var cat: ?*c.GstDebugCategory = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn flock(s: *Self) void {
    c.g_mutex_lock(&s.flow_lock);
}

fn funlock(s: *Self) void {
    c.g_mutex_unlock(&s.flow_lock);
}

fn clock(s: *Self) void {
    c.g_mutex_lock(&s.context.?.lock);
}

fn cunlock(s: *Self) void {
    c.g_mutex_unlock(&s.context.?.lock);
}

fn sinkpad(s: *Self) ?*c.GstPad {
    return s.video_sink.element.sinkpad;
}

fn target(s: *Self, w: *Win) c.GstVideoRectangle {
    if (s.keep_aspect == 0) return w.render_rect;
    const src = c.GstVideoRectangle{ .x = 0, .y = 0, .w = s.video_sink.width, .h = s.video_sink.height };
    const dst = c.GstVideoRectangle{ .x = 0, .y = 0, .w = w.render_rect.w, .h = w.render_rect.h };
    var r: c.GstVideoRectangle = undefined;
    c.gst_video_center_rect(&src, &dst, &r, 1);
    r.x += w.render_rect.x;
    r.y += w.render_rect.y;
    return r;
}

fn put(s: *Self, image: [*c]c.GstBuffer) bool {
    flock(s);
    defer funlock(s);
    const w = s.xwindow orelse return false;
    var border = false;
    if (s.cur_image == null or s.redraw_border != 0) {
        border = s.draw_borders != 0;
        s.redraw_border = 0;
    }
    var img = image;
    if (img != null and s.cur_image != img) {
        if (s.cur_image != null) c.gst_buffer_unref(s.cur_image);
        s.cur_image = c.gst_buffer_ref(img);
    }
    if (img == null) {
        if (s.cur_image == null) return true;
        border = true;
        img = s.cur_image;
    }
    const m: *xa.Memory = @ptrCast(@alignCast(c.gst_buffer_peek_memory(img, 0)));
    var src = m.crop;
    const meta = c.gst_buffer_get_meta(img, c.gst_video_crop_meta_api_get_type());
    if (meta != null) {
        const crop: *c.GstVideoCropMeta = @ptrCast(@alignCast(meta));
        src = .{ .x = @as(c.gint, @intCast(crop.x)) + m.crop.x, .y = @as(c.gint, @intCast(crop.y)) + m.crop.y, .w = @intCast(crop.width), .h = @intCast(crop.height) };
    }
    const r = target(s, w);
    xa.render(m, &src, w, &r, border);
    return true;
}

fn setTitle(s: *Self, win: ?*Win, title_in: [*c]const u8) void {
    if (title_in != null) {
        c.g_free(s.media_title);
        s.media_title = c.g_strdup(title_in);
    }
    const w = win orelse return;
    const app = c.g_get_application_name();
    var owned: [*c]u8 = null;
    var title: [*c]const u8 = null;
    if (app != null and s.media_title != null) {
        owned = c.g_strconcat(s.media_title, " : ", app, @as(?*anyopaque, null));
        title = owned;
    } else if (app != null) {
        title = app;
    } else if (s.media_title != null) title = s.media_title;
    ctxm.setTitle(w, title);
    c.g_free(owned);
}

fn winNew(s: *Self, width: c.gint, height: c.gint) *Win {
    const w = ctxm.createWindow(s.context.?, width, height);
    setTitle(s, w, null);
    ctxm.setEventHandling(w, s.handle_events);
    c.gst_video_overlay_got_window_handle(@ptrCast(s), w.win);
    return w;
}

fn updateGeometry(s: *Self) void {
    flock(s);
    if (s.xwindow) |w| ctxm.updateGeometry(w);
    funlock(s);
}

fn updateColorbalance(s: *Self) void {
    const ctx = s.context orelse return;
    ctxm.updateColorbalance(ctx, &s.config);
}

fn nav(s: *Self, e: ?*c.GstEvent) void {
    c.gst_navigation_send_event_simple(@ptrCast(s), e);
}

fn mods(state: c_uint) c.GstNavigationModifierType {
    return state & c.GST_NAVIGATION_MODIFIER_MASK;
}

fn touchEvent(s: *Self, e: *X.XEvent, open: *bool, state: *c.GstNavigationModifierType) void {
    const cookie = &e.xcookie;
    const w = s.xwindow.?;
    if (cookie.evtype == X.XI_HierarchyChanged) {
        ctxm.selectTouch(s.context.?, w);
        return;
    }
    if (cookie.evtype != X.XI_TouchBegin and cookie.evtype != X.XI_TouchUpdate and cookie.evtype != X.XI_TouchEnd) return;
    const t: *X.XIDeviceEvent = @ptrCast(@alignCast(cookie.data));
    const id: c.guint = (@as(c.guint, @bitCast(t.deviceid)) << 16) | (@as(c.guint, @bitCast(t.detail)) & 0xff);
    const list: [*]ctxm.Touch = @ptrCast(@alignCast(w.touch_devices[0].data));
    var dev: ?*ctxm.Touch = null;
    for (0..w.touch_devices[0].len) |i| {
        if (list[i].id == t.deviceid) {
            dev = &list[i];
            break;
        }
    }
    const d = dev orelse return;
    var pressure: f64 = std.math.nan(f64);
    if (d.pressure_valuator >= 0) {
        pressure = (t.valuators.values[@intCast(d.pressure_valuator)] - d.pressure_min) / (d.pressure_max - d.pressure_min);
        if (d.abs_pressure == 0) pressure += d.current_pressure;
    }
    d.current_pressure = pressure;
    cunlock(s);
    funlock(s);
    state.* = @bitCast(t.mods.effective);
    if (t.time != w.last_touch and open.* and t.time >= w.last_touch) nav(s, c.gst_navigation_event_new_touch_frame(state.*));
    const ev = switch (cookie.evtype) {
        X.XI_TouchBegin => c.gst_navigation_event_new_touch_down(id, t.event_x, t.event_y, pressure, state.*),
        X.XI_TouchEnd => c.gst_navigation_event_new_touch_up(id, t.event_x, t.event_y, state.*),
        else => c.gst_navigation_event_new_touch_motion(id, t.event_x, t.event_y, pressure, state.*),
    };
    nav(s, ev);
    w.last_touch = t.time;
    open.* = true;
    flock(s);
    clock(s);
}

fn handleEvents(s: *Self) void {
    var e: X.XEvent = undefined;
    var px: c_int = 0;
    var py: c_int = 0;
    var pstate: c_uint = 0;
    var moved = false;
    var exposed = false;
    var configured = false;
    var open = false;
    var state: c.GstNavigationModifierType = c.GST_NAVIGATION_MODIFIER_NONE;
    flock(s);
    clock(s);
    const ctx = s.context.?;
    const d = ctx.disp;
    if (s.xwindow == null) {
        cunlock(s);
        funlock(s);
        return;
    }
    while (s.xwindow != null and X.XCheckWindowEvent(d, s.xwindow.?.win, X.PointerMotionMask, &e) != 0) {
        if (e.type == X.MotionNotify) {
            px = e.xmotion.x;
            py = e.xmotion.y;
            pstate = e.xmotion.state;
            moved = true;
        }
    }
    if (moved) {
        cunlock(s);
        funlock(s);
        nav(s, c.gst_navigation_event_new_mouse_move(@floatFromInt(px), @floatFromInt(py), mods(pstate)));
        flock(s);
        clock(s);
    }
    while (s.xwindow != null and X.XCheckWindowEvent(d, s.xwindow.?.win, X.KeyPressMask | X.KeyReleaseMask | X.ButtonPressMask | X.ButtonReleaseMask, &e) != 0) {
        cunlock(s);
        funlock(s);
        switch (e.type) {
            X.ButtonPress => nav(s, c.gst_navigation_event_new_mouse_button_press(@intCast(e.xbutton.button), @floatFromInt(e.xbutton.x), @floatFromInt(e.xbutton.y), mods(e.xbutton.state))),
            X.ButtonRelease => nav(s, c.gst_navigation_event_new_mouse_button_release(@intCast(e.xbutton.button), @floatFromInt(e.xbutton.x), @floatFromInt(e.xbutton.y), mods(e.xbutton.state))),
            X.KeyPress, X.KeyRelease => {
                clock(s);
                const sym = if (ctx.use_xkb != 0) X.XkbKeycodeToKeysym(d, @intCast(e.xkey.keycode), 0, 0) else X.XKeycodeToKeysym(d, @intCast(e.xkey.keycode), 0);
                const key: [*c]const u8 = if (sym != X.NoSymbol) X.XKeysymToString(sym) else "unknown";
                cunlock(s);
                nav(s, if (e.type == X.KeyPress) c.gst_navigation_event_new_key_press(key, mods(e.xkey.state)) else c.gst_navigation_event_new_key_release(key, mods(e.xkey.state)));
            },
            else => {},
        }
        flock(s);
        clock(s);
    }
    while (s.xwindow != null and X.XCheckWindowEvent(d, s.xwindow.?.win, X.ExposureMask | X.StructureNotifyMask, &e) != 0) {
        switch (e.type) {
            X.Expose => exposed = true,
            X.ConfigureNotify => {
                cunlock(s);
                funlock(s);
                updateGeometry(s);
                flock(s);
                clock(s);
                configured = true;
            },
            else => {},
        }
    }
    if (s.handle_expose != 0 and (exposed or configured)) {
        cunlock(s);
        funlock(s);
        expose(@ptrCast(s));
        flock(s);
        clock(s);
    }
    while (X.XPending(d) != 0) {
        _ = X.XNextEvent(d, &e);
        if (e.type == X.ClientMessage) {
            const del = X.XInternAtom(d, "WM_DELETE_WINDOW", 1);
            if (del != X.None and del == @as(X.Atom, @bitCast(e.xclient.data.l[0]))) {
                cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("Output window was closed"), null, FILE, "gst_xv_image_sink_handle_xevents", 586);
                cunlock(s);
                if (s.xwindow) |w| ctxm.destroyWindow(w);
                s.xwindow = null;
                clock(s);
            }
        } else if (ctx.use_xi2 != 0 and X.XGetEventData(d, &e.xcookie) != 0) {
            if (e.xcookie.extension == ctx.xi_opcode and s.xwindow != null) touchEvent(s, &e, &open, &state);
            X.XFreeEventData(d, &e.xcookie);
        }
    }
    cunlock(s);
    funlock(s);
    if (open) nav(s, c.gst_navigation_event_new_touch_frame(state));
}

fn eventThread(data: c.gpointer) callconv(.c) c.gpointer {
    const s = me(data);
    cm.lock(s);
    while (s.running != 0) {
        cm.unlock(s);
        if (s.xwindow != null) handleEvents(s);
        c.g_usleep(c.G_USEC_PER_SEC / 20);
        cm.lock(s);
    }
    cm.unlock(s);
    return null;
}

fn manageThread(s: *Self) void {
    if (s.context == null) return;
    var t: ?*c.GThread = null;
    cm.lock(s);
    if (s.handle_expose != 0 or s.handle_events != 0) {
        if (s.event_thread == null) {
            s.running = 1;
            s.event_thread = c.g_thread_try_new("xvimagesink-events", eventThread, s, null);
        }
    } else if (s.event_thread != null) {
        s.running = 0;
        t = s.event_thread;
        s.event_thread = null;
    }
    cm.unlock(s);
    if (t != null) _ = c.g_thread_join(t);
}

fn getCaps(bs: [*c]c.GstBaseSink, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(bs);
    if (s.context) |ctx| {
        if (filter != null) return c.gst_caps_intersect_full(filter, ctx.caps, c.GST_CAPS_INTERSECT_FIRST);
        return c.gst_caps_ref(ctx.caps);
    }
    const caps = c.gst_pad_get_pad_template_caps(sinkpad(s));
    if (filter == null) return caps;
    const r = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(caps);
    return r;
}

fn createPool(s: *Self, caps: [*c]c.GstCaps, size: usize, min: c.guint) ?*c.GstBufferPool {
    const p = xa.newPool(s.allocator.?);
    const config = c.gst_buffer_pool_get_config(p);
    c.gst_buffer_pool_config_set_params(config, caps, @intCast(size), min, 0);
    if (c.gst_buffer_pool_set_config(p, config) == 0) {
        c.gst_debug_log(cat, c.GST_LEVEL_ERROR, FILE, "gst_xv_image_sink_create_pool", 841, @ptrCast(s), "failed to set config.");
        c.gst_object_unref(p);
        return null;
    }
    return p;
}

fn setCaps(bs: [*c]c.GstBaseSink, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(bs);
    const ctx = s.context.?;
    if (c.gst_caps_can_intersect(ctx.caps, caps) == 0) return 0;
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) == 0) return 0;
    s.fps_n = info.fps_n;
    s.fps_d = info.fps_d;
    s.video_width = info.width;
    s.video_height = info.height;
    if (ctxm.formatFromInfo(ctx, &info) == -1) return 0;
    ctxm.setColorimetry(ctx, &info.colorimetry);
    var dn: c.gint = 1;
    var dd: c.gint = 1;
    if (s.par != null) {
        dn = c.gst_value_get_fraction_numerator(s.par);
        dd = c.gst_value_get_fraction_denominator(s.par);
    }
    var num: c.guint = 0;
    var den: c.guint = 0;
    if (c.gst_video_calculate_display_ratio(&num, &den, @intCast(info.width), @intCast(info.height), @intCast(info.par_n), @intCast(info.par_d), @intCast(dn), @intCast(dd)) == 0) {
        cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("Error calculating the output display ratio of the video."), FILE, "gst_xv_image_sink_setcaps", 995);
        return 0;
    }
    const h: c.guint = @intCast(info.height);
    const wd: c.guint = @intCast(info.width);
    if (h % den == 0) {
        s.video_sink.width = @intCast(c.gst_util_uint64_scale_int(h, @intCast(num), @intCast(den)));
        s.video_sink.height = info.height;
    } else if (wd % num == 0) {
        s.video_sink.width = info.width;
        s.video_sink.height = @intCast(c.gst_util_uint64_scale_int(wd, @intCast(den), @intCast(num)));
    } else {
        s.video_sink.width = @intCast(c.gst_util_uint64_scale_int(h, @intCast(num), @intCast(den)));
        s.video_sink.height = info.height;
    }
    flock(s);
    if (s.xwindow == null) {
        funlock(s);
        c.gst_video_overlay_prepare_window_handle(@ptrCast(s));
    } else funlock(s);
    if (s.video_sink.width <= 0 or s.video_sink.height <= 0) {
        cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("Error calculating the output display size of the video."), FILE, "gst_xv_image_sink_setcaps", 1001);
        return 0;
    }
    flock(s);
    if (s.xwindow == null) s.xwindow = winNew(s, s.video_sink.width, s.video_sink.height);
    if (s.pending_render_rect != 0) {
        s.pending_render_rect = 0;
        ctxm.setRenderRectangle(s.xwindow.?, s.render_rect.x, s.render_rect.y, s.render_rect.w, s.render_rect.h);
    }
    s.info = info;
    s.redraw_border = 1;
    const old = s.pool;
    s.pool = null;
    funlock(s);
    if (old != null) {
        _ = c.gst_buffer_pool_set_active(old, 0);
        c.gst_object_unref(old);
    }
    return 1;
}

fn openSink(s: *Self) bool {
    if (s.context == null) {
        var err: [*c]c.GError = null;
        const ctx = ctxm.new(&s.config, &err) orelse {
            c.gst_element_message_full(@ptrCast(s), c.GST_MESSAGE_ERROR, err[0].domain, err[0].code, c.g_strdup("Could not initialise Xv output"), c.g_strdup(err[0].message), FILE, "gst_xv_image_sink_open", 1947);
            c.g_clear_error(&err);
            return false;
        };
        cm.lock(s);
        s.context = ctx;
    } else cm.lock(s);
    s.allocator = xa.newAllocator(s.context.?);
    cm.unlock(s);
    if (s.par == null) {
        s.par = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GValue))));
        c.gst_value_init_and_copy(s.par, s.context.?.par);
    }
    ctxm.setSynchronous(s.context.?, s.synchronous);
    updateColorbalance(s);
    manageThread(s);
    return true;
}

fn closeSink(s: *Self) void {
    cm.lock(s);
    s.running = 0;
    const t = s.event_thread;
    s.event_thread = null;
    cm.unlock(s);
    if (t != null) _ = c.g_thread_join(t);
    if (s.cur_image != null) {
        c.gst_buffer_unref(s.cur_image);
        s.cur_image = null;
    }
    flock(s);
    if (s.pool != null) {
        c.gst_object_unref(s.pool);
        s.pool = null;
    }
    if (s.xwindow) |w| {
        ctxm.clearWindow(w);
        ctxm.destroyWindow(w);
        s.xwindow = null;
    }
    funlock(s);
    if (s.allocator) |a| {
        c.gst_object_unref(a);
        s.allocator = null;
    }
    cm.lock(s);
    const ctx = s.context;
    s.context = null;
    cm.unlock(s);
    if (ctx) |cx| ctxm.unref(cx);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    if (t == c.GST_STATE_CHANGE_NULL_TO_READY and !openSink(s)) return c.GST_STATE_CHANGE_FAILURE;
    const ret = parent_el.change_state.?(e, t);
    switch (t) {
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            s.fps_n = 0;
            s.fps_d = 1;
            s.video_sink.width = 0;
            s.video_sink.height = 0;
            flock(s);
            if (s.pool != null) _ = c.gst_buffer_pool_set_active(s.pool, 0);
            funlock(s);
        },
        c.GST_STATE_CHANGE_READY_TO_NULL => closeSink(s),
        else => {},
    }
    return ret;
}

fn getTimes(bs: [*c]c.GstBaseSink, b: [*c]c.GstBuffer, start: [*c]c.GstClockTime, end: [*c]c.GstClockTime) callconv(.c) void {
    const s = me(bs);
    if (b[0].pts == cm.CLOCK_NONE) return;
    start[0] = b[0].pts;
    if (b[0].duration != cm.CLOCK_NONE) {
        end[0] = start[0] + b[0].duration;
    } else if (s.fps_n > 0) end[0] = start[0] + c.gst_util_uint64_scale_int(c.GST_SECOND, s.fps_d, s.fps_n);
}

fn showFrame(vs: [*c]c.GstVideoSink, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(vs);
    var to_put: [*c]c.GstBuffer = b;
    var res: c.GstFlowReturn = c.GST_FLOW_OK;
    const mem = if (c.gst_buffer_n_memory(b) == 1) c.gst_buffer_peek_memory(b, 0) else null;
    if (mem == null or !xa.fromContext(mem, s.context)) {
        if (s.pool == null) {
            const caps = c.gst_video_info_to_caps(&s.info);
            s.pool = createPool(s, caps, s.info.size, 2);
            if (s.pool == null) {
                cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, c.g_strdup("Internal error: can't allocate images"), c.g_strdup("We don't have a bufferpool negotiated"), FILE, "gst_xv_image_sink_show_frame", 1169);
                return c.GST_FLOW_ERROR;
            }
            c.gst_caps_unref(caps);
        }
        if (c.gst_buffer_pool_set_active(s.pool, 1) == 0) return c.GST_FLOW_ERROR;
        var params = std.mem.zeroes(c.GstBufferPoolAcquireParams);
        params.flags = c.GST_BUFFER_POOL_ACQUIRE_FLAG_DONTWAIT;
        to_put = null;
        res = c.gst_buffer_pool_acquire_buffer(s.pool, &to_put, &params);
        if (res != c.GST_FLOW_OK) return c.GST_FLOW_OK;
        var src: c.GstVideoFrame = undefined;
        var dst: c.GstVideoFrame = undefined;
        if (c.gst_video_frame_map(&src, &s.info, b, c.GST_MAP_READ) == 0) {
            c.gst_buffer_unref(to_put);
            return c.GST_FLOW_OK;
        }
        if (c.gst_video_frame_map(&dst, &s.info, to_put, c.GST_MAP_WRITE) == 0) {
            c.gst_video_frame_unmap(&src);
            c.gst_buffer_unref(to_put);
            return c.GST_FLOW_OK;
        }
        _ = c.gst_video_frame_copy(&dst, &src);
        c.gst_video_frame_unmap(&dst);
        c.gst_video_frame_unmap(&src);
        const cmeta = c.gst_buffer_get_meta(b, c.gst_video_crop_meta_api_get_type());
        if (cmeta != null) {
            const from: *c.GstVideoCropMeta = @ptrCast(@alignCast(cmeta));
            const into: *c.GstVideoCropMeta = @ptrCast(@alignCast(c.gst_buffer_add_meta(to_put, c.gst_video_crop_meta_get_info(), null)));
            into.x = from.x;
            into.y = from.y;
            into.width = from.width;
            into.height = from.height;
        }
    }
    if (!put(s, to_put)) res = c.GST_FLOW_ERROR;
    if (to_put != b) c.gst_buffer_unref(to_put);
    return res;
}

fn sinkEvent(bs: [*c]c.GstBaseSink, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(bs);
    if (e[0].type == c.GST_EVENT_TAG) {
        var l: ?*c.GstTagList = null;
        var title: [*c]u8 = null;
        c.gst_event_parse_tag(e, &l);
        _ = c.gst_tag_list_get_string(l, c.GST_TAG_TITLE, &title);
        if (title != null) {
            setTitle(s, s.xwindow, title);
            c.g_free(title);
        }
    }
    return parent_bs.event.?(bs, e);
}

fn proposeAllocation(bs: [*c]c.GstBaseSink, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(bs);
    var caps: [*c]c.GstCaps = null;
    var need: c.gboolean = 0;
    c.gst_query_parse_allocation(q, &caps, &need);
    if (caps == null) return 0;
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) == 0) return 0;
    var p: ?*c.GstBufferPool = null;
    if (need != 0) p = createPool(s, caps, info.size, 0) orelse return 0;
    s.info = info;
    c.gst_query_add_allocation_pool(q, p, @intCast(info.size), 2, 0);
    if (p != null) c.gst_object_unref(p);
    c.gst_query_add_allocation_meta(q, c.gst_video_meta_api_get_type(), null);
    c.gst_query_add_allocation_meta(q, c.gst_video_crop_meta_api_get_type(), null);
    return 1;
}

fn navSend(n: ?*c.GstNavigation, ev: [*c]c.GstEvent) callconv(.c) void {
    const s = me(n);
    flock(s);
    const w = s.xwindow orelse {
        funlock(s);
        c.gst_event_unref(ev);
        return;
    };
    const r = target(s, w);
    funlock(s);
    const xs = @as(f64, @floatFromInt(s.video_width)) / @as(f64, @floatFromInt(r.w));
    const ys = @as(f64, @floatFromInt(s.video_height)) / @as(f64, @floatFromInt(r.h));
    const e = c.gst_event_make_writable(ev);
    var px: f64 = 0;
    var py: f64 = 0;
    if (c.gst_navigation_event_get_coordinates(e, &px, &py) != 0) {
        px = @max(@min(px, @as(f64, @floatFromInt(r.x + r.w))) - @as(f64, @floatFromInt(r.x)), 0);
        py = @max(@min(py, @as(f64, @floatFromInt(r.y + r.h))) - @as(f64, @floatFromInt(r.y)), 0);
        _ = c.gst_navigation_event_set_coordinates(e, px * xs, py * ys);
    }
    _ = c.gst_event_ref(e);
    if (c.gst_pad_push_event(sinkpad(s), e) == 0) _ = c.gst_element_post_message(@ptrCast(s), c.gst_navigation_message_new_event(@ptrCast(s), e));
    c.gst_event_unref(e);
}

fn navInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstNavigationInterface = @ptrCast(@alignCast(iface));
    i.send_event_simple = navSend;
}

fn setWindowHandle(o: ?*c.GstVideoOverlay, id: c.guintptr) callconv(.c) void {
    const s = me(o);
    flock(s);
    defer funlock(s);
    if (s.xwindow != null and id == s.xwindow.?.win) return;
    if (s.context == null) {
        s.context = ctxm.new(&s.config, null);
        if (s.context == null) return;
    }
    updateColorbalance(s);
    if (s.xwindow) |w| {
        ctxm.destroyWindow(w);
        s.xwindow = null;
    }
    var win: ?*Win = null;
    if (id == 0) {
        if (s.video_sink.width != 0 and s.video_sink.height != 0) win = winNew(s, s.video_sink.width, s.video_sink.height);
    } else {
        win = ctxm.windowFromXid(s.context.?, id);
        ctxm.setEventHandling(win.?, s.handle_events);
    }
    if (win != null) s.xwindow = win;
}

fn expose(o: ?*c.GstVideoOverlay) callconv(.c) void {
    const s = me(o);
    updateGeometry(s);
    _ = put(s, null);
}

fn setEventHandling(o: ?*c.GstVideoOverlay, on: c.gboolean) callconv(.c) void {
    const s = me(o);
    flock(s);
    s.handle_events = on;
    if (s.xwindow) |w| ctxm.setEventHandling(w, on);
    funlock(s);
}

fn setRenderRectangle(o: ?*c.GstVideoOverlay, rx: c.gint, ry: c.gint, rw: c.gint, rh: c.gint) callconv(.c) void {
    const s = me(o);
    flock(s);
    if (s.xwindow) |w| {
        ctxm.setRenderRectangle(w, rx, ry, rw, rh);
    } else {
        s.render_rect = .{ .x = rx, .y = ry, .w = rw, .h = rh };
        s.pending_render_rect = 1;
    }
    funlock(s);
}

fn overlayInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstVideoOverlayInterface = @ptrCast(@alignCast(iface));
    i.set_window_handle = setWindowHandle;
    i.expose = expose;
    i.handle_events = setEventHandling;
    i.set_render_rectangle = setRenderRectangle;
}

fn listChannels(b: ?*c.GstColorBalance) callconv(.c) [*c]const c.GList {
    const s = me(b);
    return if (s.context) |ctx| ctx.channels_list else null;
}

fn channelSlot(s: *Self, label: [*c]const u8) ?*c.gint {
    if (c.g_ascii_strcasecmp(label, "XV_HUE") == 0) return &s.config.hue;
    if (c.g_ascii_strcasecmp(label, "XV_SATURATION") == 0) return &s.config.saturation;
    if (c.g_ascii_strcasecmp(label, "XV_CONTRAST") == 0) return &s.config.contrast;
    if (c.g_ascii_strcasecmp(label, "XV_BRIGHTNESS") == 0) return &s.config.brightness;
    c.g_log(null, c.G_LOG_LEVEL_WARNING, "got an unknown channel %s", label);
    return null;
}

fn setValue(b: ?*c.GstColorBalance, ch: [*c]c.GstColorBalanceChannel, value: c.gint) callconv(.c) void {
    const s = me(b);
    if (!cm.that(ch[0].label != null, "gst_xv_image_sink_colorbalance_set_value", "channel->label != NULL")) return;
    s.config.cb_changed = 1;
    const v: c.gint = @intFromFloat(@floor(0.5 + -1000.0 + 2000.0 * @as(f64, @floatFromInt(value - ch[0].min_value)) / @as(f64, @floatFromInt(ch[0].max_value - ch[0].min_value))));
    const slot = channelSlot(s, ch[0].label) orelse return;
    slot.* = v;
    updateColorbalance(s);
}

fn getValue(b: ?*c.GstColorBalance, ch: [*c]c.GstColorBalanceChannel) callconv(.c) c.gint {
    const s = me(b);
    if (!cm.that(ch[0].label != null, "gst_xv_image_sink_colorbalance_get_value", "channel->label != NULL")) return 0;
    const v: c.gint = if (channelSlot(s, ch[0].label)) |slot| slot.* else 0;
    return ch[0].min_value + @divTrunc((ch[0].max_value - ch[0].min_value) * (v + 1000), 2000);
}

fn balanceType(_: ?*c.GstColorBalance) callconv(.c) c.GstColorBalanceType {
    return c.GST_COLOR_BALANCE_HARDWARE;
}

fn balanceInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstColorBalanceInterface = @ptrCast(@alignCast(iface));
    i.list_channels = listChannels;
    i.set_value = setValue;
    i.get_value = getValue;
    i.get_balance_type = balanceType;
}

fn setCb(s: *Self, slot: *c.gint, v: [*c]const c.GValue) void {
    slot.* = c.g_value_get_int(v);
    s.config.cb_changed = 1;
    updateColorbalance(s);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.hue) => setCb(s, &s.config.hue, v),
        @intFromEnum(Prop.contrast) => setCb(s, &s.config.contrast, v),
        @intFromEnum(Prop.brightness) => setCb(s, &s.config.brightness, v),
        @intFromEnum(Prop.saturation) => setCb(s, &s.config.saturation, v),
        @intFromEnum(Prop.display) => {
            c.g_free(s.config.display_name);
            s.config.display_name = c.g_value_dup_string(v);
        },
        @intFromEnum(Prop.synchronous) => {
            s.synchronous = c.g_value_get_boolean(v);
            if (s.context) |ctx| ctxm.setSynchronous(ctx, s.synchronous);
        },
        @intFromEnum(Prop.pixel_aspect_ratio) => {
            c.g_free(s.par);
            s.par = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GValue))));
            _ = c.g_value_init(s.par, c.gst_fraction_get_type());
            if (c.g_value_transform(v, s.par) == 0) {
                c.g_log(null, c.G_LOG_LEVEL_WARNING, "Could not transform string to aspect ratio");
                c.gst_value_set_fraction(s.par, 1, 1);
            }
        },
        @intFromEnum(Prop.force_aspect_ratio) => s.keep_aspect = c.g_value_get_boolean(v),
        @intFromEnum(Prop.handle_events) => {
            setEventHandling(@ptrCast(s), c.g_value_get_boolean(v));
            manageThread(s);
        },
        @intFromEnum(Prop.device) => s.config.adaptor_nr = @bitCast(@as(c_int, @truncate(std.fmt.parseInt(c_long, std.mem.sliceTo(c.g_value_get_string(v), 0), 10) catch 0))),
        @intFromEnum(Prop.handle_expose) => {
            s.handle_expose = c.g_value_get_boolean(v);
            manageThread(s);
        },
        @intFromEnum(Prop.double_buffer) => s.double_buffer = c.g_value_get_boolean(v),
        @intFromEnum(Prop.autopaint_colorkey) => s.config.autopaint_colorkey = c.g_value_get_boolean(v),
        @intFromEnum(Prop.colorkey) => s.config.colorkey = c.g_value_get_int(v),
        @intFromEnum(Prop.draw_borders) => s.draw_borders = c.g_value_get_boolean(v),
        else => if (c.gst_video_overlay_set_property(o, @intFromEnum(Prop.last), id, v) == 0) cm.warnInvalid(FILE, o, id, spec, 1816),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.hue) => c.g_value_set_int(v, s.config.hue),
        @intFromEnum(Prop.contrast) => c.g_value_set_int(v, s.config.contrast),
        @intFromEnum(Prop.brightness) => c.g_value_set_int(v, s.config.brightness),
        @intFromEnum(Prop.saturation) => c.g_value_set_int(v, s.config.saturation),
        @intFromEnum(Prop.display) => c.g_value_set_string(v, s.config.display_name),
        @intFromEnum(Prop.synchronous) => c.g_value_set_boolean(v, s.synchronous),
        @intFromEnum(Prop.pixel_aspect_ratio) => if (s.par != null) {
            _ = c.g_value_transform(s.par, v);
        },
        @intFromEnum(Prop.force_aspect_ratio) => c.g_value_set_boolean(v, s.keep_aspect),
        @intFromEnum(Prop.handle_events) => c.g_value_set_boolean(v, s.handle_events),
        @intFromEnum(Prop.device) => {
            const str = c.g_strdup_printf("%u", s.config.adaptor_nr);
            c.g_value_set_string(v, str);
            c.g_free(str);
        },
        @intFromEnum(Prop.device_name) => {
            if (s.context != null and s.context.?.adaptors != null) {
                c.g_value_set_string(v, s.context.?.adaptors[s.config.adaptor_nr]);
            } else c.g_value_set_string(v, null);
        },
        @intFromEnum(Prop.handle_expose) => c.g_value_set_boolean(v, s.handle_expose),
        @intFromEnum(Prop.double_buffer) => c.g_value_set_boolean(v, s.double_buffer),
        @intFromEnum(Prop.autopaint_colorkey) => c.g_value_set_boolean(v, s.config.autopaint_colorkey),
        @intFromEnum(Prop.colorkey) => c.g_value_set_int(v, s.config.colorkey),
        @intFromEnum(Prop.draw_borders) => c.g_value_set_boolean(v, s.draw_borders),
        @intFromEnum(Prop.window_width) => c.g_value_set_uint64(v, if (s.xwindow) |w| @intCast(w.width) else 0),
        @intFromEnum(Prop.window_height) => c.g_value_set_uint64(v, if (s.xwindow) |w| @intCast(w.height) else 0),
        else => cm.warnInvalid(FILE, o, id, spec, 1905),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    closeSink(s);
    ctxm.configClear(&s.config);
    c.g_free(s.par);
    s.par = null;
    c.g_mutex_clear(&s.flow_lock);
    c.g_free(s.media_title);
    parent_obj.finalize.?(o);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.config.autopaint_colorkey = 1;
    s.config.double_buffer = 1;
    s.config.colorkey = (8 << 16) | (8 << 8) | 16;
    c.g_mutex_init(&s.flow_lock);
    s.keep_aspect = 1;
    s.handle_events = 1;
    s.handle_expose = 1;
    s.draw_borders = 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_obj = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    parent_el = @ptrCast(@alignCast(parent_obj));
    parent_bs = @ptrCast(@alignCast(parent_obj));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const RW = cm.RW;
    const RO = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, @intFromEnum(Prop.contrast), c.g_param_spec_int("contrast", "Contrast", "The contrast of the video", -1000, 1000, 0, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.brightness), c.g_param_spec_int("brightness", "Brightness", "The brightness of the video", -1000, 1000, 0, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.hue), c.g_param_spec_int("hue", "Hue", "The hue of the video", -1000, 1000, 0, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.saturation), c.g_param_spec_int("saturation", "Saturation", "The saturation of the video", -1000, 1000, 0, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.display), c.g_param_spec_string("display", "Display", "X Display name", null, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.synchronous), c.g_param_spec_boolean("synchronous", "Synchronous", "When enabled, runs the X display in synchronous mode. (unrelated to A/V sync, used only for debugging)", 0, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.pixel_aspect_ratio), c.g_param_spec_string("pixel-aspect-ratio", "Pixel Aspect Ratio", "The pixel aspect ratio of the device", "1/1", RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.force_aspect_ratio), c.g_param_spec_boolean("force-aspect-ratio", "Force aspect ratio", "When enabled, scaling will respect original aspect ratio", 1, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.handle_events), c.g_param_spec_boolean("handle-events", "Handle XEvents", "When enabled, XEvents will be selected and handled", 1, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.device), c.g_param_spec_string("device", "Adaptor number", "The number of the video adaptor", "0", RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.device_name), c.g_param_spec_string("device-name", "Adaptor name", "The name of the video adaptor", null, RO));
    c.gst_video_overlay_install_properties(oc, @intFromEnum(Prop.last));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.handle_expose), c.g_param_spec_boolean("handle-expose", "Handle expose", "When enabled, the current frame will always be drawn in response to X Expose events", 1, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.double_buffer), c.g_param_spec_boolean("double-buffer", "Double-buffer", "Whether to double-buffer the output", 1, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.autopaint_colorkey), c.g_param_spec_boolean("autopaint-colorkey", "Autofill with colorkey", "Whether to autofill overlay with colorkey", 1, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.colorkey), c.g_param_spec_int("colorkey", "Colorkey", "Color to use for the overlay mask", std.math.minInt(c.gint), std.math.maxInt(c.gint), 0, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.draw_borders), c.g_param_spec_boolean("draw-borders", "Draw Borders", "Draw black borders to fill unused area in force-aspect-ratio mode", 1, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.window_width), c.g_param_spec_uint64("window-width", "window-width", "Width of the window", 0, std.math.maxInt(u64), 0, RO));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.window_height), c.g_param_spec_uint64("window-height", "window-height", "Height of the window", 0, std.math.maxInt(u64), 0, RO));
    oc.finalize = finalize;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Video sink", "Sink/Video", "A Xv based videosink", "Julien Moutte <julien@moutte.net>");
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    ec.change_state = changeState;
    const bc: *c.GstBaseSinkClass = @ptrCast(@alignCast(k));
    bc.get_caps = getCaps;
    bc.set_caps = setCaps;
    bc.get_times = getTimes;
    bc.propose_allocation = proposeAllocation;
    bc.event = sinkEvent;
    const vc: *c.GstVideoSinkClass = @ptrCast(@alignCast(k));
    vc.show_frame = showFrame;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_video_sink_get_type(), "GstXvImageSink", Class, Self, classInit, init);
            const nv = c.GInterfaceInfo{ .interface_init = navInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_navigation_get_type(), &nv);
            const ov = c.GInterfaceInfo{ .interface_init = overlayInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_video_overlay_get_type(), &ov);
            const cb = c.GInterfaceInfo{ .interface_init = balanceInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_color_balance_get_type(), &cb);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    ctxm.cat = c._gst_debug_category_new("xcontext", 0, "xcontext miniobject");
    cat = c._gst_debug_category_new("xvimagesink", 0, "ximagesink element");
    xa.pool_cat = c._gst_debug_category_new("xvimagepool", 0, "ximagepool object");
    return c.gst_element_register(p, "xvimagesink", c.GST_RANK_PRIMARY, getType()) != 0;
}
