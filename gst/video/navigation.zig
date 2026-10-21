const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Nav = c.GstNavigation;
const Iface = c.GstNavigationInterface;
const Event = c.GstEvent;
const Query = c.GstQuery;
const Message = c.GstMessage;
const Structure = c.GstStructure;
const Mod = c.GstNavigationModifierType;
const NONE = @as(?*anyopaque, null);

const EVENT_NAME = "application/x-gst-navigation";
const QUERY_NAME = "GstNavigationQuery";
const MESSAGE_NAME = "GstNavigationMessage";

var type_once: gtype.Once = .{};

fn defaultSimple(nav: ?*Nav, event: [*c]Event) callconv(.c) void {
    const i = iface(nav);
    if (i.send_event) |f| {
        f(nav, c.gst_structure_copy(c.gst_event_get_structure(event)));
    } else c.gst_event_unref(event);
}

fn defaultInit(p: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *Iface = @ptrCast(@alignCast(p));
    i.send_event = null;
    i.send_event_simple = defaultSimple;
}

pub export fn gst_navigation_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(c.G_TYPE_INTERFACE, "GstNavigation", @sizeOf(Iface), defaultInit, 0, null, 0);
        }
    }.f);
}

fn iface(nav: ?*Nav) *Iface {
    return @ptrCast(@alignCast(c.g_type_interface_peek(@as(*c.GTypeInstance, @ptrCast(@alignCast(nav))).g_class, gst_navigation_get_type())));
}

fn isNav(nav: ?*Nav) bool {
    return gtype.instanceOf(nav, gst_navigation_get_type());
}

fn warnIf(ok: bool, comptime msg: []const u8) void {
    if (!ok) c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "%s", @as([*c]const u8, msg ++ ""));
}

pub export fn gst_navigation_send_event(nav: ?*Nav, structure: [*c]Structure) void {
    if (!check.that(isNav(nav), "gst_navigation_send_event", "GST_IS_NAVIGATION (navigation)")) return;
    const i = iface(nav);
    if (i.send_event) |f| {
        f(nav, structure);
    } else if (i.send_event_simple) |f| {
        f(nav, c.gst_event_new_navigation(structure));
    } else c.gst_structure_free(structure);
}

pub export fn gst_navigation_send_key_event(nav: ?*Nav, event: [*c]const u8, key: [*c]const u8) void {
    const fname = "gst_navigation_send_key_event";
    if (!check.that(isNav(nav), fname, "GST_IS_NAVIGATION (navigation)")) return;
    if (!check.that(c.g_strcmp0(event, "key-press") == 0 or c.g_strcmp0(event, "key-release") == 0, fname, "g_strcmp0 (event, \"key-press\") == 0 || g_strcmp0 (event, \"key-release\") == 0")) return;
    gst_navigation_send_event(nav, c.gst_structure_new(EVENT_NAME, "event", c.G_TYPE_STRING, event, "key", c.G_TYPE_STRING, key, NONE));
}

pub export fn gst_navigation_send_mouse_event(nav: ?*Nav, event: [*c]const u8, button: c_int, x: f64, y: f64) void {
    const fname = "gst_navigation_send_mouse_event";
    if (!check.that(isNav(nav), fname, "GST_IS_NAVIGATION (navigation)")) return;
    const ok = c.g_strcmp0(event, "mouse-button-press") == 0 or c.g_strcmp0(event, "mouse-button-release") == 0 or c.g_strcmp0(event, "mouse-move") == 0 or c.g_strcmp0(event, "mouse-double-click") == 0;
    if (!check.that(ok, fname, "g_strcmp0 (event, \"mouse-button-press\") == 0 || g_strcmp0 (event, \"mouse-button-release\") == 0 || g_strcmp0 (event, \"mouse-move\") == 0 || g_strcmp0 (event, \"mouse-double-click\") == 0")) return;
    gst_navigation_send_event(nav, c.gst_structure_new(EVENT_NAME, "event", c.G_TYPE_STRING, event, "button", c.G_TYPE_INT, button, "pointer_x", c.G_TYPE_DOUBLE, x, "pointer_y", c.G_TYPE_DOUBLE, y, NONE));
}

pub export fn gst_navigation_send_mouse_scroll_event(nav: ?*Nav, x: f64, y: f64, delta_x: f64, delta_y: f64) void {
    if (!check.that(isNav(nav), "gst_navigation_send_mouse_scroll_event", "GST_IS_NAVIGATION (navigation)")) return;
    gst_navigation_send_event(nav, c.gst_structure_new(EVENT_NAME, "event", c.G_TYPE_STRING, "mouse-scroll", "pointer_x", c.G_TYPE_DOUBLE, x, "pointer_y", c.G_TYPE_DOUBLE, y, "delta_pointer_x", c.G_TYPE_DOUBLE, delta_x, "delta_pointer_y", c.G_TYPE_DOUBLE, delta_y, NONE));
}

pub export fn gst_navigation_send_command(nav: ?*Nav, command: c.GstNavigationCommand) void {
    if (!check.that(isNav(nav), "gst_navigation_send_command", "GST_IS_NAVIGATION (navigation)")) return;
    gst_navigation_send_event(nav, c.gst_structure_new(EVENT_NAME, "event", c.G_TYPE_STRING, "command", "command-code", c.G_TYPE_UINT, @as(c.guint, @bitCast(command)), NONE));
}

pub export fn gst_navigation_send_event_simple(nav: ?*Nav, event: [*c]Event) void {
    const fname = "gst_navigation_send_event_simple";
    if (!check.that(isNav(nav), fname, "GST_IS_NAVIGATION (navigation)")) return;
    if (!check.that(event[0].type == c.GST_EVENT_NAVIGATION, fname, "GST_EVENT_TYPE (event) == GST_EVENT_NAVIGATION")) return;
    const i = iface(nav);
    if (i.send_event_simple) |f| {
        f(nav, event);
    } else if (i.send_event) |f| {
        f(nav, c.gst_structure_copy(c.gst_event_get_structure(event)));
        c.gst_event_unref(event);
    } else c.gst_event_unref(event);
}

fn typeIs(s: ?*const Structure, comptime name: [*:0]const u8, comptime field: [*:0]const u8) ?[*:0]const u8 {
    if (s == null or c.gst_structure_has_name(s, name) == 0) return null;
    const t = c.gst_structure_get_string(s, field);
    if (t == null) return null;
    return t;
}

fn eq(a: [*:0]const u8, comptime b: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(a), b);
}

pub export fn gst_navigation_query_get_type(query: [*c]Query) c.GstNavigationQueryType {
    if (query == null or query[0].type != c.GST_QUERY_CUSTOM) return c.GST_NAVIGATION_QUERY_INVALID;
    const t = typeIs(c.gst_query_get_structure(query), QUERY_NAME, "type") orelse return c.GST_NAVIGATION_QUERY_INVALID;
    if (eq(t, "commands")) return c.GST_NAVIGATION_QUERY_COMMANDS;
    if (eq(t, "angles")) return c.GST_NAVIGATION_QUERY_ANGLES;
    return c.GST_NAVIGATION_QUERY_INVALID;
}

pub export fn gst_navigation_query_new_commands() [*c]Query {
    return c.gst_query_new_custom(c.GST_QUERY_CUSTOM, c.gst_structure_new(QUERY_NAME, "type", c.G_TYPE_STRING, "commands", NONE));
}

fn addCommand(list: *c.GValue, v: c.GstNavigationCommand) void {
    var item = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&item, c.gst_navigation_command_get_type());
    c.g_value_set_enum(&item, @bitCast(v));
    c.gst_value_list_append_value(list, &item);
    c.g_value_unset(&item);
}

fn isCommands(q: [*c]Query) bool {
    return gst_navigation_query_get_type(q) == c.GST_NAVIGATION_QUERY_COMMANDS;
}

fn isAngles(q: [*c]Query) bool {
    return gst_navigation_query_get_type(q) == c.GST_NAVIGATION_QUERY_ANGLES;
}

pub export fn gst_navigation_query_set_commands(query: [*c]Query, n_cmds: c.gint, ...) callconv(.c) void {
    if (!check.that(isCommands(query), "gst_navigation_query_set_commands", "GST_NAVIGATION_QUERY_HAS_TYPE (query, COMMANDS)")) return;
    var list = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&list, c.gst_value_list_get_type());
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var i: c.gint = 0;
    while (i < n_cmds) : (i += 1) addCommand(&list, @cVaArg(&ap, c.GstNavigationCommand));
    c.gst_structure_take_value(c.gst_query_writable_structure(query), "commands", &list);
}

pub export fn gst_navigation_query_set_commandsv(query: [*c]Query, n_cmds: c.gint, cmds: [*c]c.GstNavigationCommand) void {
    if (!check.that(isCommands(query), "gst_navigation_query_set_commandsv", "GST_NAVIGATION_QUERY_HAS_TYPE (query, COMMANDS)")) return;
    var list = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&list, c.gst_value_list_get_type());
    var i: usize = 0;
    while (i < n_cmds) : (i += 1) addCommand(&list, cmds[i]);
    c.gst_structure_take_value(c.gst_query_writable_structure(query), "commands", &list);
}

pub export fn gst_navigation_query_parse_commands_length(query: [*c]Query, n_cmds: [*c]c.guint) c.gboolean {
    if (!check.that(isCommands(query), "gst_navigation_query_parse_commands_length", "GST_NAVIGATION_QUERY_HAS_TYPE (query, COMMANDS)")) return 0;
    if (n_cmds == null) return 1;
    const list = c.gst_structure_get_value(c.gst_query_get_structure(query), "commands");
    n_cmds[0] = if (list == null) 0 else c.gst_value_list_get_size(list);
    return 1;
}

pub export fn gst_navigation_query_parse_commands_nth(query: [*c]Query, nth: c.guint, cmd: [*c]c.GstNavigationCommand) c.gboolean {
    if (!check.that(isCommands(query), "gst_navigation_query_parse_commands_nth", "GST_NAVIGATION_QUERY_HAS_TYPE (query, COMMANDS)")) return 0;
    if (cmd == null) return 1;
    const list = c.gst_structure_get_value(c.gst_query_get_structure(query), "commands");
    if (list != null and nth < c.gst_value_list_get_size(list)) {
        cmd[0] = @bitCast(c.g_value_get_enum(c.gst_value_list_get_value(list, nth)));
    } else cmd[0] = c.GST_NAVIGATION_COMMAND_INVALID;
    return 1;
}

pub export fn gst_navigation_query_new_angles() [*c]Query {
    return c.gst_query_new_custom(c.GST_QUERY_CUSTOM, c.gst_structure_new(QUERY_NAME, "type", c.G_TYPE_STRING, "angles", NONE));
}

pub export fn gst_navigation_query_set_angles(query: [*c]Query, cur_angle: c.guint, n_angles: c.guint) void {
    if (!check.that(isAngles(query), "gst_navigation_query_set_angles", "GST_NAVIGATION_QUERY_HAS_TYPE (query, ANGLES)")) return;
    c.gst_structure_set(c.gst_query_writable_structure(query), "angle", c.G_TYPE_UINT, cur_angle, "angles", c.G_TYPE_UINT, n_angles, NONE);
}

fn getAngles(s: ?*const Structure, cur: [*c]c.guint, n: [*c]c.guint) bool {
    var ok: c.gboolean = 1;
    if (cur != null) ok &= c.gst_structure_get_uint(s, "angle", cur);
    if (n != null) ok &= c.gst_structure_get_uint(s, "angles", n);
    return ok != 0;
}

pub export fn gst_navigation_query_parse_angles(query: [*c]Query, cur_angle: [*c]c.guint, n_angles: [*c]c.guint) c.gboolean {
    if (!check.that(isAngles(query), "gst_navigation_query_parse_angles", "GST_NAVIGATION_QUERY_HAS_TYPE (query, ANGLES)")) return 0;
    const ok = getAngles(c.gst_query_get_structure(query), cur_angle, n_angles);
    warnIf(ok, "Couldn't extract details from angles query");
    return @intFromBool(ok);
}

pub export fn gst_navigation_message_get_type(message: [*c]Message) c.GstNavigationMessageType {
    if (message == null or message[0].type != c.GST_MESSAGE_ELEMENT) return c.GST_NAVIGATION_MESSAGE_INVALID;
    const t = typeIs(c.gst_message_get_structure(message), MESSAGE_NAME, "type") orelse return c.GST_NAVIGATION_MESSAGE_INVALID;
    if (eq(t, "mouse-over")) return c.GST_NAVIGATION_MESSAGE_MOUSE_OVER;
    if (eq(t, "commands-changed")) return c.GST_NAVIGATION_MESSAGE_COMMANDS_CHANGED;
    if (eq(t, "angles-changed")) return c.GST_NAVIGATION_MESSAGE_ANGLES_CHANGED;
    if (eq(t, "event")) return c.GST_NAVIGATION_MESSAGE_EVENT;
    return c.GST_NAVIGATION_MESSAGE_INVALID;
}

fn element(src: [*c]c.GstObject, s: [*c]Structure) [*c]Message {
    return c.gst_message_new_custom(c.GST_MESSAGE_ELEMENT, src, s);
}

pub export fn gst_navigation_message_new_mouse_over(src: [*c]c.GstObject, active: c.gboolean) [*c]Message {
    return element(src, c.gst_structure_new(MESSAGE_NAME, "type", c.G_TYPE_STRING, "mouse-over", "active", c.G_TYPE_BOOLEAN, active, NONE));
}

pub export fn gst_navigation_message_parse_mouse_over(message: [*c]Message, active: [*c]c.gboolean) c.gboolean {
    if (gst_navigation_message_get_type(message) != c.GST_NAVIGATION_MESSAGE_MOUSE_OVER) return 0;
    if (active != null and c.gst_structure_get_boolean(c.gst_message_get_structure(message), "active", active) == 0) return 0;
    return 1;
}

pub export fn gst_navigation_message_new_event(src: [*c]c.GstObject, event: [*c]Event) [*c]Message {
    return element(src, c.gst_structure_new(MESSAGE_NAME, "type", c.G_TYPE_STRING, "event", "event", c.gst_event_get_type(), event, NONE));
}

pub export fn gst_navigation_message_parse_event(message: [*c]Message, event: [*c][*c]Event) c.gboolean {
    if (gst_navigation_message_get_type(message) != c.GST_NAVIGATION_MESSAGE_EVENT) return 0;
    if (event != null and c.gst_structure_get(c.gst_message_get_structure(message), "event", c.gst_event_get_type(), event, NONE) == 0) return 0;
    return 1;
}

pub export fn gst_navigation_message_new_commands_changed(src: [*c]c.GstObject) [*c]Message {
    return element(src, c.gst_structure_new(MESSAGE_NAME, "type", c.G_TYPE_STRING, "commands-changed", NONE));
}

pub export fn gst_navigation_message_new_angles_changed(src: [*c]c.GstObject, cur_angle: c.guint, n_angles: c.guint) [*c]Message {
    return element(src, c.gst_structure_new(MESSAGE_NAME, "type", c.G_TYPE_STRING, "angles-changed", "angle", c.G_TYPE_UINT, cur_angle, "angles", c.G_TYPE_UINT, n_angles, NONE));
}

pub export fn gst_navigation_message_parse_angles_changed(message: [*c]Message, cur_angle: [*c]c.guint, n_angles: [*c]c.guint) c.gboolean {
    if (!check.that(gst_navigation_message_get_type(message) == c.GST_NAVIGATION_MESSAGE_ANGLES_CHANGED, "gst_navigation_message_parse_angles_changed", "GST_NAVIGATION_MESSAGE_HAS_TYPE (message, ANGLES_CHANGED)")) return 0;
    const ok = getAngles(c.gst_message_get_structure(message), cur_angle, n_angles);
    warnIf(ok, "Couldn't extract details from angles-changed event");
    return @intFromBool(ok);
}

const kinds = [_]struct { []const u8, c.GstNavigationEventType }{
    .{ "mouse-button-press", c.GST_NAVIGATION_EVENT_MOUSE_BUTTON_PRESS },
    .{ "mouse-button-release", c.GST_NAVIGATION_EVENT_MOUSE_BUTTON_RELEASE },
    .{ "mouse-move", c.GST_NAVIGATION_EVENT_MOUSE_MOVE },
    .{ "mouse-scroll", c.GST_NAVIGATION_EVENT_MOUSE_SCROLL },
    .{ "key-press", c.GST_NAVIGATION_EVENT_KEY_PRESS },
    .{ "key-release", c.GST_NAVIGATION_EVENT_KEY_RELEASE },
    .{ "command", c.GST_NAVIGATION_EVENT_COMMAND },
    .{ "touch-down", c.GST_NAVIGATION_EVENT_TOUCH_DOWN },
    .{ "touch-up", c.GST_NAVIGATION_EVENT_TOUCH_UP },
    .{ "touch-cancel", c.GST_NAVIGATION_EVENT_TOUCH_CANCEL },
    .{ "touch-motion", c.GST_NAVIGATION_EVENT_TOUCH_MOTION },
    .{ "touch-frame", c.GST_NAVIGATION_EVENT_TOUCH_FRAME },
    .{ "mouse-double-click", c.GST_NAVIGATION_EVENT_MOUSE_DOUBLE_CLICK },
};

pub export fn gst_navigation_event_get_type(event: [*c]Event) c.GstNavigationEventType {
    if (event == null or event[0].type != c.GST_EVENT_NAVIGATION) return c.GST_NAVIGATION_EVENT_INVALID;
    const t = typeIs(c.gst_event_get_structure(event), EVENT_NAME, "event") orelse return c.GST_NAVIGATION_EVENT_INVALID;
    const s = std.mem.span(t);
    for (kinds) |k| {
        if (std.mem.eql(u8, s, k[0])) return k[1];
    }
    return c.GST_NAVIGATION_EVENT_INVALID;
}

fn navEvent(s: [*c]Structure) [*c]Event {
    return c.gst_event_new_navigation(s);
}

fn modType() c.GType {
    return c.gst_navigation_modifier_type_get_type();
}

pub export fn gst_navigation_event_new_key_press(key: [*c]const u8, state: Mod) [*c]Event {
    return navEvent(c.gst_structure_new(EVENT_NAME, "event", c.G_TYPE_STRING, "key-press", "key", c.G_TYPE_STRING, key, "state", modType(), state, NONE));
}

pub export fn gst_navigation_event_new_key_release(key: [*c]const u8, state: Mod) [*c]Event {
    return navEvent(c.gst_structure_new(EVENT_NAME, "event", c.G_TYPE_STRING, "key-release", "key", c.G_TYPE_STRING, key, "state", modType(), state, NONE));
}

fn buttonEvent(comptime name: [*:0]const u8, b: c.gint, x: f64, y: f64, state: Mod) [*c]Event {
    return navEvent(c.gst_structure_new(EVENT_NAME, "event", c.G_TYPE_STRING, name, "button", c.G_TYPE_INT, b, "pointer_x", c.G_TYPE_DOUBLE, x, "pointer_y", c.G_TYPE_DOUBLE, y, "state", modType(), state, NONE));
}

pub export fn gst_navigation_event_new_mouse_button_press(b: c.gint, x: f64, y: f64, state: Mod) [*c]Event {
    return buttonEvent("mouse-button-press", b, x, y, state);
}

pub export fn gst_navigation_event_new_mouse_double_click(b: c.gint, x: f64, y: f64, state: Mod) [*c]Event {
    return buttonEvent("mouse-double-click", b, x, y, state);
}

pub export fn gst_navigation_event_new_mouse_button_release(b: c.gint, x: f64, y: f64, state: Mod) [*c]Event {
    return buttonEvent("mouse-button-release", b, x, y, state);
}

pub export fn gst_navigation_event_new_mouse_move(x: f64, y: f64, state: Mod) [*c]Event {
    return navEvent(c.gst_structure_new(EVENT_NAME, "event", c.G_TYPE_STRING, "mouse-move", "pointer_x", c.G_TYPE_DOUBLE, x, "pointer_y", c.G_TYPE_DOUBLE, y, "state", modType(), state, NONE));
}

pub export fn gst_navigation_event_new_mouse_scroll(x: f64, y: f64, delta_x: f64, delta_y: f64, state: Mod) [*c]Event {
    return navEvent(c.gst_structure_new(EVENT_NAME, "event", c.G_TYPE_STRING, "mouse-scroll", "pointer_x", c.G_TYPE_DOUBLE, x, "pointer_y", c.G_TYPE_DOUBLE, y, "delta_pointer_x", c.G_TYPE_DOUBLE, delta_x, "delta_pointer_y", c.G_TYPE_DOUBLE, delta_y, "state", modType(), state, NONE));
}

pub export fn gst_navigation_event_new_command(command: c.GstNavigationCommand) [*c]Event {
    return navEvent(c.gst_structure_new(EVENT_NAME, "event", c.G_TYPE_STRING, "command", "command-code", c.G_TYPE_UINT, @as(c.guint, @bitCast(command)), NONE));
}

fn touch(comptime name: [*:0]const u8, id: c.guint, x: f64, y: f64, pressure: f64, state: Mod) [*c]Event {
    return navEvent(c.gst_structure_new(EVENT_NAME, "event", c.G_TYPE_STRING, name, "identifier", c.G_TYPE_UINT, id, "pointer_x", c.G_TYPE_DOUBLE, x, "pointer_y", c.G_TYPE_DOUBLE, y, "pressure", c.G_TYPE_DOUBLE, pressure, "state", modType(), state, NONE));
}

pub export fn gst_navigation_event_new_touch_down(identifier: c.guint, x: f64, y: f64, pressure: f64, state: Mod) [*c]Event {
    return touch("touch-down", identifier, x, y, pressure, state);
}

pub export fn gst_navigation_event_new_touch_motion(identifier: c.guint, x: f64, y: f64, pressure: f64, state: Mod) [*c]Event {
    return touch("touch-motion", identifier, x, y, pressure, state);
}

pub export fn gst_navigation_event_new_touch_up(identifier: c.guint, x: f64, y: f64, state: Mod) [*c]Event {
    return navEvent(c.gst_structure_new(EVENT_NAME, "event", c.G_TYPE_STRING, "touch-up", "identifier", c.G_TYPE_UINT, identifier, "pointer_x", c.G_TYPE_DOUBLE, x, "pointer_y", c.G_TYPE_DOUBLE, y, "state", modType(), state, NONE));
}

pub export fn gst_navigation_event_new_touch_frame(state: Mod) [*c]Event {
    return navEvent(c.gst_structure_new(EVENT_NAME, "event", c.G_TYPE_STRING, "touch-frame", "state", modType(), state, NONE));
}

pub export fn gst_navigation_event_new_touch_cancel(state: Mod) [*c]Event {
    return navEvent(c.gst_structure_new(EVENT_NAME, "event", c.G_TYPE_STRING, "touch-cancel", "state", modType(), state, NONE));
}

fn kind(e: [*c]Event) c.GstNavigationEventType {
    return gst_navigation_event_get_type(e);
}

fn getD(s: ?*const Structure, comptime f: [*:0]const u8, p: [*c]f64, ok: *c.gboolean) void {
    if (p != null) ok.* &= c.gst_structure_get_double(s, f, p);
}

fn getU(s: ?*const Structure, comptime f: [*:0]const u8, p: [*c]c.guint, ok: *c.gboolean) void {
    if (p != null) ok.* &= c.gst_structure_get_uint(s, f, p);
}

pub export fn gst_navigation_event_parse_key_event(event: [*c]Event, key: [*c][*c]const u8) c.gboolean {
    const t = kind(event);
    if (!check.that(t == c.GST_NAVIGATION_EVENT_KEY_PRESS or t == c.GST_NAVIGATION_EVENT_KEY_RELEASE, "gst_navigation_event_parse_key_event", "e_type == GST_NAVIGATION_EVENT_KEY_PRESS || e_type == GST_NAVIGATION_EVENT_KEY_RELEASE")) return 0;
    if (key != null) {
        key[0] = c.gst_structure_get_string(c.gst_event_get_structure(event), "key");
        if (key[0] == null) return 0;
    }
    return 1;
}

pub export fn gst_navigation_event_parse_mouse_button_event(event: [*c]Event, b: [*c]c.gint, x: [*c]f64, y: [*c]f64) c.gboolean {
    const t = kind(event);
    if (!check.that(t == c.GST_NAVIGATION_EVENT_MOUSE_BUTTON_PRESS or t == c.GST_NAVIGATION_EVENT_MOUSE_BUTTON_RELEASE or t == c.GST_NAVIGATION_EVENT_MOUSE_DOUBLE_CLICK, "gst_navigation_event_parse_mouse_button_event", "e_type == GST_NAVIGATION_EVENT_MOUSE_BUTTON_PRESS || e_type == GST_NAVIGATION_EVENT_MOUSE_BUTTON_RELEASE || e_type == GST_NAVIGATION_EVENT_MOUSE_DOUBLE_CLICK")) return 0;
    const s = c.gst_event_get_structure(event);
    var ok: c.gboolean = 1;
    getD(s, "pointer_x", x, &ok);
    getD(s, "pointer_y", y, &ok);
    if (b != null) ok &= c.gst_structure_get_int(s, "button", b);
    warnIf(ok != 0, "Couldn't extract details from mouse button event");
    return ok;
}

pub export fn gst_navigation_event_parse_mouse_move_event(event: [*c]Event, x: [*c]f64, y: [*c]f64) c.gboolean {
    if (!check.that(kind(event) == c.GST_NAVIGATION_EVENT_MOUSE_MOVE, "gst_navigation_event_parse_mouse_move_event", "GST_NAVIGATION_EVENT_HAS_TYPE (event, MOUSE_MOVE)")) return 0;
    const s = c.gst_event_get_structure(event);
    var ok: c.gboolean = 1;
    getD(s, "pointer_x", x, &ok);
    getD(s, "pointer_y", y, &ok);
    warnIf(ok != 0, "Couldn't extract positions from mouse move event");
    return ok;
}

pub export fn gst_navigation_event_parse_mouse_scroll_event(event: [*c]Event, x: [*c]f64, y: [*c]f64, delta_x: [*c]f64, delta_y: [*c]f64) c.gboolean {
    if (!check.that(kind(event) == c.GST_NAVIGATION_EVENT_MOUSE_SCROLL, "gst_navigation_event_parse_mouse_scroll_event", "GST_NAVIGATION_EVENT_HAS_TYPE (event, MOUSE_SCROLL)")) return 0;
    const s = c.gst_event_get_structure(event);
    var ok: c.gboolean = 1;
    getD(s, "pointer_x", x, &ok);
    getD(s, "pointer_y", y, &ok);
    getD(s, "delta_pointer_x", delta_x, &ok);
    getD(s, "delta_pointer_y", delta_y, &ok);
    warnIf(ok != 0, "Couldn't extract positions from mouse scroll event");
    return ok;
}

pub export fn gst_navigation_event_parse_command(event: [*c]Event, command: [*c]c.GstNavigationCommand) c.gboolean {
    if (!check.that(kind(event) == c.GST_NAVIGATION_EVENT_COMMAND, "gst_navigation_event_parse_command", "GST_NAVIGATION_EVENT_HAS_TYPE (event, COMMAND)")) return 0;
    var ok: c.gboolean = 1;
    if (command != null) {
        ok = c.gst_structure_get_uint(c.gst_event_get_structure(event), "command-code", @ptrCast(command));
        warnIf(ok != 0, "Couldn't extract command code from command event");
    }
    return ok;
}

pub export fn gst_navigation_event_parse_touch_event(event: [*c]Event, identifier: [*c]c.guint, x: [*c]f64, y: [*c]f64, pressure: [*c]f64) c.gboolean {
    const t = kind(event);
    if (!check.that(t == c.GST_NAVIGATION_EVENT_TOUCH_DOWN or t == c.GST_NAVIGATION_EVENT_TOUCH_MOTION, "gst_navigation_event_parse_touch_event", "e_type == GST_NAVIGATION_EVENT_TOUCH_DOWN || e_type == GST_NAVIGATION_EVENT_TOUCH_MOTION")) return 0;
    const s = c.gst_event_get_structure(event);
    var ok: c.gboolean = 1;
    getU(s, "identifier", identifier, &ok);
    getD(s, "pointer_x", x, &ok);
    getD(s, "pointer_y", y, &ok);
    getD(s, "pressure", pressure, &ok);
    warnIf(ok != 0, "Couldn't extract details from touch event");
    return ok;
}

pub export fn gst_navigation_event_parse_touch_up_event(event: [*c]Event, identifier: [*c]c.guint, x: [*c]f64, y: [*c]f64) c.gboolean {
    if (!check.that(kind(event) == c.GST_NAVIGATION_EVENT_TOUCH_UP, "gst_navigation_event_parse_touch_up_event", "GST_NAVIGATION_EVENT_HAS_TYPE (event, TOUCH_UP)")) return 0;
    const s = c.gst_event_get_structure(event);
    var ok: c.gboolean = 1;
    getU(s, "identifier", identifier, &ok);
    getD(s, "pointer_x", x, &ok);
    getD(s, "pointer_y", y, &ok);
    warnIf(ok != 0, "Couldn't extract details from touch-up event");
    return ok;
}

fn positional(t: c.GstNavigationEventType) bool {
    return switch (t) {
        c.GST_NAVIGATION_EVENT_MOUSE_MOVE, c.GST_NAVIGATION_EVENT_MOUSE_BUTTON_PRESS, c.GST_NAVIGATION_EVENT_MOUSE_BUTTON_RELEASE, c.GST_NAVIGATION_EVENT_TOUCH_DOWN, c.GST_NAVIGATION_EVENT_TOUCH_MOTION, c.GST_NAVIGATION_EVENT_TOUCH_UP => true,
        else => false,
    };
}

pub export fn gst_navigation_event_get_coordinates(event: [*c]Event, x: [*c]f64, y: [*c]f64) c.gboolean {
    if (!positional(kind(event))) return 0;
    const s = c.gst_event_get_structure(event);
    var ok: c.gboolean = 1;
    getD(s, "pointer_x", x, &ok);
    getD(s, "pointer_y", y, &ok);
    warnIf(ok != 0, "Couldn't extract coordinates from the event");
    return ok;
}

pub export fn gst_navigation_event_set_coordinates(event: [*c]Event, x: f64, y: f64) c.gboolean {
    if (!check.that(c.gst_mini_object_is_writable(@ptrCast(event)) != 0, "gst_navigation_event_set_coordinates", "gst_event_is_writable (event)")) return 0;
    if (!positional(kind(event))) return 0;
    c.gst_structure_set(c.gst_event_writable_structure(event), "pointer_x", c.G_TYPE_DOUBLE, x, "pointer_y", c.G_TYPE_DOUBLE, y, NONE);
    return 1;
}

pub export fn gst_navigation_event_parse_modifier_state(event: [*c]Event, state: [*c]Mod) c.gboolean {
    const isEvent = event != null and event[0].mini_object.type == c.gst_event_get_type();
    if (!check.that(isEvent, "gst_navigation_event_parse_modifier_state", "GST_IS_EVENT (event)")) return 0;
    if (kind(event) == c.GST_NAVIGATION_EVENT_COMMAND) return 0;
    if (c.gst_structure_get(c.gst_event_get_structure(event), "state", modType(), state, NONE) == 0) state[0] = c.GST_NAVIGATION_MODIFIER_NONE;
    return 1;
}
