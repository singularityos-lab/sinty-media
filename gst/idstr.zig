const std = @import("std");
const c = @import("c.zig").c;
const gtype = @import("gtype.zig");

comptime {
    @import("abi.zig").check(@This());
}

const IdStr = c.GstIdStr;

const inline_kind: u8 = 0;
const owned_kind: u8 = 1;
const borrowed_kind: u8 = 2;

const Long = extern struct {
    ptr: [*c]u8,
    len: u32,
    pad: [3]u8,
    kind: u8,
};

const Repr = extern union {
    short: [16]u8,
    long: Long,
};

comptime {
    std.debug.assert(@sizeOf(Repr) == @sizeOf(IdStr));
    std.debug.assert(@alignOf(Repr) == @alignOf(IdStr));
}

fn repr(s: anytype) *Repr {
    return @ptrCast(@alignCast(@constCast(s)));
}

fn kind(s: *const Repr) u8 {
    return s.short[15];
}

var type_once: gtype.Once = .{};

pub export fn gst_id_str_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstIdStr", @ptrCast(&gst_id_str_copy), @ptrCast(&gst_id_str_free));
        }
    }.f);
}

pub export fn gst_id_str_init(s: [*c]IdStr) void {
    repr(s).* = std.mem.zeroes(Repr);
}

pub export fn gst_id_str_get_len(s: [*c]const IdStr) c.gsize {
    const r = repr(s);
    return switch (kind(r)) {
        inline_kind => std.mem.indexOfScalar(u8, &r.short, 0) orelse 15,
        else => r.long.len,
    };
}

fn store(s: [*c]IdStr, value: [*c]const u8, len: c.gsize, owned: bool) void {
    std.debug.assert(len <= std.math.maxInt(u32));
    const r = repr(s);
    if (kind(r) == owned_kind) {
        if (owned and r.long.ptr == value) return;
        c.g_free(r.long.ptr);
    }
    if (len <= 15) {
        var buf = std.mem.zeroes([16]u8);
        @memcpy(buf[0..len], value[0..len]);
        r.short = buf;
        return;
    }
    var l = Long{ .ptr = undefined, .len = @intCast(len), .pad = .{ 0, 0, 0 }, .kind = undefined };
    if (owned) {
        l.ptr = @ptrCast(c.g_malloc(len + 1));
        @memcpy(l.ptr[0..len], value[0..len]);
        l.ptr[len] = 0;
        l.kind = owned_kind;
    } else {
        l.ptr = @constCast(value);
        l.kind = borrowed_kind;
    }
    r.long = l;
}

pub export fn gst_id_str_set(s: [*c]IdStr, value: [*c]const u8) void {
    store(s, value, std.mem.len(value), true);
}

pub export fn gst_id_str_set_with_len(s: [*c]IdStr, value: [*c]const u8, len: c.gsize) void {
    store(s, value, len, true);
}

pub export fn gst_id_str_set_static_str(s: [*c]IdStr, value: [*c]const u8) void {
    store(s, value, std.mem.len(value), false);
}

pub export fn gst_id_str_set_static_str_with_len(s: [*c]IdStr, value: [*c]const u8, len: c.gsize) void {
    store(s, value, len, false);
}

pub export fn gst_id_str_clear(s: [*c]IdStr) void {
    const r = repr(s);
    if (kind(r) == owned_kind) c.g_free(r.long.ptr);
    r.* = std.mem.zeroes(Repr);
}

pub export fn gst_id_str_new() [*c]IdStr {
    return @ptrCast(@alignCast(c.g_malloc0(@sizeOf(IdStr))));
}

pub export fn gst_id_str_free(s: [*c]IdStr) void {
    gst_id_str_clear(s);
    c.g_free(s);
}

pub export fn gst_id_str_copy_into(d: [*c]IdStr, s: [*c]const IdStr) void {
    gst_id_str_clear(d);
    const dr = repr(d);
    dr.* = repr(s).*;
    if (kind(dr) == owned_kind) dr.long.ptr = @ptrCast(c.g_memdup2(dr.long.ptr, dr.long.len + 1));
}

pub export fn gst_id_str_copy(s: [*c]const IdStr) [*c]IdStr {
    const d = gst_id_str_new();
    gst_id_str_copy_into(d, s);
    return d;
}

pub export fn gst_id_str_move(d: [*c]IdStr, s: [*c]IdStr) void {
    gst_id_str_clear(d);
    repr(d).* = repr(s).*;
    repr(s).* = std.mem.zeroes(Repr);
}

pub export fn gst_id_str_as_str(s: [*c]const IdStr) [*c]const u8 {
    const r = repr(s);
    return if (kind(r) == inline_kind) &r.short else r.long.ptr;
}

pub export fn gst_id_str_is_equal(a: [*c]const IdStr, b: [*c]const IdStr) c.gboolean {
    const ra = repr(a);
    const rb = repr(b);
    if (ra == rb or std.mem.eql(u8, &ra.short, &rb.short)) return 1;
    if (kind(ra) == inline_kind or kind(rb) == inline_kind) return 0;
    if (ra.long.len != rb.long.len) return 0;
    return @intFromBool(std.mem.eql(u8, ra.long.ptr[0..ra.long.len], rb.long.ptr[0..rb.long.len]));
}

pub export fn gst_id_str_is_equal_to_str(a: [*c]const IdStr, b: [*c]const u8) c.gboolean {
    return @intFromBool(std.mem.orderZ(u8, gst_id_str_as_str(a), b) == .eq);
}

pub export fn gst_id_str_is_equal_to_str_with_len(a: [*c]const IdStr, b: [*c]const u8, len: c.gsize) c.gboolean {
    var tmp = std.mem.zeroes(IdStr);
    gst_id_str_set_static_str_with_len(&tmp, b, len);
    return gst_id_str_is_equal(a, &tmp);
}

pub fn str(s: [*c]const IdStr) []const u8 {
    return std.mem.span(gst_id_str_as_str(s));
}
