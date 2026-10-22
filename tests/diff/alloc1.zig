const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);

fn z(p: [*c]const u8) []const u8 {
    return if (p == null) "-" else std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

fn memfd(size: usize, fill: u8) c_int {
    const r = std.os.linux.memfd_create("t", 0);
    const f: c_int = @intCast(r);
    _ = std.c.ftruncate(f, @intCast(size));
    var buf: [4096]u8 = undefined;
    @memset(&buf, fill);
    var left = size;
    while (left > 0) {
        const n = @min(left, buf.len);
        _ = std.c.write(f, &buf, n);
        left -= n;
    }
    return f;
}

fn showMem(label: []const u8, m: [*c]c.GstMemory) void {
    if (m == null) {
        out("{s} -", .{label});
        return;
    }
    var off: usize = 0;
    var max: usize = 0;
    const size = c.gst_memory_get_sizes(m, &off, &max);
    out("{s} type={s} size={d} off={d} max={d} align={d} flags={d} fd={d} isfd={d} isdma={d} isphys={d} isdrm={d} parent={d}", .{ label, z(m[0].allocator[0].mem_type), size, off, max, m[0].@"align", m[0].mini_object.flags, if (c.gst_is_fd_memory(m) != 0) @as(c_int, 1) else 0, c.gst_is_fd_memory(m), c.gst_is_dmabuf_memory(m), c.gst_is_phys_memory(m), c.gst_is_drm_dumb_memory(m), @intFromBool(m[0].parent != null) });
}

fn mapShow(label: []const u8, m: [*c]c.GstMemory, flags: c.GstMapFlags) void {
    var info: c.GstMapInfo = undefined;
    if (c.gst_memory_map(m, &info, flags) == 0) {
        out("{s} map failed", .{label});
        return;
    }
    var sum: u32 = 0;
    for (info.data[0..info.size]) |b| sum +%= b;
    out("{s} map size={d} maxsize={d} first={d} sum={d}", .{ label, info.size, info.maxsize, if (info.size > 0) info.data[0] else 0, sum });
    if (flags & c.GST_MAP_WRITE != 0 and info.size > 0) info.data[0] = 0x5a;
    c.gst_memory_unmap(m, &info);
}

pub fn main() void {
    c.gst_init(null, null);
    out("types {s} {s} {s} {s} {s} {s}", .{ z(c.g_type_name(c.gst_fd_allocator_get_type())), z(c.g_type_name(c.gst_dmabuf_allocator_get_type())), z(c.g_type_name(c.gst_shm_allocator_get_type())), z(c.g_type_name(c.gst_udmabuf_allocator_get_type())), z(c.g_type_name(c.gst_drm_dumb_allocator_get_type())), z(c.g_type_name(c.gst_phys_memory_allocator_get_type())) });
    out("parents {s} {s} {s} {s} {s}", .{ z(c.g_type_name(c.g_type_parent(c.gst_fd_allocator_get_type()))), z(c.g_type_name(c.g_type_parent(c.gst_dmabuf_allocator_get_type()))), z(c.g_type_name(c.g_type_parent(c.gst_shm_allocator_get_type()))), z(c.g_type_name(c.g_type_parent(c.gst_udmabuf_allocator_get_type()))), z(c.g_type_name(c.g_type_parent(c.gst_drm_dumb_allocator_get_type()))) });
    out("iface fundamental {s}", .{z(c.g_type_name(c.g_type_fundamental(c.gst_phys_memory_allocator_get_type())))});

    const fa = c.gst_fd_allocator_new();
    out("fd alloc type={s} flags={d} floating={d}", .{ z(fa[0].mem_type), fa[0].object.flags, c.g_object_is_floating(fa) });
    const f1 = memfd(8192, 7);
    const m1 = c.gst_fd_allocator_alloc_full(fa, f1, 8192, 100, 4000, c.GST_FD_MEMORY_FLAG_NONE);
    showMem("m1", m1);
    out("getfd same {d}", .{@intFromBool(c.gst_fd_memory_get_fd(m1) == f1)});
    mapShow("m1 r", m1, c.GST_MAP_READ);
    mapShow("m1 rw", m1, c.GST_MAP_READWRITE);
    mapShow("m1 r2", m1, c.GST_MAP_READ);
    var ma: c.GstMapInfo = undefined;
    var mb: c.GstMapInfo = undefined;
    out("nested {d} {d}", .{ c.gst_memory_map(m1, &ma, c.GST_MAP_READ), c.gst_memory_map(m1, &mb, c.GST_MAP_READ) });
    out("same ptr {d}", .{@intFromBool(ma.data == mb.data)});
    c.gst_memory_unmap(m1, &mb);
    c.gst_memory_unmap(m1, &ma);
    const s1 = c.gst_memory_share(m1, 10, 100);
    showMem("share", s1);
    mapShow("share r", s1, c.GST_MAP_READ);
    const s2 = c.gst_memory_share(m1, 110, -1);
    showMem("share2", s2);
    var span_off: usize = 9;
    out("span {d} off={d}", .{ c.gst_memory_is_span(s1, s2, &span_off), span_off });
    const s3 = c.gst_memory_share(s1, 5, 10);
    showMem("share3", s3);
    mapShow("share3 r", s3, c.GST_MAP_READ);
    const cp = c.gst_memory_copy(m1, 0, 64);
    showMem("copy", cp);
    mapShow("copy r", cp, c.GST_MAP_READ);
    c.gst_memory_unref(s3);
    c.gst_memory_unref(s2);
    c.gst_memory_unref(s1);
    c.gst_memory_unref(cp);
    c.gst_memory_unref(m1);
    out("fd closed {d}", .{@intFromBool(std.c.fcntl(f1, std.os.linux.F.GETFD) == -1)});

    const f2 = memfd(4096, 3);
    const m2 = c.gst_fd_allocator_alloc(fa, f2, 4096, c.GST_FD_MEMORY_FLAG_KEEP_MAPPED | c.GST_FD_MEMORY_FLAG_DONT_CLOSE);
    mapShow("keep r", m2, c.GST_MAP_READ);
    mapShow("keep rw", m2, c.GST_MAP_READWRITE);
    mapShow("keep r", m2, c.GST_MAP_READ);
    c.gst_memory_unref(m2);
    out("dont close open {d}", .{@intFromBool(std.c.fcntl(f2, std.os.linux.F.GETFD) != -1)});
    const m3 = c.gst_fd_allocator_alloc(fa, f2, 4096, c.GST_FD_MEMORY_FLAG_MAP_PRIVATE | c.GST_FD_MEMORY_FLAG_DONT_CLOSE);
    mapShow("private rw", m3, c.GST_MAP_READWRITE);
    mapShow("private r", m3, c.GST_MAP_READ);
    c.gst_memory_unref(m3);
    const m4 = c.gst_fd_allocator_alloc(fa, -1, 64, 0);
    mapShow("nofd", m4, c.GST_MAP_READ);
    c.gst_memory_unref(m4);
    const m5 = c.gst_fd_allocator_alloc(fa, 9999, 64, 0);
    mapShow("badfd", m5, c.GST_MAP_READ);
    c.gst_memory_unref(m5);

    const da = c.gst_dmabuf_allocator_new();
    out("dmabuf alloc type={s} flags={d}", .{ z(da[0].mem_type), da[0].object.flags });
    const f3 = memfd(2048, 9);
    const d1 = c.gst_dmabuf_allocator_alloc(da, f3, 2048);
    showMem("d1", d1);
    out("dmafd same {d}", .{@intFromBool(c.gst_dmabuf_memory_get_fd(d1) == f3)});
    mapShow("d1 r", d1, c.GST_MAP_READ);
    mapShow("d1 rw", d1, c.GST_MAP_READWRITE);
    const ds = c.gst_memory_share(d1, 100, 200);
    showMem("dshare", ds);
    c.gst_memory_unref(ds);
    c.gst_memory_unref(d1);
    const f4 = memfd(2048, 1);
    const d2 = c.gst_dmabuf_allocator_alloc_with_flags(da, f4, 1024, c.GST_FD_MEMORY_FLAG_KEEP_MAPPED);
    showMem("d2", d2);
    mapShow("d2 r", d2, c.GST_MAP_READ);
    c.gst_memory_unref(d2);

    c.gst_shm_allocator_init_once();
    c.gst_shm_allocator_init_once();
    const sa = c.gst_shm_allocator_get();
    out("shm alloc type={s} flags={d} reg={d}", .{ z(sa[0].mem_type), sa[0].object.flags, @intFromBool(c.gst_allocator_find("shm") == sa) });
    for ([_][4]usize{ .{ 100, 0, 0, 0 }, .{ 100, 7, 3, 0 }, .{ 1000, 63, 16, 16 }, .{ 5, 0, 0, 3 }, .{ 0, 0, 0, 0 } }) |cfg| {
        for ([_]c.GstMemoryFlags{ 0, c.GST_MEMORY_FLAG_ZERO_PREFIXED | c.GST_MEMORY_FLAG_ZERO_PADDED }) |mf| {
            var params: c.GstAllocationParams = undefined;
            c.gst_allocation_params_init(&params);
            params.@"align" = cfg[1];
            params.prefix = cfg[2];
            params.padding = cfg[3];
            params.flags = mf;
            const sm = c.gst_allocator_alloc(sa, cfg[0], &params);
            var label: [64]u8 = undefined;
            const l = std.fmt.bufPrint(&label, "shm {d}/{d}/{d}/{d}/{d}", .{ cfg[0], cfg[1], cfg[2], cfg[3], mf }) catch "shm";
            showMem(l, sm);
            mapShow(l, sm, c.GST_MAP_READWRITE);
            c.gst_memory_unref(sm);
        }
    }
    const shmcopy = c.gst_allocator_alloc(sa, 32, null);
    const shc = c.gst_memory_copy(shmcopy, 0, -1);
    showMem("shm copy", shc);
    c.gst_memory_unref(shc);
    c.gst_memory_unref(shmcopy);

    out("udmabuf get {d}", .{@intFromBool(c.gst_udmabuf_allocator_get() != null)});
    out("udmabuf get {d}", .{@intFromBool(c.gst_udmabuf_allocator_get() != null)});
    const ua: ?*c.GstAllocator = @ptrCast(@alignCast(c.g_object_new(c.gst_udmabuf_allocator_get_type(), @as([*c]const u8, null))));
    out("udmabuf obj type={s} flags={d}", .{ z(ua.?.mem_type), ua.?.object.flags });
    out("udmabuf alloc {d}", .{@intFromBool(c.gst_allocator_alloc(ua, 100, null) != null)});
    c.gst_object_unref(ua);

    out("drm path {d}", .{@intFromBool(c.gst_drm_dumb_allocator_new_with_device_path("/dev/dri/card0") != null)});
    out("drm path nul {d}", .{@intFromBool(c.gst_drm_dumb_allocator_new_with_device_path("/dev/null") != null)});
    out("drm fd {d}", .{@intFromBool(c.gst_drm_dumb_allocator_new_with_fd(0) != null)});
    out("drm fd -1 {d}", .{@intFromBool(c.gst_drm_dumb_allocator_new_with_fd(-1) != null)});
    const dd: ?*c.GstAllocator = @ptrCast(@alignCast(c.g_object_new(c.gst_drm_dumb_allocator_get_type(), @as([*c]const u8, null))));
    var dfd: c_int = 0;
    var dpath: [*c]u8 = null;
    c.g_object_get(dd, "drm-fd", &dfd, "drm-device-path", &dpath, NONE);
    out("drm obj type={s} flags={d} fd={d} path={s} prime={d}", .{ z(dd.?.mem_type), dd.?.object.flags, dfd, z(dpath), c.gst_drm_dumb_allocator_has_prime_export(dd) });
    var pitch: u32 = 77;
    out("drm alloc {d} pitch={d}", .{ @intFromBool(c.gst_drm_dumb_allocator_alloc(dd, 0x32315559, 16, 16, &pitch) != null), pitch });
    const sm = c.gst_allocator_alloc(sa, 10, null);
    out("drm on shm {d} handle={d}", .{ c.gst_is_drm_dumb_memory(sm), c.gst_drm_dumb_memory_get_handle(sm) });
    var bogus = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&bogus, c.G_TYPE_INT);
    const ps = c.g_param_spec_int("bogus", "b", "b", 0, 1, 0, c.G_PARAM_READWRITE);
    const k: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_peek(c.gst_drm_dumb_allocator_get_type())));
    k.get_property.?(@ptrCast(@alignCast(dd)), 9, &bogus, ps);
    k.set_property.?(@ptrCast(@alignCast(dd)), 9, &bogus, ps);
    c.gst_object_unref(dd);

    out("checks", .{});
    _ = c.gst_fd_allocator_alloc_full(null, 1, 10, 0, 10, 0);
    _ = c.gst_fd_allocator_alloc_full(fa, 1, 10, 5, 10, 0);
    _ = c.gst_is_fd_memory(null);
    _ = c.gst_fd_memory_get_fd(null);
    _ = c.gst_fd_memory_get_fd(sm);
    _ = c.gst_dmabuf_allocator_alloc(fa, 1, 10);
    _ = c.gst_dmabuf_allocator_alloc_with_flags(sa, 1, 10, 0);
    _ = c.gst_dmabuf_memory_get_fd(sm);
    _ = c.gst_is_dmabuf_memory(null);
    out("{d}", .{c.gst_is_phys_memory(null)});
    _ = c.gst_phys_memory_get_phys_addr(sm);
    c.gst_memory_unref(sm);
    c.gst_object_unref(da);
    c.gst_object_unref(fa);
}
