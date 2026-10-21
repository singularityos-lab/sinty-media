const std = @import("std");
const c = @import("c.zig").c;

pub fn dropBindings(o: *c.GstObject) void {
    var l = o.control_bindings;
    while (l != null) : (l = l.*.next) @import("object.zig").gst_object_unparent(@ptrCast(@alignCast(l.*.data)));
    c.g_list_free(o.control_bindings);
    o.control_bindings = null;
}
