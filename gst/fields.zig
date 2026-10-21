const std = @import("std");
const c = @import("c.zig").c;
const structure = @import("structure.zig");

const G_TYPE_BOOLEAN: c.GType = 5 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const G_TYPE_INT: c.GType = 6 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const G_TYPE_UINT: c.GType = 7 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const G_TYPE_INT64: c.GType = 10 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const G_TYPE_UINT64: c.GType = 11 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const G_TYPE_STRING: c.GType = 16 << c.G_TYPE_FUNDAMENTAL_SHIFT;

pub fn set(s: [*c]c.GstStructure, name: [*c]const u8, t: c.GType, raw: anytype) void {
    var v: if (@TypeOf(raw) == comptime_int) i64 else @TypeOf(raw) = raw;
    _ = &v;
    var gv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&gv, t);
    switch (@typeInfo(@TypeOf(v))) {
        .float => c.g_value_set_double(&gv, v),
        .int, .comptime_int => switch (c.g_type_fundamental(t)) {
            G_TYPE_BOOLEAN => c.g_value_set_boolean(&gv, @intCast(v)),
            G_TYPE_INT => c.g_value_set_int(&gv, @intCast(v)),
            G_TYPE_UINT => c.g_value_set_uint(&gv, @intCast(v)),
            G_TYPE_INT64 => c.g_value_set_int64(&gv, @intCast(v)),
            G_TYPE_UINT64 => c.g_value_set_uint64(&gv, @intCast(v)),
            12 << c.G_TYPE_FUNDAMENTAL_SHIFT => c.g_value_set_enum(&gv, @intCast(v)),
            13 << c.G_TYPE_FUNDAMENTAL_SHIFT => c.g_value_set_flags(&gv, @intCast(v)),
            else => unreachable,
        },
        else => if (t == G_TYPE_STRING) c.g_value_set_string(&gv, @ptrCast(v)) else if (c.g_type_fundamental(t) == 20 << c.G_TYPE_FUNDAMENTAL_SHIFT) c.g_value_set_object(&gv, @ptrCast(@constCast(v))) else c.g_value_set_boxed(&gv, @ptrCast(v)),
    }
    structure.gst_structure_take_value(s, name, &gv);
}

