const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Clock = c.GstAudioClock;
const NONE: u64 = std.math.maxInt(u64);

var type_once: gtype.Once = .{};
var parent: ?*c.GObjectClass = null;

fn of(p: anytype) *Clock {
    return @ptrCast(@alignCast(p));
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const k = of(o);
    if (k.destroy_notify != null and k.user_data != null) k.destroy_notify.?(k.user_data);
    k.destroy_notify = null;
    k.user_data = null;
    parent.?.dispose.?(o);
}

fn internalTime(clock: [*c]c.GstClock) callconv(.c) c.GstClockTime {
    const k = of(clock);
    var result = k.func.?(clock, k.user_data);
    if (result == NONE) return k.last_time;
    result +%= @as(u64, @bitCast(k.time_offset));
    if (k.last_time < result) k.last_time = result else result = k.last_time;
    return result;
}

fn classInit(kl: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(kl)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(kl));
    const cc: *c.GstClockClass = @ptrCast(@alignCast(kl));
    oc.dispose = dispose;
    cc.get_internal_time = internalTime;
    _ = c._gst_debug_category_new("audioclock", 0, "audioclock");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const k = of(inst);
    k.last_time = 0;
    k.time_offset = 0;
    @as(*c.GstObject, @ptrCast(@alignCast(inst))).flags |= c.GST_CLOCK_FLAG_CAN_SET_MASTER;
}

pub export fn gst_audio_clock_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return gtype.object(c.gst_system_clock_get_type, "GstAudioClock", c.GstAudioClockClass, Clock, classInit, init, 0);
        }
    }.f);
}

pub export fn gst_audio_clock_new(name: [*c]const u8, func: c.GstAudioClockGetTimeFunc, user_data: c.gpointer, destroy: c.GDestroyNotify) [*c]c.GstClock {
    const k = of(c.g_object_new(gst_audio_clock_get_type(), "name", name, "clock-type", c.GST_CLOCK_TYPE_OTHER, @as(?*anyopaque, null)));
    k.func = func;
    k.user_data = user_data;
    k.destroy_notify = destroy;
    _ = c.gst_object_ref_sink(k);
    return @ptrCast(k);
}

pub export fn gst_audio_clock_reset(k: [*c]Clock, time: c.GstClockTime) void {
    k.*.time_offset = if (k.*.last_time >= time) @bitCast(k.*.last_time - time) else -@as(i64, @bitCast(time - k.*.last_time));
}

fn invalid(_: [*c]c.GstClock, _: c.gpointer) callconv(.c) c.GstClockTime {
    return NONE;
}

pub export fn gst_audio_clock_get_time(k: [*c]Clock) c.GstClockTime {
    const r = k.*.func.?(@ptrCast(k), k.*.user_data);
    if (r == NONE) return k.*.last_time -% @as(u64, @bitCast(k.*.time_offset));
    return r;
}

pub export fn gst_audio_clock_adjust(k: [*c]Clock, time: c.GstClockTime) c.GstClockTime {
    return time +% @as(u64, @bitCast(k.*.time_offset));
}

pub export fn gst_audio_clock_invalidate(k: [*c]Clock) void {
    k.*.func = invalid;
}
