const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const NONE = @as(?*anyopaque, null);

fn peek(comptime T: type, obj: anytype, t: c.GType) *T {
    return @ptrCast(@alignCast(c.g_type_interface_peek(@as(*c.GTypeInstance, @ptrCast(@alignCast(obj))).g_class, t)));
}

const Overlay = c.GstVideoOverlay;
const OverlayIface = c.GstVideoOverlayInterface;
var overlay_once: gtype.Once = .{};

pub export fn gst_video_overlay_get_type() c.GType {
    return overlay_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(c.G_TYPE_INTERFACE, "GstVideoOverlay", @sizeOf(OverlayIface), null, 0, null, 0);
        }
    }.f);
}

fn overlayOk(o: ?*Overlay, comptime fname: []const u8) bool {
    if (!check.that(o != null, fname, "overlay != NULL")) return false;
    return check.that(gtype.instanceOf(o, gst_video_overlay_get_type()), fname, "GST_IS_VIDEO_OVERLAY (overlay)");
}

fn overlayIface(o: ?*Overlay) *OverlayIface {
    return peek(OverlayIface, o, gst_video_overlay_get_type());
}

pub export fn gst_video_overlay_set_window_handle(overlay: ?*Overlay, handle: c.guintptr) void {
    if (!overlayOk(overlay, "gst_video_overlay_set_window_handle")) return;
    if (overlayIface(overlay).set_window_handle) |f| f(overlay, handle);
}

pub export fn gst_video_overlay_got_window_handle(overlay: ?*Overlay, handle: c.guintptr) void {
    if (!overlayOk(overlay, "gst_video_overlay_got_window_handle")) return;
    const s = c.gst_structure_new("have-window-handle", "window-handle", c.G_TYPE_UINT64, @as(c.guint64, handle), NONE);
    _ = c.gst_element_post_message(@ptrCast(@alignCast(overlay)), c.gst_message_new_element(@ptrCast(@alignCast(overlay)), s));
}

pub export fn gst_video_overlay_prepare_window_handle(overlay: ?*Overlay) void {
    if (!overlayOk(overlay, "gst_video_overlay_prepare_window_handle")) return;
    const s = c.gst_structure_new_empty("prepare-window-handle");
    _ = c.gst_element_post_message(@ptrCast(@alignCast(overlay)), c.gst_message_new_element(@ptrCast(@alignCast(overlay)), s));
}

pub export fn gst_video_overlay_expose(overlay: ?*Overlay) void {
    if (!overlayOk(overlay, "gst_video_overlay_expose")) return;
    if (overlayIface(overlay).expose) |f| f(overlay);
}

pub export fn gst_video_overlay_handle_events(overlay: ?*Overlay, handle_events: c.gboolean) void {
    if (!overlayOk(overlay, "gst_video_overlay_handle_events")) return;
    if (overlayIface(overlay).handle_events) |f| f(overlay, handle_events);
}

pub export fn gst_video_overlay_set_render_rectangle(overlay: ?*Overlay, x: c.gint, y: c.gint, width: c.gint, height: c.gint) c.gboolean {
    const fname = "gst_video_overlay_set_render_rectangle";
    if (!overlayOk(overlay, fname)) return 0;
    if (!check.that((width == -1 and height == -1) or (width > 0 and height > 0), fname, "(width == -1 && height == -1) || (width > 0 && height > 0)")) return 0;
    if (overlayIface(overlay).set_render_rectangle) |f| {
        f(overlay, x, y, width, height);
        return 1;
    }
    return 0;
}

pub export fn gst_is_video_overlay_prepare_window_handle_message(msg: [*c]c.GstMessage) c.gboolean {
    if (!check.that(msg != null, "gst_is_video_overlay_prepare_window_handle_message", "msg != NULL")) return 0;
    if (msg[0].type != c.GST_MESSAGE_ELEMENT) return 0;
    return c.gst_message_has_name(msg, "prepare-window-handle");
}

pub export fn gst_video_overlay_install_properties(oclass: [*c]c.GObjectClass, last_prop_id: c.gint) void {
    const elem = c.g_param_spec_int("rect-value", "Rectangle Value", "One of x, y, width or height value.", std.math.minInt(c.gint), std.math.maxInt(c.gint), -1, c.G_PARAM_WRITABLE | c.G_PARAM_STATIC_STRINGS);
    c.g_object_class_install_property(oclass, @bitCast(last_prop_id), c.gst_param_spec_array("render-rectangle", "Render Rectangle", "The render rectangle ('<x, y, width, height>')", elem, c.G_PARAM_WRITABLE | c.G_PARAM_STATIC_STRINGS));
}

pub export fn gst_video_overlay_set_property(object: [*c]c.GObject, last_prop_id: c.gint, property_id: c.guint, value: [*c]const c.GValue) c.gboolean {
    if (property_id != @as(c.guint, @bitCast(last_prop_id))) return 0;
    var rect: [4]c.gint = undefined;
    var ok = c.gst_value_array_get_size(value) == 4;
    if (ok) {
        for (0..4) |i| {
            const v = c.gst_value_array_get_value(value, @intCast(i));
            if (c.g_type_check_value_holds(v, c.G_TYPE_INT) == 0) {
                ok = false;
                break;
            }
            rect[i] = c.g_value_get_int(v);
        }
    }
    if (!ok) {
        var s = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&s, c.G_TYPE_STRING);
        _ = c.g_value_transform(value, &s);
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "Badly formatted rectangle, must contains four gint (got '%s')", c.g_value_get_string(&s));
        c.g_value_unset(&s);
        return 1;
    }
    _ = gst_video_overlay_set_render_rectangle(@ptrCast(object), rect[0], rect[1], rect[2], rect[3]);
    return 1;
}

const Orient = c.GstVideoOrientation;
const OrientIface = c.GstVideoOrientationInterface;
var orient_once: gtype.Once = .{};

fn orientInit(p: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *OrientIface = @ptrCast(@alignCast(p));
    i.get_hflip = null;
    i.get_vflip = null;
    i.get_hcenter = null;
    i.get_vcenter = null;
    i.set_hflip = null;
    i.set_vflip = null;
    i.set_hcenter = null;
    i.set_vcenter = null;
}

pub export fn gst_video_orientation_get_type() c.GType {
    return orient_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(c.G_TYPE_INTERFACE, "GstVideoOrientation", @sizeOf(OrientIface), orientInit, 0, null, 0);
        }
    }.f);
}

fn orientIface(o: ?*Orient) *OrientIface {
    return peek(OrientIface, o, gst_video_orientation_get_type());
}

pub export fn gst_video_orientation_get_hflip(o: ?*Orient, flip: [*c]c.gboolean) c.gboolean {
    if (orientIface(o).get_hflip) |f| return f(o, flip);
    return 0;
}

pub export fn gst_video_orientation_get_vflip(o: ?*Orient, flip: [*c]c.gboolean) c.gboolean {
    if (orientIface(o).get_vflip) |f| return f(o, flip);
    return 0;
}

pub export fn gst_video_orientation_get_hcenter(o: ?*Orient, center: [*c]c.gint) c.gboolean {
    if (orientIface(o).get_hcenter) |f| return f(o, center);
    return 0;
}

pub export fn gst_video_orientation_get_vcenter(o: ?*Orient, center: [*c]c.gint) c.gboolean {
    if (orientIface(o).get_vcenter) |f| return f(o, center);
    return 0;
}

pub export fn gst_video_orientation_set_hflip(o: ?*Orient, flip: c.gboolean) c.gboolean {
    if (orientIface(o).set_hflip) |f| return f(o, flip);
    return 0;
}

pub export fn gst_video_orientation_set_vflip(o: ?*Orient, flip: c.gboolean) c.gboolean {
    if (orientIface(o).set_vflip) |f| return f(o, flip);
    return 0;
}

pub export fn gst_video_orientation_set_hcenter(o: ?*Orient, center: c.gint) c.gboolean {
    if (orientIface(o).set_hcenter) |f| return f(o, center);
    return 0;
}

pub export fn gst_video_orientation_set_vcenter(o: ?*Orient, center: c.gint) c.gboolean {
    if (orientIface(o).set_vcenter) |f| return f(o, center);
    return 0;
}

var direction_once: gtype.Once = .{};

fn directionInit(p: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_object_interface_install_property(p, c.g_param_spec_enum("video-direction", "Video direction", "Video direction: rotation and flipping", c.gst_video_orientation_method_get_type(), c.GST_VIDEO_ORIENTATION_IDENTITY, c.GST_PARAM_CONTROLLABLE | c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | c.G_PARAM_STATIC_STRINGS));
}

pub export fn gst_video_direction_get_type() c.GType {
    return direction_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(c.G_TYPE_INTERFACE, "GstVideoDirection", @sizeOf(c.GstVideoDirectionInterface), directionInit, 0, null, 0);
        }
    }.f);
}

const Balance = c.GstColorBalance;
const BalanceIface = c.GstColorBalanceInterface;
const Channel = c.GstColorBalanceChannel;
const ChannelClass = c.GstColorBalanceChannelClass;
var balance_once: gtype.Once = .{};
var balance_signal: c.guint = 0;
var balance_inited = false;

fn balanceBaseInit(p: c.gpointer) callconv(.c) void {
    const i: *BalanceIface = @ptrCast(@alignCast(p));
    if (!balance_inited) {
        balance_signal = c.g_signal_new("value-changed", gst_color_balance_get_type(), c.G_SIGNAL_RUN_LAST, @offsetOf(BalanceIface, "value_changed"), null, null, null, c.G_TYPE_NONE, 2, gst_color_balance_channel_get_type(), c.G_TYPE_INT);
        balance_inited = true;
    }
    i.list_channels = null;
    i.set_value = null;
    i.get_value = null;
    i.get_balance_type = null;
}

pub export fn gst_color_balance_get_type() c.GType {
    return balance_once.get(struct {
        fn f() c.GType {
            var info = std.mem.zeroes(c.GTypeInfo);
            info.class_size = @sizeOf(BalanceIface);
            info.base_init = balanceBaseInit;
            return c.g_type_register_static(c.G_TYPE_INTERFACE, "GstColorBalance", &info, 0);
        }
    }.f);
}

fn isBalance(b: ?*Balance) bool {
    return gtype.instanceOf(b, gst_color_balance_get_type());
}

fn balanceIface(b: ?*Balance) *BalanceIface {
    return peek(BalanceIface, b, gst_color_balance_get_type());
}

pub export fn gst_color_balance_list_channels(balance: ?*Balance) [*c]const c.GList {
    if (!check.that(isBalance(balance), "gst_color_balance_list_channels", "GST_IS_COLOR_BALANCE (balance)")) return null;
    if (balanceIface(balance).list_channels) |f| return f(balance);
    return null;
}

pub export fn gst_color_balance_set_value(balance: ?*Balance, channel: [*c]Channel, value: c.gint) void {
    if (balanceIface(balance).set_value) |f| f(balance, channel, value);
}

pub export fn gst_color_balance_get_value(balance: ?*Balance, channel: [*c]Channel) c.gint {
    if (!check.that(isBalance(balance), "gst_color_balance_get_value", "GST_IS_COLOR_BALANCE (balance)")) return 0;
    if (balanceIface(balance).get_value) |f| return f(balance, channel);
    return channel[0].min_value;
}

pub export fn gst_color_balance_get_balance_type(balance: ?*Balance) c.GstColorBalanceType {
    const fname = "gst_color_balance_get_balance_type";
    if (!check.that(isBalance(balance), fname, "GST_IS_COLOR_BALANCE (balance)")) return c.GST_COLOR_BALANCE_SOFTWARE;
    const i = balanceIface(balance);
    if (!check.that(i.get_balance_type != null, fname, "iface->get_balance_type != NULL")) return c.GST_COLOR_BALANCE_SOFTWARE;
    return i.get_balance_type.?(balance);
}

pub export fn gst_color_balance_value_changed(balance: ?*Balance, channel: [*c]Channel, value: c.gint) void {
    if (!check.that(isBalance(balance), "gst_color_balance_value_changed", "GST_IS_COLOR_BALANCE (balance)")) return;
    c.g_signal_emit(balance, balance_signal, 0, channel, value);
    c.g_signal_emit_by_name(channel, "value_changed", value);
}

var channel_once: gtype.Once = .{};
var channel_parent: ?*c.GObjectClass = null;

fn channelDispose(obj: [*c]c.GObject) callconv(.c) void {
    const ch: *Channel = @ptrCast(@alignCast(obj));
    if (ch.label != null) c.g_free(ch.label);
    ch.label = null;
    if (channel_parent.?.dispose) |f| f(obj);
}

fn channelClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    channel_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    _ = c.g_signal_new("value-changed", @as(*c.GTypeClass, @ptrCast(@alignCast(klass))).g_type, c.G_SIGNAL_RUN_LAST, @offsetOf(ChannelClass, "value_changed"), null, null, null, c.G_TYPE_NONE, 1, c.G_TYPE_INT);
    oc.dispose = channelDispose;
}

fn channelInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const ch: *Channel = @ptrCast(@alignCast(inst));
    ch.label = null;
    ch.min_value = 0;
    ch.max_value = 0;
}

pub export fn gst_color_balance_channel_get_type() c.GType {
    return channel_once.get(struct {
        fn f() c.GType {
            var info = std.mem.zeroes(c.GTypeInfo);
            info.class_size = @sizeOf(ChannelClass);
            info.class_init = channelClassInit;
            info.instance_size = @sizeOf(Channel);
            info.instance_init = channelInit;
            return c.g_type_register_static(c.G_TYPE_OBJECT, "GstColorBalanceChannel", &info, 0);
        }
    }.f);
}
