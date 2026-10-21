const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const mini = @import("mini.zig");
const memory = @import("memory.zig");
const meta = @import("meta.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Buffer = c.GstBuffer;
const Memory = c.GstMemory;
const Mini = c.GstMiniObject;
const Meta = c.GstMeta;
const MapInfo = c.GstMapInfo;
const Item = meta.Item;

const MEM_MAX = 16;
const NONE: c.GstClockTime = std.math.maxInt(u64);

const Impl = extern struct {
    buffer: Buffer,
    len: c.guint,
    mem: [MEM_MAX]?*Memory,
    bufmem: ?*Memory,
    item: ?*Item,
    tail: ?*Item,
};

pub export var _gst_buffer_type: c.GType = 0;
var type_once: gtype.Once = .{};
var meta_seq = std.atomic.Value(i64).init(0);

fn poolRelease() ?*const fn ([*c]c.GstBufferPool, [*c]Buffer) callconv(.c) void {
    return @import("gtype.zig").lookup(?*const fn ([*c]c.GstBufferPool, [*c]Buffer) callconv(.c) void, "gst_buffer_pool_release_buffer");
}

fn impl(b: anytype) *Impl {
    return @ptrCast(@alignCast(@constCast(b)));
}

fn asMini(p: anytype) [*c]Mini {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn mems(b: anytype) []?*Memory {
    return impl(b).mem[0..impl(b).len];
}

fn memAt(b: anytype, i: usize) *Memory {
    return impl(b).mem[i].?;
}

fn isBuffer(b: anytype) bool {
    return b != null and asMini(b)[0].type == _gst_buffer_type;
}

fn setFlag(b: anytype, f: c.guint) void {
    asMini(b)[0].flags |= f;
}

fn lockExclusive(m: *Memory) bool {
    return mini.gst_mini_object_lock(@ptrCast(m), c.GST_LOCK_FLAG_EXCLUSIVE) != 0;
}

fn unlockExclusive(m: *Memory) void {
    mini.gst_mini_object_unlock(@ptrCast(m), c.GST_LOCK_FLAG_EXCLUSIVE);
}

fn noShare(m: *const Memory) bool {
    return m.mini_object.flags & c.GST_MEMORY_FLAG_NO_SHARE != 0;
}

fn adopt(b: [*c]Buffer, m: *Memory) void {
    mini.gst_mini_object_add_parent(@ptrCast(m), asMini(b));
}

fn release(b: [*c]Buffer, m: *Memory) void {
    mini.gst_mini_object_remove_parent(@ptrCast(m), asMini(b));
}

fn spanOf(list: []?*Memory, offset: *c.gsize, parent: *?*Memory) bool {
    var found = false;
    var prev: ?*Memory = null;
    for (list) |cur| {
        if (prev != null and cur != null) {
            var po: c.gsize = 0;
            if (memory.gst_memory_is_span(prev, cur, &po) == 0) return false;
            if (!found) {
                offset.* = po;
                parent.* = prev.?.parent;
                found = true;
            }
        }
        if (cur != null) prev = cur;
    }
    return found;
}

fn mergeCopy(b: [*c]Buffer, idx: c.guint, length: c.guint) ?*Memory {
    const size = gst_buffer_get_sizes_range(b, idx, @intCast(length), null, null);
    var offset: c.gsize = 0;
    var parent: ?*Memory = null;
    const list = impl(b).mem[idx .. idx + length];
    if (spanOf(list, &offset, &parent)) {
        var out: ?*Memory = null;
        if (!noShare(parent.?)) out = memory.gst_memory_share(parent, @intCast(offset), @intCast(size));
        if (out == null) out = memory.gst_memory_copy(parent, @intCast(offset), @intCast(size));
        return out;
    }
    const out = memory.gst_allocator_alloc(null, size, null) orelse return null;
    var dst = std.mem.zeroes(MapInfo);
    if (memory.gst_memory_map(out, &dst, c.GST_MAP_WRITE) == 0) {
        c.gst_memory_unref(out);
        return null;
    }
    var ptr: [*]u8 = @ptrCast(dst.data);
    var left = size;
    for (list) |m| {
        if (left == 0) break;
        var src = std.mem.zeroes(MapInfo);
        if (memory.gst_memory_map(m, &src, c.GST_MAP_READ) == 0) {
            memory.gst_memory_unmap(out, &dst);
            c.gst_memory_unref(out);
            return null;
        }
        const n = @min(src.size, left);
        @memcpy(ptr[0..n], @as([*]const u8, @ptrCast(src.data))[0..n]);
        left -= n;
        ptr += n;
        memory.gst_memory_unmap(m, &src);
    }
    memory.gst_memory_unmap(out, &dst);
    return out;
}

fn merged(b: [*c]Buffer, idx: c.guint, length: c.guint) ?*Memory {
    if (length == 0) return null;
    if (length == 1) return c.gst_memory_ref(memAt(b, idx));
    return mergeCopy(b, idx, length);
}

fn replaceRange(b: [*c]Buffer, len: c.guint, idx_in: c.guint, length_in: c.guint, m: ?*Memory) void {
    var idx = idx_in;
    var length = length_in;
    const end = idx + length;
    for (impl(b).mem[idx..end]) |old| {
        unlockExclusive(old.?);
        release(b, old.?);
        c.gst_memory_unref(old);
    }
    if (m) |nm| {
        adopt(b, nm);
        _ = lockExclusive(nm);
        impl(b).mem[idx] = nm;
        idx += 1;
        length -= 1;
    }
    if (end < len) std.mem.copyForwards(?*Memory, impl(b).mem[idx .. idx + (len - end)], impl(b).mem[end..len]);
    impl(b).len = len - length;
    setFlag(b, c.GST_BUFFER_FLAG_TAG_MEMORY);
}

pub export fn gst_buffer_get_flags(b: [*c]Buffer) c.GstBufferFlags {
    return asMini(b)[0].flags;
}

pub export fn gst_buffer_has_flags(b: [*c]Buffer, f: c.GstBufferFlags) c.gboolean {
    return @intFromBool(asMini(b)[0].flags & f == f);
}

pub export fn gst_buffer_set_flags(b: [*c]Buffer, f: c.GstBufferFlags) c.gboolean {
    asMini(b)[0].flags |= f;
    return 1;
}

pub export fn gst_buffer_unset_flags(b: [*c]Buffer, f: c.GstBufferFlags) c.gboolean {
    asMini(b)[0].flags &= ~f;
    return 1;
}

fn exclusiveRef(m: *Memory) ?*Memory {
    if (lockExclusive(m)) return c.gst_memory_ref(m);
    const copy = memory.gst_memory_copy(m, 0, -1) orelse return null;
    if (!lockExclusive(copy)) {
        c.gst_memory_unref(copy);
        return null;
    }
    return copy;
}

fn addMemory(b: [*c]Buffer, idx_in: c.gint, m: *Memory) void {
    var len = impl(b).len;
    if (len >= MEM_MAX) {
        replaceRange(b, len, 0, len, merged(b, 0, len));
        len = 1;
    }
    const idx: c.guint = if (idx_in == -1) len else @intCast(idx_in);
    var i = len;
    while (i > idx) : (i -= 1) impl(b).mem[i] = impl(b).mem[i - 1];
    impl(b).mem[idx] = m;
    impl(b).len = len + 1;
    adopt(b, m);
    setFlag(b, c.GST_BUFFER_FLAG_TAG_MEMORY);
}

pub export fn gst_buffer_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstBuffer", @ptrCast(&mini.gst_mini_object_ref), @ptrCast(&mini.gst_mini_object_unref));
        }
    }.f);
}

pub fn initialize() void {
    _gst_buffer_type = gst_buffer_get_type();
    _ = gst_reference_timestamp_meta_get_info();
}

pub export fn gst_buffer_get_max_memory() c.guint {
    return MEM_MAX;
}

fn rangeOk(len: c.guint, idx: c.guint, length: c.gint, strict_positive: bool) bool {
    if (len == 0 and idx == 0 and length == -1) return true;
    if (length == -1 and idx < len) return true;
    if (strict_positive) return length > 0 and @as(i64, length) + idx <= len;
    return @as(i64, length) + idx <= len;
}

fn copyMetas(dest: [*c]Buffer, src: [*c]Buffer, flags: c.GstBufferCopyFlags, region: bool, offset: c.gsize, size: c.gsize) void {
    const deep = flags & c.GST_BUFFER_COPY_DEEP != 0;
    var walk = impl(src).item;
    while (walk) |it| : (walk = it.next) {
        const m = &it.meta;
        const info = m.info;
        const skip_memory = (region or flags & c.GST_BUFFER_COPY_MEMORY == 0 or flags & c.GST_BUFFER_COPY_MERGE != 0) and meta.gst_meta_api_type_has_tag(info[0].api, meta._gst_meta_tag_memory) != 0;
        if (skip_memory) continue;
        if (deep and meta.gst_meta_api_type_has_tag(info[0].api, meta._gst_meta_tag_memory_reference) != 0) continue;
        if (info[0].transform_func) |t| {
            var data = c.GstMetaTransformCopy{ .region = @intFromBool(region), .offset = offset, .size = size };
            _ = t(dest, m, src, meta._gst_meta_transform_copy, &data);
        }
    }
}

pub export fn gst_buffer_copy_into(dest: [*c]Buffer, src: [*c]Buffer, flags: c.GstBufferCopyFlags, offset: c.gsize, size_in: c.gsize) c.gboolean {
    const f = "gst_buffer_copy_into";
    if (!check.that(dest != null, f, "dest != NULL")) return 0;
    if (!check.that(src != null, f, "src != NULL")) return 0;
    if (dest == src) return 1;
    if (!check.that(gst_buffer_is_writable(dest) != 0, f, "gst_buffer_is_writable (dest)")) return 0;
    const bufsize = gst_buffer_get_size(src);
    if (!check.that(bufsize >= offset, f, "bufsize >= offset")) return 0;
    var region = offset > 0;
    var size = size_in;
    if (size == std.math.maxInt(c.gsize)) size = bufsize - offset;
    if (size < bufsize) region = true;
    if (!check.that(bufsize >= offset + size, f, "bufsize >= offset + size")) return 0;
    if (flags & c.GST_BUFFER_COPY_FLAGS != 0) {
        const keep: c.guint = ~@as(c.guint, c.GST_BUFFER_FLAG_TAG_MEMORY);
        asMini(dest)[0].flags = (asMini(src)[0].flags & keep) | (asMini(dest)[0].flags & ~keep);
    }
    if (flags & c.GST_BUFFER_COPY_TIMESTAMPS != 0) {
        if (offset == 0) {
            dest[0].pts = src[0].pts;
            dest[0].dts = src[0].dts;
            dest[0].offset = src[0].offset;
            if (size == bufsize) {
                dest[0].duration = src[0].duration;
                dest[0].offset_end = src[0].offset_end;
            }
        } else {
            dest[0].pts = NONE;
            dest[0].dts = NONE;
            dest[0].duration = NONE;
            dest[0].offset = NONE;
            dest[0].offset_end = NONE;
        }
    }
    var sharing = false;
    if (flags & c.GST_BUFFER_COPY_MEMORY != 0) {
        const deep = flags & c.GST_BUFFER_COPY_DEEP != 0;
        const dest_len = impl(dest).len;
        var left = size;
        var skip = offset;
        for (mems(src)) |opt| {
            if (left == 0) break;
            const m = opt.?;
            const bsize = m.size;
            if (bsize <= skip) {
                skip -= bsize;
                continue;
            }
            const tocopy = @min(bsize - skip, left);
            var fresh: ?*Memory = null;
            if (tocopy < bsize and !deep and !noShare(m)) {
                fresh = memory.gst_memory_share(m, @intCast(skip), @intCast(tocopy));
                if (fresh) |x| {
                    _ = lockExclusive(x);
                    skip = 0;
                }
            }
            if (deep or noShare(m) or (fresh == null and tocopy < bsize)) {
                fresh = memory.gst_memory_copy(m, @intCast(skip), @intCast(tocopy));
                if (fresh) |x| {
                    _ = lockExclusive(x);
                    skip = 0;
                }
            } else if (fresh == null) {
                fresh = exclusiveRef(m);
            }
            const got = fresh orelse {
                gst_buffer_remove_memory_range(dest, dest_len, -1);
                return 0;
            };
            if (got == m) sharing = true;
            addMemory(dest, -1, got);
            left -= tocopy;
        }
        if (flags & c.GST_BUFFER_COPY_MERGE != 0) {
            const len = impl(dest).len;
            const m = merged(dest, 0, len) orelse {
                gst_buffer_remove_memory_range(dest, dest_len, -1);
                return 0;
            };
            sharing = sharing and m == memAt(dest, 0);
            replaceRange(dest, len, 0, len, m);
        }
    }
    if (flags & c.GST_BUFFER_COPY_META != 0) copyMetas(dest, src, flags, region, offset, size);
    if (sharing and src[0].pool != null) _ = gst_buffer_add_parent_buffer_meta(dest, src);
    return 1;
}

fn copyWith(src: [*c]const Buffer, flags: c.GstBufferCopyFlags) [*c]Buffer {
    if (!check.that(src != null, "gst_buffer_copy_with_flags", "buffer != NULL")) return null;
    var copy = gst_buffer_new();
    if (gst_buffer_copy_into(copy, @constCast(src), flags, 0, std.math.maxInt(c.gsize)) == 0) _ = gst_buffer_replace(&copy, null);
    if (copy != null) asMini(copy)[0].flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_TAG_MEMORY);
    return copy;
}

fn copyHook(src: [*c]const Mini) callconv(.c) [*c]Mini {
    return asMini(copyWith(@ptrCast(src), c.GST_BUFFER_COPY_ALL));
}

pub export fn gst_buffer_copy_deep(b: [*c]const Buffer) [*c]Buffer {
    return copyWith(b, c.GST_BUFFER_COPY_ALL | c.GST_BUFFER_COPY_DEEP);
}

fn disposeHook(m: [*c]Mini) callconv(.c) c.gboolean {
    const b: [*c]Buffer = @ptrCast(m);
    const pool = b[0].pool;
    if (pool == null) return 1;
    _ = gst_buffer_ref(b);
    if (poolRelease()) |rel| rel(pool, b);
    return 0;
}

fn freeHook(m: [*c]Mini) callconv(.c) void {
    const b: [*c]Buffer = @ptrCast(m);
    for (mems(b)) |opt| {
        const mem = opt.?;
        unlockExclusive(mem);
        release(b, mem);
        c.gst_memory_unref(mem);
    }
    var walk = impl(b).item;
    while (walk) |it| {
        const next = it.next;
        if (it.meta.info[0].free_func) |free| free(&it.meta, b);
        c.g_free(it);
        walk = next;
    }
    c.g_free(b);
}

pub export fn gst_buffer_new() [*c]Buffer {
    const i: *Impl = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Impl))));
    mini.gst_mini_object_init(asMini(i), 0, _gst_buffer_type, copyHook, disposeHook, freeHook);
    i.buffer.pool = null;
    i.buffer.pts = NONE;
    i.buffer.dts = NONE;
    i.buffer.duration = NONE;
    i.buffer.offset = NONE;
    i.buffer.offset_end = NONE;
    i.len = 0;
    i.item = null;
    i.tail = null;
    i.bufmem = null;
    return @ptrCast(i);
}

pub export fn gst_buffer_new_allocate(allocator: [*c]c.GstAllocator, size: c.gsize, params: [*c]c.GstAllocationParams) [*c]Buffer {
    var m: ?*Memory = null;
    if (size > 0) m = memory.gst_allocator_alloc(allocator, size, params) orelse return null;
    const b = gst_buffer_new();
    if (m) |x| {
        _ = lockExclusive(x);
        addMemory(b, -1, x);
    }
    asMini(b)[0].flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_TAG_MEMORY);
    return b;
}

pub export fn gst_buffer_new_wrapped_full(flags: c.GstMemoryFlags, data: c.gpointer, maxsize: c.gsize, offset: c.gsize, size: c.gsize, user: c.gpointer, notify: c.GDestroyNotify) [*c]Buffer {
    const b = gst_buffer_new();
    const m = memory.gst_memory_new_wrapped(flags, data, maxsize, offset, size, user, notify).?;
    _ = lockExclusive(m);
    addMemory(b, -1, m);
    asMini(b)[0].flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_TAG_MEMORY);
    return b;
}

pub export fn gst_buffer_new_wrapped(data: c.gpointer, size: c.gsize) [*c]Buffer {
    return gst_buffer_new_wrapped_full(0, data, size, 0, size, data, c.g_free);
}

fn bytesUnref(p: c.gpointer) callconv(.c) void {
    c.g_bytes_unref(@ptrCast(p));
}

pub export fn gst_buffer_new_wrapped_bytes(bytes: ?*c.GBytes) [*c]Buffer {
    if (!check.that(bytes != null, "gst_buffer_new_wrapped_bytes", "bytes != NULL")) return null;
    var size: c.gsize = 0;
    const data = c.g_bytes_get_data(bytes, &size);
    if (!check.that(data != null, "gst_buffer_new_wrapped_bytes", "bytes_data != NULL")) return null;
    return gst_buffer_new_wrapped_full(c.GST_MEMORY_FLAG_READONLY, @constCast(data), size, 0, size, c.g_bytes_ref(bytes), bytesUnref);
}

pub export fn gst_buffer_new_memdup(data: c.gconstpointer, size: c.gsize) [*c]Buffer {
    const copy = c.g_memdup2(data, size);
    return gst_buffer_new_wrapped_full(0, copy, size, 0, size, copy, c.g_free);
}

pub export fn gst_buffer_n_memory(b: [*c]Buffer) c.guint {
    if (!check.that(isBuffer(b), "gst_buffer_n_memory", "GST_IS_BUFFER (buffer)")) return 0;
    return impl(b).len;
}

pub export fn gst_buffer_prepend_memory(b: [*c]Buffer, m: [*c]Memory) void {
    gst_buffer_insert_memory(b, 0, m);
}

pub export fn gst_buffer_append_memory(b: [*c]Buffer, m: [*c]Memory) void {
    gst_buffer_insert_memory(b, -1, m);
}

pub export fn gst_buffer_insert_memory(b: [*c]Buffer, idx: c.gint, m: [*c]Memory) void {
    const f = "gst_buffer_insert_memory";
    if (!check.that(isBuffer(b), f, "GST_IS_BUFFER (buffer)")) return;
    if (!check.that(gst_buffer_is_writable(b) != 0, f, "gst_buffer_is_writable (buffer)")) return;
    if (!check.that(m != null, f, "mem != NULL")) return;
    if (!check.that(idx == -1 or (idx >= 0 and idx <= impl(b).len), f, "idx == -1 || (idx >= 0 && idx <= GST_BUFFER_MEM_LEN (buffer))")) return;
    const got = exclusiveRef(m) orelse return check.fail(f, "tmp != NULL");
    c.gst_memory_unref(m);
    addMemory(b, idx, got);
}

fn mappedAt(b: [*c]Buffer, idx: usize, info: *MapInfo, flags: c.GstMapFlags) ?*Memory {
    const m = c.gst_memory_ref(memAt(b, idx)).?;
    const out = memory.gst_memory_make_mapped(m, info, flags);
    if (out != null and out != m) {
        adopt(b, out.?);
        _ = lockExclusive(out.?);
        impl(b).mem[idx] = out;
        unlockExclusive(m);
        release(b, m);
        setFlag(b, c.GST_BUFFER_FLAG_TAG_MEMORY);
    }
    c.gst_memory_unref(m);
    return out;
}

pub export fn gst_buffer_peek_memory(b: [*c]Buffer, idx: c.guint) [*c]Memory {
    if (!check.that(isBuffer(b), "gst_buffer_peek_memory", "GST_IS_BUFFER (buffer)")) return null;
    if (!check.that(idx < impl(b).len, "gst_buffer_peek_memory", "idx < GST_BUFFER_MEM_LEN (buffer)")) return null;
    return impl(b).mem[idx];
}

pub export fn gst_buffer_get_memory(b: [*c]Buffer, idx: c.guint) [*c]Memory {
    return gst_buffer_get_memory_range(b, idx, 1);
}

pub export fn gst_buffer_get_all_memory(b: [*c]Buffer) [*c]Memory {
    return gst_buffer_get_memory_range(b, 0, -1);
}

pub export fn gst_buffer_get_memory_range(b: [*c]Buffer, idx: c.guint, length_in: c.gint) [*c]Memory {
    const f = "gst_buffer_get_memory_range";
    if (!check.that(isBuffer(b), f, "GST_IS_BUFFER (buffer)")) return null;
    const len = impl(b).len;
    if (!check.that(rangeOk(len, idx, length_in, true), f, "(len == 0 && idx == 0 && length == -1) || (length == -1 && idx < len) || (length > 0 && length + idx <= len)")) return null;
    const length: c.guint = if (length_in == -1) len - idx else @intCast(length_in);
    return merged(b, idx, length);
}

pub export fn gst_buffer_replace_memory(b: [*c]Buffer, idx: c.guint, m: [*c]Memory) void {
    gst_buffer_replace_memory_range(b, idx, 1, m);
}

pub export fn gst_buffer_replace_all_memory(b: [*c]Buffer, m: [*c]Memory) void {
    gst_buffer_replace_memory_range(b, 0, -1, m);
}

pub export fn gst_buffer_replace_memory_range(b: [*c]Buffer, idx: c.guint, length_in: c.gint, m: [*c]Memory) void {
    const f = "gst_buffer_replace_memory_range";
    if (!check.that(isBuffer(b), f, "GST_IS_BUFFER (buffer)")) return;
    if (!check.that(gst_buffer_is_writable(b) != 0, f, "gst_buffer_is_writable (buffer)")) return;
    const len = impl(b).len;
    if (!check.that(rangeOk(len, idx, length_in, true), f, "(len == 0 && idx == 0 && length == -1) || (length == -1 && idx < len) || (length > 0 && length + idx <= len)")) return;
    const length: c.guint = if (length_in == -1) len - idx else @intCast(length_in);
    replaceRange(b, len, idx, length, m);
}

pub export fn gst_buffer_remove_memory(b: [*c]Buffer, idx: c.guint) void {
    gst_buffer_remove_memory_range(b, idx, 1);
}

pub export fn gst_buffer_remove_all_memory(b: [*c]Buffer) void {
    if (impl(b).len != 0) gst_buffer_remove_memory_range(b, 0, -1);
}

pub export fn gst_buffer_remove_memory_range(b: [*c]Buffer, idx: c.guint, length_in: c.gint) void {
    const f = "gst_buffer_remove_memory_range";
    if (!check.that(isBuffer(b), f, "GST_IS_BUFFER (buffer)")) return;
    if (!check.that(gst_buffer_is_writable(b) != 0, f, "gst_buffer_is_writable (buffer)")) return;
    const len = impl(b).len;
    if (!check.that(rangeOk(len, idx, length_in, false), f, "(len == 0 && idx == 0 && length == -1) || (length == -1 && idx < len) || length + idx <= len")) return;
    const length: c.guint = if (length_in == -1) len - idx else @intCast(length_in);
    replaceRange(b, len, idx, length, null);
}

pub export fn gst_buffer_find_memory(b: [*c]Buffer, offset_in: c.gsize, size: c.gsize, idx: [*c]c.guint, length: [*c]c.guint, skip: [*c]c.gsize) c.gboolean {
    const f = "gst_buffer_find_memory";
    if (!check.that(isBuffer(b), f, "GST_IS_BUFFER (buffer)")) return 0;
    if (!check.that(idx != null, f, "idx != NULL")) return 0;
    if (!check.that(length != null, f, "length != NULL")) return 0;
    if (!check.that(skip != null, f, "skip != NULL")) return 0;
    var offset = offset_in;
    var found: c.guint = 0;
    const len = impl(b).len;
    for (0..len) |i| {
        var s = memAt(b, i).size;
        if (s <= offset) {
            offset -= s;
            continue;
        }
        if (found == 0) {
            idx.* = @intCast(i);
            skip.* = offset;
            if (size == std.math.maxInt(c.gsize)) {
                length.* = len - @as(c.guint, @intCast(i));
                return 1;
            }
            s -= offset;
            offset = 0;
        }
        found +%= @truncate(s);
        if (found >= size) {
            length.* = @as(c.guint, @intCast(i)) - idx.* + 1;
            return 1;
        }
    }
    return 0;
}

pub export fn gst_buffer_is_memory_range_writable(b: [*c]Buffer, idx: c.guint, length: c.gint) c.gboolean {
    const f = "gst_buffer_is_memory_range_writable";
    if (!check.that(isBuffer(b), f, "GST_IS_BUFFER (buffer)")) return 0;
    const total = impl(b).len;
    if (!check.that(rangeOk(total, idx, length, true), f, "(len == 0 && idx == 0 && length == -1) || (length == -1 && idx < len) || (length > 0 && length + idx <= len)")) return 0;
    const n: c.guint = if (length == -1) total - idx else @intCast(length);
    for (0..n) |i| if (c.gst_memory_is_writable(memAt(b, i + idx)) == 0) return 0;
    return 1;
}

pub export fn gst_buffer_is_all_memory_writable(b: [*c]Buffer) c.gboolean {
    return gst_buffer_is_memory_range_writable(b, 0, -1);
}

pub export fn gst_buffer_get_sizes(b: [*c]Buffer, offset: [*c]c.gsize, maxsize: [*c]c.gsize) c.gsize {
    return gst_buffer_get_sizes_range(b, 0, -1, offset, maxsize);
}

pub export fn gst_buffer_get_size(b: [*c]Buffer) c.gsize {
    if (!check.that(isBuffer(b), "gst_buffer_get_size", "GST_IS_BUFFER (buffer)")) return 0;
    var size: c.gsize = 0;
    for (mems(b)) |m| size += m.?.size;
    return size;
}

pub export fn gst_buffer_get_sizes_range(b: [*c]Buffer, idx: c.guint, length_in: c.gint, offset: [*c]c.gsize, maxsize: [*c]c.gsize) c.gsize {
    const f = "gst_buffer_get_sizes_range";
    if (!check.that(isBuffer(b), f, "GST_IS_BUFFER (buffer)")) return 0;
    const len = impl(b).len;
    if (!check.that(rangeOk(len, idx, length_in, false), f, "(len == 0 && idx == 0 && length == -1) || (length == -1 && idx < len) || (length + idx <= len)")) return 0;
    const length: c.guint = if (length_in == -1) len - idx else @intCast(length_in);
    if (length == 1) return memory.gst_memory_get_sizes(memAt(b, idx), offset, maxsize);
    const range = impl(b).mem[idx .. idx + length];
    var size: c.gsize = 0;
    if (offset == null and maxsize == null) {
        for (range) |m| size += m.?.size;
        return size;
    }
    var offs: c.gsize = 0;
    var extra: c.gsize = 0;
    for (range) |m| {
        var o: c.gsize = 0;
        var ms: c.gsize = 0;
        const s = memory.gst_memory_get_sizes(m, &o, &ms);
        if (s != 0) {
            if (size == 0) offs = extra + o;
            size += s;
            extra = ms - (o + s);
        } else extra += ms;
    }
    if (offset != null) offset.* = offs;
    if (maxsize != null) maxsize.* = offs + size + extra;
    return size;
}

pub export fn gst_buffer_resize(b: [*c]Buffer, offset: c.gssize, size: c.gssize) void {
    _ = gst_buffer_resize_range(b, 0, -1, offset, size);
}

pub export fn gst_buffer_set_size(b: [*c]Buffer, size: c.gssize) void {
    _ = gst_buffer_resize_range(b, 0, -1, 0, size);
}

pub export fn gst_buffer_resize_range(b: [*c]Buffer, idx: c.guint, length_in: c.gint, offset_in: c.gssize, size_in: c.gssize) c.gboolean {
    const f = "gst_buffer_resize_range";
    if (!check.that(gst_buffer_is_writable(b) != 0, f, "gst_buffer_is_writable (buffer)")) return 0;
    if (!check.that(size_in >= -1, f, "size >= -1")) return 0;
    const len = impl(b).len;
    if (!check.that(rangeOk(len, idx, length_in, false), f, "(len == 0 && idx == 0 && length == -1) || (length == -1 && idx < len) || (length + idx <= len)")) return 0;
    const length: c.guint = if (length_in == -1) len - idx else @intCast(length_in);
    var bufoffs: c.gsize = 0;
    var bufmax: c.gsize = 0;
    const bufsize = gst_buffer_get_sizes_range(b, idx, @intCast(length), &bufoffs, &bufmax);
    var offset = offset_in;
    const ok_offset = (offset < 0 and @as(i64, @intCast(bufoffs)) >= -offset) or (offset >= 0 and bufoffs + @as(c.gsize, @intCast(offset)) <= bufmax);
    if (!check.that(ok_offset, f, "(offset < 0 && bufoffs >= -offset) || (offset >= 0 && bufoffs + offset <= bufmax)")) return 0;
    var size = size_in;
    if (size == -1) {
        if (!check.that(@as(i64, @intCast(bufsize)) >= offset, f, "bufsize >= offset")) return 0;
        size = @as(c.gssize, @intCast(bufsize)) - offset;
    }
    if (!check.that(@as(i64, @intCast(bufmax)) >= @as(i64, @intCast(bufoffs)) + offset + size, f, "bufmax >= bufoffs + offset + size")) return 0;
    if (offset == 0 and size == @as(c.gssize, @intCast(bufsize))) return 1;
    const end = idx + length;
    var i = idx;
    while (i < end) : (i += 1) {
        const m = memAt(b, i);
        const bsize: c.gssize = @intCast(m.size);
        var noffs: c.gssize = 0;
        var left: c.gssize = undefined;
        if (i + 1 == end) {
            left = size;
        } else if (bsize <= offset) {
            left = 0;
            noffs = offset - bsize;
            offset = 0;
        } else left = @min(bsize - offset, size);
        if (offset != 0 or left != bsize) {
            if (c.gst_memory_is_writable(m) != 0) {
                memory.gst_memory_resize(m, offset, @intCast(left));
            } else {
                var fresh: ?*Memory = null;
                if (!noShare(m)) fresh = memory.gst_memory_share(m, offset, left);
                if (fresh == null) fresh = memory.gst_memory_copy(m, offset, left);
                const nm = fresh orelse return 0;
                adopt(b, nm);
                _ = lockExclusive(nm);
                impl(b).mem[i] = nm;
                unlockExclusive(m);
                release(b, m);
                c.gst_memory_unref(m);
                setFlag(b, c.GST_BUFFER_FLAG_TAG_MEMORY);
            }
        }
        offset = noffs;
        size -= left;
    }
    return 1;
}

pub export fn gst_buffer_map(b: [*c]Buffer, info: [*c]MapInfo, flags: c.GstMapFlags) c.gboolean {
    return gst_buffer_map_range(b, 0, -1, info, flags);
}

pub export fn gst_buffer_map_range(b: [*c]Buffer, idx: c.guint, length_in: c.gint, info: [*c]MapInfo, flags: c.GstMapFlags) c.gboolean {
    const f = "gst_buffer_map_range";
    if (!check.that(isBuffer(b), f, "GST_IS_BUFFER (buffer)")) return 0;
    if (!check.that(info != null, f, "info != NULL")) return 0;
    const len = impl(b).len;
    if (!check.that(rangeOk(len, idx, length_in, true), f, "(len == 0 && idx == 0 && length == -1) || (length == -1 && idx < len) || (length > 0 && length + idx <= len)")) return 0;
    const writable = gst_buffer_is_writable(b) != 0;
    if (flags & c.GST_MAP_WRITE != 0 and !writable) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "write map requested on non-writable buffer");
        info.* = std.mem.zeroes(MapInfo);
        return 0;
    }
    const length: c.guint = if (length_in == -1) len - idx else @intCast(length_in);
    const m = merged(b, idx, length) orelse {
        info.* = std.mem.zeroes(MapInfo);
        return 1;
    };
    const nm = memory.gst_memory_make_mapped(m, info, flags & ~@as(c.GstMapFlags, c.GST_MAP_REF_MEMORY)) orelse {
        info.* = std.mem.zeroes(MapInfo);
        return 0;
    };
    if ((length > 1 or nm != m) and writable) replaceRange(b, len, idx, length, c.gst_memory_ref(nm));
    info[0].flags |= c.GST_MAP_REF_MEMORY;
    return 1;
}

pub export fn gst_buffer_unmap(b: [*c]Buffer, info: [*c]MapInfo) void {
    if (!check.that(isBuffer(b), "gst_buffer_unmap", "GST_IS_BUFFER (buffer)")) return;
    if (!check.that(info != null, "gst_buffer_unmap", "info != NULL")) return;
    memory.gst_map_info_clear(info);
}

fn locate(b: [*c]Buffer, offset: *c.gsize) usize {
    var i: usize = 0;
    while (i < impl(b).len) : (i += 1) {
        const s = memAt(b, i).size;
        if (s > offset.*) break;
        offset.* -= s;
    }
    return i;
}

fn Walk(comptime Op: type) type {
    return struct {
        fn run(b: [*c]Buffer, offset_in: c.gsize, total: c.gsize, flags: c.GstMapFlags, op: *Op) c.gsize {
            var offset = offset_in;
            var left = total;
            var i: usize = if (offset != 0) locate(b, &offset) else 0;
            while (i < impl(b).len and left > 0 and op.more()) : (i += 1) {
                var info = std.mem.zeroes(MapInfo);
                const m = mappedAt(b, i, &info, flags);
                const n = @min(info.size - offset, left);
                op.step(@as([*]u8, @ptrCast(info.data)) + offset, n);
                left -= n;
                offset = 0;
                memory.gst_memory_unmap(m, &info);
            }
            return total - left;
        }
    };
}

const Fill = struct {
    src: [*]const u8,
    fn more(_: *Fill) bool {
        return true;
    }
    fn step(self: *Fill, dst: [*]u8, n: usize) void {
        @memcpy(dst[0..n], self.src[0..n]);
        self.src += n;
    }
};

const Extract = struct {
    dst: [*]u8,
    fn more(_: *Extract) bool {
        return true;
    }
    fn step(self: *Extract, src: [*]u8, n: usize) void {
        @memcpy(self.dst[0..n], src[0..n]);
        self.dst += n;
    }
};

const Compare = struct {
    ptr: [*]const u8,
    res: c.gint = 0,
    fn more(self: *Compare) bool {
        return self.res == 0;
    }
    fn step(self: *Compare, src: [*]u8, n: usize) void {
        self.res = c.memcmp(self.ptr, src, n);
        self.ptr += n;
    }
};

const Fillbyte = struct {
    val: u8,
    fn more(_: *Fillbyte) bool {
        return true;
    }
    fn step(self: *Fillbyte, dst: [*]u8, n: usize) void {
        @memset(dst[0..n], self.val);
    }
};

pub export fn gst_buffer_fill(b: [*c]Buffer, offset: c.gsize, src: c.gconstpointer, size: c.gsize) c.gsize {
    const f = "gst_buffer_fill";
    if (!check.that(isBuffer(b), f, "GST_IS_BUFFER (buffer)")) return 0;
    if (!check.that(gst_buffer_is_writable(b) != 0, f, "gst_buffer_is_writable (buffer)")) return 0;
    if (!check.that(src != null or size == 0, f, "src != NULL || size == 0")) return 0;
    if (size == 0) return 0;
    var op = Fill{ .src = @ptrCast(src) };
    return Walk(Fill).run(b, offset, size, c.GST_MAP_WRITE, &op);
}

pub export fn gst_buffer_extract(b: [*c]Buffer, offset: c.gsize, dest: c.gpointer, size: c.gsize) c.gsize {
    if (!check.that(isBuffer(b), "gst_buffer_extract", "GST_IS_BUFFER (buffer)")) return 0;
    if (!check.that(dest != null, "gst_buffer_extract", "dest != NULL")) return 0;
    var op = Extract{ .dst = @ptrCast(dest) };
    return Walk(Extract).run(b, offset, size, c.GST_MAP_READ, &op);
}

pub export fn gst_buffer_memcmp(b: [*c]Buffer, offset: c.gsize, mem: c.gconstpointer, size: c.gsize) c.gint {
    if (!check.that(isBuffer(b), "gst_buffer_memcmp", "GST_IS_BUFFER (buffer)")) return 0;
    if (!check.that(mem != null, "gst_buffer_memcmp", "mem != NULL")) return 0;
    if (gst_buffer_get_size(b) < offset + size) return -1;
    var op = Compare{ .ptr = @ptrCast(mem) };
    _ = Walk(Compare).run(b, offset, size, c.GST_MAP_READ, &op);
    return op.res;
}

pub export fn gst_buffer_memset(b: [*c]Buffer, offset: c.gsize, val: c.guint8, size: c.gsize) c.gsize {
    if (!check.that(isBuffer(b), "gst_buffer_memset", "GST_IS_BUFFER (buffer)")) return 0;
    if (!check.that(gst_buffer_is_writable(b) != 0, "gst_buffer_memset", "gst_buffer_is_writable (buffer)")) return 0;
    var op = Fillbyte{ .val = val };
    return Walk(Fillbyte).run(b, offset, size, c.GST_MAP_WRITE, &op);
}

pub export fn gst_buffer_copy_region(b: [*c]Buffer, flags: c.GstBufferCopyFlags, offset: c.gsize, size: c.gsize) [*c]Buffer {
    if (!check.that(b != null, "gst_buffer_copy_region", "buffer != NULL")) return null;
    var copy = gst_buffer_new();
    if (gst_buffer_copy_into(copy, b, flags, offset, size) == 0) _ = gst_buffer_replace(&copy, null);
    return copy;
}

pub export fn gst_buffer_append(a: [*c]Buffer, b: [*c]Buffer) [*c]Buffer {
    return gst_buffer_append_region(a, b, 0, -1);
}

pub export fn gst_buffer_append_region(a_in: [*c]Buffer, b_in: [*c]Buffer, offset: c.gssize, size: c.gssize) [*c]Buffer {
    if (!check.that(isBuffer(a_in), "gst_buffer_append_region", "GST_IS_BUFFER (buf1)")) return null;
    if (!check.that(isBuffer(b_in), "gst_buffer_append_region", "GST_IS_BUFFER (buf2)")) return null;
    const a = gst_buffer_make_writable(a_in);
    const b = gst_buffer_make_writable(b_in);
    gst_buffer_resize(b, offset, size);
    for (0..impl(b).len) |i| {
        const m = memAt(b, i);
        release(b, m);
        impl(b).mem[i] = null;
        addMemory(a, -1, m);
    }
    impl(b).len = 0;
    setFlag(b, c.GST_BUFFER_FLAG_TAG_MEMORY);
    gst_buffer_unref(b);
    return a;
}

pub export fn gst_buffer_get_meta(b: [*c]Buffer, api: c.GType) [*c]Meta {
    if (!check.that(b != null, "gst_buffer_get_meta", "buffer != NULL")) return null;
    if (!check.that(api != 0, "gst_buffer_get_meta", "api != 0")) return null;
    var walk = impl(b).item;
    while (walk) |it| : (walk = it.next) if (it.meta.info[0].api == api) return &it.meta;
    return null;
}

pub export fn gst_buffer_get_n_meta(b: [*c]Buffer, api: c.GType) c.guint {
    var state: c.gpointer = null;
    var n: c.guint = 0;
    while (gst_buffer_iterate_meta_filtered(b, &state, api) != null) n += 1;
    return n;
}

pub export fn gst_buffer_add_meta(b: [*c]Buffer, info: [*c]const c.GstMetaInfo, params: c.gpointer) [*c]Meta {
    if (!check.that(b != null, "gst_buffer_add_meta", "buffer != NULL")) return null;
    if (!check.that(info != null, "gst_buffer_add_meta", "info != NULL")) return null;
    if (!check.that(gst_buffer_is_writable(b) != 0, "gst_buffer_add_meta", "gst_buffer_is_writable (buffer)")) return null;
    const size = meta.itemSize(info);
    const it: *Item = @ptrCast(@alignCast(if (info[0].init_func == null) c.g_malloc0(size) else c.g_malloc(size)));
    it.meta.info = info;
    it.meta.flags = c.GST_META_FLAG_NONE;
    if (info[0].init_func) |init| {
        if (init(&it.meta, params, b) == 0) {
            c.g_free(it);
            return null;
        }
    }
    it.seq_num = @bitCast(meta_seq.fetchAdd(1, .monotonic));
    it.next = null;
    if (impl(b).item == null) {
        impl(b).item = it;
        impl(b).tail = it;
    } else {
        impl(b).tail.?.next = it;
        impl(b).tail = it;
    }
    return &it.meta;
}

fn unlink(b: [*c]Buffer, walk: *Item, prev: *Item) void {
    if (impl(b).tail == walk) impl(b).tail = if (prev != walk) prev else null;
    if (impl(b).item == walk) impl(b).item = walk.next else prev.next = walk.next;
}

pub export fn gst_buffer_remove_meta(b: [*c]Buffer, m: [*c]Meta) c.gboolean {
    const f = "gst_buffer_remove_meta";
    if (!check.that(b != null, f, "buffer != NULL")) return 0;
    if (!check.that(m != null, f, "meta != NULL")) return 0;
    if (!check.that(gst_buffer_is_writable(b) != 0, f, "gst_buffer_is_writable (buffer)")) return 0;
    if (!check.that(m[0].flags & c.GST_META_FLAG_LOCKED == 0, f, "!GST_META_FLAG_IS_SET (meta, GST_META_FLAG_LOCKED)")) return 0;
    var prev = impl(b).item;
    var walk = prev;
    while (walk) |it| : (walk = it.next) {
        if (&it.meta == m) {
            unlink(b, it, prev.?);
            if (m[0].info[0].free_func) |free| free(m, b);
            c.g_free(it);
            return 1;
        }
        prev = it;
    }
    return 0;
}

pub export fn gst_buffer_iterate_meta(b: [*c]Buffer, state: [*c]c.gpointer) [*c]Meta {
    if (!check.that(b != null, "gst_buffer_iterate_meta", "buffer != NULL")) return null;
    if (!check.that(state != null, "gst_buffer_iterate_meta", "state != NULL")) return null;
    const slot: *?*Item = @ptrCast(@alignCast(state));
    slot.* = if (slot.* == null) impl(b).item else slot.*.?.next;
    return if (slot.*) |it| &it.meta else null;
}

pub export fn gst_buffer_iterate_meta_filtered(b: [*c]Buffer, state: [*c]c.gpointer, api: c.GType) [*c]Meta {
    if (!check.that(b != null, "gst_buffer_iterate_meta_filtered", "buffer != NULL")) return null;
    if (!check.that(state != null, "gst_buffer_iterate_meta_filtered", "state != NULL")) return null;
    const slot: *?*Item = @ptrCast(@alignCast(state));
    slot.* = if (slot.* == null) impl(b).item else slot.*.?.next;
    while (slot.*) |it| {
        if (it.meta.info[0].api == api) return &it.meta;
        slot.* = it.next;
    }
    return null;
}

pub export fn gst_buffer_foreach_meta(b: [*c]Buffer, func: c.GstBufferForeachMetaFunc, data: c.gpointer) c.gboolean {
    const f = "gst_buffer_foreach_meta";
    if (!check.that(b != null, f, "buffer != NULL")) return 0;
    if (!check.that(func != null, f, "func != NULL")) return 0;
    var res: c.gboolean = 1;
    var prev = impl(b).item;
    var walk = prev;
    while (walk) |it| {
        const next = it.next;
        var cur: [*c]Meta = &it.meta;
        res = func.?(b, &cur, data);
        if (cur == null) {
            if (!check.that(gst_buffer_is_writable(b) != 0, f, "gst_buffer_is_writable (buffer)")) return 0;
            if (!check.that(it.meta.flags & c.GST_META_FLAG_LOCKED == 0, f, "!GST_META_FLAG_IS_SET (m, GST_META_FLAG_LOCKED)")) return 0;
            if (impl(b).tail == it) impl(b).tail = if (prev != it) prev else null;
            if (impl(b).item == it) {
                impl(b).item = next;
                prev = next;
            } else prev.?.next = next;
            if (it.meta.info[0].free_func) |free| free(&it.meta, b);
            c.g_free(it);
        } else prev = it;
        if (res == 0) break;
        walk = next;
    }
    return res;
}

pub export fn gst_buffer_extract_dup(b: [*c]Buffer, offset: c.gsize, size: c.gsize, dest: [*c]c.gpointer, dest_size: [*c]c.gsize) void {
    const real = gst_buffer_get_size(b);
    const n = @min(real -% offset, size);
    if (n == 0) {
        dest.* = null;
        dest_size.* = 0;
        return;
    }
    dest.* = c.g_malloc(n);
    dest_size.* = gst_buffer_extract(b, offset, dest.*, size);
}

pub export fn gst_buffer_add_parent_buffer_meta(b: [*c]Buffer, ref: [*c]Buffer) [*c]c.GstParentBufferMeta {
    if (!check.that(isBuffer(ref), "gst_buffer_add_parent_buffer_meta", "GST_IS_BUFFER (ref)")) return null;
    const m: [*c]c.GstParentBufferMeta = @ptrCast(@alignCast(gst_buffer_add_meta(b, gst_parent_buffer_meta_get_info(), null)));
    if (m == null) return null;
    m[0].buffer = gst_buffer_ref(ref);
    return m;
}

fn parentTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, kind: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    if (kind != meta._gst_meta_transform_copy) return 0;
    const pm: *c.GstParentBufferMeta = @ptrCast(@alignCast(m));
    return @intFromBool(gst_buffer_add_parent_buffer_meta(dest, pm.buffer) != null);
}

fn parentFree(m: [*c]Meta, _: [*c]Buffer) callconv(.c) void {
    gst_buffer_unref(@as(*c.GstParentBufferMeta, @ptrCast(@alignCast(m))).buffer);
}

fn parentInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    @as(*c.GstParentBufferMeta, @ptrCast(@alignCast(m))).buffer = null;
    return 1;
}

pub export fn gst_parent_buffer_meta_api_get_type() c.GType {
    const S = struct {
        var once: gtype.Once = .{};
        fn f() c.GType {
            var tags = [_][*c]const u8{ c.GST_META_TAG_MEMORY_REFERENCE_STR, null };
            return meta.gst_meta_api_type_register("GstParentBufferMetaAPI", &tags);
        }
    };
    return S.once.get(S.f);
}

var parent_info = std.atomic.Value(?*const c.GstMetaInfo).init(null);
var parent_lock: c.GMutex = std.mem.zeroes(c.GMutex);

pub export fn gst_parent_buffer_meta_get_info() [*c]const c.GstMetaInfo {
    if (parent_info.load(.acquire)) |i| return i;
    c.g_mutex_lock(&parent_lock);
    defer c.g_mutex_unlock(&parent_lock);
    if (parent_info.load(.acquire) == null) parent_info.store(meta.gst_meta_register(gst_parent_buffer_meta_api_get_type(), "GstParentBufferMeta", @sizeOf(c.GstParentBufferMeta), parentInit, parentFree, parentTransform), .release);
    return parent_info.load(.acquire);
}

pub export fn gst_buffer_add_reference_timestamp_meta(b: [*c]Buffer, reference: [*c]c.GstCaps, ts: c.GstClockTime, duration: c.GstClockTime) [*c]c.GstReferenceTimestampMeta {
    if (!check.that(reference != null and reference[0].mini_object.type == c.gst_caps_get_type(), "gst_buffer_add_reference_timestamp_meta", "GST_IS_CAPS (reference)")) return null;
    if (!check.that(ts != NONE, "gst_buffer_add_reference_timestamp_meta", "timestamp != GST_CLOCK_TIME_NONE")) return null;
    const m: [*c]c.GstReferenceTimestampMeta = @ptrCast(@alignCast(gst_buffer_add_meta(b, gst_reference_timestamp_meta_get_info(), null)));
    if (m == null) return null;
    m[0].reference = c.gst_caps_ref(reference);
    m[0].timestamp = ts;
    m[0].duration = duration;
    m[0].info = null;
    return m;
}

pub export fn gst_buffer_get_reference_timestamp_meta(b: [*c]Buffer, reference: [*c]c.GstCaps) [*c]c.GstReferenceTimestampMeta {
    var state: c.gpointer = null;
    const api = gst_reference_timestamp_meta_get_info()[0].api;
    while (true) {
        const m = gst_buffer_iterate_meta(b, &state);
        if (m == null) return null;
        if (m[0].info[0].api != api) continue;
        const rm: [*c]c.GstReferenceTimestampMeta = @ptrCast(@alignCast(m));
        if (reference == null or c.gst_caps_is_subset(rm[0].reference, reference) != 0) return rm;
    }
}

fn rtTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, _: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    const s: *const c.GstReferenceTimestampMeta = @ptrCast(@alignCast(m));
    var iter: c.gpointer = null;
    while (true) {
        const o = gst_buffer_iterate_meta_filtered(dest, &iter, gst_reference_timestamp_meta_api_get_type());
        if (o == null) break;
        const om: *const c.GstReferenceTimestampMeta = @ptrCast(@alignCast(o));
        const same_info = (om.info == null and s.info == null) or (om.info != null and s.info != null and c.gst_structure_is_equal(om.info, s.info) != 0);
        if (om.timestamp == s.timestamp and om.duration == s.duration and c.gst_caps_is_equal(om.reference, s.reference) != 0 and same_info) return 1;
    }
    const d = gst_buffer_add_reference_timestamp_meta(dest, s.reference, s.timestamp, s.duration);
    if (d == null) return 0;
    if (s.info != null) d[0].info = c.gst_structure_copy(s.info);
    return 1;
}

fn rtFree(m: [*c]Meta, _: [*c]Buffer) callconv(.c) void {
    const r: *c.GstReferenceTimestampMeta = @ptrCast(@alignCast(m));
    if (r.reference != null) c.gst_caps_unref(r.reference);
    if (r.info != null) c.gst_structure_free(r.info);
}

fn rtInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const r: *c.GstReferenceTimestampMeta = @ptrCast(@alignCast(m));
    r.reference = null;
    r.timestamp = NONE;
    r.duration = NONE;
    r.info = null;
    return 1;
}

fn rtSerialize(m: [*c]const Meta, data: [*c]c.GstByteArrayInterface, _: [*c]c.guint8) callconv(.c) c.gboolean {
    const r: *const c.GstReferenceTimestampMeta = @ptrCast(@alignCast(m));
    const info_str: [*c]u8 = if (r.info != null) c.gst_structure_serialize_full(r.info, c.GST_SERIALIZE_FLAG_STRICT) else null;
    defer c.g_free(info_str);
    if (r.info != null and info_str == null) return 0;
    const info_len: usize = if (info_str != null) std.mem.len(info_str) else 0;
    const caps_str = c.gst_caps_to_string(r.reference);
    defer c.g_free(caps_str);
    const caps_len = std.mem.len(caps_str);
    const size = 16 + caps_len + 1 + (if (info_str != null) info_len + 1 else 0);
    const ptr = c.gst_byte_array_interface_append(data, size);
    if (ptr == null) return 0;
    std.mem.writeInt(u64, ptr[0..8], r.timestamp, .little);
    std.mem.writeInt(u64, ptr[8..16], r.duration, .little);
    @memcpy(ptr[16 .. 16 + caps_len + 1], caps_str[0 .. caps_len + 1]);
    if (info_str != null) @memcpy(ptr[17 + caps_len .. 17 + caps_len + info_len + 1], info_str[0 .. info_len + 1]);
    return 1;
}

fn rtDeserialize(_: [*c]const c.GstMetaInfo, b: [*c]Buffer, data: [*c]const c.guint8, size: c.gsize, version: c.guint8) callconv(.c) [*c]Meta {
    if (version != 0 or size < 17 or data[size - 1] != 0) return null;
    const ts = std.mem.readInt(u64, data[0..8], .little);
    const dur = std.mem.readInt(u64, data[8..16], .little);
    const caps_str: [*c]const u8 = @ptrCast(data + 16);
    const caps_len = std.mem.len(caps_str);
    const reference = c.gst_caps_from_string(caps_str);
    var info: [*c]c.GstStructure = null;
    if (size > 16 + caps_len + 1) info = c.gst_structure_from_string(@ptrCast(data + 17 + caps_len), null);
    const m = gst_buffer_add_reference_timestamp_meta(b, reference, ts, dur);
    c.gst_caps_unref(reference);
    m[0].info = info;
    return @ptrCast(m);
}

pub export fn gst_reference_timestamp_meta_api_get_type() c.GType {
    const S = struct {
        var once: gtype.Once = .{};
        fn f() c.GType {
            var tags = [_][*c]const u8{null};
            return meta.gst_meta_api_type_register("GstReferenceTimestampMetaAPI", &tags);
        }
    };
    return S.once.get(S.f);
}

var rt_info = std.atomic.Value(?*const c.GstMetaInfo).init(null);
var rt_lock: c.GMutex = std.mem.zeroes(c.GMutex);

pub export fn gst_reference_timestamp_meta_get_info() [*c]const c.GstMetaInfo {
    if (rt_info.load(.acquire)) |i| return i;
    c.g_mutex_lock(&rt_lock);
    defer c.g_mutex_unlock(&rt_lock);
    if (rt_info.load(.acquire) == null) {
        const info = meta.gst_meta_info_new(gst_reference_timestamp_meta_api_get_type(), "GstReferenceTimestampMeta", @sizeOf(c.GstReferenceTimestampMeta));
        info[0].init_func = rtInit;
        info[0].free_func = rtFree;
        info[0].transform_func = rtTransform;
        info[0].serialize_func = rtSerialize;
        info[0].deserialize_func = rtDeserialize;
        rt_info.store(meta.gst_meta_info_register(info), .release);
    }
    return rt_info.load(.acquire);
}

pub export fn gst_buffer_add_custom_meta(b: [*c]Buffer, name: [*c]const u8) [*c]c.GstCustomMeta {
    if (!check.that(name != null, "gst_buffer_add_custom_meta", "name != NULL")) return null;
    if (!check.that(isBuffer(b), "gst_buffer_add_custom_meta", "GST_IS_BUFFER (buffer)")) return null;
    const info = meta.gst_meta_get_info(name);
    if (info == null or meta.gst_meta_info_is_custom(info) == 0) return null;
    return @ptrCast(@alignCast(gst_buffer_add_meta(b, info, null)));
}

pub export fn gst_buffer_get_custom_meta(b: [*c]Buffer, name: [*c]const u8) [*c]c.GstCustomMeta {
    if (!check.that(b != null, "gst_buffer_get_custom_meta", "buffer != NULL")) return null;
    if (!check.that(name != null, "gst_buffer_get_custom_meta", "name != NULL")) return null;
    const info = meta.gst_meta_get_info(name);
    if (info == null or meta.gst_meta_info_is_custom(info) == 0) return null;
    return @ptrCast(@alignCast(gst_buffer_get_meta(b, info[0].api)));
}

pub export fn gst_buffer_ref(b: [*c]Buffer) [*c]Buffer {
    return @ptrCast(mini.gst_mini_object_ref(asMini(b)));
}

pub export fn gst_buffer_unref(b: [*c]Buffer) void {
    mini.gst_mini_object_unref(asMini(b));
}

pub export fn gst_clear_buffer(slot: [*c][*c]Buffer) void {
    mini.gst_clear_mini_object(@ptrCast(slot));
}

pub export fn gst_buffer_copy(b: [*c]const Buffer) [*c]Buffer {
    return @ptrCast(mini.gst_mini_object_copy(asMini(b)));
}

pub export fn gst_buffer_replace(slot: [*c][*c]Buffer, b: [*c]Buffer) c.gboolean {
    return mini.gst_mini_object_replace(@ptrCast(slot), asMini(b));
}

pub export fn gst_buffer_is_writable(b: [*c]const Buffer) c.gboolean {
    return mini.gst_mini_object_is_writable(asMini(b));
}

pub export fn gst_buffer_make_writable(b: [*c]Buffer) [*c]Buffer {
    return @ptrCast(mini.gst_mini_object_make_writable(asMini(b)));
}

pub export fn gst_buffer_steal(slot: [*c][*c]Buffer) [*c]Buffer {
    return @ptrCast(mini.gst_mini_object_steal(@ptrCast(slot)));
}

pub export fn gst_buffer_take(slot: [*c][*c]Buffer, b: [*c]Buffer) c.gboolean {
    return mini.gst_mini_object_take(@ptrCast(slot), asMini(b));
}

pub fn compareBuffers(a: [*c]Buffer, b: [*c]Buffer) c.gint {
    if (a == b) return c.GST_VALUE_EQUAL;
    const n = gst_buffer_get_size(a);
    if (n != gst_buffer_get_size(b)) return c.GST_VALUE_UNORDERED;
    if (n == 0) return c.GST_VALUE_EQUAL;
    var x = std.mem.zeroes(MapInfo);
    var y = std.mem.zeroes(MapInfo);
    if (gst_buffer_map(a, &x, c.GST_MAP_READ) == 0) return c.GST_VALUE_UNORDERED;
    defer gst_buffer_unmap(a, &x);
    if (gst_buffer_map(b, &y, c.GST_MAP_READ) == 0) return c.GST_VALUE_UNORDERED;
    defer gst_buffer_unmap(b, &y);
    const r = c.memcmp(x.data, y.data, x.size);
    if (r == 0) return c.GST_VALUE_EQUAL;
    return if (r < 0) c.GST_VALUE_LESS_THAN else c.GST_VALUE_GREATER_THAN;
}

fn compareValues(a: [*c]const c.GValue, b: [*c]const c.GValue) callconv(.c) c.gint {
    return compareBuffers(@ptrCast(@alignCast(c.g_value_get_boxed(a))), @ptrCast(@alignCast(c.g_value_get_boxed(b))));
}

pub fn hexOf(b: [*c]Buffer) [*c]u8 {
    if (b == null) return null;
    var info = std.mem.zeroes(MapInfo);
    if (gst_buffer_map(b, &info, c.GST_MAP_READ) == 0) return null;
    defer gst_buffer_unmap(b, &info);
    const out: [*]u8 = @ptrCast(c.g_malloc(info.size * 2 + 1));
    const digits = "0123456789abcdef";
    const data: [*]const u8 = @ptrCast(info.data);
    for (0..info.size) |i| {
        out[i * 2] = digits[data[i] >> 4];
        out[i * 2 + 1] = digits[data[i] & 15];
    }
    out[info.size * 2] = 0;
    return out;
}

fn serializeValue(v: [*c]const c.GValue) callconv(.c) [*c]u8 {
    return hexOf(@ptrCast(@alignCast(c.g_value_get_boxed(v))));
}

pub fn fromHex(dest: [*c]c.GValue, s: [*c]const u8) c.gboolean {
    const text = std.mem.span(s);
    if (text.len & 1 != 0) return 0;
    const b = gst_buffer_new_allocate(null, text.len / 2, null);
    var info = std.mem.zeroes(MapInfo);
    if (gst_buffer_map(b, &info, c.GST_MAP_WRITE) == 0) return 0;
    const data: [*]u8 = @ptrCast(info.data);
    for (0..text.len / 2) |i| {
        if (!std.ascii.isHex(text[i * 2]) or !std.ascii.isHex(text[i * 2 + 1])) {
            gst_buffer_unmap(b, &info);
            gst_buffer_unref(b);
            return 0;
        }
        data[i] = std.fmt.parseInt(u8, text[i * 2 .. i * 2 + 2], 16) catch unreachable;
    }
    gst_buffer_unmap(b, &info);
    c.g_value_take_boxed(dest, b);
    return 1;
}

fn deserializeValue(dest: [*c]c.GValue, s: [*c]const u8) callconv(.c) c.gboolean {
    return fromHex(dest, s);
}

var value_table: c.GstValueTable = .{};

pub fn registerValue() void {
    value_table = .{ .type = gst_buffer_get_type(), .compare = compareValues, .serialize = serializeValue, .deserialize = deserializeValue, .hash = @import("vhash.zig").buffer };
    @import("value.zig").gst_value_register(&value_table);
}
