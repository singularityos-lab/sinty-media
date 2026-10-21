const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const basesrc = @import("basesrc.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Src = c.GstBaseSrc;
const Push = c.GstPushSrc;
const Class = c.GstPushSrcClass;
const Buffer = c.GstBuffer;

var type_once: gtype.Once = .{};
var parent: ?*c.GstBaseSrcClass = null;

pub export fn gst_push_src_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(basesrc.gst_base_src_get_type, "GstPushSrc", Class, Push, classInit, null, 0);
            _ = c._gst_debug_category_new("pushsrc", 0, "pushsrc element");
            return t;
        }
    }.f);
}

fn klass(s: anytype) *Class {
    return gtype.classPeek(Class, s);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.create = create;
    bc.alloc = alloc;
    bc.fill = fill;
    bc.query = query;
}

fn query(s: [*c]Src, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (q[0].type == c.GST_QUERY_SCHEDULING) {
        c.gst_query_set_scheduling(q, c.GST_SCHEDULING_FLAG_SEQUENTIAL, 1, -1, 0);
        c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PUSH);
        return 1;
    }
    return parent.?.query.?(s, q);
}

fn create(s: [*c]Src, off: c.guint64, len: c.guint, out: [*c][*c]Buffer) callconv(.c) c.GstFlowReturn {
    if (klass(s).create) |f| return f(@ptrCast(s), out);
    return parent.?.create.?(s, off, len, out);
}

fn alloc(s: [*c]Src, off: c.guint64, len: c.guint, out: [*c][*c]Buffer) callconv(.c) c.GstFlowReturn {
    if (klass(s).alloc) |f| return f(@ptrCast(s), out);
    return parent.?.alloc.?(s, off, len, out);
}

fn fill(s: [*c]Src, off: c.guint64, len: c.guint, b: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    if (klass(s).fill) |f| return f(@ptrCast(s), b);
    return parent.?.fill.?(s, off, len, b);
}
