const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const mini = @import("mini.zig");
const buffer = @import("buffer.zig");
const bufferlist = @import("bufferlist.zig");
const segment = @import("segment.zig");
const value = @import("value.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Sample = c.GstSample;
const Mini = c.GstMiniObject;

const Impl = extern struct {
    mini: Mini,
    buffer: [*c]c.GstBuffer,
    caps: [*c]c.GstCaps,
    segment: c.GstSegment,
    info: [*c]c.GstStructure,
    list: ?*c.GstBufferList,
};

pub export var _gst_sample_type: c.GType = 0;
var type_once: gtype.Once = .{};

fn impl(p: anytype) *Impl {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn asMini(p: anytype) [*c]Mini {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn isSample(p: anytype) bool {
    return p != null and asMini(p)[0].type == _gst_sample_type;
}

pub export fn gst_sample_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstSample", @ptrCast(&mini.gst_mini_object_ref), @ptrCast(&mini.gst_mini_object_unref));
        }
    }.f);
}

fn copyHook(src: [*c]const Mini) callconv(.c) [*c]Mini {
    const s = impl(src);
    const out = gst_sample_new(s.buffer, s.caps, &s.segment, if (s.info != null) c.gst_structure_copy(s.info) else null);
    if (s.list != null) {
        impl(out).list = bufferlist.gst_buffer_list_ref(s.list);
        mini.gst_mini_object_add_parent(asMini(impl(out).list), asMini(out));
    }
    return asMini(out);
}

fn drop(owner: anytype, child: anytype, comptime unref: anytype) void {
    if (child == null) return;
    mini.gst_mini_object_remove_parent(asMini(child), asMini(owner));
    unref(child);
}

fn freeHook(m: [*c]Mini) callconv(.c) void {
    const s = impl(m);
    drop(m, s.buffer, buffer.gst_buffer_unref);
    drop(m, s.caps, c.gst_caps_unref);
    if (s.info != null) {
        _ = c.gst_structure_set_parent_refcount(s.info, null);
        c.gst_structure_free(s.info);
    }
    drop(m, s.list, bufferlist.gst_buffer_list_unref);
    c.g_free(m);
}

fn ownInfo(p: ?*Sample, info: [*c]c.GstStructure) bool {
    if (c.gst_structure_set_parent_refcount(info, &impl(p).mini.refcount) != 0) return true;
    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "structure is already owned by another object");
    return false;
}

pub export fn gst_sample_new(b: [*c]c.GstBuffer, caps: [*c]c.GstCaps, seg: [*c]const c.GstSegment, info: [*c]c.GstStructure) ?*Sample {
    const s: *Impl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Impl))));
    mini.gst_mini_object_init(asMini(s), 0, _gst_sample_type, copyHook, null, freeHook);
    if (b != null) {
        s.buffer = buffer.gst_buffer_ref(b);
        mini.gst_mini_object_add_parent(asMini(s.buffer), asMini(s));
    }
    if (caps != null) {
        s.caps = c.gst_caps_ref(caps);
        mini.gst_mini_object_add_parent(asMini(s.caps), asMini(s));
    }
    if (seg != null) segment.gst_segment_copy_into(seg, &s.segment) else segment.gst_segment_init(&s.segment, c.GST_FORMAT_TIME);
    if (info != null) {
        if (c.gst_structure_set_parent_refcount(info, &s.mini.refcount) == 0) {
            gst_sample_unref(@ptrCast(s));
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "structure is already owned by another object");
            return null;
        }
        s.info = info;
    }
    return @ptrCast(s);
}

pub export fn gst_sample_get_buffer(p: ?*Sample) [*c]c.GstBuffer {
    if (!check.that(isSample(p), "gst_sample_get_buffer", "GST_IS_SAMPLE (sample)")) return null;
    return impl(p).buffer;
}

pub export fn gst_sample_get_caps(p: ?*Sample) [*c]c.GstCaps {
    if (!check.that(isSample(p), "gst_sample_get_caps", "GST_IS_SAMPLE (sample)")) return null;
    return impl(p).caps;
}

pub export fn gst_sample_get_segment(p: ?*Sample) [*c]c.GstSegment {
    if (!check.that(isSample(p), "gst_sample_get_segment", "GST_IS_SAMPLE (sample)")) return null;
    return &impl(p).segment;
}

pub export fn gst_sample_get_info(p: ?*Sample) [*c]const c.GstStructure {
    if (!check.that(isSample(p), "gst_sample_get_info", "GST_IS_SAMPLE (sample)")) return null;
    return impl(p).info;
}

pub export fn gst_sample_get_buffer_list(p: ?*Sample) ?*c.GstBufferList {
    if (!check.that(isSample(p), "gst_sample_get_buffer_list", "GST_IS_SAMPLE (sample)")) return null;
    return impl(p).list;
}

fn Swap(comptime T: type, comptime ref: anytype, comptime unref: anytype) type {
    return struct {
        fn set(p: ?*Sample, slot: *T, new: T) void {
            const old = slot.*;
            if (old == new) return;
            if (new != null) {
                slot.* = ref(new);
                mini.gst_mini_object_add_parent(asMini(slot.*), asMini(p));
            } else slot.* = null;
            drop(p, old, unref);
        }
    };
}

fn guard(comptime f: []const u8, p: ?*Sample) bool {
    if (!check.that(isSample(p), f, "GST_IS_SAMPLE (sample)")) return false;
    return check.that(gst_sample_is_writable(p) != 0, f, "gst_sample_is_writable (sample)");
}

pub export fn gst_sample_set_buffer_list(p: ?*Sample, l: ?*c.GstBufferList) void {
    if (!guard("gst_sample_set_buffer_list", p)) return;
    Swap(?*c.GstBufferList, bufferlist.gst_buffer_list_ref, bufferlist.gst_buffer_list_unref).set(p, &impl(p).list, l);
}

pub export fn gst_sample_set_buffer(p: ?*Sample, b: [*c]c.GstBuffer) void {
    if (!guard("gst_sample_set_buffer", p)) return;
    Swap([*c]c.GstBuffer, buffer.gst_buffer_ref, buffer.gst_buffer_unref).set(p, &impl(p).buffer, b);
}

pub export fn gst_sample_set_caps(p: ?*Sample, caps: [*c]c.GstCaps) void {
    if (!guard("gst_sample_set_caps", p)) return;
    Swap([*c]c.GstCaps, c.gst_caps_ref, c.gst_caps_unref).set(p, &impl(p).caps, caps);
}

pub export fn gst_sample_set_segment(p: ?*Sample, seg: [*c]const c.GstSegment) void {
    if (!guard("gst_sample_set_segment", p)) return;
    if (seg != null) segment.gst_segment_copy_into(seg, &impl(p).segment) else segment.gst_segment_init(&impl(p).segment, c.GST_FORMAT_TIME);
}

pub export fn gst_sample_set_info(p: ?*Sample, info: [*c]c.GstStructure) c.gboolean {
    if (!guard("gst_sample_set_info", p)) return 0;
    if (info != null and !ownInfo(p, info)) return 0;
    if (impl(p).info != null) {
        _ = c.gst_structure_set_parent_refcount(impl(p).info, null);
        c.gst_structure_free(impl(p).info);
    }
    impl(p).info = info;
    return 1;
}

pub export fn gst_sample_ref(p: ?*Sample) ?*Sample {
    return @ptrCast(mini.gst_mini_object_ref(asMini(p)));
}

pub export fn gst_sample_unref(p: ?*Sample) void {
    mini.gst_mini_object_unref(asMini(p));
}

pub export fn gst_sample_copy(p: ?*const Sample) ?*Sample {
    return @ptrCast(mini.gst_mini_object_copy(asMini(p)));
}

pub export fn gst_clear_sample(slot: [*c]?*Sample) void {
    mini.gst_clear_mini_object(@ptrCast(slot));
}

pub export fn gst_sample_is_writable(p: ?*const Sample) c.gboolean {
    return mini.gst_mini_object_is_writable(asMini(p));
}

pub export fn gst_sample_make_writable(p: ?*Sample) ?*Sample {
    return @ptrCast(mini.gst_mini_object_make_writable(asMini(p)));
}

fn compareValues(a: [*c]const c.GValue, b: [*c]const c.GValue) callconv(.c) c.gint {
    const x = gst_sample_get_buffer(@ptrCast(@alignCast(c.g_value_get_boxed(a))));
    const y = gst_sample_get_buffer(@ptrCast(@alignCast(c.g_value_get_boxed(b))));
    return buffer.compareBuffers(x, y);
}

fn encoded(text: [*c]u8) [*c]u8 {
    const out = c.g_base64_encode(text, std.mem.len(text) + 1);
    _ = c.g_strdelimit(out, "=", '_');
    c.g_free(text);
    return out;
}

fn serializeValue(v: [*c]const c.GValue) callconv(.c) [*c]u8 {
    const s: ?*Sample = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
    const b = gst_sample_get_buffer(s);
    const buf_str = if (b != null) buffer.hexOf(b) else c.g_strdup("None");
    const caps = gst_sample_get_caps(s);
    const caps_str = if (caps != null) encoded(c.gst_caps_to_string(caps)) else c.g_strdup("None");
    const seg = gst_sample_get_segment(s);
    const seg_str = if (seg != null) encoded(segment.toStructureString(seg, false)) else c.g_strdup("None");
    const info = gst_sample_get_info(s);
    const info_str = if (info != null) encoded(c.gst_structure_to_string(info)) else c.g_strdup("None");
    defer for ([_][*c]u8{ buf_str, caps_str, seg_str, info_str }) |p| c.g_free(p);
    return c.g_strconcat(buf_str, ":", caps_str, ":", seg_str, ":", info_str, @as(?*anyopaque, null));
}

fn decodeInPlace(p: [*c]u8) void {
    _ = c.g_strdelimit(p, "_", '=');
    var n: c.gsize = 0;
    _ = c.g_base64_decode_inplace(p, &n);
}

fn deserializeValue(dest: [*c]c.GValue, s: [*c]const u8) callconv(.c) c.gboolean {
    const fields = c.g_strsplit(s, ":", -1);
    defer c.g_strfreev(fields);
    if (c.g_strv_length(fields) != 4) return 0;
    var bval = std.mem.zeroes(c.GValue);
    var sval = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&bval, buffer._gst_buffer_type);
    _ = c.g_value_init(&sval, segment.gst_segment_get_type());
    defer c.g_value_unset(&bval);
    defer c.g_value_unset(&sval);
    var caps: [*c]c.GstCaps = null;
    defer if (caps != null) c.gst_caps_unref(caps);
    if (buffer.fromHex(&bval, fields[0]) == 0) return 0;
    if (std.mem.orderZ(u8, fields[1], "None") != .eq) {
        decodeInPlace(fields[1]);
        caps = c.gst_caps_from_string(fields[1]);
        if (caps == null) return 0;
    }
    if (std.mem.orderZ(u8, fields[2], "None") != .eq) {
        decodeInPlace(fields[2]);
        if (!segment.fromStructureString(&sval, fields[2], false)) return 0;
    }
    var info: [*c]c.GstStructure = null;
    if (std.mem.orderZ(u8, fields[3], "None") != .eq) {
        decodeInPlace(fields[3]);
        info = c.gst_structure_from_string(fields[3], null);
        if (info == null) return 0;
    }
    const out = gst_sample_new(@ptrCast(@alignCast(c.g_value_get_boxed(&bval))), caps, @ptrCast(@alignCast(c.g_value_get_boxed(&sval))), info);
    c.g_value_take_boxed(dest, out);
    return 1;
}

var value_table: c.GstValueTable = .{};

pub fn initialize() void {
    _gst_sample_type = gst_sample_get_type();
}

pub fn registerValue() void {
    value_table = .{ .type = gst_sample_get_type(), .compare = compareValues, .serialize = serializeValue, .deserialize = deserializeValue, .hash = @import("vhash.zig").sample };
    value.gst_value_register(&value_table);
}
