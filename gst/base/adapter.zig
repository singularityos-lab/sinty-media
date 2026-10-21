const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Buffer = c.GstBuffer;
const NONE: c.guint64 = std.math.maxInt(c.guint64);
const UNSET: c.guint = std.math.maxInt(c.guint);
const CHUNK = 4096;

const Adapter = extern struct {
    object: c.GObject,
    queue: ?*c.GstVecDeque,
    size: c.gsize,
    skip: c.gsize,
    count: c.guint,
    assembled: [*c]u8,
    assembled_size: c.gsize,
    assembled_len: c.gsize,
    pts: c.GstClockTime,
    pts_distance: c.guint64,
    dts: c.GstClockTime,
    dts_distance: c.guint64,
    offset: c.guint64,
    offset_distance: c.guint64,
    scan_offset: c.gsize,
    scan_idx: c.guint,
    pts_at_discont: c.GstClockTime,
    dts_at_discont: c.GstClockTime,
    offset_at_discont: c.guint64,
    distance_from_discont: c.guint64,
    info: c.GstMapInfo,

    pub const Header = c.struct__GstAdapter;
};

const AdapterClass = extern struct {
    parent: c.GObjectClass,
};

var type_once: gtype.Once = .{};
var parent: ?*c.GObjectClass = null;

pub export fn gst_adapter_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.g_object_get_type, "GstAdapter", AdapterClass, Adapter, classInit, init, 0);
            _ = c._gst_debug_category_new("adapter", 0, "object to splice and merge buffers to desired size");
            return t;
        }
    }.f);
}

fn isAdapter(a: anytype) bool {
    return gtype.instanceOf(a, gst_adapter_get_type());
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.dispose = dispose;
    gc.finalize = finalize;
}

fn resetState(a: *Adapter) void {
    a.pts = NONE;
    a.pts_distance = 0;
    a.dts = NONE;
    a.dts_distance = 0;
    a.offset = NONE;
    a.offset_distance = 0;
    a.pts_at_discont = NONE;
    a.dts_at_discont = NONE;
    a.offset_at_discont = NONE;
    a.distance_from_discont = 0;
}

fn init(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a: *Adapter = @ptrCast(@alignCast(instance));
    a.assembled = @ptrCast(c.g_malloc(CHUNK));
    a.assembled_size = CHUNK;
    resetState(a);
    a.queue = c.gst_vec_deque_new(10);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    gst_adapter_clear(@ptrCast(o));
    parent.?.dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const a: *Adapter = @ptrCast(@alignCast(o));
    c.g_free(a.assembled);
    c.gst_vec_deque_free(a.queue);
    parent.?.finalize.?(o);
}

fn nth(a: *Adapter, i: c.guint) [*c]Buffer {
    return @ptrCast(@alignCast(c.gst_vec_deque_peek_nth(a.queue, i)));
}

fn head(a: *Adapter) [*c]Buffer {
    return @ptrCast(@alignCast(c.gst_vec_deque_peek_head(a.queue)));
}

fn length(a: *Adapter) c.guint {
    return @truncate(c.gst_vec_deque_get_length(a.queue));
}

pub export fn gst_adapter_new() ?*Adapter {
    return @ptrCast(@alignCast(c.g_object_new(gst_adapter_get_type(), null)));
}

pub export fn gst_adapter_clear(a: ?*Adapter) void {
    if (!check.that(isAdapter(a), "gst_adapter_clear", "GST_IS_ADAPTER (adapter)")) return;
    const x: *Adapter = a.?;
    if (x.info.memory != null) gst_adapter_unmap(a);
    while (c.gst_vec_deque_pop_head(x.queue)) |o| c.gst_mini_object_unref(@ptrCast(@alignCast(o)));
    x.count = 0;
    x.size = 0;
    x.skip = 0;
    x.assembled_len = 0;
    resetState(x);
    x.scan_offset = 0;
    x.scan_idx = UNSET;
}

fn track(a: *Adapter, b: [*c]Buffer) void {
    const pts = b[0].pts;
    if (pts != NONE) {
        a.pts = pts;
        a.pts_distance = 0;
    }
    const dts = b[0].dts;
    if (dts != NONE) {
        a.dts = dts;
        a.dts_distance = 0;
    }
    const off = b[0].offset;
    if (off != NONE) {
        a.offset = off;
        a.offset_distance = 0;
    }
    if (b[0].mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0) {
        a.pts_at_discont = pts;
        a.dts_at_discont = dts;
        a.offset_at_discont = off;
        a.distance_from_discont = 0;
    }
}

fn copyInto(a: *Adapter, dest_in: [*c]u8, skip_in: c.gsize, size_in: c.gsize) void {
    var skip = skip_in;
    var size = size_in;
    var dest = dest_in;
    var idx: c.guint = 0;
    if (a.scan_idx != UNSET and a.scan_offset <= skip) {
        idx = a.scan_idx;
        skip -= a.scan_offset;
    }
    var b = nth(a, idx);
    idx += 1;
    var bsize = c.gst_buffer_get_size(b);
    while (skip >= bsize) {
        skip -= bsize;
        b = nth(a, idx);
        idx += 1;
        bsize = c.gst_buffer_get_size(b);
    }
    var n = @min(bsize - skip, size);
    _ = c.gst_buffer_extract(b, skip, dest, n);
    size -= n;
    dest += n;
    while (size > 0) {
        b = nth(a, idx);
        idx += 1;
        bsize = c.gst_buffer_get_size(b);
        if (bsize == 0) continue;
        n = @min(bsize, size);
        _ = c.gst_buffer_extract(b, 0, dest, n);
        size -= n;
        dest += n;
    }
}

pub export fn gst_adapter_push(a: ?*Adapter, b: [*c]Buffer) void {
    if (!check.that(isAdapter(a), "gst_adapter_push", "GST_IS_ADAPTER (adapter)")) return;
    if (!check.that(b != null and b[0].mini_object.type == c._gst_buffer_type, "gst_adapter_push", "GST_IS_BUFFER (buf)")) return;
    const x: *Adapter = a.?;
    x.size += c.gst_buffer_get_size(b);
    const first = c.gst_vec_deque_is_empty(x.queue) != 0;
    c.gst_vec_deque_push_tail(x.queue, b);
    if (first) track(x, b);
    x.count += 1;
}

pub export fn gst_adapter_map(a: ?*Adapter, size: c.gsize) c.gconstpointer {
    if (!check.that(isAdapter(a), "gst_adapter_map", "GST_IS_ADAPTER (adapter)")) return null;
    if (!check.that(size > 0, "gst_adapter_map", "size > 0")) return null;
    const x: *Adapter = a.?;
    if (x.info.memory != null) gst_adapter_unmap(a);
    if (size > x.size) return null;
    if (x.assembled_len >= size) return x.assembled;
    const cur = head(x);
    const skip = x.skip;
    if (c.gst_buffer_get_size(cur) >= size + skip) {
        if (c.gst_buffer_map(cur, &x.info, c.GST_MAP_READ) == 0) return null;
        return x.info.data + skip;
    }
    const reuse = x.assembled_len;
    if (x.assembled_size < size) {
        x.assembled_size = (size / CHUNK + 1) * CHUNK;
        if (reuse == 0) {
            c.g_free(x.assembled);
            x.assembled = @ptrCast(c.g_malloc(x.assembled_size));
        } else {
            x.assembled = @ptrCast(c.g_realloc(x.assembled, x.assembled_size));
        }
    }
    copyInto(x, x.assembled + reuse, skip + reuse, size - reuse);
    x.assembled_len = size;
    return x.assembled;
}

pub export fn gst_adapter_unmap(a: ?*Adapter) void {
    if (!check.that(isAdapter(a), "gst_adapter_unmap", "GST_IS_ADAPTER (adapter)")) return;
    const x: *Adapter = a.?;
    if (x.info.memory == null) return;
    c.gst_buffer_unmap(head(x), &x.info);
    x.info.memory = null;
}

pub export fn gst_adapter_copy(a: ?*Adapter, dest: c.gpointer, offset: c.gsize, size: c.gsize) void {
    if (!check.that(isAdapter(a), "gst_adapter_copy", "GST_IS_ADAPTER (adapter)")) return;
    if (!check.that(size > 0, "gst_adapter_copy", "size > 0")) return;
    if (!check.that(offset + size <= a.?.size, "gst_adapter_copy", "offset + size <= adapter->size")) return;
    copyInto(a.?, @ptrCast(dest), offset + a.?.skip, size);
}

pub export fn gst_adapter_copy_bytes(a: ?*Adapter, offset: c.gsize, size: c.gsize) ?*c.GBytes {
    const d = c.g_malloc(size);
    gst_adapter_copy(a, d, offset, size);
    return c.g_bytes_new_take(d, size);
}

fn flushUnchecked(a: *Adapter, amount: c.gsize) void {
    if (a.info.memory != null) gst_adapter_unmap(@ptrCast(a));
    a.size -= amount;
    a.assembled_len = 0;
    var flush = amount + a.skip;
    a.pts_distance -%= a.skip;
    a.dts_distance -%= a.skip;
    a.offset_distance -%= a.skip;
    a.distance_from_discont -%= a.skip;
    var cur = head(a);
    var size = c.gst_buffer_get_size(cur);
    while (flush >= size) {
        a.pts_distance +%= size;
        a.dts_distance +%= size;
        a.offset_distance +%= size;
        a.distance_from_discont +%= size;
        flush -= size;
        a.count -= 1;
        c.gst_buffer_unref(@ptrCast(@alignCast(c.gst_vec_deque_pop_head(a.queue))));
        if (c.gst_vec_deque_is_empty(a.queue) != 0) break;
        cur = head(a);
        track(a, cur);
        size = c.gst_buffer_get_size(cur);
    }
    a.skip = flush;
    a.pts_distance +%= flush;
    a.dts_distance +%= flush;
    a.offset_distance +%= flush;
    a.distance_from_discont +%= flush;
    a.scan_offset = 0;
    a.scan_idx = UNSET;
}

pub export fn gst_adapter_flush(a: ?*Adapter, flush: c.gsize) void {
    if (!check.that(isAdapter(a), "gst_adapter_flush", "GST_IS_ADAPTER (adapter)")) return;
    if (!check.that(flush <= a.?.size, "gst_adapter_flush", "flush <= adapter->size")) return;
    if (flush == 0) return;
    flushUnchecked(a.?, flush);
}

fn getInternal(a: *Adapter, n: c.gsize) [*c]u8 {
    const reuse = @min(n, a.assembled_len);
    const copy = n - reuse;
    var data: [*c]u8 = undefined;
    if (a.assembled_size >= n and reuse > 0) {
        data = a.assembled;
        a.assembled = @ptrCast(c.g_malloc(a.assembled_size));
    } else {
        data = @ptrCast(c.g_malloc(n));
        if (reuse > 0) @memcpy(data[0..reuse], a.assembled[0..reuse]);
    }
    if (copy > 0) copyInto(a, data + reuse, reuse + a.skip, copy);
    return data;
}

pub export fn gst_adapter_take(a: ?*Adapter, n: c.gsize) c.gpointer {
    if (!check.that(isAdapter(a), "gst_adapter_take", "GST_IS_ADAPTER (adapter)")) return null;
    if (!check.that(n > 0, "gst_adapter_take", "nbytes > 0")) return null;
    if (n > a.?.size) return null;
    const d = getInternal(a.?, n);
    flushUnchecked(a.?, n);
    return d;
}

pub export fn gst_adapter_get_buffer_fast(a: ?*Adapter, n: c.gsize) [*c]Buffer {
    if (!check.that(isAdapter(a), "gst_adapter_get_buffer_fast", "GST_IS_ADAPTER (adapter)")) return null;
    if (!check.that(n > 0, "gst_adapter_get_buffer_fast", "nbytes > 0")) return null;
    const x: *Adapter = a.?;
    if (n > x.size) return null;
    var skip = x.skip;
    const first = head(x);
    if (skip == 0 and c.gst_buffer_get_size(first) == n) return c.gst_buffer_ref(first);
    var out: [*c]Buffer = null;
    var left = n;
    const len = length(x);
    var i: c.guint = 0;
    while (i < len and left > 0) : (i += 1) {
        const cur = nth(x, i);
        const size = @min(c.gst_buffer_get_size(cur) - skip, left);
        if (out != null)
            _ = c.gst_buffer_copy_into(out, cur, c.GST_BUFFER_COPY_MEMORY | c.GST_BUFFER_COPY_META, skip, size)
        else
            out = c.gst_buffer_copy_region(cur, c.GST_BUFFER_COPY_ALL, skip, size);
        skip = 0;
        left -= size;
    }
    return out;
}

pub export fn gst_adapter_take_buffer_fast(a: ?*Adapter, n: c.gsize) [*c]Buffer {
    if (!check.that(isAdapter(a), "gst_adapter_take_buffer_fast", "GST_IS_ADAPTER (adapter)")) return null;
    if (!check.that(n > 0, "gst_adapter_take_buffer_fast", "nbytes > 0")) return null;
    const b = gst_adapter_get_buffer_fast(a, n);
    if (b != null) flushUnchecked(a.?, n);
    return b;
}

fn copyMeta(in: [*c]Buffer, meta: [*c][*c]c.GstMeta, data: c.gpointer) callconv(.c) c.gboolean {
    const minfo = meta.*[0].info;
    const api = minfo[0].api;
    if (c.gst_meta_api_type_has_tag(api, c._gst_meta_tag_memory) != 0 or c.gst_meta_api_type_has_tag(api, c._gst_meta_tag_memory_reference) != 0) return 1;
    if (minfo[0].transform_func) |f| {
        var copy = c.GstMetaTransformCopy{ .region = 0, .offset = 0, .size = std.math.maxInt(c.gsize) };
        _ = f(@ptrCast(@alignCast(data)), meta.*, in, c._gst_meta_transform_copy, &copy);
    }
    return 1;
}

pub export fn gst_adapter_get_buffer(a: ?*Adapter, n: c.gsize) [*c]Buffer {
    if (!check.that(isAdapter(a), "gst_adapter_get_buffer", "GST_IS_ADAPTER (adapter)")) return null;
    if (!check.that(n > 0, "gst_adapter_get_buffer", "nbytes > 0")) return null;
    const x: *Adapter = a.?;
    if (n > x.size) return null;
    const cur = head(x);
    const skip = x.skip;
    const hsize = c.gst_buffer_get_size(cur);
    if (skip == 0 and hsize == n) return c.gst_buffer_ref(cur);
    if (hsize >= n + skip) return c.gst_buffer_copy_region(cur, c.GST_BUFFER_COPY_ALL, skip, n);
    const d = getInternal(x, n);
    const out = c.gst_buffer_new_wrapped(d, n);
    var read: c.gsize = 0;
    const len = length(x);
    var i: c.guint = 0;
    while (i < len and read < n + x.skip) : (i += 1) {
        const b = nth(x, i);
        _ = c.gst_buffer_foreach_meta(b, copyMeta, out);
        read += c.gst_buffer_get_size(b);
    }
    return out;
}

pub export fn gst_adapter_take_buffer(a: ?*Adapter, n: c.gsize) [*c]Buffer {
    if (!check.that(isAdapter(a), "gst_adapter_take_buffer", "GST_IS_ADAPTER (adapter)")) return null;
    if (!check.that(n > 0, "gst_adapter_take_buffer", "nbytes > 0")) return null;
    const b = gst_adapter_get_buffer(a, n);
    if (b != null) flushUnchecked(a.?, n);
    return b;
}

fn headChunk(x: *Adapter, n: c.gsize) c.gsize {
    return @min(n, c.gst_buffer_get_size(head(x)) - x.skip);
}

fn piece(x: *Adapter, i: c.guint, skip: c.gsize, n: c.gsize, out: *c.gsize) [*c]Buffer {
    const cur = nth(x, i);
    const size = c.gst_buffer_get_size(cur);
    const h = @min(n, size - skip);
    out.* = h;
    if (skip == 0 and size == h) return c.gst_buffer_ref(cur);
    return c.gst_buffer_copy_region(cur, c.GST_BUFFER_COPY_ALL, skip, h);
}

pub export fn gst_adapter_take_list(a: ?*Adapter, n_in: c.gsize) ?*c.GList {
    if (!check.that(isAdapter(a), "gst_adapter_take_list", "GST_IS_ADAPTER (adapter)")) return null;
    if (!check.that(n_in <= a.?.size, "gst_adapter_take_list", "nbytes <= adapter->size")) return null;
    var q = std.mem.zeroes(c.GQueue);
    var n = n_in;
    while (n > 0) {
        const h = headChunk(a.?, n);
        c.g_queue_push_tail(&q, gst_adapter_take_buffer(a, h));
        n -= h;
    }
    return q.head;
}

pub export fn gst_adapter_get_list(a: ?*Adapter, n_in: c.gsize) ?*c.GList {
    if (!check.that(isAdapter(a), "gst_adapter_get_list", "GST_IS_ADAPTER (adapter)")) return null;
    if (!check.that(n_in <= a.?.size, "gst_adapter_get_list", "nbytes <= adapter->size")) return null;
    var q = std.mem.zeroes(c.GQueue);
    var n = n_in;
    var skip = a.?.skip;
    var i: c.guint = 0;
    while (n > 0) : (i += 1) {
        var h: c.gsize = 0;
        c.g_queue_push_tail(&q, piece(a.?, i, skip, n, &h));
        n -= h;
        skip = 0;
    }
    return q.head;
}

fn listSize(x: *Adapter, n: c.gsize) c.guint {
    if (x.count < 64) return x.count;
    const f = @as(f64, @floatFromInt(x.count)) * @as(f64, @floatFromInt(n)) * 1.2 / @as(f64, @floatFromInt(x.size));
    return @as(c.guint, @intFromFloat(f)) + 1;
}

pub export fn gst_adapter_take_buffer_list(a: ?*Adapter, n_in: c.gsize) ?*c.GstBufferList {
    if (!check.that(isAdapter(a), "gst_adapter_take_buffer_list", "GST_IS_ADAPTER (adapter)")) return null;
    if (n_in > a.?.size) return null;
    const list = c.gst_buffer_list_new_sized(listSize(a.?, n_in));
    var n = n_in;
    while (n > 0) {
        const h = headChunk(a.?, n);
        c.gst_buffer_list_insert(list, -1, gst_adapter_take_buffer(a, h));
        n -= h;
    }
    return list;
}

pub export fn gst_adapter_get_buffer_list(a: ?*Adapter, n_in: c.gsize) ?*c.GstBufferList {
    if (!check.that(isAdapter(a), "gst_adapter_get_buffer_list", "GST_IS_ADAPTER (adapter)")) return null;
    if (n_in > a.?.size) return null;
    const list = c.gst_buffer_list_new_sized(listSize(a.?, n_in));
    var n = n_in;
    var skip = a.?.skip;
    var i: c.guint = 0;
    while (n > 0) : (i += 1) {
        var h: c.gsize = 0;
        c.gst_buffer_list_insert(list, -1, piece(a.?, i, skip, n, &h));
        n -= h;
        skip = 0;
    }
    return list;
}

pub export fn gst_adapter_available(a: ?*Adapter) c.gsize {
    if (!check.that(isAdapter(a), "gst_adapter_available", "GST_IS_ADAPTER (adapter)")) return 0;
    return a.?.size;
}

pub export fn gst_adapter_available_fast(a: ?*Adapter) c.gsize {
    if (!check.that(isAdapter(a), "gst_adapter_available_fast", "GST_IS_ADAPTER (adapter)")) return 0;
    const x: *Adapter = a.?;
    if (x.size == 0) return 0;
    if (x.assembled_len != 0) return x.assembled_len;
    var i: c.guint = 0;
    while (true) : (i += 1) {
        const size = c.gst_buffer_get_size(nth(x, i));
        if (size != 0) return size - x.skip;
    }
}

pub export fn gst_adapter_distance_from_discont(a: ?*Adapter) c.guint64 {
    return a.?.distance_from_discont;
}

pub export fn gst_adapter_offset_at_discont(a: ?*Adapter) c.guint64 {
    if (!check.that(isAdapter(a), "gst_adapter_offset_at_discont", "GST_IS_ADAPTER (adapter)")) return NONE;
    return a.?.offset_at_discont;
}

pub export fn gst_adapter_pts_at_discont(a: ?*Adapter) c.GstClockTime {
    if (!check.that(isAdapter(a), "gst_adapter_pts_at_discont", "GST_IS_ADAPTER (adapter)")) return NONE;
    return a.?.pts_at_discont;
}

pub export fn gst_adapter_dts_at_discont(a: ?*Adapter) c.GstClockTime {
    if (!check.that(isAdapter(a), "gst_adapter_dts_at_discont", "GST_IS_ADAPTER (adapter)")) return NONE;
    return a.?.dts_at_discont;
}

pub export fn gst_adapter_prev_offset(a: ?*Adapter, distance: [*c]c.guint64) c.guint64 {
    if (!check.that(isAdapter(a), "gst_adapter_prev_offset", "GST_IS_ADAPTER (adapter)")) return NONE;
    if (distance != null) distance.* = a.?.offset_distance;
    return a.?.offset;
}

pub export fn gst_adapter_prev_pts(a: ?*Adapter, distance: [*c]c.guint64) c.GstClockTime {
    if (!check.that(isAdapter(a), "gst_adapter_prev_pts", "GST_IS_ADAPTER (adapter)")) return NONE;
    if (distance != null) distance.* = a.?.pts_distance;
    return a.?.pts;
}

pub export fn gst_adapter_prev_dts(a: ?*Adapter, distance: [*c]c.guint64) c.GstClockTime {
    if (!check.that(isAdapter(a), "gst_adapter_prev_dts", "GST_IS_ADAPTER (adapter)")) return NONE;
    if (distance != null) distance.* = a.?.dts_distance;
    return a.?.dts;
}

fn atOffset(x: *Adapter, offset: c.gsize, distance: [*c]c.guint64, comptime dts: bool) c.GstClockTime {
    var read: c.gsize = 0;
    var at: c.gsize = 0;
    var t = if (dts) x.dts else x.pts;
    const len = length(x);
    var i: c.guint = 0;
    while (i < len and read < offset + x.skip) : (i += 1) {
        const b = nth(x, i);
        const bt = if (dts) b[0].dts else b[0].pts;
        if (bt != NONE) {
            t = bt;
            at = read;
        }
        read += c.gst_buffer_get_size(b);
    }
    if (distance != null) distance.* = (if (dts) x.dts_distance else x.pts_distance) +% offset -% at;
    return t;
}

pub export fn gst_adapter_prev_pts_at_offset(a: ?*Adapter, offset: c.gsize, distance: [*c]c.guint64) c.GstClockTime {
    if (!check.that(isAdapter(a), "gst_adapter_prev_pts_at_offset", "GST_IS_ADAPTER (adapter)")) return NONE;
    return atOffset(a.?, offset, distance, false);
}

pub export fn gst_adapter_prev_dts_at_offset(a: ?*Adapter, offset: c.gsize, distance: [*c]c.guint64) c.GstClockTime {
    if (!check.that(isAdapter(a), "gst_adapter_prev_dts_at_offset", "GST_IS_ADAPTER (adapter)")) return NONE;
    return atOffset(a.?, offset, distance, true);
}

pub export fn gst_adapter_masked_scan_uint32_peek(a: ?*Adapter, mask: c.guint32, pattern: c.guint32, offset: c.gsize, size_in: c.gsize, value: [*c]c.guint32) c.gssize {
    const f = "gst_adapter_masked_scan_uint32_peek";
    if (!check.that(size_in > 0, f, "size > 0")) return -1;
    if (!check.that(offset + size_in <= a.?.size, f, "offset + size <= adapter->size")) return -1;
    if (!check.that((~mask) & pattern == 0, f, "((~mask) & pattern) == 0")) return -1;
    if (size_in < 4) return -1;
    const x: *Adapter = a.?;
    var size = size_in;
    var skip = offset + x.skip;
    var idx: c.guint = 0;
    if (x.scan_idx != UNSET and x.scan_offset <= skip) {
        idx = x.scan_idx;
        skip -= x.scan_offset;
    } else {
        x.scan_offset = 0;
        x.scan_idx = UNSET;
    }
    var b = nth(x, idx);
    idx += 1;
    var bsize = c.gst_buffer_get_size(b);
    while (skip >= bsize) {
        skip -= bsize;
        x.scan_offset += bsize;
        x.scan_idx = idx;
        b = nth(x, idx);
        idx += 1;
        bsize = c.gst_buffer_get_size(b);
    }
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(b, &info, c.GST_MAP_READ) == 0) return -1;
    var data = info.data + skip;
    bsize = info.size - skip;
    skip = 0;
    var state: c.guint32 = ~pattern;
    while (true) {
        bsize = @min(bsize, size);
        for (0..bsize) |i| {
            state = (state << 8) | data[i];
            if (state & mask == pattern and skip + i >= 3) {
                if (value != null) value.* = state;
                c.gst_buffer_unmap(b, &info);
                return @intCast(offset + skip + i - 3);
            }
        }
        size -= bsize;
        if (size == 0) break;
        skip += bsize;
        x.scan_offset += info.size;
        x.scan_idx = idx;
        c.gst_buffer_unmap(b, &info);
        b = nth(x, idx);
        idx += 1;
        if (c.gst_buffer_map(b, &info, c.GST_MAP_READ) == 0) return -1;
        bsize = info.size;
        data = info.data;
    }
    c.gst_buffer_unmap(b, &info);
    return -1;
}

pub export fn gst_adapter_masked_scan_uint32(a: ?*Adapter, mask: c.guint32, pattern: c.guint32, offset: c.gsize, size: c.gsize) c.gssize {
    return gst_adapter_masked_scan_uint32_peek(a, mask, pattern, offset, size, null);
}
