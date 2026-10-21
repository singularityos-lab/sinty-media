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

const PATH = "zig-out/realtag.bin";

var file: [16384]u8 = undefined;
var len: usize = 0;

fn put(d: []const u8) void {
    @memcpy(file[len..][0..d.len], d);
    len += d.len;
}

fn putLe(comptime T: type, v: T) void {
    std.mem.writeInt(T, file[len..][0..@sizeOf(T)], v, .little);
    len += @sizeOf(T);
}

fn frame(id: []const u8, text: []const u8) void {
    put(id);
    std.mem.writeInt(u32, file[len..][0..4], @intCast(text.len + 1), .big);
    len += 4;
    put("\x00\x00\x00");
    put(text);
}

fn build(v2: bool, v1: bool) void {
    len = 0;
    if (v2) {
        put("ID3\x03\x00\x00");
        const size_at = len;
        len += 4;
        const start = len;
        frame("TIT2", "Real Title");
        frame("TPE1", "Real Artist");
        frame("TALB", "Album Uno");
        frame("TRCK", "3/9");
        put(&[_]u8{0} ** 32);
        const sz: u32 = @intCast(len - start);
        file[size_at] = @truncate(sz >> 21 & 0x7f);
        file[size_at + 1] = @truncate(sz >> 14 & 0x7f);
        file[size_at + 2] = @truncate(sz >> 7 & 0x7f);
        file[size_at + 3] = @truncate(sz & 0x7f);
    }
    const pcm: u32 = 8000;
    put("RIFF");
    putLe(u32, 36 + pcm);
    put("WAVEfmt ");
    putLe(u32, 16);
    putLe(u16, 1);
    putLe(u16, 1);
    putLe(u32, 8000);
    putLe(u32, 16000);
    putLe(u16, 2);
    putLe(u16, 16);
    put("data");
    putLe(u32, pcm);
    var i: u32 = 0;
    while (i < pcm / 2) : (i += 1) putLe(i16, @truncate(@as(i32, @intCast(i % 200)) * 100 - 10000));
    if (v1) {
        var t = [_]u8{0} ** 128;
        @memcpy(t[0..3], "TAG");
        @memcpy(t[3..][0..9], "V1 Title!");
        @memcpy(t[33..][0..9], "V1 Artist");
        @memcpy(t[93..][0..4], "1999");
        t[126] = 7;
        t[127] = 17;
        put(&t);
    }
    const f = std.c.fopen(PATH, "wb") orelse return;
    _ = std.c.fwrite(&file, 1, len, f);
    _ = std.c.fclose(f);
}

fn run(desc: [*:0]const u8) void {
    var err: [*c]c.GError = null;
    const pipe = c.gst_parse_launch(desc, &err);
    if (pipe == null) {
        out("parse error {s}", .{str(err.*.message)});
        return;
    }
    out("pipeline '{s}' start {d}", .{ desc, c.gst_element_set_state(pipe, c.GST_STATE_PLAYING) });
    const bus = c.gst_element_get_bus(pipe);
    while (true) {
        const m = c.gst_bus_timed_pop_filtered(bus, 10 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR | c.GST_MESSAGE_TAG);
        if (m == null) {
            out("  timeout", .{});
            break;
        }
        defer c.gst_message_unref(m);
        if (m.*.type == c.GST_MESSAGE_TAG) {
            var l: [*c]c.GstTagList = null;
            c.gst_message_parse_tag(m, &l);
            const s = c.gst_tag_list_to_string(l);
            out("  tag from {s}: {s}", .{ str(c.gst_object_get_name(m.*.src)), str(s) });
            c.g_free(s);
            c.gst_tag_list_unref(l);
            continue;
        }
        if (m.*.type == c.GST_MESSAGE_ERROR) {
            var e: [*c]c.GError = null;
            c.gst_message_parse_error(m, &e, null);
            out("  error {s}", .{str(e.*.message)});
            c.g_error_free(e);
        } else out("  eos", .{});
        break;
    }
    var dur: i64 = -1;
    _ = c.gst_element_query_duration(pipe, c.GST_FORMAT_TIME, &dur);
    out("  duration {d}", .{dur});
    _ = c.gst_element_set_state(pipe, c.GST_STATE_NULL);
    c.gst_object_unref(bus);
    c.gst_object_unref(pipe);
}

pub fn main() void {
    c.gst_init(null, null);
    build(true, true);
    run("filesrc location=" ++ PATH ++ " ! id3demux ! wavparse ! fakesink name=sink");
    run("filesrc location=" ++ PATH ++ " ! decodebin ! audioconvert ! fakesink name=sink");
    build(false, true);
    run("filesrc location=" ++ PATH ++ " ! id3demux ! wavparse ! fakesink name=sink");
    build(true, false);
    run("filesrc location=" ++ PATH ++ " ! queue ! id3demux ! wavparse ! fakesink name=sink");
    run("filesrc location=" ++ PATH ++ " ! typefind ! fakesink name=sink");
    _ = std.c.unlink(PATH);
    out("done", .{});
}
