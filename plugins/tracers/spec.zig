const cm = @import("../common.zig");
const c = cm.c;

const N: ?*anyopaque = null;

pub const Field = union(enum) {
    gtype: c.GType,
    related: c.GstTracerValueScope,
    desc: [*:0]const u8,
    flags: c.GstTracerValueFlags,
    min_u: c.guint,
    max_u: c.guint,
    min_u64: u64,
    max_u64: u64,
};

pub fn make(name: [*:0]const u8, fields: []const Field) [*c]c.GstStructure {
    const s = c.gst_structure_new_empty(name);
    for (fields) |f| switch (f) {
        .gtype => |t| c.gst_structure_set(s, "type", c.g_gtype_get_type(), t, N),
        .related => |r| c.gst_structure_set(s, "related-to", c.gst_tracer_value_scope_get_type(), r, N),
        .desc => |d| c.gst_structure_set(s, "description", c.G_TYPE_STRING, d, N),
        .flags => |x| c.gst_structure_set(s, "flags", c.gst_tracer_value_flags_get_type(), x, N),
        .min_u => |x| c.gst_structure_set(s, "min", c.G_TYPE_UINT, x, N),
        .max_u => |x| c.gst_structure_set(s, "max", c.G_TYPE_UINT, x, N),
        .min_u64 => |x| c.gst_structure_set(s, "min", c.G_TYPE_UINT64, x, N),
        .max_u64 => |x| c.gst_structure_set(s, "max", c.G_TYPE_UINT64, x, N),
    };
    return s;
}

pub fn scope(t: c.GType, rel: c.GstTracerValueScope) [*c]c.GstStructure {
    return make("scope", &.{ .{ .gtype = t }, .{ .related = rel } });
}

pub fn value(t: c.GType, d: [*:0]const u8) [*c]c.GstStructure {
    return make("value", &.{ .{ .gtype = t }, .{ .desc = d } });
}

pub fn threadId() [*c]c.GstStructure {
    return scope(c.G_TYPE_UINT64, c.GST_TRACER_VALUE_SCOPE_THREAD);
}

pub fn ts() [*c]c.GstStructure {
    return value(c.G_TYPE_UINT64, "event ts");
}

pub fn padIx() [*c]c.GstStructure {
    return scope(c.G_TYPE_UINT, c.GST_TRACER_VALUE_SCOPE_PAD);
}

pub fn elementIx() [*c]c.GstStructure {
    return scope(c.G_TYPE_UINT, c.GST_TRACER_VALUE_SCOPE_ELEMENT);
}

pub fn u64Range(d: [*:0]const u8) [*c]c.GstStructure {
    return make("value", &.{ .{ .gtype = c.G_TYPE_UINT64 }, .{ .desc = d }, .{ .min_u64 = 0 }, .{ .max_u64 = ~@as(u64, 0) } });
}

pub fn maybeLeaked(r: anytype) void {
    @as(*c.GstObject, @ptrCast(@alignCast(r))).flags |= c.GST_OBJECT_FLAG_MAY_BE_LEAKED;
}

pub fn thread() u64 {
    return @intFromPtr(c.g_thread_self());
}

pub fn hook(t: anytype, name: [*:0]const u8, f: anytype) void {
    c.gst_tracing_register_hook(@ptrCast(@alignCast(t)), name, @ptrCast(f));
}
