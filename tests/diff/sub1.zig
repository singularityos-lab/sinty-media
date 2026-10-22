const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const N: ?*anyopaque = null;

var last_caps: [*c]u8 = null;

fn handoff(_: ?*c.GstElement, b: [*c]c.GstBuffer, pad: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    const caps = c.gst_pad_get_current_caps(pad);
    if (caps != null) {
        const s = c.gst_caps_to_string(caps);
        if (last_caps == null or c.strcmp(last_caps, s) != 0) {
            out("    caps {s}", .{z(s)});
            c.g_free(last_caps);
            last_caps = c.g_strdup(s);
        }
        c.g_free(s);
        c.gst_caps_unref(caps);
    }
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    const esc = c.g_strescape(@ptrCast(c.g_strndup(map.data, map.size)), null);
    out("    buffer pts {d} dur {d} [{s}]", .{ @as(i64, @bitCast(b.*.pts)), @as(i64, @bitCast(b.*.duration)), z(esc) });
    c.gst_buffer_unmap(b, &map);
}

fn probe(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const e: [*c]c.GstEvent = @ptrCast(@alignCast(info.*.data));
    if (e.*.type == c.GST_EVENT_TAG) {
        var tl: ?*c.GstTagList = null;
        c.gst_event_parse_tag(e, &tl);
        const s = c.gst_tag_list_to_string(tl);
        out("    tags {s}", .{z(s)});
        c.g_free(s);
    } else if (e.*.type == c.GST_EVENT_SEGMENT) {
        var seg: [*c]const c.GstSegment = null;
        c.gst_event_parse_segment(e, &seg);
        out("    segment fmt {d} start {d}", .{ seg.*.format, seg.*.start });
    }
    return c.GST_PAD_PROBE_OK;
}

fn scenario(title: []const u8, caps: []const u8, element: []const u8, filter: []const u8, chunks: []const []const u8) void {
    out("scenario {s}", .{title});
    const desc = std.fmt.allocPrintSentinel(A, "appsrc name=src format=bytes caps=\"{s}\" ! {s} name=p {s} ! fakesink name=sink signal-handoffs=true sync=false", .{ caps, element, filter }, 0) catch unreachable;
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(desc.ptr, &err);
    if (p == null) {
        out("  parse error {s}", .{z(err.*.message)});
        return;
    }
    const bin: *c.GstBin = @ptrCast(@alignCast(p));
    const src = c.gst_bin_get_by_name(bin, "src");
    const sink = c.gst_bin_get_by_name(bin, "sink");
    const parser = c.gst_bin_get_by_name(bin, "p");
    const sp = c.gst_element_get_static_pad(sink, "sink");
    _ = c.gst_pad_add_probe(sp, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, probe, null, null);
    c.gst_object_unref(sp);
    _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&handoff), null, null, 0);
    c.g_free(last_caps);
    last_caps = null;
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    var offset: u64 = 0;
    for (chunks) |ch| {
        const b = c.gst_buffer_new_allocate(null, ch.len, null);
        _ = c.gst_buffer_fill(b, 0, ch.ptr, ch.len);
        b.*.offset = offset;
        offset += ch.len;
        var ret: c.GstFlowReturn = 0;
        c.g_signal_emit_by_name(src, "push-buffer", b, &ret);
        c.gst_buffer_unref(b);
    }
    var ret: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(src, "end-of-stream", &ret);
    const bus = c.gst_element_get_bus(p);
    const m = c.gst_bus_timed_pop_filtered(bus, 5 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    if (m == null) {
        out("  timeout", .{});
    } else {
        if (m.*.type == c.GST_MESSAGE_ERROR) {
            var e: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            c.gst_message_parse_error(m, &e, &dbg);
            const d = z(dbg);
            const cut = if (std.mem.indexOf(u8, d, ": /")) |i| d[0..i] else d;
            out("  error {s} {d} [{s}] [{s}]", .{ z(c.g_quark_to_string(e.*.domain)), e.*.code, z(e.*.message), cut });
            c.g_error_free(e);
            c.g_free(dbg);
        } else out("  eos", .{});
        c.gst_message_unref(m);
    }
    var pos: i64 = 0;
    out("  position {d} {d}", .{ c.gst_element_query_position(parser, c.GST_FORMAT_TIME, &pos), pos });
    _ = c.g_signal_handlers_disconnect_matched(sink, c.G_SIGNAL_MATCH_FUNC, 0, 0, null, @constCast(@ptrCast(&handoff)), null);
    out("  null {d}", .{c.gst_element_set_state(p, c.GST_STATE_NULL)});
    c.gst_object_unref(bus);
    c.gst_object_unref(src);
    c.gst_object_unref(sink);
    c.gst_object_unref(parser);
    c.gst_object_unref(p);
}

fn typefind(title: []const u8, data: []const u8) void {
    const b = c.gst_buffer_new_allocate(null, data.len, null);
    _ = c.gst_buffer_fill(b, 0, data.ptr, data.len);
    var prob: c.GstTypeFindProbability = 0;
    const caps = c.gst_type_find_helper_for_buffer(null, b, &prob);
    const s = if (caps != null) c.gst_caps_to_string(caps) else null;
    out("typefind {s}: {s} prob {d}", .{ title, z(s), prob });
    c.g_free(s);
    if (caps != null) c.gst_caps_unref(caps);
    c.gst_buffer_unref(b);
}

const srt = "1\r\n00:00:01,000 --> 00:00:02,500\r\nHello <i>world</i> & <b>bold\r\n\r\n2\n00:00:03,000 --> 00:00:04,000\n<font color=\"red\">tag</font> <u>u</u>\nsecond line\n\n3\n00:00:05.5 --> 00:00:06.25\nshort ms </b>stray\n";
const vtt = "WEBVTT\n\n00:01.000 --> 00:02.000 align:start line:10% position:20% size:30% vertical:rl\n<v Bob>Hi</v> <c.red>there</c> <ruby>x<rt>y</rt></ruby>\n\n00:00:03.000 --> 00:00:05.000 L:-2\n<i>open\n\n";
const mdvd = "{1}{1}25.000\n{25}{50}Line one|Line two\n{75}{100}{y:i}italic{y:b}|/slash & <amp>|{s:12}big\n{200}{150}backwards\n";
const mpl2 = "[10][25] first|/second\n[30][45]/whole & italic\n[50][40] neg\n";
const tmp = "00:00:01:hello|there\n00:00:04:next\n00:00:09=\n0:00:12,1=multi\n0:00:12,2=line\n0:00:20:last\n";
const sami = "<SAMI><HEAD><TITLE>x</TITLE></HEAD><BODY>\n<SYNC Start=1000><P Class=KRCC>Hello &amp; &eacute;t&#233; &#x41;<br>next\n<SYNC Start=2500><P><font color=\"ff0000\" face=\"Sans\">red</font> <i>it</i>\n<SYNC Start=4000><P><ruby>base<rt>top</rt></ruby>\n<SYNC Start=6000><P>&nbsp;\n</BODY></SAMI>\n";
const dks = "[00:00:01]Hello[br]world\n[00:00:03]\n[00:00:05]Second\n[00:00:08]\n";
const subviewer = "[INFORMATION]\n[TITLE]x\n[END INFORMATION]\n00:00:01.00,00:00:03.00\nFirst[br]line\n\n00:00:04.50,00:00:06.00\nSecond\n\n";
const mpsub = "FORMAT=TIME\n\n1.5 2\nFirst\n\n0.5 1.25\nSecond line\nmore\n\n";
const qttext = "{QTtext}{font:Arial}{size:16}{textColor:65535,0,0}{backColor:0,0,65535}{timescale:100}\n[00:00:01.00]\n{bold}Hello\nworld\n[00:00:02.50]\n{italic}Next\n[00:00:04.00]\n";
const lrc = "[00:01.00]first\n[00:02.50]second\n[01:00.123]third\n";

pub fn main() void {
    c.gst_init(null, null);
    for ([_][*c]const u8{ "subparse", "ssaparse" }) |n| ins.element(n);
    const names = [_][]const u8{ "srt", "vtt", "mdvd", "mpl2", "tmp", "sami", "dks", "subviewer", "mpsub", "qttext", "lrc" };
    const datas = [_][]const u8{ srt, vtt, mdvd, mpl2, tmp, sami, dks, subviewer, mpsub, qttext, lrc };
    for (names, datas) |n, d| typefind(n, d);
    typefind("utf16", "\xff\xfe1\x00\n\x00");
    typefind("garbage", "nothing to see here at all");
    for (names, datas) |n, d| scenario(n, "application/x-subtitle", "subparse", "", &.{d});
    scenario("srt split", "application/x-subtitle", "subparse", "", &.{ srt[0..20], srt[20..61], srt[61..] });
    scenario("srt utf8 out", "application/x-subtitle", "subparse", "! capsfilter caps=text/x-raw,format=utf8", &.{srt});
    scenario("mdvd utf8 out", "application/x-subtitle", "subparse", "! capsfilter caps=text/x-raw,format=utf8", &.{mdvd});
    scenario("latin1", "application/x-subtitle", "subparse subtitle-encoding=ISO-8859-1", "", &.{"1\n00:00:01,000 --> 00:00:02,000\ncaf\xe9 na\xefve\n\n"});
    scenario("bom", "application/x-subtitle", "subparse", "", &.{"\xef\xbb\xbf1\n00:00:01,000 --> 00:00:02,000\nbom text\n\n"});
    scenario("unknown", "application/x-subtitle", "subparse", "", &.{"this is not a subtitle file\n"});
    scenario("ssa unframed", "application/x-ssa", "ssaparse", "", &.{"0,0,Default,,0,0,0,,text"});
    scenario("ssa", "application/x-ssa,codec_data=(buffer)5b53637269707420496e666f5d0a", "ssaparse", "", &.{ "1,0,Default,,0,0,0,,{\\b1}Hello\\Nworld\\h<x>", "2,0,Default,,0,0,0,,{\\i1}two\\n" });
    scenario("ssa no header", "application/x-ssa,codec_data=(buffer)616263", "ssaparse", "", &.{"1,0,Default,,0,0,0,,x"});
    out("done", .{});
}
