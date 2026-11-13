const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;

pub const manual = builtin.cpu.arch == .aarch64;

const Aapcs64 = extern struct {
    stack: [*]u8,
    gr_top: [*]u8,
    vr_top: [*]u8,
    gr_offs: c_int,
    vr_offs: c_int,
};

pub const VaList = if (manual) Aapcs64 else std.builtin.VaList;
pub const CVaList = if (manual) *VaList else @typeInfo(@TypeOf(c.gst_structure_set_valist)).@"fn".params[2].type.?;

const max_collect = 8;

pub const CValue = extern union {
    v_int: c.gint,
    v_long: c.glong,
    v_int64: c.gint64,
    v_double: c.gdouble,
    v_pointer: c.gpointer,
};

pub fn cvaluesOf(p: ?*c.GTypeCValue) [*]CValue {
    return @ptrCast(@alignCast(p));
}

pub fn fromC(ap: CVaList) *VaList {
    return if (manual) ap else @ptrCast(@alignCast(ap));
}

pub fn toC(ap: *VaList) CVaList {
    return if (manual) ap else @ptrCast(ap);
}

fn readArg(ap: *Aapcs64, comptime T: type) T {
    comptime std.debug.assert(@sizeOf(T) <= 8);
    const float = @typeInfo(T) == .float;
    const offs = if (float) &ap.vr_offs else &ap.gr_offs;
    if (offs.* < 0) {
        const at = offs.*;
        offs.* = at + if (float) 16 else 8;
        if (offs.* <= 0) {
            const top = if (float) ap.vr_top else ap.gr_top;
            return @as(*align(1) const T, @ptrCast(top - @as(usize, @intCast(-at)))).*;
        }
    }
    const p = ap.stack;
    ap.stack += 8;
    return @as(*align(1) const T, @ptrCast(p)).*;
}

pub inline fn arg(ap: *VaList, comptime T: type) T {
    return if (manual) readArg(ap, T) else @cVaArg(ap, T);
}

pub inline fn copy(ap: *VaList) VaList {
    return if (manual) ap.* else @cVaCopy(ap);
}

pub inline fn end(ap: *VaList) void {
    if (!manual) @cVaEnd(ap);
}

pub fn call(comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    const params = @typeInfo(@TypeOf(f)).@"fn".params;
    const last = params.len - 1;
    var full: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
    inline for (0..last) |i| full[i] = args[i];
    full[last] = if (manual) @as(*const params[last].type.?, @ptrCast(args[last])).* else @ptrCast(args[last]);
    return @call(.auto, f, full);
}

pub fn entryPoint(comptime S: type, comptime name: []const u8) *const @TypeOf(@field(S, name)) {
    return if (manual) @extern(*const @TypeOf(@field(S, name)), .{ .name = name }) else &@field(S, name);
}

pub fn entry(comptime S: type, comptime name: []const u8) void {
    if (manual) {
        @export(&@field(S, name ++ "_va"), .{ .name = "sinty_va_" ++ name, .visibility = .hidden });
    } else {
        @export(&@field(S, name), .{ .name = name });
    }
}

pub fn collect(value: *c.GValue, t: c.GType, ap: *VaList) callconv(.c) [*c]u8 {
    const vtab = c.g_type_value_table_peek(t);
    if (vtab == null) return c.g_strdup_printf("could not get value table for type '%s'", c.g_type_name(t));
    var cv_buf: [max_collect]CValue = undefined;
    var n: c.guint = 0;
    value.g_type = t;
    var fmt = vtab.*.collect_format;
    while (fmt[0] != 0) : (fmt += 1) {
        const cv = &cv_buf[n];
        n += 1;
        switch (fmt[0]) {
            'i' => cv.v_int = arg(ap, c.gint),
            'l' => cv.v_long = arg(ap, c.glong),
            'q' => cv.v_int64 = arg(ap, c.gint64),
            'd' => cv.v_double = arg(ap, c.gdouble),
            'p' => cv.v_pointer = arg(ap, c.gpointer),
            else => unreachable,
        }
    }
    const err = vtab.*.collect_value.?(value, n, @ptrCast(&cv_buf), 0);
    return err;
}

pub fn skip(t: c.GType, ap: *VaList) callconv(.c) void {
    const vtab = c.g_type_value_table_peek(t);
    if (vtab == null) return;
    var fmt = vtab.*.collect_format;
    while (fmt[0] != 0) : (fmt += 1) {
        switch (fmt[0]) {
            'i' => _ = arg(ap, c.gint),
            'l' => _ = arg(ap, c.glong),
            'q' => _ = arg(ap, c.gint64),
            'd' => _ = arg(ap, c.gdouble),
            'p' => _ = arg(ap, c.gpointer),
            else => unreachable,
        }
    }
}

pub fn lcopy(value: *const c.GValue, ap: *VaList, fieldname: [*c]const u8) callconv(.c) [*c]u8 {
    const vtab = c.g_type_value_table_peek(value.g_type);
    var cv_buf: [max_collect]CValue = std.mem.zeroes([max_collect]CValue);
    var n: c.guint = 0;
    var fmt = vtab.*.lcopy_format;
    while (fmt[0] != 0) : (fmt += 1) {
        cv_buf[n].v_pointer = arg(ap, c.gpointer);
        n += 1;
    }
    if (n == 2 and (cv_buf[0].v_pointer == null) != (cv_buf[1].v_pointer == null)) {
        return c.g_strdup_printf("either all or none of the return locations for field '%s' need to be NULL", fieldname);
    }
    if (cv_buf[0].v_pointer != null) {
        const err = vtab.*.lcopy_value.?(value, n, @ptrCast(&cv_buf), 0);
        return err;
    }
    return null;
}
