const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const iterator = @import("iterator.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Def = c.GstFormatDefinition;

var lock: c.GMutex = std.mem.zeroes(c.GMutex);
var defs: [*c]c.GList = null;
var by_nick: ?*c.GHashTable = null;
var by_value: ?*c.GHashTable = null;
var count: c.guint32 = 1;

var standard = [_]Def{
    .{ .value = c.GST_FORMAT_DEFAULT, .nick = "default", .description = "Default format for the media type", .quark = 0 },
    .{ .value = c.GST_FORMAT_BYTES, .nick = "bytes", .description = "Bytes", .quark = 0 },
    .{ .value = c.GST_FORMAT_TIME, .nick = "time", .description = "Time", .quark = 0 },
    .{ .value = c.GST_FORMAT_BUFFERS, .nick = "buffers", .description = "Buffers", .quark = 0 },
    .{ .value = c.GST_FORMAT_PERCENT, .nick = "percent", .description = "Percent", .quark = 0 },
};

fn insert(d: *Def) void {
    _ = c.g_hash_table_insert(by_nick, @constCast(d.nick), d);
    _ = c.g_hash_table_insert(by_value, @ptrFromInt(@as(usize, @intCast(d.value))), d);
    defs = c.g_list_append(defs, d);
    count += 1;
}

pub fn initialize() void {
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    if (by_nick == null) {
        by_nick = c.g_hash_table_new(c.g_str_hash, c.g_str_equal);
        by_value = c.g_hash_table_new(null, null);
    }
    for (&standard) |*d| {
        d.quark = c.g_quark_from_static_string(d.nick);
        insert(d);
    }
    _ = c.g_type_class_ref(c.gst_format_get_type());
}

pub export fn gst_format_get_details(format: c.GstFormat) [*c]const Def {
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    return @ptrCast(@alignCast(c.g_hash_table_lookup(by_value, @ptrFromInt(@as(usize, @intCast(format))))));
}

pub export fn gst_format_get_name(format: c.GstFormat) [*c]const u8 {
    const d = gst_format_get_details(format);
    return if (d != null) d[0].nick else null;
}

pub export fn gst_format_to_quark(format: c.GstFormat) c.GQuark {
    const d = gst_format_get_details(format);
    return if (d != null) d[0].quark else 0;
}

pub export fn gst_format_get_by_nick(nick: [*c]const u8) c.GstFormat {
    if (!check.that(nick != null, "gst_format_get_by_nick", "nick != NULL")) return c.GST_FORMAT_UNDEFINED;
    c.g_mutex_lock(&lock);
    const d: [*c]const Def = @ptrCast(@alignCast(c.g_hash_table_lookup(by_nick, nick)));
    c.g_mutex_unlock(&lock);
    return if (d != null) d[0].value else c.GST_FORMAT_UNDEFINED;
}

pub export fn gst_format_register(nick: [*c]const u8, description: [*c]const u8) c.GstFormat {
    if (!check.that(nick != null, "gst_format_register", "nick != NULL")) return c.GST_FORMAT_UNDEFINED;
    if (!check.that(description != null, "gst_format_register", "description != NULL")) return c.GST_FORMAT_UNDEFINED;
    const known = gst_format_get_by_nick(nick);
    if (known != c.GST_FORMAT_UNDEFINED) return known;
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    const d: *Def = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Def))));
    d.value = @intCast(count);
    d.nick = c.g_strdup(nick);
    d.description = c.g_strdup(description);
    d.quark = c.g_quark_from_static_string(d.nick);
    insert(d);
    return d.value;
}

pub export fn gst_formats_contains(formats: [*c]const c.GstFormat, format: c.GstFormat) c.gboolean {
    if (formats == null) return 0;
    var i: usize = 0;
    while (formats[i] != 0) : (i += 1) if (formats[i] == format) return 1;
    return 0;
}

pub export fn gst_format_iterate_definitions() [*c]c.GstIterator {
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    return iterator.gst_iterator_new_list(c.G_TYPE_POINTER, &lock, &count, &defs, null, null);
}
