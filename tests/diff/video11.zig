const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);

fn showS(prefix: []const u8, s: ?*const c.GstStructure) void {
    if (s == null) {
        out("{s} null", .{prefix});
        return;
    }
    const str = c.gst_structure_to_string(s);
    out("{s} {s}", .{ prefix, str });
    c.g_free(str);
}

fn sendEvent(_: ?*c.GstNavigation, s: [*c]c.GstStructure) callconv(.c) void {
    showS("    send_event", s);
    c.gst_structure_free(s);
}

fn sendSimple(_: ?*c.GstNavigation, e: [*c]c.GstEvent) callconv(.c) void {
    showS("    send_event_simple", c.gst_event_get_structure(e));
    c.gst_event_unref(e);
}

fn navA(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstNavigationInterface = @ptrCast(@alignCast(g));
    i.send_event = sendEvent;
}

fn navB(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstNavigationInterface = @ptrCast(@alignCast(g));
    i.send_event_simple = sendSimple;
}

fn navC(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstNavigationInterface = @ptrCast(@alignCast(g));
    i.send_event = null;
    i.send_event_simple = null;
}

fn expose(_: ?*c.GstVideoOverlay) callconv(.c) void {
    out("    expose", .{});
}

fn handleEvents(_: ?*c.GstVideoOverlay, h: c.gboolean) callconv(.c) void {
    out("    handle_events {d}", .{h});
}

fn renderRect(_: ?*c.GstVideoOverlay, x: c.gint, y: c.gint, w: c.gint, h: c.gint) callconv(.c) void {
    out("    render {d} {d} {d} {d}", .{ x, y, w, h });
}

fn windowHandle(_: ?*c.GstVideoOverlay, h: c.guintptr) callconv(.c) void {
    out("    window {d}", .{h});
}

fn overlayInit(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstVideoOverlayInterface = @ptrCast(@alignCast(g));
    i.expose = expose;
    i.handle_events = handleEvents;
    i.set_render_rectangle = renderRect;
    i.set_window_handle = windowHandle;
}

var channels: ?*c.GList = null;

fn listChannels(_: ?*c.GstColorBalance) callconv(.c) [*c]const c.GList {
    return channels;
}

fn setValue(_: ?*c.GstColorBalance, ch: [*c]c.GstColorBalanceChannel, v: c.gint) callconv(.c) void {
    out("    set_value {s} {d}", .{ ch[0].label, v });
}

fn getValue(_: ?*c.GstColorBalance, ch: [*c]c.GstColorBalanceChannel) callconv(.c) c.gint {
    return ch[0].max_value - 1;
}

fn balanceType(_: ?*c.GstColorBalance) callconv(.c) c.GstColorBalanceType {
    return c.GST_COLOR_BALANCE_HARDWARE;
}

fn balanceInit(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstColorBalanceInterface = @ptrCast(@alignCast(g));
    i.list_channels = listChannels;
    i.set_value = setValue;
    i.get_value = getValue;
    i.get_balance_type = balanceType;
}

fn getHflip(_: ?*c.GstVideoOrientation, f: [*c]c.gboolean) callconv(.c) c.gboolean {
    f[0] = 1;
    return 1;
}

fn setVcenter(_: ?*c.GstVideoOrientation, v: c.gint) callconv(.c) c.gboolean {
    out("    vcenter {d}", .{v});
    return 1;
}

fn orientInit(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstVideoOrientationInterface = @ptrCast(@alignCast(g));
    i.get_hflip = getHflip;
    i.set_vcenter = setVcenter;
}

fn noop(_: c.gpointer, _: c.gpointer) callconv(.c) void {}

fn setProp(obj: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    if (c.gst_video_overlay_set_property(obj, 1, id, v) != 0) return;
    out("    other prop {d}", .{id});
}

fn getProp(_: [*c]c.GObject, _: c.guint, v: [*c]c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    c.g_value_set_enum(v, c.GST_VIDEO_ORIENTATION_90R);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProp;
    oc.get_property = getProp;
    c.gst_video_overlay_install_properties(oc, 1);
    c.g_object_class_override_property(oc, 2, "video-direction");
}

fn makeType(name: [*:0]const u8, nav: c.GInterfaceInitFunc, full: bool) c.GType {
    const t = c.g_type_register_static_simple(c.gst_element_get_type(), name, @sizeOf(c.GstElementClass), if (full) classInit else null, @sizeOf(c.GstElement), null, 0);
    var ni = c.GInterfaceInfo{ .interface_init = nav, .interface_finalize = null, .interface_data = null };
    c.g_type_add_interface_static(t, c.gst_navigation_get_type(), &ni);
    if (full) {
        var oi = c.GInterfaceInfo{ .interface_init = overlayInit, .interface_finalize = null, .interface_data = null };
        c.g_type_add_interface_static(t, c.gst_video_overlay_get_type(), &oi);
        var bi = c.GInterfaceInfo{ .interface_init = balanceInit, .interface_finalize = null, .interface_data = null };
        c.g_type_add_interface_static(t, c.gst_color_balance_get_type(), &bi);
        var ri = c.GInterfaceInfo{ .interface_init = orientInit, .interface_finalize = null, .interface_data = null };
        c.g_type_add_interface_static(t, c.gst_video_orientation_get_type(), &ri);
        var di = c.GInterfaceInfo{ .interface_init = noop, .interface_finalize = null, .interface_data = null };
        c.g_type_add_interface_static(t, c.gst_video_direction_get_type(), &di);
    }
    return t;
}

fn sendAll(nav: ?*c.GstNavigation) void {
    c.gst_navigation_send_key_event(nav, "key-press", "a");
    c.gst_navigation_send_key_event(nav, "key-pressed", "a");
    c.gst_navigation_send_mouse_event(nav, "mouse-move", 1, 2.5, 3.5);
    c.gst_navigation_send_mouse_event(nav, "mouse-scroll", 1, 2.5, 3.5);
    c.gst_navigation_send_mouse_scroll_event(nav, 1, 2, 0.5, -0.5);
    c.gst_navigation_send_command(nav, c.GST_NAVIGATION_COMMAND_MENU1);
    c.gst_navigation_send_event_simple(nav, c.gst_navigation_event_new_touch_down(3, 4, 5, 0.75, c.GST_NAVIGATION_MODIFIER_SHIFT_MASK));
    c.gst_navigation_send_event(nav, c.gst_structure_new_empty("custom"));
}

fn showEvent(e: [*c]c.GstEvent) void {
    showS("  event", c.gst_event_get_structure(e));
    out("    type {d}", .{c.gst_navigation_event_get_type(e)});
    var key: [*c]const u8 = null;
    var b: c.gint = -9;
    var x: f64 = -1;
    var y: f64 = -1;
    var dx: f64 = -1;
    var dy: f64 = -1;
    var p: f64 = -1;
    var id: c.guint = 99;
    var cmd: c.GstNavigationCommand = 77;
    var st: c.GstNavigationModifierType = 1234;
    const k = c.gst_navigation_event_parse_key_event(e, &key);
    out("    key {d} {s}", .{ k, if (key != null) std.mem.span(key) else "-" });
    out("    button {d} {d} {d} {d}", .{ c.gst_navigation_event_parse_mouse_button_event(e, &b, &x, &y), b, x, y });
    out("    move {d} {d} {d}", .{ c.gst_navigation_event_parse_mouse_move_event(e, &x, &y), x, y });
    out("    scroll {d} {d} {d}", .{ c.gst_navigation_event_parse_mouse_scroll_event(e, &x, &y, &dx, &dy), dx, dy });
    out("    command {d} {d}", .{ c.gst_navigation_event_parse_command(e, &cmd), cmd });
    out("    touch {d} {d} {d}", .{ c.gst_navigation_event_parse_touch_event(e, &id, &x, &y, &p), id, p });
    out("    touch-up {d} {d}", .{ c.gst_navigation_event_parse_touch_up_event(e, &id, &x, &y), id });
    out("    coords {d} {d} {d}", .{ c.gst_navigation_event_get_coordinates(e, &x, &y), x, y });
    out("    set {d}", .{c.gst_navigation_event_set_coordinates(e, 10.25, 20.5)});
    out("    coords {d} {d} {d}", .{ c.gst_navigation_event_get_coordinates(e, &x, &y), x, y });
    out("    state {d} {d}", .{ c.gst_navigation_event_parse_modifier_state(e, &st), st });
    c.gst_event_unref(e);
}

fn events() void {
    out("events", .{});
    const m = c.GST_NAVIGATION_MODIFIER_CONTROL_MASK | c.GST_NAVIGATION_MODIFIER_BUTTON1_MASK;
    showEvent(c.gst_navigation_event_new_key_press("Return", m));
    showEvent(c.gst_navigation_event_new_key_release("Escape", 0));
    showEvent(c.gst_navigation_event_new_mouse_button_press(2, 1.5, 2.5, m));
    showEvent(c.gst_navigation_event_new_mouse_button_release(3, 4.5, 5.5, 0));
    showEvent(c.gst_navigation_event_new_mouse_double_click(1, 6, 7, m));
    showEvent(c.gst_navigation_event_new_mouse_move(8, 9, m));
    showEvent(c.gst_navigation_event_new_mouse_scroll(1, 2, 3, 4, m));
    showEvent(c.gst_navigation_event_new_command(c.GST_NAVIGATION_COMMAND_DVD_MENU));
    showEvent(c.gst_navigation_event_new_touch_down(1, 2, 3, 0.5, m));
    showEvent(c.gst_navigation_event_new_touch_motion(2, 3, 4, 0.25, 0));
    showEvent(c.gst_navigation_event_new_touch_up(3, 4, 5, m));
    showEvent(c.gst_navigation_event_new_touch_frame(m));
    showEvent(c.gst_navigation_event_new_touch_cancel(0));
    showEvent(c.gst_event_new_navigation(c.gst_structure_new("application/x-gst-navigation", "event", c.G_TYPE_STRING, "mouse-move", NONE)));
    showEvent(c.gst_event_new_navigation(c.gst_structure_new("application/x-gst-navigation", "event", c.G_TYPE_STRING, "bogus", NONE)));
    showEvent(c.gst_event_new_navigation(c.gst_structure_new_empty("other")));
    showEvent(c.gst_event_new_eos());
    out("  null type {d}", .{c.gst_navigation_event_get_type(null)});
    var st: c.GstNavigationModifierType = 0;
    out("  null state {d}", .{c.gst_navigation_event_parse_modifier_state(null, &st)});
}

fn queries() void {
    out("queries", .{});
    const q = c.gst_navigation_query_new_commands();
    var n: c.guint = 99;
    var cmd: c.GstNavigationCommand = 0;
    out("  type {d} len {d} {d}", .{ c.gst_navigation_query_get_type(q), c.gst_navigation_query_parse_commands_length(q, &n), n });
    out("  nth {d} {d}", .{ c.gst_navigation_query_parse_commands_nth(q, 0, &cmd), cmd });
    c.gst_navigation_query_set_commands(q, 3, c.GST_NAVIGATION_COMMAND_MENU1, c.GST_NAVIGATION_COMMAND_LEFT, c.GST_NAVIGATION_COMMAND_NEXT_ANGLE);
    showS("  set", c.gst_query_get_structure(q));
    out("  len {d} {d}", .{ c.gst_navigation_query_parse_commands_length(q, &n), n });
    for (0..4) |i| out("  nth {d}: {d} {d}", .{ i, c.gst_navigation_query_parse_commands_nth(q, @intCast(i), &cmd), cmd });
    var v = [_]c.GstNavigationCommand{ c.GST_NAVIGATION_COMMAND_UP, c.GST_NAVIGATION_COMMAND_ACTIVATE };
    c.gst_navigation_query_set_commandsv(q, 2, &v);
    showS("  setv", c.gst_query_get_structure(q));
    out("  null len {d}", .{c.gst_navigation_query_parse_commands_length(q, null)});
    c.gst_navigation_query_set_angles(q, 1, 2);
    const a = c.gst_navigation_query_new_angles();
    var cur: c.guint = 0;
    out("  angles type {d} parse {d}", .{ c.gst_navigation_query_get_type(a), c.gst_navigation_query_parse_angles(a, &cur, &n) });
    c.gst_navigation_query_set_angles(a, 3, 7);
    out("  angles {d} {d} {d}", .{ c.gst_navigation_query_parse_angles(a, &cur, &n), cur, n });
    showS("  angles", c.gst_query_get_structure(a));
    out("  other {d}", .{c.gst_navigation_query_get_type(c.gst_query_new_position(c.GST_FORMAT_TIME))});
    c.gst_query_unref(a);
    c.gst_query_unref(q);
}

fn messages() void {
    out("messages", .{});
    const src: [*c]c.GstObject = @ptrCast(@alignCast(c.g_object_new(c.gst_bin_get_type(), "name", "nav-src", NONE)));
    var active: c.gboolean = 7;
    var cur: c.guint = 0;
    var n: c.guint = 0;
    const mo = c.gst_navigation_message_new_mouse_over(src, 1);
    out("  mo {d} {d} {d}", .{ c.gst_navigation_message_get_type(mo), c.gst_navigation_message_parse_mouse_over(mo, &active), active });
    showS("  mo", c.gst_message_get_structure(mo));
    const cc = c.gst_navigation_message_new_commands_changed(src);
    out("  cc {d} mo-parse {d}", .{ c.gst_navigation_message_get_type(cc), c.gst_navigation_message_parse_mouse_over(cc, &active) });
    const ac = c.gst_navigation_message_new_angles_changed(src, 2, 5);
    out("  ac {d} {d} {d} {d}", .{ c.gst_navigation_message_get_type(ac), c.gst_navigation_message_parse_angles_changed(ac, &cur, &n), cur, n });
    out("  ac wrong {d}", .{c.gst_navigation_message_parse_angles_changed(cc, &cur, &n)});
    const ev = c.gst_navigation_event_new_key_press("x", 0);
    const em = c.gst_navigation_message_new_event(src, ev);
    var got: [*c]c.GstEvent = null;
    out("  ev {d} {d} same {d}", .{ c.gst_navigation_message_get_type(em), c.gst_navigation_message_parse_event(em, &got), @intFromBool(got == ev) });
    showS("  ev", c.gst_event_get_structure(got));
    c.gst_event_unref(got);
    c.gst_event_unref(ev);
    out("  eos {d}", .{c.gst_navigation_message_get_type(c.gst_message_new_eos(src))});
    for ([_][*c]c.GstMessage{ mo, cc, ac, em }) |m| c.gst_message_unref(m);
    c.gst_object_unref(src);
}

fn drain(bus: ?*c.GstBus) void {
    while (c.gst_bus_pop(bus)) |m| {
        showS("    msg", c.gst_message_get_structure(m));
        out("    prepare {d}", .{c.gst_is_video_overlay_prepare_window_handle_message(m)});
        c.gst_message_unref(m);
    }
}

fn interfaces() void {
    out("interfaces", .{});
    const ta = makeType("NavA", navA, true);
    const tb = makeType("NavB", navB, false);
    const tcc = makeType("NavC", navC, false);
    for ([_]c.GType{ ta, tb, tcc }) |t| {
        const o = c.g_object_new(t, null);
        out("  {s}", .{c.g_type_name(t)});
        sendAll(@ptrCast(o));
        c.gst_object_unref(o);
    }
    const o = c.g_object_new(ta, null);
    const bus = c.gst_bus_new();
    c.gst_element_set_bus(@ptrCast(@alignCast(o)), bus);
    const ov: ?*c.GstVideoOverlay = @ptrCast(o);
    c.gst_video_overlay_set_window_handle(ov, 1234);
    c.gst_video_overlay_got_window_handle(ov, 5678);
    c.gst_video_overlay_prepare_window_handle(ov);
    drain(bus);
    c.gst_video_overlay_expose(ov);
    c.gst_video_overlay_handle_events(ov, 1);
    out("  rect {d} {d} {d}", .{ c.gst_video_overlay_set_render_rectangle(ov, 1, 2, 3, 4), c.gst_video_overlay_set_render_rectangle(ov, 0, 0, -1, -1), c.gst_video_overlay_set_render_rectangle(ov, 0, 0, 0, 5) });
    var arr = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&arr, c.gst_value_array_get_type());
    for ([_]c.gint{ 5, 6, 7, 8 }) |x| {
        var e = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&e, c.G_TYPE_INT);
        c.g_value_set_int(&e, x);
        c.gst_value_array_append_value(&arr, &e);
        c.g_value_unset(&e);
    }
    c.g_object_set_property(@ptrCast(@alignCast(o)), "render-rectangle", &arr);
    var bad = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&bad, c.gst_value_array_get_type());
    var e2 = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&e2, c.G_TYPE_DOUBLE);
    c.g_value_set_double(&e2, 1.5);
    c.gst_value_array_append_value(&bad, &e2);
    c.g_object_set_property(@ptrCast(@alignCast(o)), "render-rectangle", &bad);
    c.g_value_unset(&e2);
    c.g_value_unset(&bad);
    c.g_value_unset(&arr);
    const pspec = c.g_object_class_find_property(@ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(o))).g_class)), "render-rectangle");
    out("  pspec {s} {s} flags {d}", .{ c.g_param_spec_get_name(pspec), c.g_param_spec_get_blurb(pspec), pspec[0].flags });
    var dir: c.gint = -1;
    c.g_object_get(o, "video-direction", &dir, NONE);
    const dp = c.g_object_interface_find_property(c.g_type_default_interface_ref(c.gst_video_direction_get_type()), "video-direction");
    out("  direction {d} spec {s} flags {d} default {d}", .{ dir, c.g_param_spec_get_nick(dp), dp[0].flags, @as(*c.GParamSpecEnum, @ptrCast(@alignCast(dp))).default_value });
    const ch: [*c]c.GstColorBalanceChannel = @ptrCast(@alignCast(c.g_object_new(c.gst_color_balance_channel_get_type(), null)));
    out("  channel init {d} {d} null {d}", .{ ch[0].min_value, ch[0].max_value, @intFromBool(ch[0].label == null) });
    ch[0].label = c.g_strdup("HUE");
    ch[0].min_value = -10;
    ch[0].max_value = 10;
    channels = c.g_list_append(null, ch);
    const cb: ?*c.GstColorBalance = @ptrCast(o);
    const l = c.gst_color_balance_list_channels(cb);
    out("  channels {d} {s}", .{ c.g_list_length(@constCast(l)), @as([*c]c.GstColorBalanceChannel, @ptrCast(@alignCast(l[0].data)))[0].label });
    c.gst_color_balance_set_value(cb, ch, 3);
    out("  value {d} type {d}", .{ c.gst_color_balance_get_value(cb, ch), c.gst_color_balance_get_balance_type(cb) });
    c.gst_color_balance_value_changed(cb, ch, 4);
    var flip: c.gboolean = 0;
    var center: c.gint = 0;
    const vo: ?*c.GstVideoOrientation = @ptrCast(o);
    out("  orient {d} {d} {d} {d} {d}", .{ c.gst_video_orientation_get_hflip(vo, &flip), flip, c.gst_video_orientation_get_vflip(vo, &flip), c.gst_video_orientation_get_hcenter(vo, &center), c.gst_video_orientation_set_vcenter(vo, 9) });
    out("  orient set {d} {d} {d} {d}", .{ c.gst_video_orientation_set_hflip(vo, 1), c.gst_video_orientation_set_vflip(vo, 1), c.gst_video_orientation_set_hcenter(vo, 1), c.gst_video_orientation_get_vcenter(vo, &center) });
    const plain = c.g_object_new(tb, null);
    out("  plain balance {d}", .{c.gst_color_balance_get_value(@ptrCast(plain), ch)});
    c.gst_video_overlay_expose(@ptrCast(plain));
    c.gst_video_overlay_expose(null);
    c.gst_navigation_send_command(@ptrCast(c.gst_bus_new()), 0);
    c.gst_object_unref(plain);
    for ([_]c.GType{ c.gst_navigation_get_type(), c.gst_video_overlay_get_type(), c.gst_color_balance_get_type(), c.gst_video_orientation_get_type(), c.gst_video_direction_get_type(), c.gst_color_balance_channel_get_type() }) |t| {
        var np: c.guint = 0;
        const pre = c.g_type_interface_prerequisites(t, &np);
        out("  type {s} fundamental {d} prereq {d}", .{ c.g_type_name(t), c.g_type_fundamental(t), np });
        c.g_free(pre);
    }
    c.g_list_free(channels);
    c.g_object_unref(ch);
    c.gst_element_set_bus(@ptrCast(@alignCast(o)), null);
    c.gst_object_unref(bus);
    c.gst_object_unref(o);
}

pub fn main() void {
    c.gst_init(null, null);
    events();
    queries();
    messages();
    interfaces();
}
