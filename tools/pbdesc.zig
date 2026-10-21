const std = @import("std");
const c = @import("c").c;

const DYNAMIC = [_][]const u8{ "video/x-raw", "video/x-h263", "video/x-h264", "video/x-h265", "video/x-h266", "video/x-dirac", "video/x-divx", "video/x-msmpeg", "video/x-truemotion", "video/x-xan", "video/x-indeo", "audio/x-wma", "video/x-wmv", "audio/x-mace", "video/x-svq", "video/x-asus", "video/x-ati-vcr", "audio/x-adpcm", "audio/mpeg", "audio/x-pn-realaudio", "video/x-pn-realvideo", "video/mpeg", "audio/x-raw", "video/x-tscc", "video/x-hap" };

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const Probe = struct {
    known: bool,
    desc: ?[]const u8,
    flags: c_uint,
    ext: []const u8,

    fn same(a: Probe, b: Probe) bool {
        if (a.known != b.known or a.flags != b.flags or !std.mem.eql(u8, a.ext, b.ext)) return false;
        if (a.desc == null or b.desc == null) return a.desc == null and b.desc == null;
        return std.mem.eql(u8, a.desc.?, b.desc.?);
    }
};

fn probe(t: [*:0]const u8, sys: bool) Probe {
    const caps = c.gst_caps_new_empty_simple(t);
    if (sys) c.gst_caps_set_simple(caps, "systemstream", c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), @as(?*anyopaque, null));
    const tl = c.gst_tag_list_new_empty();
    const known = c.gst_pb_utils_add_codec_description_to_tag_list(tl, null, caps) != 0;
    c.gst_tag_list_unref(tl);
    const d = c.gst_pb_utils_get_codec_description(caps);
    const e = c.gst_pb_utils_get_file_extension_from_caps(caps);
    const r = Probe{
        .known = known,
        .desc = if (d != null) std.mem.span(@as([*:0]const u8, @ptrCast(d))) else null,
        .flags = c.gst_pb_utils_get_caps_description_flags(caps),
        .ext = if (e != null) std.mem.span(@as([*:0]const u8, @ptrCast(e))) else "",
    };
    c.gst_caps_unref(caps);
    return r;
}

fn dynamic(t: []const u8) bool {
    for (DYNAMIC) |d| if (std.mem.eql(u8, d, t)) return true;
    return false;
}

fn emit(t: []const u8, p: Probe, sys: bool) void {
    const ext = if (std.mem.eql(u8, t, "audio/mpeg")) "" else p.ext;
    if (p.desc == null or dynamic(t)) {
        out("    .{{ .t = \"{s}\", .d = null, .f = 0x{x}, .e = \"{s}\" }},", .{ t, p.flags | @as(c_uint, if (sys) 0x100 else 0), ext });
    } else {
        out("    .{{ .t = \"{s}\", .d = \"{f}\", .f = 0x{x}, .e = \"{s}\" }},", .{ t, std.zig.fmtString(p.desc.?), p.flags | @as(c_uint, if (sys) 0x100 else 0), ext });
    }
}

pub fn main() void {
    c.gst_init(null, null);
    var buf: [65536]u8 = undefined;
    const n = std.c.read(0, &buf, buf.len);
    var it = std.mem.tokenizeScalar(u8, buf[0..@intCast(n)], '\n');
    var name: [256]u8 = undefined;
    while (it.next()) |line| {
        @memcpy(name[0..line.len], line);
        name[line.len] = 0;
        const t: [*:0]const u8 = @ptrCast(&name);
        const plain = probe(t, false);
        const sys = probe(t, true);
        if (sys.known and (!plain.known or !sys.same(plain))) emit(line, sys, true);
        if (plain.known) emit(line, plain, false);
    }
}
