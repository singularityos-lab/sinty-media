const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

const A = std.heap.c_allocator;

const PNG = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 'I', 'H', 'D', 'R', 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 0x90, 0x77, 0x53, 0xde, 0, 0, 0, 0x0c, 'I', 'D', 'A', 'T', 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0, 0, 0x03, 0x01, 0x01, 0, 0x18, 0xdd, 0x8d, 0xb0, 0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xae, 0x42, 0x60, 0x82 };

fn syncsafe(v: u32) [4]u8 {
    return .{ @truncate((v >> 21) & 0x7f), @truncate((v >> 14) & 0x7f), @truncate((v >> 7) & 0x7f), @truncate(v & 0x7f) };
}

fn frame(list: *std.ArrayList(u8), major: u8, id: []const u8, flags: u16, payload: []const u8) void {
    list.appendSlice(A, id) catch unreachable;
    if (major == 2) {
        const n: u32 = @intCast(payload.len);
        list.appendSlice(A, &.{ @truncate(n >> 16), @truncate(n >> 8), @truncate(n) }) catch unreachable;
    } else {
        const n: u32 = @intCast(payload.len);
        if (major == 4) list.appendSlice(A, &syncsafe(n)) catch unreachable else list.appendSlice(A, &.{ @truncate(n >> 24), @truncate(n >> 16), @truncate(n >> 8), @truncate(n) }) catch unreachable;
        list.appendSlice(A, &.{ @truncate(flags >> 8), @truncate(flags) }) catch unreachable;
    }
    list.appendSlice(A, payload) catch unreachable;
}

fn wrap(major: u8, minor: u8, flags: u8, body: []const u8, extra: []const u8) [*c]c.GstBuffer {
    var l = std.ArrayList(u8).empty;
    l.appendSlice(A, &.{ 'I', 'D', '3', major, minor, flags }) catch unreachable;
    l.appendSlice(A, &syncsafe(@intCast(body.len))) catch unreachable;
    l.appendSlice(A, body) catch unreachable;
    l.appendSlice(A, extra) catch unreachable;
    const b = c.gst_buffer_new_allocate(null, l.items.len, null);
    _ = c.gst_buffer_fill(b, 0, l.items.ptr, l.items.len);
    return b;
}

fn hexBuf(b: [*c]c.GstBuffer) void {
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &info, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(b, &info);
    var h = std.ArrayList(u8).empty;
    for (0..@min(info.size, 200)) |i| h.print(A, "{x:0>2}", .{info.data[i]}) catch {};
    out("  buffer {s}", .{h.items});
}

fn run(label: []const u8, b: [*c]c.GstBuffer) void {
    out("== {s} size={d}", .{ label, c.gst_tag_get_id3v2_tag_size(b) });
    const l = c.gst_tag_list_from_id3v2_tag(b);
    if (l == null) {
        out("  (null)", .{});
    } else {
        const s = c.gst_tag_list_to_string(l);
        out("  {s}", .{str(s)});
        c.g_free(s);
        c.gst_tag_list_unref(l);
    }
    hexBuf(b);
    c.gst_buffer_unref(b);
}

fn v4Frames() []const u8 {
    var f = std.ArrayList(u8).empty;
    frame(&f, 4, "TIT2", 0, "\x03Title UTF8 \xc3\xa9");
    frame(&f, 4, "TPE1", 0, "\x01\xff\xfeA\x00r\x00t\x00\x00\x00S\x00e\x00c\x00");
    frame(&f, 4, "TALB", 0, "\x02\x00A\x00l\x00b");
    frame(&f, 4, "TRCK", 0, "\x003/10");
    frame(&f, 4, "TPOS", 0, "\x00" ++ "2/0");
    frame(&f, 4, "TCON", 0, "\x00(17)(cr)Fusion\x00(9)\x00((Paren\x0042");
    frame(&f, 4, "TDRC", 0, "\x00" ++ "2004-05-06");
    frame(&f, 4, "TLEN", 0, "\x00" ++ "123456");
    frame(&f, 4, "TBPM", 0, "\x00" ++ "128.5");
    frame(&f, 4, "COMM", 0, "\x00ENGdesc\x00a comment");
    frame(&f, 4, "COMM", 0, "\x00xx1\x00plain comment");
    frame(&f, 4, "COMM", 0, "\x00deu\x00only text");
    frame(&f, 4, "COMM", 0, "\x00eng" ++ "c0\x00itunes");
    frame(&f, 4, "TXXX", 0, "\x00replaygain_track_gain\x00-3.5 dB");
    frame(&f, 4, "TXXX", 0, "\x00MusicBrainz Album Id\x00abc-123");
    frame(&f, 4, "TXXX", 0, "\x00unknown thing\x00value");
    frame(&f, 4, "WCOP", 0, "http://creativecommons.org/licenses/by/3.0/");
    frame(&f, 4, "WCOP", 0, "http://example.com/copyright\x00junk");
    frame(&f, 4, "WOAF", 0, "http://example.com/");
    frame(&f, 4, "UFID", 0, "http://musicbrainz.org\x00track-uuid");
    frame(&f, 4, "UFID", 0, "other\x00data");
    frame(&f, 4, "PRIV", 0, "owner.example\x00\x01\x02\x03");
    frame(&f, 4, "RVA2", 0, "track\x00\x01\xfc\x00\x10\x80\x00");
    frame(&f, 4, "RVA2", 0, "album\x00\x01\x02\x00\x18\x12\x34\x56");
    frame(&f, 4, "RVA2", 0, "other\x00\x02\x02\x00\x08\x12");
    var apic = std.ArrayList(u8).empty;
    apic.appendSlice(A, "\x00image/png\x00\x03desc\x00") catch unreachable;
    apic.appendSlice(A, &PNG) catch unreachable;
    frame(&f, 4, "APIC", 0, apic.items);
    frame(&f, 4, "TKEY", 0, "\x00Am");
    frame(&f, 4, "XYZW", 0, "\x00unknown frame");
    frame(&f, 4, "TS?1", 0, "\x00bad id");
    frame(&f, 4, "TENC", 0x0004, "\x00encrypted");
    frame(&f, 4, "TCOP", 0x0002, "\x00\xff\x00copy");
    frame(&f, 4, "TPUB", 0x0001, "\x00\x00\x00\x04\x00Pub");
    var src = "\x00compressed publisher text here".*;
    var dst: [128]u8 = undefined;
    var dlen: c.uLongf = dst.len;
    _ = c.compress2(&dst, &dlen, &src, src.len, 9);
    var comp = std.ArrayList(u8).empty;
    comp.appendSlice(A, &syncsafe(src.len)) catch unreachable;
    comp.appendSlice(A, dst[0..dlen]) catch unreachable;
    frame(&f, 4, "TSSE", 0x0008 | 0x0001, comp.items);
    var same = std.ArrayList(u8).empty;
    var dst2: [128]u8 = undefined;
    var dlen2: c.uLongf = dst2.len;
    var small = "\x00z".*;
    _ = c.compress2(&dst2, &dlen2, &small, small.len, 9);
    same.appendSlice(A, &syncsafe(@intCast(dlen2))) catch unreachable;
    same.appendSlice(A, dst2[0..dlen2]) catch unreachable;
    frame(&f, 4, "TOWN", 0x0008, same.items);
    frame(&f, 4, "TSRC", 0, "\x00ISRC1234");
    f.appendSlice(A, &[_]u8{0} ** 12) catch unreachable;
    return f.items;
}

fn findPng(tf: [*c]c.GstTypeFind, _: c.gpointer) callconv(.c) void {
    const d = c.gst_type_find_peek(tf, 0, 8);
    if (d == null) return;
    if (std.mem.eql(u8, d[0..8], "\x89PNG\r\n\x1a\n")) {
        const caps = c.gst_caps_new_empty_simple("image/png");
        c.gst_type_find_suggest(tf, c.GST_TYPE_FIND_MAXIMUM, caps);
        c.gst_caps_unref(caps);
    } else if (std.mem.eql(u8, d[0..7], "http://")) {
        const caps = c.gst_caps_new_empty_simple("text/uri-list");
        c.gst_type_find_suggest(tf, c.GST_TYPE_FIND_LIKELY, caps);
        c.gst_caps_unref(caps);
    }
}

fn isolate() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
}

fn typefinders() void {
    _ = c.gst_type_find_register(null, "sinty-test-png", c.GST_RANK_PRIMARY, findPng, null, null, null, null);
}

pub fn main() void {
    isolate();
    c.gst_init(null, null);
    typefinders();
    run("v4", wrap(4, 0, 0, v4Frames(), ""));
    run("v4 footer", wrap(4, 0, 0x10, v4Frames()[0..40], "3DI\x04\x00\x10\x00\x00\x00\x28"));
    var ext = std.ArrayList(u8).empty;
    ext.appendSlice(A, &syncsafe(6)) catch unreachable;
    ext.appendSlice(A, "\x01\x00") catch unreachable;
    ext.appendSlice(A, v4Frames()[0..60]) catch unreachable;
    run("v4 exthdr", wrap(4, 0, 0x40, ext.items, ""));
    run("v4 unsync hdr", wrap(4, 0, 0x80, v4Frames()[0..80], ""));
    var f3 = std.ArrayList(u8).empty;
    frame(&f3, 3, "TIT2", 0, "\x00v3 title");
    frame(&f3, 3, "TYER", 0, "\x00" ++ "1998");
    frame(&f3, 3, "TDAT", 0, "\x00" ++ "1502");
    frame(&f3, 3, "TIME", 0, "\x00" ++ "1200");
    frame(&f3, 3, "TRDA", 0, "\x00junk");
    frame(&f3, 3, "TPE1", 0x0040, "\x00grouped");
    frame(&f3, 3, "TCON", 0, "\x00(255)Custom");
    frame(&f3, 3, "COMM", 0, "\x01eng\xff\xfeD\x00\x00\x00\xfe\xff\x00T\x00x");
    frame(&f3, 3, "TPE2", 0, "\x00\xe9t\xe9");
    run("v3", wrap(3, 0, 0, f3.items, ""));
    var f3u = std.ArrayList(u8).empty;
    frame(&f3u, 3, "TIT2", 0, "\x00\xff\x00\xe0x");
    run("v3 unsync", wrap(3, 0, 0x80, f3u.items, ""));
    var f2 = std.ArrayList(u8).empty;
    frame(&f2, 2, "TT2", 0, "\x00v2 title");
    frame(&f2, 2, "TP1", 0, "\x00v2 artist");
    frame(&f2, 2, "TYE", 0, "\x00" ++ "1985");
    frame(&f2, 2, "TDA", 0, "\x00" ++ "3112");
    frame(&f2, 2, "RVA", 0, "\x00obsolete");
    frame(&f2, 2, "COM", 0, "\x00enghi\x00there");
    var pic = std.ArrayList(u8).empty;
    pic.appendSlice(A, "\x00PNG\x00\x00") catch unreachable;
    pic.appendSlice(A, &PNG) catch unreachable;
    frame(&f2, 2, "PIC", 0, pic.items);
    frame(&f2, 2, "X?Y", 0, "\x00weird");
    run("v2", wrap(2, 0, 0, f2.items, ""));
    run("v5", wrap(5, 0, 0, f2.items, ""));
    run("v4.1", wrap(4, 1, 0, f2.items, ""));
    run("short", wrap(4, 0, 0, "", ""));
    const t = c.gst_buffer_new_allocate(null, 4, null);
    _ = c.gst_buffer_fill(t, 0, "ID3\x04", 4);
    run("tiny", t);
    var truncated = wrap(4, 0, 0, v4Frames(), "");
    const tb = c.gst_buffer_copy_region(truncated, c.GST_BUFFER_COPY_ALL, 0, 30);
    c.gst_buffer_unref(truncated);
    truncated = tb;
    run("truncated", truncated);
    run("invalid synch", wrap(4, 0, 0, "", "") );
    const bad = c.gst_buffer_new_allocate(null, 20, null);
    _ = c.gst_buffer_fill(bad, 0, "ID3\x04\x00\x00\x00\x00\x00\x85TIT2\x00\x00\x00\x02\x00\x00\x00a", 20);
    run("nonsynch size", bad);
    out("crit {d}", .{c.gst_tag_get_id3v2_tag_size(null)});
    out("done", .{});
}
