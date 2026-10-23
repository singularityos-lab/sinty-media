const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const x = @import("x.zig");
const X = x.p;
const pool = @import("pool.zig");

const FILE = "../sys/ximage/ximagesink.c";
const CAPS = "video/x-raw, framerate = (fraction) [ 0, MAX ], width = (int) [ 1, MAX ], height = (int) [ 1, MAX ]";

const Prop = enum(c.guint) { display = 1, synchronous, pixel_aspect_ratio, force_aspect_ratio, handle_events, handle_expose, window_width, window_height };

pub const Ctx = extern struct {
    disp: ?*X.Display,
    screen: [*c]X.Screen,
    screen_num: c_int,
    visual: [*c]X.Visual,
    root: X.Window,
    white: c_ulong,
    black: c_ulong,
    depth: c_int,
    bpp: c_int,
    width: c_int,
    height: c_int,
    widthmm: c_int,
    heightmm: c_int,
    par: [*c]c.GValue,
    use_xshm: c.gboolean,
    use_xkb: c.gboolean,
    use_xi2: c.gboolean,
    xi_opcode: c_int,
    caps: [*c]c.GstCaps,
    last_caps: [*c]c.GstCaps,
};

pub const Win = extern struct {
    win: X.Window,
    width: c.gint,
    height: c.gint,
    internal: c.gboolean,
    gc: X.GC,
};

const Touch = extern struct {
    id: c_int,
    name: [*c]u8,
    pressure_valuator: c_int,
    abs_pressure: c.gboolean,
    pressure_min: f64,
    pressure_max: f64,
    current_pressure: f64,
};

const Hints = extern struct {
    flags: c_ulong,
    functions: c_ulong,
    decorations: c_ulong,
    input_mode: c_long,
    status: c_ulong,
};

pub const Self = extern struct {
    video_sink: c.GstVideoSink,
    display_name: [*c]u8,
    xcontext: ?*Ctx,
    xwindow: ?*Win,
    cur_image: [*c]c.GstBuffer,
    event_thread: ?*c.GThread,
    running: c.gboolean,
    info: c.GstVideoInfo,
    fps_n: c.gint,
    fps_d: c.gint,
    x_lock: c.GMutex,
    flow_lock: c.GMutex,
    par: [*c]c.GValue,
    pool: [*c]c.GstBufferPool,
    synchronous: c.gboolean,
    keep_aspect: c.gboolean,
    handle_events: c.gboolean,
    handle_expose: c.gboolean,
    draw_border: c.gboolean,
    media_title: [*c]u8,
    last_touch: c_ulong,
    touch_devices: [*c]c.GArray,
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

fn xlock(s: *Self) void {
    c.g_mutex_lock(&s.x_lock);
}

fn xunlock(s: *Self) void {
    c.g_mutex_unlock(&s.x_lock);
}

fn flock(s: *Self) void {
    c.g_mutex_lock(&s.flow_lock);
}

fn funlock(s: *Self) void {
    c.g_mutex_unlock(&s.flow_lock);
}

fn sinkpad(s: *Self) ?*c.GstPad {
    return s.video_sink.element.sinkpad;
}

fn drawBorders(s: *Self, w: *Win, r: c.GstVideoRectangle) void {
    const d = s.xcontext.?.disp;
    _ = X.XSetForeground(d, w.gc, s.xcontext.?.black);
    if (r.x > 0) _ = X.XFillRectangle(d, w.win, w.gc, 0, 0, @intCast(r.x), @intCast(w.height));
    if (r.x + r.w < w.width) _ = X.XFillRectangle(d, w.win, w.gc, r.x + r.w, 0, @intCast(w.width), @intCast(w.height));
    if (r.y > 0) _ = X.XFillRectangle(d, w.win, w.gc, 0, 0, @intCast(w.width), @intCast(r.y));
    if (r.y + r.h < w.height) _ = X.XFillRectangle(d, w.win, w.gc, 0, r.y + r.h, @intCast(w.width), @intCast(w.height));
}

fn put(s: *Self, image: [*c]c.GstBuffer) bool {
    flock(s);
    defer funlock(s);
    const w = s.xwindow orelse return false;
    var border = s.cur_image == null or s.draw_border != 0;
    var img = image;
    if (img != null and s.cur_image != img) {
        if (s.cur_image != null) c.gst_buffer_unref(s.cur_image);
        s.cur_image = c.gst_buffer_ref(img);
    }
    if (img == null) {
        border = true;
        if (s.cur_image == null) return true;
        img = s.cur_image;
    }
    const m: *pool.Memory = @ptrCast(@alignCast(c.gst_buffer_peek_memory(img, 0)));
    var src = c.GstVideoRectangle{ .x = m.x, .y = m.y, .w = m.width, .h = m.height };
    const meta = c.gst_buffer_get_meta(img, c.gst_video_crop_meta_api_get_type());
    if (meta != null) {
        const crop: *c.GstVideoCropMeta = @ptrCast(@alignCast(meta));
        src = .{ .x = @as(c.gint, @intCast(crop.x)) + m.x, .y = @as(c.gint, @intCast(crop.y)) + m.y, .w = @intCast(crop.width), .h = @intCast(crop.height) };
    }
    const dst = c.GstVideoRectangle{ .x = 0, .y = 0, .w = w.width, .h = w.height };
    var r: c.GstVideoRectangle = undefined;
    c.gst_video_center_rect(&src, &dst, &r, 0);
    xlock(s);
    const ctx = s.xcontext.?;
    if (border) {
        drawBorders(s, w, r);
        s.draw_border = 0;
    }
    if (ctx.use_xshm != 0) {
        _ = X.XShmPutImage(ctx.disp, w.win, w.gc, m.ximage, src.x, src.y, r.x, r.y, @intCast(r.w), @intCast(r.h), 0);
    } else {
        _ = X.XPutImage(ctx.disp, w.win, w.gc, m.ximage, src.x, src.y, r.x, r.y, @intCast(r.w), @intCast(r.h));
    }
    _ = X.XSync(ctx.disp, 0);
    xunlock(s);
    return true;
}

fn decorate(s: *Self, w: *Win) void {
    xlock(s);
    defer xunlock(s);
    const d = s.xcontext.?.disp;
    const atom = X.XInternAtom(d, "_MOTIF_WM_HINTS", 1);
    if (atom == X.None) return;
    var h = std.mem.zeroes(Hints);
    h.flags = 1 << 1;
    h.decorations = 1;
    _ = X.XChangeProperty(d, w.win, atom, atom, 32, X.PropModeReplace, @ptrCast(&h), @sizeOf(Hints) / @sizeOf(c_long));
    _ = X.XSync(d, 0);
}

fn setTitle(s: *Self, win: ?*Win, title_in: [*c]const u8) void {
    if (title_in != null) {
        c.g_free(s.media_title);
        s.media_title = c.g_strdup(title_in);
    }
    const w = win orelse return;
    if (w.internal == 0) return;
    const d = s.xcontext.?.disp;
    const app = c.g_get_application_name();
    var owned: [*c]u8 = null;
    var title: [*c]const u8 = null;
    if (app != null and s.media_title != null) {
        owned = c.g_strconcat(s.media_title, " : ", app, @as(?*anyopaque, null));
        title = owned;
    } else if (app != null) {
        title = app;
    } else if (s.media_title != null) title = s.media_title;
    if (title != null) {
        var prop: X.XTextProperty = undefined;
        var list = [1][*c]u8{@constCast(title)};
        if (X.XStringListToTextProperty(&list, 1, &prop) != 0) {
            const name = X.XInternAtom(d, "_NET_WM_NAME", 0);
            const utf8 = X.XInternAtom(d, "UTF8_STRING", 0);
            _ = X.XChangeProperty(d, w.win, name, utf8, 8, 0, title, @intCast(std.mem.len(title)));
            _ = X.XSync(d, 0);
            X.XSetWMName(d, w.win, &prop);
            _ = X.XFree(prop.value);
        }
        c.g_free(owned);
    }
    const hint = X.XAllocClassHint();
    if (hint != null) {
        hint[0].res_name = @constCast(app);
        hint[0].res_class = @constCast("GStreamer");
        _ = X.XSetClassHint(d, w.win, hint);
    }
    _ = X.XFree(hint);
    var pid: c_ulong = @intCast(std.c.getpid());
    const atom = X.XInternAtom(d, "_NET_WM_PID", 0);
    _ = X.XChangeProperty(d, w.win, atom, atom, 32, 0, @ptrCast(&pid), 1);
}

fn clearTouch(p: ?*anyopaque) callconv(.c) void {
    const t: *Touch = @ptrCast(@alignCast(p));
    c.g_free(t.name);
}

fn selectTouch(s: *Self, w: *Win) void {
    const ctx = s.xcontext.?;
    _ = c.g_array_remove_range(s.touch_devices, 0, s.touch_devices[0].len);
    const len: c_int = (X.XI_LASTEVENT + 7) >> 3;
    const mask: [*]u8 = @ptrCast(c.g_malloc0(@intCast(len)));
    x.setMask(mask, X.XI_TouchBegin);
    x.setMask(mask, X.XI_TouchUpdate);
    x.setMask(mask, X.XI_TouchEnd);
    var n: c_int = 0;
    const devs = X.XIQueryDevice(ctx.disp, X.XIAllDevices, &n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const dev = &devs[i];
        if (dev.use != X.XISlavePointer) continue;
        var t = Touch{ .id = dev.deviceid, .name = dev.name, .pressure_valuator = -1, .abs_pressure = 0, .pressure_min = 0, .pressure_max = 0, .current_pressure = 0 };
        var touch = false;
        var j: usize = 0;
        while (j < dev.num_classes) : (j += 1) {
            const k = dev.classes[j];
            if (k[0].type == X.XITouchClass and @as(*X.XITouchClassInfo, @ptrCast(@alignCast(k))).mode == X.XIDirectTouch) touch = true;
            if (k[0].type == X.XIValuatorClass) {
                const v: *X.XIValuatorClassInfo = @ptrCast(@alignCast(k));
                if (v.label == X.XInternAtom(ctx.disp, "Abs Pressure", 1)) {
                    t.abs_pressure = 1;
                } else if (v.label == X.XInternAtom(ctx.disp, "Rel Pressure", 1)) {
                    t.abs_pressure = 0;
                } else continue;
                t.pressure_valuator = v.number;
                t.pressure_min = v.min;
                t.pressure_max = v.max;
                t.current_pressure = v.min;
            }
        }
        if (!touch) continue;
        t.name = c.g_strdup(t.name);
        _ = c.g_array_append_vals(s.touch_devices, &t, 1);
        var em = X.XIEventMask{ .deviceid = t.id, .mask_len = len, .mask = mask };
        _ = X.XISelectEvents(ctx.disp, w.win, &em, 1);
    }
    c.g_free(mask);
    X.XIFreeDeviceInfo(devs);
}

fn winNew(s: *Self, width: c.gint, height: c.gint) *Win {
    const w: *Win = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Win))));
    w.width = width;
    w.height = height;
    w.internal = 1;
    xlock(s);
    const ctx = s.xcontext.?;
    w.win = X.XCreateSimpleWindow(ctx.disp, ctx.root, 0, 0, @intCast(width), @intCast(height), 0, 0, ctx.black);
    _ = X.XSetWindowBackgroundPixmap(ctx.disp, w.win, X.None);
    setTitle(s, w, null);
    if (s.handle_events != 0) {
        _ = X.XSelectInput(ctx.disp, w.win, x.FULL_MASK);
        var del = X.XInternAtom(ctx.disp, "WM_DELETE_WINDOW", 0);
        _ = X.XSetWMProtocols(ctx.disp, w.win, &del, 1);
        if (ctx.use_xi2 != 0) {
            var mask = [2]u8{ 0, 0 };
            selectTouch(s, w);
            x.setMask(&mask, X.XI_HierarchyChanged);
            var em = X.XIEventMask{ .deviceid = X.XIAllDevices, .mask_len = 2, .mask = &mask };
            _ = X.XISelectEvents(ctx.disp, w.win, &em, 1);
        }
    }
    var values: X.XGCValues = undefined;
    w.gc = X.XCreateGC(ctx.disp, w.win, 0, &values);
    _ = X.XMapRaised(ctx.disp, w.win);
    _ = X.XSync(ctx.disp, 0);
    xunlock(s);
    decorate(s, w);
    c.gst_video_overlay_got_window_handle(@ptrCast(s), w.win);
    return w;
}

fn winDestroy(s: *Self, w: *Win) void {
    xlock(s);
    const d = s.xcontext.?.disp;
    if (w.internal != 0) {
        _ = X.XDestroyWindow(d, w.win);
    } else _ = X.XSelectInput(d, w.win, 0);
    _ = X.XFreeGC(d, w.gc);
    _ = X.XSync(d, 0);
    xunlock(s);
    c.g_free(w);
}

fn updateGeometry(s: *Self) void {
    xlock(s);
    const w = s.xwindow orelse {
        xunlock(s);
        return;
    };
    var attr: X.XWindowAttributes = undefined;
    _ = X.XGetWindowAttributes(s.xcontext.?.disp, w.win, &attr);
    const changed = w.width != attr.width or w.height != attr.height;
    w.width = attr.width;
    w.height = attr.height;
    xunlock(s);
    if (changed) _ = c.gst_pad_push_event(sinkpad(s), c.gst_event_new_reconfigure());
}

fn winClear(s: *Self, w: *Win) void {
    xlock(s);
    const d = s.xcontext.?.disp;
    _ = X.XSetForeground(d, w.gc, s.xcontext.?.black);
    _ = X.XFillRectangle(d, w.win, w.gc, 0, 0, @intCast(w.width), @intCast(w.height));
    _ = X.XSync(d, 0);
    xunlock(s);
}

fn nav(s: *Self, e: ?*c.GstEvent) void {
    c.gst_navigation_send_event_simple(@ptrCast(s), e);
}

fn mods(state: c_uint) c.GstNavigationModifierType {
    return state & c.GST_NAVIGATION_MODIFIER_MASK;
}

fn touchEvent(s: *Self, e: *X.XEvent, open: *bool, state: *c.GstNavigationModifierType) bool {
    const ctx = s.xcontext.?;
    const cookie = &e.xcookie;
    if (cookie.evtype == X.XI_HierarchyChanged) {
        selectTouch(s, s.xwindow.?);
        return false;
    }
    if (cookie.evtype != X.XI_TouchBegin and cookie.evtype != X.XI_TouchUpdate and cookie.evtype != X.XI_TouchEnd) return false;
    const t: *X.XIDeviceEvent = @ptrCast(@alignCast(cookie.data));
    const id: c.guint = (@as(c.guint, @bitCast(t.deviceid)) << 16) | (@as(c.guint, @bitCast(t.detail)) & 0xff);
    const list: [*]Touch = @ptrCast(@alignCast(s.touch_devices[0].data));
    var dev: ?*Touch = null;
    for (0..s.touch_devices[0].len) |i| {
        if (list[i].id == t.deviceid) {
            dev = &list[i];
            break;
        }
    }
    const d = dev orelse return false;
    var pressure: f64 = std.math.nan(f64);
    if (d.pressure_valuator >= 0) {
        pressure = (t.valuators.values[@intCast(d.pressure_valuator)] - d.pressure_min) / (d.pressure_max - d.pressure_min);
        if (d.abs_pressure == 0) pressure += d.current_pressure;
    }
    d.current_pressure = pressure;
    xunlock(s);
    funlock(s);
    state.* = @bitCast(t.mods.effective);
    if (t.time != s.last_touch and open.*) {
        if (t.time >= s.last_touch) nav(s, c.gst_navigation_event_new_touch_frame(state.*));
    }
    const ev = switch (cookie.evtype) {
        X.XI_TouchBegin => c.gst_navigation_event_new_touch_down(id, t.event_x, t.event_y, pressure, state.*),
        X.XI_TouchEnd => c.gst_navigation_event_new_touch_up(id, t.event_x, t.event_y, state.*),
        else => c.gst_navigation_event_new_touch_motion(id, t.event_x, t.event_y, pressure, state.*),
    };
    nav(s, ev);
    s.last_touch = t.time;
    open.* = true;
    flock(s);
    xlock(s);
    _ = ctx;
    return true;
}

fn handleEvents(s: *Self) void {
    var e: X.XEvent = undefined;
    var px: c_int = 0;
    var py: c_int = 0;
    var moved = false;
    var pstate: c_uint = 0;
    var exposed = false;
    var configured = false;
    var open = false;
    var state: c.GstNavigationModifierType = c.GST_NAVIGATION_MODIFIER_NONE;
    flock(s);
    xlock(s);
    const ctx = s.xcontext.?;
    const d = ctx.disp;
    if (s.xwindow == null) {
        xunlock(s);
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
        xunlock(s);
        funlock(s);
        nav(s, c.gst_navigation_event_new_mouse_move(@floatFromInt(px), @floatFromInt(py), mods(pstate)));
        flock(s);
        xlock(s);
    }
    while (s.xwindow != null and X.XCheckWindowEvent(d, s.xwindow.?.win, X.KeyPressMask | X.KeyReleaseMask | X.ButtonPressMask | X.ButtonReleaseMask, &e) != 0) {
        xunlock(s);
        funlock(s);
        switch (e.type) {
            X.ButtonPress => nav(s, c.gst_navigation_event_new_mouse_button_press(@intCast(e.xbutton.button), @floatFromInt(e.xbutton.x), @floatFromInt(e.xbutton.y), mods(e.xbutton.state))),
            X.ButtonRelease => nav(s, c.gst_navigation_event_new_mouse_button_release(@intCast(e.xbutton.button), @floatFromInt(e.xbutton.x), @floatFromInt(e.xbutton.y), mods(e.xbutton.state))),
            X.KeyPress, X.KeyRelease => {
                xlock(s);
                const sym = if (ctx.use_xkb != 0) X.XkbKeycodeToKeysym(d, @intCast(e.xkey.keycode), 0, 0) else X.XKeycodeToKeysym(d, @intCast(e.xkey.keycode), 0);
                const key: [*c]const u8 = if (sym != X.NoSymbol) X.XKeysymToString(sym) else "unknown";
                xunlock(s);
                nav(s, if (e.type == X.KeyPress) c.gst_navigation_event_new_key_press(key, mods(e.xkey.state)) else c.gst_navigation_event_new_key_release(key, mods(e.xkey.state)));
            },
            else => {},
        }
        flock(s);
        xlock(s);
    }
    while (s.xwindow != null and X.XCheckWindowEvent(d, s.xwindow.?.win, X.ExposureMask | X.StructureNotifyMask, &e) != 0) {
        switch (e.type) {
            X.Expose => exposed = true,
            X.ConfigureNotify => {
                xunlock(s);
                updateGeometry(s);
                xlock(s);
                configured = true;
            },
            else => {},
        }
    }
    if (s.handle_expose != 0 and (exposed or configured)) {
        xunlock(s);
        funlock(s);
        expose(@ptrCast(s));
        flock(s);
        xlock(s);
    }
    while (X.XPending(d) != 0) {
        _ = X.XNextEvent(d, &e);
        if (e.type == X.ClientMessage) {
            const del = X.XInternAtom(d, "WM_DELETE_WINDOW", 0);
            if (del == @as(X.Atom, @bitCast(e.xclient.data.l[0]))) {
                cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("Output window was closed"), null, FILE, "gst_x_image_sink_handle_xevents", 855);
                xunlock(s);
                if (s.xwindow) |w| winDestroy(s, w);
                s.xwindow = null;
                xlock(s);
            }
        } else if (ctx.use_xi2 != 0 and X.XGetEventData(d, &e.xcookie) != 0) {
            if (e.xcookie.extension == ctx.xi_opcode and s.xwindow != null) _ = touchEvent(s, &e, &open, &state);
            X.XFreeEventData(d, &e.xcookie);
        }
    }
    xunlock(s);
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
    if (s.xcontext == null) return;
    var t: ?*c.GThread = null;
    cm.lock(s);
    if (s.handle_expose != 0 or s.handle_events != 0) {
        if (s.event_thread == null) {
            s.running = 1;
            s.event_thread = c.g_thread_try_new("ximagesink-events", eventThread, s, null);
        }
    } else if (s.event_thread != null) {
        s.running = 0;
        t = s.event_thread;
        s.event_thread = null;
    }
    cm.unlock(s);
    if (t != null) _ = c.g_thread_join(t);
}

fn calcPar(ctx: *Ctx) void {
    const table = [_][2]c.gint{ .{ 1, 1 }, .{ 16, 15 }, .{ 11, 10 }, .{ 54, 59 }, .{ 64, 45 }, .{ 5, 3 }, .{ 4, 3 } };
    var ratio = @as(f64, @floatFromInt(ctx.widthmm * ctx.height)) / @as(f64, @floatFromInt(ctx.heightmm * ctx.width));
    if (ctx.width == 720 and ctx.height == 576) ratio = 4.0 * 576.0 / (3.0 * 720.0);
    var best: usize = 0;
    var delta: f64 = @abs(ratio - 1.0);
    for (table[1..], 1..) |e, i| {
        const dd = @abs(ratio - @as(f64, @floatFromInt(e[0])) / @as(f64, @floatFromInt(e[1])));
        if (dd < delta) {
            best = i;
            delta = dd;
        }
    }
    c.g_free(ctx.par);
    ctx.par = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GValue))));
    _ = c.g_value_init(ctx.par, c.gst_fraction_get_type());
    c.gst_value_set_fraction(ctx.par, table[best][0], table[best][1]);
}

fn ctxGet(s: *Self) ?*Ctx {
    const ctx: *Ctx = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Ctx))));
    xlock(s);
    ctx.disp = X.XOpenDisplay(s.display_name);
    const d = ctx.disp orelse {
        xunlock(s);
        c.g_free(ctx);
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, c.g_strdup("Could not initialise X output"), c.g_strdup("Could not open display"), FILE, "gst_x_image_sink_xcontext_get", 1150);
        return null;
    };
    ctx.screen = X.XDefaultScreenOfDisplay(d);
    ctx.screen_num = X.XDefaultScreen(d);
    ctx.visual = X.XDefaultVisual(d, ctx.screen_num);
    ctx.root = X.XDefaultRootWindow(d);
    ctx.white = X.XWhitePixel(d, ctx.screen_num);
    ctx.black = X.XBlackPixel(d, ctx.screen_num);
    ctx.depth = X.XDefaultDepthOfScreen(ctx.screen);
    ctx.width = X.XDisplayWidth(d, ctx.screen_num);
    ctx.height = X.XDisplayHeight(d, ctx.screen_num);
    ctx.widthmm = X.XDisplayWidthMM(d, ctx.screen_num);
    ctx.heightmm = X.XDisplayHeightMM(d, ctx.screen_num);
    calcPar(ctx);
    var nf: c_int = 0;
    const fmts = X.XListPixmapFormats(d, &nf);
    if (fmts == null) {
        _ = X.XCloseDisplay(d);
        xunlock(s);
        c.g_free(ctx.par);
        c.g_free(ctx);
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_SETTINGS, c.g_strdup("Could not get supported pixmap formats"), null, FILE, "gst_x_image_sink_xcontext_get", 1181);
        return null;
    }
    for (0..@intCast(nf)) |i| {
        if (fmts[i].depth == ctx.depth) ctx.bpp = fmts[i].bits_per_pixel;
    }
    _ = X.XFree(fmts);
    const endian: c.gint = if (X.XImageByteOrder(d) == X.LSBFirst) c.G_LITTLE_ENDIAN else c.G_BIG_ENDIAN;
    ctx.use_xshm = @intFromBool(X.XShmQueryExtension(d) != 0 and pool.checkXshm(ctx));
    var op: c_int = 0;
    var ev: c_int = 0;
    var er: c_int = 0;
    var kmaj: c_int = X.XkbMajorVersion;
    var kmin: c_int = X.XkbMinorVersion;
    ctx.use_xkb = @intFromBool(X.XkbQueryExtension(d, &op, &ev, &er, &kmaj, &kmin) != 0);
    var imaj: c_int = X.XI_2_Major;
    var imin: c_int = X.XI_2_Minor;
    ctx.use_xi2 = @intFromBool(X.XQueryExtension(d, "XInputExtension", &ctx.xi_opcode, &ev, &er) != 0 and X.XIQueryVersion(d, &imaj, &imin) == X.Success and (imaj > 2 or (imaj == 2 and imin >= 2)));
    const v = ctx.visual[0];
    const alpha: u32 = if (ctx.depth == 32) ~@as(u32, @truncate(v.red_mask | v.green_mask | v.blue_mask)) else 0;
    const fmt = c.gst_video_format_from_masks(ctx.depth, ctx.bpp, endian, @truncate(v.red_mask), @truncate(v.green_mask), @truncate(v.blue_mask), alpha);
    if (fmt == c.GST_VIDEO_FORMAT_UNKNOWN) {
        xunlock(s);
        return null;
    }
    if (s.par == null) {
        s.par = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GValue))));
        c.gst_value_init_and_copy(s.par, ctx.par);
    }
    ctx.caps = c.gst_caps_new_simple("video/x-raw", "format", c.G_TYPE_STRING, c.gst_video_format_to_string(fmt), "width", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, std.math.maxInt(c.gint)), "height", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, std.math.maxInt(c.gint)), "framerate", c.gst_fraction_range_get_type(), @as(c.gint, 0), @as(c.gint, 1), @as(c.gint, std.math.maxInt(c.gint)), @as(c.gint, 1), @as(?*anyopaque, null));
    if (s.par != null) c.gst_caps_set_simple(ctx.caps, "pixel-aspect-ratio", c.gst_fraction_get_type(), c.gst_value_get_fraction_numerator(s.par), c.gst_value_get_fraction_denominator(s.par), @as(?*anyopaque, null));
    xunlock(s);
    return ctx;
}

fn ctxClear(s: *Self) void {
    cm.lock(s);
    const ctx = s.xcontext orelse {
        cm.unlock(s);
        return;
    };
    s.xcontext = null;
    cm.unlock(s);
    c.gst_caps_unref(ctx.caps);
    c.g_free(ctx.par);
    c.g_free(s.par);
    s.par = null;
    if (ctx.last_caps != null) _ = c.gst_caps_replace(&ctx.last_caps, null);
    xlock(s);
    _ = X.XCloseDisplay(ctx.disp);
    xunlock(s);
    c.g_free(ctx);
}

fn intersect(caps: [*c]c.GstCaps, filter: [*c]c.GstCaps, filter_first: bool) [*c]c.GstCaps {
    if (filter == null) return caps;
    const r = if (filter_first) c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST) else c.gst_caps_intersect_full(caps, filter, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(caps);
    return r;
}

fn getCaps(bs: [*c]c.GstBaseSink, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(bs);
    xlock(s);
    if (s.xcontext) |ctx| {
        var caps = intersect(c.gst_caps_ref(ctx.caps), filter, true);
        if (c.gst_caps_is_empty(caps) != 0) {
            xunlock(s);
            return caps;
        }
        if (s.xwindow != null and s.xwindow.?.width != 0) {
            caps = c.gst_caps_make_writable(caps);
            const s0 = c.gst_caps_get_structure(caps, 0);
            const s1 = c.gst_structure_copy(s0);
            c.gst_structure_set(s0, "width", c.G_TYPE_INT, s.xwindow.?.width, "height", c.G_TYPE_INT, s.xwindow.?.height, @as(?*anyopaque, null));
            c.gst_caps_append_structure(caps, s1);
            caps = intersect(caps, filter, false);
        }
        xunlock(s);
        return caps;
    }
    xunlock(s);
    var caps = c.gst_pad_get_pad_template_caps(sinkpad(s));
    if (s.par != null) {
        caps = c.gst_caps_make_writable(caps);
        for (0..c.gst_caps_get_size(caps)) |i| {
            c.gst_structure_set(c.gst_caps_get_structure(caps, @intCast(i)), "pixel-aspect-ratio", c.gst_fraction_get_type(), c.gst_value_get_fraction_numerator(s.par), c.gst_value_get_fraction_denominator(s.par), @as(?*anyopaque, null));
        }
    }
    return intersect(caps, filter, true);
}

fn createPool(s: *Self, caps: [*c]c.GstCaps, size: usize, min: c.guint) ?*c.GstBufferPool {
    const P = struct {
        var params = c.GstAllocationParams{ .flags = 0, .@"align" = 15, .prefix = 0, .padding = 0, ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
    };
    const p = pool.new(s);
    const config = c.gst_buffer_pool_get_config(p);
    c.gst_buffer_pool_config_set_params(config, caps, @intCast(size), min, 0);
    c.gst_buffer_pool_config_set_allocator(config, null, &P.params);
    if (c.gst_buffer_pool_set_config(p, config) == 0) {
        c.gst_object_unref(p);
        return null;
    }
    return p;
}

fn setCaps(bs: [*c]c.GstBaseSink, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(bs);
    const ctx = s.xcontext orelse return 0;
    if (c.gst_caps_can_intersect(ctx.caps, caps) == 0) return 0;
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) == 0) return 0;
    const st = c.gst_caps_get_structure(caps, 0);
    const par = c.gst_structure_get_value(st, "pixel-aspect-ratio");
    if (par != null) {
        if (s.par != null) {
            if (c.gst_value_compare(par, s.par) != c.GST_VALUE_EQUAL) return 0;
        } else if (ctx.par != null) {
            if (c.gst_value_compare(par, ctx.par) != c.GST_VALUE_EQUAL) return 0;
        }
    }
    s.video_sink.width = info.width;
    s.video_sink.height = info.height;
    s.fps_n = info.fps_n;
    s.fps_d = info.fps_d;
    flock(s);
    if (s.xwindow == null) {
        funlock(s);
        c.gst_video_overlay_prepare_window_handle(@ptrCast(s));
    } else funlock(s);
    if (s.video_sink.width <= 0 or s.video_sink.height <= 0) {
        cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("Invalid image size."), FILE, "gst_x_image_sink_setcaps", 1545);
        return 0;
    }
    flock(s);
    if (s.xwindow == null) s.xwindow = winNew(s, s.video_sink.width, s.video_sink.height);
    s.info = info;
    s.draw_border = 1;
    const fresh = createPool(s, caps, info.size, 2);
    const old = s.pool;
    s.pool = fresh;
    funlock(s);
    if (old != null) {
        _ = c.gst_buffer_pool_set_active(old, 0);
        c.gst_object_unref(old);
    }
    return 1;
}

fn reset(s: *Self) void {
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
    _ = c.g_array_remove_range(s.touch_devices, 0, s.touch_devices[0].len);
    if (s.pool != null) {
        c.gst_object_unref(s.pool);
        s.pool = null;
    }
    if (s.xwindow) |w| {
        winClear(s, w);
        winDestroy(s, w);
        s.xwindow = null;
    }
    funlock(s);
    ctxClear(s);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => {
            if (s.xcontext == null) {
                const ctx = ctxGet(s) orelse return c.GST_STATE_CHANGE_FAILURE;
                cm.lock(s);
                s.xcontext = ctx;
                cm.unlock(s);
            }
            xlock(s);
            _ = X.XSynchronize(s.xcontext.?.disp, s.synchronous);
            xunlock(s);
            manageThread(s);
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            flock(s);
            if (s.xwindow) |w| winClear(s, w);
            funlock(s);
        },
        else => {},
    }
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
        c.GST_STATE_CHANGE_READY_TO_NULL => reset(s),
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
    if (!pool.isOurs(b, s)) {
        const p = s.pool;
        if (p == null) {
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, c.g_strdup("Internal error: can't allocate images"), c.g_strdup("We don't have a bufferpool negotiated"), FILE, "gst_x_image_sink_show_frame", 1714);
            return c.GST_FLOW_ERROR;
        }
        if (c.gst_buffer_pool_set_active(p, 1) == 0) return c.GST_FLOW_ERROR;
        var params = std.mem.zeroes(c.GstBufferPoolAcquireParams);
        params.flags = c.GST_BUFFER_POOL_ACQUIRE_FLAG_DONTWAIT;
        to_put = null;
        res = c.gst_buffer_pool_acquire_buffer(p, &to_put, &params);
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
    const e = c.gst_event_make_writable(ev);
    const xo = w.width - s.video_sink.width;
    const yo = w.height - s.video_sink.height;
    funlock(s);
    var px: f64 = 0;
    var py: f64 = 0;
    if (c.gst_navigation_event_get_coordinates(e, &px, &py) != 0) {
        px -= @floatFromInt(@divTrunc(xo, 2));
        py -= @floatFromInt(@divTrunc(yo, 2));
        _ = c.gst_navigation_event_set_coordinates(e, px, py);
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
    if (s.xcontext == null) {
        s.xcontext = ctxGet(s);
        if (s.xcontext == null) return;
    }
    if (s.xwindow) |w| {
        winDestroy(s, w);
        s.xwindow = null;
    }
    var win: ?*Win = null;
    if (id == 0) {
        if (s.video_sink.width != 0 and s.video_sink.height != 0) win = winNew(s, s.video_sink.width, s.video_sink.height);
    } else {
        const w: *Win = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Win))));
        w.win = id;
        xlock(s);
        w.internal = 0;
        if (s.handle_events != 0) _ = X.XSelectInput(s.xcontext.?.disp, w.win, x.BASE_MASK);
        w.gc = X.XCreateGC(s.xcontext.?.disp, w.win, 0, null);
        xunlock(s);
        win = w;
    }
    if (win) |w| {
        s.xwindow = w;
        updateGeometry(s);
    }
}

fn expose(o: ?*c.GstVideoOverlay) callconv(.c) void {
    const s = me(o);
    updateGeometry(s);
    _ = put(s, null);
}

fn setEventHandling(o: ?*c.GstVideoOverlay, on: c.gboolean) callconv(.c) void {
    const s = me(o);
    s.handle_events = on;
    flock(s);
    defer funlock(s);
    const w = s.xwindow orelse return;
    xlock(s);
    const mask: c_long = if (on == 0) 0 else if (w.internal != 0) x.FULL_MASK else x.BASE_MASK;
    _ = X.XSelectInput(s.xcontext.?.disp, w.win, mask);
    xunlock(s);
}

fn overlayInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstVideoOverlayInterface = @ptrCast(@alignCast(iface));
    i.set_window_handle = setWindowHandle;
    i.expose = expose;
    i.handle_events = setEventHandling;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.display) => s.display_name = c.g_strdup(c.g_value_get_string(v)),
        @intFromEnum(Prop.synchronous) => {
            s.synchronous = c.g_value_get_boolean(v);
            if (s.xcontext) |ctx| {
                xlock(s);
                _ = X.XSynchronize(ctx.disp, s.synchronous);
                xunlock(s);
            }
        },
        @intFromEnum(Prop.force_aspect_ratio) => s.keep_aspect = c.g_value_get_boolean(v),
        @intFromEnum(Prop.pixel_aspect_ratio) => {
            const tmp: [*c]c.GValue = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GValue))));
            _ = c.g_value_init(tmp, c.gst_fraction_get_type());
            if (c.g_value_transform(v, tmp) == 0) {
                c.gst_debug_log(cat, c.GST_LEVEL_WARNING, FILE, "gst_x_image_sink_set_property", 2048, @ptrCast(s), "Could not transform string to aspect ratio");
                c.g_free(tmp);
            } else {
                c.g_free(s.par);
                s.par = tmp;
            }
        },
        @intFromEnum(Prop.handle_events) => {
            setEventHandling(@ptrCast(s), c.g_value_get_boolean(v));
            manageThread(s);
        },
        @intFromEnum(Prop.handle_expose) => {
            s.handle_expose = c.g_value_get_boolean(v);
            manageThread(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 2070),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.display) => c.g_value_set_string(v, s.display_name),
        @intFromEnum(Prop.synchronous) => c.g_value_set_boolean(v, s.synchronous),
        @intFromEnum(Prop.force_aspect_ratio) => c.g_value_set_boolean(v, s.keep_aspect),
        @intFromEnum(Prop.pixel_aspect_ratio) => if (s.par != null) {
            _ = c.g_value_transform(s.par, v);
        },
        @intFromEnum(Prop.handle_events) => c.g_value_set_boolean(v, s.handle_events),
        @intFromEnum(Prop.handle_expose) => c.g_value_set_boolean(v, s.handle_expose),
        @intFromEnum(Prop.window_width) => c.g_value_set_uint64(v, if (s.xwindow) |w| @intCast(w.width) else 0),
        @intFromEnum(Prop.window_height) => c.g_value_set_uint64(v, if (s.xwindow) |w| @intCast(w.height) else 0),
        else => cm.warnInvalid(FILE, o, id, spec, 2118),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    reset(s);
    c.g_free(s.display_name);
    s.display_name = null;
    c.g_free(s.par);
    s.par = null;
    _ = c.g_array_free(s.touch_devices, 1);
    c.g_mutex_clear(&s.x_lock);
    c.g_mutex_clear(&s.flow_lock);
    c.g_free(s.media_title);
    parent_obj.finalize.?(o);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.fps_n = 0;
    s.fps_d = 1;
    s.touch_devices = c.g_array_new(0, 0, @sizeOf(Touch));
    c.g_array_set_clear_func(s.touch_devices, clearTouch);
    c.g_mutex_init(&s.x_lock);
    c.g_mutex_init(&s.flow_lock);
    s.keep_aspect = 1;
    s.handle_events = 1;
    s.handle_expose = 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_obj = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    parent_el = @ptrCast(@alignCast(parent_obj));
    parent_bs = @ptrCast(@alignCast(parent_obj));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const RW = cm.RW;
    const RO = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, @intFromEnum(Prop.display), c.g_param_spec_string("display", "Display", "X Display name", null, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.synchronous), c.g_param_spec_boolean("synchronous", "Synchronous", "When enabled, runs the X display in synchronous mode. (unrelated to A/V sync, used only for debugging)", 0, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.force_aspect_ratio), c.g_param_spec_boolean("force-aspect-ratio", "Force aspect ratio", "When enabled, reverse caps negotiation (scaling) will respect original aspect ratio", 1, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.pixel_aspect_ratio), c.g_param_spec_string("pixel-aspect-ratio", "Pixel Aspect Ratio", "The pixel aspect ratio of the device", "1/1", RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.handle_events), c.g_param_spec_boolean("handle-events", "Handle XEvents", "When enabled, XEvents will be selected and handled", 1, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.handle_expose), c.g_param_spec_boolean("handle-expose", "Handle expose", "When enabled, the current frame will always be drawn in response to X Expose events", 1, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.window_width), c.g_param_spec_uint64("window-width", "window-width", "Width of the window", 0, std.math.maxInt(u64), 0, RO));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.window_height), c.g_param_spec_uint64("window-height", "window-height", "Height of the window", 0, std.math.maxInt(u64), 0, RO));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Video sink", "Sink/Video", "A standard X based videosink", "Julien Moutte <julien@moutte.net>");
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
            const t = cm.register(c.gst_video_sink_get_type(), "GstXImageSink", Class, Self, classInit, init);
            const nv = c.GInterfaceInfo{ .interface_init = navInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_navigation_get_type(), &nv);
            const ov = c.GInterfaceInfo{ .interface_init = overlayInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_video_overlay_get_type(), &ov);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    cat = c._gst_debug_category_new("ximagesink", 0, "ximagesink element");
    pool.cat = c._gst_debug_category_new("ximagepool", 0, "ximagepool object");
    return c.gst_element_register(p, "ximagesink", c.GST_RANK_SECONDARY, getType()) != 0;
}
