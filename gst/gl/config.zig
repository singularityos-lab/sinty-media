const c = @import("../c.zig").c;

comptime {
    @import("../abi.zig").check(@This());
}

pub export var GST_GL_CONFIG_ATTRIB_CONFIG_ID_NAME: [*c]const u8 = "config-id";
pub export var GST_GL_CONFIG_ATTRIB_PLATFORM_NAME: [*c]const u8 = "platform";
pub export var GST_GL_CONFIG_ATTRIB_CAVEAT_NAME: [*c]const u8 = "caveat";
pub export var GST_GL_CONFIG_ATTRIB_SURFACE_TYPE_NAME: [*c]const u8 = "surface-type";
pub export var GST_GL_CONFIG_ATTRIB_CONFORMANT_API_NAME: [*c]const u8 = "conformant-api";
pub export var GST_GL_CONFIG_ATTRIB_RENDERABLE_API_NAME: [*c]const u8 = "renderable-api";
pub export var GST_GL_CONFIG_ATTRIB_RED_SIZE_NAME: [*c]const u8 = "red-size";
pub export var GST_GL_CONFIG_ATTRIB_GREEN_SIZE_NAME: [*c]const u8 = "green-size";
pub export var GST_GL_CONFIG_ATTRIB_BLUE_SIZE_NAME: [*c]const u8 = "blue-size";
pub export var GST_GL_CONFIG_ATTRIB_ALPHA_SIZE_NAME: [*c]const u8 = "alpha-size";
pub export var GST_GL_CONFIG_ATTRIB_LUMINANCE_SIZE_NAME: [*c]const u8 = "luminance-size";
pub export var GST_GL_CONFIG_ATTRIB_DEPTH_SIZE_NAME: [*c]const u8 = "depth-size";
pub export var GST_GL_CONFIG_ATTRIB_STENCIL_SIZE_NAME: [*c]const u8 = "stencil-size";
pub export var GST_GL_CONFIG_ATTRIB_MAX_PBUFFER_WIDTH_NAME: [*c]const u8 = "max-pbuffer-width";
pub export var GST_GL_CONFIG_ATTRIB_MAX_PBUFFER_HEIGHT_NAME: [*c]const u8 = "max-pbuffer-height";
pub export var GST_GL_CONFIG_ATTRIB_MAX_PBUFFER_PIXELS_NAME: [*c]const u8 = "max-pbuffer-pixels";
pub export var GST_GL_CONFIG_ATTRIB_SAMPLE_BUFFERS_NAME: [*c]const u8 = "sample-buffers";
pub export var GST_GL_CONFIG_ATTRIB_SAMPLES_NAME: [*c]const u8 = "samples";
pub export var GST_GL_CONFIG_ATTRIB_NATIVE_RENDERABLE_NAME: [*c]const u8 = "native-renderable";
pub export var GST_GL_CONFIG_ATTRIB_NATIVE_VISUAL_ID_NAME: [*c]const u8 = "native-visual-id";
pub export var GST_GL_CONFIG_ATTRIB_LEVEL_NAME: [*c]const u8 = "level";
pub export var GST_GL_CONFIG_ATTRIB_MIN_SWAP_INTERVAL_NAME: [*c]const u8 = "min-swap-interval";
pub export var GST_GL_CONFIG_ATTRIB_MAX_SWAP_INTERVAL_NAME: [*c]const u8 = "max-swap-interval";

fn nick(t: c.GType, v: c.guint) [*c]const u8 {
    const k: *c.GEnumClass = @ptrCast(@alignCast(c.g_type_class_ref(t)));
    defer c.g_type_class_unref(k);
    const e = c.g_enum_get_value(k, @bitCast(v));
    return if (e != null) e[0].value_nick else null;
}

pub export fn gst_gl_config_caveat_to_string(caveat: c.GstGLConfigCaveat) [*c]const u8 {
    return nick(c.gst_gl_config_caveat_get_type(), caveat);
}

pub export fn gst_gl_config_surface_type_to_string(t: c.GstGLConfigSurfaceType) [*c]const u8 {
    return nick(c.gst_gl_config_surface_type_get_type(), t);
}

pub fn name(comptime n: []const u8) [*c]const u8 {
    return @field(@This(), "GST_GL_CONFIG_ATTRIB_" ++ n ++ "_NAME");
}
