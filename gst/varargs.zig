const std = @import("std");
const c = @import("c.zig").c;

pub const CVaList = @typeInfo(@TypeOf(c.gst_structure_set_valist)).@"fn".params[2].type.?;
pub const VaList = std.builtin.VaList;

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
    return @ptrCast(@alignCast(ap));
}

pub fn toC(ap: *VaList) CVaList {
    return @ptrCast(ap);
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
            'i' => cv.v_int = @cVaArg(ap, c.gint),
            'l' => cv.v_long = @cVaArg(ap, c.glong),
            'q' => cv.v_int64 = @cVaArg(ap, c.gint64),
            'd' => cv.v_double = @cVaArg(ap, c.gdouble),
            'p' => cv.v_pointer = @cVaArg(ap, c.gpointer),
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
            'i' => _ = @cVaArg(ap, c.gint),
            'l' => _ = @cVaArg(ap, c.glong),
            'q' => _ = @cVaArg(ap, c.gint64),
            'd' => _ = @cVaArg(ap, c.gdouble),
            'p' => _ = @cVaArg(ap, c.gpointer),
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
        cv_buf[n].v_pointer = @cVaArg(ap, c.gpointer);
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
