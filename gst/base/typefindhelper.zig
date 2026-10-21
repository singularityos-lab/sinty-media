const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const Pad = @import("../padlayout.zig").Pad;

comptime {
    @import("../abi.zig").check(@This());
}

const Caps = c.GstCaps;
const Prob = c.GstTypeFindProbability;
const NONE: c.guint64 = std.math.maxInt(c.guint64);

const Mapped = struct {
    buffer: [*c]c.GstBuffer,
    map: c.GstMapInfo,
};

const RangeHelper = struct {
    buffers: ?*c.GSList = null,
    size: c.guint64,
    last_offset: c.guint64 = 0,
    func: c.GstTypeFindHelperGetRangeFunction,
    best: Prob = c.GST_TYPE_FIND_NONE,
    caps: [*c]Caps = null,
    obj: [*c]c.GstObject,
    parent: [*c]c.GstObject,
    flow: c.GstFlowReturn = c.GST_FLOW_OK,
};

fn rangePeek(data: c.gpointer, off_in: i64, size: c.guint) callconv(.c) [*c]const u8 {
    const h: *RangeHelper = @ptrCast(@alignCast(data));
    if (size == 0) return null;
    var off: c.guint64 = @bitCast(off_in);
    if (off_in < 0) {
        if (h.size == NONE or h.size < @as(c.guint64, @bitCast(-off_in))) return null;
        off = h.size +% off;
    }
    var insert: ?*c.GSList = null;
    if (off <= h.last_offset) {
        var walk = h.buffers;
        while (walk) |w| : (walk = w.next) {
            const m: *Mapped = @ptrCast(@alignCast(w.data));
            const boff = m.buffer[0].offset;
            const bsize = m.map.size;
            if (boff <= off) {
                if (off +% size < boff +% bsize) return m.map.data + (off - boff);
            } else if (off +% size >= boff +% bsize) {
                insert = w;
                break;
            }
        }
    }
    var buffer: [*c]c.GstBuffer = null;
    h.flow = h.func.?(h.obj, h.parent, off, @max(size, 4096), &buffer);
    if (h.flow != c.GST_FLOW_OK) return null;
    const boff = buffer[0].offset;
    const bsize = c.gst_buffer_get_size(buffer);
    if (bsize < size or (boff != NONE and boff != off)) {
        c.gst_buffer_unref(buffer);
        return null;
    }
    const m = std.heap.c_allocator.create(Mapped) catch return null;
    if (c.gst_buffer_map(buffer, &m.map, c.GST_MAP_READ) == 0) {
        c.gst_buffer_unref(buffer);
        std.heap.c_allocator.destroy(m);
        return null;
    }
    m.buffer = buffer;
    if (insert) |at| {
        h.buffers = c.g_slist_insert_before(h.buffers, at, m);
    } else {
        h.last_offset = buffer[0].offset +% bsize;
        h.buffers = c.g_slist_prepend(h.buffers, m);
    }
    return m.map.data;
}

fn rangeSuggest(data: c.gpointer, prob: c.guint, caps: [*c]Caps) callconv(.c) void {
    const h: *RangeHelper = @ptrCast(@alignCast(data));
    if (prob > h.best) {
        _ = c.gst_caps_replace(&h.caps, caps);
        h.best = prob;
    }
}

fn rangeLength(data: c.gpointer) callconv(.c) c.guint64 {
    return @as(*RangeHelper, @ptrCast(@alignCast(data))).size;
}

fn prioritize(list_in: ?*c.GList, ext: [*c]const u8) ?*c.GList {
    if (ext == null) return list_in;
    var list = list_in;
    var pos: c.gint = 0;
    var l: ?*c.GList = list;
    while (l) |node| {
        const next = node.next;
        const f: ?*c.GstTypeFindFactory = @ptrCast(@alignCast(node.data));
        var e = c.gst_type_find_factory_get_extensions(f);
        if (e != null) {
            while (e[0] != null) : (e += 1) {
                if (c.strcmp(e[0], ext) == 0) {
                    list = c.g_list_delete_link(list, node);
                    list = c.g_list_insert(list, f, pos);
                    pos += 1;
                    break;
                }
            }
        }
        l = next;
    }
    return list;
}

pub export fn gst_type_find_helper_get_range(obj: [*c]c.GstObject, parent: [*c]c.GstObject, func: c.GstTypeFindHelperGetRangeFunction, size: c.guint64, ext: [*c]const u8, prob: [*c]Prob) [*c]Caps {
    var caps: [*c]Caps = null;
    _ = gst_type_find_helper_get_range_full(obj, parent, func, size, ext, &caps, prob);
    return caps;
}

pub export fn gst_type_find_helper_get_range_full(obj: [*c]c.GstObject, parent: [*c]c.GstObject, func: c.GstTypeFindHelperGetRangeFunction, size: c.guint64, ext: [*c]const u8, caps: [*c][*c]Caps, prob: [*c]Prob) c.GstFlowReturn {
    const f = "gst_type_find_helper_get_range_full";
    if (!check.that(gtype.instanceOf(obj, c.gst_object_get_type()), f, "GST_IS_OBJECT (obj)")) return c.GST_FLOW_ERROR;
    if (!check.that(func != null, f, "func != NULL")) return c.GST_FLOW_ERROR;
    if (!check.that(caps != null, f, "caps != NULL")) return c.GST_FLOW_ERROR;
    caps.* = null;
    var h = RangeHelper{ .size = size, .func = func, .obj = obj, .parent = parent };
    var find = c.GstTypeFind{ .peek = rangePeek, .suggest = rangeSuggest, .data = &h, .get_length = if (size == 0 or size == NONE) null else rangeLength };
    const list = prioritize(c.gst_type_find_factory_get_list(), ext);
    var l: ?*c.GList = list;
    while (l) |node| : (l = node.next) {
        c.gst_type_find_factory_call_function(@ptrCast(@alignCast(node.data)), &find);
        if (h.best >= c.GST_TYPE_FIND_MAXIMUM) {
            h.flow = c.GST_FLOW_OK;
            break;
        } else if (h.flow != c.GST_FLOW_OK and h.flow != c.GST_FLOW_EOS) {
            _ = c.gst_caps_replace(&h.caps, null);
            break;
        }
    }
    c.gst_plugin_feature_list_free(list);
    var walk = h.buffers;
    while (walk) |w| : (walk = w.next) {
        const m: *Mapped = @ptrCast(@alignCast(w.data));
        c.gst_buffer_unmap(m.buffer, &m.map);
        c.gst_buffer_unref(m.buffer);
        std.heap.c_allocator.destroy(m);
    }
    c.g_slist_free(h.buffers);
    if (prob != null) prob.* = h.best;
    caps.* = if (h.best > 0) h.caps else null;
    return if (h.flow == c.GST_FLOW_EOS) c.GST_FLOW_ERROR else h.flow;
}

pub export fn gst_type_find_helper(src: ?*c.GstPad, size: c.guint64) [*c]Caps {
    if (!check.that(gtype.instanceOf(src, c.gst_object_get_type()), "gst_type_find_helper", "GST_IS_OBJECT (src)")) return null;
    const p: *Pad = @ptrCast(@alignCast(src));
    if (!check.that(p.getrangefunc != null, "gst_type_find_helper", "GST_PAD_GETRANGEFUNC (src) != NULL")) return null;
    return gst_type_find_helper_get_range(@ptrCast(p), p.object.parent, @ptrCast(p.getrangefunc), size, null, null);
}

const BufHelper = extern struct {
    data: [*c]const u8,
    size: c.gsize,
    best: Prob,
    caps: [*c]Caps,
    obj: [*c]c.GstObject,
};

fn bufPeek(data: c.gpointer, off: i64, size: c.guint) callconv(.c) [*c]const u8 {
    const h: *BufHelper = @ptrCast(@alignCast(data));
    if (size == 0 or off < 0 or size > h.size) return null;
    if (@as(c.guint64, @intCast(off)) <= h.size - size) return h.data + @as(usize, @intCast(off));
    return null;
}

fn bufSuggest(data: c.gpointer, prob: c.guint, caps: [*c]Caps) callconv(.c) void {
    const h: *BufHelper = @ptrCast(@alignCast(data));
    if (prob > h.best) {
        _ = c.gst_caps_replace(&h.caps, caps);
        h.best = prob;
    }
}

fn bufLength(data: c.gpointer) callconv(.c) c.guint64 {
    return @as(*BufHelper, @ptrCast(@alignCast(data))).size;
}

pub export fn gst_type_find_helper_for_data(obj: [*c]c.GstObject, data: [*c]const u8, size: c.gsize, prob: [*c]Prob) [*c]Caps {
    return gst_type_find_helper_for_data_with_extension(obj, data, size, null, prob);
}

pub export fn gst_type_find_helper_for_data_with_extension(obj: [*c]c.GstObject, data: [*c]const u8, size: c.gsize, ext: [*c]const u8, prob: [*c]Prob) [*c]Caps {
    if (!check.that(data != null, "gst_type_find_helper_for_data_with_extension", "data != NULL")) return null;
    var h = BufHelper{ .data = data, .size = size, .best = c.GST_TYPE_FIND_NONE, .caps = null, .obj = obj };
    if (size == 0) return null;
    var find = c.GstTypeFind{ .peek = bufPeek, .suggest = bufSuggest, .data = &h, .get_length = bufLength };
    const list = prioritize(c.gst_type_find_factory_get_list(), ext);
    var l: ?*c.GList = list;
    while (l) |node| : (l = node.next) {
        c.gst_type_find_factory_call_function(@ptrCast(@alignCast(node.data)), &find);
        if (h.best >= c.GST_TYPE_FIND_MAXIMUM) break;
    }
    c.gst_plugin_feature_list_free(list);
    if (prob != null) prob.* = h.best;
    return if (h.best > 0) h.caps else null;
}

pub export fn gst_type_find_list_factories_for_caps(obj: [*c]c.GstObject, caps: [*c]Caps) ?*c.GList {
    _ = obj;
    if (!check.that(caps != null, "gst_type_find_list_factories_for_caps", "caps != NULL")) return null;
    const list = c.gst_type_find_factory_get_list();
    var out: ?*c.GList = null;
    var l: ?*c.GList = list;
    while (l) |node| : (l = node.next) {
        const f: ?*c.GstTypeFindFactory = @ptrCast(@alignCast(node.data));
        if (c.gst_type_find_factory_has_function(f) != 0) continue;
        const fc = c.gst_type_find_factory_get_caps(f);
        if (fc == null) continue;
        if (c.gst_caps_can_intersect(fc, caps) != 0) out = c.g_list_prepend(out, c.gst_object_ref(f));
    }
    c.gst_plugin_feature_list_free(list);
    return c.g_list_reverse(out);
}

pub export fn gst_type_find_helper_for_data_with_caps(obj: [*c]c.GstObject, data: [*c]const u8, size: c.gsize, caps: [*c]Caps, prob: [*c]Prob) [*c]Caps {
    const f = "gst_type_find_helper_for_data_with_caps";
    if (!check.that(data != null, f, "data != NULL")) return null;
    if (!check.that(caps != null, f, "caps != NULL")) return null;
    if (!check.that(size != 0, f, "size != 0")) return null;
    var h = BufHelper{ .data = data, .size = size, .best = c.GST_TYPE_FIND_NONE, .caps = null, .obj = obj };
    var find = c.GstTypeFind{ .peek = bufPeek, .suggest = bufSuggest, .data = &h, .get_length = null };
    const factories = gst_type_find_list_factories_for_caps(obj, caps);
    var result: [*c]Caps = null;
    if (factories != null) {
        var last: Prob = c.GST_TYPE_FIND_NONE;
        var l: ?*c.GList = factories;
        while (l) |node| : (l = node.next) {
            c.gst_type_find_factory_call_function(@ptrCast(@alignCast(node.data)), &find);
            if (h.best > last) {
                last = h.best;
                result = c.gst_caps_ref(h.caps);
                if (last >= c.GST_TYPE_FIND_MAXIMUM) break;
            }
        }
        if (prob != null) prob.* = last;
    }
    c.g_list_free_full(factories, c.gst_object_unref);
    if (h.caps != null) c.gst_caps_unref(h.caps);
    return result;
}

fn bufferArgs(buf: [*c]c.GstBuffer, comptime f: []const u8) bool {
    if (!check.that(buf != null, f, "buf != NULL")) return false;
    if (!check.that(buf[0].mini_object.type == c._gst_buffer_type, f, "GST_IS_BUFFER (buf)")) return false;
    return check.that(buf[0].offset == 0 or buf[0].offset == NONE, f, "GST_BUFFER_OFFSET (buf) == 0 || GST_BUFFER_OFFSET (buf) == GST_BUFFER_OFFSET_NONE");
}

pub export fn gst_type_find_helper_for_buffer(obj: [*c]c.GstObject, buf: [*c]c.GstBuffer, prob: [*c]Prob) [*c]Caps {
    return gst_type_find_helper_for_buffer_with_extension(obj, buf, null, prob);
}

pub export fn gst_type_find_helper_for_buffer_with_extension(obj: [*c]c.GstObject, buf: [*c]c.GstBuffer, ext: [*c]const u8, prob: [*c]Prob) [*c]Caps {
    if (!bufferArgs(buf, "gst_type_find_helper_for_buffer_with_extension")) return null;
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(buf, &info, c.GST_MAP_READ) == 0) return null;
    defer c.gst_buffer_unmap(buf, &info);
    return gst_type_find_helper_for_data_with_extension(obj, info.data, info.size, ext, prob);
}

pub export fn gst_type_find_helper_for_buffer_with_caps(obj: [*c]c.GstObject, buf: [*c]c.GstBuffer, caps: [*c]Caps, prob: [*c]Prob) [*c]Caps {
    if (!check.that(caps != null, "gst_type_find_helper_for_buffer_with_caps", "caps != NULL")) return null;
    if (!bufferArgs(buf, "gst_type_find_helper_for_buffer_with_caps")) return null;
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(buf, &info, c.GST_MAP_READ) == 0) return null;
    defer c.gst_buffer_unmap(buf, &info);
    return gst_type_find_helper_for_data_with_caps(obj, info.data, info.size, caps, prob);
}

pub export fn gst_type_find_helper_for_extension(obj: [*c]c.GstObject, ext: [*c]const u8) [*c]Caps {
    _ = obj;
    if (!check.that(ext != null, "gst_type_find_helper_for_extension", "extension != NULL")) return null;
    const list = c.gst_type_find_factory_get_list();
    defer c.gst_plugin_feature_list_free(list);
    var l: ?*c.GList = list;
    while (l) |node| : (l = node.next) {
        const f: ?*c.GstTypeFindFactory = @ptrCast(@alignCast(node.data));
        if (c.gst_type_find_factory_has_function(f) != 0) continue;
        var e = c.gst_type_find_factory_get_extensions(f);
        if (e == null) continue;
        while (e[0] != null) : (e += 1) {
            if (c.strcmp(e[0], ext) != 0) continue;
            const r = c.gst_type_find_factory_get_caps(f);
            if (r != null) return c.gst_caps_ref(r);
        }
    }
    return null;
}
