const c = @import("c.zig").c;

const F1 = *const fn (f64) callconv(.c) f64;
const F2 = *const fn (f64, f64) callconv(.c) f64;

var handle: ?*anyopaque = null;
var sin_f: ?F1 = null;
var cos_f: ?F1 = null;
var exp_f: ?F1 = null;
var log2_f: ?F1 = null;
var log10_f: ?F1 = null;
var pow_f: ?F2 = null;

fn resolve(comptime T: type, slot: *?T, name: [*:0]const u8) T {
    if (slot.*) |f| return f;
    if (handle == null) handle = c.dlopen("libm.so.6", c.RTLD_LAZY);
    const f: T = @ptrCast(c.dlsym(handle, name) orelse @panic("libm symbol missing"));
    slot.* = f;
    return f;
}

pub fn sin(x: f64) f64 {
    return resolve(F1, &sin_f, "sin")(x);
}

pub fn cos(x: f64) f64 {
    return resolve(F1, &cos_f, "cos")(x);
}

pub fn exp(x: f64) f64 {
    return resolve(F1, &exp_f, "exp")(x);
}

pub fn log2(x: f64) f64 {
    return resolve(F1, &log2_f, "log2")(x);
}

pub fn log10(x: f64) f64 {
    return resolve(F1, &log10_f, "log10")(x);
}

pub fn pow(x: f64, y: f64) f64 {
    return resolve(F2, &pow_f, "pow")(x, y);
}

pub fn sqrt(x: f64) f64 {
    return @sqrt(x);
}

pub fn floor(x: f64) f64 {
    return @floor(x);
}
