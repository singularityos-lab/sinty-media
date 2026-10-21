const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Site = c.GstVideoChromaSite;

const sites = [_]struct { [*:0]const u8, Site }{
    .{ "jpeg", c.GST_VIDEO_CHROMA_SITE_JPEG },
    .{ "mpeg2", c.GST_VIDEO_CHROMA_SITE_MPEG2 },
    .{ "dv", c.GST_VIDEO_CHROMA_SITE_DV },
    .{ "alt-line", c.GST_VIDEO_CHROMA_SITE_ALT_LINE },
    .{ "cosited", c.GST_VIDEO_CHROMA_SITE_COSITED },
};

fn senseless(site: Site) bool {
    return site & c.GST_VIDEO_CHROMA_SITE_NONE != 0 and site != c.GST_VIDEO_CHROMA_SITE_NONE;
}

pub export fn gst_video_chroma_site_from_string(s: [*c]const u8) Site {
    for (sites) |e| if (c.strcmp(e[0], s) == 0) return e[1];
    const klass: *c.GFlagsClass = @ptrCast(@alignCast(c.g_type_class_ref(c.gst_video_chroma_site_get_type())));
    const split = c.g_strsplit(s, "+", 0);
    var ret: Site = c.GST_VIDEO_CHROMA_SITE_UNKNOWN;
    var it = split;
    while (it[0] != null) : (it += 1) {
        const v = c.g_flags_get_value_by_nick(klass, it[0]);
        if (v == null) {
            ret = c.GST_VIDEO_CHROMA_SITE_UNKNOWN;
            break;
        }
        ret |= v[0].value;
    }
    c.g_type_class_unref(klass);
    c.g_strfreev(split);
    if (senseless(ret)) return c.GST_VIDEO_CHROMA_SITE_UNKNOWN;
    return ret;
}

pub export fn gst_video_chroma_from_string(s: [*c]const u8) Site {
    return gst_video_chroma_site_from_string(s);
}

pub export fn gst_video_chroma_to_string(site: Site) [*c]const u8 {
    for (sites) |e| if (e[1] == site) return e[0];
    return null;
}

pub export fn gst_video_chroma_site_to_string(site_in: Site) [*c]u8 {
    var site = site_in;
    if (site == 0) return null;
    for (sites) |e| if (e[1] == site) return c.g_strdup(e[0]);
    if (senseless(site)) return null;
    const klass: *c.GFlagsClass = @ptrCast(@alignCast(c.g_type_class_ref(c.gst_video_chroma_site_get_type())));
    const str = c.g_string_new(null);
    while (site != c.GST_VIDEO_CHROMA_SITE_UNKNOWN) {
        const v = c.g_flags_get_first_value(klass, site);
        if (v == null) break;
        if (str[0].len > 0) _ = c.g_string_append(str, "+");
        _ = c.g_string_append(str, v[0].value_nick);
        site &= ~v[0].value;
    }
    c.g_type_class_unref(klass);
    if (site != 0) return c.g_string_free(str, 1);
    return c.g_string_free(str, 0);
}

const Opaque = c.GstVideoChromaResample;

const H = *const fn (*Resample, c.gpointer, c.gint) void;
const V = *const fn (*Resample, [*c]c.gpointer, c.gint) void;

const Resample = struct {
    method: c.GstVideoChromaMethod,
    site: Site,
    flags: c.GstVideoChromaFlags,
    format: c.GstVideoFormat,
    h_factor: c.gint,
    v_factor: c.gint,
    n_lines: c.guint,
    offset: c.gint,
    h: ?H,
    v: V,
};

fn f11(a: u32, b: u32) u32 {
    return (a + b + 1) >> 1;
}

fn f31(a: u32, b: u32) u32 {
    return (3 * a + b + 2) >> 2;
}

fn f13(a: u32, b: u32) u32 {
    return (a + 3 * b + 2) >> 2;
}

fn f121(a: u32, b: u32, d: u32) u32 {
    return (a + 2 * b + d + 2) >> 2;
}

fn f71(a: u32, b: u32) u32 {
    return (7 * a + b + 4) >> 3;
}

fn f17(a: u32, b: u32) u32 {
    return (a + 7 * b + 4) >> 3;
}

fn f53(a: u32, b: u32) u32 {
    return (5 * a + 3 * b + 4) >> 3;
}

fn f35(a: u32, b: u32) u32 {
    return (3 * a + 5 * b + 4) >> 3;
}

fn f1331(a: u32, b: u32, d: u32, e: u32) u32 {
    return (a + 3 * (b + d) + e + 4) >> 3;
}

fn f10321(a: u32, b: u32, d: u32, e: u32) u32 {
    return (10 * a + 3 * b + 2 * d + e + 8) >> 4;
}

fn f12310(a: u32, b: u32, d: u32, e: u32) u32 {
    return (a + 2 * b + 3 * d + 10 * e + 8) >> 4;
}

fn f1234321(v: [7]u32) u32 {
    return (v[0] + 2 * (v[1] + v[5]) + 3 * (v[2] + v[4]) + 4 * v[3] + v[6] + 8) >> 4;
}

fn kernels(comptime T: type) type {
    return struct {
        fn px(p: c.gpointer) [*]T {
            return @ptrCast(@alignCast(p));
        }

        fn get(p: [*]T, i: c.gint, k: usize) u32 {
            return p[@as(usize, @intCast(i)) * 4 + k];
        }

        fn set(p: [*]T, i: c.gint, k: usize, v: u32) void {
            p[@as(usize, @intCast(i)) * 4 + k] = @truncate(v);
        }

        fn upH2(_: *Resample, pixels: c.gpointer, width: c.gint) void {
            const p = px(pixels);
            var r1 = get(p, 0, 2);
            var b1 = get(p, 0, 3);
            var i: c.gint = 1;
            while (i < width - 1) : (i += 2) {
                const r0 = r1;
                const b0 = b1;
                r1 = get(p, i + 1, 2);
                b1 = get(p, i + 1, 3);
                set(p, i, 2, f31(r0, r1));
                set(p, i, 3, f31(b0, b1));
                set(p, i + 1, 2, f13(r0, r1));
                set(p, i + 1, 3, f13(b0, b1));
            }
        }

        fn downH2(_: *Resample, pixels: c.gpointer, width: c.gint) void {
            const p = px(pixels);
            var i: c.gint = 0;
            while (i < width - 1) : (i += 2) {
                for (2..4) |k| set(p, i, k, f11(get(p, i, k), get(p, i + 1, k)));
            }
        }

        fn upH2Cs(_: *Resample, pixels: c.gpointer, width: c.gint) void {
            const p = px(pixels);
            var i: c.gint = 1;
            while (i < width - 1) : (i += 2) {
                for (2..4) |k| set(p, i, k, f11(get(p, i - 1, k), get(p, i + 1, k)));
            }
        }

        fn downH2Cs(_: *Resample, pixels: c.gpointer, width: c.gint) void {
            const p = px(pixels);
            if (width < 2) return;
            for (2..4) |k| set(p, 0, k, f31(get(p, 0, k), get(p, 1, k)));
            var i: c.gint = 2;
            while (i < width - 2) : (i += 2) {
                for (2..4) |k| set(p, i, k, f121(get(p, i - 1, k), get(p, i, k), get(p, i + 1, k)));
            }
            if (i < width) {
                for (2..4) |k| set(p, i, k, f13(get(p, i - 1, k), get(p, i, k)));
            }
        }

        fn upH4(_: *Resample, pixels: c.gpointer, width: c.gint) void {
            const p = px(pixels);
            var r1 = get(p, 0, 2);
            var b1 = get(p, 0, 3);
            var i: c.gint = 2;
            while (i < width - 3) : (i += 4) {
                const r0 = r1;
                const b0 = b1;
                r1 = get(p, i + 2, 2);
                b1 = get(p, i + 2, 3);
                set(p, i, 2, f71(r0, r1));
                set(p, i, 3, f71(b0, b1));
                set(p, i + 1, 2, f53(r0, r1));
                set(p, i + 1, 3, f53(b0, b1));
                set(p, i + 2, 2, f35(r0, r1));
                set(p, i + 2, 3, f35(b0, b1));
                set(p, i + 3, 2, f17(r0, r1));
                set(p, i + 3, 3, f17(b0, b1));
            }
        }

        fn downH4(_: *Resample, pixels: c.gpointer, width: c.gint) void {
            const p = px(pixels);
            var i: c.gint = 0;
            while (i < width - 4) : (i += 4) {
                for (2..4) |k| set(p, i, k, f1331(get(p, i, k), get(p, i + 1, k), get(p, i + 2, k), get(p, i + 3, k)));
            }
        }

        fn upH4Cs(_: *Resample, pixels: c.gpointer, width: c.gint) void {
            const p = px(pixels);
            var i: c.gint = 0;
            while (i < width - 4) : (i += 4) {
                for (2..4) |k| {
                    const a = get(p, i, k);
                    const b = get(p, i + 4, k);
                    set(p, i + 1, k, f31(a, b));
                    set(p, i + 2, k, f11(a, b));
                    set(p, i + 3, k, f13(a, b));
                }
            }
        }

        fn downH4Cs(_: *Resample, pixels: c.gpointer, width: c.gint) void {
            const p = px(pixels);
            if (width < 4) return;
            for (2..4) |k| set(p, 0, k, f10321(get(p, 0, k), get(p, 1, k), get(p, 2, k), get(p, 3, k)));
            var i: c.gint = 4;
            while (i < width - 4) : (i += 4) {
                for (2..4) |k| {
                    var v: [7]u32 = undefined;
                    for (0..7) |j| v[j] = get(p, i - 3 + @as(c.gint, @intCast(j)), k);
                    set(p, i, k, f1234321(v));
                }
            }
            if (i < width) {
                for (2..4) |k| set(p, i, k, f12310(get(p, i - 3, k), get(p, i - 2, k), get(p, i - 1, k), get(p, i, k)));
            }
        }

        fn upV2(r: *Resample, lines: [*c]c.gpointer, width: c.gint) void {
            if (r.h) |h| {
                h(r, lines[0], width);
                if (lines[0] != lines[1]) h(r, lines[1], width);
            }
            if (lines[0] == lines[1]) return;
            const l0 = px(lines[0]);
            const l1 = px(lines[1]);
            var i: c.gint = 0;
            while (i < width) : (i += 1) {
                for (2..4) |k| {
                    const a = get(l0, i, k);
                    const b = get(l1, i, k);
                    set(l0, i, k, f31(a, b));
                    set(l1, i, k, f13(a, b));
                }
            }
        }

        fn downV2(r: *Resample, lines: [*c]c.gpointer, width: c.gint) void {
            if (lines[0] != lines[1]) {
                const l0 = px(lines[0]);
                const l1 = px(lines[1]);
                var i: c.gint = 0;
                while (i < width) : (i += 1) {
                    for (2..4) |k| set(l0, i, k, f11(get(l0, i, k), get(l1, i, k)));
                }
            }
            if (r.h) |h| h(r, lines[0], width);
        }

        fn hPairs(r: *Resample, lines: [*c]c.gpointer, width: c.gint) void {
            const h = r.h orelse return;
            if (lines[0] != lines[1]) {
                h(r, lines[0], width);
                h(r, lines[1], width);
            }
            if (lines[2] != lines[3]) {
                h(r, lines[2], width);
                h(r, lines[3], width);
            }
        }

        fn upVi2(r: *Resample, lines: [*c]c.gpointer, width: c.gint) void {
            hPairs(r, lines, width);
            if (lines[0] == lines[1] or lines[2] == lines[3]) return;
            const l0 = px(lines[0]);
            const l1 = px(lines[1]);
            const l2 = px(lines[2]);
            const l3 = px(lines[3]);
            var i: c.gint = 0;
            while (i < width) : (i += 1) {
                for (2..4) |k| {
                    const t0 = get(l0, i, k);
                    const t1 = get(l1, i, k);
                    const t2 = get(l2, i, k);
                    const t3 = get(l3, i, k);
                    set(l0, i, k, f53(t0, t2));
                    set(l1, i, k, f71(t1, t3));
                    set(l2, i, k, f17(t0, t2));
                    set(l3, i, k, f35(t1, t3));
                }
            }
        }

        fn upV4(r: *Resample, lines: [*c]c.gpointer, width: c.gint) void {
            hPairs(r, lines, width);
            if (lines[0] == lines[1] or lines[2] == lines[3]) return;
            const l0 = px(lines[0]);
            const l1 = px(lines[1]);
            const l2 = px(lines[2]);
            const l3 = px(lines[3]);
            var i: c.gint = 0;
            while (i < width) : (i += 1) {
                for (2..4) |k| {
                    const a = get(l0, i, k);
                    const b = get(l2, i, k);
                    set(l0, i, k, f71(a, b));
                    set(l1, i, k, f53(a, b));
                    set(l2, i, k, f35(a, b));
                    set(l3, i, k, f17(a, b));
                }
            }
        }

        fn downV4(r: *Resample, lines: [*c]c.gpointer, width: c.gint) void {
            const l0 = px(lines[0]);
            const l1 = px(lines[1]);
            const l2 = px(lines[2]);
            const l3 = px(lines[3]);
            var i: c.gint = 0;
            while (i < width) : (i += 1) {
                for (2..4) |k| set(l0, i, k, f1331(get(l0, i, k), get(l1, i, k), get(l2, i, k), get(l3, i, k)));
            }
            if (r.h) |h| h(r, lines[0], width);
        }
    };
}

fn onlyH(r: *Resample, lines: [*c]c.gpointer, width: c.gint) void {
    if (r.h) |h| h(r, lines[0], width);
}

const K8 = kernels(u8);
const K16 = kernels(u16);

const h_table = [_]?H{
    null,
    K8.upH2,   K8.downH2,   K16.upH2,   K16.downH2,
    K8.upH2Cs, K8.downH2Cs, K16.upH2Cs, K16.downH2Cs,
    K8.upH4,   K8.downH4,   K16.upH4,   K16.downH4,
    K8.upH4Cs, K8.downH4Cs, K16.upH4Cs, K16.downH4Cs,
};

const VE = struct { f: V, n: c.guint, off: c.gint };

fn ve(f: V, n: c.guint, off: c.gint) VE {
    return .{ .f = f, .n = n, .off = off };
}

const v_table = [_]VE{
    ve(onlyH, 1, 0),
    ve(K8.upV2, 2, -1),   ve(K8.downV2, 2, 0),  ve(K16.upV2, 2, -1), ve(K16.downV2, 2, 0),
    ve(onlyH, 1, 0),      ve(onlyH, 1, 0),      ve(onlyH, 1, 0),     ve(onlyH, 1, 0),
    ve(K8.upV4, 4, -2),   ve(K8.downV4, 4, 0),  ve(K16.upV4, 4, -2), ve(K16.downV4, 4, 0),
    ve(onlyH, 1, 0),      ve(onlyH, 1, 0),      ve(onlyH, 1, 0),     ve(onlyH, 1, 0),
    ve(K8.upVi2, 4, -2),  ve(onlyH, 1, 0),      ve(K16.upVi2, 4, -2), ve(onlyH, 1, 0),
    ve(onlyH, 1, 0),      ve(onlyH, 1, 0),      ve(onlyH, 1, 0),     ve(onlyH, 1, 0),
    ve(onlyH, 1, 0),      ve(onlyH, 1, 0),      ve(onlyH, 1, 0),     ve(onlyH, 1, 0),
    ve(onlyH, 1, 0),      ve(onlyH, 1, 0),      ve(onlyH, 1, 0),     ve(onlyH, 1, 0),
};

fn index(factor: c.gint, cosite: bool, bits: c.guint) usize {
    if (factor == 0) return 0;
    const a: usize = @abs(factor);
    return (a - 1) * 8 + @as(usize, if (cosite) 4 else 0) + @as(usize, if (bits == 16) 2 else 0) + @as(usize, if (factor < 0) 1 else 0) + 1;
}

pub export fn gst_video_chroma_resample_new(method: c.GstVideoChromaMethod, site: Site, flags: c.GstVideoChromaFlags, format: c.GstVideoFormat, h_factor: c.gint, v_factor: c.gint) ?*Opaque {
    if (h_factor == 0 and v_factor == 0) return null;
    const bits: c.guint = switch (format) {
        c.GST_VIDEO_FORMAT_AYUV => 8,
        c.GST_VIDEO_FORMAT_AYUV64 => 16,
        else => return null,
    };
    const hi = index(h_factor, site & c.GST_VIDEO_CHROMA_SITE_H_COSITED != 0, bits);
    var vi = index(v_factor, site & c.GST_VIDEO_CHROMA_SITE_V_COSITED != 0, bits);
    if (flags & c.GST_VIDEO_CHROMA_FLAG_INTERLACED != 0) vi += 16;
    const r: *Resample = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Resample))));
    r.* = .{ .method = method, .site = site, .flags = flags, .format = format, .h_factor = h_factor, .v_factor = v_factor, .n_lines = v_table[vi].n, .offset = v_table[vi].off, .h = h_table[hi], .v = v_table[vi].f };
    return @ptrCast(r);
}

pub export fn gst_video_chroma_resample_get_info(resample: ?*Opaque, n_lines: ?*c.guint, offset: ?*c.gint) void {
    const r: *Resample = @ptrCast(@alignCast(resample orelse return check.fail("gst_video_chroma_resample_get_info", "resample != NULL")));
    if (n_lines) |p| p.* = r.n_lines;
    if (offset) |p| p.* = r.offset;
}

pub export fn gst_video_chroma_resample_free(resample: ?*Opaque) void {
    const r = resample orelse return check.fail("gst_video_chroma_resample_free", "resample != NULL");
    c.g_free(r);
}

pub export fn gst_video_chroma_resample(resample: ?*Opaque, lines: [*c]c.gpointer, width: c.gint) void {
    const r: *Resample = @ptrCast(@alignCast(resample orelse return check.fail("gst_video_chroma_resample", "resample != NULL")));
    r.v(r, lines, width);
}

comptime {
    std.debug.assert(h_table.len == 17 and v_table.len == 33);
}
