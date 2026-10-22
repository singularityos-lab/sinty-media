const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");
const img = @import("img.zig").p;

const FILE = "../ext/gl/gstgloverlay.c";
const PROFILE = c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY;
const FLAGS = c.GST_PARAM_CONTROLLABLE | c.GST_PARAM_MUTABLE_PLAYING | cm.RW;

const VERT = "attribute vec4 a_position;\nattribute vec2 a_texcoord;\nvarying vec2 v_texcoord;\nvoid main()\n{\n   gl_Position = a_position;\n   v_texcoord = a_texcoord;\n}";
const FRAG = "uniform sampler2D texture;\nuniform float alpha;\nvarying vec2 v_texcoord;\nvoid main()\n{\n  vec4 rgba = texture2D( texture, v_texcoord );\n  gl_FragColor = vec4(rgba.rgb, rgba.a * alpha);\n}\n";

const Prop = enum(c.guint) { location = 1, offset_x, offset_y, relative_x, relative_y, overlay_width, overlay_height, alpha };

const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

const Self = extern struct {
    filter: c.GstGLFilter,
    location: [*c]u8,
    offset_x: c.gint,
    offset_y: c.gint,
    relative_x: f64,
    relative_y: f64,
    overlay_width: c.gint,
    overlay_height: c.gint,
    alpha: f64,
    shader: ?*c.GstGLShader,
    image_memory: [*c]c.GstGLMemory,
    location_has_changed: c.gboolean,
    window_width: c.gint,
    window_height: c.gint,
    image_width: c.gint,
    image_height: c.gint,
    geometry_change: c.gboolean,
    vao: c.GLuint,
    overlay_vao: c.GLuint,
    vbo: c.GLuint,
    overlay_vbo: c.GLuint,
    vbo_indices: c.GLuint,
    attr_position: c.GLuint,
    attr_texture: c.GLuint,
};

const Class = extern struct {
    parent: c.GstGLFilterClass,
};

var once: cm.Once = .{};
var parent_gl: *c.GstGLBaseFilterClass = undefined;
var parent_obj: *c.GObjectClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn gl(s: *Self) *c.GstGLFuncs {
    return @ptrCast(@alignCast(el.base(s).context[0].gl_vtable));
}

fn glStart(bf: [*c]c.GstGLBaseFilter) callconv(.c) c.gboolean {
    const s = me(bf);
    if (parent_gl.gl_start.?(bf) == 0) return 0;
    const frag = c.g_strdup_printf("%s%s", c.gst_gl_shader_string_get_highest_precision(bf[0].context, c.GST_GLSL_VERSION_NONE, PROFILE), FRAG);
    defer c.g_free(frag);
    return el.genShader(bf[0].context, VERT, frag, &s.shader);
}

fn deleteArray(g: *c.GstGLFuncs, v: *c.GLuint) void {
    if (v.* != 0) g.DeleteVertexArrays.?(1, v);
    v.* = 0;
}

fn deleteBuffer(g: *c.GstGLFuncs, v: *c.GLuint) void {
    if (v.* != 0) g.DeleteBuffers.?(1, v);
    v.* = 0;
}

fn glStop(bf: [*c]c.GstGLBaseFilter) callconv(.c) void {
    const s = me(bf);
    const g = gl(s);
    if (s.shader != null) c.gst_object_unref(s.shader);
    s.shader = null;
    if (s.image_memory != null) {
        c.gst_memory_unref(@ptrCast(s.image_memory));
        s.image_memory = null;
        s.location_has_changed = 1;
    }
    deleteArray(g, &s.vao);
    deleteBuffer(g, &s.vbo);
    deleteBuffer(g, &s.vbo_indices);
    deleteArray(g, &s.overlay_vao);
    deleteBuffer(g, &s.overlay_vbo);
    parent_gl.gl_stop.?(bf);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_free(me(o).location);
    parent_obj.finalize.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.location) => {
            c.g_free(s.location);
            s.location_has_changed = 1;
            s.location = c.g_value_dup_string(v);
            return;
        },
        @intFromEnum(Prop.offset_x) => s.offset_x = c.g_value_get_int(v),
        @intFromEnum(Prop.offset_y) => s.offset_y = c.g_value_get_int(v),
        @intFromEnum(Prop.relative_x) => s.relative_x = c.g_value_get_double(v),
        @intFromEnum(Prop.relative_y) => s.relative_y = c.g_value_get_double(v),
        @intFromEnum(Prop.overlay_width) => s.overlay_width = c.g_value_get_int(v),
        @intFromEnum(Prop.overlay_height) => s.overlay_height = c.g_value_get_int(v),
        @intFromEnum(Prop.alpha) => {
            s.alpha = c.g_value_get_double(v);
            return;
        },
        else => {
            cm.warnInvalid(FILE, o, id, spec, 344);
            return;
        },
    }
    s.geometry_change = 1;
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.location) => c.g_value_set_string(v, s.location),
        @intFromEnum(Prop.offset_x) => c.g_value_set_int(v, s.offset_x),
        @intFromEnum(Prop.offset_y) => c.g_value_set_int(v, s.offset_y),
        @intFromEnum(Prop.relative_x) => c.g_value_set_double(v, s.relative_x),
        @intFromEnum(Prop.relative_y) => c.g_value_set_double(v, s.relative_y),
        @intFromEnum(Prop.overlay_width) => c.g_value_set_int(v, s.overlay_width),
        @intFromEnum(Prop.overlay_height) => c.g_value_set_int(v, s.overlay_height),
        @intFromEnum(Prop.alpha) => c.g_value_set_double(v, s.alpha),
        else => cm.warnInvalid(FILE, o, id, spec, 381),
    }
}

fn setCaps(f: [*c]c.GstGLFilter, incaps: [*c]c.GstCaps, _: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(f);
    const st = c.gst_caps_get_structure(incaps, 0);
    var w: c.gint = 0;
    var h: c.gint = 0;
    _ = c.gst_structure_get_int(st, "width", &w);
    _ = c.gst_structure_get_int(st, "height", &h);
    s.window_width = w;
    s.window_height = h;
    s.geometry_change = 1;
    return 1;
}

fn unbind(s: *Self) void {
    const g = gl(s);
    g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
    g.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    g.DisableVertexAttribArray.?(@bitCast(s.filter.draw_attr_position_loc));
    g.DisableVertexAttribArray.?(@bitCast(s.filter.draw_attr_texture_loc));
}

fn bind(s: *Self, vbo: c.GLuint) void {
    const g = gl(s);
    g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, s.vbo_indices);
    g.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    g.EnableVertexAttribArray.?(@bitCast(s.filter.draw_attr_position_loc));
    g.EnableVertexAttribArray.?(@bitCast(s.filter.draw_attr_texture_loc));
    g.VertexAttribPointer.?(@bitCast(s.filter.draw_attr_position_loc), 3, c.GL_FLOAT, c.GL_FALSE, 20, null);
    g.VertexAttribPointer.?(@bitCast(s.filter.draw_attr_texture_loc), 2, c.GL_FLOAT, c.GL_FALSE, 20, @ptrFromInt(12));
}

fn geometry(s: *Self) void {
    var v = [_]f32{ -1, -1, 0, 0, 0, 1, -1, 0, 1, 0, 1, 1, 0, 1, 1, -1, 1, 0, 0, 1 };
    const fw: f32 = @floatFromInt(s.window_width);
    const fh: f32 = @floatFromInt(s.window_height);
    const x: f32 = @floatCast((@as(f64, @as(f32, @floatFromInt(s.offset_x)) / fw) + s.relative_x) * 2.0 - 1.0);
    const y: f32 = @floatCast((@as(f64, @as(f32, @floatFromInt(s.offset_y)) / fh) + s.relative_y) * 2.0 - 1.0);
    const rw = if (s.overlay_width > 0) s.overlay_width else s.image_width;
    const rh = if (s.overlay_height > 0) s.overlay_height else s.image_height;
    const iw = (@as(f32, @floatFromInt(rw)) / fw) * 2.0;
    const ih = (@as(f32, @floatFromInt(rh)) / fh) * 2.0;
    v[0] = x;
    v[15] = x;
    v[5] = x + iw;
    v[10] = x + iw;
    v[1] = y;
    v[6] = y;
    v[11] = y + ih;
    v[16] = y + ih;
    gl(s).BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(v)), &v, c.GL_STATIC_DRAW);
}

fn drawImage(s: *Self) bool {
    const g = gl(s);
    var map: c.GstMapInfo = undefined;
    if (c.gst_memory_map(@ptrCast(s.image_memory), &map, c.GST_MAP_READ | c.GST_MAP_GL) == 0) return false;
    defer c.gst_memory_unmap(@ptrCast(s.image_memory), &map);
    if (map.data == null) return false;
    const tex = @as(*align(1) const c.guint, @ptrCast(map.data)).*;
    const vao = g.GenVertexArrays != null;
    if (s.overlay_vbo == 0) {
        if (vao) {
            g.GenVertexArrays.?(1, &s.overlay_vao);
            g.BindVertexArray.?(s.overlay_vao);
        }
        g.GenBuffers.?(1, &s.vbo_indices);
        g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, s.vbo_indices);
        g.BufferData.?(c.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(indices)), &indices, c.GL_STATIC_DRAW);
        g.GenBuffers.?(1, &s.overlay_vbo);
        g.BindBuffer.?(c.GL_ARRAY_BUFFER, s.overlay_vbo);
        g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, s.vbo_indices);
        s.geometry_change = 1;
    }
    if (vao) g.BindVertexArray.?(s.overlay_vao);
    bind(s, s.overlay_vbo);
    if (s.geometry_change != 0) geometry(s);
    g.BindTexture.?(c.GL_TEXTURE_2D, tex);
    c.gst_gl_shader_set_uniform_1f(s.shader, "alpha", @floatCast(s.alpha));
    g.Enable.?(c.GL_BLEND);
    if (g.BlendFuncSeparate) |f| f(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA, c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA) else g.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    g.BlendEquation.?(c.GL_FUNC_ADD);
    g.DrawElements.?(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_SHORT, null);
    g.Disable.?(c.GL_BLEND);
    return true;
}

fn draw(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, _: c.gpointer) callconv(.c) c.gboolean {
    const s = me(f);
    const g = gl(s);
    const ctx = el.base(s).context;
    if (c.gst_gl_context_get_gl_api(ctx) & c.GST_GL_API_OPENGL != 0) {
        g.MatrixMode.?(c.GL_PROJECTION);
        g.LoadIdentity.?();
    }
    g.ActiveTexture.?(c.GL_TEXTURE0);
    g.BindTexture.?(c.GL_TEXTURE_2D, c.gst_gl_memory_get_texture_id(in));
    c.gst_gl_shader_use(s.shader);
    c.gst_gl_shader_set_uniform_1f(s.shader, "alpha", 1);
    c.gst_gl_shader_set_uniform_1i(s.shader, "texture", 0);
    f[0].draw_attr_position_loc = c.gst_gl_shader_get_attribute_location(s.shader, "a_position");
    f[0].draw_attr_texture_loc = c.gst_gl_shader_get_attribute_location(s.shader, "a_texcoord");
    c.gst_gl_filter_draw_fullscreen_quad(f);
    const ok = s.image_memory != null and drawImage(s);
    if (g.GenVertexArrays != null) g.BindVertexArray.?(0) else unbind(s);
    c.gst_gl_context_clear_shader(ctx);
    s.geometry_change = 0;
    return @intFromBool(ok);
}

fn decodeError(s: *Self, msg: [*:0]const u8, line: c.gint, _: []const u8) void {
    cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, c.g_strdup(msg), c.g_strdup_printf("File: %s", s.location), FILE, "gst_gl_overlay_load_png", line);
}

fn allocImage(s: *Self, info: *c.GstVideoInfo, align_: ?*c.GstVideoAlignment) void {
    const ctx = el.base(s).context;
    const alloc: [*c]c.GstGLBaseMemoryAllocator = @ptrCast(@alignCast(c.gst_gl_memory_allocator_get_default(ctx)));
    const params: [*c]c.GstGLAllocationParams = @ptrCast(c.gst_gl_video_allocation_params_new(ctx, null, info, 0, align_, c.GST_GL_TEXTURE_TARGET_2D, c.GST_GL_RGBA));
    s.image_memory = @ptrCast(@alignCast(c.gst_gl_base_memory_alloc(alloc, params)));
    c.gst_gl_allocation_params_free(params);
    c.gst_object_unref(alloc);
}

fn loadJpeg(s: *Self, fp: *img.FILE) bool {
    var cinfo = std.mem.zeroes(img.jpeg_decompress_struct);
    var jerr: img.jpeg_error_mgr = undefined;
    img.jpeg_CreateDecompress(&cinfo, img.JPEG_LIB_VERSION, @sizeOf(img.jpeg_decompress_struct));
    cinfo.err = img.jpeg_std_error(&jerr);
    img.jpeg_stdio_src(&cinfo, fp);
    _ = img.jpeg_read_header(&cinfo, 1);
    _ = img.jpeg_start_decompress(&cinfo);
    s.image_width = @intCast(cinfo.image_width);
    s.image_height = @intCast(cinfo.image_height);
    var info: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_set_format(&info, if (cinfo.num_components == 1) c.GST_VIDEO_FORMAT_Y444 else c.GST_VIDEO_FORMAT_RGB, @intCast(s.image_width), @intCast(s.image_height));
    var al: c.GstVideoAlignment = undefined;
    c.gst_video_alignment_reset(&al);
    al.stride_align[0] = 31;
    _ = c.gst_video_info_align(&info, &al);
    allocImage(s, &info, &al);
    var map: c.GstMapInfo = undefined;
    if (c.gst_memory_map(@ptrCast(s.image_memory), &map, c.GST_MAP_WRITE) == 0) {
        cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, c.g_strdup("failed to map memory"), c.g_strdup_printf("File: %s", s.location), FILE, "gst_gl_overlay_load_jpeg", 729);
        return false;
    }
    var i: usize = 0;
    while (i < @as(usize, @intCast(s.image_height))) : (i += 1) {
        var row: img.JSAMPROW = map.data + @as(usize, @intCast(info.stride[0])) * i;
        _ = img.jpeg_read_scanlines(&cinfo, &row, 1);
    }
    _ = img.jpeg_finish_decompress(&cinfo);
    img.jpeg_destroy_decompress(&cinfo);
    c.gst_memory_unmap(@ptrCast(s.image_memory), &map);
    return true;
}

fn pngWarning(_: ?*img.png_struct, msg: [*c]const u8) callconv(.c) void {
    c.g_log(null, c.G_LOG_LEVEL_WARNING, "%s\n", msg);
}

fn loadPng(s: *Self, fp: *img.FILE) bool {
    if (el.base(s).context == null) return false;
    var magic: [8]u8 = undefined;
    if (img.fread(&magic, 1, 8, fp) != 8) {
        decodeError(s, "can't read PNG magic number", 772, "");
        return false;
    }
    if (img.png_sig_cmp(&magic, 0, 8) != 0) {
        decodeError(s, "not a valid PNG image", 779, "");
        return false;
    }
    var png = img.png_create_read_struct(img.PNG_LIBPNG_VER_STRING, null, null, null) orelse {
        decodeError(s, "failed to initialize the png_struct", 787, "");
        return false;
    };
    img.png_set_error_fn(png, null, null, pngWarning);
    var pinfo = img.png_create_info_struct(png);
    if (pinfo == null) {
        img.png_destroy_read_struct(@ptrCast(&png), null, null);
        decodeError(s, "failed to initialize the memory for image information", 798, "");
        return false;
    }
    img.png_init_io(png, fp);
    img.png_set_sig_bytes(png, 8);
    img.png_read_info(png, pinfo);
    var w: img.png_uint_32 = 0;
    var h: img.png_uint_32 = 0;
    var depth: c_int = 0;
    var color: c_int = 0;
    var interlace: c_int = 0;
    _ = img.png_get_IHDR(png, pinfo, &w, &h, &depth, &color, &interlace, null, null);
    if (color == img.PNG_COLOR_TYPE_RGB) {
        img.png_set_filler(png, 0xff, img.PNG_FILLER_AFTER);
        color = img.PNG_COLOR_TYPE_RGB_ALPHA;
    }
    if (color != img.PNG_COLOR_TYPE_RGB_ALPHA) {
        img.png_destroy_read_struct(@ptrCast(&png), null, null);
        decodeError(s, "color type is not rgb", 821, "");
        return false;
    }
    s.image_width = @bitCast(w);
    s.image_height = @bitCast(h);
    var info: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_set_format(&info, c.GST_VIDEO_FORMAT_RGBA, w, h);
    allocImage(s, &info, null);
    var map: c.GstMapInfo = undefined;
    if (c.gst_memory_map(@ptrCast(s.image_memory), &map, c.GST_MAP_WRITE) == 0) {
        img.png_destroy_read_struct(@ptrCast(&png), @ptrCast(&pinfo), null);
        decodeError(s, "failed to map memory", 845, "");
        return false;
    }
    const rows: [*][*c]u8 = @ptrCast(@alignCast(std.c.malloc(@sizeOf([*c]u8) * h)));
    for (0..h) |y| rows[y] = map.data + y * w * 4;
    img.png_read_image(png, @ptrCast(rows));
    std.c.free(@ptrCast(rows));
    c.gst_memory_unmap(@ptrCast(s.image_memory), &map);
    img.png_read_end(png, pinfo);
    img.png_destroy_read_struct(@ptrCast(&png), @ptrCast(&pinfo), null);
    return true;
}

fn loadFile(s: *Self) bool {
    if (s.location == null) return true;
    const fp = img.fopen(s.location, "rb") orelse {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("Can't open file"), c.g_strdup_printf("File: %s", s.location), FILE, "load_file", 601);
        return false;
    };
    defer _ = img.fclose(fp);
    var buf: [16]u8 = undefined;
    if (img.fread(&buf, 1, 16, fp) != 16) {
        cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, c.g_strdup("Can't read file header"), c.g_strdup_printf("File: %s", s.location), FILE, "load_file", 608);
        return false;
    }
    var caps = c.gst_type_find_helper_for_data(@ptrCast(s), &buf, 16, null);
    if (caps == null) {
        cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, c.g_strdup("Can't find file type"), c.g_strdup_printf("File: %s", s.location), FILE, "load_file", 617);
        return false;
    }
    defer _ = c.gst_caps_replace(&caps, null);
    _ = img.fseek(fp, 0, img.SEEK_SET);
    const st = c.gst_caps_get_structure(caps, 0);
    if (c.gst_structure_has_name(st, "image/jpeg") != 0) return loadJpeg(s, fp);
    if (c.gst_structure_has_name(st, "image/png") != 0) return loadPng(s, fp);
    cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, c.g_strdup("Image type not supported"), c.g_strdup_printf("File: %s", s.location), FILE, "load_file", 630);
    return false;
}

fn filterTexture(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, out: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    const s = me(f);
    if (s.location_has_changed != 0) {
        if (s.image_memory != null) c.gst_memory_unref(@ptrCast(s.image_memory));
        s.image_memory = null;
        if (!loadFile(s)) return 0;
        s.location_has_changed = 0;
    }
    _ = c.gst_gl_filter_render_to_target(f, in, out, draw, s);
    return 1;
}

fn beforeTransform(bt: [*c]c.GstBaseTransform, b: [*c]c.GstBuffer) callconv(.c) void {
    el.syncValues(bt, b);
}

fn install(oc: *c.GObjectClass, id: Prop, spec: [*c]c.GParamSpec) void {
    c.g_object_class_install_property(oc, @intFromEnum(id), spec);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_gl = el.parentOf(c.GstGLBaseFilterClass, k);
    parent_obj = el.parentOf(c.GObjectClass, k);
    c.gst_gl_filter_add_rgba_pad_templates(@ptrCast(@alignCast(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const bf: *c.GstGLBaseFilterClass = @ptrCast(@alignCast(k));
    bf.gl_start = glStart;
    bf.gl_stop = glStop;
    const fc: *c.GstGLFilterClass = @ptrCast(@alignCast(k));
    fc.set_caps = setCaps;
    fc.filter_texture = filterTexture;
    el.baseTransformClass(k).before_transform = beforeTransform;
    const maxi = std.math.maxInt(c.gint);
    const mini = std.math.minInt(c.gint);
    install(oc, .location, c.g_param_spec_string("location", "location", "Location of image file to overlay", null, FLAGS));
    install(oc, .offset_x, c.g_param_spec_int("offset-x", "X Offset", "For positive value, horizontal offset of overlay image in pixels from left of video image. For negative value, horizontal offset of overlay image in pixels from right of video image", mini, maxi, 0, FLAGS));
    install(oc, .offset_y, c.g_param_spec_int("offset-y", "Y Offset", "For positive value, vertical offset of overlay image in pixels from top of video image. For negative value, vertical offset of overlay image in pixels from bottom of video image", mini, maxi, 0, FLAGS));
    install(oc, .relative_x, c.g_param_spec_double("relative-x", "Relative X Offset", "Horizontal offset of overlay image in fractions of video image width, from top-left corner of video image", 0, 1, 0, FLAGS));
    install(oc, .relative_y, c.g_param_spec_double("relative-y", "Relative Y Offset", "Vertical offset of overlay image in fractions of video image height, from top-left corner of video image", 0, 1, 0, FLAGS));
    install(oc, .overlay_width, c.g_param_spec_int("overlay-width", "Overlay Width", "Width of overlay image in pixels (0 = same as overlay image)", 0, maxi, 0, FLAGS));
    install(oc, .overlay_height, c.g_param_spec_int("overlay-height", "Overlay Height", "Height of overlay image in pixels (0 = same as overlay image)", 0, maxi, 0, FLAGS));
    install(oc, .alpha, c.g_param_spec_double("alpha", "Alpha", "Global alpha of overlay image", 0, 1, 1, FLAGS));
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Gstreamer OpenGL Overlay", "Filter/Effect/Video", "Overlay GL video texture with a JPEG/PNG image", "Filippo Argiolas <filippo.argiolas@gmail.com>, Matthew Waters <matthew@centricular.com>");
    bf.supported_gl_api = c.GST_GL_API_OPENGL | c.GST_GL_API_GLES2 | c.GST_GL_API_OPENGL3;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    me(inst).alpha = 1;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_filter_get_type(), "GstGLOverlay", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("gloverlay", 0, "gloverlay element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "gloverlay", c.GST_RANK_NONE, getType());
}
