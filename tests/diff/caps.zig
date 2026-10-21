const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn app(buf: []u8, len: *usize, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(buf[len.*..], fmt, args) catch return;
    len.* += s.len;
}

fn str(p: [*c]u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

fn mini(p: anytype) [*c]c.GstMiniObject {
    return @ptrCast(@alignCast(p));
}

fn unref(p: anytype) void {
    if (p != null) c.gst_mini_object_unref(mini(p));
}

const caps_strings = [_][*:0]const u8{
    "video/x-raw, format=(string)I420, width=(int)640, height=(int)480, framerate=(fraction)30/1",
    "video/x-raw, format={ I420, NV12, YUY2 }, width=[ 1, 4096 ], height=[ 1, 2160 ], framerate=[ 0/1, 2147483647/1 ]",
    "video/x-raw(memory:DMABuf), format=(string)DMA_DRM, drm-format=(string)NV12:0x0100000000000002",
    "audio/x-raw, format=(string)S16LE, layout=(string)interleaved, rate=(int)44100, channels=(int)2, channel-mask=(bitmask)0x0000000000000003",
    "audio/x-raw, rate=[ 8000, 192000 ], channels=[ 1, 8 ]; audio/x-raw, rate=(int)48000, channels=(int)6",
    "image/jpeg, width=(int)1920, height=(int)1080, framerate={ (fraction)30/1, (fraction)15/1, (fraction)5/1 }",
    "ANY",
    "EMPTY",
    "NONE",
    "application/x-rtp, media=(string)video, clock-rate=(int)90000, encoding-name=(string)H264, payload=(int)96",
    "video/x-h264, stream-format=(string)avc, alignment=(string)au, codec_data=(buffer)01640028ffe1001c6764",
    "text/x-raw, format=(string)utf8, name=(string)\"hello world\", flag=(boolean)true, ratio=(double)1.5",
    "video/x-raw, width=(int)[ 2, 64, 2 ], pixel-aspect-ratio=(fraction)1/1, interlace-mode=(string)progressive",
    "test/x, s=(structure)\"sub, a=(int)1;\", l=(int)< 1, 2, 3 >, u=(uint)42, i64=(gint64)-5, u64=(guint64)99",
    "video/x-raw(ANY)",
    "audio/mpeg, mpegversion=(int)4, stream-format=(string){ raw, adts }",
};

fn caps(s: [*:0]const u8) [*c]c.GstCaps {
    return c.gst_caps_from_string(s);
}

pub fn main() void {
    c.gst_init(null, null);
    var all: [caps_strings.len][*c]c.GstCaps = undefined;
    for (caps_strings, 0..) |s, i| {
        const cp = caps(s);
        all[i] = cp;
        if (cp == null) {
            out("parse {d}: null", .{i});
            continue;
        }
        const t = c.gst_caps_to_string(cp);
        const ser = c.gst_caps_serialize(cp, c.GST_SERIALIZE_FLAG_NONE);
        out("parse {d}: size {d} any {d} empty {d} fixed {d}", .{ i, c.gst_caps_get_size(cp), c.gst_caps_is_any(cp), c.gst_caps_is_empty(cp), c.gst_caps_is_fixed(cp) });
        out("  str {s}", .{str(t)});
        out("  ser {s}", .{str(ser)});
        const back = c.gst_caps_from_string(t);
        out("  roundtrip equal {d} strict {d}", .{ c.gst_caps_is_equal(cp, back), c.gst_caps_is_strictly_equal(cp, back) });
        unref(back);
        c.g_free(t);
        c.g_free(ser);
    }
    for (all, 0..) |a, i| {
        if (a == null) continue;
        for (all, 0..) |b, j| {
            if (b == null) continue;
            const inter = c.gst_caps_intersect(a, b);
            const first = c.gst_caps_intersect_full(a, b, c.GST_CAPS_INTERSECT_FIRST);
            const it = c.gst_caps_to_string(inter);
            const ft = c.gst_caps_to_string(first);
            out("{d}x{d} can {d} subset {d} equal {d} inter {s} first {s}", .{ i, j, c.gst_caps_can_intersect(a, b), c.gst_caps_is_subset(a, b), c.gst_caps_is_equal(a, b), str(it), str(ft) });
            c.g_free(it);
            c.g_free(ft);
            unref(inter);
            unref(first);
            if (c.gst_caps_is_any(a) == 0 and i != 12 and j != 12) {
                const sub = c.gst_caps_subtract(a, b);
                const st = c.gst_caps_to_string(sub);
                out("  sub {s}", .{str(st)});
                c.g_free(st);
                unref(sub);
            }
        }
    }
    for (all, 0..) |a, i| {
        if (a == null) continue;
        if (c.gst_caps_is_any(a) != 0) continue;
        const n = c.gst_caps_normalize(c.gst_caps_copy(a));
        const ns = c.gst_caps_to_string(n);
        const s = c.gst_caps_simplify(c.gst_caps_copy(n));
        const ss = c.gst_caps_to_string(s);
        const f = c.gst_caps_fixate(c.gst_caps_copy(a));
        const fs = c.gst_caps_to_string(f);
        out("{d} normalize {s}", .{ i, str(ns) });
        out("{d} simplify {s}", .{ i, str(ss) });
        out("{d} fixate {s}", .{ i, str(fs) });
        c.g_free(ns);
        c.g_free(ss);
        c.g_free(fs);
        unref(n);
        unref(s);
        unref(f);
    }
    const merged = c.gst_caps_merge(c.gst_caps_copy(all[0]), c.gst_caps_copy(all[1]));
    const ms = c.gst_caps_to_string(merged);
    out("merge {s}", .{str(ms)});
    c.g_free(ms);
    unref(merged);

    const sc = c.gst_caps_new_simple("video/x-raw", "format", c.G_TYPE_STRING, "RGBA", "width", c.G_TYPE_INT, @as(c_int, 320), "height", c.G_TYPE_INT, @as(c_int, 240), "framerate", c.gst_fraction_get_type(), @as(c_int, 25), @as(c_int, 1), "ratio", c.G_TYPE_DOUBLE, @as(f64, 0.5), "flag", c.G_TYPE_BOOLEAN, @as(c_int, 1), "big", c.G_TYPE_UINT64, @as(u64, 1 << 40), "range", c.gst_int_range_get_type(), @as(c_int, 1), @as(c_int, 10), @as(?*anyopaque, null));
    const scs = c.gst_caps_to_string(sc);
    out("simple {s}", .{str(scs)});
    c.g_free(scs);
    c.gst_caps_set_simple(sc, "width", c.G_TYPE_INT, @as(c_int, 640), "extra", c.G_TYPE_STRING, "x y", @as(?*anyopaque, null));
    const st = c.gst_caps_get_structure(sc, 0);
    var w: c_int = 0;
    var h: c_int = 0;
    var fn_: c_int = 0;
    var fd: c_int = 0;
    var fmt: [*c]u8 = null;
    var d: f64 = 0;
    out("get {d}", .{c.gst_structure_get(st, "width", c.G_TYPE_INT, &w, "height", c.G_TYPE_INT, &h, "format", c.G_TYPE_STRING, &fmt, "framerate", c.gst_fraction_get_type(), &fn_, &fd, "ratio", c.G_TYPE_DOUBLE, &d, @as(?*anyopaque, null))});
    out("got {d} {d} {s} {d}/{d} {d}", .{ w, h, str(fmt), fn_, fd, d });
    c.g_free(fmt);
    out("get wrong type {d}", .{c.gst_structure_get(st, "width", c.G_TYPE_STRING, &fmt, @as(?*anyopaque, null))});
    var u: u64 = 0;
    out("get uint64 {d} {d}", .{ c.gst_structure_get_uint64(st, "big", &u), u });
    out("has {d} {d} typed {d}", .{ c.gst_structure_has_field(st, "ratio"), c.gst_structure_has_field(st, "nope"), c.gst_structure_has_field_typed(st, "flag", c.G_TYPE_BOOLEAN) });
    c.gst_structure_remove_fields(st, "ratio", "flag", @as(?*anyopaque, null));
    const sts = c.gst_structure_to_string(st);
    out("after remove {s} n {d}", .{ str(sts), c.gst_structure_n_fields(st) });
    c.g_free(sts);
    unref(sc);

    const vstrings = [_][*:0]const u8{
        "(int)42",      "(int)max",          "(uint)0xff",     "(int)[ 1, 5 ]",           "(double)3.25",
        "(fraction)30000/1001", "{ 1, 2, 3 }",   "< 4, 5 >",        "(string)\"a b\\\"c\"",     "(boolean)yes",
        "(float)1.5",   "(gint64)[ 0, 100, 10 ]", "(fraction)[ 1/2, 3/1 ]", "(double)[ 0.5, 2.5 ]", "(bitmask)0xff00",
        "(flagset)3:7", "(string)NULL",      "plain",           "1/4",                     "true",
        "(uchar)200",   "(int)99999999999",  "(fraction)min",   "(uniquelist){ 1, 2 }",
    };
    var vals: [vstrings.len]c.GValue = undefined;
    for (vstrings, 0..) |vs, i| {
        const st2 = c.gst_structure_from_string(c.g_strdup_printf("t, v=%s", vs), null);
        vals[i] = std.mem.zeroes(c.GValue);
        if (st2 == null) {
            out("value {d}: parse failed", .{i});
            continue;
        }
        const v = c.gst_structure_get_value(st2, "v");
        c.gst_value_init_and_copy(&vals[i], v);
        const ser = c.gst_value_serialize(v);
        var hash: c.guint = 0;
        const null_string = v.*.g_type == c.G_TYPE_STRING and c.g_value_get_string(v) == null;
        const hok = if (null_string) 0 else c.gst_value_hash(v, &hash);
        out("value {d}: type {s} ser {s} fixed {d} hash {d}", .{ i, std.mem.span(c.g_type_name(v.*.g_type)), str(ser), c.gst_value_is_fixed(v), hok });
        c.g_free(ser);
        c.gst_structure_free(st2);
    }
    for (&vals, 0..) |*a, i| {
        if (a.g_type == 0) continue;
        for (&vals, 0..) |*b, j| {
            if (b.g_type == 0) continue;
            var r = std.mem.zeroes(c.GValue);
            const cmp = c.gst_value_compare(a, b);
            var line: [2048]u8 = undefined;
            var len: usize = 0;
            app(&line, &len, "v{d}v{d} cmp {d}", .{ i, j, cmp });
            if (c.gst_value_can_intersect(a, b) != 0) {
                if (c.gst_value_intersect(&r, a, b) != 0) {
                    const s = c.gst_value_serialize(&r);
                    app(&line, &len, " inter {s}", .{str(s)});
                    c.g_free(s);
                    c.g_value_unset(&r);
                } else app(&line, &len, " inter none", .{});
            }
            if (c.gst_value_union(&r, a, b) != 0) {
                const s = c.gst_value_serialize(&r);
                app(&line, &len, " union {s}", .{str(s)});
                c.g_free(s);
                c.g_value_unset(&r);
            }
            if (c.gst_value_can_subtract(a, b) != 0) {
                if (c.gst_value_subtract(&r, a, b) != 0) {
                    const s = c.gst_value_serialize(&r);
                    app(&line, &len, " sub {s}", .{str(s)});
                    c.g_free(s);
                    c.g_value_unset(&r);
                } else app(&line, &len, " sub none", .{});
            }
            app(&line, &len, " subset {d}", .{c.gst_value_is_subset(a, b)});
            out("{s}", .{line[0..len]});
        }
        var fx = std.mem.zeroes(c.GValue);
        if (c.gst_value_fixate(&fx, a) != 0) {
            const s = c.gst_value_serialize(&fx);
            out("v{d} fixate {s}", .{ i, str(s) });
            c.g_free(s);
            c.g_value_unset(&fx);
        }
    }
    var n: c_int = 0;
    var dd: c_int = 0;
    for ([_]f64{ 29.97002997, 0.5, 1.0 / 3.0, 25.0, 59.94, 0.0, -1.25, 1e-12, 2147483647.0 }) |x| {
        c.gst_util_double_to_fraction(x, &n, &dd);
        out("d2f {d} {d}", .{ n, dd });
    }
    out("scale {d} {d} {d} {d}", .{ c.gst_util_uint64_scale(1 << 62, 3, 7), c.gst_util_uint64_scale_ceil(10, 1, 3), c.gst_util_uint64_scale_int(123456789, 1001, 30000), c.gst_util_uint64_scale_int_round(5, 1, 2) });
    var an: c_int = 0;
    var ad: c_int = 0;
    out("fadd {d} {d} {d}", .{ c.gst_util_fraction_add(1, 3, 1, 6, &an, &ad), an, ad });
    out("fmul {d} {d} {d}", .{ c.gst_util_fraction_multiply(2, 3, 9, 4, &an, &ad), an, ad });
    out("fcmp {d} {d}", .{ c.gst_util_fraction_compare(1, 3, 2, 6), c.gst_util_fraction_compare(1, 3, 1, 2) });

    const f1 = c.gst_caps_features_from_string("memory:DMABuf, meta:GstVideoOverlayComposition");
    const f2 = c.gst_caps_features_new("memory:DMABuf", @as(?*anyopaque, null));
    const fs = c.gst_caps_features_to_string(f1);
    out("features {s} size {d} contains {d} equal {d} any {d}", .{ str(fs), c.gst_caps_features_get_size(f1), c.gst_caps_features_contains(f1, "memory:DMABuf"), c.gst_caps_features_is_equal(f1, f2), c.gst_caps_features_is_any(f1) });
    c.g_free(fs);
    c.gst_caps_features_free(f1);
    c.gst_caps_features_free(f2);
    for (all) |a| unref(a);
}
