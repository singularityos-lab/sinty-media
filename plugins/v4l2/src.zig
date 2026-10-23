const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const sys = @import("sys.zig");
const V = sys.v;
const caps = @import("caps.zig");
const tuner = @import("tuner.zig");
const TEMPLATE = @import("template.zig").TEMPLATE;

const DOMAIN = "gst-plugins-good-1.0";
const CALLS = "../sys/v4l2/v4l2_calls.c";
const OBJ = "../sys/v4l2/gstv4l2object.c";
const FILE = "../sys/v4l2/gstv4l2src.c";
const MAXBUF = 8;
const NBUF = 4;
const NONE = std.math.maxInt(u64);

const Prop = enum(c.guint) { device = 1, device_name, device_fd, flags, brightness, contrast, saturation, hue, norm, io_mode, extra_controls, pixel_aspect_ratio, force_aspect_ratio, crop_top, crop_left, crop_bottom, crop_right, crop_bounds };

const Mapped = extern struct {
    start: ?*anyopaque,
    len: usize,
};

const Pref = struct {
    width: c.gint = 3840,
    height: c.gint = 2160,
    fps_n: c.gint = 120,
    fps_d: c.gint = 1,
};

pub const Self = extern struct {
    parent: c.GstPushSrc,
    device: [*c]u8,
    fd: c_int,
    vcap: V.struct_v4l2_capability,
    device_caps: u32,
    probed: [*c]c.GstCaps,
    formats: [64]u32,
    n_formats: usize,
    par: [*c]c.GValue,
    keep_aspect: c.gboolean,
    io_mode: c.gint,
    norm: c.gint,
    extra: ?*c.GstStructure,
    crop: [4]c.guint,
    bounds: V.struct_v4l2_rect,
    info: c.GstVideoInfo,
    raw: c.gboolean,
    fourcc: u32,
    duration: u64,
    bufs: [MAXBUF]Mapped,
    nbuf: u32,
    streaming: c.gboolean,
    wake: c_int,
    offset: u64,
    last_ts: u64,
    bad_ts: c.gboolean,
    colors: [*c]c.GList,
    controls: ?*c.GData,
};

const Class = extern struct {
    parent: c.GstPushSrcClass,
};

var once: cm.Once = .{};
var flags_once: cm.Once = .{};
var norm_once: cm.Once = .{};
var io_once: cm.Once = .{};
var parent_el: *c.GstElementClass = undefined;
var parent_bs: *c.GstBaseSrcClass = undefined;
var parent_obj: *c.GObjectClass = undefined;
var sig_prepare: c.guint = 0;
var cat: ?*c.GstDebugCategory = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn srcpad(s: *Self) ?*c.GstPad {
    return s.parent.parent.srcpad;
}

fn isOpen(s: *Self) bool {
    return s.fd >= 0;
}

fn tr(msg: [*c]const u8) [*c]const u8 {
    return cm.tr(DOMAIN, msg);
}

fn sysErr() [*c]u8 {
    return c.g_strdup_printf("system error: %s", c.g_strerror(sys.errno()));
}

fn err(s: *Self, code: c.gint, text: [*c]u8, debug: [*c]u8, comptime file: []const u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_resource_error_quark(), code, text, debug, file, func, line);
}

pub fn deviceFlagsType() c.GType {
    return flags_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = V.V4L2_CAP_VIDEO_CAPTURE, .value_name = "Device supports video capture", .value_nick = "capture" },
            .{ .value = V.V4L2_CAP_VIDEO_OUTPUT, .value_name = "Device supports video playback", .value_nick = "output" },
            .{ .value = V.V4L2_CAP_VIDEO_OVERLAY, .value_name = "Device supports video overlay", .value_nick = "overlay" },
            .{ .value = V.V4L2_CAP_VBI_CAPTURE, .value_name = "Device supports the VBI capture", .value_nick = "vbi-capture" },
            .{ .value = V.V4L2_CAP_VBI_OUTPUT, .value_name = "Device supports the VBI output", .value_nick = "vbi-output" },
            .{ .value = V.V4L2_CAP_TUNER, .value_name = "Device has a tuner or modulator", .value_nick = "tuner" },
            .{ .value = V.V4L2_CAP_AUDIO, .value_name = "Device has audio inputs or outputs", .value_nick = "audio" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static("GstV4l2DeviceTypeFlags", &values);
        }
    }.f);
}

fn normType() c.GType {
    return norm_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "none", .value_nick = "none" },
            .{ .value = @intCast(V.V4L2_STD_NTSC), .value_name = "NTSC", .value_nick = "NTSC" },
            .{ .value = @intCast(V.V4L2_STD_NTSC_M), .value_name = "NTSC-M", .value_nick = "NTSC-M" },
            .{ .value = @intCast(V.V4L2_STD_NTSC_M_JP), .value_name = "NTSC-M-JP", .value_nick = "NTSC-M-JP" },
            .{ .value = @intCast(V.V4L2_STD_NTSC_M_KR), .value_name = "NTSC-M-KR", .value_nick = "NTSC-M-KR" },
            .{ .value = @intCast(V.V4L2_STD_NTSC_443), .value_name = "NTSC-443", .value_nick = "NTSC-443" },
            .{ .value = @intCast(V.V4L2_STD_PAL), .value_name = "PAL", .value_nick = "PAL" },
            .{ .value = @intCast(V.V4L2_STD_PAL_BG), .value_name = "PAL-BG", .value_nick = "PAL-BG" },
            .{ .value = @intCast(V.V4L2_STD_PAL_B), .value_name = "PAL-B", .value_nick = "PAL-B" },
            .{ .value = @intCast(V.V4L2_STD_PAL_B1), .value_name = "PAL-B1", .value_nick = "PAL-B1" },
            .{ .value = @intCast(V.V4L2_STD_PAL_G), .value_name = "PAL-G", .value_nick = "PAL-G" },
            .{ .value = @intCast(V.V4L2_STD_PAL_H), .value_name = "PAL-H", .value_nick = "PAL-H" },
            .{ .value = @intCast(V.V4L2_STD_PAL_I), .value_name = "PAL-I", .value_nick = "PAL-I" },
            .{ .value = @intCast(V.V4L2_STD_PAL_DK), .value_name = "PAL-DK", .value_nick = "PAL-DK" },
            .{ .value = @intCast(V.V4L2_STD_PAL_D), .value_name = "PAL-D", .value_nick = "PAL-D" },
            .{ .value = @intCast(V.V4L2_STD_PAL_D1), .value_name = "PAL-D1", .value_nick = "PAL-D1" },
            .{ .value = @intCast(V.V4L2_STD_PAL_K), .value_name = "PAL-K", .value_nick = "PAL-K" },
            .{ .value = @intCast(V.V4L2_STD_PAL_M), .value_name = "PAL-M", .value_nick = "PAL-M" },
            .{ .value = @intCast(V.V4L2_STD_PAL_N), .value_name = "PAL-N", .value_nick = "PAL-N" },
            .{ .value = @intCast(V.V4L2_STD_PAL_Nc), .value_name = "PAL-Nc", .value_nick = "PAL-Nc" },
            .{ .value = @intCast(V.V4L2_STD_PAL_60), .value_name = "PAL-60", .value_nick = "PAL-60" },
            .{ .value = @intCast(V.V4L2_STD_SECAM), .value_name = "SECAM", .value_nick = "SECAM" },
            .{ .value = @intCast(V.V4L2_STD_SECAM_B), .value_name = "SECAM-B", .value_nick = "SECAM-B" },
            .{ .value = @intCast(V.V4L2_STD_SECAM_G), .value_name = "SECAM-G", .value_nick = "SECAM-G" },
            .{ .value = @intCast(V.V4L2_STD_SECAM_H), .value_name = "SECAM-H", .value_nick = "SECAM-H" },
            .{ .value = @intCast(V.V4L2_STD_SECAM_DK), .value_name = "SECAM-DK", .value_nick = "SECAM-DK" },
            .{ .value = @intCast(V.V4L2_STD_SECAM_D), .value_name = "SECAM-D", .value_nick = "SECAM-D" },
            .{ .value = @intCast(V.V4L2_STD_SECAM_K), .value_name = "SECAM-K", .value_nick = "SECAM-K" },
            .{ .value = @intCast(V.V4L2_STD_SECAM_K1), .value_name = "SECAM-K1", .value_nick = "SECAM-K1" },
            .{ .value = @intCast(V.V4L2_STD_SECAM_L), .value_name = "SECAM-L", .value_nick = "SECAM-L" },
            .{ .value = @intCast(V.V4L2_STD_SECAM_LC), .value_name = "SECAM-Lc", .value_nick = "SECAM-Lc" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static("V4L2_TV_norms", &values);
        }
    }.f);
}

fn ioModeType() c.GType {
    return io_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "GST_V4L2_IO_AUTO", .value_nick = "auto" },
            .{ .value = 1, .value_name = "GST_V4L2_IO_RW", .value_nick = "rw" },
            .{ .value = 2, .value_name = "GST_V4L2_IO_MMAP", .value_nick = "mmap" },
            .{ .value = 3, .value_name = "GST_V4L2_IO_USERPTR", .value_nick = "userptr" },
            .{ .value = 4, .value_name = "GST_V4L2_IO_DMABUF", .value_nick = "dmabuf" },
            .{ .value = 5, .value_name = "GST_V4L2_IO_DMABUF_IMPORT", .value_nick = "dmabuf-import" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static("GstV4l2IOMode", &values);
        }
    }.f);
}

fn normalise(name: [*]u8) void {
    var i: usize = 0;
    var j: usize = 0;
    while (name[j] != 0) : (j += 1) {
        if (std.ascii.isAlphanumeric(name[j])) {
            if (i > 0 and !std.ascii.isAlphanumeric(name[j - 1])) {
                name[i] = '_';
                i += 1;
            }
            name[i] = std.ascii.toLower(name[j]);
            i += 1;
        }
    }
    name[i] = 0;
}

fn colorCid(id: u32) bool {
    return switch (id) {
        V.V4L2_CID_BRIGHTNESS, V.V4L2_CID_CONTRAST, V.V4L2_CID_SATURATION, V.V4L2_CID_HUE, V.V4L2_CID_BLACK_LEVEL, V.V4L2_CID_AUTO_WHITE_BALANCE, V.V4L2_CID_DO_WHITE_BALANCE, V.V4L2_CID_RED_BALANCE, V.V4L2_CID_BLUE_BALANCE, V.V4L2_CID_GAMMA, V.V4L2_CID_EXPOSURE, V.V4L2_CID_AUTOGAIN, V.V4L2_CID_GAIN, V.V4L2_CID_SHARPNESS => true,
        else => false,
    };
}

fn fillControls(s: *Self) void {
    var q = std.mem.zeroes(V.struct_v4l2_queryctrl);
    q.id = V.V4L2_CTRL_FLAG_NEXT_CTRL;
    while (sys.xioctl(s.fd, sys.QUERYCTRL, &q) >= 0) {
        const id = q.id;
        defer q.id = id | V.V4L2_CTRL_FLAG_NEXT_CTRL;
        if (q.flags & V.V4L2_CTRL_FLAG_DISABLED != 0 or q.type == V.V4L2_CTRL_TYPE_CTRL_CLASS) continue;
        q.name[31] = 0;
        normalise(&q.name);
        switch (q.type) {
            V.V4L2_CTRL_TYPE_INTEGER, V.V4L2_CTRL_TYPE_BOOLEAN, V.V4L2_CTRL_TYPE_MENU, V.V4L2_CTRL_TYPE_INTEGER_MENU, V.V4L2_CTRL_TYPE_BITMASK, V.V4L2_CTRL_TYPE_BUTTON, V.V4L2_CTRL_TYPE_STRING => c.g_datalist_id_set_data_full(&s.controls, c.g_quark_from_string(@ptrCast(&q.name)), @ptrFromInt(id), null),
            else => {},
        }
        if (!colorCid(id)) continue;
        const ch: *c.GstColorBalanceChannel = @ptrCast(@alignCast(c.g_object_new(c.gst_color_balance_channel_get_type(), null)));
        ch.label = c.g_strdup(@ptrCast(&q.name));
        switch (q.type) {
            V.V4L2_CTRL_TYPE_INTEGER => {
                ch.min_value = q.minimum;
                ch.max_value = q.maximum;
            },
            V.V4L2_CTRL_TYPE_BOOLEAN => {
                ch.min_value = 0;
                ch.max_value = 1;
            },
            else => {},
        }
        c.g_object_set_data(@ptrCast(ch), "v4l2-cid", @ptrFromInt(id));
        s.colors = c.g_list_append(s.colors, ch);
    }
}

fn getControl(s: *Self, id: u32, value: *c.gint) bool {
    if (!isOpen(s)) return false;
    var ctl = V.struct_v4l2_control{ .id = id, .value = 0 };
    if (sys.xioctl(s.fd, sys.G_CTRL, &ctl) < 0) return false;
    value.* = ctl.value;
    return true;
}

fn setControl(s: *Self, id: u32, value: c.gint) bool {
    if (!isOpen(s)) return false;
    var ctl = V.struct_v4l2_control{ .id = id, .value = value };
    return sys.xioctl(s.fd, sys.S_CTRL, &ctl) >= 0;
}

fn applyExtra(s: *Self) void {
    const st = s.extra orelse return;
    const n = c.gst_structure_n_fields(st);
    var i: c.gint = 0;
    while (i < n) : (i += 1) {
        const name = c.gst_structure_nth_field_name(st, @intCast(i));
        const id = @intFromPtr(c.g_datalist_id_get_data(&s.controls, c.g_quark_from_string(name)));
        if (id == 0) continue;
        const val = c.gst_structure_get_value(st, name);
        var iv: c.GValue = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&iv, c.G_TYPE_INT);
        if (c.g_value_transform(val, &iv) != 0) _ = setControl(s, @intCast(id), c.g_value_get_int(&iv));
        c.g_value_unset(&iv);
    }
}

fn clearLists(s: *Self) void {
    c.g_list_free_full(s.colors, c.g_object_unref);
    s.colors = null;
    c.g_datalist_clear(&s.controls);
}

fn open(s: *Self) bool {
    if (s.device == null) s.device = c.g_strdup("/dev/video");
    var st: V.struct_stat = undefined;
    if (V.stat(s.device, &st) == -1) {
        err(s, c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup_printf(tr("Cannot identify device '%s'."), s.device), sysErr(), CALLS, "gst_v4l2_open", 613);
        return false;
    }
    if (st.st_mode & V.S_IFMT != V.S_IFCHR) {
        err(s, c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup_printf(tr("This isn't a device '%s'."), s.device), sysErr(), CALLS, "gst_v4l2_open", 620);
        return false;
    }
    s.fd = V.open(s.device, V.O_RDWR | V.O_CLOEXEC);
    if (s.fd < 0) {
        err(s, c.GST_RESOURCE_ERROR_OPEN_READ_WRITE, c.g_strdup_printf(tr("Could not open device '%s' for reading and writing."), s.device), sysErr(), CALLS, "gst_v4l2_open", 627);
        return false;
    }
    if (sys.xioctl(s.fd, sys.QUERYCAP, &s.vcap) < 0) {
        err(s, c.GST_RESOURCE_ERROR_SETTINGS, c.g_strdup_printf(tr("Error getting capabilities for device '%s': It isn't a v4l2 driver. Check if it is a v4l1 driver."), s.device), sysErr(), CALLS, "gst_v4l2_get_capabilities", 91);
        close(s);
        return false;
    }
    s.device_caps = if (s.vcap.capabilities & V.V4L2_CAP_DEVICE_CAPS != 0) s.vcap.device_caps else s.vcap.capabilities;
    if (s.device_caps & (V.V4L2_CAP_VIDEO_CAPTURE | V.V4L2_CAP_VIDEO_CAPTURE_MPLANE) == 0) {
        err(s, c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup_printf(tr("Device '%s' is not a capture device."), s.device), c.g_strdup_printf("Capabilities: 0x%x", s.device_caps), CALLS, "gst_v4l2_open", 634);
        close(s);
        return false;
    }
    fillControls(s);
    applyExtra(s);
    var list: std.ArrayListUnmanaged(caps.Desc) = .empty;
    defer list.deinit(std.heap.c_allocator);
    if (!caps.formats(s.fd, &list)) {
        err(s, c.GST_RESOURCE_ERROR_SETTINGS, c.g_strdup_printf(tr("Failed to enumerate possible video formats device '%s' can work with"), s.device), c.g_strdup_printf("Failed to get number %d in pixelformat enumeration for %s. (%d - %s)", @as(c_int, 0), s.device, sys.errno(), c.g_strerror(sys.errno())), OBJ, "gst_v4l2_object_fill_format_list", 1398);
        close(s);
        return false;
    }
    s.n_formats = @min(list.items.len, s.formats.len);
    for (list.items[0..s.n_formats], 0..) |d, i| s.formats[i] = d.fourcc;
    return true;
}

fn close(s: *Self) void {
    if (s.fd >= 0) _ = V.close(s.fd);
    s.fd = -1;
    clearLists(s);
    _ = c.gst_caps_replace(&s.probed, null);
    s.device_caps = 0;
    s.n_formats = 0;
    if (s.par != null and s.keep_aspect != 0) {}
}

fn probedCaps(s: *Self) [*c]c.GstCaps {
    if (s.probed != null) return s.probed;
    if (s.keep_aspect != 0 and s.par == null) {
        var cc = std.mem.zeroes(V.struct_v4l2_cropcap);
        cc.type = V.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        if (sys.xioctl(s.fd, sys.CROPCAP, &cc) < 0) {
            s.par = newPar(1, 1);
        } else if (cc.pixelaspect.numerator != 0 and cc.pixelaspect.denominator != 0) {
            s.par = newPar(@intCast(cc.pixelaspect.numerator), @intCast(cc.pixelaspect.denominator));
        }
    }
    var list: [64]caps.Desc = undefined;
    for (s.formats[0..s.n_formats], 0..) |fc, i| list[i] = .{ .fourcc = fc, .rank = caps.rank(fc) };
    s.probed = caps.probe(s.fd, list[0..s.n_formats], if (s.keep_aspect != 0) s.par else null);
    return s.probed;
}

fn newPar(n: c.gint, d: c.gint) [*c]c.GValue {
    const v: [*c]c.GValue = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GValue))));
    _ = c.g_value_init(v, c.gst_fraction_get_type());
    c.gst_value_set_fraction(v, n, d);
    return v;
}

fn getCaps(bs: [*c]c.GstBaseSrc, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(bs);
    if (!isOpen(s)) return c.gst_pad_get_pad_template_caps(srcpad(s));
    const p = probedCaps(s);
    if (filter != null) return c.gst_caps_intersect_full(filter, p, c.GST_CAPS_INTERSECT_FIRST);
    return c.gst_caps_ref(p);
}

fn fixateStruct(st: *c.GstStructure, pref: *const Pref) void {
    if (c.gst_structure_has_field(st, "width") != 0) _ = c.gst_structure_fixate_field_nearest_int(st, "width", pref.width);
    if (c.gst_structure_has_field(st, "height") != 0) _ = c.gst_structure_fixate_field_nearest_int(st, "height", pref.height);
    if (c.gst_structure_has_field(st, "framerate") != 0) _ = c.gst_structure_fixate_field_nearest_fraction(st, "framerate", pref.fps_n, pref.fps_d);
    const n = c.gst_structure_n_fields(st);
    var i: c.gint = 0;
    while (i < n) : (i += 1) {
        const name = c.gst_structure_nth_field_name(st, @intCast(i));
        const sn = std.mem.span(name);
        if (std.mem.eql(u8, sn, "interlace-mode") or std.mem.eql(u8, sn, "colorimetry")) continue;
        _ = c.gst_structure_fixate_field(st, name);
    }
}

fn parseFixed(st: *c.GstStructure, w: *c.gint, h: *c.gint, fn_: *c.gint, fd: *c.gint) void {
    if (c.gst_structure_has_field(st, "width") != 0) _ = c.gst_structure_get_int(st, "width", w);
    if (c.gst_structure_has_field(st, "height") != 0) _ = c.gst_structure_get_int(st, "height", h);
    if (c.gst_structure_has_field(st, "framerate") != 0) _ = c.gst_structure_get_fraction(st, "framerate", fn_, fd);
}

const Ranked = struct {
    caps: [*c]c.GstCaps,
    fps: c.gint,
    area: c.gint,
};

fn ranked(cp: [*c]c.GstCaps, pref: *const Pref) Ranked {
    var w: c.gint = std.math.maxInt(c.gint);
    var h: c.gint = std.math.maxInt(c.gint);
    var n: c.gint = std.math.maxInt(c.gint);
    var d: c.gint = 1;
    parseFixed(c.gst_caps_get_structure(cp, 0).?, &w, &h, &n, &d);
    const fps = @as(c.gint, @intCast(@abs(@divTrunc(n, d) - @divTrunc(pref.fps_n, pref.fps_d))));
    const area: c.gint = @intCast(@abs(@as(i64, w) *% h - @as(i64, pref.width) * pref.height) & 0x7fffffff);
    return .{ .caps = cp, .fps = fps, .area = area };
}

fn rankLess(_: void, a: Ranked, b: Ranked) bool {
    if (a.fps != b.fps) return a.fps < b.fps;
    return a.area < b.area;
}

fn tryFormat(s: *Self, st: *c.GstStructure) bool {
    const fc = caps.fourccFromAvailable(st, s.formats[0..s.n_formats]);
    if (fc == 0) return false;
    var w: c.gint = 0;
    var h: c.gint = 0;
    _ = c.gst_structure_get_int(st, "width", &w);
    _ = c.gst_structure_get_int(st, "height", &h);
    var fmt = std.mem.zeroes(V.struct_v4l2_format);
    fmt.type = V.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = @intCast(w);
    fmt.fmt.pix.height = @intCast(h);
    fmt.fmt.pix.pixelformat = fc;
    fmt.fmt.pix.field = V.V4L2_FIELD_NONE;
    if (sys.xioctl(s.fd, sys.TRY_FMT, &fmt) < 0) {
        return sys.errno() == V.ENOTTY;
    }
    return fmt.fmt.pix.pixelformat == fc;
}

fn fixate(s: *Self, input: [*c]c.GstCaps, pref: *const Pref) [*c]c.GstCaps {
    var list: std.ArrayListUnmanaged(Ranked) = .empty;
    defer list.deinit(std.heap.c_allocator);
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(input)) : (i += 1) {
        const tmp = c.gst_caps_copy_nth(input, i);
        fixateStruct(c.gst_caps_get_structure(tmp, 0).?, pref);
        list.append(std.heap.c_allocator, ranked(tmp, pref)) catch c.gst_caps_unref(tmp);
    }
    c.gst_caps_unref(input);
    std.sort.insertion(Ranked, list.items, {}, rankLess);
    var sorted = c.gst_caps_new_empty();
    for (list.items) |r| c.gst_caps_append(sorted, r.caps);
    sorted = c.gst_caps_normalize(sorted);
    defer c.gst_caps_unref(sorted);
    i = 0;
    while (i < c.gst_caps_get_size(sorted)) : (i += 1) {
        const fcaps = c.gst_caps_copy_nth(sorted, i);
        if (tryFormat(s, c.gst_caps_get_structure(fcaps, 0).?)) return fcaps;
        c.gst_caps_unref(fcaps);
    }
    err(s, c.GST_RESOURCE_ERROR_SETTINGS, c.g_strdup_printf(tr("Device '%s' does not support video capture"), s.device), c.g_strdup("Call to TRY_FMT failed for every negotiated format"), OBJ, "gst_v4l2_object_try_format", 4400);
    return null;
}

fn negotiate(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(bs);
    var pref = Pref{};
    const this = c.gst_pad_query_caps(srcpad(s), null);
    if (this == null or c.gst_caps_is_any(this) != 0) {
        if (this != null) c.gst_caps_unref(this);
        return 1;
    }
    const peer = c.gst_pad_peer_query_caps(srcpad(s), null);
    defer if (peer != null) c.gst_caps_unref(peer);
    var cp: [*c]c.GstCaps = undefined;
    if (peer != null and c.gst_caps_is_any(peer) == 0) {
        cp = c.gst_caps_intersect_full(peer, this, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(this);
    } else cp = this;
    if (c.gst_caps_is_empty(cp) != 0) {
        c.gst_caps_unref(cp);
        return 0;
    }
    if (peer != null and c.gst_caps_is_any(peer) == 0) {
        const ps = c.gst_structure_copy(c.gst_caps_get_structure(peer, 0));
        fixateStruct(ps, &pref);
        parseFixed(ps, &pref.width, &pref.height, &pref.fps_n, &pref.fps_d);
        c.gst_structure_free(ps);
    }
    const fixed = fixate(s, cp, &pref);
    if (fixed == null) return 0;
    defer c.gst_caps_unref(fixed);
    if (c.gst_caps_is_any(fixed) != 0) return 1;
    if (c.gst_caps_is_fixed(fixed) == 0) return 0;
    return c.gst_base_src_set_caps(bs, fixed);
}

fn stopStreaming(s: *Self) void {
    if (s.streaming != 0) {
        var t: c_int = V.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        _ = sys.xioctl(s.fd, sys.STREAMOFF, &t);
        s.streaming = 0;
    }
    for (s.bufs[0..s.nbuf]) |*b| {
        if (b.start) |p| _ = V.munmap(p, b.len);
        b.* = .{ .start = null, .len = 0 };
    }
    if (s.nbuf != 0 and isOpen(s)) {
        var rb = std.mem.zeroes(V.struct_v4l2_requestbuffers);
        rb.type = V.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        rb.memory = V.V4L2_MEMORY_MMAP;
        _ = sys.xioctl(s.fd, sys.REQBUFS, &rb);
    }
    s.nbuf = 0;
}

fn planeHeight(finfo: [*c]const c.GstVideoFormatInfo, plane: c.guint, h: c.gint) c.gint {
    var comps: [c.GST_VIDEO_MAX_COMPONENTS]c.gint = undefined;
    c.gst_video_format_info_component(finfo, plane, &comps);
    const comp: usize = @intCast(@max(comps[0], 0));
    const sub: u5 = @intCast(finfo[0].h_sub[comp]);
    return -((-h) >> sub);
}

fn setLayout(s: *Self, stride: u32, size: u32) void {
    const info = &s.info;
    const finfo = info.finfo;
    const n = finfo[0].n_planes;
    info.stride[0] = @intCast(stride);
    info.offset[0] = 0;
    var p: c.guint = 1;
    while (p < n) : (p += 1) {
        info.stride[p] = c.gst_video_format_info_extrapolate_stride(finfo, @intCast(p), @intCast(stride));
        info.offset[p] = info.offset[p - 1] + @as(usize, @intCast(info.stride[p - 1])) * @as(usize, @intCast(planeHeight(finfo, p - 1, info.height)));
    }
    if (size > info.size) info.size = size;
}

fn setCaps(bs: [*c]c.GstBaseSrc, cp: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(bs);
    stopStreaming(s);
    c.g_signal_emit(s, sig_prepare, 0, s.fd, cp);
    const st = c.gst_caps_get_structure(cp, 0).?;
    const fc = caps.fourccFromAvailable(st, s.formats[0..s.n_formats]);
    if (fc == 0) return 0;
    var w: c.gint = 0;
    var h: c.gint = 0;
    var fn_: c.gint = 0;
    var fd: c.gint = 1;
    _ = c.gst_structure_get_int(st, "width", &w);
    _ = c.gst_structure_get_int(st, "height", &h);
    _ = c.gst_structure_get_fraction(st, "framerate", &fn_, &fd);
    var fmt = std.mem.zeroes(V.struct_v4l2_format);
    fmt.type = V.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = @intCast(w);
    fmt.fmt.pix.height = @intCast(h);
    fmt.fmt.pix.pixelformat = fc;
    fmt.fmt.pix.field = V.V4L2_FIELD_NONE;
    if (sys.xioctl(s.fd, sys.S_FMT, &fmt) < 0) {
        err(s, c.GST_RESOURCE_ERROR_SETTINGS, c.g_strdup_printf(tr("Device '%s' does not support video capture"), s.device), c.g_strdup_printf("Call to S_FMT failed for %" ++ "u" ++ "x%u: %s", fmt.fmt.pix.width, fmt.fmt.pix.height, c.g_strerror(sys.errno())), OBJ, "gst_v4l2_object_set_format_full", 4720);
        return 0;
    }
    if (fmt.fmt.pix.width != @as(u32, @intCast(w)) or fmt.fmt.pix.height != @as(u32, @intCast(h)) or fmt.fmt.pix.pixelformat != fc) {
        err(s, c.GST_RESOURCE_ERROR_SETTINGS, c.g_strdup_printf(tr("Device '%s' cannot capture at %dx%d"), s.device, w, h), c.g_strdup_printf("Tried to capture at %dx%d, but device returned size %dx%d", w, h, fmt.fmt.pix.width, fmt.fmt.pix.height), OBJ, "gst_v4l2_object_set_format_full", 4740);
        return 0;
    }
    if (fn_ > 0) {
        var parm = std.mem.zeroes(V.struct_v4l2_streamparm);
        parm.type = V.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        if (sys.xioctl(s.fd, sys.G_PARM, &parm) >= 0 and parm.parm.capture.capability & V.V4L2_CAP_TIMEPERFRAME != 0) {
            parm.parm.capture.timeperframe.numerator = @intCast(fd);
            parm.parm.capture.timeperframe.denominator = @intCast(fn_);
            _ = sys.xioctl(s.fd, sys.S_PARM, &parm);
        }
    }
    s.fourcc = fc;
    s.raw = @intFromBool(c.gst_structure_has_name(st, "video/x-raw") != 0);
    if (s.raw != 0) {
        if (c.gst_video_info_from_caps(&s.info, cp) == 0) return 0;
        setLayout(s, fmt.fmt.pix.bytesperline, fmt.fmt.pix.sizeimage);
    } else {
        c.gst_video_info_init(&s.info);
        s.info.size = fmt.fmt.pix.sizeimage;
    }
    s.duration = if (fn_ > 0) c.gst_util_uint64_scale_int(c.GST_SECOND, fd, fn_) else NONE;
    var rb = std.mem.zeroes(V.struct_v4l2_requestbuffers);
    rb.count = NBUF;
    rb.type = V.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    rb.memory = V.V4L2_MEMORY_MMAP;
    if (sys.xioctl(s.fd, sys.REQBUFS, &rb) < 0 or rb.count == 0) {
        err(s, c.GST_RESOURCE_ERROR_READ, c.g_strdup_printf(tr("Could not map buffers from device '%s'"), s.device), c.g_strdup_printf("Failed to create buffer pool: %s", c.g_strerror(sys.errno())), OBJ, "gst_v4l2_object_setup_pool", 3523);
        return 0;
    }
    s.nbuf = @min(rb.count, MAXBUF);
    var i: u32 = 0;
    while (i < s.nbuf) : (i += 1) {
        var b = std.mem.zeroes(V.struct_v4l2_buffer);
        b.type = V.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V.V4L2_MEMORY_MMAP;
        b.index = i;
        if (sys.xioctl(s.fd, sys.QUERYBUF, &b) < 0) break;
        const p = V.mmap(null, b.length, V.PROT_READ | V.PROT_WRITE, V.MAP_SHARED, s.fd, @intCast(b.m.offset));
        if (p == V.MAP_FAILED) break;
        s.bufs[i] = .{ .start = p, .len = b.length };
        if (sys.xioctl(s.fd, sys.QBUF, &b) < 0) break;
    }
    if (i != s.nbuf) {
        err(s, c.GST_RESOURCE_ERROR_READ, c.g_strdup_printf(tr("Could not map buffers from device '%s'"), s.device), c.g_strdup_printf("Failed to create buffer pool: %s", c.g_strerror(sys.errno())), OBJ, "gst_v4l2_object_setup_pool", 3523);
        stopStreaming(s);
        return 0;
    }
    var t: c_int = V.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (sys.xioctl(s.fd, sys.STREAMON, &t) < 0) {
        err(s, c.GST_RESOURCE_ERROR_FAILED, c.g_strdup_printf(tr("Error starting streaming capture from device '%s'."), s.device), sysErr(), "../sys/v4l2/gstv4l2bufferpool.c", "gst_v4l2_buffer_pool_streamon", 680);
        stopStreaming(s);
        return 0;
    }
    s.streaming = 1;
    return 1;
}

fn wait(s: *Self) c_int {
    var fds = [2]V.struct_pollfd{ .{ .fd = s.fd, .events = V.POLLIN | V.POLLPRI, .revents = 0 }, .{ .fd = s.wake, .events = V.POLLIN, .revents = 0 } };
    while (true) {
        const n = V.poll(&fds, 2, -1);
        if (n < 0 and sys.errno() == V.EINTR) continue;
        if (n < 0) return -1;
        if (fds[1].revents & V.POLLIN != 0) return 1;
        if (fds[0].revents & V.POLLERR != 0) return -1;
        return 0;
    }
}

fn clockTime(s: *Self) [2]u64 {
    cm.lock(s);
    const clk = s.parent.parent.element.clock;
    const base = s.parent.parent.element.base_time;
    if (clk != null) _ = c.gst_object_ref(clk);
    cm.unlock(s);
    if (clk == null) return .{ NONE, NONE };
    const now = c.gst_clock_get_time(clk);
    c.gst_object_unref(clk);
    return .{ now, @bitCast(base) };
}

fn monotonic() u64 {
    var ts: V.struct_timespec = undefined;
    _ = V.clock_gettime(V.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * c.GST_SECOND + @as(u64, @intCast(ts.tv_nsec));
}

fn create(ps: [*c]c.GstPushSrc, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(ps);
    if (s.streaming == 0) return c.GST_FLOW_FLUSHING;
    var b = std.mem.zeroes(V.struct_v4l2_buffer);
    while (true) {
        switch (wait(s)) {
            1 => return c.GST_FLOW_FLUSHING,
            -1 => {
                err(s, c.GST_RESOURCE_ERROR_READ, c.g_strdup_printf(tr("Failed to read from device '%s'."), s.device), sysErr(), "../sys/v4l2/gstv4l2bufferpool.c", "gst_v4l2_buffer_pool_poll", 1500);
                return c.GST_FLOW_ERROR;
            },
            else => {},
        }
        b = std.mem.zeroes(V.struct_v4l2_buffer);
        b.type = V.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V.V4L2_MEMORY_MMAP;
        if (sys.xioctl(s.fd, sys.DQBUF, &b) < 0) {
            if (sys.errno() == V.EAGAIN) continue;
            err(s, c.GST_RESOURCE_ERROR_READ, c.g_strdup_printf(tr("Failed to read from device '%s'."), s.device), sysErr(), "../sys/v4l2/gstv4l2bufferpool.c", "gst_v4l2_buffer_pool_dqbuf", 1900);
            return c.GST_FLOW_ERROR;
        }
        if (b.flags & V.V4L2_BUF_FLAG_ERROR != 0 or b.bytesused == 0) {
            _ = sys.xioctl(s.fd, sys.QBUF, &b);
            continue;
        }
        break;
    }
    const mapped = s.bufs[b.index];
    const used: usize = if (s.raw != 0) @min(@max(b.bytesused, @as(u32, @intCast(@min(s.info.size, mapped.len)))), mapped.len) else @min(b.bytesused, mapped.len);
    const buf = c.gst_buffer_new_allocate(null, used, null);
    _ = c.gst_buffer_fill(buf, 0, mapped.start, used);
    _ = sys.xioctl(s.fd, sys.QBUF, &b);
    if (s.raw != 0) {
        const info = &s.info;
        _ = c.gst_buffer_add_video_meta_full(buf, c.GST_VIDEO_FRAME_FLAG_NONE, info.finfo[0].format, @intCast(info.width), @intCast(info.height), info.finfo[0].n_planes, &info.offset, &info.stride);
    }
    var ts: u64 = NONE;
    if (b.flags & V.V4L2_BUF_FLAG_TIMESTAMP_MASK == V.V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC) ts = @as(u64, @intCast(b.timestamp.tv_sec)) * c.GST_SECOND + @as(u64, @intCast(b.timestamp.tv_usec)) * c.GST_USECOND;
    const ct = clockTime(s);
    var delay: u64 = if (s.duration != NONE) s.duration else 0;
    if (s.bad_ts == 0 and ts != NONE) {
        const now = monotonic();
        if (ts > now or s.last_ts > ts or now - ts > ts) {
            s.bad_ts = 1;
        } else {
            s.last_ts = ts;
            delay = now - ts;
        }
    }
    var stamp: u64 = NONE;
    if (ct[0] != NONE) {
        stamp = ct[0] - ct[1];
        stamp = if (stamp > delay) stamp - delay else 0;
    }
    buf[0].offset = s.offset;
    buf[0].offset_end = s.offset + 1;
    s.offset += 1;
    buf[0].pts = stamp;
    buf[0].dts = NONE;
    buf[0].duration = s.duration;
    out[0] = buf;
    return c.GST_FLOW_OK;
}

fn query(bs: [*c]c.GstBaseSrc, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(bs);
    if (q[0].type == c.GST_QUERY_LATENCY) {
        if (!isOpen(s) or s.duration == NONE) return 0;
        const max: u64 = if (s.nbuf == 0) NONE else s.nbuf * s.duration;
        c.gst_query_set_latency(q, 1, s.duration, max);
        return 1;
    }
    return parent_bs.query.?(bs, q);
}

fn start(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(bs);
    s.offset = 0;
    s.bad_ts = 0;
    s.last_ts = 0;
    return 1;
}

fn stop(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    stopStreaming(me(bs));
    return 1;
}

fn unlock(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const one: u64 = 1;
    _ = V.write(me(bs).wake, &one, 8);
    return 1;
}

fn unlockStop(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(bs);
    var v: u64 = 0;
    _ = V.read(s.wake, &v, 8);
    s.last_ts = 0;
    return 1;
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    if (t == c.GST_STATE_CHANGE_NULL_TO_READY and !open(s)) return c.GST_STATE_CHANGE_FAILURE;
    const r = parent_el.change_state.?(e, t);
    if (t == c.GST_STATE_CHANGE_READY_TO_NULL) close(s);
    return r;
}

fn cidOf(id: c.guint) u32 {
    return switch (id) {
        @intFromEnum(Prop.brightness) => V.V4L2_CID_BRIGHTNESS,
        @intFromEnum(Prop.contrast) => V.V4L2_CID_CONTRAST,
        @intFromEnum(Prop.saturation) => V.V4L2_CID_SATURATION,
        else => V.V4L2_CID_HUE,
    };
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.device) => {
            c.g_free(s.device);
            s.device = c.g_value_dup_string(v);
        },
        @intFromEnum(Prop.brightness), @intFromEnum(Prop.contrast), @intFromEnum(Prop.saturation), @intFromEnum(Prop.hue) => _ = setControl(s, cidOf(id), c.g_value_get_int(v)),
        @intFromEnum(Prop.norm) => s.norm = c.g_value_get_enum(v),
        @intFromEnum(Prop.io_mode) => s.io_mode = c.g_value_get_enum(v),
        @intFromEnum(Prop.extra_controls) => {
            if (s.extra) |x| c.gst_structure_free(x);
            const st = c.gst_value_get_structure(v);
            s.extra = if (st != null) c.gst_structure_copy(st) else null;
            if (isOpen(s)) applyExtra(s);
        },
        @intFromEnum(Prop.pixel_aspect_ratio) => {
            if (s.par != null) {
                c.g_value_unset(s.par);
                c.g_free(s.par);
            }
            s.par = newPar(1, 1);
            if (c.g_value_transform(v, s.par) == 0) {
                c.g_log(null, c.G_LOG_LEVEL_WARNING, "Could not transform string to aspect ratio");
                c.gst_value_set_fraction(s.par, 1, 1);
            }
        },
        @intFromEnum(Prop.force_aspect_ratio) => s.keep_aspect = c.g_value_get_boolean(v),
        @intFromEnum(Prop.crop_top) => s.crop[0] = c.g_value_get_uint(v),
        @intFromEnum(Prop.crop_left) => s.crop[1] = c.g_value_get_uint(v),
        @intFromEnum(Prop.crop_bottom) => s.crop[2] = c.g_value_get_uint(v),
        @intFromEnum(Prop.crop_right) => s.crop[3] = c.g_value_get_uint(v),
        else => cm.warnInvalid(FILE, o, id, spec, 333),
    }
}

fn rectValue(v: [*c]c.GValue, r: V.struct_v4l2_rect) void {
    var x = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&x, c.G_TYPE_INT);
    _ = c.g_value_reset(v);
    for ([_]c.gint{ r.left, r.top, @intCast(r.width), @intCast(r.height) }) |n| {
        c.g_value_set_int(&x, n);
        c.gst_value_array_append_value(v, &x);
    }
    c.g_value_unset(&x);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.device) => c.g_value_set_string(v, s.device),
        @intFromEnum(Prop.device_name) => c.g_value_set_string(v, if (isOpen(s)) @as([*c]const u8, @ptrCast(&s.vcap.card)) else null),
        @intFromEnum(Prop.device_fd) => c.g_value_set_int(v, if (isOpen(s)) s.fd else -1),
        @intFromEnum(Prop.flags) => {
            var fl: c.guint = 0;
            if (isOpen(s)) {
                fl |= s.device_caps & (V.V4L2_CAP_VIDEO_CAPTURE | V.V4L2_CAP_VIDEO_OUTPUT | V.V4L2_CAP_VIDEO_OVERLAY | V.V4L2_CAP_VBI_CAPTURE | V.V4L2_CAP_VBI_OUTPUT | V.V4L2_CAP_TUNER | V.V4L2_CAP_AUDIO);
                if (s.device_caps & V.V4L2_CAP_VIDEO_CAPTURE_MPLANE != 0) fl |= V.V4L2_CAP_VIDEO_CAPTURE;
                if (s.device_caps & V.V4L2_CAP_VIDEO_OUTPUT_MPLANE != 0) fl |= V.V4L2_CAP_VIDEO_OUTPUT;
            }
            c.g_value_set_flags(v, fl);
        },
        @intFromEnum(Prop.brightness), @intFromEnum(Prop.contrast), @intFromEnum(Prop.saturation), @intFromEnum(Prop.hue) => {
            var val: c.gint = 0;
            if (getControl(s, cidOf(id), &val)) c.g_value_set_int(v, val);
        },
        @intFromEnum(Prop.norm) => c.g_value_set_enum(v, s.norm),
        @intFromEnum(Prop.io_mode) => c.g_value_set_enum(v, s.io_mode),
        @intFromEnum(Prop.extra_controls) => c.gst_value_set_structure(v, s.extra),
        @intFromEnum(Prop.pixel_aspect_ratio) => if (s.par != null) {
            _ = c.g_value_transform(s.par, v);
        },
        @intFromEnum(Prop.force_aspect_ratio) => c.g_value_set_boolean(v, s.keep_aspect),
        @intFromEnum(Prop.crop_top) => c.g_value_set_uint(v, s.crop[0]),
        @intFromEnum(Prop.crop_left) => c.g_value_set_uint(v, s.crop[1]),
        @intFromEnum(Prop.crop_bottom) => c.g_value_set_uint(v, s.crop[2]),
        @intFromEnum(Prop.crop_right) => c.g_value_set_uint(v, s.crop[3]),
        @intFromEnum(Prop.crop_bounds) => rectValue(v, s.bounds),
        else => cm.warnInvalid(FILE, o, id, spec, 386),
    }
}

fn uriType(_: c.GType) callconv(.c) c.GstURIType {
    return c.GST_URI_SRC;
}

fn uriProtocols(_: c.GType) callconv(.c) [*c]const [*c]const c.gchar {
    const P = struct {
        var list = [_][*c]const c.gchar{ "v4l2", null };
    };
    return &P.list;
}

fn uriGet(h: ?*c.GstURIHandler) callconv(.c) [*c]c.gchar {
    const s = me(h);
    if (s.device != null) return c.g_strdup_printf("v4l2://%s", s.device);
    return c.g_strdup("v4l2://");
}

fn uriSet(h: ?*c.GstURIHandler, uri: [*c]const c.gchar, _: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const dev: [*c]const u8 = if (std.mem.eql(u8, std.mem.span(uri), "v4l2://")) "/dev/video0" else uri + 7;
    c.g_object_set(h, "device", dev, @as(?*anyopaque, null));
    return 1;
}

fn uriInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstURIHandlerInterface = @ptrCast(@alignCast(iface));
    i.get_type = uriType;
    i.get_protocols = uriProtocols;
    i.get_uri = uriGet;
    i.set_uri = uriSet;
}

fn listChannels(b: ?*c.GstColorBalance) callconv(.c) [*c]const c.GList {
    return me(b).colors;
}

fn cidOfChannel(ch: [*c]c.GstColorBalanceChannel) u32 {
    return @intCast(@intFromPtr(c.g_object_get_data(@ptrCast(ch), "v4l2-cid")));
}

fn balanceSet(b: ?*c.GstColorBalance, ch: [*c]c.GstColorBalanceChannel, value: c.gint) callconv(.c) void {
    _ = setControl(me(b), cidOfChannel(ch), value);
}

fn balanceGet(b: ?*c.GstColorBalance, ch: [*c]c.GstColorBalanceChannel) callconv(.c) c.gint {
    var v: c.gint = 0;
    _ = getControl(me(b), cidOfChannel(ch), &v);
    return v;
}

fn balanceType(_: ?*c.GstColorBalance) callconv(.c) c.GstColorBalanceType {
    return c.GST_COLOR_BALANCE_HARDWARE;
}

fn balanceInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstColorBalanceInterface = @ptrCast(@alignCast(iface));
    i.list_channels = listChannels;
    i.set_value = balanceSet;
    i.get_value = balanceGet;
    i.get_balance_type = balanceType;
}

fn getFlip(o: ?*c.GstVideoOrientation, cid: u32, flip: [*c]c.gboolean) c.gboolean {
    var v: c.gint = 0;
    if (!getControl(me(o), cid, &v)) return 0;
    flip[0] = @intFromBool(v != 0);
    return 1;
}

fn getHflip(o: ?*c.GstVideoOrientation, flip: [*c]c.gboolean) callconv(.c) c.gboolean {
    return getFlip(o, V.V4L2_CID_HFLIP, flip);
}

fn getVflip(o: ?*c.GstVideoOrientation, flip: [*c]c.gboolean) callconv(.c) c.gboolean {
    return getFlip(o, V.V4L2_CID_VFLIP, flip);
}

fn setHflip(o: ?*c.GstVideoOrientation, flip: c.gboolean) callconv(.c) c.gboolean {
    return @intFromBool(setControl(me(o), V.V4L2_CID_HFLIP, flip));
}

fn setVflip(o: ?*c.GstVideoOrientation, flip: c.gboolean) callconv(.c) c.gboolean {
    return @intFromBool(setControl(me(o), V.V4L2_CID_VFLIP, flip));
}

fn getCenter(o: ?*c.GstVideoOrientation, cid: u32, center: [*c]c.gint) c.gboolean {
    return @intFromBool(getControl(me(o), cid, center));
}

fn getHcenter(o: ?*c.GstVideoOrientation, center: [*c]c.gint) callconv(.c) c.gboolean {
    return getCenter(o, V.V4L2_CID_PAN_RESET, center);
}

fn getVcenter(o: ?*c.GstVideoOrientation, center: [*c]c.gint) callconv(.c) c.gboolean {
    return getCenter(o, V.V4L2_CID_TILT_RESET, center);
}

fn setHcenter(o: ?*c.GstVideoOrientation, center: c.gint) callconv(.c) c.gboolean {
    return @intFromBool(setControl(me(o), V.V4L2_CID_PAN_RESET, center));
}

fn setVcenter(o: ?*c.GstVideoOrientation, center: c.gint) callconv(.c) c.gboolean {
    return @intFromBool(setControl(me(o), V.V4L2_CID_TILT_RESET, center));
}

fn orientationInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstVideoOrientationInterface = @ptrCast(@alignCast(iface));
    i.get_hflip = getHflip;
    i.get_vflip = getVflip;
    i.get_hcenter = getHcenter;
    i.get_vcenter = getVcenter;
    i.set_hflip = setHflip;
    i.set_vflip = setVflip;
    i.set_hcenter = setHcenter;
    i.set_vcenter = setVcenter;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    stopStreaming(s);
    close(s);
    _ = V.close(s.wake);
    c.g_free(s.device);
    if (s.par != null) {
        c.g_value_unset(s.par);
        c.g_free(s.par);
    }
    if (s.extra) |x| c.gst_structure_free(x);
    parent_obj.finalize.?(o);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.fd = -1;
    s.device = c.g_strdup("/dev/video0");
    s.keep_aspect = 1;
    s.wake = V.eventfd(0, V.EFD_CLOEXEC | V.EFD_NONBLOCK);
    s.duration = NONE;
    c.gst_base_src_set_format(@ptrCast(s), c.GST_FORMAT_TIME);
    c.gst_base_src_set_live(@ptrCast(s), 1);
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
    const CTL = RW | c.GST_PARAM_CONTROLLABLE;
    const MAXI = std.math.maxInt(c.gint);
    const MINI = std.math.minInt(c.gint);
    c.g_object_class_install_property(oc, @intFromEnum(Prop.device), c.g_param_spec_string("device", "Device", "Device location", "/dev/video0", RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.device_name), c.g_param_spec_string("device-name", "Device name", "Name of the device", null, RO));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.device_fd), c.g_param_spec_int("device-fd", "File descriptor", "File descriptor of the device", -1, MAXI, -1, RO));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.flags), c.g_param_spec_flags("flags", "Flags", "Device type flags", deviceFlagsType(), 0, RO));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.brightness), c.g_param_spec_int("brightness", "Brightness", "Picture brightness, or more precisely, the black level", MINI, MAXI, 0, CTL));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.contrast), c.g_param_spec_int("contrast", "Contrast", "Picture contrast or luma gain", MINI, MAXI, 0, CTL));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.saturation), c.g_param_spec_int("saturation", "Saturation", "Picture color saturation or chroma gain", MINI, MAXI, 0, CTL));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.hue), c.g_param_spec_int("hue", "Hue", "Hue or color balance", MINI, MAXI, 0, CTL));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.norm), c.g_param_spec_enum("norm", "TV norm", "video standard", normType(), 0, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.io_mode), c.g_param_spec_enum("io-mode", "IO mode", "I/O mode", ioModeType(), 0, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.extra_controls), c.g_param_spec_boxed("extra-controls", "Extra Controls", "Extra v4l2 controls (CIDs) for the device", c.gst_structure_get_type(), RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.pixel_aspect_ratio), c.g_param_spec_string("pixel-aspect-ratio", "Pixel Aspect Ratio", "Overwrite the pixel aspect ratio of the device", "1/1", RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.force_aspect_ratio), c.g_param_spec_boolean("force-aspect-ratio", "Force aspect ratio", "When enabled, the pixel aspect ratio will be enforced", 1, RW));
    c.gst_type_mark_as_plugin_api(deviceFlagsType(), 0);
    c.gst_type_mark_as_plugin_api(normType(), 0);
    c.gst_type_mark_as_plugin_api(ioModeType(), 0);
    c.g_object_class_install_property(oc, @intFromEnum(Prop.crop_top), c.g_param_spec_uint("crop-top", "Crop top", "Pixels to crop at top of video capture input", 0, std.math.maxInt(c.guint), 0, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.crop_left), c.g_param_spec_uint("crop-left", "Crop left", "Pixels to crop at left of video capture input", 0, std.math.maxInt(c.guint), 0, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.crop_bottom), c.g_param_spec_uint("crop-bottom", "Crop bottom", "Pixels to crop at bottom of video capture input", 0, std.math.maxInt(c.guint), 0, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.crop_right), c.g_param_spec_uint("crop-right", "Crop right", "Pixels to crop at right of video capture input", 0, std.math.maxInt(c.guint), 0, RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.crop_bounds), c.gst_param_spec_array("crop-bounds", "Crop bounds", "The bounding region for crop rectangles ('<x, y, width, height>').", c.g_param_spec_int("rect-value", "Rectangle Value", "One of x, y, width or height value.", MINI, MAXI, -1, RO), RO));
    sig_prepare = c.g_signal_new("prepare-format", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, 2, c.G_TYPE_INT, c.gst_caps_get_type());
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Video (video4linux2) Source", "Source/Video", "Reads frames from a Video4Linux2 device", "Edgard Lima <edgard.lima@gmail.com>, Stefan Kost <ensonic@users.sf.net>");
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, c.gst_caps_from_string(TEMPLATE)));
    ec.change_state = changeState;
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.get_caps = getCaps;
    bc.set_caps = setCaps;
    bc.start = start;
    bc.unlock = unlock;
    bc.unlock_stop = unlockStop;
    bc.stop = stop;
    bc.query = query;
    bc.negotiate = negotiate;
    const pc: *c.GstPushSrcClass = @ptrCast(@alignCast(k));
    pc.create = create;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_push_src_get_type(), "GstV4l2Src", Class, Self, classInit, init);
            const ui = c.GInterfaceInfo{ .interface_init = uriInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_uri_handler_get_type(), &ui);
            const ti = c.GInterfaceInfo{ .interface_init = tuner.init, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, tuner.getType(), &ti);
            const bi = c.GInterfaceInfo{ .interface_init = balanceInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_color_balance_get_type(), &bi);
            const oi = c.GInterfaceInfo{ .interface_init = orientationInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_video_orientation_get_type(), &oi);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    cat = c._gst_debug_category_new("v4l2src", 0, "V4L2 source element");
    return c.gst_element_register(p, "v4l2src", c.GST_RANK_PRIMARY, getType()) != 0;
}
