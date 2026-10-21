const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const info = @import("info.zig");
const pad = @import("pad.zig");
const flow = @import("padflow.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Pad = pad.Pad;
const Raw = pad.Raw;
const Obj = c.GstObject;
const Flow = c.GstFlowReturn;

pub const ProxyPad = extern struct {
    pad: Pad,
    priv: ?*Private,

    pub const Header = c.struct__GstProxyPad;
};

pub const GhostPad = extern struct {
    pad: ProxyPad,
    priv: c.gpointer,

    pub const Header = c.struct__GstGhostPad;
};

const ProxyPadClass = extern struct {
    parent_class: c.GstPadClass,
    reserved: [1]c.gpointer,
};

const GhostPadClass = extern struct {
    parent_class: ProxyPadClass,
    reserved: [4]c.gpointer,
};

const Private = extern struct {
    internal: [*c]Pad,
};

var proxy_offset: c.gint = 0;
var proxy_once: gtype.Once = .{};
var ghost_once: gtype.Once = .{};
var ghost_parent: ?*c.GObjectClass = null;

fn proxyOf(p: anytype) [*c]ProxyPad {
    return @ptrCast(@alignCast(p));
}

fn internalOf(p: anytype) *[*c]Pad {
    return &proxyOf(p)[0].priv.?.internal;
}

fn isProxy(p: anytype) bool {
    return gtype.instanceOf(p, gst_proxy_pad_get_type());
}

fn isGhost(p: anytype) bool {
    return gtype.instanceOf(p, gst_ghost_pad_get_type());
}

fn acquire(p: [*c]Pad) [*c]Pad {
    return @ptrCast(gst_proxy_pad_get_internal(proxyOf(p)));
}

pub export fn gst_proxy_pad_get_type() c.GType {
    return proxy_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(pad.gst_pad_get_type(), "GstProxyPad", ProxyPadClass, ProxyPad, proxyClassInit, proxyInit, 0);
            proxy_offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

fn proxyClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &proxy_offset);
    info._gst_debug_register_funcptr(@ptrCast(&gst_proxy_pad_iterate_internal_links_default), "gst_proxy_pad_iterate_internal_links_default");
    info._gst_debug_register_funcptr(@ptrCast(&gst_proxy_pad_chain_default), "gst_proxy_pad_chain_default");
    info._gst_debug_register_funcptr(@ptrCast(&gst_proxy_pad_chain_list_default), "gst_proxy_pad_chain_list_default");
    info._gst_debug_register_funcptr(@ptrCast(&gst_proxy_pad_getrange_default), "gst_proxy_pad_getrange_default");
}

fn proxyInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p = proxyOf(instance);
    const base: [*]u8 = @ptrCast(instance);
    p[0].priv = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, proxy_offset)))));
    p[0].pad.iterintlinkfunc = gst_proxy_pad_iterate_internal_links_default;
    pad.set(&p[0].pad, c.GST_PAD_FLAG_PROXY_CAPS | c.GST_PAD_FLAG_PROXY_SCHEDULING | c.GST_PAD_FLAG_PROXY_ALLOCATION);
}

pub export fn gst_proxy_pad_iterate_internal_links_default(raw: Raw, _: [*c]Obj) [*c]c.GstIterator {
    const p = pad.of(raw);
    if (!check.that(isProxy(p), "gst_proxy_pad_iterate_internal_links_default", "GST_IS_PROXY_PAD (pad)")) return null;
    const internal = acquire(p);
    if (internal == null) return null;
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, pad.gst_pad_get_type());
    c.g_value_take_object(&v, internal);
    const it = c.gst_iterator_new_single(pad.gst_pad_get_type(), &v);
    c.g_value_unset(&v);
    return it;
}

pub export fn gst_proxy_pad_chain_default(raw: Raw, _: [*c]Obj, b: [*c]c.GstBuffer) Flow {
    const f = "gst_proxy_pad_chain_default";
    const p = pad.of(raw);
    if (!check.that(isProxy(p), f, "GST_IS_PROXY_PAD (pad)")) return c.GST_FLOW_ERROR;
    if (!check.that(flow.isBuffer(b), f, "GST_IS_BUFFER (buffer)")) return c.GST_FLOW_ERROR;
    const internal = acquire(p);
    if (internal == null) return c.GST_FLOW_NOT_LINKED;
    defer c.gst_object_unref(internal);
    return flow.gst_pad_push(internal, b);
}

pub export fn gst_proxy_pad_chain_list_default(raw: Raw, _: [*c]Obj, l: ?*c.GstBufferList) Flow {
    const f = "gst_proxy_pad_chain_list_default";
    const p = pad.of(raw);
    if (!check.that(isProxy(p), f, "GST_IS_PROXY_PAD (pad)")) return c.GST_FLOW_ERROR;
    if (!check.that(flow.isList(l), f, "GST_IS_BUFFER_LIST (list)")) return c.GST_FLOW_ERROR;
    const internal = acquire(p);
    if (internal == null) return c.GST_FLOW_NOT_LINKED;
    defer c.gst_object_unref(internal);
    return flow.gst_pad_push_list(internal, l);
}

pub export fn gst_proxy_pad_getrange_default(raw: Raw, _: [*c]Obj, offset: c.guint64, size: c.guint, out: [*c][*c]c.GstBuffer) Flow {
    const f = "gst_proxy_pad_getrange_default";
    const p = pad.of(raw);
    if (!check.that(isProxy(p), f, "GST_IS_PROXY_PAD (pad)")) return c.GST_FLOW_ERROR;
    if (!check.that(out != null, f, "buffer != NULL")) return c.GST_FLOW_ERROR;
    const internal = acquire(p);
    if (internal == null) return c.GST_FLOW_NOT_LINKED;
    defer c.gst_object_unref(internal);
    return flow.gst_pad_pull_range(internal, offset, size, out);
}

pub export fn gst_proxy_pad_get_internal(p: [*c]ProxyPad) [*c]ProxyPad {
    if (!check.that(isProxy(p), "gst_proxy_pad_get_internal", "GST_IS_PROXY_PAD (pad)")) return null;
    pad.lock(p);
    defer pad.unlock(p);
    const internal = internalOf(p).*;
    if (internal != null) _ = c.gst_object_ref(internal);
    return proxyOf(internal);
}

fn target(p: [*c]Pad) [*c]Pad {
    pad.lock(p);
    defer pad.unlock(p);
    return pad.gst_pad_get_peer(internalOf(p).*);
}

pub export fn gst_ghost_pad_get_type() c.GType {
    return ghost_once.get(struct {
        fn f() c.GType {
            return gtype.object(gst_proxy_pad_get_type(), "GstGhostPad", GhostPadClass, GhostPad, ghostClassInit, ghostInit, 0);
        }
    }.f);
}

fn ghostClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    ghost_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.dispose = dispose;
    gc.constructed = constructed;
    info._gst_debug_register_funcptr(@ptrCast(&activatePull), "gst_ghost_pad_activate_pull_default");
    info._gst_debug_register_funcptr(@ptrCast(&activatePush), "gst_ghost_pad_activate_push_default");
}

fn ghostInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: [*c]Pad = @ptrCast(@alignCast(instance));
    p[0].activatemodefunc = gst_ghost_pad_activate_mode_default;
}

fn viaInternal(p: [*c]Pad, mode: c.GstPadMode, active: c.gboolean) c.gboolean {
    const other = acquire(p);
    if (other == null) return 0;
    defer c.gst_object_unref(other);
    return pad.gst_pad_activate_mode(other, mode, active);
}

fn pullThrough(p: [*c]Pad, active: c.gboolean) c.gboolean {
    if (p[0].direction == c.GST_PAD_SRC) return viaInternal(p, c.GST_PAD_MODE_PULL, active);
    const other = pad.gst_pad_get_peer(p);
    if (other == null) return @intFromBool(active == 0);
    defer c.gst_object_unref(other);
    return pad.gst_pad_activate_mode(other, c.GST_PAD_MODE_PULL, active);
}

fn activatePush(raw: Raw, _: [*c]Obj, active: c.gboolean) callconv(.c) c.gboolean {
    const p = pad.of(raw);
    if (!check.that(isGhost(p), "gst_ghost_pad_activate_push_default", "GST_IS_GHOST_PAD (pad)")) return 0;
    return viaInternal(p, c.GST_PAD_MODE_PUSH, active);
}

fn activatePull(raw: Raw, _: [*c]Obj, active: c.gboolean) callconv(.c) c.gboolean {
    return pullThrough(pad.of(raw), active);
}

pub export fn gst_ghost_pad_internal_activate_mode_default(raw: Raw, _: [*c]Obj, mode: c.GstPadMode, active: c.gboolean) c.gboolean {
    const p = pad.of(raw);
    if (!check.that(isProxy(p), "gst_ghost_pad_internal_activate_mode_default", "GST_IS_PROXY_PAD (pad)")) return 0;
    return switch (mode) {
        c.GST_PAD_MODE_PULL => pullThrough(p, active),
        c.GST_PAD_MODE_PUSH => viaInternal(p, c.GST_PAD_MODE_PUSH, active),
        else => 0,
    };
}

pub export fn gst_ghost_pad_activate_mode_default(raw: Raw, parent: [*c]Obj, mode: c.GstPadMode, active: c.gboolean) c.gboolean {
    const p = pad.of(raw);
    if (!check.that(isGhost(p), "gst_ghost_pad_activate_mode_default", "GST_IS_GHOST_PAD (pad)")) return 0;
    return switch (mode) {
        c.GST_PAD_MODE_PULL => activatePull(raw, parent, active),
        c.GST_PAD_MODE_PUSH => activatePush(raw, parent, active),
        else => 0,
    };
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const p: [*c]Pad = @ptrCast(@alignCast(o));
    _ = gst_ghost_pad_set_target(@ptrCast(p), null);
    const peer = pad.gst_pad_get_peer(p);
    if (peer != null) {
        _ = if (pad.isSrc(p)) pad.gst_pad_unlink(p, peer) else pad.gst_pad_unlink(peer, p);
        c.gst_object_unref(peer);
    }
    pad.lock(p);
    const internal = internalOf(p).*;
    if (internal != null) {
        internal[0].activatemodefunc = null;
        internalOf(p).* = null;
        internalOf(internal).* = null;
        object.gst_object_unparent(@ptrCast(internal));
    }
    pad.unlock(p);
    ghost_parent.?.dispose.?(o);
}

fn constructed(o: [*c]c.GObject) callconv(.c) void {
    ghost_parent.?.constructed.?(o);
    const p: [*c]Pad = @ptrCast(@alignCast(o));
    const dir = p[0].direction;
    if (!check.that(dir != c.GST_PAD_UNKNOWN, "gst_ghost_pad_constructed", "dir != GST_PAD_UNKNOWN")) return;
    const other: c.GstPadDirection = if (dir == c.GST_PAD_SRC) c.GST_PAD_SINK else c.GST_PAD_SRC;
    const templ = p[0].padtemplate;
    const none: [*c]const u8 = null;
    const internal: [*c]Pad = @ptrCast(@alignCast(if (templ != null)
        c.g_object_new(gst_proxy_pad_get_type(), "name", none, "direction", other, "template", templ, none)
    else
        c.g_object_new(gst_proxy_pad_get_type(), "name", none, "direction", other, none)));
    pad.clear(internal, c.GST_PAD_FLAG_FLUSHING);
    if (dir == c.GST_PAD_SINK) {
        p[0].chainfunc = gst_proxy_pad_chain_default;
        p[0].chainlistfunc = gst_proxy_pad_chain_list_default;
        internal[0].getrangefunc = gst_proxy_pad_getrange_default;
    } else {
        p[0].getrangefunc = gst_proxy_pad_getrange_default;
        internal[0].chainfunc = gst_proxy_pad_chain_default;
        internal[0].chainlistfunc = gst_proxy_pad_chain_list_default;
    }
    _ = object.gst_object_set_parent(@ptrCast(internal), @ptrCast(p));
    internalOf(p).* = internal;
    internalOf(internal).* = p;
    internal[0].activatemodefunc = gst_ghost_pad_internal_activate_mode_default;
}

pub export fn gst_ghost_pad_construct(_: [*c]GhostPad) c.gboolean {
    return 1;
}

fn newFull(name: [*c]const u8, dir: c.GstPadDirection, templ: [*c]c.GstPadTemplate) [*c]Pad {
    if (!check.that(dir != c.GST_PAD_UNKNOWN, "gst_ghost_pad_new_full", "dir != GST_PAD_UNKNOWN")) return null;
    const none: [*c]const u8 = null;
    if (templ == null) return @ptrCast(@alignCast(c.g_object_new(gst_ghost_pad_get_type(), "name", name, "direction", dir, none)));
    const g = templ[0].ABI.abi.gtype;
    const t = if (g == (1 << c.G_TYPE_FUNDAMENTAL_SHIFT)) gst_ghost_pad_get_type() else g;
    if (!check.that(c.g_type_is_a(t, gst_ghost_pad_get_type()) != 0, "gst_ghost_pad_new_full", "g_type_is_a (pad_type, GST_TYPE_GHOST_PAD)")) return null;
    return @ptrCast(@alignCast(c.g_object_new(t, "name", name, "direction", dir, "template", templ, none)));
}

pub export fn gst_ghost_pad_new_no_target(name: [*c]const u8, dir: c.GstPadDirection) [*c]Pad {
    if (!check.that(dir != c.GST_PAD_UNKNOWN, "gst_ghost_pad_new_no_target", "dir != GST_PAD_UNKNOWN")) return null;
    return newFull(name, dir, null);
}

fn withTarget(p: [*c]Pad, t: [*c]Pad) [*c]Pad {
    if (p == null) return null;
    if (gst_ghost_pad_set_target(@ptrCast(p), t) != 0) return p;
    c.gst_object_unref(p);
    return null;
}

pub export fn gst_ghost_pad_new(name: [*c]const u8, t: [*c]Pad) [*c]Pad {
    const f = "gst_ghost_pad_new";
    if (!check.that(pad.isPad(t), f, "GST_IS_PAD (target)")) return null;
    if (!check.that(pad.gst_pad_is_linked(t) == 0, f, "!gst_pad_is_linked (target)")) return null;
    return withTarget(gst_ghost_pad_new_no_target(name, t[0].direction), t);
}

pub export fn gst_ghost_pad_new_from_template(name: [*c]const u8, t: [*c]Pad, templ: [*c]c.GstPadTemplate) [*c]Pad {
    const f = "gst_ghost_pad_new_from_template";
    if (!check.that(pad.isPad(t), f, "GST_IS_PAD (target)")) return null;
    if (!check.that(pad.gst_pad_is_linked(t) == 0, f, "!gst_pad_is_linked (target)")) return null;
    if (!check.that(templ != null, f, "templ != NULL")) return null;
    if (!check.that(templ[0].direction == t[0].direction, f, "GST_PAD_TEMPLATE_DIRECTION (templ) == GST_PAD_DIRECTION (target)")) return null;
    return withTarget(newFull(name, t[0].direction, templ), t);
}

pub export fn gst_ghost_pad_new_no_target_from_template(name: [*c]const u8, templ: [*c]c.GstPadTemplate) [*c]Pad {
    if (!check.that(templ != null, "gst_ghost_pad_new_no_target_from_template", "templ != NULL")) return null;
    return newFull(name, templ[0].direction, templ);
}

pub export fn gst_ghost_pad_get_target(g: [*c]GhostPad) [*c]Pad {
    if (!check.that(isGhost(g), "gst_ghost_pad_get_target", "GST_IS_GHOST_PAD (gpad)")) return null;
    return target(@ptrCast(g));
}

pub export fn gst_ghost_pad_set_target(g: [*c]GhostPad, t: [*c]Pad) c.gboolean {
    const f = "gst_ghost_pad_set_target";
    if (!check.that(isGhost(g), f, "GST_IS_GHOST_PAD (gpad)")) return 0;
    const p: [*c]Pad = @ptrCast(g);
    if (!check.that(p != t, f, "GST_PAD_CAST (gpad) != newtarget")) return 0;
    pad.lock(p);
    const internal = internalOf(p).*;
    if (t == internal) {
        pad.unlock(p);
        return 1;
    }
    const old = pad.gst_pad_get_peer(internal);
    pad.unlock(p);
    if (old != null) {
        _ = if (pad.isSrc(internal)) pad.gst_pad_unlink(internal, old) else pad.gst_pad_unlink(old, internal);
        c.gst_object_unref(old);
    }
    if (t == null) return 1;
    const r = if (pad.isSrc(internal))
        pad.gst_pad_link_full(internal, t, c.GST_PAD_LINK_CHECK_NOTHING)
    else
        pad.gst_pad_link_full(t, internal, c.GST_PAD_LINK_CHECK_NOTHING);
    return @intFromBool(r == c.GST_PAD_LINK_OK);
}
