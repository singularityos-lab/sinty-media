const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);
const SI = ?*c.GstDiscovererStreamInfo;

fn z(p: [*c]const u8) []const u8 {
    return if (p == null) "-" else std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

var dir: [*c]u8 = null;

fn path(name: [*c]const u8) [*c]u8 {
    return c.g_build_filename(dir, name, NONE);
}

fn uri(name: [*c]const u8) [*c]u8 {
    return c.gst_filename_to_uri(path(name), null);
}

fn generate(name: [*c]const u8, desc: [*c]const u8) void {
    const p = path(name);
    if (c.g_file_test(p, c.G_FILE_TEST_EXISTS) != 0) return;
    const full = if (c.strstr(desc, "%s") != null) c.g_strdup_printf(desc, p) else c.g_strdup_printf("%s ! filesink location=\"%s\"", desc, p);
    const pipe = c.gst_parse_launch(full, null);
    _ = c.gst_element_set_state(pipe, c.GST_STATE_PLAYING);
    const bus = c.gst_element_get_bus(pipe);
    const m = c.gst_bus_timed_pop_filtered(bus, c.GST_CLOCK_TIME_NONE, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    if (m != null and m[0].type == c.GST_MESSAGE_ERROR) {
        var e: [*c]c.GError = null;
        c.gst_message_parse_error(m, &e, null);
        const log = c.g_strdup_printf("%s: %s\n", name, e[0].message);
        _ = c.g_file_set_contents(path("gen.log"), log, -1, null);
    }
    if (m != null) c.gst_message_unref(m);
    _ = c.gst_element_set_state(pipe, c.GST_STATE_NULL);
    c.gst_object_unref(bus);
    c.gst_object_unref(pipe);
}

fn capsS(cp: [*c]c.GstCaps) []const u8 {
    if (cp == null) return "-";
    const s = c.gst_caps_to_string(cp);
    c.gst_caps_unref(cp);
    return z(s);
}

var tag_buf: [8192]u8 = undefined;
var mask_tags = false;

fn tagEntry(list: ?*const c.GstTagList, tag: [*c]const u8, data: c.gpointer) callconv(.c) void {
    const arr: *std.ArrayList([]const u8) = @ptrCast(@alignCast(data));
    for ([_][]const u8{ "datetime", "encoder", "encoder-version", "application-name" }) |skip| {
        if (std.mem.eql(u8, z(tag), skip)) return;
    }
    const n = c.gst_tag_list_get_tag_size(list, tag);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const v = c.gst_tag_list_get_value_index(list, tag, i);
        const vs = c.gst_value_serialize(v);
        const e = c.g_strdup_printf("%s=%s", tag, vs);
        c.g_free(vs);
        arr.append(std.heap.c_allocator, z(e)) catch {};
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn tagsS(t: ?*const c.GstTagList) []const u8 {
    if (mask_tags) return "<masked>";
    if (t == null) return "-";
    var arr: std.ArrayList([]const u8) = .empty;
    c.gst_tag_list_foreach(t, tagEntry, &arr);
    std.mem.sort([]const u8, arr.items, {}, lessThan);
    var n: usize = 0;
    for (arr.items) |e| {
        const w = std.fmt.bufPrint(tag_buf[n..], "{s};", .{e}) catch break;
        n += w.len;
    }
    return tag_buf[0..n];
}

fn sidS(s: [*c]const u8) []const u8 {
    if (s == null) return "-";
    const full = z(s);
    if (std.mem.indexOfScalar(u8, full, '/')) |i| return full[i..];
    return if (full.len > 8) "<hash>" else full;
}

fn dumpStream(prefix: []const u8, s: SI) void {
    if (s == null) return;
    out("{s}{s} nick={s} caps={s} num={d} sid={s} tags={s} toc={d} misc={d}", .{ prefix, z(c.g_type_name_from_instance(@ptrCast(@alignCast(s)))), z(c.gst_discoverer_stream_info_get_stream_type_nick(s)), capsS(c.gst_discoverer_stream_info_get_caps(s)), c.gst_discoverer_stream_info_get_stream_number(s), sidS(c.gst_discoverer_stream_info_get_stream_id(s)), tagsS(c.gst_discoverer_stream_info_get_tags(s)), @intFromBool(c.gst_discoverer_stream_info_get_toc(s) != null), @intFromBool(c.gst_discoverer_stream_info_get_misc(s) != null) });
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(s)), c.gst_discoverer_audio_info_get_type()) != 0) {
        const a: ?*c.GstDiscovererAudioInfo = @ptrCast(s);
        out("{s}  audio ch={d} mask={d} rate={d} depth={d} br={d} maxbr={d} lang={s}", .{ prefix, c.gst_discoverer_audio_info_get_channels(a), c.gst_discoverer_audio_info_get_channel_mask(a), c.gst_discoverer_audio_info_get_sample_rate(a), c.gst_discoverer_audio_info_get_depth(a), c.gst_discoverer_audio_info_get_bitrate(a), c.gst_discoverer_audio_info_get_max_bitrate(a), z(c.gst_discoverer_audio_info_get_language(a)) });
    }
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(s)), c.gst_discoverer_video_info_get_type()) != 0) {
        const v: ?*c.GstDiscovererVideoInfo = @ptrCast(s);
        out("{s}  video {d}x{d} depth={d} fps={d}/{d} par={d}/{d} il={d} br={d} maxbr={d} img={d}", .{ prefix, c.gst_discoverer_video_info_get_width(v), c.gst_discoverer_video_info_get_height(v), c.gst_discoverer_video_info_get_depth(v), c.gst_discoverer_video_info_get_framerate_num(v), c.gst_discoverer_video_info_get_framerate_denom(v), c.gst_discoverer_video_info_get_par_num(v), c.gst_discoverer_video_info_get_par_denom(v), c.gst_discoverer_video_info_is_interlaced(v), c.gst_discoverer_video_info_get_bitrate(v), c.gst_discoverer_video_info_get_max_bitrate(v), c.gst_discoverer_video_info_is_image(v) });
    }
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(s)), c.gst_discoverer_subtitle_info_get_type()) != 0) {
        out("{s}  sub lang={s}", .{ prefix, z(c.gst_discoverer_subtitle_info_get_language(@ptrCast(s))) });
    }
    var buf: [64]u8 = undefined;
    const np = std.fmt.bufPrint(&buf, "{s}  ", .{prefix}) catch prefix;
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(s)), c.gst_discoverer_container_info_get_type()) != 0) {
        out("{s}  ctags={s}", .{ prefix, tagsS(c.gst_discoverer_container_info_get_tags(@ptrCast(s))) });
        const streams = c.gst_discoverer_container_info_get_streams(@ptrCast(s));
        var l = streams;
        while (l != null) : (l = l[0].next) dumpStream(np, @ptrCast(l[0].data));
        c.gst_discoverer_stream_info_list_free(streams);
    }
    const prev = c.gst_discoverer_stream_info_get_previous(s);
    if (prev != null) {
        out("{s}  prev={s}", .{ prefix, z(c.gst_discoverer_stream_info_get_stream_type_nick(prev)) });
        c.g_object_unref(prev);
    }
    const next = c.gst_discoverer_stream_info_get_next(s);
    if (next != null) {
        out("{s}  next:", .{prefix});
        dumpStream(np, next);
        c.g_object_unref(next);
    }
}

fn relUri(u: [*c]const u8) []const u8 {
    const s = z(u);
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

fn dumpInfo(info: ?*c.GstDiscovererInfo, err: [*c]c.GError) void {
    if (info == null) {
        out("  info - err={s}", .{z(if (err != null) err[0].message else null)});
        return;
    }
    out("  uri={s} result={d} dur={d} seek={d} live={d} tags={s} toc={d} misc={d} err={s}", .{ relUri(c.gst_discoverer_info_get_uri(info)), c.gst_discoverer_info_get_result(info), c.gst_discoverer_info_get_duration(info), c.gst_discoverer_info_get_seekable(info), c.gst_discoverer_info_get_live(info), tagsS(c.gst_discoverer_info_get_tags(info)), @intFromBool(c.gst_discoverer_info_get_toc(info) != null), @intFromBool(c.gst_discoverer_info_get_misc(info) != null), z(if (err != null) err[0].message else null) });
    const md = c.gst_discoverer_info_get_missing_elements_installer_details(info);
    if (md != null) {
        var i: usize = 0;
        while (md[i] != null) : (i += 1) out("  missing {s}", .{z(md[i])});
    }
    const si = c.gst_discoverer_info_get_stream_info(info);
    dumpStream("  ", si);
    if (si != null) c.g_object_unref(si);
    const lists = [_]struct { []const u8, *const fn (?*c.GstDiscovererInfo) callconv(.c) [*c]c.GList }{ .{ "all", c.gst_discoverer_info_get_stream_list }, .{ "audio", c.gst_discoverer_info_get_audio_streams }, .{ "video", c.gst_discoverer_info_get_video_streams }, .{ "subs", c.gst_discoverer_info_get_subtitle_streams }, .{ "cont", c.gst_discoverer_info_get_container_streams } };
    for (lists) |e| {
        const l = e[1](info);
        out("  list {s} {d}", .{ e[0], c.g_list_length(l) });
        c.gst_discoverer_stream_info_list_free(l);
    }
    const prof = c.gst_encoding_profile_from_discoverer(info);
    if (prof != null) {
        const s = c.gst_encoding_profile_to_string(prof);
        out("  profile {s} {s}", .{ z(c.g_type_name_from_instance(@ptrCast(@alignCast(prof)))), z(s) });
        c.g_free(s);
        c.g_object_unref(prof);
    } else out("  profile -", .{});
    const has_si = c.gst_discoverer_info_get_stream_info(info) != null;
    if (has_si and (c.gst_discoverer_info_get_result(info) == c.GST_DISCOVERER_OK or c.gst_discoverer_info_get_result(info) == c.GST_DISCOVERER_MISSING_PLUGINS)) {
        for ([_]c.GstDiscovererSerializeFlags{ c.GST_DISCOVERER_SERIALIZE_BASIC, c.GST_DISCOVERER_SERIALIZE_ALL }) |f| {
            const v = c.gst_discoverer_info_to_variant(info, f);
            const back = c.gst_discoverer_info_from_variant(v);
            out("  variant {s} size {d}", .{ c.g_variant_get_type_string(v), @as(usize, 0) });
            if (f == c.GST_DISCOVERER_SERIALIZE_ALL) {
                out("  roundtrip:", .{});
                dumpStream("    ", c.gst_discoverer_info_get_stream_info(back));
                out("    rt uri={s} dur={d} n={d}", .{ relUri(c.gst_discoverer_info_get_uri(back)), c.gst_discoverer_info_get_duration(back), c.g_list_length(c.gst_discoverer_info_get_stream_list(back)) });
            }
            c.g_object_unref(back);
            c.g_variant_unref(v);
        }
    }
    const cp = c.gst_discoverer_info_copy(info);
    out("  copy result={d} n={d} same-dur={d}", .{ c.gst_discoverer_info_get_result(cp), c.g_list_length(c.gst_discoverer_info_get_stream_list(cp)), @intFromBool(c.gst_discoverer_info_get_duration(cp) == c.gst_discoverer_info_get_duration(info)) });
    c.g_object_unref(cp);
}

var loop: ?*c.GMainLoop = null;

fn onStarting(_: ?*c.GstDiscoverer, _: c.gpointer) callconv(.c) void {
    out("async starting", .{});
}

fn onDiscovered(_: ?*c.GstDiscoverer, info: ?*c.GstDiscovererInfo, err: [*c]c.GError, _: c.gpointer) callconv(.c) void {
    out("async discovered", .{});
    dumpInfo(info, err);
}

fn onFinished(_: ?*c.GstDiscoverer, _: c.gpointer) callconv(.c) void {
    out("async finished", .{});
    c.g_main_loop_quit(loop);
}

fn onSource(_: ?*c.GstDiscoverer, src: ?*c.GstElement, _: c.gpointer) callconv(.c) void {
    out("  source-setup {s}", .{z(c.g_type_name_from_instance(@ptrCast(@alignCast(src))))});
}

pub fn main() void {
    _ = c.g_setenv("LC_ALL", "C", 1);
    const cwd = c.g_get_current_dir();
    dir = c.g_build_filename(cwd, "zig-out", "pbmedia", NONE);
    _ = c.g_mkdir_with_parents(dir, 0o755);
    _ = c.g_spawn_command_line_sync("rm -rf zig-out/pbmedia/cache", null, null, null, null);
    _ = c.g_setenv("XDG_CACHE_HOME", path("cache"), 1);
    c.gst_init(null, null);
    generate("av.ogg", "oggmux name=m ! filesink location=\"%s\" videotestsrc num-buffers=10 ! video/x-raw,width=64,height=48,framerate=10/1 ! theoraenc ! m. audiotestsrc num-buffers=10 samplesperbuffer=4410 ! audio/x-raw,rate=44100,channels=2 ! audioconvert ! vorbisenc ! m.");
    generate("tone.wav", "audiotestsrc num-buffers=5 ! audio/x-raw,format=S16LE,rate=8000,channels=1 ! wavenc");
    generate("pic.png", "videotestsrc num-buffers=1 ! video/x-raw,width=16,height=8 ! pngenc");
    generate("song.flac", "audiotestsrc num-buffers=4 ! audio/x-raw,rate=22050,channels=2 ! flacenc");
    generate("vp8.webm", "videotestsrc num-buffers=5 ! video/x-raw,width=32,height=32,framerate=5/1 ! vp8enc ! webmmux");
    const srt = path("subs.srt");
    _ = c.g_file_set_contents(srt, "1\n00:00:00,000 --> 00:00:01,000\nHello\n\n2\n00:00:01,500 --> 00:00:02,000\nWorld\n", -1, null);
    const junk = path("junk.bin");
    const junk_data = "\x00\x01\x02\x03 this is not media at all \x7f\x80";
    _ = c.g_file_set_contents(junk, junk_data, junk_data.len, null);
    const empty = path("empty.dat");
    _ = c.g_file_set_contents(empty, "", 0, null);

    const dc = c.gst_discoverer_new(5 * c.GST_SECOND, null);
    var t: u64 = 0;
    var uc: c.gboolean = 0;
    c.g_object_get(dc, "timeout", &t, "use-cache", &uc, NONE);
    out("props timeout={d} cache={d}", .{ t, uc });
    for ([_][*c]const u8{ "av.ogg", "tone.wav", "pic.png", "song.flac", "vp8.webm", "subs.srt", "junk.bin", "empty.dat", "missing.ogg" }) |n| {
        out("sync {s}", .{z(n)});
        mask_tags = std.mem.eql(u8, z(n), "subs.srt");
        var err: [*c]c.GError = null;
        const info = c.gst_discoverer_discover_uri(dc, uri(n), &err);
        dumpInfo(info, err);
        if (info != null) c.g_object_unref(info);
        if (err != null) c.g_error_free(err);
    }
    mask_tags = false;
    out("sync bad-uri", .{});
    var err: [*c]c.GError = null;
    dumpInfo(c.gst_discoverer_discover_uri(dc, "nosuchproto://x", &err), err);

    c.g_object_set(dc, "use-cache", @as(c.gboolean, 1), NONE);
    for (0..2) |i| {
        out("cache pass {d}", .{i});
        const info = c.gst_discoverer_discover_uri(dc, uri("tone.wav"), null);
        dumpInfo(info, null);
        c.g_object_unref(info);
    }
    c.g_object_set(dc, "use-cache", @as(c.gboolean, 0), NONE);
    c.gst_object_unref(dc);

    loop = c.g_main_loop_new(null, 0);
    const ad = c.gst_discoverer_new(5 * c.GST_SECOND, null);
    _ = c.g_signal_connect_data(ad, "starting", @ptrCast(&onStarting), null, null, 0);
    _ = c.g_signal_connect_data(ad, "discovered", @ptrCast(&onDiscovered), null, null, 0);
    _ = c.g_signal_connect_data(ad, "finished", @ptrCast(&onFinished), null, null, 0);
    _ = c.g_signal_connect_data(ad, "source-setup", @ptrCast(&onSource), null, null, 0);
    c.gst_discoverer_start(ad);
    c.gst_discoverer_start(ad);
    for ([_][*c]const u8{ "tone.wav", "pic.png", "junk.bin", "av.ogg" }) |n| out("queue {d}", .{c.gst_discoverer_discover_uri_async(ad, uri(n))});
    c.g_main_loop_run(loop);
    c.gst_discoverer_stop(ad);
    c.gst_discoverer_stop(ad);
    c.gst_object_unref(ad);

    out("checks", .{});
    _ = c.gst_discoverer_new(c.GST_CLOCK_TIME_NONE, null);
    _ = c.gst_discoverer_discover_uri(null, "x", null);
    const d2 = c.gst_discoverer_new(c.GST_SECOND, null);
    _ = c.gst_discoverer_discover_uri(d2, null, null);
    c.gst_discoverer_start(null);
    c.gst_discoverer_stop(null);
    _ = c.gst_discoverer_discover_uri_async(null, "x");
    c.g_object_set(d2, "timeout", @as(u64, 7), NONE);
    _ = c.gst_discoverer_info_to_variant(null, 0);
    _ = c.gst_discoverer_info_from_variant(null);
    _ = c.gst_discoverer_info_copy(null);
    _ = c.gst_discoverer_stream_info_get_caps(null);
    _ = c.gst_discoverer_audio_info_get_channels(null);
    _ = c.gst_discoverer_audio_info_get_channel_mask(null);
    _ = c.gst_discoverer_video_info_get_width(null);
    _ = c.gst_discoverer_video_info_is_image(null);
    _ = c.gst_discoverer_subtitle_info_get_language(null);
    _ = c.gst_discoverer_info_get_uri(null);
    _ = c.gst_discoverer_info_get_duration(null);
    _ = c.gst_discoverer_info_get_stream_info(null);
    _ = c.gst_discoverer_container_info_get_streams(null);
    out("nick {s}", .{z(c.gst_discoverer_stream_info_get_stream_type_nick(null))});
    c.gst_object_unref(d2);
}
