const std = @import("std");
const c = @import("c.zig").c;
const gtype = @import("gtype.zig");
const check = @import("check.zig");
const tracer = @import("tracer.zig");
const mini = @import("mini.zig");
const object = @import("object.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Memory = c.GstMemory;
const Allocator = c.GstAllocator;
const Params = c.GstAllocationParams;

pub export var gst_memory_alignment: c.gsize = 7;
pub export var _gst_memory_type: c.GType = 0;

var default_allocator: [*c]Allocator = null;
var sysmem: [*c]Allocator = null;
var registry_lock: c.GRWLock = std.mem.zeroes(c.GRWLock);
var registry: ?*c.GHashTable = null;

var memory_type: gtype.Once = .{};
var allocator_type: gtype.Once = .{};
var sysmem_type: gtype.Once = .{};
var params_type: gtype.Once = .{};
var allocator_priv: c.gint = 0;
var sysmem_parent: ?*c.GObjectClass = null;

pub export fn gst_memory_get_type() c.GType {
    return memory_type.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstMemory", @ptrCast(&mini.gst_mini_object_ref), @ptrCast(&mini.gst_mini_object_unref));
        }
    }.f);
}

pub export fn gst_allocation_params_get_type() c.GType {
    return params_type.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstAllocationParams", @ptrCast(&gst_allocation_params_copy), @ptrCast(&gst_allocation_params_free));
        }
    }.f);
}

pub export fn gst_allocator_get_type() c.GType {
    return allocator_type.get(struct {
        fn f() c.GType {
            const t = gtype.object(object.gst_object_get_type(), "GstAllocator", c.GstAllocatorClass, Allocator, null, allocatorInit, c.G_TYPE_FLAG_ABSTRACT);
            allocator_priv = c.g_type_add_instance_private(t, @sizeOf(c.gpointer));
            return t;
        }
    }.f);
}

fn allocatorInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a: *Allocator = @ptrCast(@alignCast(instance));
    const base: [*]u8 = @ptrCast(instance);
    a.priv = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, allocator_priv)))));
    a.mem_copy = fallbackCopy;
    a.mem_is_span = noSpan;
}

fn of(p: anytype) *Memory {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn copyAll(m: [*c]const c.GstMiniObject) callconv(.c) [*c]c.GstMiniObject {
    return @ptrCast(gst_memory_copy(@ptrCast(@constCast(m)), 0, -1));
}

fn release(m: [*c]c.GstMiniObject) callconv(.c) void {
    const mem = of(m);
    if (mem.parent != null) {
        mini.gst_mini_object_unlock(@ptrCast(mem.parent), c.GST_LOCK_FLAG_EXCLUSIVE);
        mini.gst_mini_object_unref(@ptrCast(mem.parent));
    }
    const a = mem.allocator;
    tracer.emit(.memory_free_pre, .{@as([*c]Memory, mem)});
    gst_allocator_free(a, mem);
    tracer.emit(.memory_free_post, .{@as([*c]Memory, mem)});
    object.gst_object_unref(a);
}

pub export fn gst_memory_init(mem: [*c]Memory, flags: c.GstMemoryFlags, a: [*c]Allocator, parent: [*c]Memory, maxsize: c.gsize, alignment: c.gsize, offset: c.gsize, size: c.gsize) void {
    mini.gst_mini_object_init(@ptrCast(mem), flags | c.GST_MINI_OBJECT_FLAG_LOCKABLE, _gst_memory_type, copyAll, null, release);
    mem.*.allocator = @ptrCast(@alignCast(object.gst_object_ref(a)));
    if (parent != null) {
        _ = mini.gst_mini_object_lock(@ptrCast(parent), c.GST_LOCK_FLAG_EXCLUSIVE);
        _ = mini.gst_mini_object_ref(@ptrCast(parent));
    }
    mem.*.parent = parent;
    mem.*.maxsize = maxsize;
    mem.*.@"align" = alignment;
    mem.*.offset = offset;
    mem.*.size = size;
    tracer.emit(.memory_init, .{mem});
}

pub export fn gst_memory_is_type(mem: [*c]Memory, mem_type: [*c]const u8) c.gboolean {
    const func = "gst_memory_is_type";
    if (!check.that(mem != null, func, "mem != NULL")) return 0;
    if (!check.that(mem.*.allocator != null, func, "mem->allocator != NULL")) return 0;
    if (!check.that(mem_type != null, func, "mem_type != NULL")) return 0;
    return @intFromBool(c.g_strcmp0(mem.*.allocator.*.mem_type, mem_type) == 0);
}

pub export fn gst_memory_get_sizes(mem: [*c]Memory, offset: [*c]c.gsize, maxsize: [*c]c.gsize) c.gsize {
    if (!check.that(mem != null, "gst_memory_get_sizes", "mem != NULL")) return 0;
    if (offset != null) offset.* = mem.*.offset;
    if (maxsize != null) maxsize.* = mem.*.maxsize;
    return mem.*.size;
}

pub export fn gst_memory_resize(mem: [*c]Memory, offset: c.gssize, size: c.gsize) void {
    const func = "gst_memory_resize";
    if (!check.that(mem != null, func, "mem != NULL")) return;
    if (!check.that(gst_memory_is_writable(mem) != 0, func, "gst_memory_is_writable (mem)")) return;
    if (!check.that(offset >= 0 or mem.*.offset >= @as(c.gsize, @bitCast(-offset)), func, "offset >= 0 || mem->offset >= -offset")) return;
    if (!check.that(size +% mem.*.offset +% @as(c.gsize, @bitCast(offset)) <= mem.*.maxsize, func, "size + mem->offset + offset <= mem->maxsize")) return;
    const flags = &mem.*.mini_object.flags;
    if (offset > 0) flags.* &= ~@as(c.guint, c.GST_MEMORY_FLAG_ZERO_PREFIXED);
    if (@as(c.gsize, @bitCast(offset)) +% size < mem.*.size) flags.* &= ~@as(c.guint, c.GST_MEMORY_FLAG_ZERO_PADDED);
    mem.*.offset +%= @bitCast(offset);
    mem.*.size = size;
}

pub export fn gst_memory_make_mapped(mem: [*c]Memory, info: [*c]c.GstMapInfo, flags: c.GstMapFlags) [*c]Memory {
    if (gst_memory_map(mem, info, flags) != 0) return mem;
    const copy = gst_memory_copy(mem, 0, -1);
    gst_memory_unref(mem);
    if (copy == null) return null;
    if (gst_memory_map(copy, info, flags) == 0) {
        gst_memory_unref(copy);
        return null;
    }
    return copy;
}

pub export fn gst_memory_map(mem: [*c]Memory, info: [*c]c.GstMapInfo, flags: c.GstMapFlags) c.gboolean {
    if (!check.that(mem != null, "gst_memory_map", "mem != NULL")) return 0;
    if (!check.that(info != null, "gst_memory_map", "info != NULL")) return 0;
    if (mini.gst_mini_object_lock(@ptrCast(mem), flags) == 0) {
        info.* = std.mem.zeroes(c.GstMapInfo);
        return 0;
    }
    info.*.flags = flags;
    info.*.memory = mem;
    info.*.size = mem.*.size;
    info.*.maxsize = mem.*.maxsize - mem.*.offset;
    const a = mem.*.allocator;
    const data: [*c]u8 = @ptrCast(if (a.*.mem_map_full) |f| f(mem, info, mem.*.maxsize) else a.*.mem_map.?(mem, mem.*.maxsize, flags));
    if (data == null) {
        mini.gst_mini_object_unlock(@ptrCast(mem), flags);
        info.* = std.mem.zeroes(c.GstMapInfo);
        return 0;
    }
    info.*.data = data + mem.*.offset;
    if (flags & c.GST_MAP_REF_MEMORY != 0) _ = gst_memory_ref(mem);
    return 1;
}

pub export fn gst_memory_unmap(mem: [*c]Memory, info: [*c]c.GstMapInfo) void {
    const func = "gst_memory_unmap";
    if (!check.that(mem != null, func, "mem != NULL")) return;
    if (!check.that(info != null, func, "info != NULL")) return;
    if (!check.that(info.*.memory == mem, func, "info->memory == mem")) return;
    gst_map_info_clear(info);
}

pub export fn gst_map_info_init(info: [*c]c.GstMapInfo) void {
    if (!check.that(info != null, "gst_map_info_init", "info != NULL")) return;
    info.* = std.mem.zeroes(c.GstMapInfo);
}

pub export fn gst_map_info_clear(info: [*c]c.GstMapInfo) void {
    if (!check.that(info != null, "gst_map_info_clear", "info != NULL")) return;
    const mem = info.*.memory;
    if (mem == null) return;
    const a = mem.*.allocator;
    if (a.*.mem_unmap_full) |f| f(mem, info) else _ = a.*.mem_unmap.?(mem);
    mini.gst_mini_object_unlock(@ptrCast(mem), info.*.flags);
    if (info.*.flags & c.GST_MAP_REF_MEMORY != 0) gst_memory_unref(mem);
    info.*.memory = null;
    info.*.flags = 0;
    info.*.data = null;
    info.*.user_data = std.mem.zeroes(@TypeOf(info.*.user_data));
}

pub export fn gst_map_info_get_data(info: [*c]c.GstMapInfo, size: [*c]c.gsize) [*c]u8 {
    if (!check.that(info != null, "gst_map_info_get_data", "info != NULL")) return null;
    if (!check.that(size != null, "gst_map_info_get_data", "size != NULL")) return null;
    size.* = info.*.size;
    return info.*.data;
}

pub export fn gst_memory_copy(mem: [*c]Memory, offset: c.gssize, size: c.gssize) [*c]Memory {
    if (!check.that(mem != null, "gst_memory_copy", "mem != NULL")) return null;
    return mem.*.allocator.*.mem_copy.?(mem, offset, size);
}

pub export fn gst_memory_share(mem: [*c]Memory, offset: c.gssize, size: c.gssize) [*c]Memory {
    const func = "gst_memory_share";
    if (!check.that(mem != null, func, "mem != NULL")) return null;
    if (!check.that(mem.*.mini_object.flags & c.GST_MEMORY_FLAG_NO_SHARE == 0, func, "!GST_MEMORY_FLAG_IS_SET (mem, GST_MEMORY_FLAG_NO_SHARE)")) return null;
    const m: [*c]c.GstMiniObject = @ptrCast(mem);
    if (mini.gst_mini_object_lock(m, c.GST_LOCK_FLAG_EXCLUSIVE) == 0) return null;
    defer mini.gst_mini_object_unlock(m, c.GST_LOCK_FLAG_EXCLUSIVE);
    if (mini.gst_mini_object_lock(m, c.GST_LOCK_FLAG_EXCLUSIVE) == 0) return null;
    defer mini.gst_mini_object_unlock(m, c.GST_LOCK_FLAG_EXCLUSIVE);
    return mem.*.allocator.*.mem_share.?(mem, offset, size);
}

pub export fn gst_memory_is_span(a: [*c]Memory, b: [*c]Memory, offset: [*c]c.gsize) c.gboolean {
    if (!check.that(a != null, "gst_memory_is_span", "mem1 != NULL")) return 0;
    if (!check.that(b != null, "gst_memory_is_span", "mem2 != NULL")) return 0;
    if (a.*.allocator != b.*.allocator) return 0;
    if (a.*.parent == null or a.*.parent != b.*.parent) return 0;
    return a.*.allocator.*.mem_is_span.?(a, b, offset);
}

pub export fn gst_memory_ref(m: [*c]Memory) [*c]Memory {
    return @ptrCast(mini.gst_mini_object_ref(@ptrCast(m)));
}

pub export fn gst_memory_unref(m: [*c]Memory) void {
    mini.gst_mini_object_unref(@ptrCast(m));
}

pub export fn gst_memory_is_writable(m: [*c]const Memory) c.gboolean {
    return mini.gst_mini_object_is_writable(@ptrCast(m));
}

pub export fn gst_memory_make_writable(m: [*c]Memory) [*c]Memory {
    return @ptrCast(mini.gst_mini_object_make_writable(@ptrCast(m)));
}

pub export fn gst_memory_replace(slot: [*c][*c]Memory, m: [*c]Memory) c.gboolean {
    return mini.gst_mini_object_replace(@ptrCast(slot), @ptrCast(m));
}

pub export fn gst_memory_steal(slot: [*c][*c]Memory) [*c]Memory {
    return @ptrCast(mini.gst_mini_object_steal(@ptrCast(slot)));
}

pub export fn gst_memory_take(slot: [*c][*c]Memory, m: [*c]Memory) c.gboolean {
    return mini.gst_mini_object_take(@ptrCast(slot), @ptrCast(m));
}

pub export fn gst_allocation_params_new() [*c]Params {
    const p: [*c]Params = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Params))));
    gst_allocation_params_init(p);
    return p;
}

pub export fn gst_allocation_params_init(p: [*c]Params) void {
    if (!check.that(p != null, "gst_allocation_params_init", "params != NULL")) return;
    p.* = std.mem.zeroes(Params);
}

pub export fn gst_allocation_params_copy(p: [*c]const Params) [*c]Params {
    if (p == null) return null;
    return @ptrCast(@alignCast(c.g_memdup2(p, @sizeOf(Params))));
}

pub export fn gst_allocation_params_free(p: [*c]Params) void {
    c.g_free(p);
}

pub export fn gst_allocator_register(name: [*c]const u8, a: [*c]Allocator) void {
    if (!check.that(name != null, "gst_allocator_register", "name != NULL")) return;
    if (!check.that(a != null, "gst_allocator_register", "allocator != NULL")) return;
    c.g_rw_lock_writer_lock(&registry_lock);
    defer c.g_rw_lock_writer_unlock(&registry_lock);
    object.of(a).flags |= c.GST_OBJECT_FLAG_MAY_BE_LEAKED;
    _ = c.g_hash_table_insert(registry, c.g_strdup(name), a);
}

pub export fn gst_allocator_find(name: [*c]const u8) [*c]Allocator {
    c.g_rw_lock_reader_lock(&registry_lock);
    defer c.g_rw_lock_reader_unlock(&registry_lock);
    const a: [*c]Allocator = if (name != null) @ptrCast(@alignCast(c.g_hash_table_lookup(registry, name))) else default_allocator;
    if (a != null) _ = object.gst_object_ref(a);
    return a;
}

pub export fn gst_allocator_set_default(a: [*c]Allocator) void {
    if (!check.that(gtype.instanceOf(a, gst_allocator_get_type()), "gst_allocator_set_default", "GST_IS_ALLOCATOR (allocator)")) return;
    c.g_rw_lock_writer_lock(&registry_lock);
    const old = default_allocator;
    default_allocator = a;
    c.g_rw_lock_writer_unlock(&registry_lock);
    if (old != null) object.gst_object_unref(old);
}

var no_params = std.mem.zeroes(Params);

pub export fn gst_allocator_alloc(a: [*c]Allocator, size: c.gsize, params: [*c]Params) [*c]Memory {
    var p = params;
    if (p != null) {
        if (!check.that((p.*.@"align" +% 1) & p.*.@"align" == 0, "gst_allocator_alloc", "((params->align + 1) & params->align) == 0")) return null;
    } else p = &no_params;
    const target = if (a != null) a else default_allocator;
    const alloc = gtype.classPeek(c.GstAllocatorClass, target).alloc orelse return null;
    return alloc(target, size, p);
}

pub export fn gst_allocator_free(a: [*c]Allocator, mem: [*c]Memory) void {
    const func = "gst_allocator_free";
    if (!check.that(gtype.instanceOf(a, gst_allocator_get_type()), func, "GST_IS_ALLOCATOR (allocator)")) return;
    if (!check.that(mem != null, func, "memory != NULL")) return;
    if (!check.that(mem.*.allocator == a, func, "memory->allocator == allocator")) return;
    if (gtype.classPeek(c.GstAllocatorClass, a).free) |f| f(a, mem);
}

fn fallbackCopy(mem: [*c]Memory, offset: c.gssize, size_in: c.gssize) callconv(.c) [*c]Memory {
    var src: c.GstMapInfo = undefined;
    if (gst_memory_map(mem, &src, c.GST_MAP_READ) == 0) return null;
    defer gst_memory_unmap(mem, &src);
    const off: c.gsize = @bitCast(offset);
    const size: c.gsize = if (size_in == -1) (if (src.size > off) src.size - off else 0) else @bitCast(size_in);
    var target = mem.*.allocator;
    const aflags = object.of(target).flags;
    if (aflags & (c.GST_ALLOCATOR_FLAG_CUSTOM_ALLOC | c.GST_ALLOCATOR_FLAG_NO_COPY) != 0) target = null;
    var params = Params{ .flags = 0, .@"align" = mem.*.@"align", .prefix = 0, .padding = 0, ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
    const copy = gst_allocator_alloc(target, size, &params);
    var dst: c.GstMapInfo = undefined;
    if (gst_memory_map(copy, &dst, c.GST_MAP_WRITE) == 0) {
        gst_allocator_free(copy.*.allocator, copy);
        return null;
    }
    @memcpy(dst.data[0..size], src.data[off..][0..size]);
    gst_memory_unmap(copy, &dst);
    return copy;
}

fn noSpan(_: [*c]Memory, _: [*c]Memory, _: [*c]c.gsize) callconv(.c) c.gboolean {
    return 0;
}

const SysMem = extern struct {
    mem: Memory,
    data: [*c]u8,
    user_data: c.gpointer,
    notify: c.GDestroyNotify,
};

fn sysmemType() c.GType {
    return sysmem_type.get(struct {
        fn f() c.GType {
            return gtype.object(gst_allocator_get_type(), "GstAllocatorSysmem", c.GstAllocatorClass, Allocator, sysmemClassInit, sysmemInit, 0);
        }
    }.f);
}

fn sysmemClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    const ac: *c.GstAllocatorClass = @ptrCast(@alignCast(klass));
    sysmem_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    gc.finalize = sysmemFinalize;
    ac.alloc = sysAlloc;
    ac.free = sysFree;
}

fn sysmemInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a: *Allocator = @ptrCast(@alignCast(instance));
    a.mem_type = c.GST_ALLOCATOR_SYSMEM;
    a.mem_map = @ptrCast(&sysMap);
    a.mem_unmap = @ptrCast(&sysUnmap);
    a.mem_copy = @ptrCast(&sysCopy);
    a.mem_share = @ptrCast(&sysShare);
    a.mem_is_span = @ptrCast(&sysIsSpan);
}

fn sysmemFinalize(o: [*c]c.GObject) callconv(.c) void {
    if (default_allocator != null) c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "The default memory allocator was freed!");
    sysmem_parent.?.finalize.?(o);
}

fn sysWrap(flags: c.guint, parent: [*c]Memory, data: [*c]u8, maxsize: c.gsize, alignment: c.gsize, offset: c.gsize, size: c.gsize, user_data: c.gpointer, notify: c.GDestroyNotify) *SysMem {
    const m: *SysMem = @ptrCast(@alignCast(c.g_malloc(@sizeOf(SysMem))));
    gst_memory_init(&m.mem, flags, sysmem, parent, maxsize, alignment, offset, size);
    m.data = data;
    m.user_data = user_data;
    m.notify = notify;
    return m;
}

fn sysBlock(flags: c.guint, maxsize_in: c.gsize, align_in: c.gsize, offset: c.gsize, size: c.gsize) ?*SysMem {
    const alignment = align_in | gst_memory_alignment;
    const limit = std.math.maxInt(c.gsize);
    if (maxsize_in > limit - alignment) return null;
    var maxsize = maxsize_in + alignment;
    if (maxsize > limit - @sizeOf(SysMem)) return null;
    const raw: [*]u8 = @ptrCast(c.g_malloc(@sizeOf(SysMem) + maxsize) orelse return null);
    var data: [*c]u8 = raw + @sizeOf(SysMem);
    const misalign = @intFromPtr(data) & alignment;
    if (misalign != 0) {
        const skip = alignment + 1 - misalign;
        data += skip;
        maxsize -= skip;
    }
    if (offset != 0 and flags & c.GST_MEMORY_FLAG_ZERO_PREFIXED != 0) @memset(data[0..offset], 0);
    const tail = maxsize - (offset + size);
    if (tail != 0 and flags & c.GST_MEMORY_FLAG_ZERO_PADDED != 0) @memset(data[offset + size ..][0..tail], 0);
    const m: *SysMem = @ptrCast(@alignCast(raw));
    gst_memory_init(&m.mem, flags, sysmem, null, maxsize, alignment, offset, size);
    m.data = data;
    m.user_data = null;
    m.notify = null;
    return m;
}

fn sysMap(m: *SysMem, _: c.gsize, _: c.GstMapFlags) callconv(.c) c.gpointer {
    return m.data;
}

fn sysUnmap(_: *SysMem) callconv(.c) c.gboolean {
    return 1;
}

fn sysCopy(m: *SysMem, offset: c.gssize, size_in: c.gssize) callconv(.c) ?*SysMem {
    const off: c.gsize = @bitCast(offset);
    const size: c.gsize = if (size_in == -1) (if (m.mem.size > off) m.mem.size - off else 0) else @bitCast(size_in);
    const copy = sysBlock(0, size, m.mem.@"align", 0, size) orelse return null;
    @memcpy(copy.data[0..size], (m.data + m.mem.offset + off)[0..size]);
    return copy;
}

fn sysShare(m: *SysMem, offset: c.gssize, size_in: c.gssize) callconv(.c) *SysMem {
    const parent: [*c]Memory = if (m.mem.parent != null) m.mem.parent else &m.mem;
    const size: c.gsize = if (size_in == -1) m.mem.size -% @as(c.gsize, @bitCast(offset)) else @bitCast(size_in);
    return sysWrap(parent.*.mini_object.flags | c.GST_MINI_OBJECT_FLAG_LOCK_READONLY, parent, m.data, m.mem.maxsize, m.mem.@"align", m.mem.offset +% @as(c.gsize, @bitCast(offset)), size, null, null);
}

fn sysIsSpan(a: *SysMem, b: *SysMem, offset: [*c]c.gsize) callconv(.c) c.gboolean {
    if (offset != null) {
        const parent: *SysMem = @ptrCast(@alignCast(a.mem.parent));
        offset.* = a.mem.offset - parent.mem.offset;
    }
    return @intFromBool(a.data + a.mem.offset + a.mem.size == b.data + b.mem.offset);
}

fn sysAlloc(_: [*c]Allocator, size: c.gsize, p: [*c]Params) callconv(.c) [*c]Memory {
    const m = sysBlock(p.*.flags, size + p.*.prefix + p.*.padding, p.*.@"align", p.*.prefix, size) orelse return null;
    return &m.mem;
}

fn sysFree(_: [*c]Allocator, mem: [*c]Memory) callconv(.c) void {
    const m: *SysMem = @ptrCast(@alignCast(mem));
    if (m.notify) |n| n(m.user_data);
    c.g_free(m);
}

pub export fn gst_memory_new_wrapped(flags: c.GstMemoryFlags, data: c.gpointer, maxsize: c.gsize, offset: c.gsize, size: c.gsize, user_data: c.gpointer, notify: c.GDestroyNotify) [*c]Memory {
    if (!check.that(data != null, "gst_memory_new_wrapped", "data != NULL")) return null;
    if (!check.that(offset + size <= maxsize, "gst_memory_new_wrapped", "offset + size <= maxsize")) return null;
    return &sysWrap(flags, null, @ptrCast(data), maxsize, 0, offset, size, user_data, notify).mem;
}

pub fn initialize() void {
    _gst_memory_type = gst_memory_get_type();
    registry = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, object.gst_object_unref);
    sysmem = @ptrCast(@alignCast(c.g_object_new(sysmemType(), @as([*c]const u8, null))));
    _ = object.gst_object_ref_sink(sysmem);
    gst_allocator_register(c.GST_ALLOCATOR_SYSMEM, @ptrCast(@alignCast(object.gst_object_ref(sysmem))));
    default_allocator = @ptrCast(@alignCast(object.gst_object_ref(sysmem)));
}
