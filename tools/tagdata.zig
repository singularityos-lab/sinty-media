const std = @import("std");
const c = @import("c").c;

var buf: [1 << 22]u8 = undefined;
var len: usize = 0;

fn emit(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(buf[len..], fmt, args) catch unreachable;
    len += s.len;
}

fn lit(p: [*c]const u8) void {
    if (p == null) {
        emit("null", .{});
        return;
    }
    emit("\"", .{});
    for (std.mem.span(p)) |ch| {
        if (ch == '"' or ch == '\\') {
            emit("\\{c}", .{ch});
        } else if (ch >= 0x20 and ch < 0x7f) {
            emit("{c}", .{ch});
        } else emit("\\x{x:0>2}", .{ch});
    }
    emit("\"", .{});
}

fn lang(code: [*c]const u8) void {
    const name = c.gst_tag_get_language_name(code);
    const c1 = c.gst_tag_get_language_code_iso_639_1(code);
    const t = c.gst_tag_get_language_code_iso_639_2T(code);
    const b = c.gst_tag_get_language_code_iso_639_2B(code);
    if (name == null and c1 == null and t == null and b == null) return;
    emit("    .{{ .code = ", .{});
    lit(code);
    emit(", .name = ", .{});
    lit(name);
    emit(", .c1 = ", .{});
    lit(c1);
    emit(", .t = ", .{});
    lit(t);
    emit(", .b = ", .{});
    lit(b);
    emit(" }},\n", .{});
}

pub fn main() void {
    _ = c.g_setenv("GST_TAG_LICENSE_TRANSLATIONS_DICT", "/nonexistent-sinty", 1);
    c.gst_init(null, null);
    emit("pub const Lang = struct {{ code: []const u8, name: ?[*:0]const u8, c1: ?[*:0]const u8, t: ?[*:0]const u8, b: ?[*:0]const u8 }};\n\n", .{});
    emit("pub const LANGS = [_]Lang{{\n", .{});
    lang("");
    var code: [4]u8 = .{ 0, 0, 0, 0 };
    for (0..26) |i| for (0..26) |j| {
        code = .{ @intCast('a' + i), @intCast('a' + j), 0, 0 };
        lang(&code);
    };
    for (0..26) |i| for (0..26) |j| for (0..26) |k| {
        code = .{ @intCast('a' + i), @intCast('a' + j), @intCast('a' + k), 0 };
        lang(&code);
    };
    emit("}};\n\n", .{});
    const codes = c.gst_tag_get_language_codes();
    var n: usize = 0;
    while (codes[n] != null) n += 1;
    emit("pub const LANG_CODES = {d};\n\n", .{n});
    c.g_strfreev(codes);
    emit("pub const License = struct {{ base: [:0]const u8, jur: ?[:0]const u8, flags: u32, title: ?[*:0]const u8, desc: ?[*:0]const u8 }};\n\n", .{});
    emit("pub const LICENSES = [_]License{{\n", .{});
    const refs = c.gst_tag_get_licenses();
    var i: usize = 0;
    while (refs[i] != null) : (i += 1) {
        const r = refs[i];
        const full = std.mem.span(r);
        const jur = c.gst_tag_get_license_jurisdiction(r);
        const tail = full["http://creativecommons.org/licenses/".len..];
        const base = if (jur != null) tail[0 .. tail.len - std.mem.span(jur).len - 1] else tail;
        var bz: [64]u8 = undefined;
        @memcpy(bz[0..base.len], base);
        bz[base.len] = 0;
        emit("    .{{ .base = ", .{});
        lit(&bz);
        emit(", .jur = ", .{});
        lit(jur);
        emit(", .flags = 0x{x}, .title = ", .{c.gst_tag_get_license_flags(r)});
        lit(c.gst_tag_get_license_title(r));
        emit(", .desc = ", .{});
        lit(c.gst_tag_get_license_description(r));
        emit(" }},\n", .{});
    }
    c.g_strfreev(refs);
    emit("}};\n\npub const GENRES = [_][*:0]const u8{{\n", .{});
    for (0..c.gst_tag_id3_genre_count()) |g| {
        emit("    ", .{});
        lit(c.gst_tag_id3_genre_get(@intCast(g)));
        emit(",\n", .{});
    }
    emit("}};\n", .{});
    _ = std.c.write(1, &buf, len);
}
