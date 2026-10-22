const c = @import("../common.zig").c;

pub const Vec3 = extern struct {
    v: [4]f32 align(16),
};

pub const Vec2 = extern struct {
    v: [4]f32 align(16),
};

pub const Matrix = extern struct {
    m: [16]f32 align(16),
};

pub const Point3d = extern struct {
    x: f32,
    y: f32,
    z: f32,
};

pub const Plane = extern struct {
    normal: Vec3,
    constant: f32,
};

pub const Ray = extern struct {
    origin: Vec3,
    direction: Vec3,
};

pub extern fn graphene_matrix_get_type() c.GType;
pub extern fn graphene_matrix_alloc() *Matrix;
pub extern fn graphene_matrix_free(*Matrix) void;
pub extern fn graphene_matrix_init_identity(*Matrix) *Matrix;
pub extern fn graphene_matrix_init_translate(*Matrix, *const Point3d) *Matrix;
pub extern fn graphene_matrix_init_scale(*Matrix, f32, f32, f32) *Matrix;
pub extern fn graphene_matrix_init_ortho(*Matrix, f32, f32, f32, f32, f32, f32) *Matrix;
pub extern fn graphene_matrix_init_perspective(*Matrix, f32, f32, f32, f32) *Matrix;
pub extern fn graphene_matrix_init_look_at(*Matrix, *const Vec3, *const Vec3, *const Vec3) *Matrix;
pub extern fn graphene_matrix_init_from_float(*Matrix, *const [16]f32) *Matrix;
pub extern fn graphene_matrix_scale(*Matrix, f32, f32, f32) void;
pub extern fn graphene_matrix_rotate(*Matrix, f32, *const Vec3) void;
pub extern fn graphene_matrix_translate(*Matrix, *const Point3d) void;
pub extern fn graphene_matrix_multiply(*const Matrix, *const Matrix, *Matrix) void;
pub extern fn graphene_matrix_inverse(*const Matrix, *Matrix) bool;
pub extern fn graphene_matrix_to_float(*const Matrix, *[16]f32) void;
pub extern fn graphene_matrix_transform_point3d(*const Matrix, *const Point3d, *Point3d) void;
pub extern fn graphene_matrix_transform_vec3(*const Matrix, *const Vec3, *Vec3) void;
pub extern fn graphene_vec3_alloc() *Vec3;
pub extern fn graphene_vec3_free(*Vec3) void;
pub extern fn graphene_vec3_init(*Vec3, f32, f32, f32) *Vec3;
pub extern fn graphene_vec3_normalize(*const Vec3, *Vec3) void;
pub extern fn graphene_vec3_x_axis() *const Vec3;
pub extern fn graphene_vec3_y_axis() *const Vec3;
pub extern fn graphene_vec3_z_axis() *const Vec3;
pub extern fn graphene_vec2_init(*Vec2, f32, f32) *Vec2;
pub extern fn graphene_vec2_get_x(*const Vec2) f32;
pub extern fn graphene_vec2_get_y(*const Vec2) f32;
pub extern fn graphene_point3d_init(*Point3d, f32, f32, f32) *Point3d;
pub extern fn graphene_point3d_scale(*const Point3d, f32, *Point3d) void;
pub extern fn graphene_plane_init_from_points(*Plane, *const Point3d, *const Point3d, *const Point3d) *Plane;
pub extern fn graphene_ray_init_from_vec3(*Ray, *const Vec3, *const Vec3) *Ray;
pub extern fn graphene_ray_get_distance_to_plane(*const Ray, *const Plane) f32;
pub extern fn graphene_ray_get_position_at(*const Ray, f32, *Point3d) void;
