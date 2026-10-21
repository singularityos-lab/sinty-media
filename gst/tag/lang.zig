const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const tables = @import("tables.zig");

comptime {
    @import("../abi.zig").check(@This());
}

fn find(code: [*c]const u8) ?*const tables.Lang {
    const s = std.mem.span(code);
    for (&tables.LANGS) |*l| {
        if (std.mem.eql(u8, l.code, s)) return l;
    }
    return null;
}

fn cstr(p: ?[*:0]const u8) [*c]const u8 {
    return if (p) |v| v else null;
}

pub export fn gst_tag_get_language_codes() [*c][*c]u8 {
    const out: [*c][*c]u8 = @ptrCast(@alignCast(c.g_malloc(@sizeOf([*c]u8) * (tables.LANG_CODES + 1))));
    var i: usize = 0;
    for (tables.LANGS) |l| {
        if (l.code.len == 2 and l.name != null) {
            out[i] = c.g_strndup(l.code.ptr, 2);
            i += 1;
        }
    }
    out[i] = null;
    return out;
}

pub export fn gst_tag_get_language_name(code: [*c]const u8) [*c]const u8 {
    if (!check.that(code != null, "gst_tag_get_language_name", "language_code != NULL")) return null;
    return if (find(code)) |l| cstr(l.name) else null;
}

pub export fn gst_tag_get_language_code_iso_639_1(code: [*c]const u8) [*c]const u8 {
    if (!check.that(code != null, "gst_tag_get_language_code_iso_639_1", "lang_code != NULL")) return null;
    return if (find(code)) |l| cstr(l.c1) else null;
}

pub export fn gst_tag_get_language_code_iso_639_2T(code: [*c]const u8) [*c]const u8 {
    if (!check.that(code != null, "gst_tag_get_language_code_iso_639_2T", "lang_code != NULL")) return null;
    return if (find(code)) |l| cstr(l.t) else null;
}

pub export fn gst_tag_get_language_code_iso_639_2B(code: [*c]const u8) [*c]const u8 {
    if (!check.that(code != null, "gst_tag_get_language_code_iso_639_2B", "lang_code != NULL")) return null;
    return if (find(code)) |l| cstr(l.b) else null;
}

pub export fn gst_tag_check_language_code(code: [*c]const u8) c.gboolean {
    return @intFromBool(gst_tag_get_language_code_iso_639_1(code) != null);
}
