const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const mini = @import("mini.zig");
const fields = @import("fields.zig");
const util = @import("util.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Message = c.GstMessage;
const Mini = c.GstMiniObject;
const Structure = c.GstStructure;
const Object = c.GstObject;
const NONE: u64 = std.math.maxInt(u64);
const ASYNC_DELIVERY: c.guint = c.GST_MINI_OBJECT_FLAG_LAST;

const Impl = extern struct {
    message: Message,
    s: [*c]Structure,
};

pub export var _gst_message_type: c.GType = 0;
var type_once: gtype.Once = .{};

const Name = struct { t: c.GstMessageType, name: [:0]const u8 };

const names = [_]Name{
    .{ .t = c.GST_MESSAGE_UNKNOWN, .name = "unknown" },
    .{ .t = c.GST_MESSAGE_EOS, .name = "eos" },
    .{ .t = c.GST_MESSAGE_ERROR, .name = "error" },
    .{ .t = c.GST_MESSAGE_WARNING, .name = "warning" },
    .{ .t = c.GST_MESSAGE_INFO, .name = "info" },
    .{ .t = c.GST_MESSAGE_TAG, .name = "tag" },
    .{ .t = c.GST_MESSAGE_BUFFERING, .name = "buffering" },
    .{ .t = c.GST_MESSAGE_STATE_CHANGED, .name = "state-changed" },
    .{ .t = c.GST_MESSAGE_STATE_DIRTY, .name = "state-dirty" },
    .{ .t = c.GST_MESSAGE_STEP_DONE, .name = "step-done" },
    .{ .t = c.GST_MESSAGE_CLOCK_PROVIDE, .name = "clock-provide" },
    .{ .t = c.GST_MESSAGE_CLOCK_LOST, .name = "clock-lost" },
    .{ .t = c.GST_MESSAGE_NEW_CLOCK, .name = "new-clock" },
    .{ .t = c.GST_MESSAGE_STRUCTURE_CHANGE, .name = "structure-change" },
    .{ .t = c.GST_MESSAGE_STREAM_STATUS, .name = "stream-status" },
    .{ .t = c.GST_MESSAGE_APPLICATION, .name = "application" },
    .{ .t = c.GST_MESSAGE_ELEMENT, .name = "element" },
    .{ .t = c.GST_MESSAGE_SEGMENT_START, .name = "segment-start" },
    .{ .t = c.GST_MESSAGE_SEGMENT_DONE, .name = "segment-done" },
    .{ .t = c.GST_MESSAGE_DURATION_CHANGED, .name = "duration-changed" },
    .{ .t = c.GST_MESSAGE_LATENCY, .name = "latency" },
    .{ .t = c.GST_MESSAGE_ASYNC_START, .name = "async-start" },
    .{ .t = c.GST_MESSAGE_ASYNC_DONE, .name = "async-done" },
    .{ .t = c.GST_MESSAGE_REQUEST_STATE, .name = "request-state" },
    .{ .t = c.GST_MESSAGE_STEP_START, .name = "step-start" },
    .{ .t = c.GST_MESSAGE_QOS, .name = "qos" },
    .{ .t = c.GST_MESSAGE_PROGRESS, .name = "progress" },
    .{ .t = c.GST_MESSAGE_TOC, .name = "toc" },
    .{ .t = c.GST_MESSAGE_RESET_TIME, .name = "reset-time" },
    .{ .t = c.GST_MESSAGE_STREAM_START, .name = "stream-start" },
    .{ .t = c.GST_MESSAGE_NEED_CONTEXT, .name = "need-context" },
    .{ .t = c.GST_MESSAGE_HAVE_CONTEXT, .name = "have-context" },
    .{ .t = c.GST_MESSAGE_DEVICE_ADDED, .name = "device-added" },
    .{ .t = c.GST_MESSAGE_DEVICE_REMOVED, .name = "device-removed" },
    .{ .t = c.GST_MESSAGE_DEVICE_CHANGED, .name = "device-changed" },
    .{ .t = c.GST_MESSAGE_PROPERTY_NOTIFY, .name = "property-notify" },
    .{ .t = c.GST_MESSAGE_STREAM_COLLECTION, .name = "stream-collection" },
    .{ .t = c.GST_MESSAGE_STREAMS_SELECTED, .name = "streams-selected" },
    .{ .t = c.GST_MESSAGE_REDIRECT, .name = "redirect" },
    .{ .t = c.GST_MESSAGE_INSTANT_RATE_REQUEST, .name = "instant-rate-request" },
};

var quarks: [names.len]c.GQuark = .{0} ** names.len;

fn impl(p: anytype) *Impl {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn asMini(p: anytype) [*c]Mini {
    return @ptrCast(@alignCast(@constCast(p)));
}

pub fn isMessage(p: anytype) bool {
    return p != null and asMini(p)[0].type == _gst_message_type;
}

fn kind(p: anytype) c.GstMessageType {
    return impl(p).message.type;
}

fn structureOf(p: anytype) [*c]Structure {
    return impl(p).s;
}

fn value(m: anytype, name: [*c]const u8) [*c]const c.GValue {
    return c.gst_structure_get_value(structureOf(m), name);
}

fn objectType(comptime symbol: [:0]const u8) c.GType {
    const t = gtype.weakType(symbol);
    return if (t != 0) t else c.gst_object_get_type();
}

pub export fn gst_message_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstMessage", @ptrCast(&mini.gst_mini_object_ref), @ptrCast(&mini.gst_mini_object_unref));
        }
    }.f);
}

pub fn initialize() void {
    for (names, 0..) |n, i| quarks[i] = c.g_quark_from_static_string(n.name.ptr);
    _gst_message_type = gst_message_get_type();
}

pub export fn gst_message_type_get_name(t: c.GstMessageType) [*c]const u8 {
    for (names) |n| if (n.t == t) return n.name.ptr;
    return "unknown";
}

pub export fn gst_message_type_to_quark(t: c.GstMessageType) c.GQuark {
    for (names, 0..) |n, i| if (n.t == t) return quarks[i];
    return 0;
}

fn disposeHook(m: [*c]Mini) callconv(.c) c.gboolean {
    if (m[0].flags & ASYNC_DELIVERY == 0) return 1;
    _ = mini.gst_mini_object_ref(m);
    const msg: [*c]Message = @ptrCast(@alignCast(m));
    c.g_mutex_lock(&msg[0].lock);
    c.g_cond_signal(&msg[0].cond);
    c.g_mutex_unlock(&msg[0].lock);
    return 0;
}

fn freeHook(m: [*c]Mini) callconv(.c) void {
    if (!check.that(m != null, "_gst_message_free", "message != NULL")) return;
    const msg = impl(m);
    if (msg.message.src != null) {
        c.gst_object_unref(msg.message.src);
        msg.message.src = null;
    }
    if (msg.s != null) {
        _ = c.gst_structure_set_parent_refcount(msg.s, null);
        c.gst_structure_free(msg.s);
    }
    c.g_free(m);
}

fn setup(m: *Impl, t: c.GstMessageType, src: [*c]Object) void {
    mini.gst_mini_object_init(asMini(m), 0, _gst_message_type, copyHook, disposeHook, freeHook);
    m.message.type = t;
    if (src != null) _ = c.gst_object_ref(src);
    m.message.src = src;
    m.message.timestamp = NONE;
    m.message.seqnum = util.gst_util_seqnum_next();
}

fn copyHook(src: [*c]const Mini) callconv(.c) [*c]Mini {
    const s = impl(src);
    const out: *Impl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Impl))));
    setup(out, s.message.type, s.message.src);
    out.message.timestamp = s.message.timestamp;
    out.message.seqnum = s.message.seqnum;
    if (s.s != null) {
        out.s = c.gst_structure_copy(s.s);
        _ = c.gst_structure_set_parent_refcount(out.s, &out.message.mini_object.refcount);
    }
    return asMini(out);
}

pub export fn gst_message_new_custom(t: c.GstMessageType, src: [*c]Object, s: [*c]Structure) [*c]Message {
    const m: *Impl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Impl))));
    if (s != null and c.gst_structure_set_parent_refcount(s, &m.message.mini_object.refcount) == 0) {
        c.g_free(m);
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "structure is already owned by another object");
        return null;
    }
    setup(m, t, src);
    m.s = s;
    return @ptrCast(m);
}

fn guard(comptime f: []const u8, m: [*c]Message) bool {
    return check.that(isMessage(m), f, "GST_IS_MESSAGE (message)");
}

fn guardType(comptime f: []const u8, m: [*c]Message, t: c.GstMessageType, comptime expr: []const u8) bool {
    if (!check.that(isMessage(m), f, "GST_IS_MESSAGE (message)")) return false;
    return check.that(kind(m) == t, f, "GST_MESSAGE_TYPE (message) == " ++ expr);
}

fn guardMsg(comptime f: []const u8, m: [*c]Message, t: c.GstMessageType, comptime expr: []const u8) bool {
    if (!check.that(isMessage(m), f, "GST_IS_MESSAGE (msg)")) return false;
    return check.that(kind(m) == t, f, "GST_MESSAGE_TYPE (msg) == " ++ expr);
}

pub export fn gst_message_get_seqnum(m: [*c]Message) c.guint32 {
    if (!guard("gst_message_get_seqnum", m)) return std.math.maxInt(u32);
    return m[0].seqnum;
}

pub export fn gst_message_set_seqnum(m: [*c]Message, seqnum: c.guint32) void {
    if (!guard("gst_message_set_seqnum", m)) return;
    if (!check.that(seqnum != c.GST_SEQNUM_INVALID, "gst_message_set_seqnum", "seqnum != GST_SEQNUM_INVALID")) return;
    m[0].seqnum = seqnum;
}

pub export fn gst_message_get_structure(m: [*c]Message) [*c]const Structure {
    if (!guard("gst_message_get_structure", m)) return null;
    return structureOf(m);
}

fn ensureStructure(m: [*c]Message) [*c]Structure {
    if (impl(m).s == null) {
        const s = c.gst_structure_new_static_str_empty(gst_message_type_get_name(kind(m)));
        _ = c.gst_structure_set_parent_refcount(s, &m[0].mini_object.refcount);
        impl(m).s = s;
    }
    return impl(m).s;
}

pub export fn gst_message_writable_structure(m: [*c]Message) [*c]Structure {
    if (!guard("gst_message_writable_structure", m)) return null;
    if (!check.that(gst_message_is_writable(m) != 0, "gst_message_writable_structure", "gst_message_is_writable (message)")) return null;
    return ensureStructure(m);
}

pub export fn gst_message_has_name(m: [*c]Message, name: [*c]const u8) c.gboolean {
    if (!guard("gst_message_has_name", m)) return 0;
    if (structureOf(m) == null) return 0;
    return c.gst_structure_has_name(structureOf(m), name);
}

fn attachDetails(m: [*c]Message, details: [*c]Structure) void {
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.gst_structure_get_type());
    c.g_value_take_boxed(&v, details);
    c.gst_structure_take_value(ensureStructure(m), "details", &v);
}

fn findDetails(m: [*c]Message, create: bool) [*c]Structure {
    const s = structureOf(m);
    if (s != null and c.gst_structure_has_field(s, "details") != 0) {
        const v = c.gst_structure_get_value(s, "details");
        if (v != null and v[0].g_type == c.gst_structure_get_type()) return @ptrCast(@alignCast(c.g_value_get_boxed(v)));
        return null;
    }
    if (!create) return null;
    const d = c.gst_structure_new_static_str_empty("message-details");
    attachDetails(m, d);
    return d;
}

pub export fn gst_message_set_details(m: [*c]Message, details: [*c]Structure) void {
    const f = "gst_message_set_details";
    if (!guard(f, m)) return;
    if (!check.that(gst_message_is_writable(m) != 0, f, "gst_message_is_writable (message)")) return;
    if (!check.that(details != null, f, "details")) return;
    if (structureOf(m) != null and c.gst_structure_has_field(structureOf(m), "details") != 0) {
        c.gst_structure_free(details);
        c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Message already has details");
        return;
    }
    attachDetails(m, details);
}

pub export fn gst_message_get_details(m: [*c]Message) [*c]const Structure {
    if (!guard("gst_message_get_details", m)) return null;
    return findDetails(m, false);
}

pub export fn gst_message_writable_details(m: [*c]Message) [*c]Structure {
    if (!guard("gst_message_writable_details", m)) return null;
    if (!check.that(gst_message_is_writable(m) != 0, "gst_message_writable_details", "gst_message_is_writable (message)")) return null;
    return findDetails(m, true);
}

pub export fn gst_message_new_eos(src: [*c]Object) [*c]Message {
    return gst_message_new_custom(c.GST_MESSAGE_EOS, src, null);
}

fn report(t: c.GstMessageType, comptime name: [:0]const u8, comptime word: []const u8, src: [*c]Object, err: [*c]c.GError, debug_in: [*c]const u8, details: [*c]Structure) [*c]Message {
    var debug = debug_in;
    if (debug != null and c.g_utf8_validate(debug, -1, null) == 0) {
        debug = null;
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Trying to set debug field of " ++ word ++ " message, but string is not valid UTF-8. Please file a bug.");
    }
    const s = c.gst_structure_new_static_str_empty(name);
    fields.set(s, "gerror", c.g_error_get_type(), err);
    fields.set(s, "debug", c.G_TYPE_STRING, debug);
    const m = gst_message_new_custom(t, src, s);
    if (details != null) attachDetails(m, details);
    return m;
}

pub export fn gst_message_new_error_with_details(src: [*c]Object, err: [*c]c.GError, debug: [*c]const u8, details: [*c]Structure) [*c]Message {
    return report(c.GST_MESSAGE_ERROR, "GstMessageError", "error", src, err, debug, details);
}

pub export fn gst_message_new_error(src: [*c]Object, err: [*c]c.GError, debug: [*c]const u8) [*c]Message {
    return gst_message_new_error_with_details(src, err, debug, null);
}

pub export fn gst_message_new_warning_with_details(src: [*c]Object, err: [*c]c.GError, debug: [*c]const u8, details: [*c]Structure) [*c]Message {
    return report(c.GST_MESSAGE_WARNING, "GstMessageWarning", "warning", src, err, debug, details);
}

pub export fn gst_message_new_warning(src: [*c]Object, err: [*c]c.GError, debug: [*c]const u8) [*c]Message {
    return gst_message_new_warning_with_details(src, err, debug, null);
}

pub export fn gst_message_new_info_with_details(src: [*c]Object, err: [*c]c.GError, debug: [*c]const u8, details: [*c]Structure) [*c]Message {
    return report(c.GST_MESSAGE_INFO, "GstMessageInfo", "info", src, err, debug, details);
}

pub export fn gst_message_new_info(src: [*c]Object, err: [*c]c.GError, debug: [*c]const u8) [*c]Message {
    return gst_message_new_info_with_details(src, err, debug, null);
}

fn parseReport(m: [*c]Message, err: [*c][*c]c.GError, debug: [*c][*c]u8) void {
    _ = c.gst_structure_get(structureOf(m), "gerror", c.g_error_get_type(), err, "debug", c.G_TYPE_STRING, debug, @as(?*anyopaque, null));
}

pub export fn gst_message_parse_error(m: [*c]Message, err: [*c][*c]c.GError, debug: [*c][*c]u8) void {
    if (!guardType("gst_message_parse_error", m, c.GST_MESSAGE_ERROR, "GST_MESSAGE_ERROR")) return;
    parseReport(m, err, debug);
}

pub export fn gst_message_parse_warning(m: [*c]Message, err: [*c][*c]c.GError, debug: [*c][*c]u8) void {
    if (!guardType("gst_message_parse_warning", m, c.GST_MESSAGE_WARNING, "GST_MESSAGE_WARNING")) return;
    parseReport(m, err, debug);
}

pub export fn gst_message_parse_info(m: [*c]Message, err: [*c][*c]c.GError, debug: [*c][*c]u8) void {
    if (!guardType("gst_message_parse_info", m, c.GST_MESSAGE_INFO, "GST_MESSAGE_INFO")) return;
    parseReport(m, err, debug);
}

fn reportDetails(comptime f: []const u8, m: [*c]Message, t: c.GstMessageType, comptime expr: []const u8, out: [*c][*c]const Structure, writable: bool) void {
    if (!guardType(f, m, t, expr)) return;
    if (writable and !check.that(gst_message_is_writable(m) != 0, f, "gst_message_is_writable (message)")) return;
    if (!check.that(out != null, f, "structure != NULL")) return;
    out.* = findDetails(m, writable);
}

pub export fn gst_message_parse_error_details(m: [*c]Message, out: [*c][*c]const Structure) void {
    reportDetails("gst_message_parse_error_details", m, c.GST_MESSAGE_ERROR, "GST_MESSAGE_ERROR", out, false);
}

pub export fn gst_message_parse_error_writable_details(m: [*c]Message, out: [*c][*c]Structure) void {
    reportDetails("gst_message_parse_error_writable_details", m, c.GST_MESSAGE_ERROR, "GST_MESSAGE_ERROR", @ptrCast(out), true);
}

pub export fn gst_message_parse_warning_details(m: [*c]Message, out: [*c][*c]const Structure) void {
    reportDetails("gst_message_parse_warning_details", m, c.GST_MESSAGE_WARNING, "GST_MESSAGE_WARNING", out, false);
}

pub export fn gst_message_parse_warning_writable_details(m: [*c]Message, out: [*c][*c]Structure) void {
    reportDetails("gst_message_parse_warning_writable_details", m, c.GST_MESSAGE_WARNING, "GST_MESSAGE_WARNING", @ptrCast(out), true);
}

pub export fn gst_message_parse_info_details(m: [*c]Message, out: [*c][*c]const Structure) void {
    reportDetails("gst_message_parse_info_details", m, c.GST_MESSAGE_INFO, "GST_MESSAGE_INFO", out, false);
}

pub export fn gst_message_parse_info_writable_details(m: [*c]Message, out: [*c][*c]Structure) void {
    reportDetails("gst_message_parse_info_writable_details", m, c.GST_MESSAGE_INFO, "GST_MESSAGE_INFO", @ptrCast(out), true);
}

pub export fn gst_message_new_tag(src: [*c]Object, tags: [*c]c.GstTagList) [*c]Message {
    if (!check.that(tags != null and asMini(tags)[0].type == c.gst_tag_list_get_type(), "gst_message_new_tag", "GST_IS_TAG_LIST (tag_list)")) return null;
    const s = c.gst_structure_new_static_str_empty("GstMessageTag");
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.gst_tag_list_get_type());
    c.g_value_take_boxed(&v, tags);
    c.gst_structure_take_value(s, "taglist", &v);
    return gst_message_new_custom(c.GST_MESSAGE_TAG, src, s);
}

pub export fn gst_message_parse_tag(m: [*c]Message, tags: [*c][*c]c.GstTagList) void {
    if (!guardType("gst_message_parse_tag", m, c.GST_MESSAGE_TAG, "GST_MESSAGE_TAG")) return;
    if (!check.that(tags != null, "gst_message_parse_tag", "tag_list != NULL")) return;
    _ = c.gst_structure_get(structureOf(m), "taglist", c.gst_tag_list_get_type(), tags, @as(?*anyopaque, null));
}

pub export fn gst_message_new_buffering(src: [*c]Object, percent: c.gint) [*c]Message {
    if (!check.that(percent >= 0 and percent <= 100, "gst_message_new_buffering", "percent >= 0 && percent <= 100")) return null;
    const s = c.gst_structure_new_static_str_empty("GstMessageBuffering");
    fields.set(s, "buffer-percent", c.G_TYPE_INT, percent);
    fields.set(s, "buffering-mode", c.gst_buffering_mode_get_type(), c.GST_BUFFERING_STREAM);
    fields.set(s, "avg-in-rate", c.G_TYPE_INT, -1);
    fields.set(s, "avg-out-rate", c.G_TYPE_INT, -1);
    fields.set(s, "buffering-left", c.G_TYPE_INT64, @as(i64, if (percent == 100) 0 else -1));
    return gst_message_new_custom(c.GST_MESSAGE_BUFFERING, src, s);
}

pub export fn gst_message_parse_buffering(m: [*c]Message, percent: [*c]c.gint) void {
    if (!guardType("gst_message_parse_buffering", m, c.GST_MESSAGE_BUFFERING, "GST_MESSAGE_BUFFERING")) return;
    if (percent != null) percent.* = c.g_value_get_int(value(m, "buffer-percent"));
}

pub export fn gst_message_set_buffering_stats(m: [*c]Message, mode: c.GstBufferingMode, avg_in: c.gint, avg_out: c.gint, left: c.gint64) void {
    if (!guardType("gst_message_set_buffering_stats", m, c.GST_MESSAGE_BUFFERING, "GST_MESSAGE_BUFFERING")) return;
    const s = structureOf(m);
    fields.set(s, "buffering-mode", c.gst_buffering_mode_get_type(), mode);
    fields.set(s, "avg-in-rate", c.G_TYPE_INT, avg_in);
    fields.set(s, "avg-out-rate", c.G_TYPE_INT, avg_out);
    fields.set(s, "buffering-left", c.G_TYPE_INT64, left);
}

pub export fn gst_message_parse_buffering_stats(m: [*c]Message, mode: [*c]c.GstBufferingMode, avg_in: [*c]c.gint, avg_out: [*c]c.gint, left: [*c]c.gint64) void {
    if (!check.that(kind(m) == c.GST_MESSAGE_BUFFERING, "gst_message_parse_buffering_stats", "GST_MESSAGE_TYPE (message) == GST_MESSAGE_BUFFERING")) return;
    if (mode != null) mode.* = @intCast(c.g_value_get_enum(value(m, "buffering-mode")));
    if (avg_in != null) avg_in.* = c.g_value_get_int(value(m, "avg-in-rate"));
    if (avg_out != null) avg_out.* = c.g_value_get_int(value(m, "avg-out-rate"));
    if (left != null) left.* = c.g_value_get_int64(value(m, "buffering-left"));
}

pub export fn gst_message_new_state_changed(src: [*c]Object, old: c.GstState, new: c.GstState, pending: c.GstState) [*c]Message {
    const s = c.gst_structure_new_static_str_empty("GstMessageStateChanged");
    fields.set(s, "old-state", c.gst_state_get_type(), old);
    fields.set(s, "new-state", c.gst_state_get_type(), new);
    fields.set(s, "pending-state", c.gst_state_get_type(), pending);
    return gst_message_new_custom(c.GST_MESSAGE_STATE_CHANGED, src, s);
}

pub export fn gst_message_parse_state_changed(m: [*c]Message, old: [*c]c.GstState, new: [*c]c.GstState, pending: [*c]c.GstState) void {
    if (!guardType("gst_message_parse_state_changed", m, c.GST_MESSAGE_STATE_CHANGED, "GST_MESSAGE_STATE_CHANGED")) return;
    if (old != null) old.* = @intCast(c.g_value_get_enum(value(m, "old-state")));
    if (new != null) new.* = @intCast(c.g_value_get_enum(value(m, "new-state")));
    if (pending != null) pending.* = @intCast(c.g_value_get_enum(value(m, "pending-state")));
}

pub export fn gst_message_new_state_dirty(src: [*c]Object) [*c]Message {
    return gst_message_new_custom(c.GST_MESSAGE_STATE_DIRTY, src, null);
}

fn clockType() c.GType {
    return objectType("gst_clock_get_type");
}

pub export fn gst_message_new_clock_provide(src: [*c]Object, clock: [*c]c.GstClock, ready: c.gboolean) [*c]Message {
    const s = c.gst_structure_new_static_str_empty("GstMessageClockProvide");
    fields.set(s, "clock", clockType(), clock);
    fields.set(s, "ready", c.G_TYPE_BOOLEAN, ready);
    return gst_message_new_custom(c.GST_MESSAGE_CLOCK_PROVIDE, src, s);
}

pub export fn gst_message_new_clock_lost(src: [*c]Object, clock: [*c]c.GstClock) [*c]Message {
    const s = c.gst_structure_new_static_str_empty("GstMessageClockLost");
    fields.set(s, "clock", clockType(), clock);
    return gst_message_new_custom(c.GST_MESSAGE_CLOCK_LOST, src, s);
}

pub export fn gst_message_new_new_clock(src: [*c]Object, clock: [*c]c.GstClock) [*c]Message {
    const s = c.gst_structure_new_static_str_empty("GstMessageNewClock");
    fields.set(s, "clock", clockType(), clock);
    return gst_message_new_custom(c.GST_MESSAGE_NEW_CLOCK, src, s);
}

fn clockValue(comptime f: []const u8, m: [*c]Message) ?*const c.GValue {
    const v = value(m, "clock");
    if (!check.that(v != null, f, "clock_gvalue != NULL")) return null;
    if (!check.that(v[0].g_type == clockType(), f, "G_VALUE_TYPE (clock_gvalue) == GST_TYPE_CLOCK")) return null;
    return v;
}

pub export fn gst_message_parse_clock_provide(m: [*c]Message, clock: [*c][*c]c.GstClock, ready: [*c]c.gboolean) void {
    const f = "gst_message_parse_clock_provide";
    if (!guardType(f, m, c.GST_MESSAGE_CLOCK_PROVIDE, "GST_MESSAGE_CLOCK_PROVIDE")) return;
    const v = clockValue(f, m) orelse return;
    if (ready != null) ready.* = c.g_value_get_boolean(value(m, "ready"));
    if (clock != null) clock.* = @ptrCast(@alignCast(c.g_value_get_object(v)));
}

pub export fn gst_message_parse_clock_lost(m: [*c]Message, clock: [*c][*c]c.GstClock) void {
    const f = "gst_message_parse_clock_lost";
    if (!guardType(f, m, c.GST_MESSAGE_CLOCK_LOST, "GST_MESSAGE_CLOCK_LOST")) return;
    const v = clockValue(f, m) orelse return;
    if (clock != null) clock.* = @ptrCast(@alignCast(c.g_value_get_object(v)));
}

pub export fn gst_message_parse_new_clock(m: [*c]Message, clock: [*c][*c]c.GstClock) void {
    const f = "gst_message_parse_new_clock";
    if (!guardType(f, m, c.GST_MESSAGE_NEW_CLOCK, "GST_MESSAGE_NEW_CLOCK")) return;
    const v = clockValue(f, m) orelse return;
    if (clock != null) clock.* = @ptrCast(@alignCast(c.g_value_get_object(v)));
}

fn isA(p: anytype, comptime symbol: [:0]const u8) bool {
    const t = gtype.weakType(symbol);
    return t != 0 and gtype.instanceOf(p, t);
}

pub export fn gst_message_new_structure_change(src: [*c]Object, t: c.GstStructureChangeType, owner: [*c]c.GstElement, busy: c.gboolean) [*c]Message {
    const f = "gst_message_new_structure_change";
    if (!check.that(isA(src, "gst_pad_get_type"), f, "GST_IS_PAD (src)")) return null;
    if (!check.that(isA(owner, "gst_element_get_type"), f, "GST_IS_ELEMENT (owner)")) return null;
    const s = c.gst_structure_new_static_str_empty("GstMessageStructureChange");
    fields.set(s, "type", c.gst_structure_change_type_get_type(), t);
    fields.set(s, "owner", objectType("gst_element_get_type"), owner);
    fields.set(s, "busy", c.G_TYPE_BOOLEAN, busy);
    return gst_message_new_custom(c.GST_MESSAGE_STRUCTURE_CHANGE, src, s);
}

pub export fn gst_message_parse_structure_change(m: [*c]Message, t: [*c]c.GstStructureChangeType, owner: [*c][*c]c.GstElement, busy: [*c]c.gboolean) void {
    const f = "gst_message_parse_structure_change";
    if (!guardType(f, m, c.GST_MESSAGE_STRUCTURE_CHANGE, "GST_MESSAGE_STRUCTURE_CHANGE")) return;
    const v = value(m, "owner");
    if (!check.that(v != null, f, "owner_gvalue != NULL")) return;
    if (!check.that(v[0].g_type == objectType("gst_element_get_type"), f, "G_VALUE_TYPE (owner_gvalue) == GST_TYPE_ELEMENT")) return;
    if (t != null) t.* = @intCast(c.g_value_get_enum(value(m, "type")));
    if (owner != null) owner.* = @ptrCast(@alignCast(c.g_value_get_object(v)));
    if (busy != null) busy.* = c.g_value_get_boolean(value(m, "busy"));
}

fn position(comptime name: [:0]const u8, t: c.GstMessageType, src: [*c]Object, format: c.GstFormat, pos: c.gint64) [*c]Message {
    const s = c.gst_structure_new_static_str_empty(name);
    fields.set(s, "format", c.gst_format_get_type(), format);
    fields.set(s, "position", c.G_TYPE_INT64, pos);
    return gst_message_new_custom(t, src, s);
}

pub export fn gst_message_new_segment_start(src: [*c]Object, format: c.GstFormat, pos: c.gint64) [*c]Message {
    return position("GstMessageSegmentStart", c.GST_MESSAGE_SEGMENT_START, src, format, pos);
}

pub export fn gst_message_new_segment_done(src: [*c]Object, format: c.GstFormat, pos: c.gint64) [*c]Message {
    return position("GstMessageSegmentDone", c.GST_MESSAGE_SEGMENT_DONE, src, format, pos);
}

fn parsePosition(m: [*c]Message, format: [*c]c.GstFormat, pos: [*c]c.gint64) void {
    if (format != null) format.* = @intCast(c.g_value_get_enum(value(m, "format")));
    if (pos != null) pos.* = c.g_value_get_int64(value(m, "position"));
}

pub export fn gst_message_parse_segment_start(m: [*c]Message, format: [*c]c.GstFormat, pos: [*c]c.gint64) void {
    if (!guardType("gst_message_parse_segment_start", m, c.GST_MESSAGE_SEGMENT_START, "GST_MESSAGE_SEGMENT_START")) return;
    parsePosition(m, format, pos);
}

pub export fn gst_message_parse_segment_done(m: [*c]Message, format: [*c]c.GstFormat, pos: [*c]c.gint64) void {
    if (!guardType("gst_message_parse_segment_done", m, c.GST_MESSAGE_SEGMENT_DONE, "GST_MESSAGE_SEGMENT_DONE")) return;
    parsePosition(m, format, pos);
}

pub export fn gst_message_new_application(src: [*c]Object, s: [*c]Structure) [*c]Message {
    if (!check.that(s != null, "gst_message_new_application", "structure != NULL")) return null;
    return gst_message_new_custom(c.GST_MESSAGE_APPLICATION, src, s);
}

pub export fn gst_message_new_element(src: [*c]Object, s: [*c]Structure) [*c]Message {
    if (!check.that(s != null, "gst_message_new_element", "structure != NULL")) return null;
    return gst_message_new_custom(c.GST_MESSAGE_ELEMENT, src, s);
}

pub export fn gst_message_new_duration_changed(src: [*c]Object) [*c]Message {
    return gst_message_new_custom(c.GST_MESSAGE_DURATION_CHANGED, src, c.gst_structure_new_static_str_empty("GstMessageDurationChanged"));
}

pub export fn gst_message_new_async_start(src: [*c]Object) [*c]Message {
    return gst_message_new_custom(c.GST_MESSAGE_ASYNC_START, src, null);
}

pub export fn gst_message_new_async_done(src: [*c]Object, running: c.GstClockTime) [*c]Message {
    const s = c.gst_structure_new_static_str_empty("GstMessageAsyncDone");
    fields.set(s, "running-time", c.G_TYPE_UINT64, running);
    return gst_message_new_custom(c.GST_MESSAGE_ASYNC_DONE, src, s);
}

pub export fn gst_message_parse_async_done(m: [*c]Message, running: [*c]c.GstClockTime) void {
    if (!guardType("gst_message_parse_async_done", m, c.GST_MESSAGE_ASYNC_DONE, "GST_MESSAGE_ASYNC_DONE")) return;
    if (running != null) running.* = c.g_value_get_uint64(value(m, "running-time"));
}

pub export fn gst_message_new_latency(src: [*c]Object) [*c]Message {
    return gst_message_new_custom(c.GST_MESSAGE_LATENCY, src, null);
}

pub export fn gst_message_new_request_state(src: [*c]Object, state: c.GstState) [*c]Message {
    const s = c.gst_structure_new_static_str_empty("GstMessageRequestState");
    fields.set(s, "new-state", c.gst_state_get_type(), state);
    return gst_message_new_custom(c.GST_MESSAGE_REQUEST_STATE, src, s);
}

pub export fn gst_message_parse_request_state(m: [*c]Message, state: [*c]c.GstState) void {
    if (!guardType("gst_message_parse_request_state", m, c.GST_MESSAGE_REQUEST_STATE, "GST_MESSAGE_REQUEST_STATE")) return;
    if (state != null) state.* = @intCast(c.g_value_get_enum(value(m, "new-state")));
}

pub export fn gst_message_new_stream_status(src: [*c]Object, t: c.GstStreamStatusType, owner: [*c]c.GstElement) [*c]Message {
    const s = c.gst_structure_new_static_str_empty("GstMessageStreamStatus");
    fields.set(s, "type", c.gst_stream_status_type_get_type(), t);
    fields.set(s, "owner", objectType("gst_element_get_type"), owner);
    return gst_message_new_custom(c.GST_MESSAGE_STREAM_STATUS, src, s);
}

pub export fn gst_message_parse_stream_status(m: [*c]Message, t: [*c]c.GstStreamStatusType, owner: [*c][*c]c.GstElement) void {
    const f = "gst_message_parse_stream_status";
    if (!guardType(f, m, c.GST_MESSAGE_STREAM_STATUS, "GST_MESSAGE_STREAM_STATUS")) return;
    const v = value(m, "owner");
    if (!check.that(v != null, f, "owner_gvalue != NULL")) return;
    if (t != null) t.* = @intCast(c.g_value_get_enum(value(m, "type")));
    if (owner != null) owner.* = @ptrCast(@alignCast(c.g_value_get_object(v)));
}

pub export fn gst_message_set_stream_status_object(m: [*c]Message, obj: [*c]const c.GValue) void {
    if (!guardType("gst_message_set_stream_status_object", m, c.GST_MESSAGE_STREAM_STATUS, "GST_MESSAGE_STREAM_STATUS")) return;
    c.gst_structure_set_value_static_str(structureOf(m), "object", obj);
}

pub export fn gst_message_get_stream_status_object(m: [*c]Message) [*c]const c.GValue {
    if (!guardType("gst_message_get_stream_status_object", m, c.GST_MESSAGE_STREAM_STATUS, "GST_MESSAGE_STREAM_STATUS")) return null;
    return value(m, "object");
}

pub export fn gst_message_new_step_done(src: [*c]Object, format: c.GstFormat, amount: c.guint64, rate: c.gdouble, flush: c.gboolean, intermediate: c.gboolean, duration: c.guint64, eos: c.gboolean) [*c]Message {
    const s = c.gst_structure_new_static_str_empty("GstMessageStepDone");
    fields.set(s, "format", c.gst_format_get_type(), format);
    fields.set(s, "amount", c.G_TYPE_UINT64, amount);
    fields.set(s, "rate", c.G_TYPE_DOUBLE, rate);
    fields.set(s, "flush", c.G_TYPE_BOOLEAN, flush);
    fields.set(s, "intermediate", c.G_TYPE_BOOLEAN, intermediate);
    fields.set(s, "duration", c.G_TYPE_UINT64, duration);
    fields.set(s, "eos", c.G_TYPE_BOOLEAN, eos);
    return gst_message_new_custom(c.GST_MESSAGE_STEP_DONE, src, s);
}

pub export fn gst_message_parse_step_done(m: [*c]Message, format: [*c]c.GstFormat, amount: [*c]c.guint64, rate: [*c]c.gdouble, flush: [*c]c.gboolean, intermediate: [*c]c.gboolean, duration: [*c]c.guint64, eos: [*c]c.gboolean) void {
    if (!guardType("gst_message_parse_step_done", m, c.GST_MESSAGE_STEP_DONE, "GST_MESSAGE_STEP_DONE")) return;
    _ = c.gst_structure_get(structureOf(m), "format", c.gst_format_get_type(), format, "amount", c.G_TYPE_UINT64, amount, "rate", c.G_TYPE_DOUBLE, rate, "flush", c.G_TYPE_BOOLEAN, flush, "intermediate", c.G_TYPE_BOOLEAN, intermediate, "duration", c.G_TYPE_UINT64, duration, "eos", c.G_TYPE_BOOLEAN, eos, @as(?*anyopaque, null));
}

pub export fn gst_message_new_step_start(src: [*c]Object, active: c.gboolean, format: c.GstFormat, amount: c.guint64, rate: c.gdouble, flush: c.gboolean, intermediate: c.gboolean) [*c]Message {
    const s = c.gst_structure_new_static_str_empty("GstMessageStepStart");
    fields.set(s, "active", c.G_TYPE_BOOLEAN, active);
    fields.set(s, "format", c.gst_format_get_type(), format);
    fields.set(s, "amount", c.G_TYPE_UINT64, amount);
    fields.set(s, "rate", c.G_TYPE_DOUBLE, rate);
    fields.set(s, "flush", c.G_TYPE_BOOLEAN, flush);
    fields.set(s, "intermediate", c.G_TYPE_BOOLEAN, intermediate);
    return gst_message_new_custom(c.GST_MESSAGE_STEP_START, src, s);
}

pub export fn gst_message_parse_step_start(m: [*c]Message, active: [*c]c.gboolean, format: [*c]c.GstFormat, amount: [*c]c.guint64, rate: [*c]c.gdouble, flush: [*c]c.gboolean, intermediate: [*c]c.gboolean) void {
    if (!guardType("gst_message_parse_step_start", m, c.GST_MESSAGE_STEP_START, "GST_MESSAGE_STEP_START")) return;
    _ = c.gst_structure_get(structureOf(m), "active", c.G_TYPE_BOOLEAN, active, "format", c.gst_format_get_type(), format, "amount", c.G_TYPE_UINT64, amount, "rate", c.G_TYPE_DOUBLE, rate, "flush", c.G_TYPE_BOOLEAN, flush, "intermediate", c.G_TYPE_BOOLEAN, intermediate, @as(?*anyopaque, null));
}

pub export fn gst_message_new_qos(src: [*c]Object, live: c.gboolean, running: c.guint64, stream: c.guint64, ts: c.guint64, duration: c.guint64) [*c]Message {
    const s = c.gst_structure_new_static_str_empty("GstMessageQOS");
    fields.set(s, "live", c.G_TYPE_BOOLEAN, live);
    fields.set(s, "running-time", c.G_TYPE_UINT64, running);
    fields.set(s, "stream-time", c.G_TYPE_UINT64, stream);
    fields.set(s, "timestamp", c.G_TYPE_UINT64, ts);
    fields.set(s, "duration", c.G_TYPE_UINT64, duration);
    fields.set(s, "jitter", c.G_TYPE_INT64, 0);
    fields.set(s, "proportion", c.G_TYPE_DOUBLE, @as(f64, 1.0));
    fields.set(s, "quality", c.G_TYPE_INT, 1000000);
    fields.set(s, "format", c.gst_format_get_type(), c.GST_FORMAT_UNDEFINED);
    fields.set(s, "processed", c.G_TYPE_UINT64, NONE);
    fields.set(s, "dropped", c.G_TYPE_UINT64, NONE);
    return gst_message_new_custom(c.GST_MESSAGE_QOS, src, s);
}

pub export fn gst_message_set_qos_values(m: [*c]Message, jitter: c.gint64, proportion: c.gdouble, quality: c.gint) void {
    if (!guardType("gst_message_set_qos_values", m, c.GST_MESSAGE_QOS, "GST_MESSAGE_QOS")) return;
    const s = structureOf(m);
    fields.set(s, "jitter", c.G_TYPE_INT64, jitter);
    fields.set(s, "proportion", c.G_TYPE_DOUBLE, proportion);
    fields.set(s, "quality", c.G_TYPE_INT, quality);
}

pub export fn gst_message_set_qos_stats(m: [*c]Message, format: c.GstFormat, processed: c.guint64, dropped: c.guint64) void {
    if (!guardType("gst_message_set_qos_stats", m, c.GST_MESSAGE_QOS, "GST_MESSAGE_QOS")) return;
    const s = structureOf(m);
    fields.set(s, "format", c.gst_format_get_type(), format);
    fields.set(s, "processed", c.G_TYPE_UINT64, processed);
    fields.set(s, "dropped", c.G_TYPE_UINT64, dropped);
}

pub export fn gst_message_parse_qos(m: [*c]Message, live: [*c]c.gboolean, running: [*c]c.guint64, stream: [*c]c.guint64, ts: [*c]c.guint64, duration: [*c]c.guint64) void {
    if (!guardType("gst_message_parse_qos", m, c.GST_MESSAGE_QOS, "GST_MESSAGE_QOS")) return;
    _ = c.gst_structure_get(structureOf(m), "live", c.G_TYPE_BOOLEAN, live, "running-time", c.G_TYPE_UINT64, running, "stream-time", c.G_TYPE_UINT64, stream, "timestamp", c.G_TYPE_UINT64, ts, "duration", c.G_TYPE_UINT64, duration, @as(?*anyopaque, null));
}

pub export fn gst_message_parse_qos_values(m: [*c]Message, jitter: [*c]c.gint64, proportion: [*c]c.gdouble, quality: [*c]c.gint) void {
    if (!guardType("gst_message_parse_qos_values", m, c.GST_MESSAGE_QOS, "GST_MESSAGE_QOS")) return;
    _ = c.gst_structure_get(structureOf(m), "jitter", c.G_TYPE_INT64, jitter, "proportion", c.G_TYPE_DOUBLE, proportion, "quality", c.G_TYPE_INT, quality, @as(?*anyopaque, null));
}

pub export fn gst_message_parse_qos_stats(m: [*c]Message, format: [*c]c.GstFormat, processed: [*c]c.guint64, dropped: [*c]c.guint64) void {
    if (!guardType("gst_message_parse_qos_stats", m, c.GST_MESSAGE_QOS, "GST_MESSAGE_QOS")) return;
    _ = c.gst_structure_get(structureOf(m), "format", c.gst_format_get_type(), format, "processed", c.G_TYPE_UINT64, processed, "dropped", c.G_TYPE_UINT64, dropped, @as(?*anyopaque, null));
}

pub export fn gst_message_new_progress(src: [*c]Object, t: c.GstProgressType, code: [*c]const u8, text: [*c]const u8) [*c]Message {
    const f = "gst_message_new_progress";
    if (!check.that(code != null, f, "code != NULL")) return null;
    if (!check.that(text != null, f, "text != NULL")) return null;
    const percent: c.gint = if (t == c.GST_PROGRESS_TYPE_START or t == c.GST_PROGRESS_TYPE_CONTINUE) 0 else 100;
    const s = c.gst_structure_new_static_str_empty("GstMessageProgress");
    fields.set(s, "type", c.gst_progress_type_get_type(), t);
    fields.set(s, "code", c.G_TYPE_STRING, code);
    fields.set(s, "text", c.G_TYPE_STRING, text);
    fields.set(s, "percent", c.G_TYPE_INT, percent);
    fields.set(s, "timeout", c.G_TYPE_INT, -1);
    return gst_message_new_custom(c.GST_MESSAGE_PROGRESS, src, s);
}

pub export fn gst_message_parse_progress(m: [*c]Message, t: [*c]c.GstProgressType, code: [*c][*c]u8, text: [*c][*c]u8) void {
    if (!guardType("gst_message_parse_progress", m, c.GST_MESSAGE_PROGRESS, "GST_MESSAGE_PROGRESS")) return;
    _ = c.gst_structure_get(structureOf(m), "type", c.gst_progress_type_get_type(), t, "code", c.G_TYPE_STRING, code, "text", c.G_TYPE_STRING, text, @as(?*anyopaque, null));
}

pub export fn gst_message_new_toc(src: [*c]Object, toc: ?*c.GstToc, updated: c.gboolean) [*c]Message {
    if (!check.that(toc != null, "gst_message_new_toc", "toc != NULL")) return null;
    const s = c.gst_structure_new_static_str_empty("GstMessageToc");
    fields.set(s, "toc", c.gst_toc_get_type(), toc);
    fields.set(s, "updated", c.G_TYPE_BOOLEAN, updated);
    return gst_message_new_custom(c.GST_MESSAGE_TOC, src, s);
}

pub export fn gst_message_parse_toc(m: [*c]Message, toc: [*c]?*c.GstToc, updated: [*c]c.gboolean) void {
    if (!guardType("gst_message_parse_toc", m, c.GST_MESSAGE_TOC, "GST_MESSAGE_TOC")) return;
    if (!check.that(toc != null, "gst_message_parse_toc", "toc != NULL")) return;
    _ = c.gst_structure_get(structureOf(m), "toc", c.gst_toc_get_type(), toc, "updated", c.G_TYPE_BOOLEAN, updated, @as(?*anyopaque, null));
}

pub export fn gst_message_new_reset_time(src: [*c]Object, running: c.GstClockTime) [*c]Message {
    if (!check.that(running != NONE, "gst_message_new_reset_time", "GST_CLOCK_TIME_IS_VALID (running_time)")) return null;
    const s = c.gst_structure_new_static_str_empty("GstMessageResetTime");
    fields.set(s, "running-time", c.G_TYPE_UINT64, running);
    return gst_message_new_custom(c.GST_MESSAGE_RESET_TIME, src, s);
}

pub export fn gst_message_parse_reset_time(m: [*c]Message, running: [*c]c.GstClockTime) void {
    if (!guardType("gst_message_parse_reset_time", m, c.GST_MESSAGE_RESET_TIME, "GST_MESSAGE_RESET_TIME")) return;
    if (running != null) running.* = c.g_value_get_uint64(value(m, "running-time"));
}

pub export fn gst_message_new_stream_start(src: [*c]Object) [*c]Message {
    return gst_message_new_custom(c.GST_MESSAGE_STREAM_START, src, c.gst_structure_new_static_str_empty("GstMessageStreamStart"));
}

pub export fn gst_message_set_group_id(m: [*c]Message, group: c.guint) void {
    const f = "gst_message_set_group_id";
    if (!guardType(f, m, c.GST_MESSAGE_STREAM_START, "GST_MESSAGE_STREAM_START")) return;
    if (!check.that(gst_message_is_writable(m) != 0, f, "gst_message_is_writable (message)")) return;
    if (!check.that(group != c.GST_GROUP_ID_INVALID, f, "group_id != GST_GROUP_ID_INVALID")) return;
    fields.set(structureOf(m), "group-id", c.G_TYPE_UINT, group);
}

pub export fn gst_message_parse_group_id(m: [*c]Message, group: [*c]c.guint) c.gboolean {
    if (!guardType("gst_message_parse_group_id", m, c.GST_MESSAGE_STREAM_START, "GST_MESSAGE_STREAM_START")) return 0;
    if (group == null) return 1;
    group.* = 0;
    const v = value(m, "group-id");
    if (v == null) return 0;
    group.* = c.g_value_get_uint(v);
    return 1;
}

pub export fn gst_message_new_need_context(src: [*c]Object, ctx_type: [*c]const u8) [*c]Message {
    if (!check.that(ctx_type != null, "gst_message_new_need_context", "context_type != NULL")) return null;
    const s = c.gst_structure_new_static_str_empty("GstMessageNeedContext");
    fields.set(s, "context-type", c.G_TYPE_STRING, ctx_type);
    return gst_message_new_custom(c.GST_MESSAGE_NEED_CONTEXT, src, s);
}

pub export fn gst_message_parse_context_type(m: [*c]Message, ctx_type: [*c][*c]const u8) c.gboolean {
    if (!check.that(kind(m) == c.GST_MESSAGE_NEED_CONTEXT, "gst_message_parse_context_type", "GST_MESSAGE_TYPE (message) == GST_MESSAGE_NEED_CONTEXT")) return 0;
    if (ctx_type != null) ctx_type.* = c.g_value_get_string(value(m, "context-type"));
    return 1;
}

pub export fn gst_message_new_have_context(src: [*c]Object, ctx: ?*c.GstContext) [*c]Message {
    const s = c.gst_structure_new_static_str_empty("GstMessageHaveContext");
    fields.set(s, "context", c.gst_context_get_type(), ctx);
    const m = gst_message_new_custom(c.GST_MESSAGE_HAVE_CONTEXT, src, s);
    c.gst_context_unref(ctx);
    return m;
}

pub export fn gst_message_parse_have_context(m: [*c]Message, ctx: [*c]?*c.GstContext) void {
    if (!guardType("gst_message_parse_have_context", m, c.GST_MESSAGE_HAVE_CONTEXT, "GST_MESSAGE_HAVE_CONTEXT")) return;
    if (ctx != null) _ = c.gst_structure_get(structureOf(m), "context", c.gst_context_get_type(), ctx, @as(?*anyopaque, null));
}

fn deviceType() c.GType {
    return objectType("gst_device_get_type");
}

fn device(comptime f: []const u8, comptime name: [:0]const u8, dev: [*c]c.GstDevice) ?[*c]Structure {
    if (!check.that(dev != null, f, "device != NULL")) return null;
    if (!check.that(isA(dev, "gst_device_get_type"), f, "GST_IS_DEVICE (device)")) return null;
    const s = c.gst_structure_new_static_str_empty(name);
    fields.set(s, "device", deviceType(), dev);
    return s;
}

pub export fn gst_message_new_device_added(src: [*c]Object, dev: [*c]c.GstDevice) [*c]Message {
    const s = device("gst_message_new_device_added", "GstMessageDeviceAdded", dev) orelse return null;
    return gst_message_new_custom(c.GST_MESSAGE_DEVICE_ADDED, src, s);
}

pub export fn gst_message_new_device_removed(src: [*c]Object, dev: [*c]c.GstDevice) [*c]Message {
    const s = device("gst_message_new_device_removed", "GstMessageDeviceRemoved", dev) orelse return null;
    return gst_message_new_custom(c.GST_MESSAGE_DEVICE_REMOVED, src, s);
}

pub export fn gst_message_new_device_changed(src: [*c]Object, dev: [*c]c.GstDevice, changed: [*c]c.GstDevice) [*c]Message {
    const s = device("gst_message_new_device_changed", "GstMessageDeviceChanged", dev) orelse return null;
    fields.set(s, "device-changed", deviceType(), changed);
    return gst_message_new_custom(c.GST_MESSAGE_DEVICE_CHANGED, src, s);
}

fn getDevice(m: [*c]Message, name: [*c]const u8, out: [*c][*c]c.GstDevice) void {
    if (out != null) _ = c.gst_structure_get(structureOf(m), name, deviceType(), out, @as(?*anyopaque, null));
}

pub export fn gst_message_parse_device_added(m: [*c]Message, dev: [*c][*c]c.GstDevice) void {
    if (!guardType("gst_message_parse_device_added", m, c.GST_MESSAGE_DEVICE_ADDED, "GST_MESSAGE_DEVICE_ADDED")) return;
    getDevice(m, "device", dev);
}

pub export fn gst_message_parse_device_removed(m: [*c]Message, dev: [*c][*c]c.GstDevice) void {
    if (!guardType("gst_message_parse_device_removed", m, c.GST_MESSAGE_DEVICE_REMOVED, "GST_MESSAGE_DEVICE_REMOVED")) return;
    getDevice(m, "device", dev);
}

pub export fn gst_message_parse_device_changed(m: [*c]Message, dev: [*c][*c]c.GstDevice, changed: [*c][*c]c.GstDevice) void {
    if (!guardType("gst_message_parse_device_changed", m, c.GST_MESSAGE_DEVICE_CHANGED, "GST_MESSAGE_DEVICE_CHANGED")) return;
    getDevice(m, "device", dev);
    getDevice(m, "device-changed", changed);
}

pub export fn gst_message_new_device_monitor_started(src: [*c]Object, success: c.gboolean) [*c]Message {
    const s = c.gst_structure_new_static_str_empty("GstMessageDeviceMonitorStarted");
    fields.set(s, "success", c.G_TYPE_BOOLEAN, success);
    return gst_message_new_custom(c.GST_MESSAGE_DEVICE_MONITOR_STARTED, src, s);
}

pub export fn gst_message_parse_device_monitor_started(m: [*c]Message, success: [*c]c.gboolean) void {
    if (!guardType("gst_message_parse_device_monitor_started", m, c.GST_MESSAGE_DEVICE_MONITOR_STARTED, "GST_MESSAGE_DEVICE_MONITOR_STARTED")) return;
    _ = c.gst_structure_get(structureOf(m), "success", c.G_TYPE_BOOLEAN, success, @as(?*anyopaque, null));
}

pub export fn gst_message_new_property_notify(src: [*c]Object, name: [*c]const u8, val: [*c]c.GValue) [*c]Message {
    const f = "gst_message_new_property_notify";
    if (!check.that(gtype.instanceOf(src, c.gst_object_get_type()), f, "GST_IS_OBJECT (src)")) return null;
    if (!check.that(name != null, f, "property_name != NULL")) return null;
    const s = c.gst_structure_new_static_str_empty("GstMessagePropertyNotify");
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.G_TYPE_STRING);
    c.g_value_set_static_string(&v, c.g_intern_string(name));
    c.gst_structure_take_value(s, "property-name", &v);
    if (val != null) c.gst_structure_take_value(s, "property-value", val);
    return gst_message_new_custom(c.GST_MESSAGE_PROPERTY_NOTIFY, src, s);
}

pub export fn gst_message_parse_property_notify(m: [*c]Message, obj: [*c][*c]Object, name: [*c][*c]const u8, val: [*c][*c]const c.GValue) void {
    if (!guardType("gst_message_parse_property_notify", m, c.GST_MESSAGE_PROPERTY_NOTIFY, "GST_MESSAGE_PROPERTY_NOTIFY")) return;
    if (obj != null) obj.* = m[0].src;
    if (name != null) name.* = c.g_value_get_string(value(m, "property-name"));
    if (val != null) val.* = value(m, "property-value");
}

fn isCollection(p: anytype) bool {
    return gtype.instanceOf(p, c.gst_stream_collection_get_type());
}

pub export fn gst_message_new_stream_collection(src: [*c]Object, col: [*c]c.GstStreamCollection) [*c]Message {
    const f = "gst_message_new_stream_collection";
    if (!check.that(col != null, f, "collection != NULL")) return null;
    if (!check.that(isCollection(col), f, "GST_IS_STREAM_COLLECTION (collection)")) return null;
    const s = c.gst_structure_new_static_str_empty("GstMessageStreamCollection");
    fields.set(s, "collection", c.gst_stream_collection_get_type(), col);
    return gst_message_new_custom(c.GST_MESSAGE_STREAM_COLLECTION, src, s);
}

pub export fn gst_message_parse_stream_collection(m: [*c]Message, col: [*c][*c]c.GstStreamCollection) void {
    if (!guardType("gst_message_parse_stream_collection", m, c.GST_MESSAGE_STREAM_COLLECTION, "GST_MESSAGE_STREAM_COLLECTION")) return;
    if (col != null) _ = c.gst_structure_get(structureOf(m), "collection", c.gst_stream_collection_get_type(), col, @as(?*anyopaque, null));
}

pub export fn gst_message_new_streams_selected(src: [*c]Object, col: [*c]c.GstStreamCollection) [*c]Message {
    const f = "gst_message_new_streams_selected";
    if (!check.that(col != null, f, "collection != NULL")) return null;
    if (!check.that(isCollection(col), f, "GST_IS_STREAM_COLLECTION (collection)")) return null;
    const s = c.gst_structure_new_static_str_empty("GstMessageStreamsSelected");
    fields.set(s, "collection", c.gst_stream_collection_get_type(), col);
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.gst_value_array_get_type());
    c.gst_structure_take_value(s, "streams", &v);
    return gst_message_new_custom(c.GST_MESSAGE_STREAMS_SELECTED, src, s);
}

pub export fn gst_message_streams_selected_get_size(m: [*c]Message) c.guint {
    if (!guardMsg("gst_message_streams_selected_get_size", m, c.GST_MESSAGE_STREAMS_SELECTED, "GST_MESSAGE_STREAMS_SELECTED")) return 0;
    return c.gst_value_array_get_size(value(m, "streams"));
}

pub export fn gst_message_streams_selected_add(m: [*c]Message, stream: [*c]c.GstStream) void {
    const f = "gst_message_streams_selected_add";
    if (!guardMsg(f, m, c.GST_MESSAGE_STREAMS_SELECTED, "GST_MESSAGE_STREAMS_SELECTED")) return;
    if (!check.that(gtype.instanceOf(stream, c.gst_stream_get_type()), f, "GST_IS_STREAM (stream)")) return;
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.gst_stream_get_type());
    c.g_value_set_object(&v, stream);
    c.gst_value_array_append_and_take_value(@constCast(value(m, "streams")), &v);
}

pub export fn gst_message_streams_selected_get_stream(m: [*c]Message, idx: c.guint) [*c]c.GstStream {
    if (!guardMsg("gst_message_streams_selected_get_stream", m, c.GST_MESSAGE_STREAMS_SELECTED, "GST_MESSAGE_STREAMS_SELECTED")) return null;
    const v = c.gst_value_array_get_value(value(m, "streams"), idx);
    if (v == null) return null;
    return @ptrCast(@alignCast(c.g_value_dup_object(v)));
}

pub export fn gst_message_parse_streams_selected(m: [*c]Message, col: [*c][*c]c.GstStreamCollection) void {
    if (!guardType("gst_message_parse_streams_selected", m, c.GST_MESSAGE_STREAMS_SELECTED, "GST_MESSAGE_STREAMS_SELECTED")) return;
    if (col != null) _ = c.gst_structure_get(structureOf(m), "collection", c.gst_stream_collection_get_type(), col, @as(?*anyopaque, null));
}

const LOCATIONS = "redirect-entry-locations";
const TAGLISTS = "redirect-entry-taglists";
const STRUCTURES = "redirect-entry-structures";

pub export fn gst_message_new_redirect(src: [*c]Object, location: [*c]const u8, tags: [*c]c.GstTagList, entry: [*c]Structure) [*c]Message {
    if (!check.that(location != null, "gst_message_new_redirect", "location != NULL")) return null;
    const s = c.gst_structure_new_static_str_empty("GstMessageRedirect");
    for ([_][*c]const u8{ LOCATIONS, TAGLISTS, STRUCTURES }) |name| {
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, c.gst_value_list_get_type());
        c.gst_structure_take_value_static_str(s, name, &v);
    }
    const m = gst_message_new_custom(c.GST_MESSAGE_REDIRECT, src, s);
    gst_message_add_redirect_entry(m, location, tags, entry);
    return m;
}

fn listField(comptime f: []const u8, m: [*c]Message, comptime name: [:0]const u8) ?*c.GValue {
    const v = value(m, name);
    if (!check.that(v != null and v[0].g_type == c.gst_value_list_get_type(), f, "GST_VALUE_HOLDS_LIST (" ++ name[15..] ++ "_gvalue)")) return null;
    return @constCast(v);
}

fn entryLists(comptime f: []const u8, m: [*c]Message) ?[3]*c.GValue {
    const a = listField(f, m, LOCATIONS) orelse return null;
    const b = listField(f, m, TAGLISTS) orelse return null;
    const d = listField(f, m, STRUCTURES) orelse return null;
    return .{ a, b, d };
}

pub export fn gst_message_add_redirect_entry(m: [*c]Message, location: [*c]const u8, tags: [*c]c.GstTagList, entry: [*c]Structure) void {
    const f = "gst_message_add_redirect_entry";
    if (!check.that(location != null, f, "location != NULL")) return;
    if (!guardType(f, m, c.GST_MESSAGE_REDIRECT, "GST_MESSAGE_REDIRECT")) return;
    const lists = entryLists(f, m) orelse return;
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.G_TYPE_STRING);
    c.g_value_set_string(&v, location);
    c.gst_value_list_append_and_take_value(lists[0], &v);
    _ = c.g_value_init(&v, c.gst_tag_list_get_type());
    if (tags != null) c.g_value_take_boxed(&v, tags);
    c.gst_value_list_append_and_take_value(lists[1], &v);
    _ = c.g_value_init(&v, c.gst_structure_get_type());
    if (entry != null) c.g_value_take_boxed(&v, entry);
    c.gst_value_list_append_and_take_value(lists[2], &v);
}

pub export fn gst_message_parse_redirect_entry(m: [*c]Message, idx: c.gsize, location: [*c][*c]const u8, tags: [*c][*c]c.GstTagList, entry: [*c][*c]const Structure) void {
    const f = "gst_message_parse_redirect_entry";
    if (!guardType(f, m, c.GST_MESSAGE_REDIRECT, "GST_MESSAGE_REDIRECT")) return;
    if (location == null and tags == null and entry == null) return;
    const lists = entryLists(f, m) orelse return;
    const i: c.guint = @intCast(idx);
    if (location != null) {
        const v = c.gst_value_list_get_value(lists[0], i);
        if (!check.that(v != null, f, "val != NULL")) return;
        location.* = c.g_value_get_string(v);
    }
    if (tags != null) {
        const v = c.gst_value_list_get_value(lists[1], i);
        if (!check.that(v != null, f, "val != NULL")) return;
        tags.* = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
    }
    if (entry != null) {
        const v = c.gst_value_list_get_value(lists[2], i);
        if (!check.that(v != null, f, "val != NULL")) return;
        entry.* = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
    }
}

pub export fn gst_message_get_num_redirect_entries(m: [*c]Message) c.gsize {
    const f = "gst_message_get_num_redirect_entries";
    if (!guardType(f, m, c.GST_MESSAGE_REDIRECT, "GST_MESSAGE_REDIRECT")) return 0;
    const lists = entryLists(f, m) orelse return 0;
    const n = c.gst_value_list_get_size(lists[0]);
    const ok = n == c.gst_value_list_get_size(lists[2]) and n == c.gst_value_list_get_size(lists[1]);
    if (!check.that(ok, f, "(size == gst_value_list_get_size (entry_structures_gvalue)) && (size == gst_value_list_get_size (entry_taglists_gvalue))")) return 0;
    return n;
}

pub export fn gst_message_new_instant_rate_request(src: [*c]Object, rate: c.gdouble) [*c]Message {
    if (!check.that(rate != 0.0, "gst_message_new_instant_rate_request", "rate_multiplier != 0.0")) return null;
    const s = c.gst_structure_new_static_str_empty("GstMessageInstantRateRequest");
    fields.set(s, "rate", c.G_TYPE_DOUBLE, rate);
    return gst_message_new_custom(c.GST_MESSAGE_INSTANT_RATE_REQUEST, src, s);
}

pub export fn gst_message_parse_instant_rate_request(m: [*c]Message, rate: [*c]c.gdouble) void {
    if (!guardType("gst_message_parse_instant_rate_request", m, c.GST_MESSAGE_INSTANT_RATE_REQUEST, "GST_MESSAGE_INSTANT_RATE_REQUEST")) return;
    _ = c.gst_structure_get(structureOf(m), "rate", c.G_TYPE_DOUBLE, rate, @as(?*anyopaque, null));
}

pub export fn gst_message_ref(m: [*c]Message) [*c]Message {
    return @ptrCast(mini.gst_mini_object_ref(asMini(m)));
}

pub export fn gst_message_unref(m: [*c]Message) void {
    mini.gst_mini_object_unref(asMini(m));
}

pub export fn gst_clear_message(slot: [*c][*c]Message) void {
    mini.gst_clear_mini_object(@ptrCast(slot));
}

pub export fn gst_message_copy(m: [*c]const Message) [*c]Message {
    return @ptrCast(mini.gst_mini_object_copy(asMini(m)));
}

pub export fn gst_message_replace(slot: [*c][*c]Message, m: [*c]Message) c.gboolean {
    return mini.gst_mini_object_replace(@ptrCast(slot), asMini(m));
}

pub export fn gst_message_take(slot: [*c][*c]Message, m: [*c]Message) c.gboolean {
    return mini.gst_mini_object_take(@ptrCast(slot), asMini(m));
}

pub export fn gst_message_steal(slot: [*c][*c]Message) [*c]Message {
    return @ptrCast(mini.gst_mini_object_steal(@ptrCast(slot)));
}

pub export fn gst_message_is_writable(m: [*c]const Message) c.gboolean {
    return mini.gst_mini_object_is_writable(asMini(m));
}

pub export fn gst_message_make_writable(m: [*c]Message) [*c]Message {
    return @ptrCast(mini.gst_mini_object_make_writable(asMini(m)));
}
