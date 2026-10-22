const std = @import("std");
const c = @import("../../c.zig").c;

pub const Fb = extern struct {
    bo: ?*c.struct_gbm_bo,
    fb_id: u32,
};

fn canonical(f: u32) u32 {
    if (f == c.GBM_BO_FORMAT_XRGB8888) return c.GBM_FORMAT_XRGB8888;
    if (f == c.GBM_BO_FORMAT_ARGB8888) return c.GBM_FORMAT_ARGB8888;
    return f;
}

pub fn depth(format: u32) c_int {
    return switch (canonical(format)) {
        c.GBM_FORMAT_C8, c.GBM_FORMAT_RGB332, c.GBM_FORMAT_BGR233 => 8,
        c.GBM_FORMAT_NV12, c.GBM_FORMAT_XRGB4444, c.GBM_FORMAT_XBGR4444, c.GBM_FORMAT_RGBX4444, c.GBM_FORMAT_BGRX4444 => 12,
        c.GBM_FORMAT_XRGB1555, c.GBM_FORMAT_XBGR1555, c.GBM_FORMAT_RGBX5551, c.GBM_FORMAT_BGRX5551 => 15,
        c.GBM_FORMAT_ARGB4444, c.GBM_FORMAT_ABGR4444, c.GBM_FORMAT_RGBA4444, c.GBM_FORMAT_BGRA4444, c.GBM_FORMAT_ARGB1555, c.GBM_FORMAT_ABGR1555, c.GBM_FORMAT_RGBA5551, c.GBM_FORMAT_BGRA5551, c.GBM_FORMAT_RGB565, c.GBM_FORMAT_BGR565, c.GBM_FORMAT_YUYV, c.GBM_FORMAT_YVYU, c.GBM_FORMAT_UYVY, c.GBM_FORMAT_VYUY => 16,
        c.GBM_FORMAT_RGB888, c.GBM_FORMAT_BGR888, c.GBM_FORMAT_XRGB8888, c.GBM_FORMAT_XBGR8888, c.GBM_FORMAT_RGBX8888, c.GBM_FORMAT_BGRX8888, c.GBM_FORMAT_AYUV => 24,
        c.GBM_FORMAT_XRGB2101010, c.GBM_FORMAT_XBGR2101010, c.GBM_FORMAT_RGBX1010102, c.GBM_FORMAT_BGRX1010102 => 30,
        c.GBM_FORMAT_ARGB8888, c.GBM_FORMAT_ABGR8888, c.GBM_FORMAT_RGBA8888, c.GBM_FORMAT_BGRA8888, c.GBM_FORMAT_ARGB2101010, c.GBM_FORMAT_ABGR2101010, c.GBM_FORMAT_RGBA1010102, c.GBM_FORMAT_BGRA1010102 => 32,
        else => 0,
    };
}

pub fn bpp(format: u32) c_int {
    return switch (canonical(format)) {
        c.GBM_FORMAT_C8, c.GBM_FORMAT_RGB332, c.GBM_FORMAT_BGR233 => 8,
        c.GBM_FORMAT_NV12 => 12,
        c.GBM_FORMAT_XRGB4444, c.GBM_FORMAT_XBGR4444, c.GBM_FORMAT_RGBX4444, c.GBM_FORMAT_BGRX4444, c.GBM_FORMAT_ARGB4444, c.GBM_FORMAT_ABGR4444, c.GBM_FORMAT_RGBA4444, c.GBM_FORMAT_BGRA4444, c.GBM_FORMAT_XRGB1555, c.GBM_FORMAT_XBGR1555, c.GBM_FORMAT_RGBX5551, c.GBM_FORMAT_BGRX5551, c.GBM_FORMAT_ARGB1555, c.GBM_FORMAT_ABGR1555, c.GBM_FORMAT_RGBA5551, c.GBM_FORMAT_BGRA5551, c.GBM_FORMAT_RGB565, c.GBM_FORMAT_BGR565, c.GBM_FORMAT_YUYV, c.GBM_FORMAT_YVYU, c.GBM_FORMAT_UYVY, c.GBM_FORMAT_VYUY => 16,
        c.GBM_FORMAT_RGB888, c.GBM_FORMAT_BGR888 => 24,
        c.GBM_FORMAT_XRGB8888, c.GBM_FORMAT_XBGR8888, c.GBM_FORMAT_RGBX8888, c.GBM_FORMAT_BGRX8888, c.GBM_FORMAT_ARGB8888, c.GBM_FORMAT_ABGR8888, c.GBM_FORMAT_RGBA8888, c.GBM_FORMAT_BGRA8888, c.GBM_FORMAT_XRGB2101010, c.GBM_FORMAT_XBGR2101010, c.GBM_FORMAT_RGBX1010102, c.GBM_FORMAT_BGRX1010102, c.GBM_FORMAT_ARGB2101010, c.GBM_FORMAT_ABGR2101010, c.GBM_FORMAT_RGBA1010102, c.GBM_FORMAT_BGRA1010102, c.GBM_FORMAT_AYUV => 32,
        else => 0,
    };
}

fn fbDestroy(bo: ?*c.struct_gbm_bo, data: ?*anyopaque) callconv(.c) void {
    const fd = c.gbm_device_get_fd(c.gbm_bo_get_device(bo));
    const fb: *Fb = @ptrCast(@alignCast(data));
    if (fb.fb_id != 0) _ = c.drmModeRmFB(fd, fb.fb_id);
    c.g_free(fb);
}

pub fn fbFromBo(bo: ?*c.struct_gbm_bo) ?*Fb {
    if (c.gbm_bo_get_user_data(bo)) |p| return @ptrCast(@alignCast(p));
    const fd = c.gbm_device_get_fd(c.gbm_bo_get_device(bo));
    const fb: *Fb = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Fb))));
    fb.bo = bo;
    const format = c.gbm_bo_get_format(bo);
    if (c.drmModeAddFB(fd, c.gbm_bo_get_width(bo), c.gbm_bo_get_height(bo), @intCast(depth(format)), @intCast(bpp(format)), c.gbm_bo_get_stride(bo), c.gbm_bo_get_handle(bo).u32, &fb.fb_id) != 0) {
        c.g_free(fb);
        return null;
    }
    c.gbm_bo_set_user_data(bo, fb, fbDestroy);
    return fb;
}

pub fn findDrmNode() c_int {
    var subsystems = [_][*c]const u8{ "drm", null };
    var fd: c_int = -1;
    const client = c.g_udev_client_new(@ptrCast(&subsystems)) orelse return -1;
    defer c.g_object_unref(client);
    const en = c.g_udev_enumerator_new(client) orelse return -1;
    defer c.g_object_unref(en);
    _ = c.g_udev_enumerator_add_match_subsystem(en, "drm");
    const list = c.g_udev_enumerator_execute(en) orelse return -1;
    defer c.g_list_free_full(list, c.g_object_unref);
    var e: ?*c.GList = list;
    while (e) |n| : (e = n.next) {
        const node = c.g_udev_device_get_device_file(@ptrCast(@alignCast(n.data)));
        if (node == null or c.g_str_has_prefix(node, "/dev/dri/card") == 0) continue;
        fd = c.open(node, c.O_RDWR | c.O_CLOEXEC);
        if (fd < 0) continue;
        break;
    }
    return fd;
}
