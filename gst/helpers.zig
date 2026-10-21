const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");

comptime {
    @import("abi.zig").check(@This());
}

pub export fn gst_util_array_binary_search(array: c.gpointer, n: c.guint, size: c.gsize, func: c.GCompareDataFunc, mode: c.GstSearchMode, needle: c.gconstpointer, data: c.gpointer) c.gpointer {
    const f = "gst_util_array_binary_search";
    if (!check.that(array != null, f, "array != NULL")) return null;
    if (!check.that(size > 0, f, "element_size > 0")) return null;
    const cmp = func orelse {
        check.fail(f, "search_func != NULL");
        return null;
    };
    if (n == 0) return null;
    const base: [*]u8 = @ptrCast(array);
    const at = struct {
        fn at(b: [*]u8, sz: c.gsize, i: i64) c.gpointer {
            return @ptrCast(b + @as(usize, @intCast(i)) * sz);
        }
    }.at;
    var r = cmp(at(base, size, 0), needle, data);
    if ((r >= 0 and mode == c.GST_SEARCH_MODE_AFTER) or r == 0) return at(base, size, 0);
    if (r > 0) return null;
    const last: i64 = @as(i64, n) - 1;
    r = cmp(at(base, size, last), needle, data);
    if ((r <= 0 and mode == c.GST_SEARCH_MODE_BEFORE) or r == 0) return at(base, size, last);
    if (r < 0) return null;
    var left: i64 = 0;
    var right: i64 = last;
    while (true) {
        const m = left + @divTrunc(right - left, 2);
        r = cmp(at(base, size, m), needle, data);
        if (r == 0) return at(base, size, m);
        if (r < 0) left = m + 1 else right = m - 1;
        if (right < left) {
            if (mode == c.GST_SEARCH_MODE_EXACT) return null;
            if (mode == c.GST_SEARCH_MODE_AFTER) {
                if (r < 0) return if (m < n) at(base, size, m + 1) else null;
                return at(base, size, m);
            }
            if (r < 0) return at(base, size, m);
            return if (m > 0) at(base, size, m - 1) else null;
        }
    }
}

fn dumpOffset(mem: [*c]const u8, size: c.guint, offset: c.guint) void {
    const line = c.g_string_sized_new(50);
    const chars = c.g_string_sized_new(18);
    defer _ = c.g_string_free(line, 1);
    defer _ = c.g_string_free(chars, 1);
    var i: c.guint = 0;
    var j: c.guint = 0;
    while (i < size) {
        _ = c.g_string_append_c(chars, if (std.ascii.isPrint(mem[i])) mem[i] else '.');
        c.g_string_append_printf(line, "%02x ", @as(c_uint, mem[i]));
        j += 1;
        i += 1;
        if (j == 16 or i == size) {
            c.g_print("%08x (%p): %-48.48s %-16.16s\n", i - j + offset, mem + i - j, line[0].str, chars[0].str);
            _ = c.g_string_set_size(line, 0);
            _ = c.g_string_set_size(chars, 0);
            j = 0;
        }
    }
}

pub export fn gst_util_dump_mem(mem: [*c]const u8, size: c.guint) void {
    dumpOffset(mem, size, 0);
}

pub export fn gst_util_dump_buffer(b: [*c]c.GstBuffer) void {
    const n = c.gst_buffer_n_memory(b);
    var map: c.GstMapInfo = undefined;
    if (n == 1) {
        if (c.gst_buffer_map(b, &map, c.GST_MAP_READ) != 0) {
            dumpOffset(map.data, @intCast(map.size), 0);
            c.gst_buffer_unmap(b, &map);
        }
    } else if (n > 1) {
        var offset: c.guint = 0;
        var i: c.guint = 0;
        while (i < n) : (i += 1) {
            c.g_print("[Memory #%u]\n", i);
            const mem = c.gst_buffer_get_memory(b, i);
            if (c.gst_memory_map(mem, &map, c.GST_MAP_READ) != 0) {
                dumpOffset(map.data, @intCast(map.size), offset);
                offset += @intCast(map.size);
                c.gst_memory_unmap(mem, &map);
            }
            c.gst_mini_object_unref(@ptrCast(mem));
        }
    } else c.g_print("[Empty]\n");
}

pub export fn gst_util_filename_compare(a: [*c]const u8, b: [*c]const u8) c.gint {
    const au = c.g_filename_to_utf8(a, -1, null, null, null);
    const bu = c.g_filename_to_utf8(b, -1, null, null, null);
    defer c.g_free(au);
    defer c.g_free(bu);
    if (au == null or bu == null) return c.strcmp(a, b);
    const ka = c.g_utf8_collate_key_for_filename(au, -1);
    const kb = c.g_utf8_collate_key_for_filename(bu, -1);
    defer c.g_free(ka);
    defer c.g_free(kb);
    return c.strcmp(ka, kb);
}

pub export fn gst_util_get_object_array(o: [*c]c.GObject, name: [*c]const u8, out: [*c][*c]c.GValueArray) c.gboolean {
    var v1 = std.mem.zeroes(c.GValue);
    var v2 = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v1, c.g_value_array_get_type());
    _ = c.g_value_init(&v2, c.gst_value_array_get_type());
    c.g_object_get_property(o, name, &v2);
    var ok: c.gboolean = 0;
    if (c.g_value_transform(&v2, &v1) != 0) {
        out.* = @ptrCast(@alignCast(c.g_value_get_boxed(&v1)));
        ok = 1;
    }
    c.g_value_unset(&v2);
    return ok;
}

pub export fn gst_util_set_object_array(o: [*c]c.GObject, name: [*c]const u8, array: [*c]const c.GValueArray) c.gboolean {
    var v1 = std.mem.zeroes(c.GValue);
    var v2 = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v1, c.g_value_array_get_type());
    _ = c.g_value_init(&v2, c.gst_value_array_get_type());
    c.g_value_set_static_boxed(&v1, array);
    var ok: c.gboolean = 0;
    if (c.g_value_transform(&v1, &v2) != 0) {
        c.g_object_set_property(o, name, &v2);
        ok = 1;
    }
    c.g_value_unset(&v1);
    c.g_value_unset(&v2);
    return ok;
}

pub export fn gst_util_set_object_arg(o: [*c]c.GObject, name: [*c]const u8, value: [*c]const u8) void {
    const f = "gst_util_set_object_arg";
    if (!check.that(gtype.instanceOf(o, c.G_TYPE_OBJECT), f, "G_IS_OBJECT (object)")) return;
    if (!check.that(name != null, f, "name != NULL")) return;
    if (!check.that(value != null, f, "value != NULL")) return;
    const pspec = c.g_object_class_find_property(gtype.classPeek(c.GObjectClass, o), name);
    if (pspec == null or pspec[0].flags & c.G_PARAM_WRITABLE == 0) return;
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, pspec[0].value_type);
    defer c.g_value_unset(&v);
    if (pspec[0].value_type == c.gst_structure_get_type() and c.strcmp(value, "NULL") == 0) {
        c.g_value_set_boxed(&v, null);
    } else if (c.gst_value_deserialize_with_pspec(&v, value, pspec) == 0) return;
    c.g_object_set_property(o, pspec[0].name, &v);
}

pub export fn gst_util_set_value_from_string(v: [*c]c.GValue, text: [*c]const u8) void {
    const f = "gst_util_set_value_from_string";
    if (!check.that(v != null, f, "value != NULL")) return;
    if (!check.that(text != null, f, "value_str != NULL")) return;
    var ok = c.gst_value_deserialize(v, text) != 0;
    if (!ok and v[0].g_type == c.G_TYPE_BOOLEAN) {
        c.g_value_set_boolean(v, 0);
        ok = true;
    }
    _ = check.that(ok, f, "res");
}

fn syncEach(v: [*c]const c.GValue, data: c.gpointer) callconv(.c) void {
    const ok: *c.gboolean = @ptrCast(@alignCast(data));
    const e: [*c]c.GstElement = @ptrCast(@alignCast(c.g_value_get_object(v)));
    if (c.gst_element_is_locked_state(e) != 0) {
        ok.* = 1;
        return;
    }
    ok.* = @intFromBool(ok.* != 0 and c.gst_element_sync_state_with_parent(e) != 0);
    if (gtype.instanceOf(e, c.gst_bin_get_type())) ok.* = @intFromBool(ok.* != 0 and gst_bin_sync_children_states(@ptrCast(e)) != 0);
}

pub export fn gst_bin_sync_children_states(b: [*c]c.GstBin) c.gboolean {
    const it = c.gst_bin_iterate_sorted(b);
    defer c.gst_iterator_free(it);
    var ok: c.gboolean = 1;
    var r: c.GstIteratorResult = c.GST_ITERATOR_OK;
    while (true) {
        if (r == c.GST_ITERATOR_RESYNC) {
            ok = 1;
            c.gst_iterator_resync(it);
        }
        r = c.gst_iterator_foreach(it, syncEach, &ok);
        if (r != c.GST_ITERATOR_RESYNC) break;
    }
    return ok;
}

const Cpu = struct {
    mmx: bool = false,
    mmxext: bool = false,
    amd3dnow: bool = false,
    sse2: bool = false,
    sse3: bool = false,
    ssse3: bool = false,
    sse4_1: bool = false,
    sse4_2: bool = false,
    avx: bool = false,
    avx2: bool = false,
    neon: bool = false,
    neon64: bool = false,
};

var cpu_once: gtype.Once = .{};
var cpu: Cpu = .{};

const x86 = builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86;
const arm = builtin.cpu.arch == .aarch64 or builtin.cpu.arch.isArm();

fn cpuid(leaf: u32, sub: u32) [4]u32 {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var cc: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (cc),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (sub),
    );
    return .{ a, b, cc, d };
}

fn xcr0() u32 {
    var lo: u32 = undefined;
    asm volatile ("xgetbv"
        : [lo] "={eax}" (lo),
        : [idx] "{ecx}" (@as(u32, 0)),
        : .{ .edx = true });
    return lo;
}

fn bit(v: u32, n: u5) bool {
    return (v >> n) & 1 != 0;
}

fn probe() void {
    if (comptime x86) {
        const ext = cpuid(0x80000000, 0);
        if (ext[0] >= 0x80000001) {
            const e = cpuid(0x80000001, 0);
            cpu.mmxext = bit(e[3], 22);
            cpu.amd3dnow = bit(e[3], 31);
        }
        const r = cpuid(1, 0);
        var sse_os = true;
        var avx_os = true;
        if (bit(r[2], 27)) {
            const x = xcr0();
            sse_os = bit(x, 1);
            avx_os = bit(x, 2) and sse_os;
        }
        cpu.mmx = bit(r[3], 23);
        cpu.sse2 = bit(r[3], 26) and sse_os;
        cpu.sse3 = bit(r[2], 0) and sse_os;
        cpu.ssse3 = bit(r[2], 9) and sse_os;
        cpu.sse4_1 = bit(r[2], 19) and sse_os;
        cpu.sse4_2 = bit(r[2], 20) and sse_os;
        cpu.avx = bit(r[2], 28) and avx_os;
        const r7 = cpuid(7, 0);
        cpu.avx2 = bit(r7[1], 5) and avx_os;
    } else if (comptime arm) {
        if (builtin.cpu.arch == .aarch64) {
            cpu.neon = true;
            cpu.neon64 = true;
        } else {
            cpu.neon = c.getauxval(c.AT_HWCAP) & (1 << 12) != 0;
        }
    }
}

fn flag(comptime field: []const u8) c.gboolean {
    _ = cpu_once.get(struct {
        fn f() c.GType {
            probe();
            return 1;
        }
    }.f);
    return @intFromBool(@field(cpu, field));
}

pub export fn gst_cpuid_supports_x86_mmx() c.gboolean {
    return flag("mmx");
}

pub export fn gst_cpuid_supports_x86_mmxext() c.gboolean {
    return flag("mmxext");
}

pub export fn gst_cpuid_supports_x86_3dnow() c.gboolean {
    return flag("amd3dnow");
}

pub export fn gst_cpuid_supports_x86_sse2() c.gboolean {
    return flag("sse2");
}

pub export fn gst_cpuid_supports_x86_sse3() c.gboolean {
    return flag("sse3");
}

pub export fn gst_cpuid_supports_x86_ssse3() c.gboolean {
    return flag("ssse3");
}

pub export fn gst_cpuid_supports_x86_sse4_1() c.gboolean {
    return flag("sse4_1");
}

pub export fn gst_cpuid_supports_x86_sse4_2() c.gboolean {
    return flag("sse4_2");
}

pub export fn gst_cpuid_supports_x86_avx() c.gboolean {
    return flag("avx");
}

pub export fn gst_cpuid_supports_x86_avx2() c.gboolean {
    return flag("avx2");
}

pub export fn gst_cpuid_supports_arm_neon() c.gboolean {
    return flag("neon");
}

pub export fn gst_cpuid_supports_arm_neon64() c.gboolean {
    return flag("neon64");
}
