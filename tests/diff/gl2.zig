const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [131072]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn z(p: [*c]const u8) []const u8 {
    return if (p == null) "-" else std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

fn capsStr(label: []const u8, cp: [*c]c.GstCaps) void {
    if (cp == null) {
        out("{s} NULL", .{label});
        return;
    }
    const s = c.gst_caps_to_string(cp);
    out("{s} {s}", .{ label, z(s) });
    c.g_free(s);
}

fn caps(s: [*c]const u8) [*c]c.GstCaps {
    return c.gst_caps_from_string(s);
}

fn sizes() void {
    const types = [_]struct { n: []const u8, t: *const fn () callconv(.c) c.GType }{
        .{ .n = "mixer", .t = c.gst_gl_mixer_get_type },
        .{ .n = "mixerpad", .t = c.gst_gl_mixer_pad_get_type },
        .{ .n = "basemixer", .t = c.gst_gl_base_mixer_get_type },
        .{ .n = "basemixerpad", .t = c.gst_gl_base_mixer_pad_get_type },
        .{ .n = "filter", .t = c.gst_gl_filter_get_type },
        .{ .n = "basefilter", .t = c.gst_gl_base_filter_get_type },
        .{ .n = "basesrc", .t = c.gst_gl_base_src_get_type },
        .{ .n = "upload", .t = c.gst_gl_upload_get_type },
        .{ .n = "colorconvert", .t = c.gst_gl_color_convert_get_type },
        .{ .n = "viewconvert", .t = c.gst_gl_view_convert_get_type },
        .{ .n = "overlay", .t = c.gst_gl_overlay_compositor_get_type },
        .{ .n = "bufferpool", .t = c.gst_gl_buffer_pool_get_type },
        .{ .n = "shader", .t = c.gst_gl_shader_get_type },
    };
    for (types) |t| {
        var q: c.GTypeQuery = undefined;
        const ty = t.t();
        c.g_type_query(ty, &q);
        out("type {s} {s} parent={s} class={d} inst={d} abstract={d}", .{ t.n, z(q.type_name), z(c.g_type_name(c.g_type_parent(ty))), q.class_size, q.instance_size, @intFromBool(c.g_type_test_flags(ty, c.G_TYPE_FLAG_ABSTRACT) != 0) });
    }
    out("enum {s} {s}", .{ z(c.g_type_name(c.gst_gl_stereo_downmix_mode_get_type())), z(c.g_type_name(c.gst_gl_upload_return_get_type())) });
    const vc = c.g_type_class_ref(c.gst_gl_view_convert_get_type());
    var n: c.guint = 0;
    const specs = c.g_object_class_list_properties(@ptrCast(@alignCast(vc)), &n);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const p = specs[i];
        var dv = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&dv, p[0].value_type);
        c.g_param_value_set_default(p, &dv);
        const ds = c.g_strdup_value_contents(&dv);
        out("prop {s} {s} flags={d} default={s} blurb={s}", .{ z(p[0].name), z(c.g_type_name(p[0].value_type)), p[0].flags, z(ds), z(c.g_param_spec_get_blurb(p)) });
        c.g_free(ds);
        c.g_value_unset(&dv);
    }
    c.g_free(@ptrCast(specs));
    c.g_type_class_unref(vc);
}

const SYS = [_][*c]const u8{
    "video/x-raw, format=I420, width=16, height=8, framerate=30/1",
    "video/x-raw, format=(string){ NV12, RGBA, YUY2 }, width=16, height=8",
    "video/x-raw(memory:GLMemory), format=RGBA, width=16, height=8, texture-target=2D",
    "video/x-raw(memory:GLMemory), format=(string){ RGBA, I420, v210 }, width=[1,100], height=8, texture-target=(string){ 2D, rectangle }",
    "video/x-raw(memory:DMABuf), format=DMA_DRM, drm-format=NV12, width=16, height=8",
    "video/x-raw(memory:GLMemory, meta:GstVideoOverlayComposition), format=NV12, width=16, height=8",
    "video/x-raw(ANY), format=GRAY8, width=4, height=4",
    "video/x-raw(meta:GstVideoGLTextureUploadMeta), format=RGBA, width=8, height=8",
    "video/x-raw, format=(string){ RGBx, Y444, P010_10LE, GRAY16_LE, v210 }, width=16, height=8, colorimetry=bt709, chroma-site=mpeg2",
    "video/x-raw(memory:GLMemory), format=YUY2, width=8, height=8, texture-target=external-oes",
    "ANY",
    "EMPTY",
};

fn uploadCaps(ctx: [*c]c.GstGLContext, label: []const u8) void {
    const u = c.gst_gl_upload_new(ctx);
    for (SYS, 0..) |s, i| {
        const cp = caps(s);
        for ([_]c.GstPadDirection{ c.GST_PAD_SINK, c.GST_PAD_SRC }) |d| {
            const r = c.gst_gl_upload_transform_caps(u, ctx, d, cp, null);
            var lb: [64]u8 = undefined;
            capsStr(std.fmt.bufPrint(&lb, "{s} up {d} {d}", .{ label, i, d }) catch "x", r);
            if (r != null) c.gst_caps_unref(r);
        }
        c.gst_caps_unref(cp);
    }
    const fx = [_][2][*c]const u8{
        .{ "video/x-raw, format=I420, width=16, height=8", "video/x-raw(memory:GLMemory), format=(string){ I420, RGBA }, width=[1,32], height=[1,32], texture-target=(string){ rectangle, 2D }" },
        .{ "video/x-raw, format=I420, width=16, height=8", "video/x-raw(memory:GLMemory), format=I420, width=16, height=8; video/x-raw, format=I420, width=16, height=8" },
        .{ "video/x-raw, format=I420, width=16, height=8", "video/x-raw(memory:GLMemory), format=I420, width=16, height=8, texture-target=external-oes" },
    };
    for (fx, 0..) |p, i| {
        const a = caps(p[0]);
        const r = c.gst_gl_upload_fixate_caps(u, c.GST_PAD_SINK, a, caps(p[1]));
        var lb: [64]u8 = undefined;
        capsStr(std.fmt.bufPrint(&lb, "{s} fix {d}", .{ label, i }) catch "x", r);
        c.gst_caps_unref(r);
        const r2 = c.gst_gl_upload_fixate_caps(u, c.GST_PAD_SRC, a, caps(p[1]));
        capsStr(std.fmt.bufPrint(&lb, "{s} fixsrc {d}", .{ label, i }) catch "x", r2);
        c.gst_caps_unref(r2);
        c.gst_caps_unref(a);
    }
    if (ctx == null) {
        c.gst_object_unref(u);
        return;
    }
    var q = c.gst_query_new_allocation(caps("video/x-raw, format=RGBA, width=16, height=8, framerate=30/1"), 1);
    c.gst_gl_upload_propose_allocation(u, null, q);
    out("{s} propose pools={d} params={d} metas={d}", .{ label, c.gst_query_get_n_allocation_pools(q), c.gst_query_get_n_allocation_params(q), c.gst_query_get_n_allocation_metas(q) });
    var i: c.guint = 0;
    while (i < c.gst_query_get_n_allocation_metas(q)) : (i += 1) out("{s} meta {s}", .{ label, z(c.g_type_name(c.gst_query_parse_nth_allocation_meta(q, i, null))) });
    c.gst_query_unref(q);
    q = c.gst_query_new_allocation(caps("video/x-raw(memory:GLMemory), format=RGBA, width=16, height=8, framerate=30/1"), 1);
    c.gst_gl_upload_propose_allocation(u, null, q);
    out("{s} propose gl pools={d} params={d} metas={d}", .{ label, c.gst_query_get_n_allocation_pools(q), c.gst_query_get_n_allocation_params(q), c.gst_query_get_n_allocation_metas(q) });
    c.gst_query_unref(q);
    c.gst_object_unref(u);
}

fn colorCaps(ctx: [*c]c.GstGLContext, label: []const u8) void {
    for (SYS, 0..) |s, i| {
        const cp = caps(s);
        for ([_]c.GstPadDirection{ c.GST_PAD_SINK, c.GST_PAD_SRC }) |d| {
            const r = c.gst_gl_color_convert_transform_caps(ctx, d, cp, null);
            var lb: [64]u8 = undefined;
            capsStr(std.fmt.bufPrint(&lb, "{s} cc {d} {d}", .{ label, i, d }) catch "x", r);
            c.gst_caps_unref(r);
        }
        c.gst_caps_unref(cp);
    }
    const fx = [_][2][*c]const u8{
        .{ "video/x-raw(memory:GLMemory), format=I420, width=16, height=8, texture-target=2D", "video/x-raw(memory:GLMemory), format=(string){ BGRA, NV12, RGBA, GRAY8 }, width=16, height=8, texture-target=(string){ 2D, rectangle }" },
        .{ "video/x-raw(memory:GLMemory), format=RGBA, width=16, height=8", "video/x-raw(memory:GLMemory), format=(string){ I420, NV12, Y444, AYUV }, width=16, height=8" },
        .{ "video/x-raw(memory:GLMemory), format=NV12, width=16, height=8, texture-target=external-oes", "video/x-raw(memory:GLMemory), format=(string){ NV12, RGBA }, width=16, height=8, texture-target=(string){ external-oes, 2D }" },
        .{ "video/x-raw(memory:GLMemory), format=GRAY16_LE, width=16, height=8", "video/x-raw(memory:GLMemory), format=(string){ GRAY8, RGB, ARGB64 }, width=16, height=8" },
    };
    for (fx, 0..) |p, i| {
        for ([_]c.GstPadDirection{ c.GST_PAD_SINK, c.GST_PAD_SRC }) |d| {
            const a = caps(p[0]);
            const r = c.gst_gl_color_convert_fixate_caps(ctx, d, a, caps(p[1]));
            var lb: [64]u8 = undefined;
            capsStr(std.fmt.bufPrint(&lb, "{s} ccfix {d} {d}", .{ label, i, d }) catch "x", r);
            c.gst_caps_unref(r);
            c.gst_caps_unref(a);
        }
    }
}

fn viewCaps() void {
    const v = c.gst_gl_view_convert_new();
    const ins = [_][*c]const u8{
        "video/x-raw(memory:GLMemory), format=RGBA, width=16, height=8, texture-target=2D",
        "video/x-raw(memory:GLMemory), format=RGBA, width=32, height=8, multiview-mode=side-by-side, pixel-aspect-ratio=1/1, texture-target=2D",
        "video/x-raw(memory:GLMemory), format=RGBA, width=16, height=16, multiview-mode=top-bottom, multiview-flags=0x4000/0xffffffff, pixel-aspect-ratio=2/1",
        "video/x-raw(memory:GLMemory), format=RGBA, width=[16,64], height=8, framerate=[1/1,60/1], multiview-mode=(string){ mono, separated }",
        "video/x-raw, format=RGBA, width=16, height=8",
    };
    for (ins, 0..) |s, i| {
        for ([_]c.GstPadDirection{ c.GST_PAD_SINK, c.GST_PAD_SRC }) |d| {
            const cp = caps(s);
            const r = c.gst_gl_view_convert_transform_caps(v, d, cp, null);
            var lb: [64]u8 = undefined;
            capsStr(std.fmt.bufPrint(&lb, "vc {d} {d}", .{ i, d }) catch "x", r);
            if (r != null and c.gst_caps_is_empty(r) == 0) {
                const f = c.gst_gl_view_convert_fixate_caps(v, d, cp, c.gst_caps_ref(r));
                capsStr(std.fmt.bufPrint(&lb, "vcfix {d} {d}", .{ i, d }) catch "x", f);
                c.gst_caps_unref(f);
            }
            if (r != null) c.gst_caps_unref(r);
            c.gst_caps_unref(cp);
        }
    }
    c.g_object_set(v, "output-mode-override", @as(c_int, c.GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE), "input-mode-override", @as(c_int, c.GST_VIDEO_MULTIVIEW_MODE_TOP_BOTTOM), "downmix-mode", @as(c_int, 1), @as(?*anyopaque, null));
    for (ins[0..2], 0..) |s, i| {
        for ([_]c.GstPadDirection{ c.GST_PAD_SINK, c.GST_PAD_SRC }) |d| {
            const cp = caps(s);
            const r = c.gst_gl_view_convert_transform_caps(v, d, cp, null);
            var lb: [64]u8 = undefined;
            capsStr(std.fmt.bufPrint(&lb, "vco {d} {d}", .{ i, d }) catch "x", r);
            if (r != null and c.gst_caps_is_empty(r) == 0) {
                const f = c.gst_gl_view_convert_fixate_caps(v, d, cp, c.gst_caps_ref(r));
                capsStr(std.fmt.bufPrint(&lb, "vcofix {d} {d}", .{ i, d }) catch "x", f);
                c.gst_caps_unref(f);
            }
            if (r != null) c.gst_caps_unref(r);
            c.gst_caps_unref(cp);
        }
    }
    var m: c_int = 0;
    var dm: c_int = 0;
    c.g_object_get(v, "output-mode-override", &m, "downmix-mode", &dm, @as(?*anyopaque, null));
    out("vc props {d} {d}", .{ m, dm });
    c.gst_object_unref(v);
}

fn fill(buf: [*c]c.GstBuffer, seed: u32) void {
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(buf, &map, c.GST_MAP_WRITE) == 0) return;
    var x: u32 = seed;
    for (0..map.size) |i| {
        x = x *% 1103515245 +% 12345;
        map.data[i] = @truncate(x >> 16);
    }
    c.gst_buffer_unmap(buf, &map);
}

fn frameSum(label: []const u8, buf: [*c]c.GstBuffer, info: *c.GstVideoInfo) void {
    var f: c.GstVideoFrame = undefined;
    if (c.gst_video_frame_map(&f, info, buf, c.GST_MAP_READ) == 0) {
        out("{s} map failed", .{label});
        return;
    }
    var p: c.guint = 0;
    while (p < info.finfo[0].n_planes) : (p += 1) {
        const fi = info.finfo;
        var comp: usize = 0;
        while (comp < fi[0].n_components and fi[0].plane[comp] != p) comp += 1;
        if (comp == fi[0].n_components) comp = 0;
        const hh: c_int = info.height;
        const ww: c_int = info.width;
        const ph: usize = @intCast(-((-hh) >> @intCast(fi[0].h_sub[comp])));
        const stride: usize = @intCast(f.info.stride[p]);
        var row: usize = @as(usize, @intCast(-((-ww) >> @intCast(fi[0].w_sub[comp])))) * @as(usize, @intCast(fi[0].pixel_stride[comp]));
        if (row == 0 or row > stride) row = stride;
        const data: [*]const u8 = @ptrCast(f.data[p]);
        var s: u64 = 0;
        var first: [8]u8 = undefined;
        for (0..ph) |y| {
            for (0..row) |x| s = s *% 31 +% data[y * stride + x];
        }
        for (0..8) |k| first[k] = data[k];
        out("{s} plane {d} {d}x{d} sum={d} head={any}", .{ label, p, row, ph, s, first });
    }
    c.gst_video_frame_unmap(&f);
}

fn convert(ctx: [*c]c.GstGLContext, in_fmt: []const u8, out_fmt: []const u8, w: c_int, h: c_int, extra: []const u8) void {
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    var b3: [256]u8 = undefined;
    const sys_s = std.fmt.bufPrintZ(&b1, "video/x-raw, format={s}, width={d}, height={d}, framerate=30/1{s}", .{ in_fmt, w, h, extra }) catch return;
    const gin_s = std.fmt.bufPrintZ(&b2, "video/x-raw(memory:GLMemory), format={s}, width={d}, height={d}, framerate=30/1, texture-target=2D{s}", .{ in_fmt, w, h, extra }) catch return;
    const gout_s = std.fmt.bufPrintZ(&b3, "video/x-raw(memory:GLMemory), format={s}, width={d}, height={d}, framerate=30/1, texture-target=2D{s}", .{ out_fmt, w, h, extra }) catch return;
    const sys = caps(sys_s.ptr);
    const gin = caps(gin_s.ptr);
    const gout = caps(gout_s.ptr);
    defer c.gst_caps_unref(sys);
    defer c.gst_caps_unref(gin);
    defer c.gst_caps_unref(gout);
    var info: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_from_caps(&info, sys);
    var oinfo: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_from_caps(&oinfo, gout);
    const u = c.gst_gl_upload_new(ctx);
    defer c.gst_object_unref(u);
    out("conv {s}->{s} upcaps {d}", .{ in_fmt, out_fmt, c.gst_gl_upload_set_caps(u, sys, gin) });
    const in = c.gst_buffer_new_allocate(null, info.size, null);
    fill(in, 7);
    in[0].pts = 1234;
    var up: [*c]c.GstBuffer = null;
    const r = c.gst_gl_upload_perform_with_buffer(u, in, &up);
    out("conv {s}->{s} upload ret={d} mems={d} pts={d}", .{ in_fmt, out_fmt, r, if (up != null) c.gst_buffer_n_memory(up) else 0, if (up != null) up[0].pts else 0 });
    c.gst_buffer_unref(in);
    if (up == null) return;
    var label: [64]u8 = undefined;
    frameSum(std.fmt.bufPrint(&label, "conv {s} uploaded", .{in_fmt}) catch "x", up, &info);
    const up2 = c.gst_gl_upload_new(ctx);
    _ = c.gst_gl_upload_set_caps(up2, gin, gin);
    var again: [*c]c.GstBuffer = null;
    const r2 = c.gst_gl_upload_perform_with_buffer(up2, up, &again);
    out("conv reupload ret={d} same={d}", .{ r2, @intFromBool(again == up) });
    if (again != null) c.gst_buffer_unref(again);
    c.gst_object_unref(up2);
    const cc = c.gst_gl_color_convert_new(ctx);
    defer c.gst_object_unref(cc);
    out("conv {s}->{s} cccaps {d} pass={d}", .{ in_fmt, out_fmt, c.gst_gl_color_convert_set_caps(cc, gin, gout), cc[0].passthrough });
    const o = c.gst_gl_color_convert_perform(cc, up);
    c.gst_buffer_unref(up);
    out("conv {s}->{s} out={d} mems={d}", .{ in_fmt, out_fmt, @intFromBool(o != null), if (o != null) c.gst_buffer_n_memory(o) else 0 });
    if (o == null) return;
    frameSum(std.fmt.bufPrint(&label, "conv {s}->{s}", .{ in_fmt, out_fmt }) catch "x", o, &oinfo);
    c.gst_buffer_unref(o);
}

fn viewPerform(ctx: [*c]c.GstGLContext, in_s: [*c]const u8, out_s: [*c]const u8, w: c_int, h: c_int) void {
    const gin = caps(in_s);
    const gout = caps(out_s);
    defer c.gst_caps_unref(gin);
    defer c.gst_caps_unref(gout);
    var b1: [128]u8 = undefined;
    const sys = caps((std.fmt.bufPrintZ(&b1, "video/x-raw, format=RGBA, width={d}, height={d}, framerate=30/1", .{ w, h }) catch return).ptr);
    defer c.gst_caps_unref(sys);
    var info: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_from_caps(&info, sys);
    const u = c.gst_gl_upload_new(ctx);
    defer c.gst_object_unref(u);
    const plain = caps((std.fmt.bufPrintZ(&b1, "video/x-raw(memory:GLMemory), format=RGBA, width={d}, height={d}, framerate=30/1, texture-target=2D", .{ w, h }) catch return).ptr);
    defer c.gst_caps_unref(plain);
    _ = c.gst_gl_upload_set_caps(u, sys, plain);
    const in = c.gst_buffer_new_allocate(null, info.size, null);
    fill(in, 3);
    var up: [*c]c.GstBuffer = null;
    _ = c.gst_gl_upload_perform_with_buffer(u, in, &up);
    c.gst_buffer_unref(in);
    if (up == null) return;
    const v = c.gst_gl_view_convert_new();
    defer c.gst_object_unref(v);
    c.gst_gl_view_convert_set_context(v, ctx);
    out("view caps {d}", .{c.gst_gl_view_convert_set_caps(v, gin, gout)});
    const o = c.gst_gl_view_convert_perform(v, up);
    c.gst_buffer_unref(up);
    out("view out={d} flags={d}", .{ @intFromBool(o != null), if (o != null) o[0].mini_object.flags else 0 });
    if (o == null) return;
    var oinfo: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_from_caps(&oinfo, gout);
    frameSum("view", o, &oinfo);
    c.gst_buffer_unref(o);
}

pub fn main() void {
    _ = c.setenv("GST_GL_WINDOW", "surfaceless", 1);
    _ = c.setenv("GST_GL_PLATFORM", "egl", 1);
    _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
    _ = c.setenv("EGL_PLATFORM", "surfaceless", 1);
    c.gst_init(null, null);
    sizes();
    capsStr("template", c.gst_gl_upload_get_input_template_caps());
    uploadCaps(null, "noctx");
    colorCaps(null, "noctx");
    viewCaps();
    const sw = c.gst_gl_color_convert_swizzle_shader_string(null);
    const yr = c.gst_gl_color_convert_yuv_to_rgb_shader_string(null);
    out("strings {d} {d}", .{ std.mem.len(@as([*:0]const u8, @ptrCast(sw))), std.mem.len(@as([*:0]const u8, @ptrCast(yr))) });
    c.g_free(sw);
    c.g_free(yr);
    const d = c.gst_gl_display_new();
    const ctx = c.gst_gl_context_new(d);
    var err: [*c]c.GError = null;
    if (ctx == null or c.gst_gl_context_create(ctx, null, &err) == 0) {
        out("no context", .{});
        return;
    }
    uploadCaps(ctx, "ctx");
    colorCaps(ctx, "ctx");
    const pairs = [_][2][]const u8{
        .{ "RGBA", "RGBA" },
        .{ "I420", "RGBA" },
        .{ "NV12", "RGBA" },
        .{ "NV21", "BGRx" },
        .{ "YUY2", "RGBA" },
        .{ "UYVY", "ARGB" },
        .{ "AYUV", "RGBA" },
        .{ "GRAY8", "RGBA" },
        .{ "GRAY16_LE", "RGBA" },
        .{ "RGBA", "I420" },
        .{ "RGBA", "NV12" },
        .{ "RGBA", "Y444" },
        .{ "RGBA", "AYUV" },
        .{ "RGBA", "YUY2" },
        .{ "BGRA", "GRAY8" },
        .{ "RGBx", "BGRA" },
        .{ "I420", "NV12" },
        .{ "Y42B", "I420" },
        .{ "I420", "YUY2" },
        .{ "GBR", "RGBA" },
        .{ "RGBA", "RGBP" },
        .{ "RGB16", "RGBA" },
        .{ "A420", "RGBA" },
        .{ "Y444", "A444" },
        .{ "v210", "RGBA" },
        .{ "RGBA", "v210" },
    };
    for (pairs) |p| convert(ctx, p[0], p[1], 16, 8, "");
    convert(ctx, "I420", "RGBA", 16, 8, ", colorimetry=bt709");
    convert(ctx, "NV12", "RGBA", 16, 8, ", colorimetry=bt601");
    convert(ctx, "RGBA", "I420", 16, 8, ", colorimetry=bt2020");
    viewPerform(ctx, "video/x-raw(memory:GLMemory), format=RGBA, width=32, height=8, framerate=30/1, multiview-mode=side-by-side, texture-target=2D", "video/x-raw(memory:GLMemory), format=RGBA, width=16, height=8, framerate=30/1, multiview-mode=mono, texture-target=2D", 32, 8);
    viewPerform(ctx, "video/x-raw(memory:GLMemory), format=RGBA, width=16, height=16, framerate=30/1, multiview-mode=top-bottom, texture-target=2D", "video/x-raw(memory:GLMemory), format=RGBA, width=32, height=8, framerate=30/1, multiview-mode=side-by-side, texture-target=2D", 16, 16);
    viewPerform(ctx, "video/x-raw(memory:GLMemory), format=RGBA, width=16, height=8, framerate=30/1, texture-target=2D", "video/x-raw(memory:GLMemory), format=RGBA, width=16, height=8, framerate=30/1, texture-target=2D", 16, 8);
    viewPerform(ctx, "video/x-raw(memory:GLMemory), format=RGBA, width=32, height=8, framerate=30/1, multiview-mode=side-by-side, multiview-flags=0x1/0xffffffff, texture-target=2D", "video/x-raw(memory:GLMemory), format=RGBA, width=16, height=8, framerate=30/1, multiview-mode=mono, texture-target=2D", 32, 8);
    c.gst_object_unref(ctx);
    c.gst_object_unref(d);
    out("done", .{});
}
