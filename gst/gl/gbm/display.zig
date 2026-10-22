const std = @import("std");
const c = @import("../../c.zig").c;
const gtype = @import("../../gtype.zig");
const display = @import("../display.zig");
const utils = @import("utils.zig");

pub const Gbm = extern struct {
    parent: c.GstGLDisplay,
    drm_fd: c_int,
    resources: [*c]c.drmModeRes,
    connector: [*c]c.drmModeConnector,
    mode: [*c]c.drmModeModeInfo,
    crtc_index: c_int,
    crtc_id: u32,
    gbm_dev: ?*c.struct_gbm_device,
};

var once: gtype.Once = .{};
var parent: ?*c.GObjectClass = null;
var debug_done: usize = 0;

fn g(p: anytype) *Gbm {
    return @ptrCast(@alignCast(p));
}

fn handle(d: [*c]c.GstGLDisplay) callconv(.c) c.guintptr {
    return @intFromPtr(g(d).gbm_dev);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const d = g(o);
    shutdownGbm(d);
    shutdownDrm(d);
    if (d.drm_fd >= 0) _ = c.close(d.drm_fd);
    parent.?.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GstGLDisplayClass, @ptrCast(@alignCast(k))).get_handle = handle;
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const d = g(inst);
    d.parent.type = c.GST_GL_DISPLAY_TYPE_GBM;
    d.drm_fd = -1;
}

pub fn typeGet() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return gtype.object(display.gst_gl_display_get_type, "GstGLDisplayGBM", c.GstGLDisplayClass, Gbm, classInit, init, 0);
        }
    }.f);
}

fn crtcForEncoder(d: *Gbm, enc: *const c.drmModeEncoder) u32 {
    const r = d.resources;
    var i: usize = 0;
    while (i < @as(usize, @intCast(r[0].count_crtcs))) : (i += 1) {
        if (enc.possible_crtcs & (@as(u32, 1) << @intCast(i)) != 0) return r[0].crtcs[i];
    }
    return 0;
}

fn crtcForConnector(d: *Gbm) u32 {
    const con = d.connector;
    var i: usize = 0;
    while (i < @as(usize, @intCast(con[0].count_encoders))) : (i += 1) {
        const enc = c.drmModeGetEncoder(d.drm_fd, con[0].encoders[i]);
        if (enc != null) {
            const id = crtcForEncoder(d, @ptrCast(enc));
            c.drmModeFreeEncoder(enc);
            if (id != 0) return id;
        }
    }
    return 0;
}

fn connectorName(con: *const c.drmModeConnector) [*c]const u8 {
    return switch (con.connector_type) {
        c.DRM_MODE_CONNECTOR_Unknown => "Unknown",
        c.DRM_MODE_CONNECTOR_VGA => "VGA",
        c.DRM_MODE_CONNECTOR_DVII => "DVI-I",
        c.DRM_MODE_CONNECTOR_DVID => "DVI-D",
        c.DRM_MODE_CONNECTOR_DVIA => "DVI-A",
        c.DRM_MODE_CONNECTOR_Composite => "Composite",
        c.DRM_MODE_CONNECTOR_SVIDEO => "S-Video",
        c.DRM_MODE_CONNECTOR_LVDS => "LVDS",
        c.DRM_MODE_CONNECTOR_Component => "Component",
        c.DRM_MODE_CONNECTOR_9PinDIN => "9-Pin DIN",
        c.DRM_MODE_CONNECTOR_DisplayPort => "DP",
        c.DRM_MODE_CONNECTOR_HDMIA => "HDMI-A",
        c.DRM_MODE_CONNECTOR_HDMIB => "HDMI-B",
        c.DRM_MODE_CONNECTOR_TV => "TV",
        c.DRM_MODE_CONNECTOR_eDP => "eDP",
        c.DRM_MODE_CONNECTOR_VIRTUAL => "Virtual",
        c.DRM_MODE_CONNECTOR_DSI => "DSI",
        c.DRM_MODE_CONNECTOR_DPI => "DPI",
        else => "<unknown>",
    };
}

fn setupDrm(d: *Gbm, wanted: [*c]const u8) bool {
    d.resources = c.drmModeGetResources(d.drm_fd);
    if (d.resources == null) return fail(d);
    const r = d.resources;
    var picked: [*c]c.drmModeConnector = null;
    var i: usize = 0;
    while (i < @as(usize, @intCast(r[0].count_connectors))) : (i += 1) {
        const cand = c.drmModeGetConnector(d.drm_fd, r[0].connectors[i]);
        if (cand == null) continue;
        const name = c.g_strdup_printf("%s-%i", connectorName(@ptrCast(cand)), cand[0].connector_type_id);
        defer c.g_free(name);
        if (wanted != null and c.g_ascii_strcasecmp(wanted, name) != 0) {
            c.drmModeFreeConnector(cand);
            continue;
        }
        if (cand[0].connection == c.DRM_MODE_CONNECTED) {
            picked = cand;
            break;
        }
        c.drmModeFreeConnector(cand);
    }
    if (picked == null) return fail(d);
    d.connector = picked;
    var area: c_int = -1;
    var preferred = false;
    i = 0;
    while (i < @as(usize, @intCast(picked[0].count_modes))) : (i += 1) {
        const m = &picked[0].modes[i];
        const a = @as(c_int, m.hdisplay) * @as(c_int, m.vdisplay);
        const pref = m.type & c.DRM_MODE_TYPE_PREFERRED != 0;
        if (!preferred and (pref or a > area)) {
            d.mode = m;
            area = a;
            if (pref) preferred = true;
        }
    }
    if (d.mode == null) return fail(d);
    var selected: [*c]c.drmModeEncoder = null;
    i = 0;
    while (i < @as(usize, @intCast(r[0].count_encoders))) : (i += 1) {
        const enc = c.drmModeGetEncoder(d.drm_fd, r[0].encoders[i]);
        if (selected == null and enc != null and enc[0].encoder_id == picked[0].encoder_id) {
            selected = enc;
        } else if (enc != null) c.drmModeFreeEncoder(enc);
    }
    if (selected == null) {
        d.crtc_id = crtcForConnector(d);
    } else {
        d.crtc_id = selected[0].crtc_id;
        c.drmModeFreeEncoder(selected);
    }
    if (d.crtc_id == 0) return fail(d);
    i = 0;
    while (i < @as(usize, @intCast(r[0].count_crtcs))) : (i += 1) {
        if (r[0].crtcs[i] == d.crtc_id) {
            d.crtc_index = @intCast(i);
            break;
        }
    }
    if (d.crtc_index < 0) return fail(d);
    return true;
}

fn fail(d: *Gbm) bool {
    shutdownDrm(d);
    return false;
}

fn shutdownDrm(d: *Gbm) void {
    d.mode = null;
    d.crtc_index = -1;
    d.crtc_id = 0;
    if (d.connector != null) {
        c.drmModeFreeConnector(d.connector);
        d.connector = null;
    }
    if (d.resources != null) {
        c.drmModeFreeResources(d.resources);
        d.resources = null;
    }
}

fn shutdownGbm(d: *Gbm) void {
    if (d.gbm_dev) |dev| {
        c.gbm_device_destroy(dev);
        d.gbm_dev = null;
    }
}

pub fn new() ?*c.GstGLDisplay {
    if (c.g_once_init_enter(&debug_done) != 0) {
        _ = c._gst_debug_get_category("gldisplay");
        _ = c._gst_debug_category_new("gleglgbm", 0, "Mesa3D EGL GBM debugging");
        c.g_once_init_leave(&debug_done, 1);
    }
    var fd: c_int = -1;
    if (c.g_getenv("GST_GL_GBM_DRM_DEVICE")) |node| {
        fd = c.open(node, c.O_RDWR | c.O_CLOEXEC);
        if (fd < 0) return null;
    } else {
        fd = utils.findDrmNode();
        if (fd < 0) return null;
    }
    const d = g(c.g_object_new(typeGet(), @as([*c]const u8, null)));
    d.drm_fd = fd;
    _ = setupDrm(d, c.g_getenv("GST_GL_GBM_DRM_CONNECTOR"));
    d.gbm_dev = c.gbm_create_device(fd);
    if (d.gbm_dev == null) {
        shutdownGbm(d);
        shutdownDrm(d);
        c.gst_object_unref(d);
        if (fd >= 0) _ = c.close(fd);
        return null;
    }
    return @ptrCast(d);
}
