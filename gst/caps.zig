const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const mini = @import("mini.zig");
const va = @import("varargs.zig");
const value = @import("value.zig");
const vbasic = @import("vbasic.zig");
const structure = @import("structure.zig");
const features_mod = @import("capsfeatures.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Caps = c.GstCaps;
const Structure = c.GstStructure;
const Features = c.GstCapsFeatures;
const Value = c.GValue;
const Mini = c.GstMiniObject;

const Entry = extern struct {
    s: ?*Structure,
    f: ?*Features,
};

const Impl = extern struct {
    caps: Caps,
    entries: [*c]Entry,
    len: c.guint,
    cap: c.guint,
};

pub export var _gst_caps_type: c.GType = 0;
pub export var _gst_caps_any: ?*Caps = null;
pub export var _gst_caps_none: ?*Caps = null;

var type_once: gtype.Once = .{};
var static_lock: c.GMutex = std.mem.zeroes(c.GMutex);

fn impl(p: anytype) *Impl {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn asMini(p: anytype) [*c]Mini {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn entries(p: anytype) []Entry {
    const i = impl(p);
    if (i.len == 0) return &.{};
    return i.entries[0..i.len];
}

fn featuresAt(p: anytype, idx: usize) ?*Features {
    return @atomicLoad(?*Features, &impl(p).entries[idx].f, .acquire);
}

fn refcount(p: anytype) *c.gint {
    return &asMini(p).*.refcount;
}

fn isCaps(p: anytype) bool {
    return p != null and asMini(p).*.type == _gst_caps_type;
}

fn writable(p: anytype) bool {
    return @atomicLoad(c.gint, refcount(p), .monotonic) == 1;
}

fn isAny(p: anytype) bool {
    return asMini(p).*.flags & c.GST_CAPS_FLAG_ANY != 0;
}

fn isEmptySimple(p: anytype) bool {
    return impl(p).len == 0;
}

fn isEmpty(p: anytype) bool {
    return !isAny(p) and isEmptySimple(p);
}

fn sysmem() ?*Features {
    return features_mod._gst_caps_features_memory_system_memory;
}

fn orSysmem(f: ?*Features) ?*Features {
    return f orelse sysmem();
}

fn copyUnlessSysmem(f: ?*Features) ?*Features {
    const x = f orelse return null;
    if (c.gst_caps_features_is_any(x) != 0 or c.gst_caps_features_is_equal(x, sysmem()) == 0) return c.gst_caps_features_copy(x);
    return null;
}

fn appendRaw(p: [*c]Caps, s: ?*Structure, f: ?*Features) void {
    const rc = refcount(p);
    if (c.gst_structure_set_parent_refcount(s, rc) == 0) return;
    if (f != null and c.gst_caps_features_set_parent_refcount(f, rc) == 0) return;
    const i = impl(p);
    if (i.len == i.cap) {
        i.cap = @max(4, i.cap * 2);
        i.entries = @ptrCast(@alignCast(c.g_realloc(i.entries, @as(usize, i.cap) * @sizeOf(Entry))));
    }
    i.entries[i.len] = .{ .s = s, .f = f };
    i.len += 1;
}

fn takeOut(p: [*c]Caps, idx: usize, s: *?*Structure, f: *?*Features) void {
    const i = impl(p);
    s.* = i.entries[idx].s;
    f.* = featuresAt(p, idx);
    std.mem.copyForwards(Entry, i.entries[idx .. i.len - 1], i.entries[idx + 1 .. i.len]);
    i.len -= 1;
    _ = c.gst_structure_set_parent_refcount(s.*, null);
    if (f.* != null) _ = c.gst_caps_features_set_parent_refcount(f.*, null);
}

fn takeStructure(p: [*c]Caps, idx: usize) ?*Structure {
    var s: ?*Structure = null;
    var f: ?*Features = null;
    takeOut(p, idx, &s, &f);
    if (f != null) c.gst_caps_features_free(f);
    return s;
}

fn copyCaps(src: [*c]const Mini) callconv(.c) [*c]Mini {
    if (!check.that(isCaps(src), "_gst_caps_copy", "GST_IS_CAPS (caps)")) return null;
    const out = gst_caps_new_empty();
    asMini(out).*.flags = asMini(src).*.flags;
    for (entries(src), 0..) |e, idx| gst_caps_append_structure_full(out, c.gst_structure_copy(e.s), copyUnlessSysmem(featuresAt(src, idx)));
    return asMini(out);
}

fn freeCaps(m: [*c]Mini) callconv(.c) void {
    for (entries(m), 0..) |e, idx| {
        _ = c.gst_structure_set_parent_refcount(e.s, null);
        c.gst_structure_free(e.s);
        if (featuresAt(m, idx)) |f| {
            _ = c.gst_caps_features_set_parent_refcount(f, null);
            c.gst_caps_features_free(f);
        }
    }
    c.g_free(impl(m).entries);
    c.g_free(m);
}

pub export fn gst_caps_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstCaps", @ptrCast(&mini.gst_mini_object_ref), @ptrCast(&mini.gst_mini_object_unref));
        }
    }.f);
}

pub export fn gst_caps_new_empty() [*c]Caps {
    const i: *Impl = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Impl))));
    i.entries = null;
    i.len = 0;
    i.cap = 0;
    mini.gst_mini_object_init(asMini(i), 0, _gst_caps_type, copyCaps, null, freeCaps);
    return @ptrCast(i);
}

pub export fn gst_caps_new_any() [*c]Caps {
    const p = gst_caps_new_empty();
    asMini(p).*.flags |= c.GST_CAPS_FLAG_ANY;
    return p;
}

fn warnMediaType(name: [*c]const u8, len: usize) void {
    const s = name[0..len];
    if (std.mem.eql(u8, s, "ANY")) c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "media_type should not be ANY. Please consider using `gst_caps_new_any` or `gst_caps_from_string`.");
    if (len == 0 or std.mem.eql(u8, s, "EMPTY") or std.mem.eql(u8, s, "NONE"))
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "media_type should not be `%s`. Please consider using `gst_caps_new_empty` or `gst_caps_from_string`.", name);
}

fn withStructure(s: ?*Structure) [*c]Caps {
    const p = gst_caps_new_empty();
    if (s != null) appendRaw(p, s, null);
    return p;
}

pub export fn gst_caps_new_empty_simple(media: [*c]const u8) [*c]Caps {
    const p = gst_caps_new_empty();
    warnMediaType(media, std.mem.len(media));
    const s = c.gst_structure_new_empty(media);
    if (s != null) appendRaw(p, s, null);
    return p;
}

pub export fn gst_caps_new_static_str_empty_simple(media: [*c]const u8) [*c]Caps {
    const p = gst_caps_new_empty();
    warnMediaType(media, std.mem.len(media));
    const s = c.gst_structure_new_static_str_empty(media);
    if (s != null) appendRaw(p, s, null);
    return p;
}

pub export fn gst_caps_new_id_str_empty_simple(media: [*c]const c.GstIdStr) [*c]Caps {
    const p = gst_caps_new_empty();
    warnMediaType(c.gst_id_str_as_str(media), c.gst_id_str_get_len(media));
    const s = c.gst_structure_new_id_str_empty(media);
    if (s != null) appendRaw(p, s, null);
    return p;
}

fn simpleResult(s: ?*Structure) [*c]Caps {
    const p = gst_caps_new_empty();
    if (s != null) {
        appendRaw(p, s, null);
        return p;
    }
    mini.gst_mini_object_unref(asMini(p));
    return null;
}

pub export fn gst_caps_new_simple(media: [*c]const u8, field: [*c]const u8, ...) callconv(.c) [*c]Caps {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return simpleResult(c.gst_structure_new_valist(media, field, va.toC(&ap)));
}

pub export fn gst_caps_new_static_str_simple(media: [*c]const u8, field: [*c]const u8, ...) callconv(.c) [*c]Caps {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return simpleResult(c.gst_structure_new_static_str_valist(media, field, va.toC(&ap)));
}

pub export fn gst_caps_new_id_str_simple(media: [*c]const c.GstIdStr, field: [*c]const c.GstIdStr, ...) callconv(.c) [*c]Caps {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return simpleResult(c.gst_structure_new_id_str_valist(media, field, va.toC(&ap)));
}

fn fullFrom(first: [*c]Structure, ap: *va.VaList) callconv(.c) [*c]Caps {
    const p = gst_caps_new_empty();
    var s = first;
    while (s != null) : (s = @cVaArg(ap, [*c]Structure)) appendRaw(p, s, null);
    return p;
}

pub export fn gst_caps_new_full(first: [*c]Structure, ...) callconv(.c) [*c]Caps {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return fullFrom(first, &ap);
}

pub export fn gst_caps_new_full_valist(first: [*c]Structure, ap: va.CVaList) [*c]Caps {
    return fullFrom(first, va.fromC(ap));
}

pub export fn gst_static_caps_get_type() c.GType {
    const S = struct {
        var once: gtype.Once = .{};
        fn f() c.GType {
            return c.g_pointer_type_register_static("GstStaticCaps");
        }
    };
    return S.once.get(S.f);
}

pub export fn gst_static_caps_get(sc: [*c]c.GstStaticCaps) [*c]Caps {
    if (!check.that(sc != null, "gst_static_caps_get", "static_caps != NULL")) return null;
    const slot: *?*Caps = @ptrCast(&sc.*.caps);
    if (@atomicLoad(?*Caps, slot, .acquire) == null) {
        c.g_mutex_lock(&static_lock);
        defer c.g_mutex_unlock(&static_lock);
        if (slot.* == null) {
            const text = sc.*.string;
            if (text == null) {
                c.g_mutex_unlock(&static_lock);
                c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "static caps %p string is NULL", sc);
                c.g_mutex_lock(&static_lock);
                return null;
            }
            const made = gst_caps_from_string(text);
            if (made == null) {
                c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Could not convert static caps \"%s\"", text);
            } else {
                asMini(made).*.flags |= c.GST_MINI_OBJECT_FLAG_MAY_BE_LEAKED;
                @atomicStore(?*Caps, slot, made, .release);
            }
        }
    }
    const got = slot.* orelse return null;
    _ = mini.gst_mini_object_ref(asMini(got));
    return got;
}

pub export fn gst_static_caps_cleanup(sc: [*c]c.GstStaticCaps) void {
    c.g_mutex_lock(&static_lock);
    defer c.g_mutex_unlock(&static_lock);
    _ = gst_caps_replace(@ptrCast(&sc.*.caps), null);
}

fn makeAny(p: [*c]Caps) void {
    var n = impl(p).len;
    while (n > 0) : (n -= 1) c.gst_structure_free(takeStructure(p, 0));
    asMini(p).*.flags |= c.GST_CAPS_FLAG_ANY;
}

pub export fn gst_caps_steal_structure(p: [*c]Caps, idx: c.guint) [*c]Structure {
    if (!check.that(p != null, "gst_caps_steal_structure", "caps != NULL")) return null;
    if (!check.that(writable(p), "gst_caps_steal_structure", "IS_WRITABLE (caps)")) return null;
    if (idx >= impl(p).len) return null;
    return takeStructure(p, idx);
}

pub export fn gst_caps_append(a: [*c]Caps, b_in: [*c]Caps) void {
    if (!check.that(isCaps(a), "gst_caps_append", "GST_IS_CAPS (caps1)")) return;
    if (!check.that(isCaps(b_in), "gst_caps_append", "GST_IS_CAPS (caps2)")) return;
    if (!check.that(writable(a), "gst_caps_append", "IS_WRITABLE (caps1)")) return;
    if (isAny(a) or isAny(b_in)) {
        makeAny(a);
        mini.gst_mini_object_unref(asMini(b_in));
        return;
    }
    const b = gst_caps_make_writable(b_in);
    var n = impl(b).len;
    while (n > 0) : (n -= 1) {
        var s: ?*Structure = null;
        var f: ?*Features = null;
        takeOut(b, 0, &s, &f);
        appendRaw(a, s, f);
    }
    mini.gst_mini_object_unref(asMini(b));
}

pub export fn gst_caps_merge(a_in: [*c]Caps, b_in: [*c]Caps) [*c]Caps {
    if (!check.that(isCaps(a_in), "gst_caps_merge", "GST_IS_CAPS (caps1)")) return null;
    if (!check.that(isCaps(b_in), "gst_caps_merge", "GST_IS_CAPS (caps2)")) return null;
    if (isAny(a_in)) {
        mini.gst_mini_object_unref(asMini(b_in));
        return a_in;
    }
    if (isAny(b_in)) {
        mini.gst_mini_object_unref(asMini(a_in));
        return b_in;
    }
    var a = a_in;
    const b = gst_caps_make_writable(b_in);
    var n = impl(b).len;
    while (n > 0) : (n -= 1) {
        var s: ?*Structure = null;
        var f: ?*Features = null;
        takeOut(b, 0, &s, &f);
        a = gst_caps_merge_structure_full(a, s, f);
    }
    mini.gst_mini_object_unref(asMini(b));
    return a;
}

fn isStructure(s: ?*const Structure) bool {
    return s != null and c.gst_structure_get_name(s) != null and structure.impl(s).s.type == c.gst_structure_get_type();
}

pub export fn gst_caps_append_structure(p: [*c]Caps, s: [*c]Structure) void {
    if (!check.that(isCaps(p), "gst_caps_append_structure", "GST_IS_CAPS (caps)")) return;
    if (!check.that(writable(p), "gst_caps_append_structure", "IS_WRITABLE (caps)")) return;
    if (!check.that(isStructure(s), "gst_caps_append_structure", "GST_IS_STRUCTURE (structure)")) return;
    if (isAny(p)) {
        c.gst_structure_free(s);
        return;
    }
    appendRaw(p, s, null);
}

pub export fn gst_caps_append_structure_full(p: [*c]Caps, s: [*c]Structure, f: ?*Features) void {
    if (!check.that(isCaps(p), "gst_caps_append_structure_full", "GST_IS_CAPS (caps)")) return;
    if (!check.that(writable(p), "gst_caps_append_structure_full", "IS_WRITABLE (caps)")) return;
    if (!check.that(isStructure(s), "gst_caps_append_structure_full", "GST_IS_STRUCTURE (structure)")) return;
    if (isAny(p)) {
        c.gst_structure_free(s);
        if (f != null) c.gst_caps_features_free(f);
        return;
    }
    appendRaw(p, s, f);
}

pub export fn gst_caps_remove_structure(p: [*c]Caps, idx: c.guint) void {
    if (!check.that(p != null, "gst_caps_remove_structure", "caps != NULL")) return;
    if (!check.that(idx < gst_caps_get_size(p), "gst_caps_remove_structure", "idx < gst_caps_get_size (caps)")) return;
    if (!check.that(writable(p), "gst_caps_remove_structure", "IS_WRITABLE (caps)")) return;
    c.gst_structure_free(takeStructure(p, idx));
}

pub export fn gst_caps_merge_structure(p_in: [*c]Caps, s: [*c]Structure) [*c]Caps {
    if (!check.that(isCaps(p_in), "gst_caps_merge_structure", "GST_IS_CAPS (caps)")) return null;
    if (s == null) return p_in;
    if (isAny(p_in)) {
        c.gst_structure_free(s);
        return p_in;
    }
    var idx = impl(p_in).len;
    while (idx > 0) {
        idx -= 1;
        const f = orSysmem(featuresAt(p_in, idx));
        if (c.gst_caps_features_is_equal(f, sysmem()) != 0 and c.gst_structure_is_subset(s, impl(p_in).entries[idx].s) != 0) {
            c.gst_structure_free(s);
            return p_in;
        }
    }
    const p = gst_caps_make_writable(p_in);
    appendRaw(p, s, null);
    return p;
}

pub export fn gst_caps_merge_structure_full(p_in: [*c]Caps, s: [*c]Structure, f: ?*Features) [*c]Caps {
    if (!check.that(isCaps(p_in), "gst_caps_merge_structure_full", "GST_IS_CAPS (caps)")) return null;
    if (s == null) return p_in;
    if (isAny(p_in)) {
        c.gst_structure_free(s);
        if (f != null) c.gst_caps_features_free(f);
        return p_in;
    }
    const mine = orSysmem(f);
    var idx = impl(p_in).len;
    while (idx > 0) {
        idx -= 1;
        const other = orSysmem(featuresAt(p_in, idx));
        const any_ok = c.gst_caps_features_is_any(mine) == 0 or c.gst_caps_features_is_any(other) != 0;
        if (any_ok and c.gst_caps_features_is_equal(mine, other) != 0 and c.gst_structure_is_subset(s, impl(p_in).entries[idx].s) != 0) {
            c.gst_structure_free(s);
            if (f != null) c.gst_caps_features_free(f);
            return p_in;
        }
    }
    const p = gst_caps_make_writable(p_in);
    appendRaw(p, s, f);
    return p;
}

pub export fn gst_caps_get_size(p: [*c]const Caps) c.guint {
    if (!check.that(isCaps(p), "gst_caps_get_size", "GST_IS_CAPS (caps)")) return 0;
    return impl(p).len;
}

pub export fn gst_caps_get_structure(p: [*c]const Caps, idx: c.guint) [*c]Structure {
    if (!check.that(isCaps(p), "gst_caps_get_structure", "GST_IS_CAPS (caps)")) return null;
    if (!check.that(idx < impl(p).len, "gst_caps_get_structure", "index < GST_CAPS_LEN (caps)")) return null;
    return impl(p).entries[idx].s;
}

pub export fn gst_caps_get_features(p: [*c]const Caps, idx: c.guint) ?*Features {
    if (!check.that(isCaps(p), "gst_caps_get_features", "GST_IS_CAPS (caps)")) return null;
    if (!check.that(idx < impl(p).len, "gst_caps_get_features", "index < GST_CAPS_LEN (caps)")) return null;
    if (featuresAt(p, idx)) |f| return f;
    const fresh = c.gst_caps_features_copy(sysmem());
    _ = c.gst_caps_features_set_parent_refcount(fresh, refcount(p));
    if (@cmpxchgStrong(?*Features, &impl(p).entries[idx].f, null, fresh, .acq_rel, .acquire) != null) {
        _ = c.gst_caps_features_set_parent_refcount(fresh, null);
        c.gst_caps_features_free(fresh);
        return featuresAt(p, idx);
    }
    return fresh;
}

pub export fn __gst_caps_get_features_unchecked(p: [*c]const Caps, idx: c.guint) ?*Features {
    return featuresAt(p, idx);
}

pub export fn gst_caps_set_features(p: [*c]Caps, idx: c.guint, f: ?*Features) void {
    if (!check.that(p != null, "gst_caps_set_features", "caps != NULL")) return;
    if (!check.that(idx < gst_caps_get_size(p), "gst_caps_set_features", "index < gst_caps_get_size (caps)")) return;
    if (!check.that(writable(p), "gst_caps_set_features", "IS_WRITABLE (caps)")) return;
    const old = @atomicRmw(?*Features, &impl(p).entries[idx].f, .Xchg, f, .acq_rel);
    if (f != null) _ = c.gst_caps_features_set_parent_refcount(f, refcount(p));
    if (old) |o| {
        _ = c.gst_caps_features_set_parent_refcount(o, null);
        c.gst_caps_features_free(o);
    }
}

pub export fn gst_caps_set_features_simple(p: [*c]Caps, f: ?*Features) void {
    if (!check.that(p != null, "gst_caps_set_features_simple", "caps != NULL")) return;
    if (!check.that(writable(p), "gst_caps_set_features_simple", "IS_WRITABLE (caps)")) return;
    const n = gst_caps_get_size(p);
    if (n == 0) {
        if (f != null) c.gst_caps_features_free(f);
        return;
    }
    var idx: c.guint = 0;
    while (idx < n) : (idx += 1) gst_caps_set_features(p, idx, if (f != null and idx < n - 1) c.gst_caps_features_copy(f) else f);
}

pub export fn gst_caps_copy_nth(p: [*c]const Caps, nth: c.guint) [*c]Caps {
    if (!check.that(isCaps(p), "gst_caps_copy_nth", "GST_IS_CAPS (caps)")) return null;
    const out = gst_caps_new_empty();
    asMini(out).*.flags = asMini(p).*.flags;
    if (impl(p).len > nth) appendRaw(out, c.gst_structure_copy(impl(p).entries[nth].s), copyUnlessSysmem(featuresAt(p, nth)));
    return out;
}

pub export fn gst_caps_truncate(p_in: [*c]Caps) [*c]Caps {
    if (!check.that(isCaps(p_in), "gst_caps_truncate", "GST_IS_CAPS (caps)")) return null;
    if (impl(p_in).len <= 1) return p_in;
    const p = gst_caps_make_writable(p_in);
    var idx = impl(p).len - 1;
    while (idx > 0) : (idx -= 1) gst_caps_remove_structure(p, idx);
    return p;
}

fn setGuard(comptime func: []const u8, p: [*c]Caps, field_ok: bool, comptime field_expr: []const u8, v: [*c]const Value) bool {
    if (!check.that(isCaps(p), func, "GST_IS_CAPS (caps)")) return false;
    if (!check.that(writable(p), func, "IS_WRITABLE (caps)")) return false;
    if (!check.that(field_ok, func, field_expr)) return false;
    return check.that(value.isValue(v), func, "G_IS_VALUE (value)");
}

pub export fn gst_caps_set_value(p: [*c]Caps, field: [*c]const u8, v: [*c]const Value) void {
    if (!setGuard("gst_caps_set_value", p, field != null, "field != NULL", v)) return;
    for (entries(p)) |e| c.gst_structure_set_value(e.s, field, v);
}

pub export fn gst_caps_set_value_static_str(p: [*c]Caps, field: [*c]const u8, v: [*c]const Value) void {
    if (!setGuard("gst_caps_set_value_static_str", p, field != null, "field != NULL", v)) return;
    for (entries(p)) |e| c.gst_structure_set_value_static_str(e.s, field, v);
}

pub export fn gst_caps_id_str_set_value(p: [*c]Caps, field: [*c]const c.GstIdStr, v: [*c]const Value) void {
    if (!setGuard("gst_caps_id_str_set_value", p, field != null, "field != NULL", v)) return;
    for (entries(p)) |e| c.gst_structure_id_str_set_value(e.s, field, v);
}

const SetKind = enum(c_int) { dup, static, id_str };

fn setList(p: [*c]Caps, kind: SetKind, first: c.gpointer, ap: *va.VaList) callconv(.c) void {
    var key = first;
    while (key != null) {
        const t = @cVaArg(ap, c.GType);
        var v = std.mem.zeroes(Value);
        const err = va.collect(&v, t, ap);
        if (err != null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "%s", err);
            c.g_free(err);
            return;
        }
        switch (kind) {
            .dup => gst_caps_set_value(p, @ptrCast(key), &v),
            .static => gst_caps_set_value_static_str(p, @ptrCast(key), &v),
            .id_str => gst_caps_id_str_set_value(p, @ptrCast(@alignCast(key)), &v),
        }
        c.g_value_unset(&v);
        key = @cVaArg(ap, c.gpointer);
    }
}

fn listGuard(comptime func: []const u8, p: [*c]Caps) bool {
    if (!check.that(isCaps(p), func, "GST_IS_CAPS (caps)")) return false;
    return check.that(writable(p), func, "IS_WRITABLE (caps)");
}

pub export fn gst_caps_set_simple_valist(p: [*c]Caps, field: [*c]const u8, ap: va.CVaList) void {
    if (!listGuard("gst_caps_set_simple_valist", p)) return;
    setList(p, .dup, @constCast(field), va.fromC(ap));
}

pub export fn gst_caps_set_simple_static_str_valist(p: [*c]Caps, field: [*c]const u8, ap: va.CVaList) void {
    if (!listGuard("gst_caps_set_simple_static_str_valist", p)) return;
    setList(p, .static, @constCast(field), va.fromC(ap));
}

pub export fn gst_caps_id_str_set_simple_valist(p: [*c]Caps, field: [*c]const c.GstIdStr, ap: va.CVaList) void {
    if (!listGuard("gst_caps_id_str_set_simple_valist", p)) return;
    setList(p, .id_str, @ptrCast(@constCast(field)), va.fromC(ap));
}

pub export fn gst_caps_set_simple(p: [*c]Caps, field: [*c]const u8, ...) callconv(.c) void {
    if (!listGuard("gst_caps_set_simple", p)) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    setList(p, .dup, @constCast(field), &ap);
}

pub export fn gst_caps_set_simple_static_str(p: [*c]Caps, field: [*c]const u8, ...) callconv(.c) void {
    if (!listGuard("gst_caps_set_simple_static_str", p)) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    setList(p, .static, @constCast(field), &ap);
}

pub export fn gst_caps_id_str_set_simple(p: [*c]Caps, field: [*c]const c.GstIdStr, ...) callconv(.c) void {
    if (!listGuard("gst_caps_id_str_set_simple", p)) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    setList(p, .id_str, @ptrCast(@constCast(field)), &ap);
}

pub export fn gst_caps_is_any(p: [*c]const Caps) c.gboolean {
    if (!check.that(isCaps(p), "gst_caps_is_any", "GST_IS_CAPS (caps)")) return 0;
    return @intFromBool(isAny(p));
}

pub export fn gst_caps_is_empty(p: [*c]const Caps) c.gboolean {
    if (!check.that(isCaps(p), "gst_caps_is_empty", "GST_IS_CAPS (caps)")) return 0;
    return @intFromBool(isEmpty(p));
}

fn fieldFixed(_: [*c]const c.GstIdStr, v: [*c]const Value, _: c.gpointer) callconv(.c) c.gboolean {
    return value.gst_value_is_fixed(v);
}

pub export fn gst_caps_is_fixed(p: [*c]const Caps) c.gboolean {
    if (!check.that(isCaps(p), "gst_caps_is_fixed", "GST_IS_CAPS (caps)")) return 0;
    if (impl(p).len != 1 or isAny(p)) return 0;
    if (featuresAt(p, 0)) |f| if (c.gst_caps_features_is_any(f) != 0) return 0;
    return c.gst_structure_foreach_id_str(impl(p).entries[0].s, fieldFixed, null);
}

pub export fn gst_caps_is_equal_fixed(a: [*c]const Caps, b: [*c]const Caps) c.gboolean {
    if (!check.that(gst_caps_is_fixed(a) != 0, "gst_caps_is_equal_fixed", "gst_caps_is_fixed (caps1)")) return 0;
    if (!check.that(gst_caps_is_fixed(b) != 0, "gst_caps_is_equal_fixed", "gst_caps_is_fixed (caps2)")) return 0;
    if (c.gst_structure_is_equal(impl(a).entries[0].s, impl(b).entries[0].s) == 0) return 0;
    return c.gst_caps_features_is_equal(orSysmem(featuresAt(a, 0)), orSysmem(featuresAt(b, 0)));
}

pub export fn gst_caps_is_always_compatible(a: [*c]const Caps, b: [*c]const Caps) c.gboolean {
    if (!check.that(isCaps(a), "gst_caps_is_always_compatible", "GST_IS_CAPS (caps1)")) return 0;
    if (!check.that(isCaps(b), "gst_caps_is_always_compatible", "GST_IS_CAPS (caps2)")) return 0;
    return gst_caps_is_subset(a, b);
}

fn featuresMatch(f1: ?*Features, f2: ?*Features) bool {
    return (c.gst_caps_features_is_any(f1) == 0 or c.gst_caps_features_is_any(f2) != 0) and c.gst_caps_features_is_equal(f1, f2) != 0;
}

pub export fn gst_caps_is_subset(sub: [*c]const Caps, sup: [*c]const Caps) c.gboolean {
    if (!check.that(sub != null, "gst_caps_is_subset", "subset != NULL")) return 0;
    if (!check.that(sup != null, "gst_caps_is_subset", "superset != NULL")) return 0;
    if (isEmpty(sub) or isAny(sup)) return 1;
    if (isAny(sub) or isEmpty(sup)) return 0;
    var i = impl(sub).len;
    outer: while (i > 0) {
        i -= 1;
        const s1 = impl(sub).entries[i].s;
        const f1 = orSysmem(featuresAt(sub, i));
        var j = impl(sup).len;
        while (j > 0) {
            j -= 1;
            if (featuresMatch(f1, orSysmem(featuresAt(sup, j))) and c.gst_structure_is_subset(s1, impl(sup).entries[j].s) != 0) continue :outer;
        }
        return 0;
    }
    return 1;
}

pub export fn gst_caps_is_subset_structure(p: [*c]const Caps, s: [*c]const Structure) c.gboolean {
    if (!check.that(p != null, "gst_caps_is_subset_structure", "caps != NULL")) return 0;
    if (!check.that(s != null, "gst_caps_is_subset_structure", "structure != NULL")) return 0;
    if (isAny(p)) return 1;
    if (isEmpty(p)) return 0;
    var i = impl(p).len;
    while (i > 0) {
        i -= 1;
        if (c.gst_structure_is_subset(s, impl(p).entries[i].s) != 0) return 1;
    }
    return 0;
}

pub export fn gst_caps_is_subset_structure_full(p: [*c]const Caps, s: [*c]const Structure, f_in: ?*const Features) c.gboolean {
    if (!check.that(p != null, "gst_caps_is_subset_structure_full", "caps != NULL")) return 0;
    if (!check.that(s != null, "gst_caps_is_subset_structure_full", "structure != NULL")) return 0;
    if (isAny(p)) return 1;
    if (isEmpty(p)) return 0;
    const f = orSysmem(@constCast(f_in));
    var i = impl(p).len;
    while (i > 0) {
        i -= 1;
        if (featuresMatch(f, orSysmem(featuresAt(p, i))) and c.gst_structure_is_subset(s, impl(p).entries[i].s) != 0) return 1;
    }
    return 0;
}

pub export fn gst_caps_is_equal(a: [*c]const Caps, b: [*c]const Caps) c.gboolean {
    if (!check.that(isCaps(a), "gst_caps_is_equal", "GST_IS_CAPS (caps1)")) return 0;
    if (!check.that(isCaps(b), "gst_caps_is_equal", "GST_IS_CAPS (caps2)")) return 0;
    if (a == b) return 1;
    if (gst_caps_is_fixed(a) != 0 and gst_caps_is_fixed(b) != 0) return gst_caps_is_equal_fixed(a, b);
    return @intFromBool(gst_caps_is_subset(a, b) != 0 and gst_caps_is_subset(b, a) != 0);
}

pub export fn gst_caps_is_strictly_equal(a: [*c]const Caps, b: [*c]const Caps) c.gboolean {
    if (!check.that(isCaps(a), "gst_caps_is_strictly_equal", "GST_IS_CAPS (caps1)")) return 0;
    if (!check.that(isCaps(b), "gst_caps_is_strictly_equal", "GST_IS_CAPS (caps2)")) return 0;
    if (a == b) return 1;
    if (isAny(a)) return @intFromBool(isAny(b));
    if (isAny(b)) return 0;
    if (impl(a).len != impl(b).len) return 0;
    for (0..impl(a).len) |i| {
        const f1 = orSysmem(featuresAt(a, i));
        const f2 = orSysmem(featuresAt(b, i));
        if (c.gst_caps_features_is_any(f1) != c.gst_caps_features_is_any(f2)) return 0;
        if (c.gst_caps_features_is_equal(f1, f2) == 0) return 0;
        if (c.gst_structure_is_equal(impl(a).entries[i].s, impl(b).entries[i].s) == 0) return 0;
    }
    return 1;
}

fn Diagonal(comptime Ctx: type) type {
    return struct {
        fn walk(a: [*c]const Caps, b: [*c]const Caps, ctx: *Ctx) bool {
            const l1: u64 = impl(a).len;
            const l2: u64 = impl(b).len;
            var i: u64 = 0;
            while (i < l1 + l2 - 1) : (i += 1) {
                var j: u64 = @min(i, l1 - 1);
                var k: u64 = if (i > j) i - j else 0;
                while (k < l2) {
                    if (ctx.visit(a, @intCast(j), b, @intCast(k))) return true;
                    k += 1;
                    if (j == 0) break;
                    j -= 1;
                }
            }
            return false;
        }
    };
}

const CanMeet = struct {
    fn visit(_: *CanMeet, a: [*c]const Caps, j: usize, b: [*c]const Caps, k: usize) bool {
        return c.gst_caps_features_is_equal(orSysmem(featuresAt(a, j)), orSysmem(featuresAt(b, k))) != 0 and
            c.gst_structure_can_intersect(impl(a).entries[j].s, impl(b).entries[k].s) != 0;
    }
};

pub export fn gst_caps_can_intersect(a: [*c]const Caps, b: [*c]const Caps) c.gboolean {
    if (!check.that(isCaps(a), "gst_caps_can_intersect", "GST_IS_CAPS (caps1)")) return 0;
    if (!check.that(isCaps(b), "gst_caps_can_intersect", "GST_IS_CAPS (caps2)")) return 0;
    if (a == b) return 1;
    if (isEmpty(a) or isEmpty(b)) return 0;
    if (isAny(a) or isAny(b)) return 1;
    var ctx = CanMeet{};
    return @intFromBool(Diagonal(CanMeet).walk(a, b, &ctx));
}

fn meetInto(dest: *[*c]Caps, a: [*c]const Caps, j: usize, b: [*c]const Caps, k: usize) void {
    const f1 = orSysmem(featuresAt(a, j));
    const f2 = orSysmem(featuresAt(b, k));
    if (c.gst_caps_features_is_equal(f1, f2) == 0) return;
    const s = c.gst_structure_intersect(impl(a).entries[j].s, impl(b).entries[k].s);
    if (s == null) return;
    const keep = if (c.gst_caps_features_is_any(f1) != 0) f2 else f1;
    dest.* = gst_caps_merge_structure_full(dest.*, s, copyUnlessSysmem(keep));
}

const Meet = struct {
    dest: [*c]Caps,
    fn visit(self: *Meet, a: [*c]const Caps, j: usize, b: [*c]const Caps, k: usize) bool {
        meetInto(&self.dest, a, j, b, k);
        return false;
    }
};

pub export fn gst_caps_intersect_full(a: [*c]Caps, b: [*c]Caps, mode: c.GstCapsIntersectMode) [*c]Caps {
    if (!check.that(isCaps(a), "gst_caps_intersect_full", "GST_IS_CAPS (caps1)")) return null;
    if (!check.that(isCaps(b), "gst_caps_intersect_full", "GST_IS_CAPS (caps2)")) return null;
    if (a == b) return gst_caps_ref(a);
    if (isEmpty(a) or isEmpty(b)) return gst_caps_ref(_gst_caps_none);
    if (isAny(a)) return gst_caps_ref(b);
    if (isAny(b)) return gst_caps_ref(a);
    if (mode == c.GST_CAPS_INTERSECT_FIRST) {
        var dest = gst_caps_new_empty();
        for (0..impl(a).len) |j| for (0..impl(b).len) |k| meetInto(&dest, a, j, b, k);
        return dest;
    }
    if (mode != c.GST_CAPS_INTERSECT_ZIG_ZAG) c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Unknown caps intersect mode: %d", mode);
    var ctx = Meet{ .dest = gst_caps_new_empty() };
    _ = Diagonal(Meet).walk(a, b, &ctx);
    return ctx.dest;
}

pub export fn gst_caps_intersect(a: [*c]Caps, b: [*c]Caps) [*c]Caps {
    return gst_caps_intersect_full(a, b, c.GST_CAPS_INTERSECT_ZIG_ZAG);
}

const Subtraction = struct {
    from: ?*const Structure,
    out: ?*c.GSList = null,
};

fn subtractField(field: [*c]const c.GstIdStr, v: [*c]const Value, data: c.gpointer) callconv(.c) c.gboolean {
    const e: *Subtraction = @ptrCast(@alignCast(data));
    const other = c.gst_structure_id_str_get_value(e.from, field);
    if (other == null) return 0;
    var diff = std.mem.zeroes(Value);
    if (c.gst_value_subtract(&diff, other, v) == 0) return 1;
    if (value.gst_value_compare(&diff, other) == c.GST_VALUE_EQUAL) {
        c.g_value_unset(&diff);
        return 0;
    }
    const copy = c.gst_structure_copy(e.from);
    c.gst_structure_id_str_take_value(copy, field, &diff);
    e.out = c.g_slist_prepend(e.out, copy);
    return 1;
}

fn freeList(list: ?*c.GSList) void {
    var node = list;
    while (node) |n| : (node = n.next) c.gst_structure_free(@ptrCast(@alignCast(n.data)));
    c.g_slist_free(list);
}

fn subtractStructures(into: *?*c.GSList, minuend: ?*const Structure, subtrahend: ?*const Structure) bool {
    var e = Subtraction{ .from = minuend };
    if (c.gst_structure_foreach_id_str(subtrahend, subtractField, &e) != 0) {
        into.* = e.out;
        return true;
    }
    freeList(e.out);
    return false;
}

pub export fn gst_caps_subtract(minuend: [*c]Caps, subtrahend: [*c]Caps) [*c]Caps {
    if (!check.that(minuend != null, "gst_caps_subtract", "minuend != NULL")) return null;
    if (!check.that(subtrahend != null, "gst_caps_subtract", "subtrahend != NULL")) return null;
    if (isEmpty(minuend) or isAny(subtrahend)) return gst_caps_new_empty();
    if (isEmptySimple(subtrahend)) return gst_caps_ref(minuend);
    if (!check.that(!isAny(minuend), "gst_caps_subtract", "!CAPS_IS_ANY (minuend)")) return null;
    var src: [*c]Caps = @ptrCast(copyCaps(asMini(minuend)));
    var dest: [*c]Caps = null;
    for (0..impl(subtrahend).len) |i| {
        const sub = impl(subtrahend).entries[i].s;
        const sub_f = orSysmem(featuresAt(subtrahend, i));
        if (dest != null) {
            gst_caps_unref(src);
            src = dest;
        }
        dest = gst_caps_new_empty();
        for (0..impl(src).len) |j| {
            const min = impl(src).entries[j].s;
            const min_f = orSysmem(featuresAt(src, j));
            if (!check.that(c.gst_caps_features_is_any(min_f) == 0, "gst_caps_subtract", "!gst_caps_features_is_any (min_f)")) return null;
            var list: ?*c.GSList = null;
            if (c.gst_structure_has_name(min, c.gst_structure_get_name(sub)) != 0 and c.gst_caps_features_is_equal(min_f, sub_f) != 0 and subtractStructures(&list, min, sub)) {
                var node = list;
                while (node) |n| : (node = n.next) appendRaw(dest, @ptrCast(@alignCast(n.data)), copyUnlessSysmem(min_f));
                c.g_slist_free(list);
            } else {
                appendRaw(dest, c.gst_structure_copy(min), copyUnlessSysmem(min_f));
            }
        }
        if (isEmptySimple(dest)) {
            gst_caps_unref(src);
            return dest;
        }
    }
    gst_caps_unref(src);
    return gst_caps_simplify(dest);
}

const Normalize = struct {
    caps: [*c]Caps,
    s: ?*Structure,
    f: ?*Features,
};

fn splitList(field: [*c]const c.GstIdStr, v: [*c]const Value, data: c.gpointer) callconv(.c) c.gboolean {
    const nf: *Normalize = @ptrCast(@alignCast(data));
    if (v[0].g_type != value._gst_value_list_type) return 1;
    const n = c.gst_value_list_get_size(v);
    var i: c.guint = 1;
    while (i < n) : (i += 1) {
        const copy = c.gst_structure_copy(nf.s);
        c.gst_structure_id_str_set_value(copy, field, c.gst_value_list_get_value(v, i));
        appendRaw(nf.caps, copy, copyUnlessSysmem(nf.f));
    }
    var first = std.mem.zeroes(Value);
    value.gst_value_init_and_copy(&first, c.gst_value_list_get_value(v, 0));
    c.gst_structure_id_str_take_value(nf.s, field, &first);
    return 0;
}

pub export fn gst_caps_normalize(p_in: [*c]Caps) [*c]Caps {
    if (!check.that(isCaps(p_in), "gst_caps_normalize", "GST_IS_CAPS (caps)")) return null;
    var nf = Normalize{ .caps = gst_caps_make_writable(p_in), .s = null, .f = null };
    var i: c.guint = 0;
    while (i < gst_caps_get_size(nf.caps)) : (i += 1) {
        nf.s = impl(nf.caps).entries[i].s;
        nf.f = featuresAt(nf.caps, i);
        while (c.gst_structure_foreach_id_str(nf.s, splitList, &nf) == 0) {}
    }
    return nf.caps;
}

fn entryOrder(_: void, x: Entry, y: Entry) bool {
    const r = std.mem.orderZ(u8, c.gst_structure_get_name(x.s), c.gst_structure_get_name(y.s));
    if (r != .eq) return r == .lt;
    return c.gst_structure_n_fields(y.s) < c.gst_structure_n_fields(x.s);
}

const UnionField = struct {
    name: c.GstIdStr = std.mem.zeroes(c.GstIdStr),
    value: Value = std.mem.zeroes(Value),
    compare: ?*Structure,
};

fn figureUnion(field: [*c]const c.GstIdStr, v: [*c]const Value, data: c.gpointer) callconv(.c) c.gboolean {
    const u: *UnionField = @ptrCast(@alignCast(data));
    const other = c.gst_structure_id_str_get_value(u.compare, field);
    if (other == null) {
        if (u.value.g_type != 0) c.g_value_unset(&u.value);
        return 0;
    }
    if (value.gst_value_compare(other, v) == c.GST_VALUE_EQUAL) return 1;
    if (u.value.g_type != 0) {
        c.g_value_unset(&u.value);
        return 0;
    }
    c.gst_id_str_copy_into(&u.name, field);
    _ = c.gst_value_union(&u.value, other, v);
    return 1;
}

fn simplifyPair(result: *?*Structure, simplify: ?*Structure, compare: ?*Structure) bool {
    var list: ?*c.GSList = null;
    if (subtractStructures(&list, simplify, compare)) {
        if (list == null) {
            result.* = null;
            return true;
        }
        if (list.?.next == null) {
            result.* = @ptrCast(@alignCast(list.?.data));
            c.g_slist_free(list);
            return true;
        }
        freeList(list);
    }
    var u = UnionField{ .compare = compare };
    defer c.gst_id_str_clear(&u.name);
    if (c.gst_structure_foreach_id_str(simplify, figureUnion, &u) == 0) return false;
    if (u.value.g_type != 0) {
        if (c.gst_structure_n_fields(simplify) == c.gst_structure_n_fields(compare)) {
            c.gst_structure_id_str_take_value(compare, &u.name, &u.value);
            result.* = null;
            return true;
        }
        c.g_value_unset(&u.value);
    }
    return false;
}

pub export fn gst_caps_simplify(p_in: [*c]Caps) [*c]Caps {
    if (!check.that(isCaps(p_in), "gst_caps_simplify", "GST_IS_CAPS (caps)")) return null;
    if (impl(p_in).len <= 1) return p_in;
    const p = gst_caps_make_writable(p_in);
    std.mem.sort(Entry, entries(p), {}, entryOrder);
    var start: isize = @as(isize, impl(p).len) - 1;
    var i: isize = start;
    while (i >= 0) : (i -= 1) {
        const ui: usize = @intCast(i);
        var simplify = impl(p).entries[ui].s;
        const simplify_f = orSysmem(featuresAt(p, ui));
        const head = impl(p).entries[@intCast(start)].s;
        const head_f = orSysmem(featuresAt(p, @intCast(start)));
        if (c.gst_structure_has_name(simplify, c.gst_structure_get_name(head)) == 0 or c.gst_caps_features_is_equal(simplify_f, head_f) == 0) start = i;
        var j: isize = start;
        while (j >= 0) : (j -= 1) {
            if (j == i) continue;
            const uj: usize = @intCast(j);
            const compare = impl(p).entries[uj].s;
            const compare_f = orSysmem(featuresAt(p, uj));
            if (c.gst_structure_has_name(simplify, c.gst_structure_get_name(compare)) == 0 or c.gst_caps_features_is_equal(simplify_f, compare_f) == 0) break;
            var result: ?*Structure = null;
            if (!simplifyPair(&result, simplify, compare)) continue;
            if (result) |r| {
                _ = c.gst_structure_set_parent_refcount(simplify, null);
                c.gst_structure_free(simplify);
                _ = c.gst_structure_set_parent_refcount(r, refcount(p));
                impl(p).entries[ui].s = r;
                simplify = r;
            } else {
                gst_caps_remove_structure(p, @intCast(ui));
                start -= 1;
                break;
            }
        }
    }
    return p;
}

pub export fn gst_caps_fixate(p_in: [*c]Caps) [*c]Caps {
    if (!check.that(isCaps(p_in), "gst_caps_fixate", "GST_IS_CAPS (caps)")) return null;
    if (!check.that(!isAny(p_in), "gst_caps_fixate", "!CAPS_IS_ANY (caps)")) return null;
    const p = gst_caps_make_writable(gst_caps_truncate(p_in));
    if (isEmpty(p)) return p;
    c.gst_structure_fixate(gst_caps_get_structure(p, 0));
    if (featuresAt(p, 0)) |f| if (c.gst_caps_features_is_any(f) != 0) gst_caps_set_features(p, 0, c.gst_caps_features_new_empty());
    return p;
}

fn serialize(p: [*c]const Caps, flags: c.GstSerializeFlags) [*c]u8 {
    if (p == null) return c.g_strdup("NULL");
    if (isAny(p)) return c.g_strdup("ANY");
    if (isEmptySimple(p)) return c.g_strdup("EMPTY");
    const out = c.g_string_sized_new(64 * @as(usize, impl(p).len));
    for (entries(p), 0..) |e, i| {
        if (i > 0) _ = c.g_string_append_c(out, ' ');
        _ = c.g_string_append(out, c.gst_structure_get_name(e.s));
        if (featuresAt(p, i)) |f| {
            if (c.gst_caps_features_is_any(f) != 0 or c.gst_caps_features_is_equal(f, sysmem()) == 0) {
                _ = c.g_string_append_c(out, '(');
                features_mod.appendTo(f, out);
                _ = c.g_string_append_c(out, ')');
            }
        }
        _ = structure.appendFields(e.s, out, @intFromBool(flags & c.GST_SERIALIZE_FLAG_BACKWARD_COMPAT == 0));
    }
    if (out.*.len > 0 and out.*.str[out.*.len - 1] == ';') {
        out.*.len -= 1;
        out.*.str[out.*.len] = 0;
    }
    return c.g_string_free(out, 0);
}

pub export fn gst_caps_to_string(p: [*c]const Caps) [*c]u8 {
    return serialize(p, c.GST_SERIALIZE_FLAG_BACKWARD_COMPAT);
}

pub export fn gst_caps_serialize(p: [*c]const Caps, flags: c.GstSerializeFlags) [*c]u8 {
    return serialize(p, flags);
}

fn parseInto(p: [*c]Caps, text: [*c]const u8) bool {
    if (std.mem.orderZ(u8, text, "ANY") == .eq) {
        asMini(p).*.flags = c.GST_CAPS_FLAG_ANY;
        return true;
    }
    if (std.mem.orderZ(u8, text, "EMPTY") == .eq or std.mem.orderZ(u8, text, "NONE") == .eq) return true;
    const copy = c.g_strdup(text);
    defer c.g_free(copy);
    var s: [*c]u8 = copy;
    while (true) {
        while (std.ascii.isWhitespace(s[0])) s += 1;
        if (s[0] == 0) break;
        var end: [*c]u8 = undefined;
        var next: [*c]u8 = undefined;
        if (!structure.parseName(s, &s, &end, &next, false)) return false;
        const saved = end[0];
        end[0] = 0;
        const st = c.gst_structure_new_empty(s);
        end[0] = saved;
        if (st == null) return false;
        s = next;
        var feats: ?*Features = null;
        if (s[0] == '(') {
            s += 1;
            var close = s;
            while (close[0] != 0 and close[0] != ')') close += 1;
            const was = close[0];
            close[0] = 0;
            feats = c.gst_caps_features_from_string(s);
            if (feats == null) {
                c.gst_structure_free(st);
                return false;
            }
            close[0] = was;
            s = close;
            if (was == ')') s += 1;
        }
        if (s[0] != 0 and !structure.parseFields(s, &s, st)) {
            c.gst_structure_free(st);
            if (feats != null) c.gst_caps_features_free(feats);
            return false;
        }
        appendRaw(p, st, feats);
        if (s[0] == 0) break;
    }
    return true;
}

pub export fn gst_caps_from_string(text: [*c]const u8) [*c]Caps {
    if (!check.that(text != null, "gst_caps_from_string", "string")) return null;
    const p = gst_caps_new_empty();
    if (parseInto(p, text)) return p;
    gst_caps_unref(p);
    return null;
}

fn toString(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    const f = "gst_caps_transform_to_string";
    if (!check.that(value.isValue(src), f, "G_IS_VALUE (src_value)")) return;
    if (!check.that(value.isValue(dest), f, "G_IS_VALUE (dest_value)")) return;
    if (!check.that(c.g_type_check_value_holds(src, _gst_caps_type) != 0, f, "G_VALUE_HOLDS (src_value, GST_TYPE_CAPS)")) return;
    if (!check.that(c.g_type_check_value_holds(dest, c.G_TYPE_STRING) != 0 or c.g_type_check_value_holds(dest, c.G_TYPE_POINTER) != 0, f, "G_VALUE_HOLDS (dest_value, G_TYPE_STRING) || G_VALUE_HOLDS (dest_value, G_TYPE_POINTER)")) return;
    c.g_value_take_string(dest, gst_caps_to_string(value.gst_value_get_caps(src)));
}

pub export fn gst_caps_foreach(p: [*c]const Caps, func: c.GstCapsForeachFunc, data: c.gpointer) c.gboolean {
    if (!check.that(isCaps(p), "gst_caps_foreach", "GST_IS_CAPS (caps)")) return 0;
    if (!check.that(func != null, "gst_caps_foreach", "func != NULL")) return 0;
    for (entries(p), 0..) |e, i| if (func.?(featuresAt(p, i), e.s, data) == 0) return 0;
    return 1;
}

fn ensureFeatures(p: [*c]Caps, i: usize) ?*Features {
    if (featuresAt(p, i)) |f| return f;
    const f = c.gst_caps_features_copy(sysmem());
    gst_caps_set_features(p, @intCast(i), f);
    return f;
}

pub export fn gst_caps_map_in_place(p: [*c]Caps, func: c.GstCapsMapFunc, data: c.gpointer) c.gboolean {
    if (!check.that(isCaps(p), "gst_caps_map_in_place", "GST_IS_CAPS (caps)")) return 0;
    if (!check.that(gst_caps_is_writable(p) != 0, "gst_caps_map_in_place", "gst_caps_is_writable (caps)")) return 0;
    if (!check.that(func != null, "gst_caps_map_in_place", "func != NULL")) return 0;
    for (0..impl(p).len) |i| {
        const f = ensureFeatures(p, i);
        if (func.?(f, impl(p).entries[i].s, data) == 0) return 0;
    }
    return 1;
}

pub export fn gst_caps_filter_and_map_in_place(p: [*c]Caps, func: c.GstCapsFilterMapFunc, data: c.gpointer) void {
    if (!check.that(isCaps(p), "gst_caps_filter_and_map_in_place", "GST_IS_CAPS (caps)")) return;
    if (!check.that(gst_caps_is_writable(p) != 0, "gst_caps_filter_and_map_in_place", "gst_caps_is_writable (caps)")) return;
    if (!check.that(func != null, "gst_caps_filter_and_map_in_place", "func != NULL")) return;
    var i: usize = 0;
    while (i < impl(p).len) {
        const f = ensureFeatures(p, i);
        const s = impl(p).entries[i].s;
        if (func.?(f, s, data) != 0) {
            i += 1;
            continue;
        }
        var gone_s: ?*Structure = null;
        var gone_f: ?*Features = null;
        takeOut(p, i, &gone_s, &gone_f);
        c.gst_structure_free(gone_s);
        if (gone_f != null) c.gst_caps_features_free(gone_f);
    }
}

pub export fn gst_caps_copy(p: [*c]const Caps) [*c]Caps {
    return @ptrCast(mini.gst_mini_object_copy(asMini(p)));
}

pub export fn gst_caps_ref(p: [*c]Caps) [*c]Caps {
    return @ptrCast(mini.gst_mini_object_ref(asMini(p)));
}

pub export fn gst_caps_unref(p: [*c]Caps) void {
    mini.gst_mini_object_unref(asMini(p));
}

pub export fn gst_clear_caps(slot: [*c][*c]Caps) void {
    mini.gst_clear_mini_object(@ptrCast(slot));
}

pub export fn gst_caps_replace(slot: [*c][*c]Caps, new: [*c]Caps) c.gboolean {
    return mini.gst_mini_object_replace(@ptrCast(slot), asMini(new));
}

pub export fn gst_caps_take(slot: [*c][*c]Caps, new: [*c]Caps) c.gboolean {
    return mini.gst_mini_object_take(@ptrCast(slot), asMini(new));
}

pub export fn gst_caps_steal(slot: [*c][*c]Caps) [*c]Caps {
    return @ptrCast(mini.gst_mini_object_steal(@ptrCast(slot)));
}

pub export fn gst_caps_is_writable(p: [*c]const Caps) c.gboolean {
    return mini.gst_mini_object_is_writable(asMini(p));
}

pub export fn gst_caps_make_writable(p: [*c]Caps) [*c]Caps {
    return @ptrCast(mini.gst_mini_object_make_writable(asMini(p)));
}

fn compareValues(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    const x = value.gst_value_get_caps(a);
    const y = value.gst_value_get_caps(b);
    if (x == y) return c.GST_VALUE_EQUAL;
    if (x == null or y == null) return c.GST_VALUE_UNORDERED;
    return if (gst_caps_is_equal(x, y) != 0) c.GST_VALUE_EQUAL else c.GST_VALUE_UNORDERED;
}

fn serializeValue(v: [*c]const Value) callconv(.c) [*c]u8 {
    return vbasic.takeAndWrap(gst_caps_to_string(@ptrCast(@alignCast(c.g_value_get_boxed(v)))));
}

fn deserializeValue(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    var p: [*c]Caps = null;
    if (s[0] != '"') {
        p = gst_caps_from_string(s);
    } else {
        const raw = vbasic.unwrap(s);
        if (raw == null) return 0;
        p = gst_caps_from_string(raw);
        c.g_free(raw);
    }
    if (p == null) return 0;
    c.g_value_take_boxed(dest, p);
    return 1;
}

var value_table: c.GstValueTable = .{};

pub fn initialize() void {
    _gst_caps_type = gst_caps_get_type();
    _gst_caps_any = gst_caps_new_any();
    _gst_caps_none = gst_caps_new_empty();
    c.g_value_register_transform_func(_gst_caps_type, c.G_TYPE_STRING, toString);
    value_table = .{ .type = _gst_caps_type, .compare = compareValues, .serialize = serializeValue, .deserialize = deserializeValue, .hash = @import("vhash.zig").caps };
    value.gst_value_register(&value_table);
}
