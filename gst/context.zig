const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const mini = @import("mini.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Ctx = c.GstContext;
const Mini = c.GstMiniObject;

const Impl = extern struct {
    mini: Mini,
    kind: [*c]u8,
    s: [*c]c.GstStructure,
    persistent: c.gboolean,
};

pub export var _gst_context_type: c.GType = 0;
var type_once: gtype.Once = .{};

fn impl(p: anytype) *Impl {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn asMini(p: anytype) [*c]Mini {
    return @ptrCast(@alignCast(@constCast(p)));
}

pub fn isContext(p: anytype) bool {
    return p != null and asMini(p)[0].type == _gst_context_type;
}

pub export fn gst_context_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstContext", @ptrCast(&mini.gst_mini_object_ref), @ptrCast(&mini.gst_mini_object_unref));
        }
    }.f);
}

pub fn initialize() void {
    _gst_context_type = gst_context_get_type();
}

fn freeHook(m: [*c]Mini) callconv(.c) void {
    if (!check.that(m != null, "_gst_context_free", "context != NULL")) return;
    const i = impl(m);
    if (i.s != null) {
        _ = c.gst_structure_set_parent_refcount(i.s, null);
        c.gst_structure_free(i.s);
    }
    c.g_free(i.kind);
    c.g_free(m);
}

fn create() *Impl {
    const i: *Impl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Impl))));
    mini.gst_mini_object_init(asMini(i), 0, _gst_context_type, copyHook, null, freeHook);
    return i;
}

fn copyHook(src: [*c]const Mini) callconv(.c) [*c]Mini {
    const s = impl(src);
    const out = create();
    out.kind = c.g_strdup(s.kind);
    out.s = c.gst_structure_copy(s.s);
    _ = c.gst_structure_set_parent_refcount(out.s, &out.mini.refcount);
    out.persistent = s.persistent;
    return asMini(out);
}

pub export fn gst_context_new(kind: [*c]const u8, persistent: c.gboolean) ?*Ctx {
    if (!check.that(kind != null, "gst_context_new", "context_type != NULL")) return null;
    const i = create();
    i.s = c.gst_structure_new_static_str_empty("context");
    _ = c.gst_structure_set_parent_refcount(i.s, &i.mini.refcount);
    i.kind = c.g_strdup(kind);
    i.persistent = persistent;
    return @ptrCast(i);
}

pub export fn gst_context_get_context_type(p: ?*const Ctx) [*c]const u8 {
    if (!check.that(isContext(p), "gst_context_get_context_type", "GST_IS_CONTEXT (context)")) return null;
    return impl(p).kind;
}

pub export fn gst_context_has_context_type(p: ?*const Ctx, kind: [*c]const u8) c.gboolean {
    if (!check.that(isContext(p), "gst_context_has_context_type", "GST_IS_CONTEXT (context)")) return 0;
    if (!check.that(kind != null, "gst_context_has_context_type", "context_type != NULL")) return 0;
    return @intFromBool(std.mem.orderZ(u8, impl(p).kind, kind) == .eq);
}

pub export fn gst_context_get_structure(p: ?*const Ctx) [*c]const c.GstStructure {
    if (!check.that(isContext(p), "gst_context_get_structure", "GST_IS_CONTEXT (context)")) return null;
    return impl(p).s;
}

pub export fn gst_context_writable_structure(p: ?*Ctx) [*c]c.GstStructure {
    if (!check.that(isContext(p), "gst_context_writable_structure", "GST_IS_CONTEXT (context)")) return null;
    if (!check.that(gst_context_is_writable(p) != 0, "gst_context_writable_structure", "gst_context_is_writable (context)")) return null;
    return impl(p).s;
}

pub export fn gst_context_is_persistent(p: ?*const Ctx) c.gboolean {
    if (!check.that(isContext(p), "gst_context_is_persistent", "GST_IS_CONTEXT (context)")) return 0;
    return impl(p).persistent;
}

pub export fn gst_context_ref(p: ?*Ctx) ?*Ctx {
    return @ptrCast(mini.gst_mini_object_ref(asMini(p)));
}

pub export fn gst_context_unref(p: ?*Ctx) void {
    mini.gst_mini_object_unref(asMini(p));
}

pub export fn gst_clear_context(slot: [*c]?*Ctx) void {
    mini.gst_clear_mini_object(@ptrCast(slot));
}

pub export fn gst_context_copy(p: ?*const Ctx) ?*Ctx {
    return @ptrCast(mini.gst_mini_object_copy(asMini(p)));
}

pub export fn gst_context_replace(slot: [*c]?*Ctx, p: ?*Ctx) c.gboolean {
    return mini.gst_mini_object_replace(@ptrCast(slot), asMini(p));
}

pub export fn gst_context_is_writable(p: ?*const Ctx) c.gboolean {
    return mini.gst_mini_object_is_writable(asMini(p));
}

pub export fn gst_context_make_writable(p: ?*Ctx) ?*Ctx {
    return @ptrCast(mini.gst_mini_object_make_writable(asMini(p)));
}
