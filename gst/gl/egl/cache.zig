const std = @import("std");
const c = @import("../../c.zig").c;

const Entry = extern struct {
    images: [c.GST_VIDEO_MAX_PLANES][*c]c.GstEGLImage,
};

const Cache = extern struct {
    refs: c.gint,
    table: ?*c.GHashTable,
    lock: c.GMutex,
};

pub export fn gst_egl_image_cache_ref(cache: *Cache) *Cache {
    _ = @atomicRmw(c.gint, &cache.refs, .Add, 1, .acq_rel);
    return cache;
}

pub export fn gst_egl_image_cache_unref(cache: *Cache) void {
    if (@atomicRmw(c.gint, &cache.refs, .Sub, 1, .acq_rel) == 1) {
        c.g_hash_table_unref(cache.table);
        c.g_mutex_clear(&cache.lock);
        c.g_free(cache);
    }
}

fn entryRemove(data: c.gpointer, mem: [*c]c.GstMiniObject) callconv(.c) void {
    const cache: *Cache = @ptrCast(@alignCast(data));
    c.g_mutex_lock(&cache.lock);
    _ = c.g_hash_table_remove(cache.table, mem);
    c.g_mutex_unlock(&cache.lock);
    gst_egl_image_cache_unref(cache);
}

fn entryAdd(cache: *Cache, mem: [*c]c.GstMemory) *Entry {
    const e: *Entry = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Entry))));
    _ = gst_egl_image_cache_ref(cache);
    c.gst_mini_object_weak_ref(@ptrCast(mem), entryRemove, cache);
    c.g_mutex_lock(&cache.lock);
    _ = c.g_hash_table_insert(cache.table, mem, e);
    c.g_mutex_unlock(&cache.lock);
    return e;
}

fn entryFree(data: c.gpointer) callconv(.c) void {
    const e: *Entry = @ptrCast(@alignCast(data));
    for (e.images) |img| {
        if (img != null) c.gst_mini_object_unref(@ptrCast(img));
    }
    c.g_free(e);
}

pub export fn gst_egl_image_cache_lookup(cache: *Cache, mem: [*c]c.GstMemory, plane: c.gint, prev: *[*c]c.GstMemory, entry: *?*Entry) [*c]c.GstEGLImage {
    if (mem != prev.*) {
        c.g_mutex_lock(&cache.lock);
        entry.* = @ptrCast(@alignCast(c.g_hash_table_lookup(cache.table, mem)));
        c.g_mutex_unlock(&cache.lock);
        prev.* = mem;
    }
    if (entry.*) |e| return e.images[@intCast(plane)];
    return null;
}

pub export fn gst_egl_image_cache_store(cache: *Cache, mem: [*c]c.GstMemory, plane: c.gint, img: [*c]c.GstEGLImage, entry: *?*Entry) void {
    if (entry.* == null) entry.* = entryAdd(cache, mem);
    entry.*.?.images[@intCast(plane)] = img;
}

pub export fn gst_egl_image_cache_new() *Cache {
    const cache: *Cache = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Cache))));
    cache.refs = 1;
    cache.table = c.g_hash_table_new_full(c.g_direct_hash, c.g_direct_equal, null, entryFree);
    c.g_mutex_init(&cache.lock);
    return cache;
}
