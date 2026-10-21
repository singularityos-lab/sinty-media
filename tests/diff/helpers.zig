const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

fn cmpInt(a: c.gconstpointer, b: c.gconstpointer, _: c.gpointer) callconv(.c) c.gint {
    const x = @as(*const c_int, @ptrCast(@alignCast(a))).*;
    const y = @as(*const c_int, @ptrCast(@alignCast(b))).*;
    return if (x < y) -1 else if (x > y) @as(c.gint, 1) else 0;
}

const Holder = extern struct {
    obj: c.GObject,
    arr: c.GValue,
};

fn holderSet(o: [*c]c.GObject, _: c.guint, v: [*c]const c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const h: *Holder = @ptrCast(@alignCast(o));
    if (h.arr.g_type != 0) c.g_value_unset(&h.arr);
    _ = c.g_value_init(&h.arr, c.gst_value_array_get_type());
    c.g_value_copy(v, &h.arr);
}

fn holderGet(o: [*c]c.GObject, _: c.guint, v: [*c]c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const h: *Holder = @ptrCast(@alignCast(o));
    if (h.arr.g_type != 0) c.g_value_copy(&h.arr, v);
}

fn holderClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = holderSet;
    gc.get_property = holderGet;
    c.g_object_class_install_property(gc, 1, c.gst_param_spec_array("list", "L", "l", c.g_param_spec_int("i", "i", "i", 0, 100, 0, c.G_PARAM_READWRITE), c.G_PARAM_READWRITE));
}

fn holderType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.G_TYPE_OBJECT, "HelperHolder", @sizeOf(c.GObjectClass), holderClass, @sizeOf(Holder), null, 0);
    return S.t;
}

pub fn main() void {
    c.gst_init(null, null);
    var arr = [_]c_int{ 1, 3, 5, 7, 9, 11 };
    const modes = [_]c.GstSearchMode{ c.GST_SEARCH_MODE_EXACT, c.GST_SEARCH_MODE_BEFORE, c.GST_SEARCH_MODE_AFTER };
    for ([_]c_int{ 0, 1, 4, 5, 10, 11, 12 }) |needle| {
        for (modes) |m| {
            var nd = needle;
            const r = c.gst_util_array_binary_search(&arr, arr.len, @sizeOf(c_int), cmpInt, m, &nd, null);
            out("search {d} mode {d} -> {d}", .{ needle, m, if (r != null) @as(*c_int, @ptrCast(@alignCast(r))).* else -1 });
        }
    }
    var one = [_]c_int{5};
    var nd: c_int = 6;
    out("single {d}", .{@intFromBool(c.gst_util_array_binary_search(&one, 1, @sizeOf(c_int), cmpInt, c.GST_SEARCH_MODE_BEFORE, &nd, null) != null)});
    out("empty {d}", .{@intFromBool(c.gst_util_array_binary_search(&one, 0, @sizeOf(c_int), cmpInt, c.GST_SEARCH_MODE_EXACT, &nd, null) == null)});
    const text = "Hello, sinty-media world! \x01\x02\xff";
    c.gst_util_dump_mem(text, text.len);
    const b = c.gst_buffer_new_wrapped(c.g_strdup("abcdefghijklmnopqrstuvwxyz0123"), 30);
    c.gst_util_dump_buffer(b);
    c.gst_buffer_append_memory(b, c.gst_memory_new_wrapped(0, @constCast("XYZ"), 3, 0, 3, null, null));
    c.gst_util_dump_buffer(b);
    c.gst_buffer_unref(b);
    const e = c.gst_buffer_new();
    c.gst_util_dump_buffer(e);
    c.gst_buffer_unref(e);
    out("fname {d} {d} {d}", .{ std.math.sign(c.gst_util_filename_compare("file10", "file9")), std.math.sign(c.gst_util_filename_compare("a.txt", "a.txt")), std.math.sign(c.gst_util_filename_compare("B", "a")) });
    const bin = c.gst_bin_new("b");
    c.gst_util_set_object_arg(@ptrCast(bin), "async-handling", "true");
    c.gst_util_set_object_arg(@ptrCast(bin), "message-forward", "yes");
    c.gst_util_set_object_arg(@ptrCast(bin), "name", "renamed");
    c.gst_util_set_object_arg(@ptrCast(bin), "nosuch", "x");
    c.gst_util_set_object_arg(@ptrCast(bin), "async-handling", "notabool");
    var ah: c.gboolean = 0;
    var mf: c.gboolean = 0;
    c.g_object_get(bin, "async-handling", &ah, "message-forward", &mf, @as([*c]const u8, null));
    out("object arg {d} {d} name {s}", .{ ah, mf, str(@as(*c.GstObject, @ptrCast(@alignCast(bin))).name) });
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.G_TYPE_BOOLEAN);
    c.gst_util_set_value_from_string(&v, "true");
    out("bool true {d}", .{c.g_value_get_boolean(&v)});
    c.gst_util_set_value_from_string(&v, "garbage");
    out("bool garbage {d}", .{c.g_value_get_boolean(&v)});
    c.g_value_unset(&v);
    _ = c.g_value_init(&v, c.G_TYPE_INT);
    c.gst_util_set_value_from_string(&v, "42");
    out("int {d}", .{c.g_value_get_int(&v)});
    c.gst_util_set_value_from_string(&v, "x");
    c.g_value_unset(&v);
    const h: [*c]c.GObject = @ptrCast(@alignCast(c.g_object_new(holderType(), @as([*c]const u8, null))));
    const va = c.g_value_array_new(2);
    var iv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&iv, c.G_TYPE_INT);
    c.g_value_set_int(&iv, 3);
    _ = c.g_value_array_append(va, &iv);
    c.g_value_set_int(&iv, 4);
    _ = c.g_value_array_append(va, &iv);
    out("set array {d}", .{c.gst_util_set_object_array(h, "list", va)});
    var got: [*c]c.GValueArray = null;
    out("get array {d}", .{c.gst_util_get_object_array(h, "list", &got)});
    if (got != null) out("  n {d} first {d}", .{ got.*.n_values, c.g_value_get_int(c.g_value_array_get_nth(got, 0)) });
    c.g_object_unref(h);
    const pipe = c.gst_pipeline_new("p");
    const inner = c.gst_bin_new("inner");
    const leaf = c.gst_bin_new("leaf");
    _ = c.gst_bin_add(@ptrCast(inner), leaf);
    _ = c.gst_bin_add(@ptrCast(pipe), inner);
    _ = c.gst_element_set_state(pipe, c.GST_STATE_READY);
    const late = c.gst_bin_new("late");
    _ = c.gst_bin_add(@ptrCast(inner), late);
    out("sync {d}", .{c.gst_bin_sync_children_states(@ptrCast(pipe))});
    var st: c.GstState = 0;
    _ = c.gst_element_get_state(late, &st, null, 0);
    out("late state {d}", .{st});
    _ = c.gst_element_set_state(pipe, c.GST_STATE_NULL);
    c.gst_object_unref(pipe);
    out("cpu mmx {d} sse2 {d} sse3 {d} ssse3 {d} sse41 {d} sse42 {d} avx {d} avx2 {d} mmxext {d} 3dnow {d} neon {d} neon64 {d}", .{ c.gst_cpuid_supports_x86_mmx(), c.gst_cpuid_supports_x86_sse2(), c.gst_cpuid_supports_x86_sse3(), c.gst_cpuid_supports_x86_ssse3(), c.gst_cpuid_supports_x86_sse4_1(), c.gst_cpuid_supports_x86_sse4_2(), c.gst_cpuid_supports_x86_avx(), c.gst_cpuid_supports_x86_avx2(), c.gst_cpuid_supports_x86_mmxext(), c.gst_cpuid_supports_x86_3dnow(), c.gst_cpuid_supports_arm_neon(), c.gst_cpuid_supports_arm_neon64() });
    out("done", .{});
}
