const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const x = @import("x.zig");
const X = x.p;

pub const Config = extern struct {
    display_name: [*c]u8,
    adaptor_nr: c.guint,
    autopaint_colorkey: c.gboolean,
    double_buffer: c.gboolean,
    colorkey: c.gint,
    cb_changed: c.gboolean,
    brightness: c.gint,
    contrast: c.gint,
    hue: c.gint,
    saturation: c.gint,
};

pub const Format = extern struct {
    format: c.gint,
    vformat: c.GstVideoFormat,
    caps: [*c]c.GstCaps,
};

pub const Ctx = extern struct {
    parent: c.GstMiniObject,
    lock: c.GMutex,
    disp: ?*X.Display,
    screen: [*c]X.Screen,
    screen_num: c.gint,
    visual: [*c]X.Visual,
    root: X.Window,
    white: c_ulong,
    black: c_ulong,
    depth: c.gint,
    bpp: c.gint,
    endianness: c.gint,
    width: c.gint,
    height: c.gint,
    widthmm: c.gint,
    heightmm: c.gint,
    par: [*c]c.GValue,
    use_xshm: c.gboolean,
    use_xkb: c.gboolean,
    use_xi2: c.gboolean,
    xi_opcode: c_int,
    xv_port_id: X.XvPortID,
    nb_adaptors: c_uint,
    adaptors: [*c][*c]u8,
    adaptor_nr: c.gint,
    im_format: c.gint,
    have_autopaint_colorkey: c.gboolean,
    have_colorkey: c.gboolean,
    have_double_buffer: c.gboolean,
    have_iturbt709: c.gboolean,
    have_xvcolorspace: c.gboolean,
    formats_list: [*c]c.GList,
    channels_list: [*c]c.GList,
    caps: [*c]c.GstCaps,
    last_caps: [*c]c.GstCaps,
};

pub const Touch = extern struct {
    id: c_int,
    name: [*c]u8,
    pressure_valuator: c_int,
    abs_pressure: c.gboolean,
    pressure_min: f64,
    pressure_max: f64,
    current_pressure: f64,
};

pub const Win = extern struct {
    context: *Ctx,
    win: X.Window,
    width: c.gint,
    height: c.gint,
    have_render_rect: c.gboolean,
    render_rect: c.GstVideoRectangle,
    internal: c.gboolean,
    gc: X.GC,
    last_touch: c_ulong,
    touch_devices: [*c]c.GArray,
};

const Hints = extern struct {
    flags: c_ulong,
    functions: c_ulong,
    decorations: c_ulong,
    input_mode: c_long,
    status: c_ulong,
};

pub var cat: ?*c.GstDebugCategory = null;
var type_once: cm.Once = .{};
var caught = false;

fn boxCopy(p: c.gpointer) callconv(.c) c.gpointer {
    return c.gst_mini_object_ref(@ptrCast(@alignCast(p)));
}

fn boxFree(p: c.gpointer) callconv(.c) void {
    c.gst_mini_object_unref(@ptrCast(@alignCast(p)));
}

pub fn getType() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static(c.g_intern_static_string("GstXvContext"), boxCopy, boxFree);
        }
    }.f);
}

pub fn ref(ctx: *Ctx) *Ctx {
    return @ptrCast(@alignCast(c.gst_mini_object_ref(&ctx.parent)));
}

pub fn unref(ctx: *Ctx) void {
    c.gst_mini_object_unref(&ctx.parent);
}

pub fn configClear(cfg: *Config) void {
    c.g_free(cfg.display_name);
    cfg.display_name = null;
    cfg.adaptor_nr = @bitCast(@as(c_int, -1));
}

fn onError(_: ?*X.Display, _: [*c]X.XErrorEvent) callconv(.c) c_int {
    caught = true;
    return 0;
}

pub fn trapErrors() X.XErrorHandler {
    caught = false;
    return X.XSetErrorHandler(onError);
}

pub fn untrap(prev: X.XErrorHandler) void {
    caught = false;
    _ = X.XSetErrorHandler(prev);
}

pub fn errorCaught() bool {
    return caught;
}

pub fn clearCaught() void {
    caught = false;
}

fn grabPort(ctx: *Ctx, ads: [*c]X.XvAdaptorInfo, nr: usize) void {
    if (ads[nr].type & X.XvImageMask == 0) return;
    var j: c_ulong = 0;
    while (j < ads[nr].num_ports and ctx.xv_port_id == 0) : (j += 1) {
        if (X.XvGrabPort(ctx.disp, ads[nr].base_id + j, 0) == X.Success) ctx.xv_port_id = ads[nr].base_id + j;
    }
}

fn setError(err: [*c][*c]c.GError, domain: c.GQuark, code: c.gint, msg: [*c]const u8) void {
    c.g_set_error_literal(err, domain, code, msg);
}

fn formatCaps(fmt: c.GstVideoFormat, w: c_ulong, h: c_ulong) [*c]c.GstCaps {
    return c.gst_caps_new_simple("video/x-raw", "format", c.G_TYPE_STRING, c.gst_video_format_to_string(fmt), "width", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, @truncate(@as(c_long, @bitCast(w)))), "height", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, @truncate(@as(c_long, @bitCast(h)))), "framerate", c.gst_fraction_range_get_type(), @as(c.gint, 0), @as(c.gint, 1), @as(c.gint, std.math.maxInt(c.gint)), @as(c.gint, 1), @as(?*anyopaque, null));
}

fn xvSupport(ctx: *Ctx, cfg: *const Config, err: [*c][*c]c.GError) [*c]c.GstCaps {
    var dummy: c_int = 0;
    if (X.XQueryExtension(ctx.disp, "XVideo", &dummy, &dummy, &dummy) == 0) {
        setError(err, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_SETTINGS, "XVideo extension is not available");
        return null;
    }
    var ads: [*c]X.XvAdaptorInfo = null;
    if (X.XvQueryAdaptors(ctx.disp, ctx.root, &ctx.nb_adaptors, &ads) != X.Success) {
        setError(err, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_SETTINGS, "Failed getting XV adaptors list");
        return null;
    }
    ctx.xv_port_id = 0;
    ctx.adaptors = @ptrCast(@alignCast(c.g_malloc0(ctx.nb_adaptors * @sizeOf([*c]u8))));
    for (0..ctx.nb_adaptors) |i| ctx.adaptors[i] = c.g_strdup(ads[i].name);
    if (cfg.adaptor_nr != @as(c.guint, @bitCast(@as(c_int, -1))) and cfg.adaptor_nr < ctx.nb_adaptors) grabPort(ctx, ads, cfg.adaptor_nr);
    if (ctx.xv_port_id == 0) {
        var i: usize = 0;
        while (i < ctx.nb_adaptors and ctx.xv_port_id == 0) : (i += 1) {
            grabPort(ctx, ads, i);
            ctx.adaptor_nr = @intCast(i);
        }
    }
    X.XvFreeAdaptorInfo(ads);
    if (ctx.xv_port_id == 0) {
        ctx.adaptor_nr = -1;
        setError(err, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_BUSY, "No Xv Port available");
        return null;
    }
    var count: c_int = 0;
    const attr = X.XvQueryPortAttributes(ctx.disp, ctx.xv_port_id, &count);
    var todo: c_int = 4;
    var i: usize = 0;
    while (i < count and todo != 0) : (i += 1) {
        const name = std.mem.span(attr[i].name);
        if (std.mem.eql(u8, name, "XV_AUTOPAINT_COLORKEY")) {
            _ = X.XvSetPortAttribute(ctx.disp, ctx.xv_port_id, X.XInternAtom(ctx.disp, "XV_AUTOPAINT_COLORKEY", 0), @intFromBool(cfg.autopaint_colorkey != 0));
            todo -= 1;
            ctx.have_autopaint_colorkey = 1;
        } else if (std.mem.eql(u8, name, "XV_DOUBLE_BUFFER")) {
            _ = X.XvSetPortAttribute(ctx.disp, ctx.xv_port_id, X.XInternAtom(ctx.disp, "XV_DOUBLE_BUFFER", 0), @intFromBool(cfg.double_buffer != 0));
            todo -= 1;
            ctx.have_double_buffer = 1;
        } else if (std.mem.eql(u8, name, "XV_COLORKEY")) {
            const key: u32 = @bitCast(cfg.colorkey);
            var cr = key >> 16;
            var cg = (key >> 8) & 0xff;
            var cb = key & 0xff;
            var ckey: u32 = 0;
            var set = true;
            switch (ctx.depth) {
                16 => {
                    cr >>= 3;
                    cg >>= 2;
                    cb >>= 3;
                    ckey = (cr << 11) | (cg << 5) | cb;
                },
                24, 32 => ckey = (cr << 16) | (cg << 8) | cb,
                else => set = false,
            }
            if (set) {
                ckey = std.math.clamp(ckey, @as(u32, @bitCast(attr[i].min_value)), @as(u32, @bitCast(attr[i].max_value)));
                _ = X.XvSetPortAttribute(ctx.disp, ctx.xv_port_id, X.XInternAtom(ctx.disp, "XV_COLORKEY", 0), @bitCast(ckey));
            }
            todo -= 1;
            ctx.have_colorkey = 1;
        } else if (std.mem.eql(u8, name, "XV_ITURBT_709")) {
            todo -= 1;
            ctx.have_iturbt709 = 1;
        } else if (std.mem.eql(u8, name, "XV_COLORSPACE")) {
            ctx.have_xvcolorspace = 1;
            todo -= 1;
        }
    }
    _ = X.XFree(attr);
    var max_w: c_ulong = std.math.maxInt(c.gint);
    var max_h: c_ulong = std.math.maxInt(c.gint);
    var nenc: c_uint = 0;
    var enc: [*c]X.XvEncodingInfo = null;
    _ = X.XvQueryEncodings(ctx.disp, ctx.xv_port_id, &nenc, &enc);
    for (0..nenc) |k| {
        if (std.mem.eql(u8, std.mem.span(enc[k].name), "XV_IMAGE")) {
            max_w = enc[k].width;
            max_h = enc[k].height;
        }
    }
    X.XvFreeEncodingInfo(enc);
    var nf: c_int = 0;
    const fmts = X.XvListImageFormats(ctx.disp, ctx.xv_port_id, &nf);
    const caps = c.gst_caps_new_empty();
    var rgb: [*c]c.GstCaps = null;
    for (0..@intCast(nf)) |k| {
        const f = &fmts[k];
        ctx.im_format = f.id;
        var vf: c.GstVideoFormat = c.GST_VIDEO_FORMAT_UNKNOWN;
        var fc: [*c]c.GstCaps = null;
        const is_rgb = f.type == X.XvRGB;
        if (is_rgb) {
            const endian: c.gint = if (f.byte_order == X.LSBFirst) c.G_LITTLE_ENDIAN else c.G_BIG_ENDIAN;
            vf = c.gst_video_format_from_masks(f.depth, f.bits_per_pixel, endian, @bitCast(f.red_mask), @bitCast(f.green_mask), @bitCast(f.blue_mask), 0);
        } else vf = c.gst_video_format_from_fourcc(@bitCast(f.id));
        if (vf != c.GST_VIDEO_FORMAT_UNKNOWN) fc = formatCaps(vf, max_w, max_h);
        if (fc == null) continue;
        const entry: *Format = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Format))));
        entry.format = f.id;
        entry.vformat = vf;
        entry.caps = c.gst_caps_copy(fc);
        ctx.formats_list = c.g_list_append(ctx.formats_list, entry);
        if (is_rgb) {
            if (rgb == null) rgb = fc else c.gst_caps_append(rgb, fc);
        } else c.gst_caps_append(caps, fc);
    }
    if (rgb != null) c.gst_caps_append(caps, rgb);
    if (fmts != null) _ = X.XFree(fmts);
    if (c.gst_caps_is_empty(caps) != 0) {
        c.gst_caps_unref(caps);
        setError(err, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_WRONG_TYPE, "No supported format found");
        return null;
    }
    return caps;
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

fn checkXshm(ctx: *Ctx) bool {
    var info: X.XShmSegmentInfo = undefined;
    _ = X.XSync(ctx.disp, 0);
    info.shmaddr = @ptrCast(x.NO_ADDR);
    info.shmid = -1;
    const prev = trapErrors();
    var ok = false;
    var attached = false;
    const img = X.XvShmCreateImage(ctx.disp, ctx.xv_port_id, ctx.im_format, null, 1, 1, &info);
    _ = X.XSync(ctx.disp, 0);
    blk: {
        if (img == null or caught) break :blk;
        const size: usize = @intCast(img[0].data_size);
        info.shmid = X.shmget(X.IPC_PRIVATE, size, X.IPC_CREAT | 0o777);
        if (info.shmid == -1) break :blk;
        info.shmaddr = @ptrCast(X.shmat(info.shmid, null, 0));
        if (x.noAddr(info.shmaddr)) {
            _ = X.shmctl(info.shmid, X.IPC_RMID, null);
            break :blk;
        }
        img[0].data = info.shmaddr;
        info.readOnly = 0;
        if (X.XShmAttach(ctx.disp, &info) == 0) {
            _ = X.shmctl(info.shmid, X.IPC_RMID, null);
            break :blk;
        }
        _ = X.XSync(ctx.disp, 0);
        _ = X.shmctl(info.shmid, X.IPC_RMID, null);
        if (!caught) {
            attached = true;
            ok = true;
        }
    }
    _ = X.XSync(ctx.disp, 0);
    untrap(prev);
    if (attached) {
        _ = X.XShmDetach(ctx.disp, &info);
        _ = X.XSync(ctx.disp, 0);
    }
    if (!x.noAddr(info.shmaddr)) _ = X.shmdt(info.shmaddr);
    if (img != null) _ = X.XFree(img);
    return ok;
}

fn copyCtx(_: [*c]const c.GstMiniObject) callconv(.c) [*c]c.GstMiniObject {
    return null;
}

fn freeCtx(o: [*c]c.GstMiniObject) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(o));
    var l = ctx.formats_list;
    while (l != null) : (l = l[0].next) {
        const f: *Format = @ptrCast(@alignCast(l[0].data));
        c.gst_caps_unref(f.caps);
        c.g_free(f);
    }
    c.g_list_free(ctx.formats_list);
    l = ctx.channels_list;
    while (l != null) : (l = l[0].next) c.g_object_unref(l[0].data);
    c.g_list_free(ctx.channels_list);
    if (ctx.caps != null) c.gst_caps_unref(ctx.caps);
    if (ctx.last_caps != null) c.gst_caps_unref(ctx.last_caps);
    for (0..ctx.nb_adaptors) |i| c.g_free(ctx.adaptors[i]);
    c.g_free(@ptrCast(ctx.adaptors));
    c.g_free(ctx.par);
    if (ctx.xv_port_id != 0) _ = X.XvUngrabPort(ctx.disp, ctx.xv_port_id, 0);
    if (ctx.disp != null) _ = X.XCloseDisplay(ctx.disp);
    c.g_mutex_clear(&ctx.lock);
    c.g_free(ctx);
}

fn be32(v: c_ulong) c_ulong {
    return @byteSwap(@as(u32, @truncate(v)));
}

pub fn new(cfg: *Config, err: [*c][*c]c.GError) ?*Ctx {
    const ctx: *Ctx = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Ctx))));
    c.gst_mini_object_init(&ctx.parent, 0, getType(), copyCtx, null, freeCtx);
    c.g_mutex_init(&ctx.lock);
    ctx.adaptor_nr = -1;
    ctx.disp = X.XOpenDisplay(cfg.display_name);
    const d = ctx.disp orelse {
        unref(ctx);
        c.g_set_error(err, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, "Could not open display %s", cm.strNull(cfg.display_name));
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
    const px = X.XListPixmapFormats(d, &nf);
    if (px == null) {
        unref(ctx);
        setError(err, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_SETTINGS, "Could not get pixel formats");
        return null;
    }
    for (0..@intCast(nf)) |i| {
        if (px[i].depth == ctx.depth) ctx.bpp = px[i].bits_per_pixel;
    }
    _ = X.XFree(px);
    ctx.endianness = if (X.XImageByteOrder(d) == X.LSBFirst) c.G_LITTLE_ENDIAN else c.G_BIG_ENDIAN;
    if ((ctx.bpp == 24 or ctx.bpp == 32) and ctx.endianness == c.G_LITTLE_ENDIAN) {
        ctx.endianness = c.G_BIG_ENDIAN;
        const v = &ctx.visual[0];
        v.red_mask = be32(v.red_mask);
        v.green_mask = be32(v.green_mask);
        v.blue_mask = be32(v.blue_mask);
        if (ctx.bpp == 24) {
            v.red_mask >>= 8;
            v.green_mask >>= 8;
            v.blue_mask >>= 8;
        }
    }
    ctx.caps = xvSupport(ctx, cfg, err);
    if (ctx.caps == null) {
        unref(ctx);
        return null;
    }
    ctx.use_xshm = @intFromBool(X.XShmQueryExtension(d) != 0 and checkXshm(ctx));
    var op: c_int = 0;
    var ev: c_int = 0;
    var er: c_int = 0;
    var kmaj: c_int = X.XkbMajorVersion;
    var kmin: c_int = X.XkbMinorVersion;
    ctx.use_xkb = @intFromBool(X.XkbQueryExtension(d, &op, &ev, &er, &kmaj, &kmin) != 0);
    var imaj: c_int = X.XI_2_Major;
    var imin: c_int = X.XI_2_Minor;
    ctx.use_xi2 = @intFromBool(X.XQueryExtension(d, "XInputExtension", &ctx.xi_opcode, &ev, &er) != 0 and X.XIQueryVersion(d, &imaj, &imin) == X.Success and (imaj > 2 or (imaj == 2 and imin >= 2)));
    var nattr: c_int = 0;
    const attrs = X.XvQueryPortAttributes(d, ctx.xv_port_id, &nattr);
    const names = [_][*:0]const u8{ "XV_HUE", "XV_SATURATION", "XV_BRIGHTNESS", "XV_CONTRAST" };
    for (names) |name| {
        const atom = X.XInternAtom(d, name, 1);
        if (atom == X.None) continue;
        var match: ?*X.XvAttribute = null;
        if (attrs != null) {
            var j: usize = 0;
            while (j < nattr and match == null) : (j += 1) {
                if (c.g_ascii_strcasecmp(name, attrs[j].name) == 0) match = &attrs[j];
            }
        }
        const m = match orelse continue;
        const ch: *c.GstColorBalanceChannel = @ptrCast(@alignCast(c.g_object_new(c.gst_color_balance_channel_get_type(), null)));
        ch.label = c.g_strdup(name);
        ch.min_value = m.min_value;
        ch.max_value = m.max_value;
        ctx.channels_list = c.g_list_append(ctx.channels_list, ch);
        if (cfg.cb_changed == 0) {
            var val: c_int = 0;
            _ = X.XvGetPortAttribute(d, ctx.xv_port_id, atom, &val);
            const v: c.gint = @intFromFloat(@floor(0.5 + -1000.0 + 2000.0 * @as(f64, @floatFromInt(val - ch.min_value)) / @as(f64, @floatFromInt(ch.max_value - ch.min_value))));
            if (c.g_ascii_strcasecmp(name, "XV_HUE") == 0) {
                cfg.hue = v;
            } else if (c.g_ascii_strcasecmp(name, "XV_SATURATION") == 0) {
                cfg.saturation = v;
            } else if (c.g_ascii_strcasecmp(name, "XV_BRIGHTNESS") == 0) {
                cfg.brightness = v;
            } else if (c.g_ascii_strcasecmp(name, "XV_CONTRAST") == 0) cfg.contrast = v;
        }
    }
    if (attrs != null) _ = X.XFree(attrs);
    return ctx;
}

pub fn setSynchronous(ctx: *Ctx, on: c.gboolean) void {
    c.g_mutex_lock(&ctx.lock);
    _ = X.XSynchronize(ctx.disp, on);
    c.g_mutex_unlock(&ctx.lock);
}

pub fn updateColorbalance(ctx: *Ctx, cfg: *const Config) void {
    if (cfg.cb_changed == 0) return;
    var l = ctx.channels_list;
    while (l != null) : (l = l[0].next) {
        if (l[0].data == null or c.g_type_check_instance_is_a(@ptrCast(@alignCast(l[0].data)), c.gst_color_balance_channel_get_type()) == 0) continue;
        const ch: *c.GstColorBalanceChannel = @ptrCast(@alignCast(c.g_object_ref(l[0].data)));
        defer c.g_object_unref(ch);
        const coef = @as(f64, @floatFromInt(ch.max_value - ch.min_value)) / 2000.0;
        const value: c.gint = if (c.g_ascii_strcasecmp(ch.label, "XV_HUE") == 0)
            cfg.hue
        else if (c.g_ascii_strcasecmp(ch.label, "XV_SATURATION") == 0)
            cfg.saturation
        else if (c.g_ascii_strcasecmp(ch.label, "XV_CONTRAST") == 0)
            cfg.contrast
        else if (c.g_ascii_strcasecmp(ch.label, "XV_BRIGHTNESS") == 0)
            cfg.brightness
        else {
            c.g_log(null, c.G_LOG_LEVEL_WARNING, "got an unknown channel %s", ch.label);
            return;
        };
        c.g_mutex_lock(&ctx.lock);
        const atom = X.XInternAtom(ctx.disp, ch.label, 1);
        if (atom != X.None) {
            const xv: c_int = @intFromFloat(@floor(0.5 + @as(f64, @floatFromInt(value + 1000)) * coef + @as(f64, @floatFromInt(ch.min_value))));
            _ = X.XvSetPortAttribute(ctx.disp, ctx.xv_port_id, atom, xv);
        }
        c.g_mutex_unlock(&ctx.lock);
    }
}

pub fn formatFromInfo(ctx: *Ctx, info: *const c.GstVideoInfo) c.gint {
    var l = ctx.formats_list;
    while (l != null) : (l = l[0].next) {
        const f: ?*Format = @ptrCast(@alignCast(l[0].data));
        if (f != null and f.?.vformat == info.finfo[0].format) return f.?.format;
    }
    return -1;
}

pub fn setColorimetry(ctx: *Ctx, cm_: *const c.GstVideoColorimetry) void {
    if (ctx.have_iturbt709 == 0 and ctx.have_xvcolorspace == 0) return;
    const v: c_int = switch (cm_.matrix) {
        c.GST_VIDEO_COLOR_MATRIX_SMPTE240M, c.GST_VIDEO_COLOR_MATRIX_BT709 => 1,
        else => 0,
    };
    c.g_mutex_lock(&ctx.lock);
    if (ctx.have_iturbt709 != 0) {
        const a = X.XInternAtom(ctx.disp, "XV_ITURBT_709", 1);
        if (a != X.None) _ = X.XvSetPortAttribute(ctx.disp, ctx.xv_port_id, a, v);
    }
    if (ctx.have_xvcolorspace != 0) {
        const a = X.XInternAtom(ctx.disp, "XV_COLORSPACE", 1);
        if (a != X.None) _ = X.XvSetPortAttribute(ctx.disp, ctx.xv_port_id, a, v);
    }
    c.g_mutex_unlock(&ctx.lock);
}

fn clearTouch(p: ?*anyopaque) callconv(.c) void {
    const t: *Touch = @ptrCast(@alignCast(p));
    c.g_free(t.name);
}

fn touchArray() [*c]c.GArray {
    const a = c.g_array_new(0, 0, @sizeOf(Touch));
    c.g_array_set_clear_func(a, clearTouch);
    return a;
}

pub fn createWindow(ctx: *Ctx, width: c.gint, height: c.gint) *Win {
    const w: *Win = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Win))));
    w.context = ref(ctx);
    w.render_rect = .{ .x = 0, .y = 0, .w = width, .h = height };
    w.width = width;
    w.height = height;
    w.internal = 1;
    w.touch_devices = touchArray();
    c.g_mutex_lock(&ctx.lock);
    const d = ctx.disp;
    w.win = X.XCreateSimpleWindow(d, ctx.root, 0, 0, @intCast(width), @intCast(height), 0, 0, ctx.black);
    _ = X.XSetWindowBackgroundPixmap(d, w.win, X.None);
    var del = X.XInternAtom(d, "WM_DELETE_WINDOW", 1);
    if (del != X.None) _ = X.XSetWMProtocols(d, w.win, &del, 1);
    const hints = X.XInternAtom(d, "_MOTIF_WM_HINTS", 1);
    if (hints != X.None) {
        var h = std.mem.zeroes(Hints);
        h.flags = 1 << 1;
        h.decorations = 1;
        _ = X.XChangeProperty(d, w.win, hints, hints, 32, X.PropModeReplace, @ptrCast(&h), @sizeOf(Hints) / @sizeOf(c_long));
        _ = X.XSync(d, 0);
    }
    var pid: c_ulong = @intCast(std.c.getpid());
    const atom = X.XInternAtom(d, "_NET_WM_PID", 0);
    _ = X.XChangeProperty(d, w.win, atom, atom, 32, 0, @ptrCast(&pid), 1);
    w.gc = X.XCreateGC(d, w.win, 0, null);
    _ = X.XMapRaised(d, w.win);
    _ = X.XSync(d, 0);
    c.g_mutex_unlock(&ctx.lock);
    return w;
}

pub fn windowFromXid(ctx: *Ctx, xid: X.Window) *Win {
    const w: *Win = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Win))));
    w.win = xid;
    w.context = ref(ctx);
    c.g_mutex_lock(&ctx.lock);
    var attr: X.XWindowAttributes = undefined;
    _ = X.XGetWindowAttributes(ctx.disp, xid, &attr);
    w.width = attr.width;
    w.height = attr.height;
    w.internal = 0;
    w.render_rect = .{ .x = 0, .y = 0, .w = attr.width, .h = attr.height };
    w.touch_devices = touchArray();
    w.gc = X.XCreateGC(ctx.disp, xid, 0, null);
    c.g_mutex_unlock(&ctx.lock);
    return w;
}

pub fn destroyWindow(w: *Win) void {
    const ctx = w.context;
    c.g_mutex_lock(&ctx.lock);
    _ = c.g_array_free(w.touch_devices, 1);
    if (w.internal != 0) {
        _ = X.XDestroyWindow(ctx.disp, w.win);
    } else _ = X.XSelectInput(ctx.disp, w.win, 0);
    _ = X.XFreeGC(ctx.disp, w.gc);
    _ = X.XSync(ctx.disp, 0);
    c.g_mutex_unlock(&ctx.lock);
    unref(ctx);
    c.g_free(w);
}

pub fn selectTouch(ctx: *Ctx, w: *Win) void {
    _ = c.g_array_remove_range(w.touch_devices, 0, w.touch_devices[0].len);
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
        _ = c.g_array_append_vals(w.touch_devices, &t, 1);
        var em = X.XIEventMask{ .deviceid = t.id, .mask_len = len, .mask = mask };
        _ = X.XISelectEvents(ctx.disp, w.win, &em, 1);
    }
    c.g_free(mask);
    X.XIFreeDeviceInfo(devs);
}

pub fn setEventHandling(w: *Win, on: c.gboolean) void {
    const ctx = w.context;
    c.g_mutex_lock(&ctx.lock);
    if (on != 0) {
        _ = X.XSelectInput(ctx.disp, w.win, if (w.internal != 0) x.FULL_MASK else x.BASE_MASK);
        if (ctx.use_xi2 != 0) {
            var mask = [2]u8{ 0, 0 };
            selectTouch(ctx, w);
            x.setMask(&mask, X.XI_HierarchyChanged);
            var em = X.XIEventMask{ .deviceid = X.XIAllDevices, .mask_len = 2, .mask = &mask };
            _ = X.XISelectEvents(ctx.disp, w.win, &em, 1);
        }
    } else _ = X.XSelectInput(ctx.disp, w.win, 0);
    c.g_mutex_unlock(&ctx.lock);
}

pub fn setTitle(w: *Win, title: [*c]const u8) void {
    if (w.internal == 0 or title == null) return;
    const d = w.context.disp;
    const name = X.XInternAtom(d, "_NET_WM_NAME", 0);
    const utf8 = X.XInternAtom(d, "UTF8_STRING", 0);
    var prop: X.XTextProperty = undefined;
    var list = [1][*c]u8{@constCast(title)};
    if (X.XStringListToTextProperty(&list, 1, &prop) == 0) return;
    X.XSetWMName(d, w.win, &prop);
    _ = X.XFree(prop.value);
    _ = X.XChangeProperty(d, w.win, name, utf8, 8, 0, title, @intCast(std.mem.len(title)));
    _ = X.XSync(d, 0);
    const hint = X.XAllocClassHint();
    if (hint != null) {
        hint[0].res_name = @constCast(title);
        hint[0].res_class = @constCast("GStreamer");
        _ = X.XSetClassHint(d, w.win, hint);
    }
    _ = X.XFree(hint);
}

pub fn updateGeometry(w: *Win) void {
    const ctx = w.context;
    c.g_mutex_lock(&ctx.lock);
    var attr: X.XWindowAttributes = undefined;
    _ = X.XGetWindowAttributes(ctx.disp, w.win, &attr);
    w.width = attr.width;
    w.height = attr.height;
    if (w.have_render_rect == 0) w.render_rect = .{ .x = 0, .y = 0, .w = attr.width, .h = attr.height };
    c.g_mutex_unlock(&ctx.lock);
}

pub fn clearWindow(w: *Win) void {
    const ctx = w.context;
    c.g_mutex_lock(&ctx.lock);
    _ = X.XvStopVideo(ctx.disp, ctx.xv_port_id, w.win);
    _ = X.XSync(ctx.disp, 0);
    c.g_mutex_unlock(&ctx.lock);
}

pub fn setRenderRectangle(w: *Win, rx: c.gint, ry: c.gint, rw: c.gint, rh: c.gint) void {
    if (rw >= 0 and rh >= 0) {
        w.render_rect = .{ .x = rx, .y = ry, .w = rw, .h = rh };
        w.have_render_rect = 1;
    } else {
        w.render_rect = .{ .x = 0, .y = 0, .w = w.width, .h = w.height };
        w.have_render_rect = 0;
    }
}
