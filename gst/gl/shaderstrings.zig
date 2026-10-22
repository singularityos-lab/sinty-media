const c = @import("../c.zig").c;
const glsl = @import("glsl.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const MEDIUMP = "#ifdef GL_ES\nprecision mediump float;\n#endif\n";
const HIGHP = "#ifdef GL_ES\nprecision highp float;\n#endif\n";
const FRAGMENT_BODY = "varying vec2 v_texcoord;\nuniform sampler2D tex;\nvoid main()\n{\n  gl_FragColor = texture2D(tex, v_texcoord);\n}";
const EXTERNAL_HEADER = "#extension GL_OES_EGL_image_external : require\n";
const EXTERNAL_BODY = "varying vec2 v_texcoord;\nuniform samplerExternalOES tex;\nvoid main()\n{\n  gl_FragColor = texture2D(tex, v_texcoord);\n}";

pub export var gst_gl_shader_string_fragment_mediump_precision: [*c]const u8 = MEDIUMP;
pub export var gst_gl_shader_string_fragment_highp_precision: [*c]const u8 = HIGHP;
pub export var gst_gl_shader_string_vertex_default: [*c]const u8 = "attribute vec4 a_position;\nattribute vec2 a_texcoord;\nvarying vec2 v_texcoord;\nvoid main()\n{\n   gl_Position = a_position;\n   v_texcoord = a_texcoord;\n}\n";
pub export var gst_gl_shader_string_vertex_mat4_texture_transform: [*c]const u8 = "uniform mat4 u_transformation;\nattribute vec4 a_position;\nattribute vec2 a_texcoord;\nvarying vec2 v_texcoord;\nvoid main()\n{\n   gl_Position = a_position;\n   v_texcoord = (u_transformation * vec4(a_texcoord, 0, 1)).xy;\n}\n";
pub export var gst_gl_shader_string_vertex_mat4_vertex_transform: [*c]const u8 = "uniform mat4 u_transformation;\nattribute vec4 a_position;\nattribute vec2 a_texcoord;\nvarying vec2 v_texcoord;\nvoid main()\n{\n   gl_Position = u_transformation * a_position;\n   v_texcoord = a_texcoord;\n}\n";
pub export var gst_gl_shader_string_fragment_default: [*c]const u8 = MEDIUMP ++ FRAGMENT_BODY;
pub export var gst_gl_shader_string_fragment_external_oes_default: [*c]const u8 = EXTERNAL_HEADER ++ MEDIUMP ++ EXTERNAL_BODY;

pub export fn gst_gl_shader_string_get_highest_precision(ctx: [*c]c.GstGLContext, v: c.GstGLSLVersion, p: c.GstGLSLProfile) [*c]const u8 {
    if (glsl.gst_gl_context_supports_precision(ctx, v, p) != 0) {
        if (glsl.gst_gl_context_supports_precision_highp(ctx, v, p) != 0) return gst_gl_shader_string_fragment_highp_precision;
        return gst_gl_shader_string_fragment_mediump_precision;
    }
    return "";
}

pub export fn gst_gl_shader_string_fragment_get_default(ctx: [*c]c.GstGLContext, v: c.GstGLSLVersion, p: c.GstGLSLProfile) [*c]u8 {
    return c.g_strdup_printf("%s%s", gst_gl_shader_string_get_highest_precision(ctx, v, p), FRAGMENT_BODY);
}

pub export fn gst_gl_shader_string_fragment_external_oes_get_default(ctx: [*c]c.GstGLContext, v: c.GstGLSLVersion, p: c.GstGLSLProfile) [*c]u8 {
    return c.g_strdup_printf("%s%s%s", EXTERNAL_HEADER, gst_gl_shader_string_get_highest_precision(ctx, v, p), EXTERNAL_BODY);
}
