const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const pad = @import("pad.zig");
const padflow = @import("padflow.zig");
const padtemplate = @import("padtemplate.zig");
const element = @import("element.zig");
const va = @import("varargs.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Element = c.GstElement;
const Pad = pad.Pad;
const Obj = c.GstObject;
const Templ = c.GstPadTemplate;

fn padOf(p: anytype) [*c]Pad {
    return @ptrCast(@alignCast(p));
}

fn parentOf(o: anytype) [*c]Obj {
    return @as([*c]Obj, @ptrCast(@alignCast(o)))[0].parent;
}

fn objName(o: anytype) [*c]const u8 {
    return pad.nameOf(@ptrCast(@alignCast(o)));
}

pub export fn gst_element_create_all_pads(e: [*c]Element) void {
    var l = element.gst_element_class_get_pad_template_list(element.classOf(e));
    while (l != null) : (l = l[0].next) {
        const t: [*c]Templ = @ptrCast(@alignCast(l[0].data));
        if (t[0].presence == c.GST_PAD_ALWAYS) _ = element.gst_element_add_pad(e, pad.gst_pad_new_from_template(t, t[0].name_template));
    }
}

pub export fn gst_element_get_compatible_pad_template(e: [*c]Element, compat: [*c]Templ) [*c]Templ {
    const f = "gst_element_get_compatible_pad_template";
    if (!check.that(e != null, f, "element != NULL")) return null;
    if (!check.that(element.isElement(e), f, "GST_IS_ELEMENT (element)")) return null;
    if (!check.that(compat != null, f, "compattempl != NULL")) return null;
    var l = element.gst_element_class_get_pad_template_list(element.classOf(e));
    while (l != null) : (l = l[0].next) {
        const t: [*c]Templ = @ptrCast(@alignCast(l[0].data));
        if (t[0].direction != compat[0].direction and c.gst_caps_can_intersect(compat[0].caps, t[0].caps) != 0) return t;
    }
    return null;
}

fn padFromTemplate(e: [*c]Element, t: [*c]Templ) [*c]Pad {
    return switch (t[0].presence) {
        c.GST_PAD_ALWAYS, c.GST_PAD_SOMETIMES => blk: {
            const p = element.gst_element_get_static_pad(e, t[0].name_template);
            if (p == null and t[0].presence == c.GST_PAD_ALWAYS)
                c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Element %s has an ALWAYS template %s, but no pad of the same name", objName(e), t[0].name_template);
            break :blk p;
        },
        c.GST_PAD_REQUEST => element.gst_element_request_pad(e, t, null, null),
        else => null,
    };
}

fn requestCompatible(e: [*c]Element, t: [*c]Templ) [*c]Pad {
    if (!check.that(element.isElement(e), "gst_element_request_compatible_pad", "GST_IS_ELEMENT (element)")) return null;
    if (!check.that(padtemplate.isTemplate(t), "gst_element_request_compatible_pad", "GST_IS_PAD_TEMPLATE (templ)")) return null;
    const nt = gst_element_get_compatible_pad_template(e, t);
    var p: [*c]Pad = null;
    if (nt != null) p = padFromTemplate(e, nt);
    if (p != null and p[0].peer != null) {
        c.gst_object_unref(p);
        p = null;
    }
    return p;
}

pub export fn gst_element_get_compatible_pad(e: [*c]Element, p: [*c]Pad, caps: [*c]c.GstCaps) [*c]Pad {
    const f = "gst_element_get_compatible_pad";
    if (!check.that(element.isElement(e), f, "GST_IS_ELEMENT (element)")) return null;
    if (!check.that(pad.isPad(p), f, "GST_IS_PAD (pad)")) return null;
    if (!check.that(p[0].peer == null, f, "GST_PAD_PEER (pad) == NULL")) return null;
    const it = if (pad.isSrc(p)) element.gst_element_iterate_sink_pads(e) else if (pad.isSink(p)) element.gst_element_iterate_src_pads(e) else element.gst_element_iterate_pads(e);
    var item = std.mem.zeroes(c.GValue);
    var done = false;
    while (!done) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_OK => {
                const cur = padOf(c.g_value_get_object(&item));
                const src = if (pad.isSrc(cur)) cur else p;
                const sink = if (pad.isSrc(cur)) p else cur;
                const peer = pad.gst_pad_get_peer(cur);
                if (peer == null and pad.checkLink(src, sink) != 0) {
                    var temp = padflow.gst_pad_query_caps(p, null);
                    var inter = temp;
                    if (caps != null) {
                        inter = c.gst_caps_intersect(temp, caps);
                        c.gst_caps_unref(temp);
                    }
                    temp = padflow.gst_pad_query_caps(cur, null);
                    const ok = c.gst_caps_can_intersect(temp, inter) != 0;
                    c.gst_caps_unref(temp);
                    c.gst_caps_unref(inter);
                    if (ok) {
                        c.gst_iterator_free(it);
                        _ = c.gst_object_ref(cur);
                        c.g_value_unset(&item);
                        return cur;
                    }
                }
                _ = c.g_value_reset(&item);
                if (peer != null) c.gst_object_unref(peer);
            },
            c.GST_ITERATOR_RESYNC => c.gst_iterator_resync(it),
            else => done = true,
        }
    }
    c.g_value_unset(&item);
    c.gst_iterator_free(it);
    var tc = padflow.gst_pad_query_caps(p, null);
    if (caps != null) {
        const inter = c.gst_caps_intersect(tc, caps);
        c.gst_caps_unref(tc);
        tc = inter;
    }
    const t = padtemplate.gst_pad_template_new(p[0].object.name, p[0].direction, c.GST_PAD_ALWAYS, tc);
    c.gst_caps_unref(tc);
    const found = requestCompatible(e, t);
    c.gst_object_unref(t);
    return found;
}

fn hasAncestor(o: [*c]Obj, ancestor: [*c]Obj, direct: ?*[*c]Obj) bool {
    if (direct) |d| d.* = null;
    var child: [*c]Obj = @ptrCast(@alignCast(c.gst_object_ref(o)));
    var parent = c.gst_object_get_parent(o);
    while (parent != null) {
        if (parent == ancestor) {
            if (direct) |d| d.* = child else c.gst_object_unref(child);
            c.gst_object_unref(parent);
            return true;
        }
        c.gst_object_unref(child);
        child = parent;
        parent = c.gst_object_get_parent(parent);
    }
    c.gst_object_unref(child);
    return false;
}

fn commonRoot(a: [*c]Obj, b: [*c]Obj) [*c]Obj {
    var top = a;
    while (parentOf(top) != null) top = parentOf(top);
    var kid2: [*c]Obj = null;
    var kid1: [*c]Obj = null;
    if (!hasAncestor(b, top, &kid2)) return null;
    var root: [*c]Obj = @ptrCast(@alignCast(c.gst_object_ref(top)));
    while (true) {
        if (!hasAncestor(a, kid2, &kid1)) {
            c.gst_object_unref(kid2);
            return root;
        }
        c.gst_object_unref(root);
        root = kid2;
        if (!hasAncestor(b, kid1, &kid2)) {
            c.gst_object_unref(kid1);
            return root;
        }
        c.gst_object_unref(root);
        root = kid1;
    }
}

var ghost_index = std.atomic.Value(c.gint).init(0);

fn ghostUp(e: [*c]Element, p: [*c]Pad) [*c]Pad {
    const parent: [*c]Element = @ptrCast(@alignCast(parentOf(e)));
    const n = c.g_strdup_printf("ghost%d", ghost_index.fetchAdd(1, .seq_cst));
    const g = @import("ghostpad.zig").gst_ghost_pad_new(n, p);
    c.g_free(n);
    if (g == null) return null;
    c.g_rec_mutex_lock(@ptrCast(&parent[0].state_lock));
    defer c.g_rec_mutex_unlock(@ptrCast(&parent[0].state_lock));
    var cur: c.GstState = 0;
    var next: c.GstState = 0;
    _ = element.gst_element_get_state(parent, &cur, &next, 0);
    if (cur > c.GST_STATE_READY or next >= c.GST_STATE_PAUSED) _ = pad.gst_pad_set_active(g, 1);
    if (element.gst_element_add_pad(parent, g) == 0) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Pad named %s already exists in element %s\n", g[0].object.name, objName(parent));
        return null;
    }
    return g;
}

fn removeCreated(data: c.gpointer, _: c.gpointer) callconv(.c) void {
    const p = padOf(data);
    if (element.gst_element_remove_pad(@ptrCast(@alignCast(parentOf(p))), p) == 0)
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Couldn't remove pad %s from element %s", p[0].object.name, objName(parentOf(p)));
}

fn prepareGhosting(src: *[*c]Pad, sink: *[*c]Pad, created: *[*c]c.GSList) bool {
    var e1 = parentOf(src.*);
    var e2 = parentOf(sink.*);
    if (e1 == null or e2 == null) return false;
    if (parentOf(e1) == parentOf(e2)) return true;
    const root = commonRoot(e1, e2);
    if (root == null) {
        const n1 = objName(e1);
        const n2 = objName(e2);
        if (parentOf(e1) == null)
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Trying to link elements %s and %s that don't share a common ancestor: %s hasn't been added to a bin or pipeline, but %s is in %s", n1, n2, n1, n2, objName(parentOf(e2)))
        else if (parentOf(e2) == null)
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Trying to link elements %s and %s that don't share a common ancestor: %s hasn't been added to a bin or pipeline, and %s is in %s", n1, n2, n2, n1, objName(parentOf(e1)))
        else
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Trying to link elements %s and %s that don't share a common ancestor: %s is in %s, and %s is in %s", n1, n2, n1, objName(parentOf(e1)), n2, objName(parentOf(e2)));
        return false;
    }
    defer c.gst_object_unref(root);
    var local: [*c]c.GSList = null;
    while (parentOf(e1) != root) {
        src.* = ghostUp(@ptrCast(@alignCast(e1)), src.*);
        if (src.* == null) return failGhost(local);
        e1 = parentOf(src.*);
        local = c.g_slist_prepend(local, src.*);
    }
    while (parentOf(e2) != root) {
        sink.* = ghostUp(@ptrCast(@alignCast(e2)), sink.*);
        if (sink.* == null) return failGhost(local);
        e2 = parentOf(sink.*);
        local = c.g_slist_prepend(local, sink.*);
    }
    created.* = c.g_slist_concat(created.*, local);
    return true;
}

fn failGhost(local: [*c]c.GSList) bool {
    c.g_slist_foreach(local, removeCreated, null);
    c.g_slist_free(local);
    return false;
}

fn linkGhosting(src_in: [*c]Pad, sink_in: [*c]Pad, flags: c.GstPadLinkCheck) bool {
    var src = src_in;
    var sink = sink_in;
    var created: [*c]c.GSList = null;
    const ok = prepareGhosting(&src, &sink, &created) and pad.gst_pad_link_full(src, sink, flags) == c.GST_PAD_LINK_OK;
    if (!ok) c.g_slist_foreach(created, removeCreated, null);
    c.g_slist_free(created);
    return ok;
}

pub export fn gst_pad_link_maybe_ghosting_full(src: [*c]Pad, sink: [*c]Pad, flags: c.GstPadLinkCheck) c.gboolean {
    if (!check.that(pad.isPad(src), "gst_pad_link_maybe_ghosting_full", "GST_IS_PAD (src)")) return 0;
    if (!check.that(pad.isPad(sink), "gst_pad_link_maybe_ghosting_full", "GST_IS_PAD (sink)")) return 0;
    return @intFromBool(linkGhosting(src, sink, flags));
}

pub export fn gst_pad_link_maybe_ghosting(src: [*c]Pad, sink: [*c]Pad) c.gboolean {
    if (!check.that(pad.isPad(src), "gst_pad_link_maybe_ghosting", "GST_IS_PAD (src)")) return 0;
    if (!check.that(pad.isPad(sink), "gst_pad_link_maybe_ghosting", "GST_IS_PAD (sink)")) return 0;
    return gst_pad_link_maybe_ghosting_full(src, sink, c.GST_PAD_LINK_CHECK_DEFAULT);
}

fn releaseUnref(e: [*c]Element, p: [*c]Pad, request: bool) void {
    if (p == null) return;
    if (request) element.gst_element_release_request_pad(e, p);
    c.gst_object_unref(p);
}

fn namedPad(e: [*c]Element, n: [*c]const u8, request: *bool) [*c]Pad {
    var p = element.gst_element_get_static_pad(e, n);
    if (p == null) {
        p = element.gst_element_request_pad_simple(e, n);
        if (p != null) request.* = true;
    }
    return p;
}

fn isRequest(p: [*c]Pad) bool {
    return p != null and p[0].padtemplate != null and p[0].padtemplate[0].presence == c.GST_PAD_REQUEST;
}

fn firstPad(e: [*c]Element, list: *[*c]c.GList) [*c]Pad {
    c.g_mutex_lock(@ptrCast(&e[0].object.lock));
    defer c.g_mutex_unlock(@ptrCast(&e[0].object.lock));
    list.* = e[0].pads;
    const p: [*c]Pad = if (list.* != null) padOf(list.*[0].data) else null;
    if (p != null) _ = c.gst_object_ref(p);
    return p;
}

pub export fn gst_element_link_pads_full(src: [*c]Element, srcname: [*c]const u8, dest: [*c]Element, destname: [*c]const u8, flags: c.GstPadLinkCheck) c.gboolean {
    if (!check.that(element.isElement(src), "gst_element_link_pads_full", "GST_IS_ELEMENT (src)")) return 0;
    if (!check.that(element.isElement(dest), "gst_element_link_pads_full", "GST_IS_ELEMENT (dest)")) return 0;
    var srcreq = false;
    var destreq = false;
    var srcpads: [*c]c.GList = null;
    var destpads: [*c]c.GList = null;
    var srcpad: [*c]Pad = null;
    var destpad: [*c]Pad = null;
    if (srcname != null) {
        srcpad = namedPad(src, srcname, &srcreq);
        if (srcpad == null) return 0;
        if (srcpad[0].direction != c.GST_PAD_SRC) {
            releaseUnref(src, srcpad, srcreq);
            return 0;
        }
        if (srcpad[0].peer != null) {
            c.gst_object_unref(srcpad);
            return 0;
        }
    } else srcpad = firstPad(src, &srcpads);
    if (destname != null) {
        destpad = namedPad(dest, destname, &destreq);
        if (destpad == null) {
            releaseUnref(src, srcpad, srcreq);
            return 0;
        }
        if (destpad[0].direction != c.GST_PAD_SINK) {
            releaseUnref(src, srcpad, srcreq);
            releaseUnref(dest, destpad, destreq);
            return 0;
        }
        if (destpad[0].peer != null) {
            releaseUnref(src, srcpad, srcreq);
            c.gst_object_unref(destpad);
            return 0;
        }
    } else destpad = firstPad(dest, &destpads);
    if (srcname != null and destname != null) {
        const ok = linkGhosting(srcpad, destpad, flags);
        if (ok) {
            c.gst_object_unref(srcpad);
            c.gst_object_unref(destpad);
        } else {
            releaseUnref(src, srcpad, srcreq);
            releaseUnref(dest, destpad, destreq);
        }
        return @intFromBool(ok);
    }
    if (srcpad != null) {
        while (true) {
            if (srcpad[0].direction == c.GST_PAD_SRC and srcpad[0].peer == null) {
                var tempreq = false;
                var temp: [*c]Pad = undefined;
                if (destname != null) {
                    temp = destpad;
                    _ = c.gst_object_ref(temp);
                } else {
                    temp = gst_element_get_compatible_pad(dest, srcpad, null);
                    tempreq = isRequest(temp);
                }
                if (temp != null and linkGhosting(srcpad, temp, flags)) {
                    if (destpad != null) c.gst_object_unref(destpad);
                    c.gst_object_unref(srcpad);
                    c.gst_object_unref(temp);
                    return 1;
                }
                if (temp != null) {
                    if (tempreq) element.gst_element_release_request_pad(dest, temp);
                    c.gst_object_unref(temp);
                }
            }
            if (srcpads == null) break;
            srcpads = srcpads[0].next;
            if (srcpads == null) break;
            c.gst_object_unref(srcpad);
            srcpad = padOf(srcpads[0].data);
            _ = c.gst_object_ref(srcpad);
        }
    }
    if (srcname != null) {
        if (destpad != null) c.gst_object_unref(destpad);
        destpad = null;
    }
    if (srcpad != null) {
        releaseUnref(src, srcpad, srcreq);
        srcpad = null;
    }
    if (destpad != null) {
        while (true) {
            if (destpad[0].direction == c.GST_PAD_SINK and destpad[0].peer == null) {
                const temp = gst_element_get_compatible_pad(src, destpad, null);
                const tempreq = isRequest(temp);
                if (temp != null and linkGhosting(temp, destpad, flags)) {
                    c.gst_object_unref(temp);
                    c.gst_object_unref(destpad);
                    return 1;
                }
                releaseUnref(src, temp, tempreq);
            }
            if (destpads == null) break;
            destpads = destpads[0].next;
            if (destpads == null) break;
            c.gst_object_unref(destpad);
            destpad = padOf(destpads[0].data);
            _ = c.gst_object_ref(destpad);
        }
    }
    if (destname != null) {
        releaseUnref(dest, destpad, destreq);
        return 0;
    }
    if (destpad != null) c.gst_object_unref(destpad);
    var st = element.gst_element_class_get_pad_template_list(element.classOf(src));
    const dt = element.gst_element_class_get_pad_template_list(element.classOf(dest));
    if (st == null or dt == null) return 0;
    while (st != null) : (st = st[0].next) {
        const stl: [*c]Templ = @ptrCast(@alignCast(st[0].data));
        if (stl[0].presence != c.GST_PAD_REQUEST) continue;
        var l = dt;
        while (l != null) : (l = l[0].next) {
            const dtl: [*c]Templ = @ptrCast(@alignCast(l[0].data));
            if (dtl[0].presence != c.GST_PAD_REQUEST or dtl[0].direction == stl[0].direction) continue;
            const sc = padtemplate.gst_pad_template_get_caps(stl);
            const dc = padtemplate.gst_pad_template_get_caps(dtl);
            defer {
                c.gst_caps_unref(sc);
                c.gst_caps_unref(dc);
            }
            if (c.gst_caps_is_always_compatible(sc, dc) == 0) continue;
            const sp = element.gst_element_request_pad(src, stl, stl[0].name_template, null);
            const dp = element.gst_element_request_pad(dest, dtl, dtl[0].name_template, null);
            if (sp != null and dp != null and linkGhosting(sp, dp, flags)) {
                c.gst_object_unref(sp);
                c.gst_object_unref(dp);
                return 1;
            }
            if (sp != null) {
                element.gst_element_release_request_pad(src, sp);
                c.gst_object_unref(sp);
            }
            if (dp != null) {
                element.gst_element_release_request_pad(dest, dp);
                c.gst_object_unref(dp);
            }
        }
    }
    return 0;
}

pub export fn gst_element_link_pads(src: [*c]Element, sn: [*c]const u8, dest: [*c]Element, dn: [*c]const u8) c.gboolean {
    return gst_element_link_pads_full(src, sn, dest, dn, c.GST_PAD_LINK_CHECK_DEFAULT);
}

fn lookup(comptime T: type, comptime n: [:0]const u8) T {
    return gtype.lookup(T, n);
}

pub export fn gst_element_link_pads_filtered(src: [*c]Element, sn: [*c]const u8, dest: [*c]Element, dn: [*c]const u8, filter: [*c]c.GstCaps) c.gboolean {
    const f = "gst_element_link_pads_filtered";
    if (!check.that(element.isElement(src), f, "GST_IS_ELEMENT (src)")) return 0;
    if (!check.that(element.isElement(dest), f, "GST_IS_ELEMENT (dest)")) return 0;
    if (!check.that(filter == null or filter[0].mini_object.type == c._gst_caps_type, f, "filter == NULL || GST_IS_CAPS (filter)")) return 0;
    if (filter == null) return gst_element_link_pads(src, sn, dest, dn);
    const make = lookup(?*const fn ([*c]const u8, [*c]const u8) callconv(.c) [*c]Element, "gst_element_factory_make") orelse return 0;
    const bin_add = lookup(?*const fn ([*c]Element, [*c]Element) callconv(.c) c.gboolean, "gst_bin_add") orelse return 0;
    const bin_remove = lookup(?*const fn ([*c]Element, [*c]Element) callconv(.c) c.gboolean, "gst_bin_remove") orelse return 0;
    const bin_type = gtype.weakType("gst_bin_get_type");
    const cf = make("capsfilter", null);
    if (cf == null) return 0;
    _ = element.gst_element_set_locked_state(cf, 1);
    const parent: [*c]Element = @ptrCast(@alignCast(c.gst_object_get_parent(@ptrCast(src))));
    if (!check.that(bin_type != 0 and gtype.instanceOf(parent, bin_type), f, "GST_IS_BIN (parent)")) return 0;
    var state: c.GstState = 0;
    var pending: c.GstState = 0;
    _ = element.gst_element_get_state(parent, &state, &pending, 0);
    if (bin_add(parent, cf) == 0) {
        c.gst_object_unref(parent);
        return 0;
    }
    if (pending != c.GST_STATE_VOID_PENDING) state = pending;
    _ = element.gst_element_set_state(cf, state);
    c.gst_object_unref(parent);
    c.g_object_set(cf, "caps", filter, @as([*c]const u8, null));
    const a = gst_element_link_pads(src, sn, cf, "sink") != 0;
    const b = gst_element_link_pads(cf, "src", dest, dn) != 0;
    if (a and b) {
        _ = element.gst_element_set_locked_state(cf, 0);
        _ = element.gst_element_sync_state_with_parent(cf);
        return 1;
    }
    _ = element.gst_element_set_state(cf, c.GST_STATE_NULL);
    _ = bin_remove(@ptrCast(@alignCast(parentOf(cf))), cf);
    return 0;
}

pub export fn gst_element_link(src: [*c]Element, dest: [*c]Element) c.gboolean {
    return gst_element_link_pads(src, null, dest, null);
}

pub export fn gst_element_link_many(a_in: [*c]Element, b_in: [*c]Element, ...) callconv(.c) c.gboolean {
    if (!check.that(element.isElement(a_in), "gst_element_link_many", "GST_IS_ELEMENT (element_1)")) return 0;
    if (!check.that(element.isElement(b_in), "gst_element_link_many", "GST_IS_ELEMENT (element_2)")) return 0;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var a = a_in;
    var b = b_in;
    while (b != null) {
        if (gst_element_link(a, b) == 0) return 0;
        a = b;
        b = @cVaArg(&ap, [*c]Element);
    }
    return 1;
}

pub export fn gst_element_link_filtered(src: [*c]Element, dest: [*c]Element, filter: [*c]c.GstCaps) c.gboolean {
    return gst_element_link_pads_filtered(src, null, dest, null, filter);
}

pub export fn gst_element_unlink_pads(src: [*c]Element, sn: [*c]const u8, dest: [*c]Element, dn: [*c]const u8) void {
    const f = "gst_element_unlink_pads";
    if (!check.that(src != null, f, "src != NULL")) return;
    if (!check.that(element.isElement(src), f, "GST_IS_ELEMENT (src)")) return;
    if (!check.that(sn != null, f, "srcpadname != NULL")) return;
    if (!check.that(dest != null, f, "dest != NULL")) return;
    if (!check.that(element.isElement(dest), f, "GST_IS_ELEMENT (dest)")) return;
    if (!check.that(dn != null, f, "destpadname != NULL")) return;
    var sr = false;
    var dr = false;
    const sp = namedPad(src, sn, &sr);
    if (sp == null) return;
    const dp = namedPad(dest, dn, &dr);
    if (dp != null) {
        _ = pad.gst_pad_unlink(sp, dp);
        releaseUnref(dest, dp, dr);
    }
    releaseUnref(src, sp, sr);
}

pub export fn gst_element_unlink_many(a_in: [*c]Element, b_in: [*c]Element, ...) callconv(.c) void {
    if (!check.that(a_in != null and b_in != null, "gst_element_unlink_many", "element_1 != NULL && element_2 != NULL")) return;
    if (!check.that(element.isElement(a_in) and element.isElement(b_in), "gst_element_unlink_many", "GST_IS_ELEMENT (element_1) && GST_IS_ELEMENT (element_2)")) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var a = a_in;
    var b = b_in;
    while (b != null) {
        gst_element_unlink(a, b);
        a = b;
        b = @cVaArg(&ap, [*c]Element);
    }
}

pub export fn gst_element_unlink(src: [*c]Element, dest: [*c]Element) void {
    if (!check.that(element.isElement(src), "gst_element_unlink", "GST_IS_ELEMENT (src)")) return;
    if (!check.that(element.isElement(dest), "gst_element_unlink", "GST_IS_ELEMENT (dest)")) return;
    const it = element.gst_element_iterate_pads(src);
    var item = std.mem.zeroes(c.GValue);
    var done = false;
    while (!done) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_OK => {
                const p = padOf(c.g_value_get_object(&item));
                if (pad.isSrc(p)) {
                    const peer = pad.gst_pad_get_peer(p);
                    if (peer != null) {
                        const pe = pad.gst_pad_get_parent_element(peer);
                        if (pe == dest) _ = pad.gst_pad_unlink(p, peer);
                        if (pe != null) c.gst_object_unref(pe);
                        c.gst_object_unref(peer);
                    }
                }
                _ = c.g_value_reset(&item);
            },
            c.GST_ITERATOR_RESYNC => c.gst_iterator_resync(it),
            else => done = true,
        }
    }
    c.g_value_unset(&item);
    c.gst_iterator_free(it);
}

pub export fn gst_element_query_position(e: [*c]Element, format: c.GstFormat, cur: [*c]c.gint64) c.gboolean {
    if (cur != null) cur.* = -1;
    if (!check.that(element.isElement(e), "gst_element_query_position", "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(format != c.GST_FORMAT_UNDEFINED, "gst_element_query_position", "format != GST_FORMAT_UNDEFINED")) return 0;
    const q = c.gst_query_new_position(format);
    const ok = element.gst_element_query(e, q);
    if (ok != 0) c.gst_query_parse_position(q, null, cur);
    c.gst_query_unref(q);
    return ok;
}

pub export fn gst_element_query_duration(e: [*c]Element, format: c.GstFormat, dur: [*c]c.gint64) c.gboolean {
    if (dur != null) dur.* = -1;
    if (!check.that(element.isElement(e), "gst_element_query_duration", "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(format != c.GST_FORMAT_UNDEFINED, "gst_element_query_duration", "format != GST_FORMAT_UNDEFINED")) return 0;
    const q = c.gst_query_new_duration(format);
    const ok = element.gst_element_query(e, q);
    if (ok != 0) c.gst_query_parse_duration(q, null, dur);
    c.gst_query_unref(q);
    return ok;
}

pub export fn gst_element_query_convert(e: [*c]Element, sf: c.GstFormat, sv: c.gint64, df: c.GstFormat, dv: [*c]c.gint64) c.gboolean {
    const f = "gst_element_query_convert";
    if (!check.that(element.isElement(e), f, "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(df != c.GST_FORMAT_UNDEFINED, f, "dest_format != GST_FORMAT_UNDEFINED")) return 0;
    if (!check.that(dv != null, f, "dest_val != NULL")) return 0;
    if (df == sf or sv == -1) {
        dv.* = sv;
        return 1;
    }
    dv.* = -1;
    const q = c.gst_query_new_convert(sf, sv, df);
    const ok = element.gst_element_query(e, q);
    if (ok != 0) c.gst_query_parse_convert(q, null, null, null, dv);
    c.gst_query_unref(q);
    return ok;
}

pub export fn gst_element_seek_simple(e: [*c]Element, format: c.GstFormat, flags: c.GstSeekFlags, pos: c.gint64) c.gboolean {
    if (!check.that(element.isElement(e), "gst_element_seek_simple", "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(pos >= 0, "gst_element_seek_simple", "seek_pos >= 0")) return 0;
    return element.gst_element_seek(e, 1.0, format, flags, c.GST_SEEK_TYPE_SET, pos, c.GST_SEEK_TYPE_SET, -1);
}

fn decorate(e: [*c]Element, id: [*c]const u8) [*c]u8 {
    var upstream: [*c]u8 = null;
    const sink = element.gst_element_get_static_pad(e, "sink");
    if (sink != null) {
        const ev = pad.gst_pad_get_sticky_event(sink, c.GST_EVENT_STREAM_START, 0);
        if (ev != null) {
            var tmp: [*c]const u8 = null;
            c.gst_event_parse_stream_start(ev, &tmp);
            if (tmp != null) upstream = c.g_strdup(tmp);
            c.gst_mini_object_unref(@ptrCast(ev));
        }
        c.gst_object_unref(sink);
    }
    if (upstream == null) {
        const q = c.gst_query_new_uri();
        var uri: [*c]u8 = null;
        if (element.gst_element_query(e, q) != 0) c.gst_query_parse_uri(q, &uri);
        if (uri != null) {
            const cs = c.g_checksum_new(c.G_CHECKSUM_SHA256);
            c.g_checksum_update(cs, uri, @intCast(c.strlen(uri)));
            c.g_free(uri);
            upstream = c.g_strdup(c.g_checksum_get_string(cs));
            c.g_checksum_free(cs);
        } else upstream = c.g_strdup_printf("%08x%08x%08x%08x", c.g_random_int(), c.g_random_int(), c.g_random_int(), c.g_random_int());
        c.gst_query_unref(q);
    }
    defer c.g_free(upstream);
    return if (id != null) c.g_strconcat(upstream, "/", id, @as([*c]const u8, null)) else c.g_strdup(upstream);
}

pub export fn gst_element_decorate_stream_id_printf_valist(e: [*c]Element, fmt: [*c]const u8, ap: va.CVaList) [*c]u8 {
    if (!check.that(fmt != null, "gst_element_decorate_stream_id_printf_valist", "format")) return null;
    const id = c.g_strdup_vprintf(fmt, ap);
    defer c.g_free(id);
    return decorate(e, id);
}

pub export fn gst_element_decorate_stream_id_printf(e: [*c]Element, fmt: [*c]const u8, ...) callconv(.c) [*c]u8 {
    if (!check.that(fmt != null, "gst_element_decorate_stream_id_printf", "format")) return null;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return gst_element_decorate_stream_id_printf_valist(e, fmt, va.toC(&ap));
}

pub export fn gst_element_decorate_stream_id(e: [*c]Element, id: [*c]const u8) [*c]u8 {
    if (!check.that(id != null, "gst_element_decorate_stream_id", "stream_id")) return null;
    if (!check.that(element.isElement(e), "gst_element_decorate_stream_id", "GST_IS_ELEMENT (element)")) return null;
    return decorate(e, id);
}

fn createId(p: [*c]Pad, parent: [*c]Element, id: [*c]const u8) [*c]u8 {
    const f = "gst_pad_create_stream_id_internal";
    if (!check.that(pad.isPad(p), f, "GST_IS_PAD (pad)")) return null;
    if (!check.that(pad.isSrc(p), f, "GST_PAD_IS_SRC (pad)")) return null;
    if (!check.that(element.isElement(parent), f, "GST_IS_ELEMENT (parent)")) return null;
    if (!check.that(parent[0].numsinkpads <= 1, f, "parent->numsinkpads <= 1")) return null;
    if (!check.that(parent[0].numsrcpads <= 1 or id != null, f, "parent->numsrcpads <= 1 || stream_id")) return null;
    return decorate(parent, id);
}

pub export fn gst_pad_create_stream_id_printf_valist(p: [*c]Pad, parent: [*c]Element, fmt: [*c]const u8, ap: va.CVaList) [*c]u8 {
    const expanded: [*c]u8 = if (fmt != null) c.g_strdup_vprintf(fmt, ap) else null;
    defer c.g_free(expanded);
    return createId(p, parent, expanded);
}

pub export fn gst_pad_create_stream_id_printf(p: [*c]Pad, parent: [*c]Element, fmt: [*c]const u8, ...) callconv(.c) [*c]u8 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return gst_pad_create_stream_id_printf_valist(p, parent, fmt, va.toC(&ap));
}

pub export fn gst_pad_create_stream_id(p: [*c]Pad, parent: [*c]Element, id: [*c]const u8) [*c]u8 {
    return createId(p, parent, id);
}
