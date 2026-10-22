const c = @import("../../c.zig").c;

const Iface = c.struct_wl_interface;
const Msg = c.struct_wl_message;

fn msg(comptime name: [*:0]const u8, comptime sig: [*:0]const u8, t: [*]const ?*const Iface) Msg {
    return .{ .name = name, .signature = sig, .types = @ptrCast(@constCast(t)) };
}

var types: [26]?*const Iface = .{
    null,                     null,                  null,                    null,
    &positioner,              &surface,              &c.wl_surface_interface, &toplevel,
    &popup,                   &surface,              &positioner,             &toplevel,
    &c.wl_seat_interface,     null,                  null,                    null,
    &c.wl_seat_interface,     null,                  &c.wl_seat_interface,    null,
    null,                     &c.wl_output_interface, &c.wl_seat_interface,   null,
    &positioner,              null,
};

const wm_requests = [_]Msg{ msg("destroy", "", types[0..]), msg("create_positioner", "n", types[4..]), msg("get_xdg_surface", "no", types[5..]), msg("pong", "u", types[0..]) };
const wm_events = [_]Msg{msg("ping", "u", types[0..])};
pub const wm_base = Iface{ .name = "xdg_wm_base", .version = 7, .method_count = 4, .methods = &wm_requests, .event_count = 1, .events = &wm_events };

const positioner_requests = [_]Msg{ msg("destroy", "", types[0..]), msg("set_size", "ii", types[0..]), msg("set_anchor_rect", "iiii", types[0..]), msg("set_anchor", "u", types[0..]), msg("set_gravity", "u", types[0..]), msg("set_constraint_adjustment", "u", types[0..]), msg("set_offset", "ii", types[0..]), msg("set_reactive", "3", types[0..]), msg("set_parent_size", "3ii", types[0..]), msg("set_parent_configure", "3u", types[0..]) };
const positioner = Iface{ .name = "xdg_positioner", .version = 7, .method_count = 10, .methods = &positioner_requests, .event_count = 0, .events = null };

const surface_requests = [_]Msg{ msg("destroy", "", types[0..]), msg("get_toplevel", "n", types[7..]), msg("get_popup", "n?oo", types[8..]), msg("set_window_geometry", "iiii", types[0..]), msg("ack_configure", "u", types[0..]) };
const surface_events = [_]Msg{msg("configure", "u", types[0..])};
const surface = Iface{ .name = "xdg_surface", .version = 7, .method_count = 5, .methods = &surface_requests, .event_count = 1, .events = &surface_events };

const toplevel_requests = [_]Msg{ msg("destroy", "", types[0..]), msg("set_parent", "?o", types[11..]), msg("set_title", "s", types[0..]), msg("set_app_id", "s", types[0..]), msg("show_window_menu", "ouii", types[12..]), msg("move", "ou", types[16..]), msg("resize", "ouu", types[18..]), msg("set_max_size", "ii", types[0..]), msg("set_min_size", "ii", types[0..]), msg("set_maximized", "", types[0..]), msg("unset_maximized", "", types[0..]), msg("set_fullscreen", "?o", types[21..]), msg("unset_fullscreen", "", types[0..]), msg("set_minimized", "", types[0..]) };
const toplevel_events = [_]Msg{ msg("configure", "iia", types[0..]), msg("close", "", types[0..]), msg("configure_bounds", "4ii", types[0..]), msg("wm_capabilities", "5a", types[0..]) };
const toplevel = Iface{ .name = "xdg_toplevel", .version = 7, .method_count = 14, .methods = &toplevel_requests, .event_count = 4, .events = &toplevel_events };

const popup_requests = [_]Msg{ msg("destroy", "", types[0..]), msg("grab", "ou", types[22..]), msg("reposition", "3ou", types[24..]) };
const popup_events = [_]Msg{ msg("configure", "iiii", types[0..]), msg("popup_done", "", types[0..]), msg("repositioned", "3u", types[0..]) };
const popup = Iface{ .name = "xdg_popup", .version = 7, .method_count = 3, .methods = &popup_requests, .event_count = 3, .events = &popup_events };

pub const STATE_FULLSCREEN = 2;

const Proxy = ?*c.struct_wl_proxy;

fn proxy(p: anytype) Proxy {
    return @ptrCast(p);
}

pub fn getXdgSurface(wm: ?*anyopaque, s: ?*c.struct_wl_surface) ?*anyopaque {
    const p = proxy(wm);
    return c.wl_proxy_marshal_flags(p, 2, &surface, c.wl_proxy_get_version(p), 0, @as(?*anyopaque, null), s);
}

pub fn pong(wm: ?*anyopaque, serial: u32) void {
    const p = proxy(wm);
    _ = c.wl_proxy_marshal_flags(p, 3, null, c.wl_proxy_get_version(p), 0, serial);
}

pub fn wmDestroy(wm: ?*anyopaque) void {
    const p = proxy(wm);
    _ = c.wl_proxy_marshal_flags(p, 0, null, c.wl_proxy_get_version(p), c.WL_MARSHAL_FLAG_DESTROY);
}

pub fn getToplevel(xs: ?*anyopaque) ?*anyopaque {
    const p = proxy(xs);
    return c.wl_proxy_marshal_flags(p, 1, &toplevel, c.wl_proxy_get_version(p), 0, @as(?*anyopaque, null));
}

pub fn ackConfigure(xs: ?*anyopaque, serial: u32) void {
    const p = proxy(xs);
    _ = c.wl_proxy_marshal_flags(p, 4, null, c.wl_proxy_get_version(p), 0, serial);
}

pub fn surfaceDestroy(xs: ?*anyopaque) void {
    const p = proxy(xs);
    _ = c.wl_proxy_marshal_flags(p, 0, null, c.wl_proxy_get_version(p), c.WL_MARSHAL_FLAG_DESTROY);
}

pub fn setTitle(t: ?*anyopaque, title: [*c]const u8) void {
    const p = proxy(t);
    _ = c.wl_proxy_marshal_flags(p, 2, null, c.wl_proxy_get_version(p), 0, title);
}

pub fn setAppId(t: ?*anyopaque, id: [*c]const u8) void {
    const p = proxy(t);
    _ = c.wl_proxy_marshal_flags(p, 3, null, c.wl_proxy_get_version(p), 0, id);
}

pub fn toplevelDestroy(t: ?*anyopaque) void {
    const p = proxy(t);
    _ = c.wl_proxy_marshal_flags(p, 0, null, c.wl_proxy_get_version(p), c.WL_MARSHAL_FLAG_DESTROY);
}

pub fn addListener(obj: ?*anyopaque, listener: *const anyopaque, data: ?*anyopaque) c_int {
    return c.wl_proxy_add_listener(proxy(obj), @ptrCast(@alignCast(@constCast(listener))), data);
}
