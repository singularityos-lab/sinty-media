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

fn z(p: [*:0]const u8) [*c]const u8 {
    return p;
}

const end: ?*anyopaque = null;
var base_seq: u32 = 0;

fn show(label: []const u8, e: [*c]c.GstEvent) void {
    if (e == null) {
        out("{s}: (null)", .{label});
        return;
    }
    const s = c.gst_event_get_structure(e);
    const ss = if (s != null) c.gst_structure_to_string(s) else null;
    out("{s}: type {s} quark {s} flags {d} sticky {d} seq +{d} ts {d} struct {s}", .{ label, str(c.gst_event_type_get_name(e.*.type)), str(c.g_quark_to_string(c.gst_event_type_to_quark(e.*.type))), c.gst_event_type_get_flags(e.*.type), c.gst_event_type_to_sticky_ordering(e.*.type), c.gst_event_get_seqnum(e) -% base_seq, e.*.timestamp, str(ss) });
    c.g_free(ss);
}

pub fn main() void {
    c.gst_init(null, null);
    const types = [_]c_uint{ c.GST_EVENT_UNKNOWN, c.GST_EVENT_FLUSH_START, c.GST_EVENT_SEGMENT, c.GST_EVENT_INSTANT_RATE_CHANGE, c.GST_EVENT_CUSTOM_BOTH_OOB, c.GST_EVENT_INSTANT_RATE_SYNC_TIME, 12345 };
    for (types) |t| out("t {d} {s} q {s} f {d} o {d}", .{ t, str(c.gst_event_type_get_name(t)), str(c.g_quark_to_string(c.gst_event_type_to_quark(t))), c.gst_event_type_get_flags(t), c.gst_event_type_to_sticky_ordering(t) });

    const fs = c.gst_event_new_flush_start();
    base_seq = c.gst_event_get_seqnum(fs);
    show("flush-start", fs);
    const fst = c.gst_event_new_flush_stop(1);
    show("flush-stop", fst);
    var b: c.gboolean = 0;
    c.gst_event_parse_flush_stop(fst, &b);
    out("  reset {d}", .{b});

    var list: [*c]c.GList = null;
    list = c.g_list_append(list, @constCast("a"));
    list = c.g_list_append(list, @constCast("b"));
    const sel = c.gst_event_new_select_streams(list);
    show("select", sel);
    var got: [*c]c.GList = null;
    c.gst_event_parse_select_streams(sel, &got);
    out("  n {d} {s}", .{ c.g_list_length(got), str(@ptrCast(got.*.next.*.data)) });
    c.g_list_free_full(got, c.g_free);
    c.g_list_free(list);
    show("select null", c.gst_event_new_select_streams(null));

    const gd = c.gst_event_new_stream_group_done(7);
    show("group-done", gd);
    var g: c_uint = 0;
    c.gst_event_parse_stream_group_done(gd, &g);
    out("  group {d}", .{g});
    show("group-done bad", c.gst_event_new_stream_group_done(c.GST_GROUP_ID_INVALID));
    show("eos", c.gst_event_new_eos());

    const gap = c.gst_event_new_gap(1000, 500);
    var ts: u64 = 0;
    var du: u64 = 0;
    c.gst_event_parse_gap(gap, &ts, &du);
    var gf: c.GstGapFlags = 99;
    c.gst_event_parse_gap_flags(gap, &gf);
    out("  gap {d} {d} flags {d}", .{ ts, du, gf });
    c.gst_event_set_gap_flags(gap, c.GST_GAP_FLAG_MISSING_DATA);
    c.gst_event_parse_gap_flags(gap, &gf);
    show("gap", gap);
    out("  flags {d}", .{gf});
    show("gap bad", c.gst_event_new_gap(c.GST_CLOCK_TIME_NONE, 0));

    const caps = c.gst_caps_from_string("video/x-raw, width=(int)320");
    const ce = c.gst_event_new_caps(caps);
    show("caps", ce);
    var pc: ?*c.GstCaps = null;
    c.gst_event_parse_caps(ce, @ptrCast(&pc));
    out("  same {d}", .{@intFromBool(pc == caps)});
    const unfixed = c.gst_caps_from_string("video/x-raw, width=(int)[1,2]");
    show("caps unfixed", c.gst_event_new_caps(unfixed));

    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    seg.start = 5;
    const se = c.gst_event_new_segment(&seg);
    show("segment", se);
    var ps: [*c]const c.GstSegment = null;
    c.gst_event_parse_segment(se, &ps);
    var cs: c.GstSegment = undefined;
    c.gst_event_copy_segment(se, &cs);
    out("  start {d} copy {d}", .{ ps.*.start, cs.start });
    seg.rate = 0;
    show("segment bad", c.gst_event_new_segment(&seg));

    const tl = c.gst_tag_list_new(z("title"), z("T"), end);
    const te = c.gst_event_new_tag(tl);
    show("tag", te);
    const gl = c.gst_tag_list_new(z("title"), z("G"), end);
    c.gst_tag_list_set_scope(gl, c.GST_TAG_SCOPE_GLOBAL);
    show("tag global", c.gst_event_new_tag(gl));
    var pt: [*c]c.GstTagList = null;
    c.gst_event_parse_tag(te, &pt);
    out("  tag same {d}", .{@intFromBool(pt == tl)});

    const bs = c.gst_event_new_buffer_size(c.GST_FORMAT_BYTES, 10, 20, 1);
    show("bufsize", bs);
    var f: c.GstFormat = 0;
    var mn: i64 = 0;
    var mx: i64 = 0;
    var asy: c.gboolean = 0;
    c.gst_event_parse_buffer_size(bs, &f, &mn, &mx, &asy);
    out("  {d} {d} {d} {d}", .{ f, mn, mx, asy });

    const q = c.gst_event_new_qos(c.GST_QOS_TYPE_UNDERFLOW, 1.25, -400, 1000);
    show("qos", q);
    var qt: c.GstQOSType = 0;
    var prop: f64 = 0;
    var diff: i64 = 0;
    var qts: u64 = 0;
    c.gst_event_parse_qos(q, &qt, &prop, &diff, &qts);
    out("  {d} {d} {d} {d}", .{ qt, prop, diff, qts });
    c.gst_event_set_running_time_offset(q, -800);
    c.gst_event_parse_qos(q, null, null, null, &qts);
    out("  off -800 ts {d} rto {d}", .{ qts, c.gst_event_get_running_time_offset(q) });
    c.gst_event_set_running_time_offset(q, 300);
    c.gst_event_parse_qos(q, null, null, null, &qts);
    out("  off 300 ts {d}", .{qts});
    show("qos bad", c.gst_event_new_qos(c.GST_QOS_TYPE_OVERFLOW, 1.0, -2000, 1000));

    const sk = c.gst_event_new_seek(1.5, c.GST_FORMAT_TIME, c.GST_SEEK_FLAG_FLUSH | c.GST_SEEK_FLAG_KEY_UNIT | c.GST_SEEK_FLAG_SNAP_AFTER, c.GST_SEEK_TYPE_SET, 100, c.GST_SEEK_TYPE_END, -1);
    show("seek", sk);
    var rate: f64 = 0;
    var sf: c.GstSeekFlags = 0;
    var st1: c.GstSeekType = 0;
    var st2: c.GstSeekType = 0;
    var sv1: i64 = 0;
    var sv2: i64 = 0;
    c.gst_event_parse_seek(sk, &rate, &f, &sf, &st1, &sv1, &st2, &sv2);
    out("  {d} {d} {d} {d} {d} {d} {d}", .{ rate, f, sf, st1, sv1, st2, sv2 });
    var iv: u64 = 0;
    c.gst_event_parse_seek_trickmode_interval(sk, &iv);
    c.gst_event_set_seek_trickmode_interval(sk, 42);
    c.gst_event_parse_seek_trickmode_interval(sk, &iv);
    out("  interval {d}", .{iv});
    show("seek snap", c.gst_event_new_seek(1.0, c.GST_FORMAT_TIME, c.GST_SEEK_FLAG_SNAP_BEFORE | c.GST_SEEK_FLAG_ACCURATE, c.GST_SEEK_TYPE_SET, 0, c.GST_SEEK_TYPE_NONE, 0));
    show("seek instant bad", c.gst_event_new_seek(1.0, c.GST_FORMAT_TIME, c.GST_SEEK_FLAG_INSTANT_RATE_CHANGE, c.GST_SEEK_TYPE_SET, 0, c.GST_SEEK_TYPE_NONE, 0));
    show("seek rate0", c.gst_event_new_seek(0.0, c.GST_FORMAT_TIME, 0, c.GST_SEEK_TYPE_SET, 0, c.GST_SEEK_TYPE_NONE, 0));

    show("nav", c.gst_event_new_navigation(c.gst_structure_new_empty("application/x-gst-navigation")));
    const lat = c.gst_event_new_latency(77);
    show("latency", lat);
    c.gst_event_parse_latency(lat, &iv);
    out("  {d}", .{iv});
    const stp = c.gst_event_new_step(c.GST_FORMAT_BUFFERS, 3, 2.0, 1, 0);
    show("step", stp);
    var amt: u64 = 0;
    var fl: c.gboolean = 0;
    var im: c.gboolean = 0;
    c.gst_event_parse_step(stp, &f, &amt, &rate, &fl, &im);
    out("  {d} {d} {d} {d} {d}", .{ f, amt, rate, fl, im });
    show("step bad", c.gst_event_new_step(c.GST_FORMAT_BUFFERS, 3, -1.0, 1, 0));
    show("reconfigure", c.gst_event_new_reconfigure());
    show("sink-message null", c.gst_event_new_sink_message("x", null));

    const ss = c.gst_event_new_stream_start("sid");
    show("stream-start", ss);
    var sid: [*c]const u8 = null;
    c.gst_event_parse_stream_start(ss, &sid);
    var sfl: c.GstStreamFlags = 9;
    c.gst_event_parse_stream_flags(ss, &sfl);
    out("  sid {s} flags {d} group {d} g {d}", .{ str(sid), sfl, c.gst_event_parse_group_id(ss, &g), g });
    c.gst_event_set_group_id(ss, 5);
    c.gst_event_set_stream_flags(ss, c.GST_STREAM_FLAG_SPARSE);
    const stream = c.gst_stream_new("sid", null, c.GST_STREAM_TYPE_AUDIO, 0);
    c.gst_event_set_stream(ss, stream);
    var ps2: ?*c.GstStream = null;
    c.gst_event_parse_stream(ss, @ptrCast(&ps2));
    out("  group {d} g {d} stream {s}", .{ c.gst_event_parse_group_id(ss, &g), g, str(c.gst_stream_get_stream_id(ps2)) });
    if (ps2) |p| c.gst_object_unref(p);
    const sss = c.gst_structure_to_string(c.gst_event_get_structure(ss));
    out("  {d}", .{@intFromBool(sss != null)});
    c.g_free(sss);
    c.gst_event_set_group_id(ss, c.GST_GROUP_ID_INVALID);

    const col = c.gst_stream_collection_new("up");
    const ce2 = c.gst_event_new_stream_collection(col);
    out("collection type {s}", .{str(c.gst_event_type_get_name(ce2.*.type))});
    var pcol: ?*c.GstStreamCollection = null;
    c.gst_event_parse_stream_collection(ce2, @ptrCast(&pcol));
    out("  {s}", .{str(c.gst_stream_collection_get_upstream_id(pcol))});
    if (pcol) |p| c.gst_object_unref(p);
    show("collection bad", c.gst_event_new_stream_collection(@ptrCast(stream)));

    const toc = c.gst_toc_new(c.GST_TOC_SCOPE_CURRENT);
    const toce = c.gst_event_new_toc(toc, 1);
    out("toc type {s} name {s}", .{ str(c.gst_event_type_get_name(toce.*.type)), str(c.gst_structure_get_name(c.gst_event_get_structure(toce))) });
    var ptoc: ?*c.GstToc = null;
    var upd: c.gboolean = 0;
    c.gst_event_parse_toc(toce, &ptoc, &upd);
    out("  same {d} upd {d}", .{ @intFromBool(ptoc == toc), upd });
    const tsel = c.gst_event_new_toc_select("uid1");
    show("toc-select", tsel);
    var uid: [*c]u8 = null;
    c.gst_event_parse_toc_select(tsel, &uid);
    out("  {s}", .{str(uid)});
    c.g_free(uid);

    const buf = c.gst_buffer_new_allocate(null, 4, null);
    const pe = c.gst_event_new_protection("sys", buf, "isobmff/pssh");
    out("protection name {s}", .{str(c.gst_structure_get_name(c.gst_event_get_structure(pe)))});
    const pe2 = c.gst_event_new_protection("sys", buf, null);
    out("protection name {s}", .{str(c.gst_structure_get_name(c.gst_event_get_structure(pe2)))});
    var psys: [*c]const u8 = null;
    var porig: [*c]const u8 = null;
    var pbuf: [*c]c.GstBuffer = null;
    c.gst_event_parse_protection(pe, &psys, &pbuf, &porig);
    out("  {s} {s} {d}", .{ str(psys), str(porig), @intFromBool(pbuf == buf) });
    c.gst_event_parse_protection(pe2, &psys, &pbuf, &porig);
    out("  {s} {s}", .{ str(psys), str(porig) });

    const sd = c.gst_event_new_segment_done(c.GST_FORMAT_TIME, 99);
    show("segment-done", sd);
    var pos: i64 = 0;
    c.gst_event_parse_segment_done(sd, &f, &pos);
    out("  {d} {d}", .{ f, pos });

    const irc = c.gst_event_new_instant_rate_change(2.0, c.GST_SEGMENT_FLAG_TRICKMODE | c.GST_SEGMENT_FLAG_RESET);
    show("irc", irc);
    var sgf: c.GstSegmentFlags = 0;
    c.gst_event_parse_instant_rate_change(irc, &rate, &sgf);
    out("  {d} {d}", .{ rate, sgf });
    const irs = c.gst_event_new_instant_rate_sync_time(0.5, 10, 20);
    show("irs", irs);
    var r1: u64 = 0;
    var r2: u64 = 0;
    c.gst_event_parse_instant_rate_sync_time(irs, &rate, &r1, &r2);
    out("  {d} {d} {d}", .{ rate, r1, r2 });

    const cu = c.gst_event_new_custom(c.GST_EVENT_CUSTOM_DOWNSTREAM, c.gst_structure_new_empty("my-event"));
    show("custom", cu);
    out("  has {d} {d} id {d}", .{ c.gst_event_has_name(cu, "my-event"), c.gst_event_has_name(cu, "x"), c.gst_event_has_name_id(cu, c.g_quark_from_string("my-event")) });
    const owned = c.gst_event_get_structure(cu);
    show("custom owned", c.gst_event_new_custom(c.GST_EVENT_CUSTOM_UPSTREAM, @constCast(owned)));
    const eos2 = c.gst_event_new_eos();
    out("has eos {d}", .{c.gst_event_has_name(eos2, "eos")});
    const ws = c.gst_event_writable_structure(eos2);
    c.gst_structure_set(ws, "x", c.G_TYPE_INT, @as(c_int, 1), end);
    show("eos writable", eos2);
    const cp = c.gst_event_copy(cu);
    show("copy", cp);
    c.gst_event_set_seqnum(cp, 1234);
    out("  seq {d}", .{c.gst_event_get_seqnum(cp)});
    c.gst_event_set_seqnum(cp, c.GST_SEQNUM_INVALID);
    _ = c.gst_event_ref(cp);
    c.gst_event_set_seqnum(cp, 5);
    c.gst_event_set_running_time_offset(cp, 5);
    out("  writable {d}", .{c.gst_event_is_writable(cp)});
    const w = c.gst_event_make_writable(cp);
    out("  made {d} diff {d}", .{ c.gst_event_is_writable(w), @intFromBool(w != cp) });

    out("wrong parse", .{});
    c.gst_event_parse_caps(fs, @ptrCast(&pc));
    c.gst_event_parse_seek(null, null, null, null, null, null, null, null);
    c.gst_event_parse_toc(fs, &ptoc, null);
    c.gst_event_parse_stream_start(null, &sid);
    out("{d}", .{c.gst_event_get_seqnum(null)});
    var slot: [*c]c.GstEvent = null;
    out("replace {d} take {d} steal {d}", .{ c.gst_event_replace(&slot, fs), c.gst_event_take(&slot, c.gst_event_new_eos()), @intFromBool(c.gst_event_steal(&slot) != null) });
    slot = c.gst_event_new_eos();
    c.gst_clear_event(&slot);
    out("cleared {d}", .{@intFromBool(slot == null)});
}
