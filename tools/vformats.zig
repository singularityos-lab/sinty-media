const std = @import("std");
const c = @import("c").c;

var buf: [1 << 22]u8 = undefined;
var len: usize = 0;

fn emit(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(buf[len..], fmt, args) catch unreachable;
    len += s.len;
}

fn arr(comptime T: type, v: [4]T) void {
    emit(".{{ {d}, {d}, {d}, {d} }}", .{ v[0], v[1], v[2], v[3] });
}

pub fn main() void {
    c.gst_init(null, null);
    emit("const c = @import(\"../c.zig\").c;\n\npub const Row = struct {{ format: c.GstVideoFormat, name: [:0]const u8, description: [:0]const u8, flags: c.guint, bits: c.guint, n_components: c.guint, shift: [4]c.guint, depth: [4]c.guint, pixel_stride: [4]c.gint, n_planes: c.guint, plane: [4]c.guint, poffset: [4]c.guint, w_sub: [4]c.guint, h_sub: [4]c.guint, unpack_format: c.GstVideoFormat, pack_lines: c.gint, tile_mode: c.GstVideoTileMode, tile_ws: c.guint, tile_hs: c.guint, tiles: [4][4]c.guint, fourcc: u32 }};\n\npub const rows = [_]Row{{\n", .{});
    var f: c_int = 0;
    while (true) : (f += 1) {
        const info = c.gst_video_format_get_info(@intCast(f));
        if (info == null) break;
        emit("    .{{ .format = {d}, .name = \"{s}\", .description = \"{s}\", .flags = {d}, .bits = {d}, .n_components = {d}, .shift = ", .{ info.*.format, info.*.name, info.*.description, info.*.flags, info.*.bits, info.*.n_components });
        arr(c.guint, info.*.shift);
        emit(", .depth = ", .{});
        arr(c.guint, info.*.depth);
        emit(", .pixel_stride = ", .{});
        arr(c.gint, info.*.pixel_stride);
        emit(", .n_planes = {d}, .plane = ", .{info.*.n_planes});
        arr(c.guint, info.*.plane);
        emit(", .poffset = ", .{});
        arr(c.guint, info.*.poffset);
        emit(", .w_sub = ", .{});
        arr(c.guint, info.*.w_sub);
        emit(", .h_sub = ", .{});
        arr(c.guint, info.*.h_sub);
        emit(", .unpack_format = {d}, .pack_lines = {d}, .tile_mode = {d}, .tile_ws = {d}, .tile_hs = {d}, .tiles = .{{ ", .{ info.*.unpack_format, info.*.pack_lines, info.*.tile_mode, info.*.tile_ws, info.*.tile_hs });
        for (0..4) |p| {
            const t = info[0].tile_info[p];
            emit(".{{ {d}, {d}, {d}, {d} }}, ", .{ t.width, t.height, t.stride, t.size });
        }
        emit("}}, .fourcc = 0x{x} }},\n", .{c.gst_video_format_to_fourcc(@intCast(f))});
        if (f > 400) break;
    }
    emit("}};\n", .{});
    _ = std.c.write(1, &buf, len);
}
