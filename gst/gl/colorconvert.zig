const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const context = @import("context.zig");
const format = @import("format.zig");
const framebuffer = @import("framebuffer.zig");
const glsl = @import("glsl.zig");
const glslstage = @import("glslstage.zig");
const shader = @import("shader.zig");
const shaderstrings = @import("shaderstrings.zig");
const memory = @import("memory.zig");
const basememory = @import("basememory.zig");
const bufferpool = @import("bufferpool.zig");
const syncmeta = @import("syncmeta.zig");
const utils = @import("utils.zig");
const debug = @import("debug.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Conv = c.GstGLColorConvert;
const OConv = [*c]Conv;
const Class = c.GstGLColorConvertClass;
const OCtx = [*c]c.GstGLContext;
const OBuf = [*c]c.GstBuffer;
const OCaps = [*c]c.GstCaps;
const OMem = [*c]c.GstGLMemory;
const Fmt = c.GstVideoFormat;
const FInfo = [*c]const c.GstVideoFormatInfo;
const S = [*:0]const u8;
const MAXP = c.GST_VIDEO_MAX_PLANES;

const TO_RGB = "uniform mat4 to_RGB_matrix;\n";
const TO_YUV = "uniform mat4 to_YUV_matrix;\n";
const WEIGHT = "const vec2 compose_weight = vec2(0.996109, 0.003891);\n";
const UNIFORMS = "uniform vec2 tex_scale0;\nuniform vec2 tex_scale1;\nuniform vec2 tex_scale2;\nuniform vec2 tex_scale3;\nuniform float width;\nuniform float height;\nuniform float poffset_x;\nuniform float poffset_y;\nuniform int input_swizzle[4];\nuniform int output_swizzle[4];\n";
const OES = "#extension GL_OES_EGL_image_external : require \n";

const F_MATRIX = "vec4 color_matrix_apply (vec4 texel, mat4 colormatrix) {\n  float a = texel.a;\n  texel.a = 1.0;\n  vec4 ret = colormatrix * texel;\n  ret.a = a;\n  return ret;\n}\n";
const F_SWIZZLE = "vec4 swizzle(vec4 texel, int components[4]) {\n  return vec4(texel[components[0]], texel[components[1]], texel[components[2]], texel[components[3]]);\n}\nvec3 swizzle(vec3 texel, int components[3]) {\n  return vec3(texel[components[0]], texel[components[1]], texel[components[2]]);\n}\nvec2 swizzle(vec2 texel, int components[2]) {\n  return vec2(texel[components[0]], texel[components[1]]);\n}\nvec2 swizzle2(vec3 texel, int components[3]) {\n  return vec2(texel[components[0]], texel[components[1]]);\n}\nvec2 swizzle2(vec4 texel, int components[4]) {\n  return vec2(texel[components[0]], texel[components[1]]);\n}\nvec3 swizzle3(vec4 texel, int components[4]) {\n  return vec3(texel[components[0]], texel[components[1]], texel[components[2]]);\n}\n";
const F_FETCH_PLANAR = "vec4 fetch_planar_yuv(sampler2D Ytex, sampler2D Utex, sampler2D Vtex, vec2 texcoord) {\n  vec4 yuva;\n  yuva.x = texture2D(Ytex, texcoord * tex_scale0).r * in_bitdepth_factor;\n  yuva.y = texture2D(Utex, texcoord * tex_scale1).r * in_bitdepth_factor;\n  yuva.z = texture2D(Vtex, texcoord * tex_scale2).r * in_bitdepth_factor;\n  yuva.a = 1.0;\n  return yuva;\n}\nvec4 fetch_planar_yuva(sampler2D Ytex, sampler2D Utex, sampler2D Vtex, sampler2D Atex, vec2 texcoord) {\n  vec4 yuva = fetch_planar_yuv(Ytex, Utex, Vtex, texcoord);\n  yuva.a = texture2D(Atex, texcoord * tex_scale3).r * in_bitdepth_factor;\n  return yuva;\n}\n";
const F_CHROMA = "vec4 chroma_sample(sampler2D tex, vec2 texcoord, vec2 unnormalization) {\n  vec4 uv_texel = vec4(0.0);\n  vec2 chroma_pos = texcoord * chroma_sampling * unnormalization;\n  chroma_pos -= clamp(chroma_sampling * 0.5 - 0.5, vec2(0.0), chroma_sampling);\n  if (chroma_pos.x < width && chroma_pos.y < height) {\n    for (int i = 0; i < int(chroma_sampling.x); i++) {\n      vec2 delta = vec2 (float(i), 0.0);\n      for (int j = 0; j < int(chroma_sampling.y); j++) {\n        int n = (i+1)*(j+1);\n        delta.y = float(j);\n        vec4 s = swizzle(texture2D(tex, (chroma_pos + delta) / unnormalization), input_swizzle);\n        uv_texel = (float(n-1) * uv_texel + s) / float(n);\n      }\n    }\n  }\n  return uv_texel;\n}\n";
const F_WRITE_YUV = "void write_planar_yuv(vec4 yuva) {\n  gl_FragData[0] = vec4(yuva.x, 0.0, 0.0, 1.0);\n  gl_FragData[1] = vec4(yuva.y, 0.0, 0.0, 1.0);\n  gl_FragData[2] = vec4(yuva.z, 0.0, 0.0, 1.0);\n}\n";
const F_WRITE_YUVA = "void write_planar_yuva(vec4 yuva) {\n  gl_FragData[0] = vec4(yuva.x, 0.0, 0.0, 1.0);\n  gl_FragData[1] = vec4(yuva.y, 0.0, 0.0, 1.0);\n  gl_FragData[2] = vec4(yuva.z, 0.0, 0.0, 1.0);\n  gl_FragData[3] = vec4(yuva.a, 0.0, 0.0, 1.0);\n}\n";
const F_TILE = "ivec2 frag_to_tile(ivec2 tile_coord, ivec2 delta_coord, ivec2 dim, int width, int tiles_per_row, int need_offset) {\n  int tile_size = (dim.x * dim.y);\n  int tile_index = tile_coord.y * tiles_per_row + tile_coord.x;\n  int linear_index = tile_index * tile_size + delta_coord.y * dim.x + delta_coord.x;\n  linear_index += need_offset * tile_size / 2;\n  return ivec2(linear_index % width, linear_index / width);\n}\n";
const F_YUY2_UNPACK = "vec4 yuy2_uyvy_unpack(sampler2D tex, vec2 v_texcoord, vec2 vert_to_tex, vec2 chroma_sampling) {\n  vec4 yuva;\n  float dx1 = -poffset_x;\n  float dx2 = 0.0;\n  yuva.x = texture2D(tex, v_texcoord * vert_to_tex * tex_scale0)[input_swizzle[0]];\n  vec2 half_poffset = vec2(poffset_x / 2.0, poffset_y / 2.0);\n  int inorder = int(((v_texcoord.x * vert_to_tex.x - half_poffset.x) * chroma_sampling.x + half_poffset.x) * width / vert_to_tex) % 2;\n  if (inorder == 0) {\n    dx2 = -dx1;\n    dx1 = 0.0;\n  }\n  vec2 non_offset = v_texcoord * vert_to_tex * tex_scale0 - half_poffset;\n  vec4 u_texel = texture2D(tex, non_offset * chroma_sampling + half_poffset + vec2(dx1, 0.0));\n  vec4 v_texel = texture2D(tex, non_offset * chroma_sampling + half_poffset + vec2(dx2, 0.0));\n  yuva.yz = vec2(u_texel[input_swizzle[1]], v_texel[input_swizzle[2]]);\n  yuva.a = 1.0;\n  return yuva;\n}\n";
const F_YUY2_PACK = "ivec2 YUY2_UYVY_pack(vec2 texcoord, vec2 v_texcoord, out vec2 texcoord0, out vec2 texcoord1) {\n  vec4 texel1, texel2;\n  vec4 yuva, yuv1, yuv2;\n  float fx, dx, fy;\n  float inorder = mod (v_texcoord.x * out_width, 2.0);\n  fx = texcoord.x;\n  dx = poffset_x;\n  if (inorder > 1.0) {\n    dx = -dx;\n  }\n  fy = texcoord.y;\n  texcoord0 = vec2(fx, fy);\n  texcoord1 = vec2(fx + dx, fy);\n  if (inorder < 1.0) {\n    return ivec2(output_swizzle[0], output_swizzle[1]);\n  } else {\n    return ivec2(output_swizzle[2], output_swizzle[3]);\n  }\n}\n";
const F_V210_UNPACK = "ivec2 v210_component_to_texel(int comp) {\n  return ivec2(comp / 3, comp % 3);\n}\nivec2 v210_y_xoffset(int xpos) {\n  int texel_i = xpos * 2 + 1;\n  return v210_component_to_texel(texel_i);\n}\nivec2 v210_u_xoffset(int xpos) {\n  int texel_i = 4 * (xpos / 2);\n  return v210_component_to_texel(texel_i);\n}\nivec2 v210_v_xoffset(int xpos) {\n  int texel_i = 4 * (xpos / 2) + 2;\n  return v210_component_to_texel(texel_i);\n}\nvec4 v210_unpack(sampler2D tex, vec2 v_texcoord, vec2 vert_to_tex, vec2 chroma_sampling) {\n  int xpos = int(v_texcoord.x * out_width);\n  ivec2 y_xoffset = v210_y_xoffset(xpos);\n  ivec2 u_xoffset = v210_u_xoffset(xpos * int(chroma_sampling.x));\n  ivec2 v_xoffset = v210_v_xoffset(xpos * int(chroma_sampling.x));\n  vec2 half_x_offset = vec2(poffset_x / 2.0, 0.0);\n  vec4 y_texel = texture2D(tex, vec2(poffset_x * float(y_xoffset[0]), v_texcoord.y * vert_to_tex.y) * tex_scale0 + half_x_offset);\n  vec4 u_texel = texture2D(tex, vec2(poffset_x * float(u_xoffset[0]), v_texcoord.y * vert_to_tex.y * chroma_sampling.y) * tex_scale0 + half_x_offset);\n  vec4 v_texel = texture2D(tex, vec2(poffset_x * float(v_xoffset[0]), v_texcoord.y * vert_to_tex.y * chroma_sampling.y) * tex_scale0 + half_x_offset);\n  return vec4(y_texel[y_xoffset[1]], u_texel[u_xoffset[1]], v_texel[v_xoffset[1]], 1.0);\n}\n";
const F_V210_PACK = "ivec3 v210_pack(vec2 texcoord, vec2 vert_to_tex, out vec2 texcoord0, out vec2 texcoord1, out vec2 texcoord2) {\n  ivec2[12] block_indices;\n  block_indices[0] = ivec2(0, 1);\n  block_indices[1] = ivec2(0, 0);\n  block_indices[2] = ivec2(0, 2);\n  block_indices[3] = ivec2(1, 0);\n  block_indices[4] = ivec2(2, 1);\n  block_indices[5] = ivec2(2, 0);\n  block_indices[6] = ivec2(2, 2);\n  block_indices[7] = ivec2(3, 0);\n  block_indices[8] = ivec2(4, 1);\n  block_indices[9] = ivec2(4, 0);\n  block_indices[10] = ivec2(4, 2);\n  block_indices[11] = ivec2(5, 0);\n  vec2 half_x_offset = vec2(poffset_x * 0.66666 / 2.0, 0.0);\n  int xpos = int(texcoord.x * out_width);\n  ivec2 sub_idx0 = block_indices[(xpos % 4) * 3 + 0];\n  ivec2 sub_idx1 = block_indices[(xpos % 4) * 3 + 1];\n  ivec2 sub_idx2 = block_indices[(xpos % 4) * 3 + 2];\n  vec2 block_offset = vec2(float((xpos / 4) * 6) * poffset_x, texcoord.y * vert_to_tex.y) + half_x_offset;\n  texcoord0 = block_offset + vec2(float(sub_idx0[0]) * poffset_x, 0.0);\n  texcoord1 = block_offset + vec2(float(sub_idx1[0]) * poffset_x, 0.0);\n  texcoord2 = block_offset + vec2(float(sub_idx2[0]) * poffset_x, 0.0);\n  return ivec3(sub_idx0[1], sub_idx1[1], sub_idx2[1]);\n}\n";
const F_YUV_TO_RGB = "vec3 yuv_to_rgb (vec3 yuv, vec3 offset, vec3 ycoeff, vec3 ucoeff, vec3 vcoeff) {\n  vec3 rgb;\n  yuv += offset;\n  rgb.r = dot(yuv, ycoeff);\n  rgb.g = dot(yuv, ucoeff);\n  rgb.b = dot(yuv, vcoeff);\n  return rgb;\n}\n";

const Templ = struct {
    uniforms: S,
    functions: []const S,
};

fn templ(comptime u: S, comptime f: []const S) Templ {
    return .{ .uniforms = u, .functions = f };
}

const PLANAR_IN = "uniform sampler2D Ytex, Utex, Vtex;\n";
const PLANAR_A_IN = "uniform sampler2D Ytex, Utex, Vtex, Atex;\n";
const CHROMA = "uniform vec2 chroma_sampling;\n";
const IN_DEPTH = "uniform float in_bitdepth_factor;\n";
const OUT_DEPTH = "uniform float out_bitdepth_factor;\n";
const TEX = "uniform sampler2D tex;\n";
const YTEX = "uniform sampler2D Ytex;\n";
const OUT_W = "uniform float out_width;\n";
const V2T = "uniform vec2 vert_to_tex;\n";
const RGB_PLANES = "uniform sampler2D Rtex, Gtex, Btex, Atex;\n";

const T_REORDER = templ(UNIFORMS ++ TEX, &.{F_SWIZZLE});
const T_COMPOSE = templ(UNIFORMS ++ WEIGHT ++ TEX, &.{F_SWIZZLE});
const T_AYUV_RGB = templ(UNIFORMS ++ TO_RGB ++ TEX, &.{ F_SWIZZLE, F_MATRIX });
const T_RGB_AYUV = templ(UNIFORMS ++ TO_YUV ++ TEX, &.{ F_SWIZZLE, F_MATRIX });
const T_PLANAR_RGB = templ(UNIFORMS ++ TO_RGB ++ PLANAR_IN ++ IN_DEPTH, &.{ F_SWIZZLE, F_MATRIX, F_FETCH_PLANAR });
const T_A420_RGB = templ(UNIFORMS ++ TO_RGB ++ PLANAR_A_IN ++ IN_DEPTH, &.{ F_SWIZZLE, F_MATRIX, F_FETCH_PLANAR });
const T_RGB_PLANAR = templ(UNIFORMS ++ TO_YUV ++ TEX ++ CHROMA ++ OUT_DEPTH, &.{ F_SWIZZLE, F_MATRIX, F_CHROMA, F_WRITE_YUV });
const T_RGB_PLANAR_A = templ(UNIFORMS ++ TO_YUV ++ TEX ++ CHROMA ++ OUT_DEPTH, &.{ F_SWIZZLE, F_MATRIX, F_CHROMA, F_WRITE_YUVA });
const T_P_P = templ(UNIFORMS ++ TO_YUV ++ PLANAR_IN ++ CHROMA ++ IN_DEPTH ++ OUT_DEPTH, &.{ F_SWIZZLE, F_MATRIX, F_WRITE_YUV });
const T_P_PA = templ(UNIFORMS ++ TO_YUV ++ PLANAR_IN ++ CHROMA ++ IN_DEPTH ++ OUT_DEPTH, &.{ F_SWIZZLE, F_MATRIX, F_WRITE_YUVA });
const T_PA_PA = templ(UNIFORMS ++ TO_YUV ++ PLANAR_A_IN ++ CHROMA ++ IN_DEPTH ++ OUT_DEPTH, &.{ F_SWIZZLE, F_MATRIX, F_WRITE_YUV, F_WRITE_YUVA });
const T_PA_P = templ(UNIFORMS ++ TO_YUV ++ PLANAR_A_IN ++ CHROMA ++ IN_DEPTH ++ OUT_DEPTH, &.{ F_SWIZZLE, F_MATRIX, F_CHROMA, F_WRITE_YUV });
const T_SEMI_RGB = templ(UNIFORMS ++ TO_RGB ++ "uniform sampler2D Ytex, UVtex;\n", &.{ F_SWIZZLE, F_MATRIX });
const T_AV12_RGB = templ(UNIFORMS ++ TO_RGB ++ "uniform sampler2D Ytex, UVtex, Atex;\n", &.{ F_SWIZZLE, F_MATRIX });
const T_TILED_RGB = templ(UNIFORMS ++ TO_RGB ++ "uniform sampler2D Ytex, UVtex;\n", &.{ F_SWIZZLE, F_MATRIX, F_TILE });
const T_RGB_SEMI = templ(UNIFORMS ++ TO_YUV ++ TEX ++ CHROMA, &.{ F_SWIZZLE, F_MATRIX });
const T_YUY2_RGB = templ(UNIFORMS ++ TO_RGB ++ YTEX ++ V2T, &.{ F_SWIZZLE, F_MATRIX, F_YUY2_UNPACK });
const T_YUY2_P = templ(UNIFORMS ++ TO_RGB ++ YTEX ++ CHROMA ++ OUT_DEPTH ++ V2T, &.{ F_SWIZZLE, F_MATRIX, F_YUY2_UNPACK, F_WRITE_YUV });
const T_YUY2_PA = templ(UNIFORMS ++ TO_RGB ++ YTEX ++ CHROMA ++ OUT_DEPTH ++ V2T, &.{ F_SWIZZLE, F_MATRIX, F_YUY2_UNPACK, F_WRITE_YUVA });
const T_RGB_YUY2 = templ(UNIFORMS ++ TO_YUV ++ TEX ++ OUT_W, &.{ F_SWIZZLE, F_MATRIX, F_YUY2_PACK });
const T_P_YUY2 = templ(UNIFORMS ++ TO_YUV ++ YTEX ++ "uniform sampler2D Utex;\nuniform sampler2D Vtex;\n" ++ IN_DEPTH ++ OUT_W, &.{ F_SWIZZLE, F_MATRIX, F_YUY2_PACK, F_FETCH_PLANAR });
const T_V210_RGB = templ(UNIFORMS ++ TO_RGB ++ YTEX ++ OUT_W ++ V2T, &.{ F_SWIZZLE, F_MATRIX, F_V210_UNPACK });
const T_V210_P = templ(UNIFORMS ++ TO_RGB ++ YTEX ++ OUT_W ++ OUT_DEPTH ++ CHROMA ++ V2T, &.{ F_SWIZZLE, F_MATRIX, F_V210_UNPACK, F_WRITE_YUV });
const T_V210_PA = templ(UNIFORMS ++ TO_RGB ++ YTEX ++ OUT_W ++ OUT_DEPTH ++ CHROMA ++ V2T, &.{ F_SWIZZLE, F_MATRIX, F_V210_UNPACK, F_WRITE_YUVA });
const T_P_V210 = templ(UNIFORMS ++ TO_RGB ++ YTEX ++ "uniform sampler2D Utex;\nuniform sampler2D Vtex;\n" ++ OUT_W ++ IN_DEPTH ++ CHROMA ++ V2T, &.{ F_SWIZZLE, F_MATRIX, F_FETCH_PLANAR, F_V210_PACK });
const T_RGB_V210 = templ(UNIFORMS ++ TO_YUV ++ TEX ++ OUT_W ++ V2T, &.{ F_SWIZZLE, F_MATRIX, F_V210_PACK });
const T_YUY2_V210 = templ(UNIFORMS ++ TO_RGB ++ TEX ++ OUT_W ++ V2T, &.{ F_SWIZZLE, F_MATRIX, F_YUY2_UNPACK, F_V210_PACK });
const T_V210_YUY2 = templ(UNIFORMS ++ TO_RGB ++ TEX ++ OUT_W ++ V2T, &.{ F_SWIZZLE, F_MATRIX, F_V210_UNPACK, F_YUY2_PACK });
const T_YUY2_YUY2 = templ(UNIFORMS ++ TO_RGB ++ TEX ++ OUT_W ++ V2T, &.{ F_SWIZZLE, F_MATRIX, F_YUY2_UNPACK, F_YUY2_PACK });
const T_PRGB_RGB = templ(UNIFORMS ++ RGB_PLANES, &.{F_SWIZZLE});
const T_RGB_PRGB = templ(UNIFORMS ++ TEX, &.{F_SWIZZLE});
const T_PRGB_PRGB = templ(UNIFORMS ++ RGB_PLANES, &.{F_SWIZZLE});

const B_REORDER = "vec4 t = swizzle(texture2D(tex, texcoord * tex_scale0), input_swizzle);\ngl_FragColor = vec4(swizzle(t, output_swizzle));\n";
const B_REORDER_OPAQUE = "vec4 t = swizzle(texture2D(tex, texcoord * tex_scale0), input_swizzle);\nt.a = 1.0;\ngl_FragColor = vec4(swizzle(t, output_swizzle));\n";
const B_COMPOSE = "vec4 rgba;\nvec4 t = texture2D(tex, texcoord * tex_scale0);\nrgba.rgb = vec3 (dot(swizzle2(t, input_swizzle), compose_weight));\nrgba.a = 1.0;\ngl_FragColor = swizzle(rgba, output_swizzle);\n";
const B_AYUV_RGB = "vec4 texel = swizzle(texture2D(tex, texcoord * tex_scale0), input_swizzle);\nvec4 rgba = color_matrix_apply(texel, to_RGB_matrix);\ngl_FragColor = swizzle(rgba, output_swizzle);\n";
const B_RGB_AYUV = "vec4 texel = swizzle(texture2D(tex, texcoord), input_swizzle);\nvec4 yuva = color_matrix_apply(texel, to_YUV_matrix);\nyuva.a = %s;\ngl_FragColor = swizzle(yuva, output_swizzle);\n";
const B_PLANAR_RGB = "vec4 yuva = fetch_planar_yuv(Ytex, Utex, Vtex, texcoord);\nyuva = swizzle(yuva, input_swizzle);\nvec4 rgba = color_matrix_apply(yuva, to_RGB_matrix);\ngl_FragColor = swizzle(rgba, output_swizzle);\n";
const B_PLANAR_A_RGB = "vec4 yuva = fetch_planar_yuva(Ytex, Utex, Vtex, Atex, texcoord);\nyuva = swizzle(yuva, input_swizzle);\nvec4 rgba = color_matrix_apply(yuva, to_RGB_matrix);\ngl_FragColor = swizzle(rgba, output_swizzle);\n";
const B_RGB_PLANAR_HEAD = "vec4 texel = swizzle(texture2D(tex, texcoord), input_swizzle);\nvec2 unnormalization;\nif (texcoord.x == v_texcoord.x) {\n  unnormalization = vec2(width, height);\n} else {\n  unnormalization = vec2 (1.0);\n}\nvec4 uv_texel = chroma_sample(tex, texcoord, unnormalization);\nvec4 yuva;\nyuva.x = color_matrix_apply(texel, to_YUV_matrix).x;\nyuva.yz = color_matrix_apply(uv_texel, to_YUV_matrix).yz;\nyuva.a = texel.a;\nyuva = swizzle(yuva, output_swizzle) * out_bitdepth_factor;\n";
const B_RGB_PLANAR = B_RGB_PLANAR_HEAD ++ "write_planar_yuv(yuva);\n";
const B_RGB_PLANAR_A = B_RGB_PLANAR_HEAD ++ "write_planar_yuva(yuva);\n";
const B_PP_HEAD = "vec4 yuva;\nyuva.x = swizzle(texture2D(Ytex, texcoord * tex_scale0), input_swizzle).r * in_bitdepth_factor;\nyuva.y = swizzle(texture2D(Utex, texcoord * tex_scale1 * chroma_sampling), input_swizzle).r * in_bitdepth_factor;\nyuva.z = swizzle(texture2D(Vtex, texcoord * tex_scale2 * chroma_sampling), input_swizzle).r * in_bitdepth_factor;\n";
const B_P_P = B_PP_HEAD ++ "yuva.a = 1.0;\nyuva = swizzle(yuva, output_swizzle) * out_bitdepth_factor;\nwrite_planar_yuv(yuva);\n";
const B_P_PA = B_PP_HEAD ++ "yuva.a = 1.0;\nyuva = swizzle(yuva, output_swizzle) * out_bitdepth_factor;\nwrite_planar_yuva(yuva);\n";
const B_PA_PA = B_PP_HEAD ++ "yuva.a = swizzle(texture2D(Atex, texcoord * tex_scale3), input_swizzle).r;\nyuva = swizzle(yuva, output_swizzle) * out_bitdepth_factor;\nwrite_planar_yuva(yuva);\n";
const B_PA_P = B_PP_HEAD ++ "yuva.a = swizzle(texture2D(Atex, texcoord * tex_scale3), input_swizzle).r;\nyuva = swizzle(yuva, output_swizzle) * out_bitdepth_factor;\nwrite_planar_yuv(yuva);\n";
const B_SEMI_RGB = "vec4 yuva;\nyuva.x=texture2D(Ytex, texcoord * tex_scale0).r;\nyuva.yz=texture2D(UVtex, texcoord * tex_scale1).r%c;\n%syuva = swizzle(yuva, input_swizzle);\nvec4 rgba = color_matrix_apply (yuva, to_RGB_matrix);\ngl_FragColor = swizzle(rgba, output_swizzle);\n";
const B_TILED_RGB = "  vec4 yuva;\n  ivec2 texel;\n\n  const ivec2 luma_dim = ivec2(%i, %i);\n  const ivec2 chroma_dim = ivec2(%i, %i);\n  const int fy = chroma_dim.y * 2 / luma_dim.y;\n\n  int iwidth = int(width);\n  int tiles_per_row = iwidth / luma_dim.x;\n\n  ivec2 coord = ivec2(gl_FragCoord.xy);\n  ivec2 tile_coord = coord / luma_dim;\n  ivec2 delta_coord = coord %% luma_dim;\n  texel = frag_to_tile(tile_coord, delta_coord, luma_dim, iwidth, tiles_per_row, 0);\n  yuva.x = texelFetch(Ytex, texel, 0).r;\n\n  ivec2 chroma_tcoord = ivec2(tile_coord.x, tile_coord.y / fy);\n  texel = frag_to_tile(chroma_tcoord, delta_coord / 2, chroma_dim, iwidth / 2, tiles_per_row, tile_coord.y %% fy);\n  yuva.yz = texelFetch(UVtex, texel, 0).%c%c;\n  yuva.a = 1.0;\n\n  vec4 rgba = color_matrix_apply(yuva, to_RGB_matrix);\n  gl_FragColor = swizzle(rgba, output_swizzle);\n";
const B_RGB_SEMI = "vec4 texel, uv_texel;\nvec4 yuva;\ntexel = swizzle(texture2D(tex, texcoord), input_swizzle);\nuv_texel = swizzle(texture2D(tex, texcoord * tex_scale0 * chroma_sampling), input_swizzle);\nyuva.x = color_matrix_apply(texel, to_YUV_matrix).x;\nyuva.yz = color_matrix_apply(uv_texel, to_YUV_matrix).yz;\nyuva.a = 1.0;\nyuva = swizzle(yuva, output_swizzle);\ngl_FragData[0] = vec4(yuva.x, 0.0, 0.0, 1.0);\ngl_FragData[1] = vec4(yuva.y, yuva.z, 0.0, 1.0);\n%s";
const B_YUY2_RGB = "vec4 yuva = yuy2_uyvy_unpack(Ytex, v_texcoord, vert_to_tex, vec2(1.0));\nvec4 rgba = color_matrix_apply(yuva, to_RGB_matrix);\ngl_FragColor = swizzle(rgba, output_swizzle);\n";
const B_YUY2_P = "vec4 yuva = yuy2_uyvy_unpack(Ytex, v_texcoord, vert_to_tex, chroma_sampling);\nyuva = swizzle(yuva, output_swizzle) * out_bitdepth_factor;\nwrite_planar_yuv(yuva);\n";
const B_YUY2_PA = "vec4 yuva = yuy2_uyvy_unpack(Ytex, v_texcoord, vert_to_tex, chroma_sampling);\nyuva = swizzle(yuva, output_swizzle) * out_bitdepth_factor;\nwrite_planar_yuva(yuva);\n";
const B_RGB_YUY2 = "vec2 texcoord0, texcoord1;\nivec2 idx = YUY2_UYVY_pack(texcoord, v_texcoord, texcoord0, texcoord1);\nvec4 rgba0 = swizzle(texture2D(tex, texcoord0), input_swizzle);\nvec4 rgba1 = swizzle(texture2D(tex, texcoord1), input_swizzle);\nvec4 yuva0 = color_matrix_apply(rgba0, to_YUV_matrix);\nvec4 yuva1 = color_matrix_apply(rgba1, to_YUV_matrix);\nvec4 yuva;\nyuva.x = yuva0.x;\nyuva.yz = (yuva0.yz + yuva1.yz) * 0.5;\ngl_FragColor = vec4(yuva[idx[0]], yuva[idx[1]], 0.0, 0.0);\n";
const B_P_YUY2 = "vec2 texcoord0, texcoord1;\nivec2 idx = YUY2_UYVY_pack(texcoord, v_texcoord, texcoord0, texcoord1);\nvec4 yuva0 = fetch_planar_yuv(Ytex, Utex, Vtex, texcoord0);\nvec4 yuva1 = fetch_planar_yuv(Ytex, Utex, Vtex, texcoord1);\nvec4 yuva;\nyuva.x = yuva0.x;\nyuva.yz = (yuva0.yz + yuva1.yz) * 0.5;\ngl_FragColor = vec4(yuva[idx[0]], yuva[idx[1]], 0.0, 0.0);\n";
const B_V210_RGB = "vec4 yuva = v210_unpack(Ytex, v_texcoord, vert_to_tex, vec2(1.0));\nvec4 rgba = color_matrix_apply(yuva, to_RGB_matrix);\ngl_FragColor = swizzle(rgba, output_swizzle);\n";
const B_V210_P = "vec4 yuva = v210_unpack(Ytex, v_texcoord, vert_to_tex, chroma_sampling);\nyuva = swizzle(yuva, output_swizzle) * out_bitdepth_factor;\nwrite_planar_yuv(yuva);\n";
const B_V210_PA = "vec4 yuva = v210_unpack(Ytex, v_texcoord, vert_to_tex, chroma_sampling);\nyuva = swizzle(yuva, output_swizzle) * out_bitdepth_factor;\nwrite_planar_yuva(yuva);\n";
const B_P_V210 = "vec2 texcoord0, texcoord1, texcoord2;\nivec3 idx = v210_pack(v_texcoord, vert_to_tex, texcoord0, texcoord1, texcoord2);\nvec4 yuva0 = fetch_planar_yuv(Ytex, Utex, Vtex, texcoord0);\nvec4 yuva1 = fetch_planar_yuv(Ytex, Utex, Vtex, texcoord1);\nvec4 yuva2 = fetch_planar_yuv(Ytex, Utex, Vtex, texcoord2);\ngl_FragColor = vec4(yuva0[idx[0]], yuva1[idx[1]], yuva2[idx[2]], 1.0);\n";
const B_RGB_V210 = "vec2 texcoord0, texcoord1, texcoord2;\nivec3 idx = v210_pack(v_texcoord, vert_to_tex, texcoord0, texcoord1, texcoord2);\nvec4 rgba0 = swizzle(texture2D(tex, texcoord0), input_swizzle);\nvec4 rgba1 = swizzle(texture2D(tex, texcoord1), input_swizzle);\nvec4 rgba2 = swizzle(texture2D(tex, texcoord2), input_swizzle);\nvec4 yuva0 = color_matrix_apply(rgba0, to_YUV_matrix);\nvec4 yuva1 = color_matrix_apply(rgba1, to_YUV_matrix);\nvec4 yuva2 = color_matrix_apply(rgba2, to_YUV_matrix);\ngl_FragColor = vec4(yuva0[idx[0]], yuva1[idx[1]], yuva2[idx[2]], 1.0);\n";
const B_YUY2_V210 = "vec2 texcoord0, texcoord1, texcoord2;\nivec3 idx = v210_pack(v_texcoord, vert_to_tex, texcoord0, texcoord1, texcoord2);\nvec4 yuva0 = yuy2_uyvy_unpack(tex, texcoord0 / vert_to_tex, vert_to_tex, vec2(1.0));\nvec4 yuva1 = yuy2_uyvy_unpack(tex, texcoord1 / vert_to_tex, vert_to_tex, vec2(1.0));\nvec4 yuva2 = yuy2_uyvy_unpack(tex, texcoord2 / vert_to_tex, vert_to_tex, vec2(1.0));\ngl_FragColor = vec4(yuva0[idx[0]], yuva1[idx[1]], yuva2[idx[2]], 1.0);\n";
const B_V210_YUY2 = "vec4 yuva = v210_unpack(tex, v_texcoord, vert_to_tex, vec2(1.0));\nvec2 texcoord0, texcoord1;\nivec2 idx = YUY2_UYVY_pack(texcoord, v_texcoord, texcoord0, texcoord1);\ngl_FragColor = vec4(yuva[idx[0]], yuva[idx[1]], 0.0, 0.0);\n";
const B_YUY2_YUY2 = "vec4 yuva = yuy2_uyvy_unpack(tex, v_texcoord, vert_to_tex, vec2(1.0));\nvec2 texcoord0, texcoord1;\nivec2 idx = YUY2_UYVY_pack(texcoord, v_texcoord, texcoord0, texcoord1);\ngl_FragColor = vec4(yuva[idx[0]], yuva[idx[1]], 0.0, 0.0);\n";
const B_PRGB_RGB = "vec4 rgba;\nrgba.r = texture2D(Rtex, texcoord * tex_scale0).r;\nrgba.g = texture2D(Gtex, texcoord * tex_scale1).r;\nrgba.b = texture2D(Btex, texcoord * tex_scale2).r;\n%s\nrgba = swizzle(rgba, input_swizzle);\ngl_FragColor = swizzle(rgba, output_swizzle);\n";
const B_RGB_PRGB = "vec4 rgba;\nrgba = swizzle(texture2D(tex, texcoord), input_swizzle);\nrgba = swizzle(rgba, output_swizzle);\ngl_FragData[0] = vec4(rgba.r, 0, 0, 1.0);\ngl_FragData[1] = vec4(rgba.g, 0, 0, 1.0);\ngl_FragData[2] = vec4(rgba.b, 0, 0, 1.0);\n%s\n";
const B_PRGB_PRGB = "vec4 rgba;\nrgba.r = texture2D(Rtex, texcoord * tex_scale0).r;\nrgba.g = texture2D(Gtex, texcoord * tex_scale1).r;\nrgba.b = texture2D(Btex, texcoord * tex_scale2).r;\n%s\nrgba = swizzle(rgba, input_swizzle);\nrgba = swizzle(rgba, output_swizzle);\ngl_FragData[0] = vec4(rgba.r, 0, 0, 1.0);\ngl_FragData[1] = vec4(rgba.g, 0, 0, 1.0);\ngl_FragData[2] = vec4(rgba.b, 0, 0, 1.0);\n%s\n";

const VERTEX = "attribute vec4 a_position;   \nattribute vec2 a_texcoord;   \nvarying vec2 v_texcoord;     \nvoid main()                  \n{                            \n  gl_Position = a_position; \n  v_texcoord = a_texcoord;  \n}                            \n";
const VERTICES = [20]c.GLfloat{ 1, -1, 0, 1, 0, -1, -1, 0, 0, 0, -1, 1, 0, 0, 1, 1, 1, 0, 1, 1 };
const INDICES = [6]c.GLushort{ 0, 1, 2, 0, 2, 3 };

const M4 = [4][4]f64;

const Info = struct {
    in_n: c.gint,
    out_n: c.gint,
    templ: ?*const Templ,
    body: [*c]u8,
    prog: [*c]u8,
    names: [MAXP]?S,
    to_rgb: M4,
    to_yuv: M4,
    chroma: [2]f32,
    in_swizzle: [MAXP]c_int,
    out_swizzle: [MAXP]c_int,
    in_depth: f32,
    out_depth: f32,
};

const Priv = struct {
    result: c.gboolean,
    info: Info,
    from: c.GstGLTextureTarget,
    to: c.GstGLTextureTarget,
    in_tex: [MAXP]OMem,
    out_tex: [MAXP]OMem,
    in_formats: [MAXP]c.GstGLFormat,
    vao: c.GLuint,
    vbo: c.GLuint,
    ibo: c.GLuint,
    attr_pos: c.GLint,
    attr_tex: c.GLint,
    in_caps: OCaps,
    out_caps: OCaps,
    pool: [*c]c.GstBufferPool,
    pool_started: c.gboolean,
    padded_w: c.gint,
    padded_h: c.gint,
};

var once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GObjectClass = null;

fn cv(p: anytype) OConv {
    return @ptrCast(@alignCast(p));
}

fn pv(p: anytype) *Priv {
    return @ptrCast(@alignCast(cv(p)[0].priv));
}

fn vt(ctx: OCtx) *c.GstGLFuncs {
    return @ptrCast(ctx[0].gl_vtable);
}

fn objLock(p: anytype) void {
    c.g_mutex_lock(&@as(*c.GstObject, @ptrCast(@alignCast(p))).lock);
}

fn objUnlock(p: anytype) void {
    c.g_mutex_unlock(&@as(*c.GstObject, @ptrCast(@alignCast(p))).lock);
}

fn using(ctx: OCtx, api: c.GstGLAPI, maj: c.gint, min: c.gint) bool {
    return context.gst_gl_context_check_gl_version(ctx, api, maj, min) != 0;
}

fn usingGl(ctx: OCtx) bool {
    return using(ctx, c.GST_GL_API_OPENGL, 1, 0);
}

fn usingGl3(ctx: OCtx) bool {
    return using(ctx, c.GST_GL_API_OPENGL3, 3, 1);
}

fn usingGl30(ctx: OCtx) bool {
    return using(ctx, c.GST_GL_API_OPENGL, 3, 0) or usingGl3(ctx);
}

fn usingGles2(ctx: OCtx) bool {
    return using(ctx, c.GST_GL_API_GLES2, 2, 0);
}

fn usingGles3(ctx: OCtx) bool {
    return using(ctx, c.GST_GL_API_GLES2, 3, 0);
}

fn finfoOf(f: Fmt) FInfo {
    return c.gst_video_format_get_info(f);
}

fn flags(fi: FInfo) c.guint {
    return @bitCast(fi[0].flags);
}

fn isRgb(fi: FInfo) bool {
    return flags(fi) & c.GST_VIDEO_FORMAT_FLAG_RGB != 0;
}

fn isYuv(fi: FInfo) bool {
    return flags(fi) & c.GST_VIDEO_FORMAT_FLAG_YUV != 0;
}

fn isGray(fi: FInfo) bool {
    return flags(fi) & c.GST_VIDEO_FORMAT_FLAG_GRAY != 0;
}

fn hasAlpha(fi: FInfo) bool {
    return flags(fi) & c.GST_VIDEO_FORMAT_FLAG_ALPHA != 0;
}

fn isTiled(fi: FInfo) bool {
    return flags(fi) & c.GST_VIDEO_FORMAT_FLAG_TILED != 0;
}

fn fmtOf(i: anytype) Fmt {
    return i.finfo[0].format;
}

fn identity() M4 {
    var m: M4 = undefined;
    for (0..4) |i| {
        for (0..4) |j| m[i][j] = if (i == j) 1 else 0;
    }
    return m;
}

fn mul(a: M4, b: M4) M4 {
    var r: M4 = undefined;
    for (0..4) |i| {
        for (0..4) |j| {
            var x: f64 = 0;
            for (0..4) |k| x += a[i][k] * b[k][j];
            r[i][j] = x;
        }
    }
    return r;
}

fn toFloat(m: *const M4, out: *[16]f32) void {
    for (0..4) |i| {
        for (0..4) |j| out[j * 4 + i] = @floatCast(m[i][j]);
    }
}

fn offsetBy(m: *M4, a1: f64, a2: f64, a3: f64) void {
    var a = identity();
    a[0][3] = a1;
    a[1][3] = a2;
    a[2][3] = a3;
    m.* = mul(a, m.*);
}

fn scaleBy(m: *M4, a1: f64, a2: f64, a3: f64) void {
    var a = identity();
    a[0][0] = a1;
    a[1][1] = a2;
    a[2][2] = a3;
    m.* = mul(a, m.*);
}

fn ycbcrToRgb(m: *M4, kr: f64, kb: f64) void {
    const kg = 1.0 - kr - kb;
    const k = M4{
        .{ 1, 0, 2 * (1 - kr), 0 },
        .{ 1, -2 * kb * (1 - kb) / kg, -2 * kr * (1 - kr) / kg, 0 },
        .{ 1, 2 * (1 - kb), 0, 0 },
        .{ 0, 0, 0, 1 },
    };
    m.* = mul(k, m.*);
}

fn rgbToYcbcr(m: *M4, kr: f64, kb: f64) void {
    const kg = 1.0 - kr - kb;
    const x1 = 1 / (2 * (1 - kb));
    const x2 = 1 / (2 * (1 - kr));
    const k = M4{
        .{ kr, kg, kb, 0 },
        .{ -x1 * kr, -x1 * kg, x1 * (1 - kb), 0 },
        .{ x2 * (1 - kr), -x2 * kg, -x2 * kb, 0 },
        .{ 0, 0, 0, 1 },
    };
    m.* = mul(k, m.*);
}

const Range = struct { off: [4]c.gint, scale: [4]c.gint, depth: [3]f32 };

fn rangeOf(info: anytype) Range {
    var r: Range = undefined;
    const fi = finfoOf(fmtOf(info));
    c.gst_video_color_range_offsets(info.colorimetry.range, fi, &r.off, &r.scale);
    var d: [4]c.gint = undefined;
    for (0..fi[0].n_components) |i| d[i] = (@as(c.gint, 1) << @intCast(fi[0].depth[i])) - 1;
    for (0..3) |i| r.depth[i] = @floatFromInt(d[i]);
    return r;
}

fn f32of(x: c.gint) f32 {
    return @floatFromInt(x);
}

fn convertToRgb(info: *Info, vi: anytype) void {
    const m = &info.to_rgb;
    const r = rangeOf(vi);
    offsetBy(m, -f32of(r.off[0]) / r.depth[0], -f32of(r.off[1]) / r.depth[1], -f32of(r.off[2]) / r.depth[2]);
    scaleBy(m, r.depth[0] / f32of(r.scale[0]), r.depth[1] / f32of(r.scale[1]), r.depth[2] / f32of(r.scale[2]));
    if (isYuv(vi.finfo)) {
        var kr: f64 = 0;
        var kb: f64 = 0;
        if (c.gst_video_color_matrix_get_Kr_Kb(vi.colorimetry.matrix, &kr, &kb) != 0) ycbcrToRgb(m, kr, kb);
    }
}

fn convertToYuv(info: *Info, vi: anytype) void {
    const m = &info.to_yuv;
    if (isYuv(vi.finfo)) {
        var kr: f64 = 0;
        var kb: f64 = 0;
        if (c.gst_video_color_matrix_get_Kr_Kb(vi.colorimetry.matrix, &kr, &kb) != 0) rgbToYcbcr(m, kr, kb);
    }
    const r = rangeOf(vi);
    scaleBy(m, f32of(r.scale[0]) / r.depth[0], f32of(r.scale[1]) / r.depth[1], f32of(r.scale[2]) / r.depth[2]);
    offsetBy(m, f32of(r.off[0]) / r.depth[0], f32of(r.off[1]) / r.depth[1], f32of(r.off[2]) / r.depth[2]);
}

fn resetGl(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const p = pv(data);
    const gl = vt(ctx);
    if (p.vao != 0) {
        gl.DeleteVertexArrays.?(1, &p.vao);
        p.vao = 0;
    }
    if (p.vbo != 0) {
        gl.DeleteBuffers.?(1, &p.vbo);
        p.vbo = 0;
    }
    if (p.ibo != 0) {
        gl.DeleteBuffers.?(1, &p.ibo);
        p.ibo = 0;
    }
}

fn resetShader(cc: OConv) void {
    const info = &pv(cc).info;
    info.chroma = .{ 1, 1 };
    c.g_free(info.prog);
    info.prog = null;
    c.g_free(info.body);
    info.body = null;
    if (cc[0].shader != null) {
        c.gst_object_unref(cc[0].shader);
        cc[0].shader = null;
    }
    cc[0].initted = 0;
}

fn reset(cc: OConv) void {
    const p = pv(cc);
    if (cc[0].fbo != null) {
        c.gst_object_unref(cc[0].fbo);
        cc[0].fbo = null;
    }
    var i: usize = 0;
    while (i < @as(usize, @intCast(@max(p.info.out_n, 0)))) : (i += 1) {
        if (p.out_tex[i] != null) c.gst_memory_unref(@ptrCast(p.out_tex[i]));
        p.out_tex[i] = null;
    }
    if (p.pool != null) {
        p.pool_started = 0;
        c.gst_object_unref(p.pool);
        p.pool = null;
    }
    _ = c.gst_caps_replace(&p.in_caps, null);
    _ = c.gst_caps_replace(&p.out_caps, null);
    if (cc[0].context != null) c.gst_gl_context_thread_add(cc[0].context, resetGl, cc);
    resetShader(cc);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const cc = cv(o);
    reset(cc);
    if (cc[0].context != null) {
        c.gst_object_unref(cc[0].context);
        cc[0].context = null;
    }
    parent.?.finalize.?(o);
}

pub export fn gst_gl_color_convert_new(ctx: OCtx) OConv {
    const cc = cv(c.g_object_new(gst_gl_color_convert_get_type(), null));
    _ = c.gst_object_ref_sink(cc);
    cc[0].context = @ptrCast(@alignCast(c.gst_object_ref(ctx)));
    _ = c.gst_video_info_set_format(&cc[0].in_info, c.GST_VIDEO_FORMAT_ENCODED, 0, 0);
    _ = c.gst_video_info_set_format(&cc[0].out_info, c.GST_VIDEO_FORMAT_ENCODED, 0, 0);
    return cc;
}

fn canPassthrough(in: *const c.GstVideoInfo, out: *const c.GstVideoInfo) bool {
    if (fmtOf(in) != fmtOf(out) or in.width != out.width or in.height != out.height or in.size != out.size) return false;
    for (0..in.finfo[0].n_planes) |i| {
        if (in.stride[i] != out.stride[i] or in.offset[i] != out.offset[i]) return false;
    }
    if (c.gst_video_colorimetry_is_equal(&in.colorimetry, &out.colorimetry) == 0) return false;
    return in.chroma_site == out.chroma_site;
}

fn yuvToYuv(fi: FInfo) bool {
    if (isYuv(fi) and fi[0].n_planes == fi[0].n_components) return true;
    const f = fi[0].format;
    return f == c.GST_VIDEO_FORMAT_v210 or f == c.GST_VIDEO_FORMAT_UYVY or f == c.GST_VIDEO_FORMAT_YUY2;
}

fn supported(in: FInfo, out: FInfo) bool {
    return isRgb(in) or isRgb(out) or (yuvToYuv(in) and yuvToYuv(out));
}

fn targetOf(s: ?*const c.GstStructure) c.GstGLTextureTarget {
    if (c.gst_structure_has_field_typed(s, "texture-target", c.G_TYPE_STRING) == 0) return c.GST_GL_TEXTURE_TARGET_2D;
    return format.gst_gl_texture_target_from_string(c.gst_structure_get_string(s, "texture-target"));
}

fn setCapsUnlocked(cc: OConv, in_caps: OCaps, out_caps: OCaps) bool {
    const fname = "_gst_gl_color_convert_set_caps_unlocked";
    if (!check.that(cc != null, fname, "convert != NULL")) return false;
    if (!check.that(in_caps != null, fname, "in_caps")) return false;
    if (!check.that(out_caps != null, fname, "out_caps")) return false;
    var in: c.GstVideoInfo = undefined;
    var out: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&in, in_caps) == 0) check.assertFail("gstglcolorconvert.c", 1406, fname, null);
    if (c.gst_video_info_from_caps(&out, out_caps) == 0) check.assertFail("gstglcolorconvert.c", 1409, fname, null);
    if (!check.that(fmtOf(&in) != c.GST_VIDEO_FORMAT_UNKNOWN, fname, "GST_VIDEO_INFO_FORMAT (&in_info) != GST_VIDEO_FORMAT_UNKNOWN")) return false;
    if (!check.that(fmtOf(&in) != c.GST_VIDEO_FORMAT_ENCODED, fname, "GST_VIDEO_INFO_FORMAT (&in_info) != GST_VIDEO_FORMAT_ENCODED")) return false;
    if (!check.that(fmtOf(&out) != c.GST_VIDEO_FORMAT_UNKNOWN, fname, "GST_VIDEO_INFO_FORMAT (&out_info) != GST_VIDEO_FORMAT_UNKNOWN")) return false;
    if (!check.that(fmtOf(&out) != c.GST_VIDEO_FORMAT_ENCODED, fname, "GST_VIDEO_INFO_FORMAT (&out_info) != GST_VIDEO_FORMAT_ENCODED")) return false;
    if (c.gst_caps_features_contains(c.gst_caps_get_features(in_caps, 0), "memory:GLMemory") == 0 or c.gst_caps_features_contains(c.gst_caps_get_features(out_caps, 0), "memory:GLMemory") == 0) return false;
    const from = targetOf(c.gst_caps_get_structure(in_caps, 0));
    const to = targetOf(c.gst_caps_get_structure(out_caps, 0));
    if (to == c.GST_GL_TEXTURE_TARGET_NONE or from == c.GST_GL_TEXTURE_TARGET_NONE) return false;
    const p = pv(cc);
    if (c.gst_video_info_is_equal(&cc[0].in_info, &in) != 0 and c.gst_video_info_is_equal(&cc[0].out_info, &out) != 0 and p.from == from and p.to == to) return true;
    const pass = canPassthrough(&in, &out) and from == to;
    if (!pass and to != c.GST_GL_TEXTURE_TARGET_2D and to != c.GST_GL_TEXTURE_TARGET_RECTANGLE) return false;
    if (!pass and !supported(in.finfo, out.finfo)) return false;
    reset(cc);
    cc[0].in_info = in;
    cc[0].out_info = out;
    _ = c.gst_caps_replace(&p.in_caps, in_caps);
    _ = c.gst_caps_replace(&p.out_caps, out_caps);
    p.from = from;
    p.to = to;
    p.padded_w = in.width;
    p.padded_h = in.height;
    cc[0].initted = 0;
    cc[0].passthrough = @intFromBool(pass);
    return true;
}

pub export fn gst_gl_color_convert_set_caps(cc: OConv, in_caps: OCaps, out_caps: OCaps) c.gboolean {
    objLock(cc);
    defer objUnlock(cc);
    return @intFromBool(setCapsUnlocked(cc, in_caps, out_caps));
}

pub export fn gst_gl_color_convert_decide_allocation(cc: OConv, q: ?*c.GstQuery) c.gboolean {
    var caps: OCaps = null;
    c.gst_query_parse_allocation(q, &caps, null);
    if (caps == null) return 0;
    var vinfo: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_from_caps(&vinfo, caps);
    var pool: [*c]c.GstBufferPool = null;
    var size: c.guint = 0;
    var min: c.guint = 0;
    var max: c.guint = 0;
    var update = false;
    const n = c.gst_query_get_n_allocation_pools(q);
    if (n > 0) {
        update = true;
        var i: c.guint = 0;
        while (i < n) : (i += 1) {
            c.gst_query_parse_nth_allocation_pool(q, i, &pool, &size, &min, &max);
            if (pool == null or !gtype.instanceOf(pool, bufferpool.gst_gl_buffer_pool_get_type())) {
                if (pool != null) c.gst_object_unref(pool);
                pool = null;
            }
        }
    }
    if (pool == null) {
        size = 0;
        min = 0;
        max = 0;
        update = false;
        pool = bufferpool.gst_gl_buffer_pool_new(cc[0].context);
    }
    const cfg = c.gst_buffer_pool_get_config(pool);
    c.gst_buffer_pool_config_set_params(cfg, caps, size, min, max);
    c.gst_buffer_pool_config_add_option(cfg, "GstBufferPoolOptionVideoMeta");
    if (c.gst_query_find_allocation_meta(q, syncmeta.gst_gl_sync_meta_api_get_type(), null) != 0) c.gst_buffer_pool_config_add_option(cfg, "GstBufferPoolOptionGLSyncMeta");
    const params = memory.gst_gl_video_allocation_params_new(cc[0].context, null, &vinfo, 0, null, pv(cc).to, 0);
    bufferpool.gst_buffer_pool_config_set_gl_allocation_params(cfg, @ptrCast(params));
    basememory.gst_gl_allocation_params_free(@ptrCast(params));
    _ = c.gst_buffer_pool_set_config(pool, cfg);
    if (update) c.gst_query_set_nth_allocation_pool(q, 0, pool, size, min, max) else c.gst_query_add_allocation_pool(q, pool, size, min, max);
    const p = pv(cc);
    if (p.pool != null) {
        c.gst_object_unref(p.pool);
        p.pool_started = 0;
    }
    p.pool = pool;
    return 1;
}

fn strList(list: *c.GValue, comptime names: []const S) void {
    for (names) |s| {
        var item = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&item, c.G_TYPE_STRING);
        c.g_value_set_string(&item, s);
        c.gst_value_list_append_value(list, &item);
        c.g_value_unset(&item);
    }
}

fn newList(list: *c.GValue, comptime names: []const S) void {
    _ = c.g_value_init(list, c.gst_value_list_get_type());
    strList(list, names);
}

fn fmtOk(ctx: OCtx, f: c.GstGLFormat) bool {
    return ctx == null or format.gst_gl_format_is_supported(ctx, f) != 0;
}

fn supportedFormats(ctx: OCtx, output: bool, v: *c.GValue) void {
    newList(v, &.{ "RGBA", "RGB", "RGBx", "BGR", "BGRx", "BGRA", "xRGB", "xBGR", "ARGB", "ABGR", "GRAY8", "GRAY16_LE", "GRAY16_BE", "AYUV", "VUYA", "YUY2", "UYVY", "RBGA" });
    if (!output or ctx == null or vt(ctx).DrawBuffers != null) strList(v, &.{ "GBRA", "GBR", "RGBP", "BGRP", "Y444", "I420", "YV12", "Y42B", "Y41B", "NV12", "NV21", "NV16", "NV61", "NV24", "A420", "AV12", "A444", "A422" });
    if (ctx == null or usingGles3(ctx) or usingGl(ctx)) strList(v, &.{ "YUY2", "UYVY" });
    if (fmtOk(ctx, c.GST_GL_RGBA16)) strList(v, &.{ "ARGB64", "RGBA64_LE" });
    if (fmtOk(ctx, c.GST_GL_RGB565)) strList(v, &.{ "RGB16", "BGR16" });
    if (fmtOk(ctx, c.GST_GL_RGB10_A2)) strList(v, &.{ "BGR10A2_LE", "RGB10A2_LE", "BGR10x2_LE", "RGB10x2_LE", "Y410", "v210" });
    if (ctx == null or (format.gst_gl_format_is_supported(ctx, c.GST_GL_R16) != 0 and format.gst_gl_format_is_supported(ctx, c.GST_GL_RG16) != 0)) strList(v, &.{ "P010_10LE", "P012_LE", "P016_LE" });
    if (fmtOk(ctx, c.GST_GL_RG16)) strList(v, &.{ "Y210", "Y212_LE" });
    if (fmtOk(ctx, c.GST_GL_RGBA16)) strList(v, &.{"Y412_LE"});
    if (fmtOk(ctx, c.GST_GL_R16)) strList(v, &.{ "A420_10LE", "A422_10LE", "A444_10LE", "A444_12LE", "A422_12LE", "A420_12LE", "A444_16LE", "A422_16LE", "A420_16LE", "I420_12LE", "I420_10LE", "I422_10LE", "I422_12LE", "Y444_10LE", "Y444_12LE", "Y444_16LE" });
    if (ctx == null or usingGles3(ctx) or usingGl30(ctx)) strList(v, &.{ "NV12_16L32S", "NV12_4L4" });
}

fn infoOfString(v: [*c]const c.GValue) FInfo {
    return finfoOf(c.gst_video_format_from_string(c.g_value_get_string(v)));
}

fn appendCopy(res: OCaps, st: [*c]c.GstStructure, f: ?*c.GstCapsFeatures) void {
    c.gst_caps_append_structure_full(res, c.gst_structure_copy(st), c.gst_caps_features_copy(f));
}

fn dropColor(st: [*c]c.GstStructure) void {
    c.gst_structure_remove_fields(st, "colorimetry", "chroma-site", "texture-target", @as(?*anyopaque, null));
}

fn splitYuv(res: OCaps, st: [*c]c.GstStructure, f: ?*c.GstCapsFeatures, planar: bool, planar_fmts: *c.GValue, rgb_fmts: *c.GValue) void {
    if (planar) {
        appendCopy(res, st, f);
        c.gst_structure_set_value(st, "format", planar_fmts);
        c.gst_structure_remove_fields(st, "texture-target", @as(?*anyopaque, null));
    }
    appendCopy(res, st, f);
    c.gst_structure_set_value(st, "format", rgb_fmts);
    dropColor(st);
}

fn transformFormatInfo(ctx: OCtx, output: bool, caps: OCaps) OCaps {
    var all = std.mem.zeroes(c.GValue);
    var rgb = std.mem.zeroes(c.GValue);
    var rgb_ok = std.mem.zeroes(c.GValue);
    var planar = std.mem.zeroes(c.GValue);
    var planar_ok = std.mem.zeroes(c.GValue);
    newList(&rgb, &.{ "RGBA", "ARGB", "BGRA", "ABGR", "RGBx", "xRGB", "BGRx", "xBGR", "RGB", "BGR", "ARGB64", "BGR10A2_LE", "RGB10A2_LE", "BGR10x2_LE", "RGB10x2_LE", "RGBA64_LE", "RGBA64_BE", "RBGA", "GBRA", "GBR", "RGBP", "BGRP", "RGB16", "BGR16" });
    newList(&planar, &.{ "Y444", "Y444_10LE", "Y444_12LE", "Y444_16LE", "Y444_10BE", "Y444_12BE", "Y444_16BE", "I420", "Y42B", "Y41B", "A420", "A444", "A422", "A420_10LE", "A422_10LE", "A444_10LE", "A444_12LE", "A422_12LE", "A420_12LE", "A444_16LE", "A422_16LE", "A420_16LE", "I420_12LE", "I420_10LE", "I422_10LE", "I422_12LE", "A420_10BE", "A422_10BE", "A444_10BE", "A444_12BE", "A422_12BE", "A420_12BE", "A444_16BE", "A422_16BE", "A420_16BE", "I420_12BE", "I420_10BE", "I422_10BE", "I422_12BE", "v210", "UYVY", "YUY2" });
    supportedFormats(ctx, output, &all);
    _ = c.gst_value_intersect(&rgb_ok, &rgb, &all);
    _ = c.gst_value_intersect(&planar_ok, &planar, &all);
    const res = c.gst_caps_new_empty();
    var i: c.guint = 0;
    const n = c.gst_caps_get_size(caps);
    while (i < n) : (i += 1) {
        const f = c.gst_caps_get_features(caps, i);
        const src = c.gst_caps_get_structure(caps, i);
        const fv = c.gst_structure_get_value(src, "format");
        const st = c.gst_structure_copy(src);
        if (c.gst_caps_features_is_any(f) == 0 and c.gst_caps_features_contains(f, "memory:GLMemory") != 0) {
            if (fv != null and fv[0].g_type == c.gst_value_list_get_type()) {
                var have_rgb = false;
                var have_planar = false;
                var pass = std.mem.zeroes(c.GValue);
                _ = c.g_value_init(&pass, c.gst_value_list_get_type());
                var j: c.guint = 0;
                while (j < c.gst_value_list_get_size(fv)) : (j += 1) {
                    const val = c.gst_value_list_get_value(fv, j);
                    if (c.g_type_check_value_holds(@constCast(val), c.G_TYPE_STRING) == 0) continue;
                    const ti = infoOfString(val);
                    if (flags(ti) & (c.GST_VIDEO_FORMAT_FLAG_YUV | c.GST_VIDEO_FORMAT_FLAG_GRAY) != 0) {
                        c.gst_value_list_append_value(&pass, val);
                    } else if (flags(ti) & c.GST_VIDEO_FORMAT_FLAG_RGB != 0) {
                        have_rgb = true;
                        break;
                    } else if (yuvToYuv(ti)) have_planar = true;
                }
                if (have_rgb) {
                    c.gst_structure_set_value(st, "format", &all);
                    dropColor(st);
                } else {
                    c.gst_structure_set_value(st, "format", &pass);
                    splitYuv(res, st, f, have_planar, &planar_ok, &rgb_ok);
                }
                c.g_value_unset(&pass);
            } else if (fv != null and c.g_type_check_value_holds(@constCast(fv), c.G_TYPE_STRING) != 0) {
                const ti = infoOfString(fv);
                if (isRgb(ti)) {
                    c.gst_structure_set_value(st, "format", &all);
                    dropColor(st);
                } else {
                    c.gst_structure_set_value(st, "format", fv);
                    splitYuv(res, st, f, yuvToYuv(ti), &planar_ok, &rgb_ok);
                }
            }
        }
        c.gst_caps_append_structure_full(res, st, c.gst_caps_features_copy(f));
    }
    c.g_value_unset(&all);
    c.g_value_unset(&rgb);
    c.g_value_unset(&rgb_ok);
    c.g_value_unset(&planar);
    c.g_value_unset(&planar_ok);
    return res;
}

pub export fn gst_gl_color_convert_transform_caps(ctx: OCtx, dir: c.GstPadDirection, in_caps: OCaps, filter: OCaps) OCaps {
    var caps = transformFormatInfo(ctx, dir == c.GST_PAD_SINK, in_caps);
    if (filter != null) {
        const t = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(caps);
        caps = t;
    }
    return caps;
}

fn demask(m: c.guint) c.GstGLTextureTarget {
    if (m & (1 << c.GST_GL_TEXTURE_TARGET_2D) != 0) return c.GST_GL_TEXTURE_TARGET_2D;
    if (m & (1 << c.GST_GL_TEXTURE_TARGET_RECTANGLE) != 0) return c.GST_GL_TEXTURE_TARGET_RECTANGLE;
    if (m & (1 << c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES) != 0) return c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES;
    return 0;
}

const Score = struct {
    loss: c.gint = std.math.maxInt(c.gint),
    out: FInfo = null,
    target: c.GstGLTextureTarget = c.GST_GL_TEXTURE_TARGET_NONE,
};

fn scoreFormat(in: FInfo, mask: c.guint, f: Fmt, other_in: c.guint, sc: *Score) void {
    const t = finfoOf(f);
    if (t == null) return;
    var other = other_in;
    if (in == t and mask & other != 0) {
        sc.* = .{ .loss = 0, .out = t, .target = demask(mask & other) };
        return;
    }
    other &= ~@as(c.guint, 1 << c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES);
    if (mask & other != 0) other &= mask;
    const strip: c.guint = c.GST_VIDEO_FORMAT_FLAG_LE | c.GST_VIDEO_FORMAT_FLAG_COMPLEX | c.GST_VIDEO_FORMAT_FLAG_UNPACK;
    const inf = flags(in) & ~strip;
    const tf = flags(t) & ~strip;
    if (!supported(in, t)) return;
    var loss: c.gint = 1;
    const PAL: c.guint = c.GST_VIDEO_FORMAT_FLAG_PALETTE;
    const CS: c.guint = c.GST_VIDEO_FORMAT_FLAG_YUV | c.GST_VIDEO_FORMAT_FLAG_RGB | c.GST_VIDEO_FORMAT_FLAG_GRAY;
    const AL: c.guint = c.GST_VIDEO_FORMAT_FLAG_ALPHA;
    if (tf & PAL != inf & PAL) {
        loss += 1;
        if (tf & PAL != 0) loss += 64;
    }
    if (tf & CS != inf & CS) {
        loss += 2;
        if (tf & c.GST_VIDEO_FORMAT_FLAG_GRAY != 0) loss += 128;
    }
    if (tf & AL != inf & AL) {
        loss += 1;
        if (inf & AL != 0) loss += 8;
    }
    if (in[0].h_sub[1] != t[0].h_sub[1]) {
        loss += 1;
        if (in[0].h_sub[1] < t[0].h_sub[1]) loss += 32;
    }
    if (in[0].w_sub[1] != t[0].w_sub[1]) {
        loss += 1;
        if (in[0].w_sub[1] < t[0].w_sub[1]) loss += 16;
    }
    if (in[0].bits != t[0].bits) {
        loss += 1;
        if (in[0].bits > t[0].bits) loss += 4;
    }
    if (loss < sc.loss) sc.* = .{ .loss = loss, .out = t, .target = demask(other) };
}

fn fixateFormatTarget(caps: OCaps, result: OCaps) void {
    const ins = c.gst_caps_get_structure(caps, 0);
    const in_fmt = c.gst_structure_get_string(ins, "format");
    if (in_fmt == null) return;
    const tv = c.gst_structure_get_value(ins, "texture-target");
    const mask: c.guint = if (tv != null) @bitCast(utils.gst_gl_value_get_texture_target_mask(tv)) else 0;
    const in = finfoOf(c.gst_video_format_from_string(in_fmt));
    if (in == null) return;
    const outs = c.gst_caps_get_structure(result, 0);
    var sc = Score{};
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(result)) : (i += 1) {
        const tests = c.gst_caps_get_structure(result, i);
        const fv = c.gst_structure_get_value(tests, "format");
        if (fv == null) continue;
        const ov = c.gst_structure_get_value(tests, "texture-target");
        const other: c.guint = if (ov != null) @bitCast(utils.gst_gl_value_get_texture_target_mask(ov)) else 0;
        if (fv[0].g_type == c.gst_value_list_get_type()) {
            var j: c.guint = 0;
            while (j < c.gst_value_list_get_size(fv)) : (j += 1) {
                const val = c.gst_value_list_get_value(fv, j);
                if (c.g_type_check_value_holds(@constCast(val), c.G_TYPE_STRING) == 0) continue;
                scoreFormat(in, mask, c.gst_video_format_from_string(c.g_value_get_string(val)), other, &sc);
                if (sc.loss == 0) break;
            }
        } else if (c.g_type_check_value_holds(@constCast(fv), c.G_TYPE_STRING) != 0) {
            scoreFormat(in, mask, c.gst_video_format_from_string(c.g_value_get_string(fv)), other, &sc);
        }
    }
    if (sc.out != null) c.gst_structure_set(outs, "format", c.G_TYPE_STRING, sc.out[0].name, @as(?*anyopaque, null));
    if (sc.target != c.GST_GL_TEXTURE_TARGET_NONE) c.gst_structure_set(outs, "texture-target", c.G_TYPE_STRING, format.gst_gl_texture_target_to_string(sc.target), @as(?*anyopaque, null));
}

pub export fn gst_gl_color_convert_fixate_caps(_: OCtx, dir: c.GstPadDirection, caps: OCaps, other: OCaps) OCaps {
    var result = c.gst_caps_intersect(other, caps);
    if (c.gst_caps_is_empty(result) != 0) {
        c.gst_caps_unref(result);
        result = other;
    } else c.gst_caps_unref(other);
    result = c.gst_caps_make_writable(result);
    fixateFormatTarget(caps, result);
    result = c.gst_caps_fixate(result);
    if (dir == c.GST_PAD_SINK and c.gst_caps_is_subset(caps, result) != 0) _ = c.gst_caps_replace(&result, caps);
    return result;
}

fn performUnlocked(cc: OConv, in: OBuf) OBuf {
    const fname = "_gst_gl_color_convert_perform_unlocked";
    if (!check.that(cc != null, fname, "convert != NULL")) return null;
    if (!check.that(in != null, fname, "inbuf")) return null;
    if (cc[0].passthrough != 0) return c.gst_buffer_ref(in);
    cc[0].inbuf = in;
    c.gst_gl_context_thread_add(cc[0].context, doConvert, cc);
    if (pv(cc).result == 0) {
        if (cc[0].outbuf != null) c.gst_buffer_unref(cc[0].outbuf);
        cc[0].outbuf = null;
        return null;
    }
    return cc[0].outbuf;
}

pub export fn gst_gl_color_convert_perform(cc: OConv, in: OBuf) OBuf {
    if (!check.that(cc != null, "gst_gl_color_convert_perform", "convert != NULL")) return null;
    objLock(cc);
    defer objUnlock(cc);
    return performUnlocked(cc, in);
}

fn isRGBx(f: Fmt) bool {
    return switch (f) {
        c.GST_VIDEO_FORMAT_RGBx, c.GST_VIDEO_FORMAT_xRGB, c.GST_VIDEO_FORMAT_BGRx, c.GST_VIDEO_FORMAT_xBGR => true,
        else => false,
    };
}

fn isPlanarRgb(f: Fmt) bool {
    return switch (f) {
        c.GST_VIDEO_FORMAT_GBR, c.GST_VIDEO_FORMAT_RGBP, c.GST_VIDEO_FORMAT_BGRP, c.GST_VIDEO_FORMAT_GBR_10BE, c.GST_VIDEO_FORMAT_GBR_10LE, c.GST_VIDEO_FORMAT_GBRA, c.GST_VIDEO_FORMAT_GBRA_10BE, c.GST_VIDEO_FORMAT_GBRA_10LE, c.GST_VIDEO_FORMAT_GBR_12BE, c.GST_VIDEO_FORMAT_GBR_12LE, c.GST_VIDEO_FORMAT_GBRA_12BE, c.GST_VIDEO_FORMAT_GBRA_12LE => true,
        else => false,
    };
}

fn glReorder(f: Fmt, r: *[4]c_int, input: bool) void {
    switch (f) {
        c.GST_VIDEO_FORMAT_v210 => r.* = .{ 0, 1, 2, 3 },
        c.GST_VIDEO_FORMAT_UYVY => r.* = .{ 1, 0, if (input) 0 else 2, 0 },
        c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_Y210, c.GST_VIDEO_FORMAT_Y212_LE, c.GST_VIDEO_FORMAT_Y212_BE => r.* = .{ 0, 1, if (input) 1 else 0, 2 },
        c.GST_VIDEO_FORMAT_GBR => r.* = if (input) .{ 2, 0, 1, 3 } else .{ 0, 1, 2, 3 },
        else => if (format.gst_gl_video_format_swizzle(f, r) == 0) check.assertFail("gstglcolorconvert.c", 2285, "video_format_to_gl_reorder", null),
    }
}

fn reorder(in: Fmt, out: Fmt, ret_in: *[MAXP]c_int, ret_out: *[MAXP]c_int) void {
    var ri = [4]c_int{ 0, 0, 0, 0 };
    var ro = [4]c_int{ 0, 0, 0, 0 };
    glReorder(in, &ri, true);
    glReorder(out, &ro, false);
    if (out == c.GST_VIDEO_FORMAT_YUY2 or out == c.GST_VIDEO_FORMAT_UYVY) ret_out.* = ro else format.gst_gl_swizzle_invert(&ro, ret_out);
    ret_in.* = ri;
}

fn nTextures(f: Fmt) c.gint {
    return @intCast(finfoOf(f)[0].n_planes);
}

fn isPlanar(f: Fmt) bool {
    const fi = finfoOf(f);
    return fi[0].n_planes == fi[0].n_components;
}

fn setNames(info: *Info, names: []const S) void {
    for (names, 0..) |n, i| info.names[i] = n;
}

fn useTempl(info: *Info, t: *const Templ, body: [*c]u8) void {
    info.templ = t;
    info.body = body;
}

fn dup(s: S) [*c]u8 {
    return c.g_strdup(s);
}

fn ioFormats(cc: OConv) struct { in: Fmt, out: Fmt } {
    return .{ .in = fmtOf(&cc[0].in_info), .out = fmtOf(&cc[0].out_info) };
}

fn planarRgbAlpha(cc: OConv, info: *Info) S {
    if (hasAlpha(cc[0].in_info.finfo)) {
        setNames(info, &.{ "Rtex", "Gtex", "Btex", "Atex" });
        return "rgba.a = texture2D(Atex, texcoord * tex_scale3).r;";
    }
    setNames(info, &.{ "Rtex", "Gtex", "Btex" });
    return "rgba.a = 1.0;";
}

fn rgbToRgb(cc: OConv, info: *Info) void {
    const f = ioFormats(cc);
    const in_planar = isPlanarRgb(f.in);
    const out_planar = isPlanarRgb(f.out);
    if (in_planar or out_planar) {
        reorder(f.in, f.out, &info.in_swizzle, &info.out_swizzle);
        info.prog = null;
    }
    if (in_planar and out_planar) {
        const a = planarRgbAlpha(cc, info);
        const out_alpha: S = if (hasAlpha(cc[0].out_info.finfo)) "gl_FragData[3] = vec4(rgba.a, 0, 0, 1.0);\n" else "\n";
        info.out_n = if (hasAlpha(cc[0].out_info.finfo)) 4 else 3;
        useTempl(info, &T_PRGB_PRGB, c.g_strdup_printf(B_PRGB_PRGB, a, out_alpha));
    } else if (in_planar) {
        const a = planarRgbAlpha(cc, info);
        info.out_n = 1;
        useTempl(info, &T_PRGB_RGB, c.g_strdup_printf(B_PRGB_RGB, a));
    } else if (out_planar) {
        info.names[0] = "tex";
        const a: S = if (hasAlpha(cc[0].out_info.finfo)) "gl_FragData[3] = vec4(rgba.a, 0, 0, 1.0);" else "";
        info.out_n = if (hasAlpha(cc[0].out_info.finfo)) 4 else 3;
        useTempl(info, &T_RGB_PRGB, c.g_strdup_printf(B_RGB_PRGB, a));
    } else {
        if (isRGBx(f.in)) useTempl(info, &T_REORDER, dup(B_REORDER_OPAQUE)) else useTempl(info, &T_REORDER, dup(B_REORDER));
        info.names[0] = "tex";
        reorder(f.in, f.out, &info.in_swizzle, &info.out_swizzle);
    }
}

fn rectangularApple(cc: OConv) bool {
    const p = pv(cc);
    var rect = false;
    const m = c.gst_buffer_peek_memory(cc[0].inbuf, 0);
    if (memory.gst_is_gl_memory(m) != 0 and (usingGl(cc[0].context) or usingGl3(cc[0].context))) rect = p.from == c.GST_GL_TEXTURE_TARGET_RECTANGLE;
    return rect and context.gst_gl_context_check_feature(cc[0].context, "GL_APPLE_ycbcr_422") != 0 and c.gst_buffer_n_memory(cc[0].inbuf) == 1;
}

fn inDepth(fi: FInfo) f32 {
    const b: u5 = @intCast(fi[0].bits);
    const r: u5 = @intCast((fi[0].bits + 7) & ~@as(c.guint, 7));
    return @as(f32, @floatFromInt((@as(u32, 1) << r) - 1)) / @as(f32, @floatFromInt((@as(u32, 1) << b) - 1));
}

fn outDepthExact(fi: FInfo) f32 {
    const b: u5 = @intCast(fi[0].bits);
    const r: u5 = @intCast((fi[0].bits + 7) & ~@as(c.guint, 7));
    return @as(f32, @floatFromInt((@as(u32, 1) << b) - 1)) / @as(f32, @floatFromInt((@as(u32, 1) << r) - 1));
}

fn chromaFrom(fi: FInfo) [2]f32 {
    return .{ @floatFromInt(@as(u32, 1) << @intCast(fi[0].w_sub[1])), @floatFromInt(@as(u32, 1) << @intCast(fi[0].h_sub[1])) };
}

fn uvChannel(p: *Priv) c_int {
    return if (p.in_formats[1] == c.GST_GL_LUMINANCE_ALPHA) 'a' else 'g';
}

fn yuvToRgb(cc: OConv, info: *Info) void {
    const f = ioFormats(cc);
    const p = pv(cc);
    const fi = finfoOf(f.in);
    info.out_n = 1;
    info.out_depth = 1.0;
    reorder(f.in, f.out, &info.in_swizzle, &info.out_swizzle);
    if (rectangularApple(cc)) {
        useTempl(info, &T_REORDER, dup(B_REORDER));
        info.names[0] = "tex";
    } else if (fi[0].n_planes >= 3 and isPlanar(f.in)) {
        setNames(info, &.{ "Ytex", "Utex", "Vtex" });
        info.in_depth = inDepth(fi);
        if (hasAlpha(fi)) {
            useTempl(info, &T_A420_RGB, dup(B_PLANAR_A_RGB));
            info.names[3] = "Atex";
        } else useTempl(info, &T_PLANAR_RGB, dup(B_PLANAR_RGB));
    } else switch (f.in) {
        c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_VUYA, c.GST_VIDEO_FORMAT_Y410, c.GST_VIDEO_FORMAT_Y412_LE, c.GST_VIDEO_FORMAT_Y412_BE => {
            useTempl(info, &T_AYUV_RGB, dup(B_AYUV_RGB));
            info.names[0] = "tex";
        },
        c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_UYVY, c.GST_VIDEO_FORMAT_Y210, c.GST_VIDEO_FORMAT_Y212_LE, c.GST_VIDEO_FORMAT_Y212_BE => {
            if (p.in_formats[0] == c.GST_GL_LUMINANCE_ALPHA) {
                if (f.in == c.GST_VIDEO_FORMAT_YUY2) {
                    info.in_swizzle[1] = 3;
                    info.in_swizzle[2] = 3;
                } else if (f.in == c.GST_VIDEO_FORMAT_UYVY) info.in_swizzle[0] = 3;
            }
            useTempl(info, &T_YUY2_RGB, dup(B_YUY2_RGB));
            info.names[0] = "Ytex";
        },
        c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_NV16, c.GST_VIDEO_FORMAT_NV24, c.GST_VIDEO_FORMAT_NV21, c.GST_VIDEO_FORMAT_NV61, c.GST_VIDEO_FORMAT_P010_10LE, c.GST_VIDEO_FORMAT_P010_10BE, c.GST_VIDEO_FORMAT_P012_LE, c.GST_VIDEO_FORMAT_P012_BE, c.GST_VIDEO_FORMAT_P016_LE, c.GST_VIDEO_FORMAT_P016_BE => {
            useTempl(info, &T_SEMI_RGB, c.g_strdup_printf(B_SEMI_RGB, uvChannel(p), "yuva.a = 1.0;\n"));
            setNames(info, &.{ "Ytex", "UVtex" });
        },
        c.GST_VIDEO_FORMAT_AV12 => {
            useTempl(info, &T_AV12_RGB, c.g_strdup_printf(B_SEMI_RGB, uvChannel(p), "yuva.a = texture2D(Atex, texcoord * tex_scale2).r;\n"));
            setNames(info, &.{ "Ytex", "UVtex", "Atex" });
        },
        c.GST_VIDEO_FORMAT_NV12_16L32S => {
            useTempl(info, &T_TILED_RGB, c.g_strdup_printf(B_TILED_RGB, @as(c_int, 16), @as(c_int, 32), @as(c_int, 8), @as(c_int, 16), @as(c_int, 'r'), uvChannel(p)));
            setNames(info, &.{ "Ytex", "UVtex" });
        },
        c.GST_VIDEO_FORMAT_NV12_4L4 => {
            useTempl(info, &T_TILED_RGB, c.g_strdup_printf(B_TILED_RGB, @as(c_int, 4), @as(c_int, 4), @as(c_int, 2), @as(c_int, 4), @as(c_int, 'r'), uvChannel(p)));
            setNames(info, &.{ "Ytex", "UVtex" });
        },
        c.GST_VIDEO_FORMAT_v210 => {
            useTempl(info, &T_V210_RGB, dup(B_V210_RGB));
            info.names[0] = "Ytex";
        },
        else => {},
    }
    convertToRgb(info, &cc[0].in_info);
}

fn rgbToYuv(cc: OConv, info: *Info) void {
    const f = ioFormats(cc);
    const fo = finfoOf(f.out);
    info.prog = null;
    info.names[0] = "tex";
    reorder(f.in, f.out, &info.in_swizzle, &info.out_swizzle);
    if (fo[0].n_planes >= 3 and isPlanar(f.out)) {
        if (hasAlpha(fo)) useTempl(info, &T_RGB_PLANAR_A, dup(B_RGB_PLANAR_A)) else useTempl(info, &T_RGB_PLANAR, dup(B_RGB_PLANAR));
        info.chroma = chromaFrom(fo);
        info.out_depth = outDepthExact(fo);
    } else switch (f.out) {
        c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_VUYA, c.GST_VIDEO_FORMAT_Y410, c.GST_VIDEO_FORMAT_Y412_LE, c.GST_VIDEO_FORMAT_Y412_BE => {
            const a: S = if (isRGBx(f.in)) "1.0" else "texel.a";
            useTempl(info, &T_RGB_AYUV, c.g_strdup_printf(B_RGB_AYUV, a));
        },
        c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_Y210, c.GST_VIDEO_FORMAT_Y212_LE, c.GST_VIDEO_FORMAT_Y212_BE, c.GST_VIDEO_FORMAT_UYVY => useTempl(info, &T_RGB_YUY2, dup(B_RGB_YUY2)),
        c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_NV16, c.GST_VIDEO_FORMAT_NV24, c.GST_VIDEO_FORMAT_NV21, c.GST_VIDEO_FORMAT_NV61 => {
            useTempl(info, &T_RGB_SEMI, c.g_strdup_printf(B_RGB_SEMI, ""));
            info.chroma = switch (f.out) {
                c.GST_VIDEO_FORMAT_NV16, c.GST_VIDEO_FORMAT_NV61 => .{ 2, 1 },
                c.GST_VIDEO_FORMAT_NV24 => .{ 1, 1 },
                else => .{ 2, 2 },
            };
        },
        c.GST_VIDEO_FORMAT_AV12 => {
            useTempl(info, &T_RGB_SEMI, c.g_strdup_printf(B_RGB_SEMI, "gl_FragData[2] = vec4(yuva.a, 0.0, 0.0, 1.0);\n"));
            info.chroma = .{ 2, 2 };
        },
        c.GST_VIDEO_FORMAT_v210 => useTempl(info, &T_RGB_V210, dup(B_RGB_V210)),
        else => {},
    }
    convertToYuv(info, &cc[0].out_info);
}

fn unreachableAt(line: c_int) noreturn {
    check.assertFail("gstglcolorconvert.c", line, "_YUV_to_YUV", null);
}

fn yuvToYuvConv(cc: OConv, info: *Info) void {
    const f = ioFormats(cc);
    const p = pv(cc);
    const fi = finfoOf(f.in);
    const fo = finfoOf(f.out);
    const in_planar = isPlanar(f.in);
    const out_planar = isPlanar(f.out);
    reorder(f.in, f.out, &info.in_swizzle, &info.out_swizzle);
    if (rectangularApple(cc)) {
        useTempl(info, &T_REORDER, dup(B_REORDER));
        info.names[0] = "tex";
    } else if (in_planar and out_planar) {
        info.chroma = chromaFrom(fo);
        setNames(info, &.{ "Ytex", "Utex", "Vtex" });
        info.in_depth = inDepth(fi);
        info.out_depth = outDepthExact(fo);
        if (!hasAlpha(fi)) {
            if (!hasAlpha(fo)) useTempl(info, &T_P_P, dup(B_P_P)) else useTempl(info, &T_P_PA, dup(B_P_PA));
        } else {
            info.names[3] = "Atex";
            if (!hasAlpha(fo)) useTempl(info, &T_PA_P, dup(B_PA_P)) else useTempl(info, &T_PA_PA, dup(B_PA_PA));
        }
    } else if (in_planar) {
        info.chroma = chromaFrom(fi);
        setNames(info, &.{ "Ytex", "Utex", "Vtex" });
        info.in_depth = inDepth(fi);
        switch (f.out) {
            c.GST_VIDEO_FORMAT_v210 => useTempl(info, &T_P_V210, dup(B_P_V210)),
            c.GST_VIDEO_FORMAT_UYVY, c.GST_VIDEO_FORMAT_YUY2 => useTempl(info, &T_P_YUY2, dup(B_P_YUY2)),
            else => unreachableAt(2841),
        }
    } else if (out_planar) {
        info.chroma = chromaFrom(fo);
        info.out_depth = outDepthExact(fo);
        switch (f.in) {
            c.GST_VIDEO_FORMAT_v210 => if (!hasAlpha(fo)) useTempl(info, &T_V210_P, dup(B_V210_P)) else useTempl(info, &T_V210_PA, dup(B_V210_PA)),
            c.GST_VIDEO_FORMAT_UYVY, c.GST_VIDEO_FORMAT_YUY2 => {
                if (p.in_formats[0] == c.GST_GL_LUMINANCE_ALPHA) {
                    if (f.in == c.GST_VIDEO_FORMAT_UYVY) {
                        info.in_swizzle[0] = 3;
                    } else {
                        info.in_swizzle[1] = 3;
                        info.in_swizzle[2] = 3;
                    }
                }
                if (!hasAlpha(fo)) useTempl(info, &T_YUY2_P, dup(B_YUY2_P)) else useTempl(info, &T_YUY2_PA, dup(B_YUY2_PA));
            },
            else => unreachableAt(2879),
        }
    } else switch (f.in) {
        c.GST_VIDEO_FORMAT_UYVY, c.GST_VIDEO_FORMAT_YUY2 => {
            info.names[0] = "tex";
            switch (f.out) {
                c.GST_VIDEO_FORMAT_v210 => useTempl(info, &T_YUY2_V210, dup(B_YUY2_V210)),
                c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_UYVY => useTempl(info, &T_YUY2_YUY2, dup(B_YUY2_YUY2)),
                else => unreachableAt(2898),
            }
        },
        c.GST_VIDEO_FORMAT_v210 => {
            info.names[0] = "tex";
            switch (f.out) {
                c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_UYVY => useTempl(info, &T_V210_YUY2, dup(B_V210_YUY2)),
                else => unreachableAt(2911),
            }
        },
        else => unreachableAt(2916),
    }
}

fn rgbToGray(cc: OConv, info: *Info) void {
    const f = ioFormats(cc);
    info.names[0] = "tex";
    if (isRGBx(f.in)) useTempl(info, &T_REORDER, dup(B_REORDER_OPAQUE)) else useTempl(info, &T_REORDER, dup(B_REORDER));
    if (f.out == c.GST_VIDEO_FORMAT_GRAY8) {
        reorder(f.in, c.GST_VIDEO_FORMAT_RGBA, &info.in_swizzle, &info.out_swizzle);
        info.out_swizzle = .{ 0, 0, 0, 0 };
    }
}

fn grayToRgb(cc: OConv, info: *Info) void {
    const f = ioFormats(cc);
    const la = pv(cc).in_formats[0] == c.GST_GL_LUMINANCE_ALPHA;
    info.names[0] = "tex";
    switch (f.in) {
        c.GST_VIDEO_FORMAT_GRAY8 => {
            info.templ = &T_REORDER;
            reorder(c.GST_VIDEO_FORMAT_RGBA, f.out, &info.in_swizzle, &info.out_swizzle);
            info.in_swizzle = .{ 0, 0, 0, 3 };
            info.body = dup(B_REORDER);
        },
        c.GST_VIDEO_FORMAT_GRAY16_LE => {
            reorder(c.GST_VIDEO_FORMAT_RGBA, f.out, &info.in_swizzle, &info.out_swizzle);
            info.templ = &T_COMPOSE;
            info.in_swizzle[0] = if (la) 3 else 1;
            info.in_swizzle[1] = 0;
            info.body = dup(B_COMPOSE);
        },
        c.GST_VIDEO_FORMAT_GRAY16_BE => {
            reorder(c.GST_VIDEO_FORMAT_RGBA, f.out, &info.in_swizzle, &info.out_swizzle);
            info.templ = &T_COMPOSE;
            info.in_swizzle[0] = 0;
            info.in_swizzle[1] = if (la) 3 else 1;
            info.body = dup(B_COMPOSE);
        },
        else => {},
    }
}

fn bindBuffer(cc: OConv) void {
    const gl = vt(cc[0].context);
    const p = pv(cc);
    gl.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, p.ibo);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, p.vbo);
    gl.VertexAttribPointer.?(@bitCast(p.attr_pos), 3, c.GL_FLOAT, c.GL_FALSE, 5 * @sizeOf(c.GLfloat), null);
    gl.EnableVertexAttribArray.?(@bitCast(p.attr_pos));
    if (p.attr_tex != -1) {
        gl.VertexAttribPointer.?(@bitCast(p.attr_tex), 2, c.GL_FLOAT, c.GL_FALSE, 5 * @sizeOf(c.GLfloat), @ptrFromInt(3 * @sizeOf(c.GLfloat)));
        gl.EnableVertexAttribArray.?(@bitCast(p.attr_tex));
    }
}

fn unbindBuffer(cc: OConv) void {
    const gl = vt(cc[0].context);
    const p = pv(cc);
    gl.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
    gl.DisableVertexAttribArray.?(@bitCast(p.attr_pos));
    if (p.attr_tex != -1) {
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
        gl.DisableVertexAttribArray.?(@bitCast(p.attr_tex));
    }
}

fn dropStage(st: anytype, sh: anytype, err: *[*c]c.GError) [*c]c.GstGLShader {
    c.g_clear_error(err);
    if (st != null) c.gst_object_unref(st);
    c.gst_object_unref(sh);
    return null;
}

fn createShader(cc: OConv) [*c]c.GstGLShader {
    const p = pv(cc);
    const info = &p.info;
    const ctx = cc[0].context;
    var ver: c.GstGLSLVersion = 0;
    var prof: c.GstGLSLProfile = 0;
    var err: [*c]c.GError = null;
    const sh = shader.gst_gl_shader_new(ctx);
    const vsrc = glsl.mangle(VERTEX, c.GL_VERTEX_SHADER, c.GST_GL_TEXTURE_TARGET_2D, p.from, ctx, &ver, &prof);
    const vp = glsl.gst_glsl_version_profile_to_string(ver, prof);
    const header = c.g_strdup_printf("#version %s\n", vp);
    c.g_free(vp);
    var strs = [2][*c]const u8{ header, vsrc };
    const vstage = glslstage.gst_glsl_stage_new_with_strings(ctx, c.GL_VERTEX_SHADER, ver, prof, 2, &strs);
    c.g_free(vsrc);
    if (vstage == null) {
        c.g_free(header);
        c.gst_object_unref(sh);
        return null;
    }
    if (shader.gst_gl_shader_compile_attach_stage(sh, vstage, &err) == 0) {
        c.g_free(header);
        return dropStage(vstage, sh, &err);
    }
    const s = c.g_string_new(null);
    if (p.from == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES) _ = c.g_string_append(s, OES);
    _ = c.g_string_append(s, shaderstrings.gst_gl_shader_string_get_highest_precision(ctx, ver, prof));
    _ = c.g_string_append(s, info.templ.?.uniforms);
    _ = c.g_string_append_c(s, '\n');
    const core = prof == c.GST_GLSL_PROFILE_CORE;
    const es = prof == c.GST_GLSL_PROFILE_ES;
    if ((core and ver >= c.GST_GLSL_VERSION_330) or (es and ver >= c.GST_GLSL_VERSION_300)) {
        if (info.out_n > 1) {
            var i: c_int = 0;
            while (i < info.out_n) : (i += 1) c.g_string_append_printf(s, "layout(location = %d) out vec4 fragColor_%d;\n", i, i);
        } else _ = c.g_string_append(s, "layout (location = 0) out vec4 fragColor;\n");
    } else if (core and ver >= c.GST_GLSL_VERSION_150) {
        if (info.out_n > 1) {
            var i: c_int = 0;
            while (i < info.out_n) : (i += 1) {
                const name = c.g_strdup_printf("fragColor_%d", i);
                c.g_string_append_printf(s, "out vec4 %s;\n", name);
                shader.gst_gl_shader_bind_frag_data_location(sh, @intCast(i), name);
                c.g_free(name);
            }
        } else {
            _ = c.g_string_append(s, "out vec4 fragColor;\n");
            shader.gst_gl_shader_bind_frag_data_location(sh, 0, "fragColor");
        }
    }
    for (info.templ.?.functions) |fnc| {
        _ = c.g_string_append_c(s, '\n');
        _ = c.g_string_append(s, fnc);
        _ = c.g_string_append_c(s, '\n');
    }
    const varying: S = if ((es and ver >= c.GST_GLSL_VERSION_300) or (core and ver >= c.GST_GLSL_VERSION_150)) "in" else "varying";
    c.g_string_append_printf(s, "\n%s vec2 v_texcoord;\nvoid main (void) {\n", varying);
    if (info.body != null) {
        _ = c.g_string_append(s, "vec2 texcoord;\n");
        if (p.from == c.GST_GL_TEXTURE_TARGET_RECTANGLE) _ = c.g_string_append(s, "texcoord = v_texcoord * vec2 (width, height);\n") else _ = c.g_string_append(s, "texcoord = v_texcoord;\n");
        _ = c.g_string_append(s, info.body);
    }
    _ = c.g_string_append(s, "\n}");
    const src = c.g_string_free(s, 0);
    info.prog = glsl.mangle(src, c.GL_FRAGMENT_SHADER, c.GST_GL_TEXTURE_TARGET_2D, p.from, ctx, &ver, &prof);
    c.g_free(src);
    strs[1] = info.prog;
    const fstage = glslstage.gst_glsl_stage_new_with_strings(ctx, c.GL_FRAGMENT_SHADER, ver, prof, 2, &strs);
    c.g_free(header);
    if (fstage == null or shader.gst_gl_shader_compile_attach_stage(sh, fstage, &err) == 0) {
        c.g_free(info.prog);
        info.prog = null;
        return dropStage(fstage, sh, &err);
    }
    if (shader.gst_gl_shader_link(sh, &err) == 0) {
        c.g_free(info.prog);
        info.prog = null;
        return dropStage(@as(?*anyopaque, null), sh, &err);
    }
    return sh;
}

fn initConvert(cc: OConv) bool {
    const p = pv(cc);
    const info = &p.info;
    const ctx = cc[0].context;
    const gl = vt(ctx);
    if (cc[0].initted != 0) return true;
    if (gl.CreateProgramObject == null and gl.CreateProgram == null) return false;
    const fi = cc[0].in_info.finfo;
    const fo = cc[0].out_info.finfo;
    info.* = std.mem.zeroes(Info);
    info.in_n = nTextures(fmtOf(&cc[0].in_info));
    info.out_n = nTextures(fmtOf(&cc[0].out_info));
    info.to_rgb = identity();
    info.to_yuv = identity();
    if (isRgb(fi) and isRgb(fo)) rgbToRgb(cc, info);
    if (isYuv(fi) and isRgb(fo)) yuvToRgb(cc, info);
    if (isRgb(fi) and isYuv(fo)) rgbToYuv(cc, info);
    if (isYuv(fi) and isYuv(fo)) yuvToYuvConv(cc, info);
    if (isRgb(fi) and isGray(fo)) rgbToGray(cc, info);
    if (isGray(fi) and isRgb(fo)) grayToRgb(cc, info);
    if (info.body == null) return false;
    if (info.out_n > 1 and gl.DrawBuffers == null) return false;
    const of = fmtOf(&cc[0].out_info);
    if (usingGles2(ctx) and !usingGles3(ctx) and (of == c.GST_VIDEO_FORMAT_YUY2 or of == c.GST_VIDEO_FORMAT_UYVY)) return false;
    if (!(usingGles3(ctx) or usingGl30(ctx)) and isTiled(fi)) return false;
    cc[0].shader = createShader(cc);
    if (cc[0].shader == null) return false;
    const sh = cc[0].shader;
    p.attr_pos = shader.gst_gl_shader_get_attribute_location(sh, "a_position");
    p.attr_tex = if (!isTiled(fi)) shader.gst_gl_shader_get_attribute_location(sh, "a_texcoord") else -1;
    shader.gst_gl_shader_use(sh);
    var m: [16]f32 = undefined;
    toFloat(&info.to_rgb, &m);
    shader.gst_gl_shader_set_uniform_matrix_4fv(sh, "to_RGB_matrix", 1, 0, &m);
    toFloat(&info.to_yuv, &m);
    shader.gst_gl_shader_set_uniform_matrix_4fv(sh, "to_YUV_matrix", 1, 0, &m);
    var i: c.gint = info.in_n - 1;
    while (i >= 0) : (i -= 1) {
        if (info.names[@intCast(i)]) |n| shader.gst_gl_shader_set_uniform_1i(sh, n, i);
    }
    var in_w: f32 = @floatFromInt(cc[0].in_info.width);
    var out_w: f32 = @floatFromInt(cc[0].out_info.width);
    const in_h: f32 = @floatFromInt(cc[0].in_info.height);
    if (fmtOf(&cc[0].in_info) == c.GST_VIDEO_FORMAT_v210) in_w = @floatFromInt(@divTrunc(cc[0].in_info.width + 5, 6) * 4);
    if (of == c.GST_VIDEO_FORMAT_v210) out_w = @floatFromInt(@divTrunc(cc[0].out_info.width + 5, 6) * 4);
    if (isTiled(fi)) {
        const stride: c.guint = @bitCast(cc[0].in_info.stride[0]);
        const tw = fi[0].tile_info[0].width;
        const th = fi[0].tile_info[0].height;
        shader.gst_gl_shader_set_uniform_1f(sh, "width", @floatFromInt((stride & 0xffff) * tw));
        shader.gst_gl_shader_set_uniform_1f(sh, "height", @floatFromInt((stride >> 16) * th));
    } else {
        shader.gst_gl_shader_set_uniform_1f(sh, "width", in_w);
        shader.gst_gl_shader_set_uniform_1f(sh, "height", in_h);
    }
    shader.gst_gl_shader_set_uniform_1f(sh, "out_width", out_w);
    shader.gst_gl_shader_set_uniform_1f(sh, "out_height", @floatFromInt(cc[0].out_info.height));
    if (p.from == c.GST_GL_TEXTURE_TARGET_RECTANGLE) {
        shader.gst_gl_shader_set_uniform_1f(sh, "poffset_x", 1);
        shader.gst_gl_shader_set_uniform_1f(sh, "poffset_y", 1);
        shader.gst_gl_shader_set_uniform_2f(sh, "vert_to_tex", in_w, in_h);
    } else {
        shader.gst_gl_shader_set_uniform_1f(sh, "poffset_x", 1.0 / in_w);
        shader.gst_gl_shader_set_uniform_1f(sh, "poffset_y", 1.0 / in_h);
        shader.gst_gl_shader_set_uniform_2f(sh, "vert_to_tex", 1, 1);
    }
    if (info.chroma[0] > 0 and info.chroma[1] > 0) shader.gst_gl_shader_set_uniform_2fv(sh, "chroma_sampling", 1, &info.chroma);
    shader.gst_gl_shader_set_uniform_1iv(sh, "input_swizzle", 4, &info.in_swizzle);
    shader.gst_gl_shader_set_uniform_1iv(sh, "output_swizzle", 4, &info.out_swizzle);
    shader.gst_gl_shader_set_uniform_1f(sh, "in_bitdepth_factor", info.in_depth);
    shader.gst_gl_shader_set_uniform_1f(sh, "out_bitdepth_factor", info.out_depth);
    shader.gst_gl_context_clear_shader(ctx);
    if (cc[0].fbo == null) {
        cc[0].fbo = framebuffer.gst_gl_framebuffer_new_with_default_depth(ctx, @intCast(cc[0].out_info.width), @intCast(cc[0].out_info.height));
        if (cc[0].fbo == null) return false;
    }
    if (p.vbo == 0) {
        if (gl.GenVertexArrays) |gen| {
            gen(1, &p.vao);
            gl.BindVertexArray.?(p.vao);
        }
        gl.GenBuffers.?(1, &p.vbo);
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, p.vbo);
        gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(VERTICES)), &VERTICES, c.GL_STATIC_DRAW);
        gl.GenBuffers.?(1, &p.ibo);
        gl.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, p.ibo);
        gl.BufferData.?(c.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(INDICES)), &INDICES, c.GL_STATIC_DRAW);
        if (gl.GenVertexArrays != null) {
            bindBuffer(cc);
            gl.BindVertexArray.?(0);
        }
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
        gl.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
    }
    const vm = c.gst_buffer_get_video_meta(cc[0].inbuf);
    const pw: c.gint = if (vm != null) @intCast(vm[0].width) else cc[0].in_info.width;
    const ph: c.gint = if (vm != null) @intCast(vm[0].height) else cc[0].in_info.height;
    if (pw != p.padded_w or ph != p.padded_h) {
        const sx: f32 = @floatCast(@as(f64, @floatFromInt(cc[0].in_info.width)) / @as(f64, @floatFromInt(pw)));
        const sy: f32 = @floatCast(@as(f64, @floatFromInt(cc[0].in_info.height)) / @as(f64, @floatFromInt(ph)));
        const crop = [20]c.GLfloat{ 1, 1, 0, sx, 0, -1, 1, 0, 0, 0, -1, -1, 0, 0, sy, 1, -1, 0, sx, sy };
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, p.vbo);
        gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(crop)), &crop, c.GL_STATIC_DRAW);
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
        p.padded_w = pw;
        p.padded_h = ph;
    }
    gl.BindTexture.?(c.GL_TEXTURE_2D, 0);
    cc[0].initted = 1;
    return true;
}

fn peek(b: OBuf, i: c.guint) OMem {
    return @ptrCast(@alignCast(c.gst_buffer_peek_memory(b, i)));
}

fn mem(m: anytype) [*c]c.GstMemory {
    return @ptrCast(@alignCast(m));
}

fn needsTemp(cc: OConv, out: OMem) bool {
    const w: c.gint = @intCast(memory.gst_gl_memory_get_texture_width(out));
    const h: c.gint = @intCast(memory.gst_gl_memory_get_texture_height(out));
    return out[0].tex_format == c.GST_GL_LUMINANCE or out[0].tex_format == c.GST_GL_LUMINANCE_ALPHA or cc[0].out_info.height != h or (cc[0].out_info.width != w and fmtOf(&cc[0].out_info) != c.GST_VIDEO_FORMAT_v210);
}

fn convertView(ctx: OCtx, cc: OConv, view: c.guint) bool {
    const p = pv(cc);
    const info = &p.info;
    const in_n: usize = @intCast(info.in_n);
    const out_n: usize = @intCast(info.out_n);
    const in_off: c.guint = view * @as(c.guint, @intCast(info.in_n));
    const out_off: c.guint = view * @as(c.guint, @intCast(info.out_n));
    var in_map: [MAXP]c.GstMapInfo = undefined;
    var out_map: [MAXP]c.GstMapInfo = undefined;
    var ok = true;
    var i: usize = 0;
    var j: usize = 0;
    run: {
        while (i < in_n) : (i += 1) {
            p.in_tex[i] = peek(cc[0].inbuf, @as(c.guint, @intCast(i)) + in_off);
            if (memory.gst_is_gl_memory(mem(p.in_tex[i])) == 0 or cc[0].context != p.in_tex[i][0].mem.context or c.gst_memory_map(mem(p.in_tex[i]), &in_map[i], c.GST_MAP_READ | c.GST_MAP_GL) == 0) {
                ok = false;
                break :run;
            }
        }
        while (j < out_n) : (j += 1) {
            const out = peek(cc[0].outbuf, @as(c.guint, @intCast(j)) + out_off);
            if (memory.gst_is_gl_memory(mem(out)) == 0 or cc[0].context != out[0].mem.context) {
                ok = false;
                break :run;
            }
            if (needsTemp(cc, out)) {
                if (p.out_tex[j] == null) {
                    const tf: Fmt = if (cc[0].out_info.finfo[0].bits > 8) c.GST_VIDEO_FORMAT_RGBA64_LE else c.GST_VIDEO_FORMAT_RGBA;
                    var ti: c.GstVideoInfo = undefined;
                    _ = c.gst_video_info_set_format(&ti, tf, @intCast(cc[0].out_info.width), @intCast(cc[0].out_info.height));
                    const texf = format.gst_gl_format_from_video_info(ctx, &ti, 0);
                    const alloc = c.gst_allocator_find("GLMemory");
                    const params = memory.gst_gl_video_allocation_params_new(ctx, null, &ti, 0, null, p.to, texf);
                    p.out_tex[j] = @ptrCast(@alignCast(basememory.gst_gl_base_memory_alloc(@ptrCast(alloc), @ptrCast(params))));
                    basememory.gst_gl_allocation_params_free(@ptrCast(params));
                    c.gst_object_unref(alloc);
                }
            } else p.out_tex[j] = out;
            if (c.gst_memory_map(mem(p.out_tex[j]), &out_map[j], c.GST_MAP_WRITE | c.GST_MAP_GL) == 0) {
                ok = false;
                break :run;
            }
        }
        if (!draw(ctx, cc)) ok = false;
    }
    while (j > 0) {
        j -= 1;
        const out = peek(cc[0].outbuf, @as(c.guint, @intCast(j)) + out_off);
        c.gst_memory_unmap(mem(p.out_tex[j]), &out_map[j]);
        if (needsTemp(cc, out)) {
            var from: c.GstMapInfo = undefined;
            var to: c.GstMapInfo = undefined;
            if (c.gst_memory_map(mem(p.out_tex[j]), &from, c.GST_MAP_READ | c.GST_MAP_GL) == 0 or c.gst_memory_map(mem(out), &to, c.GST_MAP_WRITE | c.GST_MAP_GL) == 0) {
                ok = false;
                continue;
            }
            _ = memory.gst_gl_memory_copy_into(p.out_tex[j], out[0].tex_id, p.to, out[0].tex_format, @intCast(memory.gst_gl_memory_get_texture_width(out)), @intCast(memory.gst_gl_memory_get_texture_height(out)));
            c.gst_memory_unmap(mem(p.out_tex[j]), &from);
            c.gst_memory_unmap(mem(out), &to);
        } else p.out_tex[j] = null;
    }
    while (i > 0) {
        i -= 1;
        c.gst_memory_unmap(mem(p.in_tex[i]), &in_map[i]);
    }
    return ok;
}

fn fail(p: *Priv) void {
    p.result = 0;
}

fn doConvert(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const cc = cv(data);
    const p = pv(cc);
    const info = &p.info;
    cc[0].outbuf = null;
    const views: c.guint = if (cc[0].in_info.ABI.abi.multiview_mode == c.GST_VIDEO_MULTIVIEW_MODE_SEPARATED) @intCast(cc[0].in_info.views) else 1;
    info.in_n = nTextures(fmtOf(&cc[0].in_info));
    info.out_n = nTextures(fmtOf(&cc[0].out_info));
    var changed = false;
    var v: c.guint = 0;
    while (v < views) : (v += 1) {
        var i: c.guint = 0;
        while (i < @as(c.guint, @intCast(info.in_n))) : (i += 1) {
            const j = v * @as(c.guint, @intCast(info.in_n)) + i;
            const t = peek(cc[0].inbuf, j);
            if (memory.gst_is_gl_memory(mem(t)) == 0) return fail(p);
            if (j >= MAXP) check.assertFail("gstglcolorconvert.c", 3715, "_do_convert", null);
            if (v > 0 and t[0].tex_format != p.in_formats[i]) return fail(p);
            if (p.in_formats[j] != t[0].tex_format) changed = true;
            p.in_formats[j] = t[0].tex_format;
        }
    }
    if (changed) resetShader(cc);
    if (isTiled(cc[0].in_info.finfo)) {
        const vm = c.gst_buffer_get_video_meta(cc[0].inbuf);
        if (vm != null and vm[0].stride[0] != cc[0].in_info.stride[0]) {
            cc[0].in_info.stride[0] = vm[0].stride[0];
            resetShader(cc);
        }
    }
    if (!initConvert(cc)) return fail(p);
    const sm = c.gst_buffer_get_meta(cc[0].inbuf, syncmeta.gst_gl_sync_meta_api_get_type());
    if (sm != null) syncmeta.gst_gl_sync_meta_wait(@ptrCast(@alignCast(sm)), cc[0].context);
    if (p.pool == null) {
        const q = c.gst_query_new_allocation(p.out_caps, 1);
        const r = gst_gl_color_convert_decide_allocation(cc, q);
        c.gst_query_unref(q);
        if (r == 0 or p.pool == null) return fail(p);
    }
    if (p.pool_started == 0) {
        if (c.gst_buffer_pool_set_active(p.pool, 1) == 0) return fail(p);
        p.pool_started = 1;
    }
    if (c.gst_buffer_pool_acquire_buffer(p.pool, &cc[0].outbuf, null) != c.GST_FLOW_OK) return fail(p);
    debug.gst_gl_insert_debug_marker(ctx, "%s converting from %s to %s", cc[0].parent.name, c.gst_video_format_to_string(fmtOf(&cc[0].in_info)), c.gst_video_format_to_string(fmtOf(&cc[0].out_info)));
    var ok = true;
    v = 0;
    while (ok and v < views) : (v += 1) ok = convertView(ctx, cc, v);
    if (!ok) {
        c.gst_buffer_unref(cc[0].outbuf);
        cc[0].outbuf = null;
    }
    if (cc[0].outbuf != null) {
        if (c.gst_mini_object_is_writable(@ptrCast(cc[0].outbuf)) == 0) return fail(p);
        var osm: [*c]c.GstGLSyncMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(cc[0].outbuf, syncmeta.gst_gl_sync_meta_api_get_type())));
        if (osm == null) osm = syncmeta.gst_buffer_add_gl_sync_meta(cc[0].context, cc[0].outbuf);
        syncmeta.gst_gl_sync_meta_set_sync_point(osm, cc[0].context);
    }
    p.result = @intFromBool(ok);
}

fn draw(ctx: OCtx, cc: OConv) bool {
    const p = pv(cc);
    const gl = vt(ctx);
    const rts = [4]c.GLenum{ c.GL_COLOR_ATTACHMENT0, c.GL_COLOR_ATTACHMENT1, c.GL_COLOR_ATTACHMENT2, c.GL_COLOR_ATTACHMENT3 };
    framebuffer.gst_gl_framebuffer_bind(cc[0].fbo);
    var i: c.gint = 0;
    while (i < p.info.out_n) : (i += 1) framebuffer.gst_gl_framebuffer_attach(cc[0].fbo, @intCast(c.GL_COLOR_ATTACHMENT0 + i), @ptrCast(p.out_tex[@intCast(i)]));
    if (gl.DrawBuffers) |db| db(p.info.out_n, &rts) else if (gl.DrawBuffer) |d| d(c.GL_COLOR_ATTACHMENT0);
    var w: c.guint = 0;
    var h: c.guint = 0;
    framebuffer.gst_gl_framebuffer_get_effective_dimensions(cc[0].fbo, &w, &h);
    gl.Viewport.?(0, 0, @intCast(w), @intCast(h));
    shader.gst_gl_shader_use(cc[0].shader);
    if (gl.BindVertexArray) |b| b(p.vao);
    bindBuffer(cc);
    const target = format.gst_gl_texture_target_to_gl(p.from);
    i = p.info.in_n - 1;
    while (i >= 0) : (i -= 1) {
        const name = c.g_strdup_printf("tex_scale%u", @as(c.guint, @intCast(i)));
        const t = p.in_tex[@intCast(i)];
        gl.ActiveTexture.?(@intCast(c.GL_TEXTURE0 + i));
        gl.BindTexture.?(target, t[0].tex_id);
        gl.TexParameteri.?(target, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        gl.TexParameteri.?(target, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        gl.TexParameteri.?(target, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        gl.TexParameteri.?(target, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        shader.gst_gl_shader_set_uniform_2fv(cc[0].shader, name, 1, &t[0].tex_scaling);
        c.g_free(name);
    }
    gl.DrawElements.?(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_SHORT, null);
    if (gl.BindVertexArray) |b| b(0) else unbindBuffer(cc);
    if (gl.DrawBuffer) |d| d(c.GL_COLOR_ATTACHMENT0);
    shader.gst_gl_context_clear_shader(ctx);
    const ok = framebuffer.gst_gl_context_check_framebuffer_status(ctx, c.GL_FRAMEBUFFER) != 0;
    framebuffer.gst_gl_context_clear_framebuffer(ctx);
    return ok;
}

pub export fn gst_gl_color_convert_swizzle_shader_string(_: OCtx) [*c]u8 {
    return c.g_strdup(F_SWIZZLE);
}

pub export fn gst_gl_color_convert_yuv_to_rgb_shader_string(_: OCtx) [*c]u8 {
    return c.g_strdup(F_YUV_TO_RGB);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const cc = cv(inst);
    cc[0].priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    pv(cc).* = std.mem.zeroes(Priv);
    reset(cc);
}

pub export fn gst_gl_color_convert_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstGLColorConvert", Class, Conv, classInit, init, 0);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            _ = c._gst_debug_category_new("glconvert", 0, "convert");
            return t;
        }
    }.f);
}
